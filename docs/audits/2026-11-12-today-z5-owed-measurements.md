# Today edition Z5: the measurements still owed, and how to take each (#937)

**Date:** 12 November 2026
**Epic:** Z · Today edition (#932), Z5 (#937); the budgets land in the re-baseline of #543.
**What this is:** the list of performance numbers Z5 still owes, each with the command that produces it, so they can be scheduled one at a time on a quiet Mac. Nothing was measured for this document and the app was not launched. It is a record about a view (`ArticleListView`, `TodayEditionView`) that shows the lane plan of Athena · attention; the stored edition and the library copy belong to Mnemosyne · storage and search. No code of either changed.

Aggregate numbers only. Library copies, stored editions and traces stay under `~/news-eval/`; a stored edition can hold one sentence of a report (a Coverage card's differing account), so it is never copied into the repository or an issue.

## What "first card" means since #1243

The app logs one `First card visible ms_since_process_start=… restored=…` line per process (`NewsSignposts.firstCardAppeared`, category `Launch`). Since #1243 there are two launches behind that one line, and they are separate numbers:

| State | How it is produced | Log lines that prove it | Numbers |
| --- | --- | --- | --- |
| **COLD**: nothing stored | The library copy is restored and no `<library>.sqlite3.today-edition.json` lies beside it | `today_edition_restored outcome=none`, then `First card visible … restored=false` | First card |
| **WARM**: stored edition present | One seeding launch on the same copy stores the edition; that file is put back beside the restored copy before each launch | `today_edition_restored outcome=shown`, then `First card visible … restored=true`, then `today_fresh_edition_ready outcome=confirmed` (or `swapped`, `held`) | First restored card, and the fresh edition ready behind it |
| Baseline `ba1853e` | The build before Today | `First card visible …` without `restored=` | First card |

- A stored edition is rejected (`otherFormat`, `otherReader`, `tooOld`, `noLead`, `storiesGone`) and the launch falls back to the wait. Such a launch is a COLD launch that paid for a file read; it counts for neither arm and is reported.
- `Launch milestone` lines stop at the first card. A WARM launch therefore logs `list_page_fetched` and never `today_edition_installed`; the fresh edition's time is the `today_fresh_edition_ready` event. The `Today edition stage=…` lines (context, assignment) are logged in both states.
- The stored edition is valid for 72 hours and Today lists 72 hours of stories, so the library copy and the seeding launch are made on the day of the run.

## The scripts against `main` (`33199b7`)

Checked by reading the scripts and their call sites, by their unit tests and by parsing the `footprint` and `vmmap` receipts of 12 November. No script was run against the app.

| Script | Checked | Result |
| --- | --- | --- |
| `script/launch_baseline.sh` | Log predicate (`com.marspater.news`, `Launch`), the `First card visible` line, bundle id `com.marspater.news.launchcheck`, container path, `vmmap` labels, the three defaults keys | The names match. **Mismatch, fixed:** the library is seeded once, so every launch after the first can show the edition the one before stored, and the report averaged both states as one. Each launch now records `first_card_restored`, `stored_edition` and `fresh_edition_ready_ms`. Whether the seeded stories give a Lead with a photo, and so a restore at all, is not known until it runs |
| `script/profile_signposts.sh`, `script/summarize_signposts.py`, `script/compare_profile.py`, `.github/workflows/profile.yml` | Profile configuration, `com.marspater.news.dev`, `NEWS_LIBRARY_NAME`, `NEWS_FIXTURE_FEED`, the `UITests` plan, the signposter categories | No mismatch. They summarize signpost intervals. The first card is a signpost event and the launch stages are log lines, so this pipeline never held a Today number and holds none now; its library is new on every run, so it always measures COLD on two fixture stories |
| `script/native_performance_baseline.sh` | The three source patterns it patches (`ArticleWebView` `didFinish`, `fetchPage(`, `publisherContentRevisions`) | All three still match once. Its harnesses were not re-run; `ListInvalidationBaseline`'s expectations predate the edition, as the audit of 11 November says |
| `script/build_and_run.sh` | Bundle ids, app names | No mismatch; not a measurement script |
| Schema | `DatabaseEngine.schemaVersion` at `ba1853e` and on `main` | 36 on both: one library copy opens on the baseline and on `main` without a migration |

**Missing, added:** the paired runs of 12 November were driven by scripts outside the repository, and their library copy, feed list and builds no longer exist. `script/paired_launch.sh` and `script/summarize_launches.py` replace them:

- Arms `baseline`, `cold`, `warm` and `swap`, in an order that rotates by round; the library copy is restored before every launch.
- Profile builds only (`com.marspater.news.dev`), on a copy named `paired-launch` through `NEWS_LIBRARY_NAME`. The development library `news.sqlite3` and the real app's container are not opened; the run stops if the app did not open the named copy.
- It takes the measurement lock of the build protocol (`/tmp/news-measure.lock`) and refuses to start while a build runs, a News app is open or the load average is above 2.5.
- A launch counts for its arm only when its log shows the arm's state; the others are listed as excluded. The first round is discarded. p95 is the nearest rank: with 20 launches, the 19th.
- **The launcher has never been executed.** Its parsing is covered by `script/test_summarize_launches.py`; the launch loop is checked for syntax only. The first scheduled run is its test: run it with 2 rounds first.

## Before every run

One measurement at a time, per the [build measurement protocol](2026-11-07-build-measurement-protocol.md). From the checkout root:

```sh
uptime
pgrep -fl 'xcodebuild|swift-build|swiftc|test.sh'
ls -d /tmp/news-measure.lock
pgrep -lx News
```

The one-minute load is low and the other three print nothing (`ls` reports no such file). My proposal for "idle" is a load of 2.5 or less at the start and during the run; that figure is not a decision yet.

## Setup, once on the day of the run

About 10 minutes, most of it two cold Profile builds. Builds are not measurements, but nothing is measured while they run.

```sh
RUN="$HOME/news-eval/z5-937-$(date +%F)"
DEV="$HOME/Library/Containers/com.marspater.news.dev/Data/Library/Application Support/com.marspater.news"
mkdir -p "$RUN" && chmod 700 "$RUN"
git fetch origin main
git worktree add --detach "$RUN/src-main" origin/main
git worktree add --detach "$RUN/src-baseline" ba1853e
(cd "$RUN/src-main" && NEWS_CONFIGURATION=Profile NEWS_SENTRY_DISABLED=1 NEWS_APP_DIR="$RUN/main/News.app" ./build.sh)
(cd "$RUN/src-baseline" && NEWS_CONFIGURATION=Profile NEWS_SENTRY_DISABLED=1 NEWS_APP_DIR="$RUN/baseline/News.app" ./build.sh)
sqlite3 -readonly "$DEV/news.sqlite3" ".backup '$RUN/pristine.sqlite3'"
```

- The development build must have refreshed the same day and be closed (`pgrep -lx News` prints nothing) before the copy is taken; otherwise Today has no stories of the last 72 hours.
- The copy is read from the development container; nothing is written there except the working copies `paired-launch.sqlite3*` and `z5-*.sqlite3*`, which each command removes.
- Earlier runs used Release builds under `com.marspater.news.isolatedqa`. Profile is whole-module, Release per file, so figures from the two are not compared with each other; both arms of a run use the same configuration.
- Each launch refreshes the development build's subscriptions from the network, as on 12 November.
- Afterwards: `git worktree remove "$RUN/src-main"` and `git worktree remove "$RUN/src-baseline"`.

## The numbers owed

| # | Number owed | Already measured | Command | Precondition | Duration |
| --- | --- | --- | --- | --- | --- |
| 1 | First card on an idle Mac, baseline against `main`, COLD and WARM apart: median, p95, range; the fresh edition behind a restored page | Mac in use, Release, 10 counted rounds (#1243): baseline 952 ms, nothing stored 1,118 ms (+17 %), stored 943 ms with the fresh edition at 1,047 ms. No p95, no idle run | A | Setup; idle check | 35 min |
| 2 | Peak memory and footprint at 20 s, same three arms | Same run: 376 / 416 MB, 448 / 457 MB, 494 / 504 MB (footprint / peak). The 45 MB of the restored arm over the fallback is unexplained | A (same run) | | none extra |
| 3 | Lane assignment and context read in the app, idle | 125 ms in the optimized test runner (11 November); about 57 to 77 ms as a launch stage, Mac in use. Proposed budget 250 ms for context plus assignment | A (same run, `Context` and `Assignment` columns of the cold arm) | | none extra |
| 4 | Memory after the swap from the restored to the fresh edition, against the baseline | Not measured | B | Setup; idle check; the seed of run A is not needed, B seeds itself | 5 min |
| 5 | Memory after scrolling The Latest, against the baseline scrolled as far | 780 MB (peak 983 MB), about 350 MB of it CoreAnimation, on 11 November; no baseline | B with `NEWS_PAIRED_HOLD=1` | As 4, and me or a trackpad at the Mac | 15 min |
| 6 | Image memory: decoded images and layer backing, by region | One launch each at 25 s (12 November): CoreAnimation 21 against 62 MB, CG Raster Data 21 against 33 MB, Malloc Small 190 against 208 MB | A and B (the region columns of `summary.md`; every `footprint` report is kept) | | none extra |
| 7 | Scroll frame time per lane and of the page | Not measured | C, one recording per row | Setup; idle check; a trackpad at the Mac | 15 min and the reading |
| 8 | What makes up the launch peak | Not attributed: Allocations could not attach to the Release build | D | Setup; idle check; the entitlement check in D passes | 10 min and the reading |
| 9 | First card on the seeded 10,000-story library (the 850 ms budget of 2 October) | 656.8 ms median in October, before Today; not run since | E | Idle check; builds and seeds by itself | 10 min |

No budget figure exists yet for 2, 4, 5, 6 and 7, and the first card's tolerance (10 % over the baseline) is a proposal. Recording a number does not meet a budget; setting each budget from these runs is my decision and goes into #543.

### A. First card, peak memory, assignment (numbers 1, 2, 3, 6)

```sh
script/paired_launch.sh "$RUN/first-card-trial" 2 baseline="$RUN/baseline/News.app" cold="$RUN/main/News.app" warm="$RUN/main/News.app"
script/paired_launch.sh "$RUN/first-card" 21 baseline="$RUN/baseline/News.app" cold="$RUN/main/News.app" warm="$RUN/main/News.app"
```

- The first line is the launcher's trial (about 4 minutes). Read `summary.md`: three arms, one counted launch each, none excluded. Only then the second line.
- 21 rounds give 20 counted launches an arm, 63 launches of about 30 seconds.
- Output: `$RUN/first-card/summary.md` and `summary.json`; per launch `r<round>-<arm>.log`, `.load` and `.settled.footprint`.
- Report with it: the commits of both builds, macOS, the load range, and the excluded launches.

### B. Memory after the swap and after scrolling (numbers 4, 5, 6)

```sh
script/paired_launch.sh "$RUN/swap" 4 baseline="$RUN/baseline/News.app" swap="$RUN/main/News.app"
NEWS_PAIRED_HOLD=1 script/paired_launch.sh "$RUN/scrolled" 4 baseline="$RUN/baseline/News.app" swap="$RUN/main/News.app"
```

- The `swap` arm starts from the seeded edition with one lane row reversed, so the fresh edition differs and takes the untouched page. Only launches that log `today_fresh_edition_ready outcome=swapped` count. **Not verified:** that a reversed row is restored in that order and so differs; if every swap launch is excluded, the stored edition has to be made to differ another way.
- The window must not be touched before the 20-second sample, or the fresh edition is held instead of swapped.
- With `NEWS_PAIRED_HOLD=1` the script waits after that sample: The Latest is scrolled to its last card, Return is pressed, and a second report is taken as `scrolled`. On the baseline the Today list is scrolled past the same number of stories. How far "the same" is on a build without lanes is my call to make before the run; my proposal is the end of the first page of 200 stories on both.

### C. Scroll frame time (number 7)

One recording per row: `in-motion`, `deep-read`, `your-beat`, `outside-your-usual`, `page` (the whole page, which ends in The Latest) and `baseline-page` (with `$RUN/baseline/News.app`). The Lead is a carousel and has no row to scroll.

```sh
ROW=in-motion
APP="$RUN/main/News.app"
mkdir -p "$RUN/scroll"
rm -f "$DEV"/z5-scroll.sqlite3*
cp "$RUN/pristine.sqlite3" "$DEV/z5-scroll.sqlite3"
xcrun xctrace record --template 'Animation Hitches' --time-limit 40s --no-prompt \
    --output "$RUN/scroll/$ROW.trace" --env NEWS_LIBRARY_NAME=z5-scroll \
    --launch -- "$APP/Contents/MacOS/News" -first_launch_completed YES -notifications_enabled NO
xcrun xctrace export --input "$RUN/scroll/$ROW.trace" --toc --output "$RUN/scroll/$ROW.toc.xml"
rm -f "$DEV"/z5-scroll.sqlite3*
```

- In each recording: wait 10 seconds after the window appears, then scroll that row end to end and back with the trackpad until the recording stops. Trackpad scrolling cannot be synthesized, so this needs a person at the Mac.
- `xctrace` exits non-zero when the time limit ends the app; the trace is complete.
- The numbers to record per row: frames, hitches and the longest frame, read in Instruments or from the table the `toc.xml` names. **Not verified:** that the Animation Hitches template records hitches for a Mac app on this system, and the name of its table. If the trace holds no hitch data, the SwiftUI template (used on 12 November) gives update durations instead, and I decide whether that stands in for frame time.

### D. Launch peak attribution (number 8)

```sh
codesign -d --entitlements - "$RUN/main/News.app" 2>/dev/null | grep -q get-task-allow && echo "can attach" || echo "STOP: Allocations cannot attach to this build"
mkdir -p "$RUN/allocations"
rm -f "$DEV"/z5-alloc.sqlite3*
cp "$RUN/pristine.sqlite3" "$DEV/z5-alloc.sqlite3"
xcrun xctrace record --template 'Allocations' --time-limit 30s --no-prompt \
    --output "$RUN/allocations/main-cold.trace" --env NEWS_LIBRARY_NAME=z5-alloc \
    --launch -- "$RUN/main/News.app/Contents/MacOS/News" -first_launch_completed YES -notifications_enabled NO
rm -f "$DEV"/z5-alloc.sqlite3*
```

- Repeat with `$RUN/baseline/News.app` as `baseline.trace`, and for WARM as `main-warm.trace` after `cp "$RUN/first-card/seed.today-edition.json" "$DEV/z5-alloc.sqlite3.today-edition.json"` (between the `cp` and the recording).
- **Not verified:** that the Profile build carries `get-task-allow`. The project leaves Xcode's base entitlements on for Profile and off for Release, which is why Release could not be attached to; `build.sh` signs again with `News.entitlements` alone when Sentry is linked, hence `NEWS_SENTRY_DISABLED=1` in the setup. The first line settles it without recording anything.
- The numbers to record: the largest contributors, in MB by responsible library and call tree, to the memory alive at the peak and gone by 20 seconds, for `main` against the baseline. This is read in Instruments. Times from these traces are not launch times: Allocations slows the app.

### E. Seeded launch baseline (number 9)

```sh
NEWS_LAUNCHES=10 ./script/launch_baseline.sh "$RUN/seeded"
```

- It builds a Release bundle as `com.marspater.news.launchcheck`, seeds 10,000 stories and launches ten times; output `launch-baseline.json`. The first launch of a newly built bundle is reported apart, as in October, which leaves nine.
- Read `first_card_restored` per launch: launches with `false` and with `true` are two series. The script does not take the measurement lock, so the idle check above is done by hand.

## Not covered here

- The captures on macOS 26 and the macOS 15 fallback, the held path of a restored edition and the hardware checks of #932 are not performance numbers; they stay on #937 and #932.
- VoiceOver checks are in the cumulative gate #1244.
- The weekly `profile.yml` run is unchanged apart from running the new parser's unit test.
