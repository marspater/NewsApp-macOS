# Story singletons — 27 October 2026

Refs #581 (story layer follow-up), #574. Measures the story pass's attachment of reports alone ("singletons") to the
story of an event, on matcher v13 (#688). Labelled by Claude; Mars delegated the spot-check of the group review to the
coordinator, who draws the sample from the review sheet independently.

## Setup

- Library: a scratch copy of `~/news-eval/library-2026-10-27.sqlite3` (6,400 articles, newest 25 October 18:05 UTC,
  schema v25, SHA-256 `d8a8095e…cbf4`), never written in place.
- `--library-holdout` with `NEWS_HOLDOUT_NOW=1792854000` (the clusterer's clock pinned to 24 October 15:00 UTC, when the
  holdout `bbb4ded1…10b9` was drawn), the pair-model prefix off, pair cutoff 0.9 unless stated.
- Two windows. The printed share line ("recent stories in a multi-publisher story", `cards`) counts the 1,211 reports
  of the 72 h before the copy's newest report (22 October 18:05 – 25 October 18:05 UTC). Card counts, named cases and
  the group review below use the clusterer's window: the 1,954 reports published since 72 h before the pinned clock
  (21 October 15:00 UTC onward), dumped to `story-cards.csv`.
- Before: matcher v13 at the slice-1 commit (333014a) with the same card dump. After: this slice.

## Rule

A report alone in the active window (unclustered, or the only member of its event) joins the story of the event of two
or more reports it agrees with best: two thirds of its pairs with that event's five earliest members agree by the rules
alone (no conflict other than a different act; two shared specific names that are not common actors, or one such name,
a shared headline figure and two keywords; a shared keyword) and reach the semantic veto's cosine (0.55); its own
headline and one of the event's headlines name one of the shared specific names; no reader exclusion stands. Ties go to
the event with more shared names, then the one that began first. It is stored as a one-member event that carries the
story's `story_id`, so no schema change: the card lists it as one more report, the story is always named by its
earliest event of two or more reports, and the fragment merge never takes it into another event.

The headline condition was added during this review. Without it, two of 22 attachments were wrong: a live blog whose
headline leads with a march in Greece and whose latest entry (its feed description) reports an American freed by
Russia, attached to that release; and a report on Iran's supreme leader whose feed description was another article's,
attached to a story on Israel's prime minister.

## Results

| | v13 (before) | Singletons (after) |
| --- | --- | --- |
| Holdout same / related / different linked, 0.80 | 15 / 1 / 3 | 15 / 1 / 3 |
| … 0.85 | 14 / 1 / 3 | 14 / 1 / 3 |
| … 0.90 | 15 / 1 / 2 | 15 / 1 / 2 |
| … 0.95 | 16 / 1 / 2 | 16 / 1 / 2 |
| Printed share (1,211 reports), 0.90 | 439 (36%) | 451 (37%) |
| Printed cards, 0.90 | 875 | 862 |
| Clock window: reports in a multi-publisher card | 747 of 1,954 (38%) | 764 (39%) |
| Clock window: cards | 1,392 | 1,374 |
| Clock window: story groups (cards joining 2+ events) | 8 | 24 |
| Reports attached alone | — | 18 |

Pair-level results are identical at every cutoff: attaching never changes which reports share an event.

## Named cases (clock window)

| Case | Before | After |
| --- | --- | --- |
| Eagle's Nest fire | 8 reports on 2 cards (the fire and arrest events as one story; one report alone) | 8 on 1 card, 8 publishers |
| Jordan church attack | 25 reports on 5 cards (4 events, 1 alone) | unchanged |
| France 70,000 police | 5 reports on 2 cards (2 events) | unchanged |
| Pope Leo | 4 reports on 2 cards (his treatment; the Oleshky ceasefire he helped broker) | unchanged, rightly two stories |
| Ebola | 20 reports on 11 cards (7 events, 4 alone) | unchanged |

The Jordan, France and Ebola reports name a country, a king or a disease and little else that is specific: a country
is no specific name, so neither the event-to-event rule nor the attachment finds two shared names. The Jordan report
alone (the king's order) shares one name with the event of the king's orders; the figure route needs a headline
number it does not have. Merging these needs a different story signal (#627's three-way head), not a looser name rule.

## Group review

All 24 groups were reviewed (the copy has 24, not the 100 the acceptance names): 8 joined by event-to-event links (two
of them also carry an attached report), 16 that exist only because a report attached alone. Labels: 24 right, 0 wrong
(0 of 8 and 0 of 16); every one of the 18 attachments right. Weakest calls, both labelled right: a Yemeni leader's
statement on the Houthis attached to the Houthi strikes on Saudi Arabia, and a mourning report from the Riyadh airport
attack attached to an event that already mixes the Riyadh and Dammam airport attacks (an event-level error that
predates this slice). The sheet with group ids, member article ids, publishers, headlines and labels is
`~/news-eval/m581-singletons-2026-10-27/story-group-review.csv` (`0600`, SHA-256 `fc0e3bad…dc4e1`).

## Where an attached report shows

- Card: one more report on the story card (newest first), counted in its stories and publishers; its event's version
  adds to the story's, so a new attachment marks the card as updated until the reader opens it.
- Overview: the story opens its lead event's overview, which reads only that event's reports; the attached report is
  not cited there.
- "Earlier in This Story": listed only when it began before the lead event and the lexical relation or a related-act
  decision links it, like any other event; a later attachment is on the card, not in that list. Listing every event of
  a story by `story_id` is for the connected timeline (#671).

## Limits found

- The story rule compares a report with an event's five earliest members, so a report more than 36 h after the event
  began conflicts on time with all of them and never attaches.
- `commonStoryTerms` checks only the first 64 terms in alphabetical order; the story pass passes it every anchor of
  every active event, so most common actors (names after "c") are never tested. Not changed here: it also governs the
  event-to-event links already reviewed in #631.
- Story-level numbers can move by one group between identical runs when two candidate events tie, since event IDs are
  random; the tie now goes to the event that began first.

## Receipts

`~/news-eval/m581-singleton-stories-2026-10-27/` (`0700`): `before-final/` and `after-final/` hold the holdout logs,
`story-groups.csv` and `story-cards.csv` (SHA-256 `269c0999…da02` before, `2b7d3376…b1ea` after); earlier runs of this
slice (`after/`, `after-w/`) are kept as they were.
