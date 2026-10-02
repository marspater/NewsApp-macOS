# Active-work cancellation — 2 October 2026

Refs #104, #153, #90. Base: `49f0396`, including the merged source-reader and overview accessibility work. Apple M5 / 24 GiB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, SQLite 3.54.0; optimized arm64, deployment target macOS 15.

Run `./test.sh --performance-baseline --active-work-cancellation`. The first flag selects optimized compilation; the second selects the active-work workload instead of the complete core baseline. The command emits five samples per operation. [Raw evidence](../benchmarks/2026-10-02-active-work-cancellation.json) retains two complete optimized runs, ten samples per operation, including the slower rollback tail in the second run. The full regression suite exercises one cancellation per operation against the same fixtures.

## Transactional ingestion

The fixture starts with one saved/read article, its timestamps, indexed text, identities and original feed validators. A 20,001-row input first changes that article's title and body, then supplies 20,000 new rows with 8,360-character bodies. No production cache settings or schema are changed. The input is deliberately larger than a normal feed; it forces actual dirty-page spill before the batch reaches commit.

The observer waits for the temporary WAL to exceed 1 MiB and verifies the detached ingestion task has not finished. It then cancels `DatabaseEngine.upsertArticles`. Completion must throw `CancellationError` within two seconds. The measured endpoint includes transactional rollback, and excludes observer polling and fixture setup.

All article, state, alias, enrichment, feed-association, feed-metadata and FTS rows are compared with the original snapshot. The original searchable body survives; cancelled body text and every new row are absent. FTS integrity also passes after the repeated rollbacks. This verifies rollback of actual writes, including the changed existing row, rather than cancellation before a transaction starts.

WAL growth alone is insufficient for a smaller batch: it may first occur during commit, after the last cooperative cancellation check. [SQLite's cache-spill threshold](https://www.sqlite.org/pragma.html#pragma_cache_spill) governs when dirty pages can spill during the transaction. The larger fixture and required cancellation/rollback outcome ensure this test reaches active ingestion before commit. The 60-second readiness deadline is a failure bound for setup/progress, not a performance budget.

## Clustering

The second temporary library contains 400 articles across 20 publisher labels. Each sample resets their matcher version, starts the real `EventClusterer.run`, and waits until its database reports committed progress with pending rows still remaining. Every observed cancellation point had 399 pending rows. No injected sleep or cancellable mock is involved.

Task cancellation must complete with `CancellationError` within two seconds. All 400 source rows and the seeded read/save state survive. Already committed clustering progress remains valid; cancellation does not roll back the whole pass. A subsequent pass drains the remaining work, and another unchanged pass processes zero rows.

## Measurements and limits

Timings start immediately before `Task.cancel()` and end at the operation's completion timestamp inside its task. Synchronous locked completion observations avoid including actor notification or five-millisecond polling delays.

| Operation | Samples | Median ms | Sample p95 / maximum ms | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| Active ingestion cancellation and rollback | 10 | 6.542 | 17.098 | 21.4 ms |
| Active clustering cancellation | 10 | 0.989 | 2.131 | 2.7 ms |

Budgets allow 25% above the observed maximum, rounded upward to 0.1 ms, for these controlled service workloads on comparable hardware. With ten samples, nearest-rank sample p95 is the maximum; it is not a population-tail estimate. CI asserts state and a generous two-second completion deadline, never these timing budgets.

The tests use temporary SQLite files and synthetic `.example` URLs, with no network or model calls. Production sources, reserved tension calibration/collection work, real settings/library and installed app are unchanged. Full regressions are enforced by the mandatory commit hook; their result and hosted CI are recorded on the PR. An app rebuild is not required for this test/documentation-only slice.

This measures service-level cancellation in detached tasks. It does not promise interruption inside a single native SQLite/NaturalLanguage call, reversal of a transaction that already committed, or latency under arbitrary scheduler load. #104/#153 remain open for production launch/memory, representative network refresh and publisher/TLS behavior; the disconnected model path has no active-work measurement.
