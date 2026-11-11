# Today edition Z2: re-run and comparisons for In Motion and Your Beat (#934, 11 November 2026)

Mars asked on 11 November 2026 for [the first shadow evaluation](2026-11-10-today-z2-shadow-evaluation.md) of [Z2 (#934)](https://github.com/marspater/NewsApp-macOS/issues/934) to be run again with his real subscriptions and his label corrections, and for two rules to be compared before he chooses: In Motion's update window and rising momentum, and Your Beat's publisher affinity. This audit holds that comparison. Nothing here is a decision: every variant is a default-off option or lives in the evaluation harness, `TodayEditionThresholds.standard` and the shipped rule are unchanged, and each section ends with a recommendation for Mars, marked as one. The first evaluation stays preliminary, and this run does not pass the Z2 gate.

Aggregate numbers only. Titles, review sheets and label files stay under `~/news-eval/today-shadow-2026-11-11/` and `/private/tmp`.

## Dataset

| Input | What it is |
| --- | --- |
| Library | The copy of 30 October 2026 the first run used (`~/news-eval/library-copy.sqlite3`): 7,442 articles, 37 fetched feeds, 99 stories read or saved in the 30 days before the clock, and 29.8 days of stories inside that window. Read through a copy under `/private/tmp`; the original is untouched |
| Clock and window | `NEWS_TODAY_NOW=1793382432` (the newest story), 72 h candidate window, as in the first run |
| Subscriptions | The reader's list exported from the app on 11 November 2026: 28 feeds. All 28 are among the 37 feeds the copy fetched; the other 9 fetched feeds are not on the list. The list is twelve days newer than the snapshot: a feed removed in between counts as never subscribed here |
| Labels | The first run's single-pass reviewer labels (200 stories, 50 events) with Mars's spot-check applied; where his reading and the reviewer's differ, his wins |

**What the subscription list did to the candidate pool.** It admits 612 of the 738 stories in the 72 h window (83 %) and 406 of the 522 stories of the last 24 h (78 %). Of the labelled set, 161 of 200 stories and 48 of 50 events are still candidates: 10 of 10 real updates, the borderline event, 7 of 8 repetitions and 30 of 31 initial reports.

**What the corrections changed: 10 label values, on 4 events and 5 stories.**

| Label | Changes | Detail |
| --- | --- | --- |
| Event label (In Motion) | 4 | 2 `repetition` to `new_information`, 1 `repetition` to `borderline` (a class of its own, counted apart), 1 `new_information` to `repetition` |
| Lead-worthy | 3 | 2 from no to yes, 1 from yes to no |
| Expected lane | 3 | 1 from The Latest to In Motion (a story whose event he ruled a real update); 2 removed, because his ruling leaves no expected lane: the borderline event's story, and the story he ruled not Lead-worthy whose label expected The Lead |

The corrected events are 10 `new_information`, 8 `repetition`, 1 `borderline` and 31 `initial_report`. He ruled on 12 events; the stories of 9 of them are older than the 200 labelled stories, so only their event labels exist. Everything he did not rule on keeps its reviewer label: 7 of the 8 `repetition` labels and all 31 `initial_report` labels are the reviewer's alone, and he overturned all 3 `repetition` labels he checked.

## Commands

```sh
NEWS_TEST_ATOM=Tests/NewsTests.swift \
NEWS_TODAY_NOW=1793382432 \
NEWS_TODAY_LABELS=<private>/labels-corrected-private.json \
NEWS_TODAY_FEEDS=<private>/feeds-real-app-2026-11-11.txt \
./test.sh --today-shadow /private/tmp/<run>/library-copy.sqlite3 /private/tmp/<run>/<output>
```

One call writes the main report and, under `comparisons` in `shadow-report.json`, every In Motion and Your Beat variant below, so all rows of a table share one build, one copy and one clock. The runs of record were measured at commit `50f6e74`: one optimized runner (`script/build_test_runner.sh <runner> -O`, which is what `./test.sh --today-shadow` builds) started three times with the arguments above.

| Run | `NEWS_TODAY_FEEDS` | `NEWS_TODAY_LABELS` | Purpose |
| --- | --- | --- | --- |
| A | not set (37 fetched feeds) | the reviewer labels of 10 November | Reproduces the first run on this branch |
| B | not set (37 fetched feeds) | corrected labels | Shows what the corrections alone change |
| C | the 28 subscribed feeds | corrected labels | The run every table below reports, unless it says otherwise |

The harness changed in four ways that matter when reading the numbers; run A shows that none of them moves a figure of the first run.

- The three rankings are compared on the labelled stories that are candidates, not on the 200 newest stories: with fewer feeds the 200 newest reach further back than the labels do, and an unlabelled story in a top five was silently left out of the precision.
- The stories of the last 24 h are counted among subscribed stories; the first run counted every story of those 24 h, which was the same number only because every fetched feed stood in for a subscription.
- The counts of stories clearing a lane's bar, and the In Motion figures, use the assigner's own lane tests. The harness held copies of them with rising momentum and the 24 h window written in, which an option would not have reached.
- In Motion is scored on what the lane shows, and a missed update says why: not rising, dropped by the cap, or taken by The Lead.

## 1. Re-run with the real subscriptions and the corrected labels

| Measure | First run (10 November, after #1194) | A: reproduction | B: corrected labels | C: real subscriptions, corrected labels |
| --- | --- | --- | --- | --- |
| Feeds in the pool | 37 | 37 | 37 | 28 |
| Candidates, 72 h / 24 h | 738 / 522 | 738 / 522 | 738 / 522 | 612 / 406 |
| Labelled stories / events that are candidates | 200 / 50 | 200 / 50 | 200 / 50 | 161 / 48 |
| Lead precision@5: publisher count | 5 / 5 | 5 / 5 | 4 / 5 | 4 / 5 |
| Lead precision@5: Briefing signals | 5 / 5 | 5 / 5 | 4 / 5 | 4 / 5 |
| Lead precision@5: Z2 combined score | 5 / 5 | 5 / 5 | 4 / 5 | 4 / 5 |
| Lane purity, overall | 0.975 (195 / 200) | 0.975 (195 / 200) | 0.985 (195 / 198) | 0.987 (157 / 159) |
| Lane purity: The Lead / In Motion / The Deep Read | 1.00 / 0.33 / 1.00 | 1.00 / 0.33 / 1.00 | 1.00 / 1.00 / 1.00 | 1.00 / 1.00 / 0.80 |
| Lane purity: Your Beat / Outside Your Usual / The Latest | 0.875 / not restated / not restated | 0.875 / 1.00 / 0.989 | 0.875 / 1.00 / 0.989 | 0.875 / 1.00 / 1.00 |
| Lane distribution (Lead / In Motion / Deep Read / Your Beat / Outside / Latest) | 5 / 5 / 8 / 12 / 6 / 702 | 5 / 5 / 8 / 12 / 6 / 702 | 5 / 5 / 8 / 12 / 6 / 702 | 5 / 5 / 8 / 12 / 6 / 576 |
| Stories clearing the bar (In Motion / Deep Read / Your Beat / Outside) | 5 / 34 / 375 / 33 | 5 / 34 / 375 / 33 | 5 / 34 / 375 / 33 | 5 / 25 / 348 / 31 |
| Every conditional lane shows | yes | yes | yes | yes |
| Publisher diversity, The Lead: publishers / largest share | 3 / 0.60 | 3 / 0.60 | 3 / 0.60 | 3 / 0.60 |
| Publisher diversity, conditional lanes: publishers / Simpson index | 13 / 0.835 before #1194 | 13 / 0.860 | 13 / 0.860 | 12 / 0.793 |
| Latest completeness | 1.00 | 1.00 | 1.00 | 1.00 |
| Duplicate rate | 0 | 0 | 0 | 0 |
| Your Beat qualifying per day, before the cap | 254 of 522 (49 %) | 254 of 522 | 254 of 522 | 229 of 406 (56 %) |
| Your Beat shown per day | 12 | 12 | 12 | 12 |
| Coverage gate among stories of 3 or more publishers | 23 / 29 | 23 / 29 | 23 / 29 | 22 / 28 |

Run A matches the first run after #1194 on every figure the two share. What the real list changes, beyond a smaller pool:

- **Your Beat is wider, not narrower:** 56 % of the day's stories qualify before the cap, against 49 %. The pool lost 116 of the day's stories, and only 25 of them qualified, all through the interest match. The 155 stories that qualify through publisher affinity alone are all still in it: the four affinity publishers are on the list.
- **The Deep Read shows content types again.** Only 4 stored reads of 8 min or more remain among the candidates (the other 4 of the first run came from feeds not on the list), so 4 of the 8 places go to stories classified by headline, section or URL (2 Explainer, 2 Opinion). Its purity is 4 of 5 on this pool: one of the classified stories is labelled for another lane.
- **In Motion with the corrections reads as Mars found it:** the lane shows 5 stories, 4 real updates and the borderline one, no repetition, and misses 6 real updates. All 6 pass the headline test and are kept out by momentum alone (section 2).

### The Lead comparison still does not separate the three rankings

All three read 4 of 5: each top five holds the same story, the one Mars ruled not Lead-worthy, and it is a Lead slide (of the lane's 5 slides 4 are labelled, 3 of them Lead-worthy). The lists share 4 of 5 stories pairwise, 7 distinct stories in all. His other two corrections cannot show at five: the stories he added as Lead-worthy have one report each; one is not a candidate under the real list, and the other ranks 66th by publisher count and by the Briefing signals and 97th by the Z2 score.

**Proposal (not built).** Five places and one day cannot separate rankers that agree on the few widely covered stories; the difference is in the stories they order differently. I would label the union of each ranker's top 20 on three to five clocks (other days of this copy, or newer copies) blind and by more than one reader, as #737 does for pairs, and score each ranker on precision at 10 and average precision over the Lead-worthy stories, plus a pairwise read ("which of these two leads?") on the pairs the rankers order differently. A first look says depth does separate them: from the rank positions the private sheet of run C already holds, the top ten read 9 of 10 for publisher count, 9 of 10 for the Briefing signals and 7 of 10 for the Z2 score, and average precision over the 11 Lead-worthy stories among the 161 is 0.81, 0.82 and 0.70. That is 11 positives from one reviewer plus three corrections on one day, computed outside the harness: a reason to label properly before the weights are accepted, not a result.

## 2. In Motion: update window and rising momentum

**The variants.** The shipped rule uses one 24 h cutoff for two questions. The evaluation option `inMotionUpdateWindowSeconds` separates them:

- *Is the story already underway?* It has a report older than 24 h (`inMotionWindowSeconds`, unchanged). A story whose reports all fall in the last 24 h is new, in every variant.
- *How recent is the new report?* It is dated within the update window, 24 h or 36 h.
- The candidate report is compared against the reports dated before it, not against those older than the window, and must still be a material headline change against every one of them (`isMaterialHeadlineChange`, unchanged). A report with nothing before it is a first report.
- `inMotionRequiresRisingMomentum = false` lets steady and fading stories in. Nothing else changes: minimum 3, cap 12, and over the cap the lane keeps the highest `score`.

Replacing 24 with 36 in the shipped rule would be wrong: it also moves the earlier reports' cutoff, so a story first reported 30 h ago and updated 2 h ago would read as new. `Tests/TodayLaneAssignmentTests.swift` holds that case and the other boundaries (an update 25, 30 and 36 h old on an older story; a story inside 24 h; a repetition inside the window; a lane of two real updates and one repetition, which stays hidden).

**On the 48 labelled events that are candidates (run C).**

| | Shipped | 24 h, rising | 24 h, any momentum | 36 h, rising | 36 h, any momentum |
| --- | --- | --- | --- | --- | --- |
| Stories clearing the bar | 5 | 5 | 17 | 5 | 26 |
| Lane size (cap 12) | 5 | 5 | 12 | 5 | 12 |
| Lane shows (minimum 3) | yes | yes | yes | yes | yes |
| Real updates shown (of 10) | 4 | 4 | 6 | 4 | 4 |
| Real updates missed | 6 | 6 | 4 | 6 | 6 |
| … kept out by momentum | 6 | 6 | 0 | 6 | 0 |
| … dropped by the cap | 0 | 0 | 4 | 0 | 6 |
| Borderline shown (of 1) | 1 | 1 | 1 | 1 | 1 |
| Repetitions shown (of 7) | 0 | 0 | 5 | 0 | 4 |
| Repetitions clearing the bar | 0 | 0 | 6 | 0 | 6 |
| Initial reports shown (of 30) | 0 | 0 | 0 | 0 | 2 |
| Unlabelled stories shown / clearing the bar | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 1 / 7 |
| Clearing with the newest report older than 24 h | 0 | 0 | 0 | 0 | 9 |
| … of which every report is 24 to 36 h old | 0 | 0 | 0 | 0 | 3 |

No real update is taken by The Lead in any variant, and the lane is never hidden. Run B (37 feeds) gives the same count in every row.

**Downstream placement, against the shipped plan.**

| | 24 h, rising | 24 h, any momentum | 36 h, rising | 36 h, any momentum |
| --- | --- | --- | --- | --- |
| Stories entering In Motion | 0 | 8: 6 from The Latest, 2 from Your Beat | 0 | 8: 5 from The Latest, 3 from Your Beat |
| Stories leaving In Motion | 0 | 1, to The Latest: a real update, dropped by the cap | 0 | 1, to The Latest: the same real update |
| Lanes after (Lead / In Motion / Deep Read / Your Beat / Outside / Latest) | 5 / 5 / 8 / 12 / 6 / 576 | 5 / 12 / 8 / 12 / 6 / 569 | 5 / 5 / 8 / 12 / 6 / 576 | 5 / 12 / 8 / 12 / 6 / 569 |

Your Beat stays at 12: the places In Motion takes from it are refilled from the stories its cap had dropped. The Deep Read, Outside Your Usual and The Lead do not move.

**What each variant gains and loses.**

- **24 h, rising.** The same five stories as the shipped rule, on both pools. It gains a definition that keeps the two questions apart and compares an update with what came before it; on this copy it costs and changes nothing.
- **24 h, any momentum.** Every one of the 10 real updates now clears the bar: the 6 the shipped rule misses are 4 steady and 2 fading, and momentum was the only thing keeping them out. But 6 of the 7 labelled repetitions clear it too (4 steady, 2 fading), so 17 stories compete for 12 places, and the cap, which keeps the highest `score`, shows 6 real updates, the borderline one and 5 repetitions and drops 4 real updates. By the labels the lane goes from 4 real updates in 5 to 6 in 12. The headline test does not fill the lane to reach three, but once momentum is gone it is the only filter, and on these labels it lets most repetitions through.
- **36 h, rising.** The same five stories again. Momentum looks only at the last 12 h (reports of the last 6 h against the 6 h before), so a story whose newest report is 25 to 36 h old is never rising: the wider window can only add a story that also has a fresh report, and this copy has none. 2 labelled initial reports pass the 36 h headline test and are kept out by momentum.
- **36 h, any momentum.** 9 more stories clear the bar than at 24 h, all with a newest report older than 24 h. None is a labelled real update: 2 carry the reviewer's `initial_report` label and 7 have no label. 3 of the 9 are stories whose every report is 24 to 36 h old, which is a first day's burst of differing headlines read as an update: the rule as specified lets them in, because a report 30 h old is "older than 24 h" and has a report before it. With 26 stories for 12 places the lane shows 4 real updates, fewer than at 24 h, and 2 initial reports.

**Limits that bear on the choice.**

- The event labels answer the 24 h question: does a report of the last 24 h add something new? An event whose real update is 30 h old was labelled `initial_report` or `repetition` under that question. The 9 stories the 36 h window adds are therefore unjudged, not wrong, and this data cannot say what 36 h gains.
- The repetition count rests on reviewer labels. Of the 6 repetitions that clear the bar without momentum, 1 was ruled a repetition by Mars; the other 5 are single-pass reviewer labels, and he overturned all 3 reviewer `repetition` labels he checked.
- One copy, one clock, 48 events, drawn around the 24 h boundary.

A private sheet lists the events that clear the bar in a variant and that Mars has not ruled on (`~/news-eval/today-shadow-2026-11-11/spot-check-in-motion-variants-for-mars.md`: 14 events: the 5 repetitions, the 2 initial reports and the 7 unlabelled stories, with every report's age and headline), so the two open points above can be settled by reading them.

**Recommendation for Mars (not a decision).**

1. Take the two-question form with a **24 h** update window. It is the shipped lane on this copy and removes the trap of a literal 24-to-36 change.
2. **Do not widen to 36 h on this evidence.** It adds no labelled real update, its 9 entrants are unjudged, 3 of them are first-day bursts, and with any momentum it pushes real updates out through the cap. If 36 h is still wanted, it needs the sheet's verdicts first and a guard for a story whose every report is in the 24 to 36 h band.
3. **Rising momentum is what misses the 6 real updates, and dropping it is not safe yet.** Read the 5 reviewer-labelled repetitions on the sheet before choosing. If most are repetition, keep rising for now and strengthen the headline test first, because without momentum the lane would be about two fifths repetition. If most are real updates, drop rising with the 24 h window; the cap then binds (17 for 12 places), so the over-cap order for this lane, today the importance `score`, should be reviewed in the same step, since it is what drops 4 real updates here.

## 3. Your Beat: narrower publisher affinity

A story qualifies for Your Beat through a starred feed, an interest match of 0.50 or more, or a publisher in the top quartile of the reader's 30-day engagement (read 1, saved 3, publishers with a weight of 2 or more). Starred feeds and the 0.50 interest match stay independent in every option; only the third path changes. In Motion stays on the shipped rule for these runs.

| Option | How it is built |
| --- | --- |
| Current | The shipped rule |
| Booster at 0.20, 0.30, 0.40 | `yourBeatAffinityInterestMinimum`: a top-quartile publisher qualifies a story only together with an interest match of at least that value |
| Per story published | The top quartile is taken by engagement per story the publisher published in the 30-day window, not by engagement alone (harness: the profile's affinity set is replaced) |
| Minimum 3, 5, 10 stories | A top-quartile publisher counts only when the reader read or saved at least that many of its stories (harness) |
| No affinity | Affinity does not qualify a story (harness: an empty affinity set) |

The library copy holds no starred feeds (they live in the app's settings), so no story qualifies by a star in any run: that path is not measured here.

**The whole reading history (99 stories, 16 engaged publishers), run C.**

| Option | Qualify per day, of 406 | By interest / by affinity alone | Affinity publishers: rank by the day's volume | Busiest publisher / top three, before the cap | Busiest publisher / top three, in the lane (12 shown) | Lane stories that differ from current | Labelled lane stories as expected | Lane purity, all lanes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Current | 229 (56 %) | 74 / 155 | 4 publishers: 1, 2, 4, 6 | 36 % / 79 % | 58 % / 92 % | 0 | 7 of 8 | 0.987 |
| Booster at 0.20 | 163 (40 %) | 74 / 89 | the same | 31 % / 73 % | 42 % / 92 % | 3 | 6 of 6 | 0.981 |
| Booster at 0.30 | 157 (39 %) | 74 / 83 | the same | 31 % / 72 % | 42 % / 83 % | 4 | 5 of 5 | 0.975 |
| Booster at 0.40 | 148 (36 %) | 74 / 74 | the same | 32 % / 71 % | 42 % / 75 % | 4 | 5 of 5 | 0.975 |
| Per story published | 96 (24 %) | 74 / 22 | 4 publishers: 6, 10, and two with no story that day | 24 % / 55 % | 25 % / 50 % | 9 | 2 of 3 | 0.950 |
| Minimum 3, 5 or 10 stories | 229 (56 %) | 74 / 155 | as current | 36 % / 79 % | 58 % / 92 % | 0 | 7 of 8 | 0.987 |
| No affinity | 74 (18 %) | 74 / 0 | none | 31 % / 51 % | 25 % / 58 % | 9 | 2 of 3 | 0.950 |

"By affinity alone" under a booster means affinity together with an interest match between the booster's bar and 0.50. Lane purity falls as affinity narrows (157 of 159 labelled stories in their expected lane, down to 151) because stories the reviewer expected in Your Beat no longer enter it. The reviewer wrote those expectations with the shipped lanes in view and cannot know the reader's taste, so the last two columns show that an option moves labelled stories, not that it misplaces them. Outside Your Usual is the same size in every row: 31 stories clear its bar, 6 are shown (its cap) and the lane shows. Its membership changes by 3 of 6 whenever affinity is narrowed, because stories that no longer enter Your Beat become its candidates.

**A reader with little history.** The reading history is cut to its newest stories (`interactionLimit`); every other input is the same.

| History | Engaged / affinity publishers | Current | Booster at 0.30 | Per story published | Minimum 3 | Minimum 5 or 10 | No affinity | Your Beat shown | Outside Your Usual: clearing / shown |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Whole (99 stories) | 16 / 4 | 229 | 157 | 96 | 229 | 229 | 74 | 12 in every option | 31 / 6 |
| Newest 15 | 5 / 2 | 202 | 159 | 130 | 202 | 118 | 118 | 12 in every option | 19 / 6 |
| Newest 5 | 2 / 1 | 103 | 103 | 103 | 97 | 97 | 97 | 12 in every option | 20 / 6 |
| None | 0 / 0 | 0 | 0 | 0 | 0 | 0 | 0 | hidden | 0 / hidden |

Cells are stories qualifying per day, of 406, before the cap. With no history Your Beat and Outside Your Usual are both hidden and their stories are in The Latest (594), whatever the option.

**What each option gains and loses.**

- **Current.** More than half of a day's stories qualify, two thirds of them through affinity alone, and the four affinity publishers are the 1st, 2nd, 4th and 6th busiest of the day: the signal follows volume. In the lane, 7 of 12 stories come from one publisher and 11 of 12 from three.
- **Booster.** Cuts the daily number by about a third (229 to 157 at 0.30) and keeps a topical reason behind every Your Beat story, which is what the lane's description promises. It leaves the same four busy publishers in charge: the top three still hold 72 % before the cap and 10 of 12 places. The bar matters little between 0.20 and 0.40 (163 to 148). For a 15-story history it cuts about a fifth (202 to 159); for 5 stories it changes nothing.
- **Per story published.** The strongest cut that keeps affinity as its own path (96 a day), and the only one that changes which publishers count: away from the busiest. The lane's concentration falls to the level of no affinity (3 of 12 from one publisher). Its weakness shows in the same row: two of its four publishers have no candidate story that day, which is what a rate does with small numbers, a few reads of a publisher that publishes little. It needs a floor on stories published or read before it can be trusted, and this run did not test one.
- **Minimum stories read.** Changes nothing for this reader's whole history, where each affinity publisher has at least 10 read or saved stories. It is a guard for short histories only: at 15 stories a minimum of 5 removes affinity (202 to 118), at 5 stories any minimum does.
- **No affinity.** The narrowest (74 a day, 18 %) and the simplest, with the lane's concentration at 3 of 12. It sets aside the decision of 9 November that affinity has full weight in Your Beat.

**Two findings beside the question asked.**

- **For a short history, affinity hardly matters; the interest match does.** With 5 stories read, 97 stories a day qualify by interest alone, more than with the whole history (74), and with 15 stories 118 do. The interest match is scaled by the largest weight in the reader's own profile, so in a small profile every matching keyword counts fully. Your Beat is full at 12 from five read stories under every option. Whether a five-story profile should fill the lane is a separate question from affinity, and no option here answers it.
- **Outside Your Usual does not depend on the choice**, except with no history, where it has no profile to be outside of.

**Recommendation for Mars (not a decision).**

1. Make publisher affinity a **booster at 0.30** now. It is the measured option that narrows the lane (56 % to 39 % of the day) without setting aside the 9 November decision, it is a tested, default-off threshold in the module, and it needs no new data in the profile.
2. Treat **per story published** as the real answer to "a busy publisher dominates by volume", but only with a floor (a minimum of stories published and read) and as a follow-up measurement: as built it promotes two publishers with nothing to show that day. A booster does not fix concentration, so if 10 of 12 places from three publishers is still too much after step 1, this is the next step, or a per-publisher limit inside the lane, which this run did not measure either.
3. Do not adopt a minimum of stories read on its own: it does nothing for a reader with history.
4. Decide separately what a short history may fill (the first finding above).

## Limits

- One library copy at one clock, one reader. The subscription list is twelve days newer than the snapshot.
- Reviewer labels are single-pass; Mars checked 20 stories and 12 events. Lead-worthiness is his one reading, as he says himself.
- 161 labelled stories and 48 labelled events are candidates under the real list; the conditional lanes hold few labelled stories, so their purity moves in steps of one story.
- Starred feeds are not in the copy and are not measured. Publisher volume is counted over the 29.8 days of stories the copy holds.
- No timing is claimed. The harness computes each story's language score once and reuses it across the variant passes of a run; the first attempt, which recomputed it in every pass, was stopped when its memory grew without bound. The main report's own passes are unchanged.
- This run does not pass the Z2 gate in #934.

## Run ledger

Experiment `934-today-assignment`, `source=docs/audits/2026-11-11-today-z2-comparisons.md`, `commit=50f6e74`. Run C and its variants are logged under `dataset=library-copy-2026-10-30+real-subscriptions-2026-11-11+corrected-labels`: the shipped rule as `baseline`, and as `reference` the four In Motion variants and the eight narrower Your Beat options. Runs A and B are logged as `reference` under `library-copy-2026-10-30+fetched-feeds+reviewer-labels` and `library-copy-2026-10-30+fetched-feeds+corrected-labels`. The measure names are in [`docs/TOOLING.md`](../TOOLING.md).
