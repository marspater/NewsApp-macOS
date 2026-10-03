# Memory while reading — 3 October 2026

Refs #153, #104, #90. Base: `c55acf0`. Apple M5 / 24 GiB (Mac17,3), macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4; optimized arm64.

Earlier slices measured launch and idle memory of the production bundle ([launch baseline](2026-10-02-launch-baseline.md): peak 88.2 MiB) but not reading. This slice reads live stories in the production reader.

## Method

`NEWS_NATIVE_HARNESS=Tests/NativeReadingMemory.swift ./script/native_performance_baseline.sh [output-dir]`. The existing native script now accepts a harness file; the default remains the first-card baseline.

The harness uses temporary storage and settings (AI and notifications off) and fetches the current items of five image-carrying panel feeds (BBC World, The Guardian World, Al Jazeera, DW English, CNA) through the app's own client. It takes exactly 20 distinct stories, four per feed where possible, and fails otherwise. It then shows the production `ArticleDetailView` for each story in turn in one 1100×800 window, with a new view identity per story as navigation creates, and reads all 20 twice in one process (`NEWS_READING_PASSES` sets more passes). The feed manager's initial clustering of the stored stories finishes before measuring starts.

Before advancing, each story waits until a publisher document is stored (from the feed or from page extraction; 15-second limit) and until the reader reports each of its images (figures and lead image) decoded or failed (15-second limit). `ArticleRemoteImage` posts a `readerImageFinished` notification for this when a load completes; nothing listens in the app. A missing document or image marks the report incomplete and fails the run. A sampler reads the task's physical footprint (`TASK_VM_INFO`) every 50 ms; the lifetime peak comes from the same ledger.

## Results

[Raw evidence](../benchmarks/2026-10-03-reading-memory.json): three complete runs, 49 images per pass (98 in a two-pass run, 245 in the five-pass run), all decoded. Openings took 0.7–4.7 seconds including the waits.

| Measure | Run 1 (2 passes) | Run 2 (2 passes) | Run 3 (5 passes) |
| --- | ---: | ---: | ---: |
| Before reading (after setup, live fetch and clustering) | 17.5 MiB | 17.3 MiB | 17.4 MiB |
| Highest sampled while reading | 158.1 MiB | 160.4 MiB | 169.0 MiB |
| Lifetime peak | 168.7 MiB | 171.0 MiB | 174.4 MiB |
| After each pass | 117.2, 132.0 | 115.7, 140.5 | 116.5, 139.9, 136.6, 137.9, 143.1 |
| 3 s after the window closed | 129.9 MiB | 138.3 MiB | 141.0 MiB |

Investigation budget for the documented two-pass workload: 214 MiB peak footprint, 25% above the highest two-pass peak, as in earlier slices.

Footprint rises with stories that carry several large figures (four or five on BBC and Guardian pages) and falls between them. Retained memory grows over the first two passes (about 100 MiB, then 15–25 MiB) and then levels off: passes three to five added about 3 MiB in all, roughly 0.05 MiB per opening. That is a cache filling to its working size, not a per-opening leak.

An earlier version of the harness measured while the feed manager was still clustering the new stories; that work overlapped reading and made the second pass look smaller. It is excluded now.

## Limits

- The harness is not the shipping app: it skips the app delegate and its 64 MB `URLCache` setup (which would write to a real cache directory), the web view and event overviews. Its footprint includes the harness itself and the live fetch.
- Live stories and images change from run to run; two runs on one network and day.
- The window was on screen; this is not a measurement under memory pressure, and no images were evicted.
