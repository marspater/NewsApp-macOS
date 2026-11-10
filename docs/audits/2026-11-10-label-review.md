# Independent review of the Stage 1 and validation labels (#737, 10 November 2026)

Follows [the veto share audit](2026-11-10-veto-share-out-of-sample.md). Mars, 10 November: the single-pass labels get an independent review with a hard line between one occurrence and a later development, before anything else. **No matcher, model or default changes; no new candidate is proposed.** Receipts are private under `~/news-eval/label-review-2026-11-10/` and `~/news-eval/clustering-737-2026-11-09/`; this file carries counts only. The 6 November blind set stays sealed.

## Rubric

Frozen and posted on #737 before any labelling, derived from Mars's rulings of 4 October, 6 November and 10 November, with no example from either set.

| Label | Meaning |
| --- | --- |
| `same` | One act (actors, deed, place, time) is the news of both reports. |
| `pegged-reaction` | One report's news is the act; the other's is words about that very act and no new deed. |
| `pegged-analysis` | One report's news is the act; the other explains or surrounds that very act and reports no new deed. |
| `pegged-part` | One report covers the act as a whole; the other one part or scene of it at the same time. |
| `later` | Different acts, one the antecedent, consequence or continuation of the other in one story. |
| `topic`, `unrelated` | Only broad context in common; nothing in common. |

Rulings: a response that is a deed is `later`; one statement reported twice is `same`; two different responses to one trigger are `later`; a higher toll of the same act stays `same` and a new decision point is `later`; a preview against the event is `later`; separate acts of one kind in a long-running conflict are `topic` unless one is the consequence of the other.

The `pegged` labels exist because Mars's rulings pull apart there: on 4 October a words-only reaction "joins its event", on 6 November `same` needs the same act, place, time and actors. Every number below is given both ways.

## Protocol

1. Second pass: one fresh reader per set labelled all 400 Stage 1 and all 300 validation rows from source, time, title and lead in a shuffled order, without the first-pass label, note, stratum, ids or any matcher output.
2. Third pass: a third fresh reader labelled the 119 pairs where first and second pass differ on same | pegged | later | different, which includes every `pegged` pair. `topic` against `unrelated` was not counted as a difference.
3. Two of three decide. The reviewed labels were frozen (Stage 1 SHA-256 `a0f5869d…`, validation `0a5d4e59…`) before they were joined to matcher output. The first-pass files are unchanged.

All three readers are the same model family as the first pass: the review is blind, not a different judge. Mars has reviewed none of it.

## Agreement

First pass against the blind second pass:

| Set | Pairs scored | Agree, pegged as `same` | Agree, pegged as `later` | same↔later flips | `pegged` |
| --- | --- | --- | --- | --- | --- |
| Stage 1 | 394 | 345 (kappa 0.80) | 357 (kappa 0.85) | 4 | 24 |
| Validation | 300 | 249 (kappa 0.74) | 267 (kappa 0.83) | 16 | 32 |

No pair moved between `same` and `topic` or `unrelated`. By Stage 1 stratum the two passes differ on 2 of 60 (1-close), 1 of 30 (1-later), 8 of 90 (2-close), 4 of 40 (2-later), 11 of 120 (3-close) and 11 of 60 (3-later), not counting `pegged`.

The third reader sided with the second pass on 100 of the 119 pairs and with the first pass on 14; 5 are three-way splits.

## Reviewed labels

| Set | same | pegged (reaction / analysis / part) | later | topic | unrelated | unsure | split |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Stage 1 (400) | 105 | 19 (5 / 10 / 4) | 70 | 100 | 101 | 2 | 3 |
| Validation (300) | 57 | 31 (13 / 17 / 1) | 69 | 77 | 64 | 0 | 2 |

What changed against the first pass:

| Set | Changed | later → same | same → later | same → pegged | later → pegged | later → topic or unrelated |
| --- | --- | --- | --- | --- | --- | --- |
| Stage 1 | 51 of 400 | 1 | 0 | 6 | 13 | 22 |
| Validation | 54 of 300 | 13 | 2 | 7 | 24 | 6 |

The first pass had no `pegged` class and filed three quarters of those pairs under `later` (37 of 50). On validation it also called 13 same-act pairs `later`.

## Where the rubric is still open

The readers marked 221 of 819 readings as close and named the same gaps independently:

- Two pieces that hang on one act when neither is the act report (a reaction against an explainer, two tributes). They were labelled `later` under the shared-trigger ruling, although neither is a later act.
- An announcement of an imminent act against the report of the act done.
- Whether voting, exit polls and partial counts of one election day are one act or steps.
- Day-two reports of a disaster: more detail on the act, or a new deed.
- Short waves (a week of protests, successive days of threats or of one trial): repeated acts or one continuing story.
- An explainer whose lead also reports the act: `same` or `pegged-analysis`.

## The baseline under the reviewed labels

Same replays as before; only the labels change. Strict same / related / different with the number of `same` pairs, then story same+related / different.

| Set | First-pass labels | Reviewed, pegged inside the event | Reviewed, pegged outside |
| --- | --- | --- | --- |
| Validation | 18 / 6 / 0 of 51; 47 / 0 | 21 / 3 / 0 of 81; 47 / 0 | 19 / 5 / 0 of 55; 47 / 0 |
| Stage 1 late | 17 / 3 / 0 of 29; 26 / 0 | 17 / 3 / 0 of 33; 26 / 0 | 16 / 4 / 0 of 27; 26 / 0 |
| Stage 1 early | 50 / 11 / 3 of 71; 63 / 3 | 53 / 7 / 4 of 77; 62 / 4 | 51 / 9 / 4 of 69; 62 / 4 |

## What an event is to the matcher today

The 553 replayed pairs of the three sets, by reviewed label, and how many the baseline puts in one event:

| Reviewed label | In one event | Share |
| --- | --- | --- |
| `same` | 86 of 151 | 57 % |
| `pegged` | 5 of 40 | 12 % |
| `later` | 13 of 104 | 12 % |
| `topic` | 4 of 128 | 3 % |
| `unrelated` | 0 of 125 | 0 % |

- Of the 108 linked labelled pairs, 86 are the same act, 5 are pegged, 13 are later developments and 4 share only a topic. Under the first-pass labels the same links read 85 same, 20 related, 3 different.
- The matcher joins a pegged report as rarely as a later development. In practice its event is the act alone.
- Of the 13 later developments inside an event, the pair model admitted 8 and a rule match 5.

## Earlier results under the reviewed labels

- **Evidence head.** Its 44 positives on validation at the frozen cutoff were 33 `same` and 11 `later` under the first-pass labels (0.75 against the pre-registered 0.90). Reviewed, they are 33 `same`, 8 `pegged` and 3 `later`: 0.93 with pegged inside the event, 0.75 with pegged outside. Its validation replay reads 21 / 3 / 0 → 25 / 3 / 0 with pegged inside and 19 / 5 / 0 → 22 / 6 / 0 with pegged outside. This is a re-reading after the fact, not a new test; the head stays off.
- **Setting g.** Validation 21 / 3 / 0 → 22 / 2 / 0 with pegged inside, 19 / 5 / 0 → 19 / 5 / 0 with pegged outside; story 47 → 43 either way. Still a gain of a handful and a story recall loss.

## Open for Mars

1. Whether a pegged report (a words-only reaction, an explainer, a part of the act) belongs inside the event. It decides 50 of 700 labels, the size of the recall denominator (81 against 55 `same` pairs on validation), and whether the evidence head's own check fired.
2. The five three-way splits (`splits-for-mars.txt` in the review folder).
3. The six rubric gaps above.
