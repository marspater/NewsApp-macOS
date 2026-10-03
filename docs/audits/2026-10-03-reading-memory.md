# Memory while reading — 3 October 2026

Refs #153, #104, #90. Base: `c55acf0`. Apple M5 / 24 GiB (Mac17,3), macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4; optimized arm64.

Earlier slices measured launch and idle memory of the production bundle ([launch baseline](2026-10-02-launch-baseline.md): peak 88.2 MiB) but not reading. This slice reads live stories in the production reader.

## Method

`NEWS_NATIVE_HARNESS=Tests/NativeReadingMemory.swift ./script/native_performance_baseline.sh [output-dir]`. The existing native script now accepts a harness file; the default remains the first-card baseline.

The harness uses temporary storage and settings (AI and notifications off) and fetches the current items of five image-carrying panel feeds (BBC World, The Guardian World, Al Jazeera, DW English, CNA) through the app's own client, four stories each. It then shows the production `ArticleDetailView` for each story in turn in one 1100×800 window, with a new view identity per story as navigation creates. Each story waits until a publisher document is stored (from the feed or from page extraction; 15-second limit) plus two seconds for images, which load through `SecureHTTPClient`. A sampler reads the task's physical footprint (`TASK_VM_INFO`) every 50 ms; the lifetime peak comes from the same ledger. The second run reads the same 20 stories twice in one process, so retained growth can be told apart from a leak.

## Results

[Raw evidence](../benchmarks/2026-10-03-reading-memory.json): two runs. Every story reached a stored publisher document, in 2.0–3.2 seconds including the image wait.

| Measure | Run 1 (one pass) | Run 2 (two passes) |
| --- | ---: | ---: |
| Before reading (after setup and live fetch) | 17.0 MiB | 17.0 MiB |
| Highest sampled while reading | 140.4 MiB | 128.1 MiB |
| Lifetime peak | 141.5 MiB | 137.9 MiB |
| After the first pass | — | 103.7 MiB |
| After the second pass | — | 95.2 MiB |
| 3 s after the window closed | 111.0 MiB | 95.2 MiB |

Investigation budget for reading 20 image-carrying stories: 177 MiB peak footprint, 25% above the highest observed peak, as in earlier slices.

Footprint rises with stories that carry several large figures (BBC and Guardian pages with four or five) and falls between them. Reading the same stories a second time did not add memory: the second pass ended 8.5 MiB lower than the first. The memory held after closing is therefore reused caches and allocator pages, not a per-story leak.

## Limits

- The harness is not the shipping app: it skips the app delegate and its 64 MB `URLCache` setup (which would write to a real cache directory), the web view and event overviews. Its footprint includes the harness itself and the live fetch.
- Live stories and images change from run to run; two runs on one network and day.
- The window was on screen; this is not a measurement under memory pressure, and no images were evicted.
