# Three-way pair model (M17) — 27 October 2026

Refs #627 (M17), #574 (epic M), #624, #625. Run on Mars's Mac in the training venv (`script/training/requirements.txt`: Python 3.13, torch 2.14.1, transformers 5.20.2, coremltools 9.0). Receipts under `~/news-eval/m17-2026-10-27/` (`0700`, CSVs `0600`); nothing of them enters the repository. Labelled data, the library copy and the holdout stay private; this file carries counts only.

## Setup

- Library copy: `~/news-eval/library-2026-10-27.sqlite3`, a read-only backup of the live library (6,400 articles, newest 25 October 18:05 UTC, schema v25, matcher v11 events), SHA-256 `d8a8095e…cbf4`; every run reads a scratch copy.
- Library holdout (#579): `library-holdout-2026-10-24.json`, SHA-256 `bbb4ded1…10b9`, 219 pairs (44 same / 25 related / 150 different), all of whose 311 articles resolve in the copy. The copy is a day newer than the one the holdout was drawn from, and the re-clustering reads only stories dated within 72 h of `now`, so with `now` at the copy's newest story 159 holdout articles were never re-clustered (only 89 pairs inside the window). Every holdout run therefore pins the clock to when the holdout was drawn: `NEWS_HOLDOUT_NOW=1792854000` (24 October 15:00 UTC). Then no holdout article lies before `now − 72 h`; 417 articles are dated after the anchor and are still clustered, 5 of them holdout articles (in 3 `same` and 2 `different` pairs).
- No text prefix (#626): `NEWS_PAIR_PREFIX=0`, the default since 46e46ab.
- Dual gate (#627, approved by Mars on #574), relative to the branch below (v12; v13 = v12 at 0.9 on this setup): strict event `same` ≥ 15 and `different` ≤ 2; story level `different` < 3 and same-or-related pairs in one story > 20; tune 44 / 0 / 49; authored corpus unchanged.

## Baseline: v12 under the dual gate

`--library-holdout`, shipped `pairscorer.mlmodelc` (binary, v11 weights). Strict: `same` / `related` / `different` pairs in one event (precision `same`/linked, recall of 44). Story level: `same` + `related` pairs whose events share a story / `different` pairs whose events share a story (recall of 69). Receipt `baseline-v12.log`.

| Cutoff | Strict | Precision | Recall | Story level | Precision | Recall | Corpus | Tune |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.80 | 15 / 1 / 3 | 0.789 | 0.341 | 20 (18 + 2) / 4 | 0.833 | 0.290 | 22 / 0 | 44 / 0 / 49 |
| 0.85 | 14 / 1 / 3 | 0.778 | 0.318 | 19 (17 + 2) / 4 | 0.826 | 0.275 | 22 / 0 | 44 / 0 / 49 |
| 0.90 | 15 / 1 / 2 | 0.833 | 0.341 | 20 (18 + 2) / 3 | 0.870 | 0.290 | 22 / 0 | 44 / 0 / 49 |
| 0.95 | 16 / 1 / 2 | 0.842 | 0.364 | 21 (19 + 2) / 3 | 0.875 | 0.304 | 22 / 0 | 43 / 0 / 50 |

With the old prefix switched on (`NEWS_PAIR_PREFIX=1`, the default before 46e46ab, which fed the unprefixed v11 weights gap-and-publisher words), strict / story level: 0.80 15 / 3 / 7, 19 / 9; 0.85 16 / 3 / 7, 20 / 9; 0.90 17 / 3 / 7, 21 / 8; 0.95 14 / 2 / 7, 18 / 8 — four to five more wrong links at every cutoff.

The brief's 14 / 4 / 3 was measured on a copy that no longer exists; these numbers replace it.

## Training data

Labels follow the three-way contract in `script/training/train_pair_model.py`: `label` 0 different, 1 related, 2 same; `marginal` names the classes of a partial label, whose summed probability is the target. The rule for partial labels (approved on #627): pairs known only to be one story are `12`; pairs known only not to be one occurrence (GDELT hard negatives, far-apart library negatives, "Not the Same Event" verdicts) are `01`; reviewed `different` labels and clean same-day negatives stay exact `different`.

| Input | Rows | Labels | Weight | SHA-256 |
| --- | --- | --- | --- | --- |
| Library export (`--export-pairs` from a copy re-clustered at matcher v12: 137 clock steps, 933 events in 920 stories) | 8,691 | 2,174 same (cross-publisher rule matches inside one event); 4,343 far-apart negatives `01` (shared anchor, 36 h–7 d); 2,174 of 6,749 clean same-day negatives exact different (different stories, and a hard conflict or cosine < 0.58; capped at the positives) | 1; same-day 2 | `789b54d3…cc74` |
| Reviewed #551 labels (`sample_pairs.py --labels --holdout`) | 212 of 356 | 142 same, 27 related, 43 different, exact | 5 | `adc8d262…9050` |
| WCEP-10 train, revision `e231ece6b913` (stage 1, capped at 40,000 by CRC-32 order) | 325,545 | 108,515 within-cluster pairs `12` (the dataset has no publication times, so none is known to be within 18 h); 217,030 cross-cluster name-sharing pairs exact different | 1 | `8d26ead1…c5fc` |
| GDELT 2.1, 24 September – 23 October 2026 (stage 1) | 15,497 | `01`; the trainer reads the 12,132 whose shipped-MiniLM cosine is below 0.55 as exact different | 1 | `e7073346…c958` |

The export left out 317 articles for the library holdout (its 311 ids and 6 copies of their headlines) and 381 corpus or corpus-window articles; the copy has no reader verdicts. Stage 2 is the export plus the reviewed rows (`stage2-reclustered.csv`, 8,903 rows, `976ef788…2d48`).

Two changes to the export on this branch: it now re-clusters a copy from scratch at the current matcher before mining, in arrival order (`reclusteredLibraryCopy`), because the copy's stored v11 events had no stories and the same-day negatives' different-story condition could never apply; and positives leave out pairs the pair model alone linked. On this copy that filter removes nothing: the current rules never match a pair the v11 model confirmed (769 such decisions are stored, 339 inside one event), so those pairs were already not positives.

## Leakage

No training row may carry a library-holdout or a tune-corpus article. Checked three ways: the export leaves out holdout ids and their headline copies and the whole corpus window; `sample_pairs.py --labels --holdout` drops reviewed rows naming a holdout id; and `train_pair_model.py --exclude-headlines` drops every row of every input whose headline (folded: accents stripped, case folded, words of letters and digits) is one of the 308 holdout or 143 tune-corpus headlines (`excluded-headlines.txt`, 451 lines, `2d0c9e5e…7f40`; the tune list reads the corpus file's `tune` split only). The headline check found 0 rows in the export, 2 in the reviewed rows (a holdout headline under another article id) and 62 in GDELT (14 holdout, 48 tune: GDELT crawled the same pages); all are left out at training. The trainer records the count per input in `metadata.json`. The embedder track's independent check (27 October) agrees: the two reviewed rows are `r:match:118` and `r:match:119`, whose second text carries a holdout or tune headline, and both are dropped by `--exclude-headlines`; its folding finds 1 of the 143 tune titles and 3 of the 308 holdout titles missing from `excluded-headlines.txt`, and no training row carries any of those four.

**Earlier runs (27 October 2026).** 144 of the 356 #551 reviewed rows name a library-holdout article: 70 of 200 rule matches, 48 of 100 pair-model confirmations, 26 of 56 related-act rows. Runs B–E of the 24 October pretraining audit trained on all 356 at weight 5, so their holdout numbers were optimistic. Those rows are now left out (212 remain).

## Candidates

Training config (Mars, 25 October, for every primary candidate): three-way head, cross-entropy against the classes a row allows, label smoothing 0.05, no class weight on top of row weights, stage 2 three epochs at 1.5e-5 with `bert.embeddings` and `encoder.layer[:2]` frozen, no prefix, `--exclude-headlines`. Stage 1 (run-b2): WCEP 40,000 + GDELT 15,435 rows, two epochs at 3e-5, all layers.

Admission rules (#627): `same` admits a borderline pair when p_same ≥ c; `story` admits when p_same + p_related ≥ c, p_same > p_related and p_different ≤ 0.10. A three-way softmax with label smoothing does not put p_same on the binary model's scale, so the rule and cutoff are chosen on the tune replay (the highest cutoff that keeps the best tune recall with no false pair) and checked on the held-out split of the training rows (exact `same` rows against rows that exclude `same`); the library holdout is then read once.

| Run | Held-out AUC same / one story | Held-out sweep (TP / FP of 25 same) | Tune, rule `same` 0.5 / 0.6 / 0.7 / 0.8 / 0.85 / 0.9 | Tune, rule `story` 0.8 / 0.85 / 0.9 / 0.93 / 0.95 | Corpus | Chosen | Holdout read |
| --- | --- | --- | --- | --- | --- | --- | --- |
| b1: stage 2 only | 0.960 / 0.932 | `same` 0.7 21 / 5, 0.8 11 / 2; `story` 0.93 6 / 1 | 42/3, 42/3, 42/3, 39/3, 40/0, 40/0 | 39/3, 39/3, 39/3, 41/0, 40/0 | 22 / 0 at every setting | none: no setting keeps 44 / 0 | none (but see the log below) |
| b2: stage 1 + stage 2 | 0.983 / 0.974 | `same` 0.85 16 / 1, 0.9 6 / 0; `story` 0.93 11 / 0 | 42/3, 42/3, 42/0, 42/0, 44/0, 42/0 | 42/0, 42/0, 42/0, 44/0, 42/0 | 22 / 0 at every setting | `story` 0.93 (44 / 0 on tune, 0 false on held-out; `same` 0.85 also keeps 44 / 0 but admits one false held-out pair) | strict 12 / 0 / 3, story 13 / 4 — fails |

run-b2 at `story` 0.93 on the library holdout: strict 15 linked = 12 same, 0 related, 3 different (precision 0.800, recall 0.273); story level 17 = 13 same or related, 4 different (precision 0.765, recall 0.188); 30% of recent stories in a multi-publisher event against v12's 36–37%. The gate needs strict same ≥ 15 and different ≤ 2, story different < 3 and more than 20 story links. The three wrong links are two acts of a running war or outbreak a day apart (Sudan, Ebola in Nigeria and Kenya, Houthi strikes); the extra story-level one is the Eagle's Nest fire and the arrest.

### Holdout reads

Every read of the library holdout by this program on 27 October, in order (`NEWS_HOLDOUT_NOW=1792854000`, prefix off unless named):

1. v12 shipped model, rule `same`, 0.80 / 0.85 / 0.90 / 0.95 (baseline; and with `NEWS_PAIR_PREFIX=1` at the same four).
2. run-s2 (stage 2 on the pre-re-clustering export; smoke test, not a candidate), 0.5 and 0.7.
3. run-b1, rule `same`, 0.5 / 0.6 / 0.7 / 0.8 / 0.9, before the one-read rule: strict 17/2/5, 15/2/5, 13/1/5, 14/0/3, 8/1/2; story 20/6, 18/6, 14/6, 15/4, 13/3.
4. run-b2, rule `story`, 0.93 (the one read).
5. a1, a2 and a3, rule `story`, 0.93, one read each, on the v13 runner.
6. Shipped model with the knob off, and the story signal at s = 0.80 and 0.90 (shipped binary model), pair cutoff 0.9, on the #696 tip. No further reads: Mars stopped holdout reads until a fresh set exists.

Three earlier reads on the copy's own clock (before the anchor) and on the 24 October snapshot were discarded as measurement errors.

**Code change after these reads.** Slice A merged #694 (`mars/m-683-importance-judges`, with #688 and the #581 singleton-attachment follow-up) on 27 October: matcher v13, the newest event opens a story, and the common-actor fix in the story pass. Every story-level number above comes from the v12 story layer; story-level numbers measured after f44af4c come from the new code, and the v12/v13 baseline is re-measured before any of them is compared.

## After #694: v13 baseline and the ablations

Runner built at ce0d5b0 (slice B with PR #695's slice A, which carries #694: matcher v13 and the new story layer). Same setup. Receipt `baseline-v13.log`.

| Cutoff | Strict | Story level | Corpus | Tune |
| --- | --- | --- | --- | --- |
| 0.80 | 15 / 1 / 3 | 20 (18 + 2) / 4 | 23 / 0 | 44 / 0 / 49 |
| 0.85 | 14 / 1 / 3 | 18 (17 + 1) / 5 | 23 / 0 | 44 / 0 / 49 |
| 0.90 | 15 / 1 / 2 | 19 (18 + 1) / 4 | 23 / 0 | 44 / 0 / 49 |
| 0.95 | 16 / 1 / 2 | 20 (19 + 1) / 4 | 23 / 0 | 43 / 0 / 50 |

The new story layer joins one more `different` pair at story level than v12 did. The gate stays relative to v13 at 0.9.

Ablations (deviations from Mars's config, approved as ablations; each is stage 2 from run-b2's stage-1 state, otherwise as b2). The tune sweeps for a1 and a2 ran on the v12 runner and were re-checked at the chosen setting on the v13 runner; a3 was swept on the v13 runner.

| Run | Change | Held-out same AUC | Held-out at the chosen setting | Tune keeping 44 / 0 | Corpus | Chosen | Holdout read (v13 runner) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| a1 | label smoothing 0.02 | 0.986 | 12 / 0 | `story` 0.93 only | 22 / 0 (v12), 23 / 0 (v13) | `story` 0.93 | strict 12 / 0 / 3; story 15 / 5 — fails |
| a2 | stage 2 with no frozen layer | 0.991 | 18 / 0 | `same` 0.9, `story` 0.93, `story` 0.95 (corpus 23 / 2 there) | 22 / 0 except `story` 0.95 | `story` 0.93 | strict 12 / 1 / 2; story 16 / 4 — fails |
| a3 | stage 2 with one frozen layer | 0.991 | 16 / 0 | `story` 0.93 only | 23 / 0 | `story` 0.93 | strict 12 / 0 / 3; story 15 / 5 — fails |

How each model scores the three run-b2 wrong pairs (p_different / p_related / p_same, both orders averaged):

| Pair | b1 | b2 | a1 | a2 | a3 |
| --- | --- | --- | --- | --- | --- |
| Sudan: two France 24 reports of the war | 0.93 / 0.04 / 0.04 | 0.89 / 0.04 / 0.07 | 0.92 / 0.02 / 0.06 | 0.82 / 0.04 / 0.14 | 0.88 / 0.04 / 0.08 |
| Ebola in Nigeria / Ebola death in Kenya | 0.19 / 0.07 / 0.73 | 0.27 / 0.06 / 0.68 | 0.26 / 0.05 / 0.69 | 0.30 / 0.06 / 0.64 | 0.20 / 0.06 / 0.73 |
| Yemen strikes on the Houthis / Saudi drone interceptions | 0.67 / 0.04 / 0.29 | 0.86 / 0.04 / 0.10 | 0.89 / 0.03 / 0.08 | 0.87 / 0.05 / 0.09 | 0.87 / 0.05 / 0.09 |

No variant moves them to `related`. Two of the three score clearly `different`, and the Ebola pair stays below every admission cutoff. All three wrong links therefore come in through other members of the event: the model confirms a pair of other reports, and the two-thirds rule carries these pairs in. That is a property of admission, not of these pair scores.

The holdout reads of this section: a1, a2 and a3, each once, rule `story` 0.93, on the v13 runner.

## Decision

No candidate passes the dual gate. The best strict result is 12 `same` (gate ≥ 15). Every candidate loses three or more `same` links that v13 makes, and none removes a wrong link without losing others. Following Mars's rule for a failed retrain: the shipped `pairscorer.mlmodelc` (binary, v11 weights) and `EventMatcher.version` stay; the three-way code path ships, so `PairScorer` reads either kind of model and admission still gates on p_same. Recommended next lever, outside M17: admission. The wrong links of every candidate come in through other members of an event (the two-thirds rule carries a report in once one pair of other reports is confirmed), not through their own pair scores, so later matcher work should look at third-member carry-in. The story-level signal (p_same + p_related) is wired behind `EventMatchPolicy.storyModelThreshold`, off by default (see "Story signal"). The training data teaches multi-day acts of one running story as `12`, and the lever the runs point at is admission (third-member carry-in), not the pair head.

## Story signal (timeboxed experiment)

`EventMatchPolicy.storyModelThreshold` (off by default, `NEWS_STORY_MODEL=s` to evaluate) gives the story pass a second link signal: two events, or a report alone and an event, are one story when two thirds of their cross pairs (earliest five members) score p_same + p_related ≥ s with p_different ≤ 0.15, have no conflict other than a different act, share one specific name that is not a common actor, and share a keyword or reach cosine 0.55. Event admission is untouched: with the knob off, the 3-way code path with shipped weights gives v13's decisions exactly (runner at the #696 tip: holdout 0.9 strict 15 / 1 / 2, story 19 / 4; corpus 23 / 0; tune 44 / 0 / 49, 43 / 0 / 50 at 0.95), so no matcher version bump. Receipts `story-signal/`.

Two story models were tried. The shipped binary model (related 0, so the signal is p_same) was measured on the gate setup as asked, with two holdout reads (s = 0.80 and 0.90, both at pair cutoff 0.9) before Mars stopped holdout reads until a fresh set exists. run-a2 as a separate story model (`NEWS_STORY_MODEL_PATH`; it would ship as `storyscorer.mlmodelc`) was measured without reading the holdout: the library copy re-clustered with the pinned clock and scored against an empty pair file, for its story groups only, plus tune and the authored corpus scored by event and by story (`NEWS_SCORE_STORIES=1`: two events of one story count as one). Added story groups (groups whose events are not all in one baseline group; baseline 12 groups) were labelled by Claude for the coordinator's spot-check (`*-added.csv`, columns as `story-groups.csv` plus `label` and `note`).

| Story model | s | Groups | Added | Wrong added | Named cases | Holdout (strict; story) | Corpus by story | Tune by story |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none (off) | — | 12 | — | — | Eagle's Nest 3 events; Kenya Ebola apart | 15/1/2; 19/4 | 25 / 0 | 44 / 0 |
| shipped binary | 0.80 | 18 | 9 | 2 (22%) | Kenya Ebola joined (2 events) | 15/1/2; 19/5 | — | — |
| shipped binary | 0.90 | 18 | 8 | 1 (12%) | Kenya Ebola joined | 15/1/2; 19/5 | — | — |
| run-a2 | 0.80 / 0.85 | 20 | 11 | 1 (9%) | Kenya Ebola joined | not read | 25 / 4 | 44 / 0 |
| run-a2 | 0.90 | 19 | 9 | 1 (11%) | Kenya Ebola joined | not read | 25 / 4 | 44 / 0 |
| run-a2 | 0.95 | 18 | 6 | 1 (17%) | Kenya Ebola joined | not read | 25 / 4 | 44 / 0 |

The wrong added groups: an iPhone Duo explainer joined to an executive interview about launch availability (every setting; the holdout labels such pairs different), and, for the binary model at 0.80, a call for Witkoff to resign joined to Ukraine's Starlink access. Jordan church, France 70,000 police and Pope Leo form no multi-event group on this copy with any setting; the Ebola case consolidates only the two Kenya reports. Event-level tune and corpus are unchanged by construction (the story pass never moves members). Story-level corpus: the knob off joins the corpus's two missed pairs through stories without a false pair; run-a2 adds four false story pairs at every s.

Result: no setting meets ≤ 2 % wrong added groups (the best is 9 %), and run-a2 adds four false story pairs on the authored corpus, so the knob stays off and no story model ships. The code path stays, off, for the fresh labelled set Mars is arranging (29 October).
