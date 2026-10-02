# Integrated performance verification — 2 October 2026

Refs #104, #153, #90. Production source: `635b0b2` (after #222); benchmark changes are in this slice. Apple M5, 24 GiB, arm64, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4; optimized compilation, deployment target macOS 15.

## Core services

Run `./test.sh --performance-baseline`. [Raw samples](../benchmarks/2026-10-02-integrated-core-baseline.json) retain the complete successful run. Compilation had finished before this measurement run. SQLite and defaults are temporary; no real library, notifications, network or generative model is involved.

The previous harness let FeedManager's initial catch-up compete with refresh, then timed five different slices of an unprocessed archive. This slice marks the initial 10,000 rows as previously matched, waits for follow-up clustering outside each collection timer, checks an unchanged pass processes zero rows, and resets the same 200 rows before each dense pass. Every dense sample asserts exactly 200 processed rows and no remaining pending work. These benchmark fixture changes are not a production matching shortcut.

The library still has 20 publisher labels, 2,030-character article bodies with image candidates, a 500-row store snapshot, and five mocked feeds returning 50 articles each. The first refresh inserts 250 rows; nine repeat the same batches. Final library: 10,250 rows. Dense candidates deliberately share generic research wording across the archive: this is a stress workload, not a representative publisher corpus or matching-quality evaluation.

Percentiles use nearest rank. With ten samples, sample p95 is the maximum; five dense samples likewise report their maximum. A single snapshot sample supports no statistical percentile claim.

| Operation | Samples | Median ms | Sample p95 ms | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| Snapshot hydration, first 500 | 1 | 76.281 | — | 100 ms |
| Refresh collection, first ingestion | 1 | 855.467 | — | 1.1 s |
| Refresh collection, nine identical repeats | 9 | 547.490 | 572.631 | 720 ms |
| FTS, first 100 | 10 | 66.411 | 70.897 | 90 ms |
| HTML extraction | 10 | 1.620 | 2.280 | 3 ms |
| NaturalLanguage / extractive analysis | 10 | 6.113 | 7.173 | 10 ms |
| Unchanged clustering pass | 10 | 11.755 | 12.360 | 16 ms; **zero rows processed** |
| Dense clustering, 200 reset rows | 5 | 15,867.576 | 16,092.638 | 20.2 s for this stress input |
| Event feed grouping | 10 | 0.301 | 0.434 | 0.6 ms |
| Deterministic overview generation and persistence | 10 | 21.334 | 25.948 | 33 ms |
| Persistent overview lookup | 10 | 0.034 | 0.086 | 0.12 ms |
| Cooperative mocked-wait refresh cancellation | 10 | 0.024 | 0.055 | 0.1 ms |

Core process peak RSS: 120.344 MiB, including fixture setup; investigation budget 155 MiB. Budgets allow approximately 25% headroom, rounded upward, and apply only to these inputs on comparable hardware. They are not CI timing assertions or release-wide guarantees. Earlier extraction numbers predate the current extractor; this is not a controlled attribution of its speedup.

The dense clustering cost merits separate profiling before optimization. It runs after collection, off MainActor, and does not define the refresh budget. No new refresh rematches the whole archive: both the existing clustering regressions and this 10,250-row unchanged-pass check enforce that invariant. Core cancellation measures an injected cancellable wait, not active TLS, parsing, SQLite writes or model generation.

## Native window

Run `./script/native_performance_baseline.sh [output-directory]` on an active Mac desktop. It compiles the real production MainView and dependencies with a separate AppKit entry point. The normal app delegate, notification authorization, installed bundle and production storage are not used. The script preserves JSON and the first-card PNG in the printed output directory.

The native fixture has 10,000 text-only stories across 20 publishers, already matched, and opens five 1100 × 800 point windows against the same seeded store. It checks the actual rendered bitmap using [Apple's on-device Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images). The measurement ends at capture of the first sampled bitmap containing the synthetic headline, before successful recognition finishes. Prior unsuccessful capture/recognition polls remain included, so this is an upper bound on rendering readiness, not an exact first-frame or cold-launch measurement. Memory includes fixture setup, SwiftUI, repeated windows and Vision overhead.

[Raw native samples](../benchmarks/2026-10-02-native-mainview-baseline.json): time to sampled rendered card was **407.293 ms median**, **454.578 ms sample p95** (five windows; observed range 398.587–454.578 ms). An investigation budget for this exact probe is **575 ms**. The first PNG was inspected and contains the expected headline and list cards. The single mocked feed inserted one row through the real collection/store path in **30.295 ms**; its one-sample investigation budget is **40 ms**. Final row count was 10,001, the loading indicator ended, and the expected feed-scoped ID was published.

Native probe peak RSS was **239.438 MiB**, with an investigation budget of **300 MiB**. This includes Vision and fixture setup and is explicitly not a shipping-app memory budget. These timings cannot be compared directly with the five-feed core workload: article bodies, feed count, ingestion size and measurement endpoints differ.

## Verification and remaining gates

Full `./test.sh`, the optimized core baseline with workload assertions, shell syntax and diff checks passed. The native script also passed, including Swift 6 compilation of all production sources with the separate entry point, five pixel-verified card samples and refresh persistence assertions. The mandatory commit hook reruns the full suite before publication; its result is logged on the PR. No shipping source, schema or entitlements changed; no installation or hosted CI result is implied.

#104 and #153 remain open for cold app launch, real transport and active-work cancellation, production app memory without the probe, and model costs if a generative path is connected. #155/#123 still require keyboard, VoiceOver, accessibility settings and reader/lifecycle interaction. #102's independently labelled holdout and #115's real problem pages remain separate user-input gates. Phase I stays after the core release.
