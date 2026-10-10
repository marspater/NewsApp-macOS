# Cold launch after `purge` — 5 October 2026

Refs #104, #153, #90. Apple M5 / 24 GiB (Mac17,3), macOS 27.0.1. Method and bundle as in the [launch baseline](2026-10-02-launch-baseline.md): `com.marspater.news.launchcheck`, ad-hoc signed arm64, its own sandbox container with a seeded 10,000-story library, feed pointed at a reserved `.invalid` host. The installed app and the real library were not opened.

## Conditions

Mars ran `sudo purge && ./script/launch_baseline.sh <private dir>` from the local main checkout (`03a0a8e`; the launch path is unchanged on `aed9f8c`). The script builds the bundle and seeds its library after the purge, so the first measured launch is the first launch of a newly built bundle after the file cache was purged. The build itself reads compiler and SDK files back into the cache; this is the closest cold measurement available without a reboot. Launches 2–5 follow immediately and are warm.

## Results

[Raw evidence](../benchmarks/2026-10-05-cold-launch.json).

| Measure | Cold (launch 1) | Warm median (2–5) | Warm max | Earlier warm budget |
| --- | ---: | ---: | ---: | ---: |
| Process start to first card | 1,203.3 ms | 625.8 ms | 629.8 ms | 850 ms |
| `open` to first card | 1,265.3 ms | 668.5 ms | 673.7 ms | 890 ms |
| Physical footprint at first card | 59.1 MiB | 59.3 MiB | 67.6 MiB | 85 MiB |
| Peak physical footprint after 5 s | 66.2 MiB | 66.8 MiB | 74.6 MiB | 111 MiB |

Warm launches match the 2 October baseline (median 656.8 ms) and stay inside every budget. The cold launch costs about 0.58 s more than a warm one, and about 0.15 s more than the 2 October first launch of a new build without a purge (1,049.6 ms). Memory does not depend on the cache state.

**Cold-launch investigation budget:** 1.5 s from process start to first card, 25% above this observation, as in earlier slices. It is an investigation trigger, not a CI threshold.

## Limits

- One cold sample. A reboot is colder than `purge`, because a reboot also clears the dyld shared cache.
- `onAppear` of the first card marks SwiftUI creation, not pixels on screen.
- No real network refresh, model work, reader, web view or event overview was part of launch. The additional component workload is now recorded in the [combined cache/reader/Web/overview audit](2026-10-05-full-app-workload.md); its scoped memory limits remain explicit.
