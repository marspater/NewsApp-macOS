# Pair model pretraining data — 24 October 2026

Refs #623 (M11), #624 (M12), #574. Built on Mars's Mac with `script/training/pretrain_pairs.py` into `~/news-eval/pretrain-2026-10-24/` (`0700`, files `0600`); nothing of it enters the repository. The training rows are the `--export-pairs` shape (headline, lead, the app's word pieces) plus a `weight` column.

## Sources and licences

| Source | Version read | Rows | Use | Licence note |
| --- | --- | --- | --- | --- |
| WCEP-10 (`ccdv/WCEP-10` on the Hugging Face Hub, train split; Ghalandari et al. 2020, ACL) | `train.zip` as served on 24 October 2026, 8,158 clusters | 325,545 pairs: 108,515 same event (pairs inside a cluster, cap 15 per cluster; headline = first sentence, lead = next 600 characters), 217,030 different (clusters whose headlines share a capitalized name) | stage-1 pretraining, weight 1 | Article text from Common Crawl News, published for research; the shipped weights derive from it. Mars decides before a model trained on it ships. |
| GDELT 2.1 Events, Mentions and GKG (data.gdeltproject.org), 24 September to 23 October 2026, 8 slots a day (720 files, none missing) | 168,078 events with two actors, 240,559 titled pages | 15,497 different (same Actor1/Actor2 names and action country, different event id, 1–7 days apart, and the two headlines share a capitalized name; headline only). A first build without the shared-name rule gave 82,136 pairs, most of them unrelated reports under coarse actor codes such as POLICE or UNITED STATES, and was discarded. | stage-1 hard negatives, weight 1 | Unrestricted use. Headlines only (`PAGE_TITLE`), entity-decoded; shared event ids are never positives. |
| SemEval-2022 Task 8 (Zenodo 6507872), English–English pairs, pages from the Internet Archive | filled when the fetch finishes | | stage-2 graded pairs, weight 2 | Research dataset; URLs and ratings on Zenodo, text from the Internet Archive. |
| Reviewed labels of the #551 review (`sample_pairs.py --labels`): 200 rule matches, 100 pair-model confirmations, 56 related-act rows | labels of 24 October | 356 rows: 233 same, 123 not (related and different) | stage 2, weight 5 (#625) | Mars's own library; the library holdout is not among them. |
| Library pairs with same-day negatives (`--export-pairs` of 25 October, #625) | 24 October copy | 7,861 rows: 1,966 same, 3,929 far-apart negatives, 1,966 same-day cross-event negatives at weight 2 | stage 2 | Mars's own library. |
| Library pairs (`--export-pairs`, 24 October copy) and reader verdicts (#552) | `pairs.csv` of 24 October (44,038 rows) | | stage 2, weight 1 (verdicts 5) | Mars's own library. |

`gdelt-negatives.csv`: 5,457,149 bytes, SHA-256 `92c9051242aa54bfbe68d3cc84489858ce383188c78e3c9022b78111a8751a42`.

`reviewed-pairs.csv`: SHA-256 `6085daced6ea4a29a7b1b5822ce900d1a55bd60614a8d07aa4440afc5d4d2d13`; `library-m15/pairs.csv`: SHA-256 `14e678fe5392bc15d2844406e407233e7f2f600e14af6d195f6bff5be7ce53ee`.

`wcep-pairs.csv`: 978,539,979 bytes, SHA-256 `94c2c25a9cc60fe642c732002eab86ec6342b32dd156f27bb9352ee418f56a91`.

## Results

Filled by #624: the ablation (library only vs pretrained then library) at the same cutoff against the library holdout (#579), the tune replay and the authored corpus, and the gate decision.
