# Today edition Z2: the evaluated pool against the pool the app assigns from (#934, 12 November 2026)

Both Z2 audits ([10 November](2026-11-10-today-z2-shadow-evaluation.md), [11 November](2026-11-11-today-z2-comparisons.md)) assign over every story of 72 hours. The app assigns over the listed page, 200 stories at a time before grouping. This audit repeats the Z2 measures on the app's pool and sets both side by side. It concerns Athena · attention (the lane assignment, `Sources/Intelligence/Today/`). Nothing shipped changes: the new pool is a mode of the evaluation harness (`Tests/TodayShadowEvaluation.swift`).

Aggregate numbers only. Titles and label files stay under `~/news-eval/` and `/private/tmp`.

## How the app's pool is built in the harness

`NEWS_TODAY_POOL=page` lists the stories with the engine query the list uses for Today, with the same arguments: `DatabaseEngine.fetchArticles(section: "Today", limit: 201, options: ArticleFetchOptions(after: cursor))`, the first 200 kept, then `eventFeedSummaries` and `EventFeedGrouping.entries`. `NEWS_TODAY_PAGES=n` loads further pages through the same cursor, as scrolling The Latest does.

- The query and paging are the app's own engine code. The few lines that call them are mirrored from `ArticleListView.reload` and `fetchPage`, which are private to the view; sharing them would mean moving them out of the view, which this audit does not do.
- The query does not read the clock and does not filter by subscription. The page is taken first and the assigner then drops the stories of feeds I left, as in the app.
- Settings a library copy does not hold are at their defaults: read stories stay listed (`autoHideRead` off), nothing is muted, no feed is collection-only, no feed is starred.
- The photo rule (a story without a photo takes no Lead slide) is reported apart, so the other figures stay comparable with the earlier audits.

## Dataset and command

The inputs of run C of 11 November: the library copy of 30 October 2026, clock `NEWS_TODAY_NOW=1793382432`, my 28 subscribed feeds, the corrected labels. Measured on `eddd2ae`, one optimized runner for all runs:

```sh
NEWS_TEST_ATOM=Tests/NewsTests.swift \
NEWS_TODAY_NOW=1793382432 \
NEWS_TODAY_LABELS=<private>/labels-corrected-private.json \
NEWS_TODAY_FEEDS=<private>/feeds-real-app-2026-11-11.txt \
NEWS_TODAY_POOL=page NEWS_TODAY_PAGES=1 \
./test.sh --today-shadow /private/tmp/today-pool-2026-11-12/library-copy.sqlite3 /private/tmp/today-pool-2026-11-12/page1
```

Without `NEWS_TODAY_POOL` the run is the 72-hour pool. That run reproduces run C of 11 November exactly (612 candidates, 406 a day, 229 for Your Beat, 4 of 5 for each Lead ranking), so `main` since #1235 and #1243 assigns as it did then.

## The two pools

| | 72 hours (evaluated so far) | First page (what the app assigns at launch) | 2 pages | 3 pages | 5 pages |
| --- | --- | --- | --- | --- | --- |
| Stories listed | 937 | 200 | 400 | 600 | 1,000 |
| Hours from newest to oldest | 71.9 | 3.2 | 7.6 | 20.0 | 99.8 |
| Story entries after grouping | 738 | 176 | 325 | 473 | 797 |
| Candidates under my subscriptions | 612 | 144 | 249 | 358 | 671 |

- **The first page holds 3.2 hours of stories on this library**, not a day. The edition a reader sees at launch is assigned from 144 candidates; the evaluated one from 612.
- The pool grows only when The Latest is scrolled to its end and the next page loads. Three pages reach 20 hours; the fifth passes the 72 hours (63 of its stories are older).

## Z2 measures on both pools

| Measure | 72 hours | First page | 2 pages | 3 pages | 5 pages |
| --- | --- | --- | --- | --- | --- |
| Lead precision@5: publisher count / Briefing signals / Z2 score | 0.8 / 0.8 / 0.8 | 0.8 / 0.8 / 0.8 | 0.8 / 0.8 / 0.8 | 0.8 / 0.8 / 0.8 | 0.8 / 0.8 / 0.8 |
| Lead slides shown; with a label; labelled Lead-worthy | 5; 4; 3 | 5; 5; 4 | 5; 4; 3 | 5; 4; 3 | 5; 4; 3 |
| The Lead: publishers; busiest publisher's share | 3; 60 % | 2; 60 % | 3; 60 % | 3; 60 % | 3; 60 % |
| In Motion: clear the bar / shown | 5 / 5 | 2 / 0 (hidden) | 5 / 5 | 5 / 5 | 5 / 5 |
| The Deep Read: clear the bar / shown | 25 / 8 | 6 / 5 | 10 / 8 | 12 / 8 | 28 / 8 |
| Your Beat: clear the bar / shown | 348 / 12 | 69 / 12 | 128 / 12 | 200 / 12 | 373 / 12 |
| Outside Your Usual: clear the bar / shown | 31 / 6 | 11 / 6 | 19 / 6 | 23 / 6 | 31 / 6 |
| The Latest | 576 | 116 | 213 | 322 | 635 |
| Conditional lanes: publishers; Simpson diversity | 12; 0.79 | 8; 0.77 | 13; 0.84 | 10; 0.77 | 12; 0.81 |
| Latest completeness | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 |
| Duplicate rate | 0 | 0 | 0 | 0 | 0 |
| Lane purity (labelled stories in the expected lane) | 0.987 | 0.915 | 0.969 | 0.975 | 0.987 |
| Your Beat, shown lane: busiest publisher / top three | 58 % / 92 % | 42 % / 100 % | 50 % / 92 % | 58 % / 92 % | 58 % / 92 % |

"Clear the bar" counts every story that clears the lane's bar on its own, before lane order, minimum and cap.

What changes on the app's pool:

- **In Motion is hidden on the first page.** Two stories clear its bar and the lane needs three. On two pages or more it shows the same five stories as the 72-hour run. So whether a reader sees the lane at launch depends on how many hours the first page holds, which depends on how much my feeds published in the last hours.
- **The Deep Read shows five stories, not eight**: six clear the bar on the page and one of them is taken by The Lead.
- **The Lead's five slides differ from the 72-hour run's.** All five carry a label on the first page and four of them are labelled Lead-worthy (three of four labelled slides in the 72-hour run). Publisher diversity is narrower: two publishers, not three.
- **Your Beat and Outside Your Usual are full on every pool.** Your Beat's concentration is as in the wider pool or worse: the top three publishers hold the whole shown lane on the first page.
- **Latest completeness and the duplicate rate hold on every pool**: every candidate is placed once.

## Your Beat counts on the app's pool

Stories that clear Your Beat's bar, before the cap of 12; the 72-hour column counts the last 24 hours (406 candidates), the first page counts its own 144 candidates (3.2 hours).

| Rule | 72-hour pool, per day | First page | 2 pages | 3 pages |
| --- | --- | --- | --- | --- |
| Current (shipped) | 229 of 406 | 69 of 144 | 128 of 249 | 200 of 358 |
| Per story published, then floor of 5 | 96 | 26 | 54 | 79 |
| No affinity | 74 | 18 | 37 | 58 |

The shares are close on both pools (shipped: 56 % of a day's candidates, 48 % of the first page's). The finding of 11 November holds on the app's pool: the shipped affinity qualifies about half of all candidates, and the combined rule about a fifth.

## The photo rule

Counted here for the first time: stories with no photo on any report of their event, and Lead slides the rule replaces. A photo that fails to load cannot be known offline.

| | 72 hours | First page | 3 pages | 5 pages |
| --- | --- | --- | --- | --- |
| Candidates without any photo | 4 | 0 | 1 | 6 |
| Lead slides replaced by the rule | 0 | 0 | 0 | 0 |

On this library the rule changes no slide.

## What the existing labels cover on the smaller pool, and what they do not

- **Story labels cover the first page completely.** The 200 labelled stories were the 200 newest of the copy, so all 144 candidates of the first page carry a label (161 of the 612 candidates of the 72-hour pool do). Lane purity and the Lead figures of the first page therefore rest on a fully labelled pool; those of the wider pools rest on its newest quarter.
- **Lead precision@5 ranks the same labelled stories in every pool from two pages on** (161), so it cannot differ there. On the first page it ranks 144 and still reads 4 of 5 for all three rankings. The three rankings remain indistinguishable by this measure on either pool.
- **The event labels do not cover the first page.** Of 50 labelled In Motion events, 18 are candidates on the first page: 15 initial reports, 1 real update, 1 borderline, 1 repetition. Nine of the ten real updates are not on it. In Motion on the first page cannot be judged from these labels; it can only be said that the lane is hidden there.
- **No label was written with the first page in view.** The expected lanes were written against the 72-hour edition. Purity on the first page is 0.915 overall and lower in the small lanes: The Lead 0.75, The Deep Read 0.60, Your Beat 0.50, Outside Your Usual 0.40, The Latest 1.00 (72-hour run: The Lead 1, In Motion 1, The Deep Read 0.8, Your Beat 0.88, Outside Your Usual 1, The Latest 1). With a quarter of the candidates, each lane reaches further down its own ranking, so stories the reviewer expected in The Latest of the wide edition sit in a lane of the narrow one. The labels cannot tell that apart from misplacement: the first page needs expected lanes of its own before its purity means anything.
- **Not covered by any label:** Your Beat's and Outside Your Usual's quality (3 labelled stories in Your Beat), starred feeds, and what a reader sees after "Show Updates" or after scrolling.

## Timing

The first page (200 stories, 176 entries) took 48 ms for the context and 38 to 39 ms for the assignment in the optimized runner, medians of three passes, with the Mac in use. This is not a budget figure; the budget record is #937.

## Limits

- One library copy, one clock, one reader. The 28-feed list is twelve days newer than the snapshot.
- The first page is 3.2 hours on this copy at this clock. On a quiet morning it holds more hours, on a busy evening fewer; the lanes' behaviour on the first page moves with that.
- The harness lists the page as the app does at launch. It does not model a held list, "Show Updates", a restored edition (#1243) or a refresh during reading.
- Publisher shares are counted on event groups; one occurrence split into two events counts twice (#737).

## The choice for gate 6

**(a) Accept the page pool.** The app stays as it is and the Z2 evaluation is the one in this audit's first-page column. What that accepts: the edition at launch is built from the last 3 hours or so, In Motion is often hidden, The Deep Read is thinner, and the lanes change when further pages load. In Motion on that pool has no usable labels (1 real update among its candidates), so its gate would need a new reviewed set made on first pages.

**(b) The app assigns over the 72-hour window while the list keeps paging.** The lanes are then the ones the spec describes and the ones both Z2 audits measured, whatever the last hours held. The Latest stays the paged list.

### Cost of (b), from these runs

One pass each in the optimized runner with the Mac in use; the assignment time here includes each story's language score, which the app works out while the list loads (#1235) and so pays earlier.

| Pool | Stories; entries; candidates | Context read | Assignment with language scores |
| --- | --- | --- | --- |
| First page | 200; 176; 144 | 33 ms | 89 ms |
| 2 pages | 400; 325; 249 | 120 ms | 378 ms |
| 3 pages | 600; 473; 358 | 145 ms | 490 ms |
| 72 hours | 937; 738; 612 | 106 ms | 404 ms |

- The 72-hour pool costs about three to four times the first page: roughly 0.5 s against 0.12 s for context and assignment together on this copy. With the scores prepared ahead, as the app does for its page, the assignment alone was 38 ms for the first page (median of three); the same figure for the window was not taken.
- Memory was not measured. The pool adds the stories of 72 hours as list rows (937 here) for the length of the assignment; the plan keeps the entries of the lanes only if The Latest keeps coming from the list.
- The first card is already over its reference on a cold launch (#937). (b) adds to that unless the wider assignment runs behind a page that is already shown, which is what the restored edition of #1243 does on a warm launch.

### What (b) would change, in files this audit does not touch

No part of it can be offered from `Sources/Intelligence/` alone: the pool is chosen where the edition is requested, in view code.

- **`ArticleListView.reloadTodayEdition`** passes `listed`, the grouped page, as the pool. It would ask the store for the window's stories as well (`fetchArticles(section: "Today", options: ArticleFetchOptions(publicationWindow: …))` already exists in the engine, with the list's muting and read filter), group them, and pass both. The task that reloads the edition is keyed on the listed page's revision; it would also have to follow the window's stories, which change with every refresh.
- **`ArticleStore.todayEdition`** would load the context and assign over the window's entries, and prepare their language scores and event photos (today: the page's 200 stories and at most 60 events).
- **`TodayEdition.make`** already shows a lane's stories from the plan and fills The Latest from the listed stories no lane took, so a fresh edition works with a wider plan. Three places assume that every lane story is on the listed page and would drop the others: the held edition (`where listedIDs.contains(story.id)`), the stored edition's restore check (#1243), and the removal of a story that left the list.
- **Paging:** a story placed in a lane from beyond the first page must not appear a second time when its page loads into The Latest; `make` already excludes placed stories, the held path would need the same.
- **Tests and budget:** the Today tests of the edition layout, and the Z5 runs of #937 with the option on.

It can ship as an option that is off by default (a pool setting read in `reloadTodayEdition`), so the freeze on shipped defaults holds until I turn it on.

### Recommendation

**(b), built off by default and measured before it is turned on.** The lanes, their bars and all the evidence so far describe a day-scale pool; on the page pool the edition depends on how much was published in the last three hours, In Motion mostly does not show, and the labels cannot judge it. Accepting (a) would mean accepting an edition that was not the one specified or evaluated, and re-labelling for it. The cost of (b) is real and falls on the first card, so it goes behind the Z5 first-card work and not in front of it. Until (b) is built and measured, this gate stays open and nothing shipped changes.

## Ledger

Experiment `934-today-assignment`, `source=docs/audits/2026-11-12-today-evaluated-pool.md`, `commit=eddd2ae`. The 72-hour run is logged as `reference` under the dataset of run C (`library-copy-2026-10-30+real-subscriptions-2026-11-11+corrected-labels`); the page runs as `reference` under that name with `+page-1`, `+page-2`, `+page-3` and `+page-5`. The measure names are in [`docs/TOOLING.md`](../TOOLING.md).
