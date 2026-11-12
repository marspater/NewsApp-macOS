# Today edition: first pass in a window (epic Z, #932)

**Date:** 11 November 2026
**Asked for by:** Mars, after his own first run of the development build.
**What this is:** the checks of the Today edition that need a real window, as far as they could be done on the one Mac at hand. An untested combination is listed as not run, with what it needs.

## Environment

| | |
| --- | --- |
| Mac | Mac17,3, Apple M5, 24 GB |
| OS | macOS 27.2.1 (26B131). No macOS 26 or macOS 15 system or virtual machine is available on this Mac |
| Build | Release, ad-hoc signed, bundle id `com.marspater.news.isolatedqa` (`script/run_isolated.sh`), from `fix/today-live-feedback`; each row below names the commit it was seen on where that matters |
| Library | A read-only backup of the development library (about 3,040 stories, 320 grouped events) in the isolated container. The real app's container was not touched; the development container was only read |
| Settings | The development build's 43 subscriptions, first-launch and notification flags, passed as launch arguments, which override nothing stored |
| Driving | Background accessibility input and window captures. No trackpad, no VoiceOver speech, no system setting was changed |
| Appearance | Dark (the system's), light (`-appAppearance Light`), dark with Increase Contrast and Reduce Motion simulated (`--increase-contrast --reduce-motion`) |

## Results on macOS 27.2.1

| Check | Result |
| --- | --- |
| Page against the mocks, wide window, sidebar open, dark and light | Seen. Structure, The Lead, lane rows, cards and The Latest follow `docs/mocks/today/`. Differences that remain are the documented ones (#1224) |
| The Lead's image extends under the sidebar | Passed, dark and light |
| Lane cards pass under the sidebar | **Failed, fixed, passed.** Rows were cut at the column's edge: the page's own scroll view clipped them. Fixed in `e841044` (`scrollClipDisabled` on the page as well as the row) and seen passing |
| A lane's previous and next buttons | **Failed, fixed, passed.** They did not move the row. Two fixes did not work in a window (an id-bound scroll position with view-aligned snapping; a scroll reader, which moved the page instead). Setting the row's own offset works (`e841044`) |
| The Lead's dots and arrows | **Failed, fixed, partly seen.** Legible in an active window; in an inactive window the glass turned pale and the white marks vanished. A dark backing between glass and marks was added in `e841044`; the inactive state was not re-captured after it |
| The Lead's foot (time, publishers, original reports) on a bright photo | **Weak, fixed.** Teal on a bright image was hard to read; a foot scrim was added and seen in light and dark |
| Carousel: next arrow, automatic rotation | Passed: the arrow changes the slide; the slide advanced on its own between captures about ten seconds apart |
| Vertical page scrolling | Passed with wheel events. The Lead scrolls under the toolbar |
| Arrow keys | Passed: down moves from The Lead to the lanes, right moves along a row and the row scrolls only as far as needed, the focused card shows the ring and the lift |
| Opening a story and returning | Passed from The Latest: the scroll position is kept, the card keeps focus and shows as read |
| Applying queued updates | Passed: the button leaves, the page returns to the masthead, then scrolls back to the card that kept focus, as today.md specifies |
| The Latest after an applied update | In order: 8, 8, 9, 9, 9, 13, 17, 18, 18, 19 minutes and on |
| Compact cards | Photos fill the trailing side; cards of a row are equally tall; photos arrive a moment after a long jump down the page |
| Grid columns in Unread | Passed: showing an event's sources grew its own column; the cards in the other columns stayed |
| A layout per list | Passed: Unread switched to the list layout while Today kept its grid |
| Increase Contrast | Seen in dark: hairlines and secondary text strengthen |
| Reduce Motion | Launched with it: The Lead shows its first slide. That it never rotates was not timed |

## Not run

| Check | Why | What it needs |
| --- | --- | --- |
| macOS 26, and the macOS 15 fallback | Only macOS 27 here | A Mac or virtual machine on each; CI compiles and tests on macOS 26 (Xcode 26.6) but shows no window |
| Narrow window (900 pt), sidebar closed | The screen locked before these steps; background input stops then | The same pass again, or a look by Mars. Offscreen captures at the 900 pt column width exist |
| Trackpad: page against row, diagonal gestures | No trackpad input can be synthesised | Mars on hardware. One wheel scroll with the pointer over a row moved that row by a card once; not reproduced, worth a look |
| Hover lift and image scale | Needs a real pointer | Mars on hardware |
| The transition smear from the recording (0:16–0:19) | A capture cannot catch a frame mid-transition; the last frame after returning is clean | A new screen recording on the fixed build |
| J and K, focus restoration when a lane disappears | Not reached before the lock; the rules are unit-tested (`TodayFocusMap`) | The pass again |
| VoiceOver, lane names and descriptions, the Lanes rotor, card actions, slide position | Turning VoiceOver on is a system setting and speaks aloud | Mars, or a session he starts for it |
| Reduce Transparency, Show Borders, clear and tinted glass | System settings | Mars, or his go-ahead to change them for a pass |
| Launch and refresh watched as motion | Captures are stills | A screen recording |
| Scroll frame time | Needs Instruments on the Profile build with real scrolling | An Instruments run by Mars, or his go-ahead to record one |

## Recheck on `main`, 12 November 2026

Build `f742e0b` (Release, ad-hoc signed, bundle id `com.marspater.news.isolatedqa`), macOS 27.2.1 (26B131), dark appearance, a window of about 1,300 by 820 points left in the background, driven by background accessibility input. The library copy was restored before launch and deleted from the isolated container afterwards. A launch refresh ran, so the page showed stories of 12 November.

| Check | Result |
| --- | --- |
| The edition is what Today shows by default | Passed |
| A lane's previous and next buttons move its row | Passed (Your Beat) |
| Lane cards pass under the sidebar | Passed |
| Sidebar closed: The Lead and the lanes use the full width | Passed |
| Opening a story from a lane and going back | Passed: the page returns to the same place and the opened card holds focus |
| Down and Right arrows and J move focus between lanes and cards, and the row follows | Passed |
| The Lead's dots and arrows in an inactive window, after the backing fix | Not passed: the dark backing shows, but the dots and arrow marks on it are barely visible while the window is inactive |
| The Latest is newest first after updates are applied | Passed: 17 minutes to 1 hour over fifteen cards, in order |
| Unread and Today keep separate layouts | Passed: Unread in the list while Today's Latest is a grid, and back |
| Unread grid: expanding one card's sources moves only its column | Passed |
| K, Up and Left; hover; trackpad gestures; a narrow window | Not run: K, Up and Left were not sent; background input has no pointer hover, no trackpad and cannot resize the window |
| A story without a photo takes no Lead slide; the "on-device model is active" text; the Factor breakdown row | Not run in a window in this recheck (the photo rule has its unit test) |
| VoiceOver and the Lanes rotor; Reduce Transparency; Show Borders; tinted glass | Not run: they need system settings switched, which were left alone |
| The article transition from my recording | Not run: stills cannot show it; it needs a screen recording on this build |
| Light appearance on this build | Not run in this recheck |
| macOS 26 and the macOS 15 fallback | Not run: no such system or virtual machine on this Mac |
| Scroll frame time | Not run: needs Instruments on the Profile build with the Mac idle |

### Seen during the recheck, not judged

- **The Lead held one slide from the launch refresh until the updates were applied.** At launch on yesterday's stories the page showed five slides. The launch refresh then replaced the page, which is the documented exception for a list showing only earlier days, and The Lead showed one slide without controls, on two launches and after grouping had settled. "Show Updates" was offered; pressing it gave five slides and an In Motion lane. The cause is not established. One candidate is an edition built while the new stories were still ungrouped and then held.
- **The evaluated pool and the app's pool differ, by the code.** The shadow runs assign over every story of 72 hours (`Tests/TodayShadowEvaluation.swift`: all articles, then the window; 612 candidates on the real subscription list). The app assigns over the listed page (`ArticleListView.fetchPage`, 200 articles at a time, before grouping). Whether this contributed to the one-slide Lead is not established.
- **A card's photo changed after its story was opened and closed** (a Your Beat card). Which photo a card settles on is not stable across a visit to the reader.
- **The one Lead slide paired a headline about a Senate result with a photo of the Pentagon.** The stored event behind it had 15 reports from 12 publishers, and a second, single-report event held another report of the same result. Whether the photo is the representative report's own was not established. Grouping is #737.

## Scope, from 12 November 2026

My rulings of 12 November 2026: macOS 26 and macOS 15 windows are out of epic Z's scope, and macOS 26 is verified only through the CI target's captures. Every VoiceOver check belongs to #1244 only. The rows above that list them as not run are kept as the record of those passes; neither is owed for epic Z.

## Second recheck, evening of 12 November 2026

Build: `main` at `33199b7` with the Lead control fix of this change (`PhotoControlSurface`), Release, ad-hoc signed, bundle id `com.marspater.news.isolatedqa`, macOS 27.2.1 (26B131). A read-only copy of the development library (about 4,030 stories) was put in the isolated container under its own name (`NEWS_LIBRARY_NAME`), so the library another session had left there was not touched; the copy and its side files were deleted afterwards. The window stayed in the background and inactive throughout, driven by background accessibility input; no system setting was changed. Appearances and accessibility settings came from the app's launch arguments.

| Check | Result |
| --- | --- |
| The Lead's dots and arrows in an inactive window | **Failed on `main`, fixed, passed.** On `main` the capsule and circles read as flat gray and the dots and chevrons were barely visible, as in the morning recheck. The glass was a background of the marks, and the shared glass container drew it over them. With the marks as the glass's own content (`glassEffect` on the control, the dark backing under the marks) the dots and chevrons are crisp white in an inactive window, dark and light. The active window was not captured: background control cannot make the window key |
| Reduce Motion never rotates The Lead | Passed: launched with `--reduce-motion`, "1 of 5" from launch through 66 seconds (six rotation periods), with the card times ticking between captures. The arrows still change the slide |
| The carousel pauses while the reader is open | Passed: a story was opened from In Motion on slide 2 of 5, the reader stayed open for about 30 seconds (three periods), and The Lead was still on slide 2 when the page came back |
| The carousel pauses while The Lead holds keyboard focus | Passed: with focus on slide 5, the slide did not change for 25 seconds |
| Hover pause | Not run: background input has no pointer hover |
| Right, Left, Up, Down, K | Passed: after returning from the reader the opened card held focus; Right and Left moved the lift along In Motion, Up left the row for The Lead, Down came back to the lane's remembered card, K from the lane's first card went to The Lead's last slide (5 of 5), and Left on The Lead showed slide 4 |
| Focus when a lane disappears | Not run: no update that removes a lane could be produced on demand; the rule is unit-tested (`TodayFocusMap`) |
| Narrow window, about 900 pt | Passed at 908 by 822 pt (resized by dragging the corner in the background; a window frame passed as a launch argument was ignored because the window restores its saved state). Sidebar open: The Lead scales and a lane shows two cards. Sidebar closed: The Lead and the rows span the full window |
| Light appearance on current `main` | Passed: masthead, The Lead, In Motion and the toolbar's updates button as in dark |
| Increase Contrast in light | Passed: card hairlines and secondary text strengthen; status pills keep their contrast |
| A story without a photo takes no Lead slide | Partly: all five slides of each edition seen carried a photo. Whether a photoless story that would otherwise lead was held out could not be seen; the rule has its unit test |
| Restored edition at launch | Seen: restored and confirmed unseen once, restored and swapped twice (`today_fresh_edition_ready` in the launch log), never held, because the page was untouched each time |

### Seen during the recheck

- **The one-slide Lead reproduced on current `main`, by another path than the new-day page.** The first launch's refresh was cut short by quitting the app before its stories were grouped. At the next launch the stored edition was rejected (`storiesGone`), and the fresh edition was assigned over a page of 200 stories with no event among them, so The Lead had one slide and no controls. Grouping then ran (366 to 436 events), the list held, and "Show Updates" gave five slides and an In Motion lane. Nothing in the update rules lets an ungrouped launch page give way once grouping has run, except for a page of earlier days.

## Integration pass, night of 12 November 2026

Build: `mars/epic-z-integration` at `7eedcd4` (`main` with the 18 open epic Z PRs merged), Release, ad-hoc signed, bundle id `com.marspater.news.zview` ("News Z view", `script/run_isolated.sh --background`), macOS 27.2.1. A fresh read-only copy of the development library (about 4,030 stories) was used and deleted afterwards. The Mac was under heavy load (load average 12 to 17, other apps encoding), so the times below are not budget figures. Counts and ids only; captures stay private.

| Check | Result |
| --- | --- |
| Today with the window pool off | The Lead with five slides, In Motion, The Deep Read, Outside Your Usual and The Latest; the launch refresh waited behind "Show Updates" |
| One slide after a large launch refresh | **Found on the first integration head (`2f48b1c`), fixed in #1285 (`77bf49d`), passed on `7eedcd4`.** Three stories the matcher had not reached marked the launch page as awaiting grouping. After the refresh (691 new stories) was grouped, the untouched page gave way to the newest 200 stories, which held one event: one Lead slide. The mark now needs most of the page unprocessed |
| Window pool on (`-today_window_pool YES`), at launch | The restored edition showed first (first card 2.09 s). The pool edition swapped in about 2.4 s later, untouched: context 948 ms over 1,798 entries, assignment 1,382 ms over 299 events, layout 26 ms |
| Window pool on: the lanes | The Lead 5, In Motion 8, Your Beat 12, The Deep Read 8, Outside Your Usual 6, The Latest 156; 195 stories, each once. The lanes reached past the listed page (The Deep Read: 7 of 8 older than the newest 260 reports; Your Beat: 8 of 12); all 156 of The Latest were within it |
| Window pool on: "Show 1 New Story" | Applied: the page laid out afresh (context 318 ms, assignment 425 ms), the same lane sizes, each story once, and the button left |

## Measurements

First card after process start, from the app's own `First card visible` log line, same library, warm launches. Memory from `footprint` 25 seconds after the last launch.

| Build | Conditions | First card, ms | Physical footprint | Peak |
| --- | --- | --- | --- | --- |
| Edition (`d5a6bdf` plus the pager fix) | Load average 2 to 5 | 882, 862, 890 | 253 MB | 429 MB |
| Main (`ba1853e`) | Load 7 to 19, a test run active | 713, 614, 625, 617 | 306 MB | 314 MB |
| Edition (`33411bc`) | Same, alternating with main | 2,530, 2,615, 2,387 (and 1,773, 1,894, 1,806 a round earlier) | 251 MB | 439 MB |

- **The edition is slower to its first card than main.** Main shows the first page as soon as it is read. The edition waits for the lane assignment, which uses every core, so it also suffers most when the Mac is busy. The quiet-Mac figure, about 880 ms, is above the 850 ms budget of the 2 October launch baseline, which was set on a small seeded library; main on this library was not measured on a quiet Mac. A clean paired run is still owed.
- **Peak memory is about 130 MB higher with the edition** in the first seconds, and the same at rest. After scrolling the whole of The Latest the footprint reached 780 MB (peak 983 MB), of which CoreAnimation held about 350 MB; main was not scrolled the same way, so this has no comparison yet.
- Scroll frame time was not measured.

None of the three budgets Z5 (#937) names is recorded as met.

### Paired launch comparison, 12 November 2026

I asked for a paired Release comparison against the build before Today. Baseline `ba1853e` and current `main` `f742e0b`, both Release, ad-hoc signed, bundle id `com.marspater.news.isolatedqa`, macOS 27.2.1, dark appearance. Seven alternating rounds, the first discarded; the same library copy (3,056 articles) was restored before every launch, and each window opened in the background and ran 25 seconds. The criterion was fixed before the run: confirmed if the median on `main` exceeds the baseline's by more than 10 % and `main` is slower in at least 5 of 6 rounds.

| Build | First card, ms: median (range) | Footprint after 25 s, median | Peak, median |
| --- | --- | --- | --- |
| Baseline `ba1853e` | 906 (844 to 967) | 426 MB | 456 MB |
| `main` `f742e0b` | 1,200 (1,136 to 1,232) | 557 MB | 599 MB |

- **The slower first card is confirmed:** 294 ms at the median (32 %), slower in 6 of 6 rounds by 178 to 357 ms, and the two ranges do not overlap.
- **This was not a quiet Mac.** The load average was 3.8 to 7.1 during the run (the Mac was in use), and both builds are slower than in the rows above. The difference between the builds stands; the absolute figures are not budget figures. A run on an idle Mac is still owed before a budget is set.
- **Memory:** `main` holds about 130 MB more after 25 seconds and about 140 MB more at its peak. The footprints here are higher than above for both builds. The cause was not looked into; the rows above relaunched a library left in place, and here it was restored before every launch.

**Options for the first card, for Mars:** keep the wait and set Today's budget from a clean measurement; or remember the last edition's lanes and lay the page out from them at launch, refreshing the assignment in place afterwards, which removes the wait at the price of a new stored value.
