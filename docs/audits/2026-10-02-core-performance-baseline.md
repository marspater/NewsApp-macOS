# Core-service performance baseline — 2 October 2026

## Reproduction and isolation

Run `./test.sh --performance-baseline`. Only this opt-in mode adds `-O`; default regression compilation remains unchanged. The existing test runner uses current services, temporary SQLite and an isolated defaults suite, with scheduling/notifications/model generation disabled. Cleanup removes only its own temporary fixtures. No network, production library or installed app is used.

Measured on Apple M5 / 24 GiB, arm64, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, minimum macOS 15. Source: `da3c58e` plus this harness. [Raw samples](../benchmarks/2026-10-02-core-baseline.json) retain every timing. Fixtures start with 10,000 stories across 20 publisher labels, each containing 2,030 characters and a reader image candidate. Hydration includes existing image-recurrence curation. The visible snapshot is 500 rows. Five mocked feeds return 50 articles each; first refresh inserts 250, the next nine repeat those batches. Final library: 10,250 rows.

## Measurements

All timings use monotonic process uptime. Percentiles use nearest rank; with ten samples p95 is the maximum. Initial snapshot has one sample, so it has no statistical percentile claim. Extraction input has 4,175 HTML characters, headings, two paragraphs and a figure. FTS returns the first 100 matching rows. Analysis uses the current NaturalLanguage/extractive fallback (`allowFoundationModels: false`); it is not a generative model probe.

| Operation | Samples | Median ms | Sample p95 ms |
|---|---:|---:|---:|
| `fts_first_100_ms` | 10 | 75.801 | 87.902 |
| `html_extraction_ms` | 10 | 179.281 | 193.446 |
| `natural_language_analysis_ms` | 10 | 7.052 | 21.779 |
| `refresh_5_mocked_feeds_ms` | 10 | 2972.193 | 4029.390 |
| `refresh_cancel_mock_wait_ms` | 10 | 0.022 | 0.037 |
| `snapshot_first_500_ms` | 1 | 78.495 | 78.495 |

Peak benchmark-process RSS was 107.56 MiB (112,787,456 bytes), including archive construction, SQLite, repeated hydration and analysis. It is not app-window memory. Initial snapshot hydration was 78.495 ms after seeding, not a cold disk/app launch. It is not first rendered card time.

Refresh cancellation times stop a manager while its injected fetch awaits cancellable Task.sleep, then wait for the refresh to return. They measure cooperative wait cancellation, not DNS/TLS, a CPU-bound batch or model cancellation. Assertions verify expected snapshots, archive count, FTS count, extraction and deterministic analysis.

## Provisional core budgets for #153

Use the same workload, optimized build and comparable hardware. These are investigation triggers, not cross-machine CI assertions or release guarantees. About 25% headroom above observed upper samples, rounded upward:

- Snapshot hydration: 100 ms (single observed sample; repeat on cold launch before accepting a UI target).
- FTS first 100: 110 ms.
- HTML extraction for this input: 250 ms.
- Deterministic analysis for this input: 30 ms, including first-use cost.
- Repeated five-feed ingestion/snapshot publication: 5.1 s. First ingest was 710 ms; do not compare the two workloads as identical samples.
- Benchmark process peak RSS: 135 MiB.
- Cooperative mocked-wait cancellation: 1 ms. Real transport, ingestion and model cancellation need separate budgets.

Repeated refreshes measured 2.85–4.03 s, materially slower than first ingestion. Profile repeated upsert/identity/state publication with existing signposts before adding clustering overhead or guessing a cause. This run does not justify a production optimization on its own.

## Remaining acceptance

#104 stays open: rendered first-card timing, actual app peak memory, controlled real transport/cancellation and FoundationModels analysis costs have not been measured here. Phase E's model work is excluded. #153 overview p50/p95 and full end-to-end targets remain unmeasured. #102 still requires an independently labeled holdout; synthetic timing fixtures establish no matching precision. G is complete per Mars and is unchanged.

The optimized benchmark completed with all workload assertions. Full regression/commit-hook results and PR state are logged on the issues.
