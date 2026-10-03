# Production launch and memory baseline — 2 October 2026

Refs #104, #153, #90. Base: `6322436`. Apple M5 / 24 GiB (Mac17,3), macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4; `build.sh` arm64, ad-hoc signed, deployment target macOS 15.

Earlier slices measured core services and a separate native window harness. This slice launches the production bundle, including its app delegate and real view hierarchy, and samples that process's memory.

## Method

Run `./script/launch_baseline.sh [output-dir]`. The script:

1. Copies the working tree to a temporary directory and builds it with `build.sh` under the bundle identifier `com.marspater.news.launchcheck`. The sandbox therefore gives it its own container, database and preferences; the installed app and the real library are never opened.
2. Launches once, if needed, to create that container, then replaces its library with a newly seeded one (`./test.sh --seed-launch-library`): 10,000 unread stories from the last two days, 20 publisher labels, reader documents, already clustered. Launch therefore loads a steady-state archive, not a first-run clustering backlog.
3. Launches the bundle five times with `open -n`. Launch arguments set the subscription to a reserved `.invalid` host and turn notifications and AI off, so no publisher is contacted. Each launch is stopped after the measurement.

The app now emits a `FirstCard` signpost and one log line, once per process, when the first story card's `onAppear` runs. The line carries the time since the kernel's process start time. `open_to_first_card` adds LaunchServices, measured from just before `open` to the log entry's timestamp. Memory is the `vmmap` physical footprint at the first card, five seconds later, and the peak at that point.

## Results

[Raw evidence](../benchmarks/2026-10-02-launch-baseline.json) holds two runs of five launches. The first launch of the second run was the first launch of a newly built bundle; it is reported separately.

| Measure | Samples | Median | Maximum | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| Process start to first card | 9 | 656.8 ms | 678.2 ms | 850 ms |
| `open` to first card | 9 | 689.6 ms | 709.3 ms | 890 ms |
| Physical footprint at first card | 9 | 60.0 MiB | 67.9 MiB | 85 MiB |
| Physical footprint 5 s later | 9 | 67.4 MiB | 85.5 MiB | 107 MiB |
| Peak physical footprint after 5 s | 10 | 78.4 MiB | 88.2 MiB | 111 MiB |

First launch of a newly built bundle: 1,049.6 ms from process start and 1,087.4 ms from `open`, footprint peak 78.7 MiB. Budgets allow 25% above the observed maximum, as in earlier slices. They are investigation triggers, not CI thresholds.

The footprint is well under the 239 MiB of the native probe, which also held fixture setup, repeated windows and Vision.

## Limits

- File caches were warm. A true cold launch after a reboot or `purge` needs administrator rights and was not measured; the first launch of a new build is the closest observation.
- `onAppear` marks when SwiftUI creates the first card, not when its pixels reach the screen. The native probe's sampled bitmap remains the rendering bound.
- Refresh failed locally against the `.invalid` host; launch did not include a real network refresh, model work, image loading or an open reader. Memory after reading and browsing images is not covered.
- The script leaves the `com.marspater.news.launchcheck` container in place; it contains only the seeded library. Remove `~/Library/Containers/com.marspater.news.launchcheck` to discard it. On its first launch macOS may ask that bundle for notification permission.
