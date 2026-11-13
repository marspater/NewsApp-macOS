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
- Profile builds only (`com.marspater.news.dev`), on a uniquely named `paired-launch-XXXXXX` copy through `NEWS_LIBRARY_NAME`. The development library `news.sqlite3` and the real app's container are not opened; the run stops if the app did not open the named copy. The development container's settings and caches are used and written as by any launch of the development build.
- It takes the measurement lock of the build protocol (`/tmp/news-measure.lock`) and refuses to start while a build or test run is active, a News app is open or the load average is above 2.5.
- A launch counts for its arm only when its log shows that state. The baseline rejects Today markers; swap memory is sampled only after a logged swap; stage timings require one complete, unambiguous edition attempt. Invalid samples are excluded. The first round is discarded. p95 is the nearest rank: with 20 launches, the 19th.
- **The launcher has never been executed.** Its parsing is covered by `script/test_summarize_launches.py`; the launch loop is checked for syntax only. It refuses nonempty output directories to prevent old rounds or checkpoints from entering new reports. The first scheduled run is its test: run it with 2 rounds first.

## Before every run

One measurement at a time, per the [build measurement protocol](2026-11-07-build-measurement-protocol.md). Every command in this document runs from the root of a checkout that has `script/paired_launch.sh`: this branch until it is merged, `main` afterwards. In every new terminal, first:

```sh
RUN="$HOME/news-eval/z5-937-2026-11-13"
DEV="$HOME/Library/Containers/com.marspater.news.dev/Data/Library/Application Support/com.marspater.news"
export NEWS_PAIRED_LIBRARY="$RUN/pristine.sqlite3"
```

`RUN` carries the day of the run (replace the date above), written out so that it does not change at midnight. Then the idle check:

```sh
uptime
pgrep -fl '[x]codebuild -project|^/bin/bash \./test\.sh'
ls -d /tmp/news-measure.lock
pgrep -lx News
```

The one-minute load is low and the other three print nothing (`ls` reports no such file). The `pgrep` pattern is anchored on purpose: a plain `xcodebuild|test.sh` also matches the shell of any session that is waiting with those words in its command, and two waiting sessions then block each other. A session waits at most 10 minutes on it. My proposal for "idle" is a load of 2.5 or less at the start and during the run; that figure is not a decision yet.

## Setup, once on the day of the run

About 10 minutes, most of it two cold Profile builds. Builds are not measurements, but nothing is measured while they run.

```sh
mkdir -p "$RUN" && chmod 700 "$RUN"
git fetch origin main
git worktree add --detach "$RUN/src-main" origin/main
git worktree add --detach "$RUN/src-baseline" ba1853e
(cd "$RUN/src-main" && NEWS_CONFIGURATION=Profile NEWS_SENTRY_DISABLED=1 NEWS_APP_DIR="$RUN/main/News.app" ./build.sh)
(cd "$RUN/src-baseline" && NEWS_CONFIGURATION=Profile NEWS_SENTRY_DISABLED=1 NEWS_APP_DIR="$RUN/baseline/News.app" ./build.sh)
sqlite3 -readonly "$DEV/news.sqlite3" ".backup '$RUN/pristine.sqlite3'"
```

- The development build must have refreshed the same day and be closed (`pgrep -lx News` prints nothing) before the copy is taken; otherwise Today has no stories of the last 72 hours.
- The copy is read from the development container. The library files written there are uniquely named `paired-launch-XXXXXX.sqlite3*`, `z5-scroll-XXXXXX.sqlite3*` and `z5-alloc-XXXXXX.sqlite3*` working copies, which each command removes by its own exact run-specific prefix; `news.sqlite3` is not opened. The Profile builds are the development build, so they read and write that container's settings, image cache and other caches. These are shared by every arm and are not restored between launches: the first launches fill the image cache and later ones find it filled, which is one reason the first round is discarded and a caveat for the image-memory figures.
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
- The window must not be touched before the 20-second sample, or the fresh edition is held instead of swapped. The script starts the executable directly, so the window comes to the front; if the list takes keyboard focus by itself, the launch logs `held` and is excluded. **Not verified** either way.
- With `NEWS_PAIRED_HOLD=1` the script waits after that sample: The Latest is scrolled to its last card, Return is pressed, and a second report is taken as `scrolled`. On the baseline the Today list is scrolled past the same number of stories. How far "the same" is on a build without lanes is my call to make before the run; my proposal is the end of the first page of 200 stories on both.

### C. Scroll frame time (number 7)

One recording per row: `in-motion`, `deep-read`, `your-beat`, `outside-your-usual`, `page` (the whole page, which ends in The Latest) and `baseline-page` (with `$RUN/baseline/News.app`). The Lead is a carousel and has no row to scroll.

```sh
ROW=in-motion
APP="$RUN/main/News.app"
mkdir -p "$RUN/scroll"
# New per-recording name. Never delete another session's files.
SCROLL_DIR=$(mktemp -d "$RUN/z5-scroll-XXXXXX")
SCROLL_NAME=${SCROLL_DIR##*/}
cp "$RUN/pristine.sqlite3" "$DEV/$SCROLL_NAME.sqlite3"
xcrun xctrace record --template 'Animation Hitches' --time-limit 40s --no-prompt \
    --output "$RUN/scroll/$ROW.trace" --env NEWS_LIBRARY_NAME="$SCROLL_NAME" \
    --launch -- "$APP/Contents/MacOS/News" -first_launch_completed YES -notifications_enabled NO
xcrun xctrace export --input "$RUN/scroll/$ROW.trace" --toc --output "$RUN/scroll/$ROW.toc.xml"
rm -f "$DEV/$SCROLL_NAME.sqlite3"*
rmdir "$SCROLL_DIR"
```

- Each recording, including `baseline-page`, must create its own `SCROLL_NAME` and remove only that name's files after exiting. In each recording: wait 10 seconds after the window appears, then scroll that row end to end and back with the trackpad until the recording stops. Trackpad scrolling cannot be synthesized, so this needs a person at the Mac.
- `xctrace` exits non-zero when the time limit ends the app; the trace is complete.
- The numbers to record per row: frames, hitches and the longest frame, read in Instruments or from the table the `toc.xml` names. **Not verified:** that the Animation Hitches template records hitches for a Mac app on this system, and the name of its table. If the trace holds no hitch data, the SwiftUI template (used on 12 November) gives update durations instead, and I decide whether that stands in for frame time.

### D. Launch peak attribution (number 8)

```sh
codesign -d --entitlements - "$RUN/main/News.app" 2>/dev/null | grep -q get-task-allow \
    || { echo "STOP: Allocations cannot attach to this build" >&2; exit 1; }
mkdir -p "$RUN/allocations"
# New library name and pristine copy for EACH trace, including the baseline and warm repeats.
ALLOC_DIR=$(mktemp -d "$RUN/z5-alloc-XXXXXX")
ALLOC_NAME=${ALLOC_DIR##*/}
cp "$RUN/pristine.sqlite3" "$DEV/$ALLOC_NAME.sqlite3"
xcrun xctrace record --template 'Allocations' --time-limit 30s --no-prompt \
    --output "$RUN/allocations/main-cold.trace" --env NEWS_LIBRARY_NAME="$ALLOC_NAME" \
    --launch -- "$RUN/main/News.app/Contents/MacOS/News" -first_launch_completed YES -notifications_enabled NO
rm -f "$DEV/$ALLOC_NAME.sqlite3"*
rmdir "$ALLOC_DIR"
```

- Repeat with `$RUN/baseline/News.app` as `baseline.trace`, and for WARM as `main-warm.trace` after `cp "$RUN/first-card/seed-warm.today-edition.json" "$DEV/$ALLOC_NAME.sqlite3.today-edition.json"` (between that recording's copy and the recording). Use fresh `ALLOC_DIR`/`ALLOC_NAME` for each repeat, and remove only its files.
- **Not verified:** that the Profile build carries `get-task-allow`. The project switches Xcode's base entitlements off for Release only, which fits Release refusing the attach and suggests Profile allows it; `build.sh` signs again with `News.entitlements` alone when Sentry is linked, hence `NEWS_SENTRY_DISABLED=1` in the setup. The first line settles it without recording anything.
- The numbers to record: the largest contributors, in MB by responsible library and call tree, to the memory alive at the peak and gone by 20 seconds, for `main` against the baseline. This is read in Instruments. Times from these traces are not launch times: Allocations slows the app.

### E. Seeded launch baseline (number 9)

```sh
NEWS_LAUNCHES=10 ./script/launch_baseline.sh "$RUN/seeded"
```

- It builds a Release bundle as `com.marspater.news.launchcheck`, seeds 10,000 stories and launches ten times; output `launch-baseline.json`. The first launch of a newly built bundle is reported apart, as in October, which leaves nine.
- Read `first_card_restored` per launch: launches with `false` and with `true` are two series. The script does not take the measurement lock, so the idle check above is done by hand.

## Results of 13 November 2026

Run between 00:52 and 02:20 on 13 November. These are recorded figures. **No budget is set or met by them**, and none of the runs was on an idle Mac: the load was 2.7 when the first run started and between 4.5 and 30 while it ran. The launches themselves raise it (every launch refreshes 43 feeds and groups the new stories for 20 seconds before it is ended), and other work on the Mac came and went. Every figure below is therefore "Mac in use", with its load range beside it.

- **Builds:** baseline `ba1853e`; `33199b7`, which was `main` before the epic Z pull requests of 12 November merged; `7eedcd4`, the integration head that stands for the code after all 18 of them. Profile configuration, `com.marspater.news.dev`, macOS 27.2.1, Mac17,3.
- **Library:** a copy of the development library taken on 12 November (3,359 stories, newest about a day old), restored before every launch.
- **Launcher:** `script/paired_launch.sh` at `9e3caf6`. Its first execution (a two-round trial) counted all three arms and excluded none.
- The aggregates are in `docs/benchmarks/2026-11-13-today-launch.json`; logs and `footprint` reports stay under `~/news-eval/z5-937-2026-11-12/`.

### First card, 21 rounds, 20 counted launches an arm, none excluded (numbers 1, 2, 3, 6)

| Arm | Build | First card: median | p95 | Range | Slower than baseline in | Fresh edition ready | Load per launch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Baseline | `ba1853e` | 1,641 ms | 3,494 ms | 1,332 to 3,506 | – | – | 5.2 to 29.8 |
| COLD | `33199b7` | 1,919 ms | 3,700 ms | 1,531 to 4,149 | 17 of 20 rounds | – | 5.0 to 21.2 |
| WARM | `33199b7` | 1,520 ms | 3,365 ms | 1,326 to 3,472 | 9 of 20 | 1,846 ms | 5.2 to 18.1 |
| COLD | `7eedcd4` | 1,678 ms | 4,422 ms | 1,547 to 4,935 | 16 of 20 | – | 5.9 to 21.5 |
| WARM | `7eedcd4` | 1,473 ms | 3,738 ms | 1,315 to 3,841 | 11 of 20 | 1,689 ms | 4.5 to 27.3 |
| COLD, 72-hour pool (`-today_window_pool YES`) | `7eedcd4` | 4,389 ms | 6,338 ms | 2,318 to 6,501 | 20 of 20 | – | 4.8 to 23.1 |

The medians and p95s carry the load of rounds 2, 3 and 14 to 18 (load 13 to 30). Two readings that depend less on it:

| Arm | Difference to the baseline in the same round: median | Median in the 9 rounds with every launch at load 9 or less |
| --- | --- | --- |
| Baseline | – | 1,425 ms |
| COLD `33199b7` | +178 ms | 1,654 ms |
| WARM `33199b7` | −19 ms | 1,389 ms |
| COLD `7eedcd4` | +203 ms | 1,599 ms |
| WARM `7eedcd4` | +8 ms | 1,396 ms |
| COLD, 72-hour pool | +2,141 ms | 3,524 ms |

- **COLD is slower than the baseline by about 0.2 s** (12 to 16 % in the quieter rounds) on both builds; **WARM is level with the baseline**. That is the picture of #1243 again, now with p95s, on a Mac in use.
- **The code after all 18 pull requests does not launch slower than `main` before them**: cold 1,599 against 1,654 ms and warm 1,396 against 1,389 ms in the quieter rounds.
- **The absolute level is not the 850 ms reference's**: the fastest baseline launches of this run are 1.33 s. Profile builds in the development container on this library were never measured before, so these figures compare the arms with each other and not with the Release figures of 12 November.
- **Every WARM launch showed the stored edition and confirmed it** (20 of 20 on both builds); the fresh edition was ready 0.2 to 0.3 s after the restored first card.
- **The 72-hour pool costs the cold first card about 2 s more** (3,524 against 1,599 ms in the quieter rounds). This is the price of gate 6's option in the app as it is built on `7eedcd4`, where the cold first card waits for the wider assignment.

### Assignment and context in the app (number 3)

| Arm | Build | Context read: median | Lane assignment: median |
| --- | --- | --- | --- |
| COLD | `33199b7` | 88 ms | 110 ms |
| COLD | `7eedcd4` | 79 ms | 91 ms |
| WARM (behind the restored page) | `33199b7` | 245 ms | 130 ms |
| WARM (behind the restored page) | `7eedcd4` | 230 ms | 90 ms |
| COLD, 72-hour pool | `7eedcd4` | 704 ms | 1,169 ms |

Athena · attention's part of a cold launch on the page pool is about 0.2 s on a Mac in use; the 250 ms I proposed for context plus assignment is not a budget yet. With the 72-hour pool it is about 1.9 s.

### Memory 20 seconds after launch (numbers 2, 4, 6)

Medians in MB; the peak's highest value in brackets.

| Arm | Build | Footprint | Peak | CoreAnimation | CG Raster Data | Malloc Small |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline | `ba1853e` | 246 | 263 (300) | 16 | 15 | 166 |
| COLD | `33199b7` | 300 | 368 (415) | 67 | 27 | 157 |
| WARM | `33199b7` | 298 | 376 (387) | 69 | 27 | 159 |
| COLD | `7eedcd4` | 300 | 368 (399) | 69 | 27 | 159 |
| WARM | `7eedcd4` | 297 | 376 (399) | 69 | 27 | 162 |
| COLD, 72-hour pool | `7eedcd4` | 372 | 457 (493) | 66 | 25 | 218 |
| After the swap (3 launches) | `33199b7` | 297 | 366 (381) | 69 | 27 | 159 |
| After the swap (3 launches) | `7eedcd4` | 301 | 383 (384) | 69 | 27 | 163 |
| Baseline of the swap run (3 launches) | `ba1853e` | 229 | 278 (281) | 20 | 19 | 154 |

- **The edition stands about 55 MB above the baseline at 20 seconds and about 105 MB at the peak.** Nearly all of the standing difference is layer backing (CoreAnimation, +50 MB) and decoded images (CG Raster Data, +12 MB): the image memory of number 6.
- **WARM and COLD are level** (298 against 300 MB). The 45 MB that the restored arm showed over the fallback on 12 November does not appear here.
- **The swap from the restored to the fresh edition adds nothing measurable**: 297 and 301 MB after it. The swap arm worked as built: all 6 launches logged `today_fresh_edition_ready outcome=swapped`, which also settles the two points this document listed as not verified (the reversed row differs, and the window coming to the front leaves the page untouched). Three counted launches an arm is a small sample.
- **The 72-hour pool adds about 70 MB standing and 90 MB at the peak**, in Malloc and not in layers.

### Seeded 10,000-story launch baseline (number 9)

`NEWS_LAUNCHES=10 ./script/launch_baseline.sh`, Release build of `main` at `f63c6f0` under `com.marspater.news.launchcheck`, load 5 to 15 (it launches straight after its own build).

| | Process start to first card | Footprint settled | Peak |
| --- | --- | --- | --- |
| Launches 2 to 10 (9) | 807 ms median, 771 to 880 | 102 MiB | 157 MiB (highest 173) |
| First launch of the new bundle, apart | 1,867 ms | 98 MiB | 152 MiB |
| October, before Today | 656.8 ms median | | |

- All nine are COLD launches: the seeded stories carry no photo, so no edition with a Lead is stored (`noLead`) and none is restored. This run never measures WARM.
- **807 ms is 150 ms above October's figure**, on a Mac in use; the 850 ms reference of October is not re-set or declared met here.
- **A defect in the run, fixed in the script and not explained:** on `7eedcd4` the first launch on the freshly seeded library did not reach a first card in 30 seconds and the script stopped. A stack sample showed the library open busy in the statement that fills missing topic labels (`DatabaseEngine.open`, the `news_topic` update), for at least 56 seconds, before any window. On `f63c6f0` the same first launch took 1.9 s. The script now gives the first launch 20 minutes and still reports it apart; why the two builds differ was not established and should be looked at before the next seeded run is trusted.

### Not obtained

| Number | What happened | Still owed |
| --- | --- | --- |
| 5, memory after scrolling The Latest | Needs a person scrolling; not attempted | Me, with command B and `NEWS_PAIRED_HOLD=1` |
| 7, scroll frame time | Attempted without a person. `xctrace record --template 'Animation Hitches' --attach <pid>` records (the `--launch` form of command C is refused, see below). Scroll-wheel events posted to the app's process were not delivered: the posting process is not trusted for event posting (`CGPreflightPostEventAccess()` is false), and the page's layer memory did not move (69 to 73 MB). The trace therefore holds no scrolling and no figure is taken from it | Me at the trackpad, with the attach form: start the app as command C does without `xctrace`, then `xcrun xctrace record --template 'Animation Hitches' --attach <pid> --time-limit 40s --no-prompt --output "$RUN/scroll/$ROW.trace"` |
| 8, launch peak attribution | **Not an entitlement problem**: all three Profile builds carry `get-task-allow`. `xctrace record … --launch -- <path>/News.app/Contents/MacOS/News` stops with "Provided process … is ambiguous" and lists every `News.app` registered on this Mac, the installed app among them. It was not forced, because a wrong choice could start the real app. Attaching after launch would miss the launch peak | Me, in Instruments, choosing the Profile build as the target by hand; or `xctrace` on a Mac account where only one `News.app` is registered |

Commands C and D above are wrong in their `--launch` form for that reason and are kept as written for the record.

## Not covered here

- The captures on macOS 26 and the macOS 15 fallback, the held path of a restored edition and the hardware checks of #932 are not performance numbers; they stay on #937 and #932.
- VoiceOver checks are in the cumulative gate #1244.
- The weekly `profile.yml` run is unchanged apart from running the new parser's unit test.
