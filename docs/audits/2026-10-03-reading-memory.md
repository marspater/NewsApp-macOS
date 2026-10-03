# Memory while reading — 3 October 2026

Refs #153, #104, #90. Base: `c55acf0`. Apple M5 / 24 GiB (Mac17,3), macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4; optimized arm64.

Earlier slices measured launch and idle memory of the production bundle ([launch baseline](2026-10-02-launch-baseline.md): peak 88.2 MiB) but not reading. This slice reads live stories in the production reader.

## Method

`NEWS_NATIVE_HARNESS=Tests/NativeReadingMemory.swift ./script/native_performance_baseline.sh [output-dir]`. The existing native script now accepts a harness file; the default remains the first-card baseline.

The harness uses temporary storage and settings (AI and notifications off) and fetches the current items of five image-carrying panel feeds (BBC World, The Guardian World, Al Jazeera, DW English, CNA) through the app's own client. It takes exactly 20 distinct stories, four per feed where possible, and fails otherwise. It then shows the production `ArticleDetailView` for each story in turn in one 1100×800 window, with a new view identity per story as navigation creates, and reads all 20 twice in one process.

Before advancing, each story waits until a publisher document is stored (from the feed or from page extraction; 15-second limit) and until the reader reports each of its images (figures and lead image) decoded or failed (15-second limit). `ArticleRemoteImage` posts a `readerImageFinished` notification for this when a load completes; nothing listens in the app. A missing document or image marks the report incomplete and fails the run. A sampler reads the task's physical footprint (`TASK_VM_INFO`) every 50 ms; the lifetime peak comes from the same ledger.

## Results

[Raw evidence](../benchmarks/2026-10-03-reading-memory.json): two complete runs, 40 openings each, 98 images per run, all decoded. Openings took 0.7–1.7 seconds including the waits.

| Measure | Run 1 | Run 2 |
| --- | ---: | ---: |
| Before reading (after setup and live fetch) | 17.4 MiB | 17.3 MiB |
| Highest sampled while reading | 128.4 MiB | 153.7 MiB |
| Lifetime peak | 132.6 MiB | 159.1 MiB |
| After the first pass | 96.9 MiB | 114.0 MiB |
| After the second pass | 90.0 MiB | 131.2 MiB |
| 3 s after the window closed | 88.1 MiB | 129.1 MiB |

Investigation budget for reading 20 image-carrying stories: 199 MiB peak footprint, 25% above the highest observed peak, as in earlier slices.

Footprint rises with stories that carry several large figures (four or five on BBC and Guardian pages) and falls between them. The first pass fills caches by about 80–97 MiB. The second pass changed the footprint by −6.9 and +17.2 MiB in the two runs, so these runs show no consistent growth per opening but cannot rule out a small leak; that needs a longer run with many passes.

## Limits

- The harness is not the shipping app: it skips the app delegate and its 64 MB `URLCache` setup (which would write to a real cache directory), the web view and event overviews. Its footprint includes the harness itself and the live fetch.
- Live stories and images change from run to run; two runs on one network and day.
- The window was on screen; this is not a measurement under memory pressure, and no images were evicted.
