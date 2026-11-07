# Publisher-excerpt harness build path (#577)

Date: 7 November 2026. Base: main at 312ec37. Follows the external engineering audit of the same day, which named the GitHub "Verify Publisher Excerpts" step as the largest visible CI bottleneck.

## CI numbers (GitHub Actions log)

Run 42359059160, the latest green `ci.yml` run on main (312ec37), job "Test (macOS 26, Apple Silicon)", Xcode 26.6. Times from step boundaries and log timestamps.

| Step / phase | Time |
|---|---|
| Run Unit Tests (`./test.sh`), whole step | 4m42s |
| of which: self-checks before the compile | 9s |
| of which: `NewsTestRunner` compile, Debug (09:17:40 to 09:21:21) | 3m41s |
| of which: running the atoms | about 52s |
| Verify Publisher Excerpts, whole step | 5m50s |
| of which: `xcodebuild` of `NewsHarness`, Release (09:22:32.8 to 09:28:22.1) | 5m49s |
| of which: running the harness binary (48 checks) | under 1s |

The harness step recompiles all of `Sources/`: its log repeats the same `Sources/` warnings the runner build printed (for example `FeedManager.swift:724` and `SentenceEmbedder.swift:333`). Both builds use the same DerivedData (`build/DerivedData` of the checkout, from `script/xcode_build.sh`), so the path is not the reason.

## Why nothing is reused

- Each target compiles `Sources/` itself: `NewsTestRunner`, `NewsHarness` and `News` are separate native targets over the synchronized folders, with no shared framework or library target. Xcode keeps intermediates per target, so a shared DerivedData directory cannot share object files between them.
- The configurations differ as well: the runner builds Debug (`-Onone`, testability on), `build.sh` built the harness in Release (`-O`, single-file mode). Even within one target, Debug and Release products are separate.
- The CI cache (`actions/cache`) keeps `.build`, `build/DerivedData/SourcePackages` and the SwiftPM cache only, so each job starts both builds from scratch.

## Local numbers (this Mac)

Apple M5, 10 cores, Xcode 27.0, scratch DerivedData (not the checkout's), Sentry off, `build.sh` and `script/build_test_runner.sh` only, `NEWS_NATIVE_HARNESS=Tests/Harness/PublisherExcerptTests.swift`. One run each, other sessions possibly running (load average 3 to 4). The harness app was built, not launched.

| Case | Time |
|---|---|
| A. Clean harness build, Release | 124 s |
| B. Same again, nothing changed | 4 s |
| C. Clean runner build, Debug | 73 s |
| D. Harness Release right after C, same DerivedData | 132 s |
| E. Harness Debug right after a runner build, same DerivedData | 33 s |
| F. Same as E again, nothing changed | 2 s |

D is no faster than A, which confirms that the runner build gives the harness nothing. B and F show that the harness's own incremental build works; CI never sees it because no build products survive between jobs. Release costs about four times Debug for this target (132 s against 33 s). DerivedData held 997 MB after these builds.

## Levers, ranked

1. **Build the harness in Debug in CI (implemented).** The publisher-excerpt checks test behaviour, not speed, so `-O` buys nothing there. `build.sh` gains `NEWS_CONFIGURATION` (default Release, so every other caller is unchanged), and the three providers set it to Debug for this step. Expected saving from the local ratio: about three quarters of the 5m49s compile, roughly 4 minutes per GitHub run; to be confirmed from this PR's CI log.
2. **Run the excerpt checks in the runner build.** Moving `PublisherExcerptTests` into the `NewsTestRunner` (or the native `NewsTests`) build removes the second compile altogether. It touches `Tests/Runner.swift` and the test atoms, which another session owns now; it fits #1070's porting work better than a CI change.
3. **Cache DerivedData build products keyed on source hashes.** About 1 GB per job, and Xcode decides staleness by file times, which a fresh checkout resets, so a restored cache would likely recompile anyway. Not worth trying before 1 and 2.

Moving the step to a main-only or scheduled workflow was considered and not chosen: with lever 1 the step should cost about a minute and a half, and it guards a correctness contract that PRs should keep checking.

## Result in CI

PR #1108's GitHub run 42362521968 (Debug harness): "Verify Publisher Excerpts" took 1m51s against 5m50s on main, all 48 checks passing. In the same run `./test.sh` took 8m04s against 4m42s on main without any change to it, so runner load varies between runs; compare step times, not job totals.
