# Pair model pretraining data — 24 October 2026

Refs #623 (M11), #624 (M12), #574. Built on Mars's Mac with `script/training/pretrain_pairs.py` into `~/news-eval/pretrain-2026-10-24/` (`0700`, files `0600`); nothing of it enters the repository. The training rows are the `--export-pairs` shape (headline, lead, the app's word pieces) plus a `weight` column.

## Sources and licences

| Source | Version read | Rows | Use | Licence note |
| --- | --- | --- | --- | --- |
| WCEP-10 (`ccdv/WCEP-10` on the Hugging Face Hub, train split; Ghalandari et al. 2020, ACL) | `train.zip` as served on 24 October 2026, 8,158 clusters | 325,545 pairs: 108,515 same event (pairs inside a cluster, cap 15 per cluster; headline = first sentence, lead = next 600 characters), 217,030 different (clusters whose headlines share a capitalized name) | stage-1 pretraining, weight 1 | Article text from Common Crawl News, published for research; the shipped weights derive from it. Mars decides before a model trained on it ships. |
| GDELT 2.1 Events, Mentions and GKG (data.gdeltproject.org), 24 September to 23 October 2026, 8 slots a day (720 files, none missing) | 168,078 events with two actors, 240,559 titled pages | 15,497 different (same Actor1/Actor2 names and action country, different event id, 1–7 days apart, and the two headlines share a capitalized name; headline only). A first build without the shared-name rule gave 82,136 pairs, most of them unrelated reports under coarse actor codes such as POLICE or UNITED STATES, and was discarded. | stage-1 hard negatives, weight 1 | Unrestricted use. Headlines only (`PAGE_TITLE`), entity-decoded; shared event ids are never positives. |
| SemEval-2022 Task 8 (Zenodo 6507872), English–English pairs, pages from the Internet Archive | filled when the fetch finishes | | stage-2 graded pairs, weight 2 | Research dataset; URLs and ratings on Zenodo, text from the Internet Archive. |
| Reviewed labels of the #551 review (`sample_pairs.py --labels`): 200 rule matches, 100 pair-model confirmations, 56 related-act rows | labels of 24 October | 356 rows: 233 same, 123 not (related and different) | stage 2, weight 5 (#625) | Mars's own library; the library holdout is not among them. |
| Library pairs with same-day negatives (`--export-pairs` of 25 October, #625) | 24 October copy | 7,861 rows: 1,966 same, 3,932 far-apart negatives, 1,966 same-day cross-event negatives at weight 2 | stage 2 | Mars's own library. |
| Library pairs (`--export-pairs`, 24 October copy) and reader verdicts (#552) | `pairs.csv` of 24 October (`pairs-2026-10-24-v3`, 9,343 rows, 3,178 same event; the file has 44,038 lines because leads span lines) | run A stage 2 | stage 2, weight 1 (verdicts 5) | Mars's own library. |

`gdelt-negatives.csv`: 5,457,149 bytes, SHA-256 `92c9051242aa54bfbe68d3cc84489858ce383188c78e3c9022b78111a8751a42`.

`reviewed-pairs.csv`: SHA-256 `6085daced6ea4a29a7b1b5822ce900d1a55bd60614a8d07aa4440afc5d4d2d13`; `library-m15/pairs.csv`: SHA-256 `14e678fe5392bc15d2844406e407233e7f2f600e14af6d195f6bff5be7ce53ee`.

`wcep-pairs.csv`: 978,539,979 bytes, SHA-256 `94c2c25a9cc60fe642c732002eab86ec6342b32dd156f27bb9352ee418f56a91`.

## Results

Gate (#624): library holdout (#579) precision not below v12's 0.667 and recall not below 0.318 at any cutoff of the sweep 0.8–0.95; authored corpus 22 / 0; private tune replay 44 / 0. Every candidate is compiled with `coremlcompiler` and read through `NEWS_PAIR_MODEL_PATH` by `test_runner_e --library-holdout`; the shipped v12 model is the row marked shipped. Receipts: `~/news-eval/pretrain-2026-10-24/eval.log`, `…/run-a/holdout-diagnose.log`, `~/news-eval/pretrain-2026-10-24-prefix/eval.log`, tune output under `~/Documents/NewsHoldout-2026-10-03/epic-m-2026-10-24/tune-run-*`.

| Model | Stage 1 | Stage 2 | Prefix (#626) | Holdout 0.8 | 0.85 | 0.9 | 0.95 | Corpus | Tune | Gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| v12 (shipped v11 weights, #525) | — | library pairs of the #525 export, far-apart negatives only | no | — | — | 0.667 / 0.318 (TP 14, FP 7) | — | 22 / 0 | 44 / 0 / 49 | baseline |
| Run A | WCEP 120,000 of 325,545 rows (CRC-32 subset) + GDELT 15,497; 2 epochs at 3e-5; 109,348 training, 1,460 held out, held-out AUC 0.961 | library pairs of 24 October, 9,343 rows (`pairs-2026-10-24-v3`), 3 epochs; library held-out AUC 1.000 (105 pairs) | no | 0.520 / 0.295 (TP 13, FP 12) | 0.520 / 0.295 (13, 12) | 0.520 / 0.295 (13, 12) | 0.542 / 0.295 (13, 11) | 22 / 0 (FN 2) | 44 / 0 / 49 | **fails**: five more wrong links than v12, one same pair fewer |
| Run B | WCEP 120,000 + GDELT 15,725 prefixed rows, 2 epochs | prefixed library pairs with same-day negatives (7,861 rows, #625) + 356 reviewed labels at weight 5; 3 epochs | yes | pending | pending | pending | pending | pending | pending | training since 11:10 on 25 October |

Run A's wrong links are not the rules' seven: twelve pairs link, five `different` and seven `related`, all of them two acts of one ongoing story a day or more apart (Houthi strikes on Saudi Arabia on two days, two Sudan war reports, two West Bank lockdown reports, Putin on talks with Kyiv, US strikes on Iran, iPhone Duo launch demand). WCEP-10 clusters are Wikipedia Current Events entries whose articles span the days around the event, so the pretraining taught "same running story" rather than "same occurrence"; the 15,497 GDELT negatives are one eighth of the positives and did not undo it. The scores are saturated: the sweep changes one pair between 0.8 and 0.95. Core ML output matched PyTorch within 0.0034 on 64 held-out pairs; `run-a/metadata.json` records the input SHA-256s and the per-stage held-out numbers.

