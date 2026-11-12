# Build measurement protocol (#577)

Date: 7 November 2026. Applies to every build-time claim from now on, starting with the native integration plan.

## Local measurements

Run only `script/measure_build.sh`, from the checkout root, and only when the session coordinating the work has said the machine is free; wait on its process, never poll its output. It refuses to start while the lock `/tmp/news-measure.lock` exists (one fixed path, so one measurement runs per Mac across all worktrees and sessions, whatever their `TMPDIR`) or another `xcodebuild`, `swift-build` or `swiftc` runs, runs the cases below one at a time in a scratch DerivedData (never the checkout's `build/DerivedData`), three runs each, appends each result with timestamp, seconds, commit, Xcode version and load average to `build/measure-results.txt` as it finishes, stops at the first failed build, and prints the median of each case. Nothing is launched. Report all three runs and the median; a difference smaller than the spread of the runs is no difference.

| Case | Command (from the checkout root, `NEWS_DERIVED_DATA` set to the scratch directory, Sentry off) |
|---|---|
| (a) Cold app build, Release | delete DerivedData, then `./build.sh` |
| (b) Incremental, one-file edit in `Sources/Models` | `touch Sources/Models/FeedError.swift`, then `./build.sh` |
| (c) Incremental, one-file edit in `Sources/Views` | `touch Sources/Views/List/ArticleCardView.swift`, then `./build.sh` |
| (d) `NewsTests` build, cold, Debug | delete DerivedData, then `xcodebuild build-for-testing -project News.xcodeproj -scheme News -destination 'platform=macOS' -derivedDataPath "$NEWS_DERIVED_DATA" -only-testing:NewsTests -quiet` |

`build-for-testing` compiles without running anything; Xcode rebuilds a touched file by its modification time, so no edit needs reverting.

## CI measurements

CI numbers are per step, read from step boundaries in the provider's log, never job totals: runner load moves a whole job by minutes (`./test.sh` took 3m32s, 6m50s and 8m04s on unchanged code on 7 November). A CI claim names the run IDs and takes the median of three runs of the step when the change is expected to be smaller than that spread.

## Before-state on main

Source: newscore-spike session, 7 November 2026, main cd68be0, Xcode 27.0, Apple M5, Sentry off, per-worktree `build/DerivedData`, medians of three. These runs used the cases above by hand, before `script/measure_build.sh` existed; the script's first run verifies that it reproduces them.

| Case | Run 1 | Run 2 | Run 3 | Median | Load (1-min) |
|---|---|---|---|---|---|
| (a) cold `./build.sh` (Release, `rm -rf build/DerivedData`) | 91 s | 95 s | 99 s | 95 s | 2.6 / 8.1 / 10.3 |
| (b) incremental `./build.sh`, touch `Sources/Models/FeedError.swift` | 6 s | 5 s | 5 s | 5 s | 9.5 / 11.6 / 10.1 |
| (c) incremental `./build.sh`, touch `Sources/Views/List/ArticleCardView.swift` | 5 s | 5 s | 5 s | 5 s | 8.6 / 11.1 / 9.6 |
| (d) `xcodebuild build-for-testing -scheme News -only-testing:NewsTests`, cold DerivedData (Debug) | 62 s | 68 s | 72 s | 68 s | 9.0 / 12.0 / 14.3 |

(b) and (c) sit at the one-second resolution floor, so changes show in the cold build (a) and the test-bundle build (d).
