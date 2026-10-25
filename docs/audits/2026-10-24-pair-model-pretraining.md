# Pair model pretraining data — 24 October 2026

Refs #623 (M11), #624 (M12), #574. Built on Mars's Mac with `script/training/pretrain_pairs.py` into `~/news-eval/pretrain-2026-10-24/` (`0700`, files `0600`); nothing of it enters the repository. The training rows are the `--export-pairs` shape (headline, lead, the app's word pieces) plus a `weight` column.

## Sources and licences

| Source | Version read | Rows | Use | Licence note |
| --- | --- | --- | --- | --- |
| WCEP-10 (`ccdv/WCEP-10` on the Hugging Face Hub, train split; Ghalandari et al. 2020, ACL) | `train.zip` as served on 24 October 2026, 8,158 clusters | 325,545 pairs: 108,515 same event (pairs inside a cluster, cap 15 per cluster; headline = first sentence, lead = next 600 characters), 217,030 different (clusters whose headlines share a capitalized name) | stage-1 pretraining, weight 1 | Article text from Common Crawl News, published for research; the shipped weights derive from it. Mars decides before a model trained on it ships. |
| GDELT 2.1 Events, Mentions and GKG (data.gdeltproject.org), 24 September to 23 October 2026, 8 slots a day (720 files, none missing) | 168,078 events with two actors, 240,559 titled pages | 15,497 different (same Actor1/Actor2 names and action country, different event id, 1–7 days apart, and the two headlines share a capitalized name; headline only). A first build without the shared-name rule gave 82,136 pairs, most of them unrelated reports under coarse actor codes such as POLICE or UNITED STATES, and was discarded. | stage-1 hard negatives, weight 1 | Unrestricted use. Headlines only (`PAGE_TITLE`), entity-decoded; shared event ids are never positives. |
| SemEval-2022 Task 8 (Zenodo 6507872), English–English pairs, pages from the Internet Archive | training and evaluation CSVs as served on 24 October 2026; the archive fetch was stopped on 25 October after 2,735 of about 4,070 pages (rate-limited to about 200 pages an hour) and the CSV written with `--cached-only` | 1,145 pairs: 224 same (overall similarity below 1.5), 921 different (2.5 and above); 2 dropped | stage-2 graded pairs, weight 2 (run E) | Research dataset; URLs and ratings on Zenodo, text from the Internet Archive. The fetch resumes from the cache when more pairs are wanted. |
| Reviewed labels of the #551 review (`sample_pairs.py --labels`): 200 rule matches, 100 pair-model confirmations, 56 related-act rows | labels of 24 October | 356 rows: 233 same, 123 not (related and different) | stage 2, weight 5 (#625) | Mars's own library; the library holdout is not among them. |
| Library pairs with same-day negatives (`--export-pairs` of 25 October, #625) | 24 October copy | 7,861 rows: 1,966 same, 3,932 far-apart negatives, 1,966 same-day cross-event negatives at weight 2 | stage 2 | Mars's own library. |
| Library pairs (`--export-pairs`, 24 October copy) and reader verdicts (#552) | `pairs.csv` of 24 October (`pairs-2026-10-24-v3`, 9,343 rows, 3,178 same event; the file has 44,038 lines because leads span lines) | run A stage 2 | stage 2, weight 1 (verdicts 5) | Mars's own library. |

`gdelt-negatives.csv`: 5,457,149 bytes, SHA-256 `92c9051242aa54bfbe68d3cc84489858ce383188c78e3c9022b78111a8751a42`.

`reviewed-pairs.csv`: SHA-256 `6085daced6ea4a29a7b1b5822ce900d1a55bd60614a8d07aa4440afc5d4d2d13`; `library-m15/pairs.csv`: SHA-256 `14e678fe5392bc15d2844406e407233e7f2f600e14af6d195f6bff5be7ce53ee`.

`semeval-pairs.csv` (prefixed, 25 October): SHA-256 `47e899c5967e6328a72e4ce44d96264ed0cf9356d6ab8c0748824e7283569a5e`. Stage-2 files: prefixed library + reviewed `stage2.csv` SHA-256 `2f9d881c20fb84003d1ef3d5f2f48aca39c4272c3d67aeb58e6795e772d7b481`, plain `stage2-m15.csv` `49c2f08025b7ff4f4e3778fa1ee15316d1d0f35254fe9695182bbcf79288e3b7`, prefixed with SemEval `stage2-semeval.csv` `6cb13cbc20972af3d0c1cd354f01d28226c067c6d15e3fa6e1caefc195d746e6`; prefixed `wcep-pairs.csv` (325,545 rows) `ff721259…`, prefixed `gdelt-negatives.csv` (15,725) `ad085156…` as recorded in `run-b/metadata.json`.

`wcep-pairs.csv`: 978,539,979 bytes, SHA-256 `94c2c25a9cc60fe642c732002eab86ec6342b32dd156f27bb9352ee418f56a91`.

## Results

Gate (#624): library holdout (#579) precision not below v12's 0.667 and recall not below 0.318 at some cutoff of the sweep 0.8–0.95; authored corpus 22 / 0; private tune replay 44 / 0. Every candidate is compiled with `coremlcompiler` and read through `NEWS_PAIR_MODEL_PATH` by `test_runner_e --library-holdout` (`NEWS_PAIR_PREFIX` matches the rows the model was trained on). Receipts: `~/news-eval/pretrain-2026-10-24/eval.log` and `…-prefix/eval.log`, `run-*/train.log`, `run-*/metadata.json` (input SHA-256s, per-stage held-out numbers), `run-a/holdout-diagnose.log` and `run-b/holdout-diagnose.log`, tune output under `~/Documents/NewsHoldout-2026-10-03/epic-m-2026-10-24/tune-run-*`.

Rows: WCEP 120,000 (CRC-32 subset of 325,545) and GDELT (15,497 plain, 15,725 prefixed) in stage 1, two epochs at 3e-5; stage 2 three epochs at 3e-5 on the library rows named, from the shipped MiniLM weights when there is no stage 1. "Library (#625)" is the 7,861-row export with same-day cross-event negatives at weight 2 plus the 356 reviewed labels at weight 5; "library v3" is the 9,343-row export without them. Holdout cells are `same` linked / wrong links.

| Run | Stage 1 | Stage 2 | Prefix (#626) | Holdout 0.8 | 0.85 | 0.9 | 0.95 | Corpus | Tune | Gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| v12 (shipped v11 weights, #525) | — | the #525 export, far-apart negatives only | no | — | — | 14 / 7 (0.667 / 0.318) | — | 22 / 0 | 44 / 0 / 49 | baseline |
| A | WCEP + GDELT (held-out AUC 0.961) | library v3 (held-out AUC 1.000, saturated) | no | 13 / 12 | 13 / 12 | 13 / 12 | 13 / 11 | 22 / 0 | 44 / 0 / 49 | fails: five more wrong links |
| B | WCEP + GDELT, prefixed (0.964) | library (#625) (0.981) | yes | 14 / 16 | 14 / 15 | 14 / 12 | 13 / 9 | 22 / 0 | 42 / 0 / 51 | fails: wrong links and two tune pairs lost |
| C | — | library (#625) (0.969) | yes | 17 / 11 | 17 / 10 | 15 / 11 | 13 / 8 | 22 / 0 | 42 / 3 / 51 | fails: three false tune pairs |
| D | — | library (#625) (0.948) | no | 12 / 6 | 13 / 6 | 10 / 6 | 9 / 7 | 22 / 0 | 43 / 0 / 50 | fails: recall 0.295 at best, one tune pair lost |
| E | — | library (#625) + SemEval 1,145 cached pairs at weight 2 (0.960) | yes | 18 / 13 | 17 / 13 | 15 / 12 | 9 / 11 | 22 / 0 | 42 / 4 / 51 | fails: four false tune pairs |

No candidate replaces the shipped model; `pairscorer.mlmodelc` and matcher v12 stay. What the five runs say:

- Pretraining on WCEP-10 and GDELT (A, B) adds wrong links, all of one kind: two acts of a running story a day or more apart (Houthi strikes on Saudi Arabia on two days, two Sudan war reports, two West Bank lockdown reports, Putin on talks with Kyiv, US strikes on Iran, Israel's election explainers, the iPhone Duo launch). WCEP-10 clusters are Wikipedia Current Events entries whose articles span the days around the event, so stage 1 teaches "same running story"; the GDELT negatives, one eighth of the positives, do not undo it, and run A's scores are saturated (one pair moves across the sweep).
- The reviewed labels and same-day negatives alone (D) make the model more careful: six wrong links at every cutoff, the fewest of any run, but it also links fewer `same` pairs (13 at best against 14) and loses one tune pair, so recall never reaches the bar.
- The prefix (C against D) raises recall (17 against 13 `same` at 0.85) and wrong links with it, and puts three false pairs on the tune replay, which no other run does: the words "gap N hours; same publisher" let the model link close-in-time pairs the rules then do not veto.
- SemEval on top of C (E) pushes the same way as the prefix: more `same` pairs linked (18 at 0.8, the most of any run) and more wrong links, four false tune pairs. Its pairs rated 3–4 are mostly different topics, not the same-topic hard negatives the library needs, and the ambiguous 2s are dropped.
- The library held-out split is no longer saturated once the same-day negatives are in (AUC 0.95–0.98 against 1.000 for the v3 export), so the training-time number has become informative again; the holdout and the tune replay remain the gate.

Next: the lever the runs point at is more reviewed labels on the running-story pairs (M15's loop: label the next model's confirmations with `sample_pairs.py --labels`), and a bi-encoder tuned on the same pairs for the cosine gate (M18, #628), not more public pretraining rows.
