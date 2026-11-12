# Today edition Z2: In Motion with and without rising momentum, reviewer check (#934, 12 November 2026)

I allowed this check to be done without waiting for my own read of the 14 disputed events. It compares what In Motion shows under the rule on `main` and under the one alternative still open, and ends with one recommendation. It concerns Athena · attention (the lane assignment). **Every label here is a reviewer label, not mine**, except the 12 events I ruled on in the spot check of 11 November, which are marked. Nothing shipped changes.

Counts and event-id prefixes only. Headlines, sheets and label files stay under `~/news-eval/`.

## What is implemented, and what the alternative is

| | Rule | Where it exists |
| --- | --- | --- |
| **Shipped** | A report dated in the last 24 hours whose headline is not among the event's headlines from before those 24 hours, **and rising momentum** | On `main`, in the module (`TodayEditionThresholds.standard`). This is what the app shows |
| **Alternative** | The same headline test, **any momentum** | In the module as an evaluation option that ships off (`inMotionRequiresRisingMomentum`), switched on only by the harness and by tests. The app never sets it |

So the rule is fully implemented; nothing has to be built before a read of the events. The read chooses between the two rows. A 36-hour update window is a third harness option, already set aside on 11 November, and is reported below only for the events it adds.

## How it was checked

The check ran in the shadow harness, not in a window. The app takes the clock from the system, and the library copy with the reviewed events is of 30 October: opened today, every story on it is older than 24 hours and the lane would be empty under either rule. The harness runs the app's own assigner and bars at the pinned clock (`NEWS_TODAY_NOW=1793382432`), which is the only way to see these events as they stood.

Inputs as in [the pool audit](2026-11-12-today-evaluated-pool.md): the copy of 30 October, my 28 feeds, `eddd2ae`. Labels:

- **Reviewed set:** 50 events, labelled by the first reviewer on 10 November. I ruled on 12 of them on 11 November (4 changes). 48 are candidates under my subscriptions: 10 real updates, 8 repetitions, 1 borderline, 29 initial reports.
- **The 14 disputed events:** those that clear the bar in some variant and that I have not ruled on. The first reviewer had labelled 7 (5 repetition, 2 initial report); 7 had no label. A second reviewer labelled all 14 on 12 November, blind: it saw each event's reports with their ages and headlines, and neither the first labels nor which variant shows what.

## Result on the 72-hour pool

| | Shipped: 24 h, rising | Alternative: 24 h, any momentum |
| --- | --- | --- |
| Stories that clear the bar | 5 | 17 |
| Shown (cap 12) | 5 | 12 |
| Real updates shown | 4 | 6 |
| Repetitions shown, first reviewer | 0 | 5 |
| Repetitions shown, second reviewer on those five | 0 | 2 (it calls the other 3 real updates) |
| Borderline shown (my ruling) | 1 | 1 |
| Initial reports shown | 0 | 0 |
| Real updates missed | 6 (4 steady, 2 fading) | 4, all dropped by the cap |
| Unlabelled stories shown | 0 | 0 |

- **The shipped rule shows no repetition under either reviewer**, and misses 6 of the 10 real updates because their momentum is steady or fading.
- **The alternative lets all 10 real updates clear the bar but shows only 6**: 17 stories compete for 12 places, the cap keeps the highest scores, and 4 real updates fall out while repetitions stay in.
- **How much of the alternative's lane is repetition depends on the reviewer**: 5 of 12 by the first, 2 of 12 by the second.

## The 14 disputed events

| # | Event | Newest report | Momentum | First reviewer | Second reviewer, blind (confidence) | 24 h, any momentum | 36 h, any momentum |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `C9BDE7EC` | 25 h | steady | initial_report | borderline (medium) | does not clear | shown |
| 2 | `7593C294` | 27 h | steady | initial_report | repetition (high) | does not clear | shown |
| 3 | `EC74B9BF` | 3 h | steady | repetition | new_information (high) | shown | shown |
| 4 | `F8D91313` | 7 h | fading | repetition | new_information (medium) | shown | shown |
| 5 | `E7CE308B` | 10 h | fading | repetition | repetition (high) | shown | dropped by cap |
| 6 | `8F10818D` | 17 h | steady | repetition | new_information (high) | shown | shown |
| 7 | `244E2F37` | 20 h | steady | repetition | repetition (high) | shown | shown |
| 8 | `06268CB9` | 25 h | steady | none | new_information (medium) | does not clear | shown |
| 9 | `CABD64AA` | 25 h | steady | none | new_information (low) | does not clear | dropped by cap |
| 10 | `8AE07E47` | 27 h | steady | none | repetition (medium) | does not clear | dropped by cap |
| 11 | `0C708EA5` | 27 h | steady | none | initial_report (high) | does not clear | dropped by cap |
| 12 | `A06C5F49` | 29 h | steady | none | initial_report (high) | does not clear | dropped by cap |
| 13 | `7EDE2083` | 30 h | steady | none | borderline (medium) | does not clear | dropped by cap |
| 14 | `06526C23` | 31 h | steady | none | new_information (low) | does not clear | dropped by cap |

None of the 14 clears the shipped bar.

- **Only events 3 to 7 bear on the choice between the two rules.** They are the five repetitions the alternative shows. Events 1, 2 and 8 to 14 clear the bar only with the 36-hour window.
- **The two reviewers agree on 2 of the 7 events both labelled** (events 5 and 7). On events 3, 4 and 6 the first says repetition and the second says real update. That disagreement is the whole difference between "5 repetitions" and "2 repetitions".
- For the 36-hour window the second reviewer finds 3 real updates among the 7 unlabelled events, two of them with low confidence, beside 1 repetition, 2 initial reports and 1 borderline. That does not reopen the window.

## On the page the app assigns from

On the first listed page (144 candidates, 3.2 hours) 18 of the labelled events are candidates.

| | Shipped | Alternative |
| --- | --- | --- |
| Clear the bar | 2 | 3 |
| Lane | hidden (needs 3) | shown: 1 real update, 1 repetition (first reviewer), 1 borderline |

With either rule the lane rests on two or three stories there. That is a question of the pool, not of momentum.

## Recommendation

**Keep the rising requirement.**

1. It is the only rule of the two that shows no repetition under both reviewers. The lane's promise is "new reporting", and the shipped rule keeps it on this set: 4 real updates and one event I called borderline.
2. Dropping it does not deliver the updates it admits. Ten clear the bar, six are shown; the cap then decides by score, which follows publisher count, and it keeps repetitions over real updates. Without a better order inside the lane, any momentum trades 2 more real updates for 2 to 5 repetitions.
3. The evidence for dropping it rests on labels two reviewers disagree on in 5 of 7 cases. It cannot carry a change to a shipped default.

What this recommendation costs, stated plainly: 6 of 10 real updates on the reviewed set are not shown, and on the first page the lane is hidden. If that recall is not acceptable, the lever to look at is the order under the cap and the pool, not the momentum test; neither is measured here.

My read of events 3 to 7 would settle the one open point: if I call at least three of them real updates, the alternative's lane is 9 real updates to 2 repetitions and the choice is closer than this audit makes it.

## Limits

- One library copy, one clock, one reader; 48 events, of which 10 are real updates.
- Reviewer labels judge headlines and ages only. The second reviewer saw the 14 events and nothing else.
- Momentum is computed from report dates inside an event; a split event (#737) lowers it.
- Not a live check: no window was opened, for the reason given above.

## Ledger

Not logged as runs: the three label sets give the same assignment and differ only in how events are counted. The run under the corrected labels is the `reference` line of the pool audit; the receipts of the two reviewer-label runs are in `today-pool-2026-11-12/` under `~/news-eval/`.
