# Combined app workload — 5 October 2026

Refs #104, #153, #90. Extends the existing reading harness; no benchmark framework or shipping behavior changes. Current production scope is English-only. Parked #264 and #268 are excluded.

## Method

`NEWS_READING_FULL_APP=1 ./script/native_performance_baseline.sh <private output directory>` reuses `build.sh`, optimized Swift 6 arm64 compilation, macOS 15 deployment target, ad-hoc signing, App Sandbox and production entitlements. The bundle identifier is `com.marspater.news.workloadcheck`; it has its own container. The installed app, subscriptions, saved/read history and logs are not opened or replaced.

The existing AppKit harness invokes the exact `CacheManager.configureOfflineCache()` used at app-delegate startup (64 MiB memory capacity / 512 MiB disk capacity). It fetches the five English panel feeds, builds temporary SQLite storage/preferences, waits for initial clustering, then reads twenty distinct stories twice in one 1100 × 800 window. Each visit waits for a stored publisher document and all expected reader images to decode. Missing documents/images fail the run.

Next it generates ten independent deterministic overviews through `OverviewGenerationCoordinator` and the existing enrichment queue, using three stored publisher-text inputs. Every result must have citations and read back with the same ID from SQLite. These are controlled timing inputs, **not an assertion that the selected publications describe one event**. The production `EventOverviewReaderView` is mounted with a fresh identity and captured through AppKit; the first PNG is inspected locally, without publishing article text in this audit.

Finally five selected publisher pages load through production `ArticleWebView`, its nonpersistent WebKit storage, disabled publisher scripts, content rules and destination-pinning gateway. Success requires the native navigation delegate's `didFinish`, not merely an ended loading state. A notification observation hook is injected only into the temporary staged source, after the existing active-navigation guard. Shipping sources are unchanged. The hosting view is replaced with empty content before closing the window; footprint is sampled again after three seconds.

Footprint uses the existing `TASK_VM_INFO` physical-footprint ledger and a 50 ms sampler. Native navigation completion and bitmap capture are observable milestones, not exact first-frame presentation. The report records hardware, OS, toolchain, revision, local-change state, library size, cache usage, visits and operation samples. Live stories and ordering can vary between runs; comparisons are not fixed-content microbenchmarks. The isolated HTTP disk cache may be warm from earlier runs; this is not a cold-Web measurement.

## Results and budgets

Final native-completion-verified results are recorded in [raw evidence](../benchmarks/2026-10-05-full-app-workload.json).

Apple M5 / 24 GiB / Mac17,3, macOS 27.0.1, Xcode 27 / Swift 6.4. Source `0828ec4` plus the recorded harness changes. Temporary library: **133 rows**, twenty visited stories, five feeds, forty visits. All documents were ready; all **78 expected image loads** completed, zero failures. All ten overviews persisted with citations and all five publisher pages reached native `didFinish`.

| Final run measure | Median | Sample p95 (nearest rank) |
| --- | ---: | ---: |
| Overview generation + persisted readback | 55.3 ms | 100.4 ms |
| Overview mounted-view bitmap capture | 40.1 ms | 258.3 ms |
| Protected publisher Web navigation | 520.9 ms | 1434.8 ms |

With ten overview samples and five Web samples, nearest-rank p95 is the sample maximum, not a population tail estimate. Across the final run and two earlier sizing runs, overview generation reached 153.6 ms and mounted-view capture 441.1 ms. Variation comes from live content and desktop conditions; the raw file distinguishes the earlier, weaker Web completion checks from the final native-completion proof.

Final app lifetime peak: **195.8 MiB**; highest across the three sizing/completion runs: **214.2 MiB**. Footprint after reading passes: 133.0 / 155.8 MiB; three seconds after explicit content teardown and window close: 129.5 MiB. Two passes do not establish leak freedom. The 64 MiB shared cache is a capacity, not an eager 64 MiB allocation: final occupied response bytes were 12.36 MiB.

| Investigation trigger | Budget | Basis |
| --- | ---: | --- |
| Combined workload app-process lifetime peak | 270 MiB | Three observed sizing/completion runs |
| Overview generation + persisted readback | 200 ms | Largest observed ten-sample run maximum |
| Mounted overview bitmap capture | 560 ms | Largest observed capture maximum; includes synchronous snapshot cost |
| Five-page native Web navigation | 1.8 s | Final native-completion-verified maximum; network dependent |


These budgets apply only to this bounded combined workload, with roughly 25% headroom above observed maxima. They trigger investigation, not CI failures or publisher/model latency promises. Earlier 33 ms deterministic-core and 214 MiB reader-only budgets retain their different workloads; the combined workload does not retroactively replace them.

## Acceptance reconciliation

The [cold launch after purge plus rebuild](2026-10-05-cold-launch.md) already records the shipping startup path on a seeded 10,000-story library: first sample 1,203.3 ms, warm median 625.8 ms, 1.5 s cold investigation budget. This run completes the additional cache / reader / Web / deterministic-overview component evidence requested by #104/#153. Existing refresh, TLS and active parsing/ingestion/clustering cancellation evidence remains unchanged; unused model paths are not new gates.

Memory pressure and WebKit auxiliary-process footprint remain unverified. Reported memory is the app process, **not the total of the app plus WebContent/GPU/network services**. Notification authorization and the shipping `NewsApp` scene lifecycle are excluded from this combined harness; startup is covered separately by the existing launch audit. These boundaries prevent a general production-memory or release-readiness claim from this bounded workload. Parked language and live VoiceOver work is not restored to release gates.

## Validation

- Existing `./test.sh` regression suite passed; the required commit hook runs the same suite again before publication.
- Final documented combined-workload command passed: optimized arm64 compilation, strict bundle signature verification, document/image readiness, ten persisted/cited overviews, five native Web completions, exported JSON and inspected overview PNG.
- Shell syntax, JSON, local documentation links and `git diff --check` validated before publication.
- No installation, merge or hosted-CI result is implied.
