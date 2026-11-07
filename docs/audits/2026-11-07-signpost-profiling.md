# Scheduled signpost profiling (7 November 2026)

Part of #577, item G of [the native integration plan](../plans/2026-11-07-native-integration.md).

## What is recorded

`.github/workflows/profile.yml` runs weekly (Mondays 04:17 UTC) and on manual dispatch, on GitHub's `macos-26` runner with Xcode 26.6. It never runs for pull requests. `script/profile_signposts.sh`:

1. Builds the Debug app with `build.sh` as `com.marspater.news.dev` into the output directory, and refuses to launch any other bundle identifier.
2. Records it with `xctrace record --template 'Time Profiler' --instrument os_signpost --time-limit 60s`, launching the binary with `NEWS_LIBRARY_NAME=profile-<run id>` (an empty library per run) and `NEWS_FIXTURE_FEED` set to `Tests/Fixtures/profiling/feed.xml` with the current date. The fixture feed answers every subscription only in a build that contains #1121; before that the development build ignores the variable and refreshes from the network, so runs are not comparable until #1121 is on main.
3. Exports the `os-signpost-interval` table and runs `script/summarize_signposts.py`: per category and interval name of the `com.marspater.news` subsystem (`NewsSignposts.swift`), count, median and p90 duration in milliseconds, plus revision, hardware, OS and Xcode.

Artifacts (90 days): `News.trace`, `summary.json`, `summary.md`, `build.log`. The job summary shows the table.

`PROFILE_DRY_RUN=1` builds and prints the recording command without launching the app; that is the only mode for a developer's Mac.

## Comparing two runs

Compare only runs with the same hardware model, OS and Xcode lines in `meta`. Download both `summary.json` files and compare median and p90 per category and interval; a count change means the workload changed, so check the fixture and the revision range before reading durations. For a regression, open both `News.trace` bundles in Instruments and compare the os_signpost track and the Time Profiler call tree over the interval in question. A single run is one sample; confirm a change with a second dispatched run before acting on it, as the [build measurement protocol](2026-11-07-build-measurement-protocol.md) asks for repeated samples.

## Baseline

No run has been captured yet. The first scheduled or dispatched run on main after #1121 merges is the baseline.
