# Today edition Z2: Your Beat affinity per story published with a floor of 5 stories (#934, 12 November 2026)

On 12 November 2026 I chose to pursue one Your Beat rule from [the comparison of 11 November](2026-11-11-today-z2-comparisons.md): publisher affinity per story published, with a minimum of 5 engaged stories. That comparison measured the two parts apart. This audit measures them together and looks at a reader with little history, before anything goes into the module. Nothing here ships: the rule lives in the evaluation harness (`Tests/TodayShadowComparisons.swift`), and `TodayEditionThresholds.standard` and the shipped rule are unchanged.

Aggregate numbers only. Titles and label files stay under `~/news-eval/` and `/private/tmp`.

## The rule and its two readings

A story qualifies for Your Beat through a starred feed, an interest match of 0.50 or more, or an affinity publisher. Only the third path changes. "Engaged stories" are the stories of a publisher the reader read or saved in the 30-day profile window, counted once each. The floor can be read in two ways, and both were run:

| Reading | How the affinity publishers are chosen |
| --- | --- |
| Per story, then the floor | The top quartile of engaged publishers by engagement per story published; a publisher below 5 read or saved stories is then removed |
| Per story among the floor | Only publishers with 5 or more read or saved stories are ranked, and the top quartile of those is taken |

## Dataset and command

The same inputs as run C of 11 November: the library copy of 30 October 2026, clock `NEWS_TODAY_NOW=1793382432`, my 28 subscribed feeds, the corrected labels. Measured on `f742e0b` plus this branch's harness change, one optimized runner:

```sh
NEWS_TEST_ATOM=Tests/NewsTests.swift \
NEWS_TODAY_NOW=1793382432 \
NEWS_TODAY_LABELS=<private>/labels-corrected-private.json \
NEWS_TODAY_FEEDS=<private>/feeds-real-app-2026-11-11.txt \
./test.sh --today-shadow /private/tmp/today-shadow-2026-11-12/library-copy.sqlite3 /private/tmp/today-shadow-2026-11-12/out
```

The rows this run shares with 11 November (current, booster, per story published, minimum 5, no affinity, at the whole history and at 15, 5 and no stories) reproduce that audit's figures exactly.

## Whole reading history (99 stories, 16 engaged publishers)

Stories qualifying per day, of 406, before the cap of 12.

| Rule | Qualify per day | By interest / by affinity alone | Affinity publishers: number, rank by the day's volume | Busiest publisher / top three, before the cap | Busiest publisher / top three, in the lane |
| --- | --- | --- | --- | --- | --- |
| Current | 229 | 74 / 155 | 4: 1, 2, 4, 6 | 36 % / 79 % | 58 % / 92 % |
| Per story published | 96 | 74 / 22 | 4: 6, 10, two with no story that day | 24 % / 55 % | 25 % / 50 % |
| **Per story, then floor of 5** | 96 | 74 / 22 | the same 4 | 24 % / 55 % | 25 % / 50 % |
| **Per story among floor of 5** | 74 | 74 / 0 | 2: neither had a story that day | 31 % / 51 % | 25 % / 58 % |
| No affinity | 74 | 74 / 0 | none | 31 % / 51 % | 25 % / 58 % |

- **With the whole history, the first reading equals per story published.** All four per-story publishers have at least 5 read or saved stories, so the floor removes none. This confirms what the 11 November audit could only estimate.
- **The second reading equals no affinity on this day.** Fewer publishers reach the floor, a quarter of them is two, and the per-story rate picks the two that publish least: neither had a story in the last 24 hours. On another day they would contribute a handful of stories.
- **The per-story rate favours publishers that publish little.** That is its purpose, and also its weak point: under both readings, affinity adds between 0 and 22 stories a day on top of the 74 that the interest match already qualifies. The rule's effect on the lane is close to that of removing affinity.

## A reader with little history

The reading history is cut to its newest stories; every other input is the same. Cells are stories qualifying per day, of 406, before the cap, with the number of affinity publishers in brackets.

| History (stories) | Engaged publishers | Current | Per story published | Per story, then floor of 5 | Per story among floor of 5 | No affinity | By interest alone |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Whole (99) | 16 | 229 (4) | 96 (4) | 96 (4) | 74 (2) | 74 | 74 |
| Newest 50 | 10 | 219 (3) | 120 (3) | 120 (3) | 102 (2) | 80 | 80 |
| Newest 25 | 7 | 162 (2) | 121 (2) | 98 (0) | 98 (0) | 98 | 98 |
| Newest 15 | 5 | 202 (2) | 130 (2) | 118 (0) | 118 (0) | 118 | 118 |
| Newest 5 | 2 | 103 (1) | 103 (1) | 97 (0) | 97 (0) | 97 | 97 |
| None | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Your Beat shows 12 stories in every cell except with no history, where it is hidden. Outside Your Usual shows 6 in every cell except with no history; between 19 and 31 stories clear its bar, and which rule is used does not change that number. Its membership differs from the shipped page by 3 to 5 of 6.

- **The floor does what it is for.** Up to 25 read stories no publisher reaches 5, so affinity is off and one or two publishers read twice no longer qualify 12 to 84 stories a day by themselves. From 50 stories on, affinity is back.
- **Cold start is not an affinity problem.** With 5 read stories, 97 stories a day qualify by the interest match alone, more than with the whole history (74), and the lane is full at 12. The interest match is scaled by the largest weight in the reader's own profile, so in a small profile every matching keyword counts fully. No affinity rule changes this. If a reader with five read stories should not get a full Your Beat, the interest match or the lane's display condition needs its own floor. That is a separate question and was not measured.
- **With no history both personal lanes hide** and their stories are in The Latest, under every rule.

## Lane concentration, in the lane as shown (12 stories)

| History | Current: busiest / top three | Per story, then floor of 5 | Per story among floor of 5 |
| --- | --- | --- | --- |
| Whole | 58 % / 92 % | 25 % / 50 % | 25 % / 58 % |
| Newest 50 | 58 % / 92 % | 33 % / 58 % | 25 % / 58 % |
| Newest 25 | 25 % / 58 % | 17 % / 42 % | 17 % / 42 % |
| Newest 15 | 58 % / 75 % | 17 % / 42 % | 17 % / 42 % |
| Newest 5 | 17 % / 42 % | 17 % / 42 % | 17 % / 42 % |

Under the combined rule no publisher holds more than a third of the lane at any history size. Under the current rule one publisher holds 7 of 12 places at three of the five sizes.

## Limits

- One reader, one day, one library copy. The 28-feed list is twelve days newer than the snapshot.
- The copy holds no starred feeds, so that path is not measured.
- The lane-purity figures move with every narrowing of affinity (0.987 to 0.950 for the whole history), because the reviewer wrote the expected lanes with the shipped page in view. They show that stories move, not that they are misplaced: 3 labelled stories remain in the lane under the combined rule, too few to judge it.
- Publisher shares are counted on event groups. One occurrence split into two events counts twice (#737).
- A short history is simulated by cutting this reader's history to its newest stories. A real new reader's first stories may look different.
- The per-story rate rests on few stories: 5 to 10 read stories of 57 to 255 published for its four publishers.

## Reading for my decision (not a decision)

1. The combined rule is safe to take as defined in its first reading: per story published, then the floor. It is identical to per story published for an established reader and switches affinity off below about 25 to 50 read stories.
2. The second reading is not better: it selects fewer and quieter publishers and equals no affinity on this day.
3. What the rule buys over no affinity is small: 22 stories a day here; in the lane, the busiest publisher's share is unchanged (25 %) and the top three's falls from 58 % to 50 %. Whether that is worth the stored count of stories published per publisher that the module would need is the open question for integration.
4. The cold-start width of Your Beat comes from the interest match and needs its own measurement before it is called resolved.

## Integration as a default-off option (12 November 2026, later the same day)

The rule in its first reading (per story published, then the floor) is now in the module behind an option that ships off: `TodayEditionThresholds.yourBeatAffinityPerStoryFloor`, `nil` in `TodayEditionThresholds.standard`. Athena · attention (lane assignment) is the sub-system; no view changes.

- **Off (shipped):** nothing changes. The thresholds, the profile and the plan are the ones on `main`, and the loader runs no further query. A test holds the loaded context equal with and without the parameter.
- **On:** `DatabaseEngine.todayUserProfile` reads the id, source and link of every visible story dated in the 30-day profile window (about 7,400 rows on the evaluation copy) and takes the affinity publishers as the top quartile of engaged publishers by engagement per story published, less those with fewer read or saved stories than the floor. No schema change and no stored count: the count is taken from the stories when the context is loaded.
- **It is the rule this audit measured.** In the shadow run of 12 November (`eddd2ae`) the module's publishers give the harness row's figures at every history size, on both pools:

| History | Harness, per story then floor of 5 | Module option, floor 5 |
| --- | --- | --- |
| Whole | 96 (4 publishers) | 96 (4) |
| Newest 50 | 120 (3) | 120 (3) |
| Newest 25 | 98 (0) | 98 (0) |
| Newest 15 | 118 (0) | 118 (0) |
| Newest 5 | 97 (0) | 97 (0) |
| None | 0 | 0 |

Stories qualifying per day of 406, 72-hour pool. On the first listed page (144 candidates, [the pool audit](2026-11-12-today-evaluated-pool.md)): shipped 69, option 26, no affinity 18, harness and module again equal.

**What turning it on would take:** one line, the default of `yourBeatAffinityPerStoryFloor` set to 5, and one measurement that is still owed: the time of the 30-day read on the launch path, which runs before the first card (#937). It was not timed here. If it costs too much there, the count per publisher can be kept in the library and updated as stories arrive; that is the stored count this audit named, and it is not built.

**The choice, on or off:** on narrows Your Beat from 229 to 96 qualifying stories a day and takes the busiest publisher from 58 % of the shown lane to 25 %, and switches affinity off for a reader with fewer than about 25 to 50 read stories. Against no affinity at all it adds 22 stories a day and leaves the lane's shares about where they are. Off keeps the shipped lane, in which one publisher holds 7 of 12 places.
