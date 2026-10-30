# Pair decision review — 24 October 2026

Refs #551 (M1), #574. Review of the pair decisions stored in a read-only copy of the live library (5,998 articles, newest published 24 October 2026 15:00 UTC, schema v25, matcher v11), exported with `--review-pairs` and labelled under the protocol in CONTRIBUTING ("Pair review protocol"). Labelled by Claude; Mars has not spot-checked yet (20 pairs are due, see the last section). Receipts: `~/news-eval/review-2026-10-24/` (`0700`), SHA-256 of the export `a2bacbb6…8847`, of the label files `05641689…901d` (match), `93cd0005…4815` (pair model), `83824a6a…e846` (related act).

Rows in the copy: 921 `match`/`match`, 484 `match`/`pairModel`, 470 `borderline`, 56 `related-act`, 0 `vetoed` (the copy predates the row type).

## Results

| Sample | Rows | `same` | `related` | `different` | False merges (`different`) | Wrong cards (`related` + `different`) |
| --- | --- | --- | --- | --- | --- | --- |
| `match` with reason `match` (rules) | 200 of 921 | 164 | 23 | 13 | 6.5% | 18.0% |
| `match` with reason `pairModel` | 100 of 484 | 67 | 12 | 21 | 21.0% | 33.0% |
| `related-act` (all) | 56 | 2 | 19 | 35 | — | 62.5% of links are not the same story |

The ceiling in #551 is 2% false merges per sample. Neither match sample meets it. The 24 October diagnosis said "no wrong merge was found among the pairs read"; that reading was of a few story groups, not a sample, and it was wrong.

## What the false merges are

Rule matches (13 `different` of 200):

- **Series items from one publisher with templated headlines** (8 of 13): Euronews "Latest news bulletin | October 21st, 2026 – Midday / Evening / Morning" (three pairs), "9to5Mac Daily: October 20 / 21 / 22 / 23" (two pairs), two Arab News opinion pieces, two Wired iPhone guides. The headlines share most words and the publisher; the matcher has no publisher signal.
- **Same topic, different story** (5 of 13): two oil-price reports a day apart, Gaza food shortages vs Palestinians facing hunger (31 h), a Sudan interview vs a Sudan drone attack, Brazil poll vs Brazil feature, Ilhan Omar news vs opinion.

Pair-model confirmations (21 `different` of 100):

- **Same topic, different story, within 36 h**: Rosebank oilfield vs Jackdaw gasfield; Kenya's eighth Ebola case vs Nigeria's first; Starlink restrictions lifted vs Ukraine partners with Nokia; iPhone Duo launch vs iPhone Duo accessory picks (twice); Saudi interior minister inspects security facilities vs inaugurates medical facilities; German youth plan protests vs French ban vs Greek protesters; Ukraine envoy meets Zelenskyy vs envoys to Oslo; a quiz on protests vs a Greek protest report.
- The model was trained on positives from stored events and negatives that share an anchor but lie 36 h to 7 days apart (`--export-pairs`). It never saw the hard negative the library is full of: two stories on one topic, same day, different occurrence. On the private holdout it still scored 38 / 0 / 0, because that holdout has no such pairs.

Related-act rows (35 `different` of 56): the rule is "act conflict, one shared specific anchor, two shared keywords". With `@US` or `trump` or `putin` as the anchor and "election", "attack", "police" as the keywords it links an Islamabad court story to Macron's protest speech and a Punjab bus crash to a Saudi airport attack. The 19 `related` rows are the links the feature exists for (arrest after the shooting, missiles after the talks, condemnation after the attack).

## Consequences for the program

1. **#582 must not lower the pair-model cutoff to 0.8.** At 0.9 the model's library precision on confirmed pairs is about 0.67 (`same` only) or 0.79 (`same` + `related`). The slice's first measurement is the cutoff sweep against the library holdout (#579); the likely outcome is a higher cutoff, or a retrained model with same-topic-same-day negatives mined from the library (`--export-pairs` gains a negative class: pairs in different stored events sharing an anchor within 36 h, after the story layer exists to label them).
2. **#581 (story layer) cannot join events through `related-act` rows as they stand**: 62% of them link unrelated stories. The story link needs two shared specific anchors (not a country) or a pair-model agreement, and the audit of 100 story groups in #581's acceptance is the gate.
3. **#580/#583: a same-publisher pair needs stricter evidence.** Eight of thirteen rule false merges are one publisher's series items. A same-source pair should require a shared specific anchor beyond the publisher's own templated words and no date-only difference in the headline ("October 21st" vs "October 22nd" are `titleNumbers` only when written as digits; ordinal dates are not).
4. The authored corpus (22 / 0) and the private holdout (38 / 0 / 0) are both saturated and blind to these errors. The library holdout from #579 replaces them as the gate.

## Spot-check (not done; see `2026-10-30-epic-m-verification.md`)

Twenty pairs for Mars, drawn as the first twenty of the match sample in the recorded order (`python3 script/evaluation/sample_pairs.py pairs-review.csv match 0 20` on the export). Mars's labels and any overturned label are to be appended here with the reason; three overturned in twenty mean the sample is relabelled.

## Reproduce

```sh
sqlite3 "file:$HOME/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3?mode=ro" ".backup copy.sqlite3"
NEWS_SNAPSHOT_DB=copy.sqlite3 NEWS_EVENT_OUTPUT=$HOME/news-eval/review-2026-10-24 ./test.sh --review-pairs
python3 script/evaluation/sample_pairs.py $HOME/news-eval/review-2026-10-24/pairs-review.csv match 0 200      # also: pairModel 0 100, related 0 56, vetoed 0 100
```
