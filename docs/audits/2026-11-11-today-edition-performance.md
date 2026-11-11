# Today edition: performance and QA captures (Z5, #937)

**Date:** 11 November 2026
**Epic:** Z · Today edition (#932)
**Scope:** what laying out the Today page costs, the offscreen captures of the page, and what was not measured. The budget table itself belongs to the re-baseline of #543; the numbers proposed here are carried into it.

## Lane assignment for one page

The Today list loads 200 stories a page. `TodayEdition` is built from them off the main actor: `loadTodayAssignmentContext` (SQLite), then `TodayEditionAssigner.assign` (pure), then the differing accounts of the Coverage cards.

Measured with the optimized test runner on a private copy of the development library (74 MB), the newest 200 stories of a 72-hour window, medians of three passes per run:

```bash
./test.sh --today-shadow /private/tmp/<run>/library-copy.sqlite3 /private/tmp/<run>/<output>
```

The run prints `TODAY_PAGE_TIMING`; `--today-shadow` now builds with `-O`.

| Measure | Before | After, run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: | ---: |
| Stories / story entries | 200 / 180 | 200 / 180 | 200 / 180 | 200 / 180 |
| Context load, median ms | 39.3 | 41.1 | 40.8 | 40.8 |
| Assignment, median ms | 727.0 | 125.6 | 125.3 | 125.2 |

**What changed.** Each story's evidence needs three NaturalLanguage passes (sentiment, names, and names again for the interest match when the library holds no entity mentions for it), about 4 ms a story. The stories are independent, so `evaluateStories` spreads them over the cores with `DispatchQueue.concurrentPerform` and writes each result to its own slot. The order of the result and every value in it are unchanged; `testConcurrentEvaluationMatchesSerial` compares the concurrent evaluation of 40 stories with the serial one.

The Mac was in use during the runs (load average about 4), so the figures are an upper bound for an idle Mac, not a clean median under `docs/audits/2026-11-07-build-measurement-protocol.md`. The "before" figure is one run.

**Proposed budget for #543:** 250 ms for context load plus assignment of a 200-story page. The two medians above sum to 166 ms, which is not the median of the combined durations: the runs above did not record it, and `TODAY_PAGE_TIMING` now prints `combinedMedianMs` for the next run. The launch transition waits for the edition for at most one second (`ArticleListView.settleLaunch`). These timings follow a full-window load and assignment and leave out other page work, so they do not show that the edition arrives with the first frame; that needs the first-frame measurement listed below.

## Not measured

Each needs the app in a window, which agents do not open on this Mac:

| Budget | How to measure |
| --- | --- |
| Today first frame | `script/launch_baseline.sh`, or the `NewsPerformanceTests` UI test plan in CI's profile workflow |
| Scroll frame time per lane, and of the page | Instruments (Animation Hitches) on the Profile build, scrolling each row and the page |
| Image memory with the edition showing | `NEWS_READING_FULL_APP=1 script/native_performance_baseline.sh`, extended to leave Today showing |
| What a baked photo dissolve would cost the Compact grid | Compare the grid's scroll hitches with and without it; Z6 ships a gradient that costs no pass per photo |

`Tests/Harness/ListInvalidationBaseline.swift` counts view bodies with Today showing; its expectations predate the edition and it was not re-run.

## Captures

`Tests/Harness/TodayCaptures.swift` renders, without a window, the card variants and the whole page: at the column widths of a 1,440 pt and a 900 pt window, light and dark, Increase Contrast at the wide width, full and partly filled (The Lead and The Latest only). Fictional stories and drawn photos; nothing reads a library or the network.

```bash
NEWS_CONFIGURATION=Debug NEWS_NATIVE_HARNESS=Tests/Harness/TodayCaptures.swift script/native_performance_baseline.sh /private/tmp/today-captures
```

The captures cannot show glass, the image carried under the sidebar, hover, the carousel's motion or macOS 15. Those are checked in a window.

Earlier renders of this harness found two layout defects that the tests had not: a card image collapsing to its ideal width under a fixed row height, and a lane row taking the height of its first cards.
