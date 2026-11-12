# Veto share out of sample (#737, 10 November 2026)

Follows [the recall levers audit](2026-11-05-recall-levers.md) and [the evidence head audit](2026-11-09-evidence-head.md). **Setting g fails out of sample; no default changes and no matcher code is proposed.** This change amends one clause of the matcher gate in CONTRIBUTING.md (decided 10 November) and records the measurement.

Build a8da29b (matcher code equal to `main` at 64ae7a4), matcher v15. Receipts are private under `~/news-eval/clustering-737-2026-11-09/`; this file carries counts only. Stage 1 and validation labels are single-pass agent labels, which I have not reviewed.

## Setting

g of the 5 November audit, frozen as chosen there on the 3 November set: `NEWS_VETO_SHARE=0.34 NEWS_PAIR_THRESHOLD=0.85 NEWS_BORDERLINE_FLOOR=0.5`, no evidence head. The expected effect and the falsifiers were posted on #737 before the runs. The sets are those of the evidence head audit; g was never chosen on Stage 1 or on the validation draw (SHA-256 `89d092c6…`, second read of that set). The blind 6 November set stays sealed.

## Rows

| Set | Run | Strict same / related / different | Story same+related / different | Multi-publisher event |
| --- | --- | --- | --- | --- |
| Validation, 29 October library (51 same) | baseline | 18 / 6 / 0 | 47 / 0 | 1,201 of 3,165 |
| | g | 19 / 5 / 0 | 43 / 0 | 1,230 |
| Stage 1 late (29 same) | baseline | 17 / 3 / 0 | 26 / 0 | 259 of 924 |
| | g | 17 / 3 / 0 | 26 / 0 | 263 |
| Stage 1 early (71 same) | baseline | 50 / 11 / 3 | 63 / 3 | 421 of 1,397 |
| | g | 53 / 11 / 3 | 67 / 3 | 428 |
| 3 November set (38 same), where g was chosen | baseline | 4 / 5 / 3 | 12 / 3 | 433 of 1,436 |
| | g | 13 / 6 / 3 | 21 / 3 | 443 |

The tune replay (44 / 0 / 49 in English), the matcher regressions (TP 24, FP 0, FN 2) and the story regressions are unchanged under g. The validation pass takes 146.6 s under g against 59.8 s.

## Falsifiers

| Falsifier | Result |
| --- | --- |
| A new strict or story `different` on validation or Stage 1 | none: holds |
| Fewer than 90 % of the newly linked labelled pairs are `same` | 4 of 5 (one `related` link on validation): fires, by one pair |
| Tune or a regression moves | none: holds |

## Gate

On validation, strict `same` does not fall and strict `different` does not rise, but story recall falls from 47 to 43 of 148: five `related` pairs leave their story and one `same` pair joins. g fails the gate there under the old and the amended wording. The cause of the lost story links was not traced.

The amended clause: story-level `different` "does not rise" instead of "falls". The validation set has no story `different` at baseline, so "falls" could not be met there by any candidate, and on the 3 November set it asked a recall change to repair one unrelated card of shopping round-ups.

## Reading

- Out of the set it was chosen on, g adds 4 `same` links among 151 `same` pairs. The jump from 4 to 13 on the 3 November set does not transfer. Veto thresholds are not pursued further.
- The Stage 1 refusals explain why: a single member vetoes in 3 of the 13 matched-but-refused pairs; in the others 20 % to 60 % of the members do, and most also fail the two-thirds rule, which a veto share does not touch.
- Those refused pairs are mostly two fragments of one occurrence, each already an event of three or more reports. Joining them removes a duplicate card; it does not raise the multi-publisher share.
- Later developments sit inside events on every set at baseline: 6 of 24 linked labelled pairs on validation, 14 of 84 on Stage 1, 5 of 12 on the 3 November set are `related`. Telling one occurrence from its later development is the next lever, and the place to look for why large events refuse a true report.

**Revised on 10 November 2026.** The [label review](2026-11-10-label-review.md) re-read these pairs. Pairs labelled `later` are 3 of 24 linked pairs on validation and 10 of 84 on Stage 1, not 6 and 14; the rest are pegged, the same act or topic only, and the 3 November set was not re-read. By the readers' notes at least 2 of those 13 are two sets of words after one act, not a later act. The larger gap is on the other side: 65 of 151 same-act pairs are not in one event. The last bullet's "next lever" does not stand as written.
