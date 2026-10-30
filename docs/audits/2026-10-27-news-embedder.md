# News-tuned sentence encoder (M18) — 27 October 2026

Refs #628, #574 (epic M). The first candidate fails the gate. `minilm.mlmodelc` and `SentenceEmbedder.modelVersion` 2 stay. `script/training/train_embedding.py` and this record are committed, as Mars decided for a failed candidate. Receipts are in `~/news-eval/m18-2026-10-27/` (`0700`). The private English holdout was not read.

## Training

- `train_embedding.py` starts from `sentence-transformers/all-MiniLM-L6-v2` at the revision `convert_minilm.py` pins; these are the weights the app ships.
- It trains the mean-pooled, normalized vector `SentenceEmbedder.embed` returns:
  - an in-batch contrastive loss over the positives, both directions, scale 20 (texts of one event are never each other's negatives);
  - plus CoSENT, which ranks every positive's cosine above every hard negative's;
  - each row scaled by its weight.
- One epoch, rate 2e-5 with a tenth warm-up, 32 positive and 32 hard-negative pairs a step. Training ran on the GPU (MPS) in minutes.
- The model is exported through `convert_minilm.convert`: four fixed-length functions (#554).

| Input | SHA-256 | Positives | Hard negatives | Left out | Excluded headline |
| --- | --- | --- | --- | --- | --- |
| `m17-2026-10-27/stage2-reclustered.csv` | `976ef788…2d48` | 2,314 | 2,217 | 4,370 | 2 |
| `pretrain-2026-10-24/gdelt-negatives.csv` | `92c90512…6a91` | 0 | 15,435 | 0 | 62 |

The library export is the re-clustered copy of 27 October, with 212 #551 reviewed labels.

- **Positives:**
  - 2,174 cross-publisher rule matches inside one event; links the pair model alone made are already left out by the export.
  - 140 reviewed `same` rows at weight 5.
- **Hard negatives:**
  - 2,174 clean same-day cross-story negatives at weight 2;
  - 43 reviewed `different` rows at weight 5;
  - GDELT same-actor negatives, headline only.
- **Left out:**
  - 4,343 far-apart negatives: the 36 h window already separates them, and some are later acts of one story;
  - 27 reviewed `related` rows;
  - WCEP-10 in full: it has no dates, so the 18 h rule cannot be applied.
- **Split:** a tenth of the texts (CRC-32) is held out, and pairs that straddle the split are dropped. That leaves 1,839 positives and 14,244 negatives to fit, and 33 positives and 206 negatives held out.

## Leakage

`train_embedding.py` leaves out every row that names a folded headline from any of these:
- `excluded-headlines.txt` (SHA-256 `2d0c9e5e…7f40`, 450 lines);
- the library holdout file (`library-holdout-2026-10-24.json`, SHA-256 `bbb4ded1…10b9`);
- the tune split of the private corpus. Holdout-split entries are skipped.

The run fails if any such row remains. `excluded-headlines.txt` misses 1 of the 143 tune titles and 3 of the 308 holdout titles; the script adds both sets directly.

An independent check compared every selected text's headline against the tune titles, the holdout pairs' titles, the library copy's titles of the 311 holdout article ids, and the exclusion file:

| | Rows | Texts | Tune | Holdout titles | Holdout ids | Exclusion file |
| --- | --- | --- | --- | --- | --- | --- |
| Before exclusion | 20,030 | 40,060 | 48 | 16 | 16 | 64 |
| As trained | 19,966 | 39,932 | 0 | 0 | 0 | 0 |

The 64 rows removed are 62 GDELT rows and two reviewed `same` rows, `r:match:118` and `r:match:119`. The second text of each is a holdout or tune headline. This was passed to the model track.

## Held-out pairs (training-time sanity check, not the gate)

| | Cosine AUC | Positives ≥ 0.55 | Negatives ≥ 0.55 | Positives ≥ 0.70 | Negatives ≥ 0.70 | Median positive / negative |
| --- | --- | --- | --- | --- | --- | --- |
| shipped encoder | 0.938 | 1.00 | 0.243 | 0.879 | 0.087 | 0.777 / 0.401 |
| candidate | 0.962 | 1.00 | 0.257 | 0.970 | 0.107 | 0.852 / 0.437 |

The candidate ranks better, but it raises every cosine, negatives included. The veto and rescue cutoffs therefore have to move with it.

## Gate

Evaluation setup:
- One `-O` runner with `modelVersion` 3, so the library holdout recomputes every vector instead of reading the copy's 2,842 stored v2 vectors.
- Each encoder in an evaluation directory whose `Sources/Resources/Models` holds it. The baseline is the shipped encoder in the same harness.
- `NEWS_SEMANTIC_VETO` and `NEWS_SEMANTIC_RESCUE`, new in `StoryCorpus.policyFromEnvironment`, set the two cutoffs.

The setting was chosen on tune and the authored corpus only:

| Veto / rescue | Authored corpus | Tune en (TP / FP / FN) |
| --- | --- | --- |
| shipped encoder 0.55 / 0.70 | 23 / 0 | 44 / 0 / 49 |
| candidate 0.55 / 0.70 | 23 / 0 | 52 / 14 / 41 |
| 0.60 / 0.70 | 23 / 0 | 50 / 8 / 43 |
| 0.55 / 0.75 | 23 / 0 | 52 / 17 / 41 |
| 0.60 / 0.75 | 23 / 0 | 50 / 9 / 43 |
| 0.65 / 0.80 | 23 / 0 | 50 / 1 / 43 |
| 0.50 / 0.70 | 22 / 2 | 52 / 14 / 41 |
| 0.55 / 0.65 | 23 / 0 | 48 / 14 / 45 |
| 0.70 / 0.80 | 23 / 0 | 42 / 0 / 51 |
| 0.65 / 0.85 | 23 / 0 | 50 / 1 / 43 |
| 0.70 / 0.85 | 23 / 0 | 42 / 0 / 51 |
| 0.68 / 0.80 | 23 / 0 | 48 / 0 / 45 |
| 0.75 / 0.85 | 23 / 0 | 36 / 0 / 57 |
| 0.66 / 0.80 | 23 / 0 | 50 / 1 / 43 |
| 0.67 / 0.80 | 23 / 0 | 48 / 0 / 45 |
| 0.68 / 0.75 | 23 / 0 | 48 / 6 / 45 |
| **0.68 / 0.85 (chosen)** | 23 / 0 | **48 / 0 / 45** |

Chosen setting: veto 0.68 and rescue 0.85. This is the highest tune recall with no false pair. At 0.66 the first false pair appears; 0.85 sits clear of the false pairs at 0.75.

Library holdout: the only two reads, and the last ones on this set. Mars has since retired the 24 October holdout as read too often; later candidates are gated on a fresh, independently labelled set. The copy is `library-2026-10-27.sqlite3`, the holdout 219 pairs, `NEWS_HOLDOUT_NOW=1792854000`, pair cutoff 0.90, prefix off.

| Read | Strict event (same / related / different linked) | Strict recall | Story level (same or related / different) | Story recall |
| --- | --- | --- | --- | --- |
| shipped encoder, 0.55 / 0.70 | 15 / 1 / 2 | 0.341 | 19 / 5 | 0.275 |
| candidate, 0.68 / 0.85 | 12 / 0 / 3 | 0.273 | 17 / 4 | 0.246 |

The candidate fails:
- strict `same` falls from 15 to 12;
- strict `different` rises from 2 to 3;
- story recall falls.

Its one gain is a story-level wrong link fewer. The baseline here differs from the earlier v12/v13 numbers (20 linked in one story, 3 different) because this harness recomputes every vector rather than reading the copy's stored ones.

## Reading

- Decision (Mars, 27 October): the candidate fails on the gate in force when it was trained. It is not re-read on the fresh set, which would be gate-shopping. Version 2 stays. The trained state stays in the receipts (`run-1/embedding-state.pt`, SHA-256 `b39b304f…9d19c6`).

- The tuned encoder wins on tune and the corpus at its chosen setting (48 / 0 / 45 against 44 / 0 / 49 at 0.68 / 0.85), but loses on the holdout (strict 12 / 0 / 3 and story 17 / 4, against 15 / 1 / 2 and 19 / 5).
- It pulls rule-matched cross-publisher pairs together. It also pulls up the cosine of hard negatives, so the matcher's 0.55 veto lets through false rule matches: 14 on tune. A stricter veto removes them, and that costs same-event recall.
- Raising the veto to remove them costs the recall the encoder gained. On the holdout the net effect is fewer correct links and one more wrong one.
- The cutoffs and the cosine scale are coupled. A next candidate should keep the negatives' cosine where it was, for example with a margin loss on the hard negatives or a smaller learning rate. Or it should be judged with the matcher re-tuned on a larger reviewed tune set, rather than with two hand-moved cutoffs.
