# Story singletons — 27 October 2026

Refs #581 (story layer follow-up), #574. Measures the story pass's attachment of reports alone ("singletons") to the
story of an event, on matcher v13 (#688). Labelled by Claude; Mars delegated the spot-check of the group review to the
coordinator, who draws the sample from the review sheet independently.

## Setup

- Library: a scratch copy of `~/news-eval/library-2026-10-27.sqlite3` (6,400 articles, newest 25 October 18:05 UTC,
  source schema v25, migrated to v27 in the scratch copy before the run, SHA-256 `d8a8095e…cbf4`), never written in place.
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

First run (commit 1836f73): all 24 groups were reviewed (the copy has 24, not the 100 the acceptance names): 8 joined
by event-to-event links (two of them also carry an attached report), 16 that exist only because a report attached
alone. Labels by Claude: 24 right, 0 wrong (0 of 8 and 0 of 16); every one of the 18 attachments right. The
orchestrator, to whom Mars delegated the spot-check, then reviewed all 24 groups independently of these labels: 0
wrong. Three were borderline and accepted: the 9to5Mac iOS 27.2 bundle, a Yemeni leader's statement on the Houthis
beside the Houthi strikes on Saudi Arabia, and a Le Pen poll beside her campaign kick-off. Sheet:
`~/news-eval/m581-singletons-2026-10-27/story-group-review.csv` (`0600`, SHA-256 `fc0e3bad…dc4e1`).

## Review round: story opening, common actors, ties (A–C)

- The card opens the story's newest event of two or more reports (by first report), and that event's "Earlier in
  This Story" lists the story's earlier events; `story_id` stays the earliest event.
- `commonStoryTerms` checks every name two units share instead of the first 64 alphabetically; this also affects the
  "Earlier in This Story" relation, and can only remove links.
- Story naming and attachment ties go by first report (date, then article ID), never by the random event ID.

Result, same setup: holdout pair results unchanged at every cutoff (15/1/3, 14/1/3, 15/1/2, 16/1/2); printed share
449 of 1,211 (37%), cards 867, 12 stories joining two or more events; clock window 759 of 1,954 reports (39%) in a
multi-publisher card, 1,382 cards, 18 story groups (7 by event links, 11 by attachment alone), 13 attached reports.
The common-actor check removed six groups (among them the Witkoff and Putin talks link and five attachments); every
remaining group is one of the 24 reviewed right, so 0 wrong. Two runs gave identical numbers and identical groups.
Named cases unchanged. Sheet: `story-group-review-abc.csv` (SHA-256 `630d4af8…`).

## Measured and not adopted: the 72 h story window (F)

Sampling each side's five members nearest in time to the other (instead of the five earliest) and reading story pairs
up to 72 h apart (every other conflict still vetoing; admission and fragment merges unchanged) left the holdout pairs
unchanged and was deterministic over two runs, but 2 of 25 groups were wrong (8%, above the 2% gate): a report on
Canada's prime minister defending trade with countries that do not share its values attached to the US embassy's
accusation of election meddling, and three 9to5Mac daily deals round-ups of different days joined as one story. Clock
window with it: 770 of 1,954 (39%), 1,367 cards, 25 groups (12 by event links), 21 attached reports; printed share
451 (37%), 15 stories. Named cases unchanged. Sheet: `story-group-review-f.csv` (SHA-256 `f4baa6c9…`). Kept out of
this slice by decision (it adds 7 groups, 2 of them wrong, and moves no named case); its diffs are kept in the
implementer's scratch directory, not in the repository. The deals round-ups also show a gap in the #688 series guard:
two of them merged at event level, because their headlines ("Deals: …") carry no date, so no calendar-day conflict can
fire between days, and the edition guard needs edition words.

## Matcher findings from the review

- Event 7023B132 (Storm Austen) contains the Guardian's report on Storm Boelo, a different named storm: an
  event-level false merge.
- The Hindu's "Obama blasts Trump's 'chaos and cruelty'…" has the same headline as the Arab News member and matches it
  (score 0.73), but it cannot join the event: its pair with the BBC member is vetoed by the semantic veto (cosine
  0.548 against 0.55; its feed description starts mid-sentence), and admission needs every member pair free of
  conflict. The story pass then attached it.

## Notifications (traced, no change)

Notifications are decided per event and only for reports inserted by the refresh that notifies. Attaching a report
already in the library creates its one-member event but no new report, so nothing notifies. A new report attached in
the same pass is its own one-member event with no ledger entry, exactly as it was when unclustered (its key was its
own id), so it notifies as before; nothing dedupes it against the story's other events, either before or after this
slice. A story's version rises with an attachment; that only marks the card as updated.

## Where an attached report shows

- Card: one more report on the story card (newest first), counted in its stories and publishers; its event's version
  adds to the story's, so a new attachment marks the card as updated until the reader opens it.
- Overview: the card opens the story's newest event of two or more reports; an attached report never opens a story and
  is not cited in that overview.
- "Earlier in This Story": the open event lists the story's events that began before it (`relatedActEvents`), next to
  the lexical and related-act links; `ArticleStore.relatedStoryEvents` still caps the list at three links, lexical
  first, so a long story's earlier events can be cut (for #671).

## Limits found

- The story rule compares a report with an event's five earliest members, so a report more than 36 h after the event
  began conflicts on time with all of them and never attaches (F above measured the fix).
- Fixed in the review round: the 64-term common-actor cap and the random-ID ties.

## Receipts

`~/news-eval/m581-singleton-stories-2026-10-27/` (`0700`): `before-final/` and `after-final/` hold the holdout logs,
`story-groups.csv` and `story-cards.csv` (SHA-256 `269c0999…da02` before, `2b7d3376…b1ea` after); earlier runs of this
slice (`after/`, `after-w/`) are kept as they were; `abc-run1/`, `abc-run2/` (review round) and `f-run1/`, `f-run2/`
(the 72 h window) hold the later runs.
