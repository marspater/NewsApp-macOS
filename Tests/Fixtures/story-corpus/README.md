# Story evaluation corpus v1

Refs #102. This is a **candidate evaluation corpus**, not an independently audited gold standard or a release-accuracy result.

## Contents and provenance

460 pairs: 200 `same_event`, 130 `same_document`, 130 `different`.

- 300 URL records represent 100 single-event W2E topics, with three distinct publisher hosts per topic. The two same-event pairs per topic inherit the authors' relevance annotations. The 100 different-event pairs join distinct merged-topic families; these negatives require independent event review.
- 100 additional documents/pairs are derived tracking-URL controls. They are not independently observed copies of publisher documents.
- 30 fictional paired-event families in English, Ukrainian and Polish add 30 hard negatives and 30 normalized-text copy positives. The hard negatives cover successive company quarters, different strikes in one region, and identical headlines about different projects. Repeated authored prose intentionally exercises the exact-text signal's length requirements; it is not representative news prose.
- There are 490 document records and 160 event records: **100 imported events plus 60 fictional events**. Synthetic controls are reported separately from imported annotations.

Source: [W2E](https://github.com/smutahoang/w2e), Tuan-Anh Hoang, Khoi Duy Vo and Wolfgang Nejdl, CIKM 2018. Downloads were retrieved October 2, 2026. The corpus stores URLs, dates, topic IDs, category names and derived labels. It does not redistribute publisher bodies, the source event summaries, or Kite data. No publisher-text license is asserted. Input SHA-256 values are recorded in the JSON provenance.

W2E relevance is topic-level. Sampling only topics with exactly one event and URLs dated within one day reduces ambiguity but does not replace independent document review. Distinct hosts are not proof of independent reporting. These historical URLs have not been fetched or checked for current availability. Real-record languages remain `undetermined`; domain names are not language labels. `observedDay` is a day-level dataset observation, not a precise publication timestamp.

## Labels and split

- `same_document`: the same publisher document, including a tracking variant or normalized copy; syndicated reporting from another publisher stays distinct.
- `same_event`: distinct documents reporting the same concrete occurrence.
- `different`: different occurrences, including another quarter, strike or municipal decision involving related participants.

Builder unions **all** source topics connected by a W2E merged group or shared normalized URL before sampling. It selects one topic from each of 100 disjoint families using a fixed SHA-256 ordering. First 70 families are tuning; last 30 are holdout. Each authored family stays in one split (seven tuning and three holdout per language). Thus 322 pairs are tuning and 138 holdout. Negative pairs never cross splits. Authored templates occur in both splits and cannot be used to claim generalization.

`corpus-v1.sha256` freezes the artifact. Never tune thresholds after viewing holdout results. Corrections require a reviewed new corpus version and an explanation of affected labels/families; do not silently replace this holdout or overwrite its checksum. The default check validates structure without running holdout predictions. Native checks additionally detect canonical-URL and normalized-body leakage across splits.

## Run checks and evaluation

```sh
python3 script/evaluation/evaluate.py
./test.sh
./test.sh --corpus-fingerprints > /tmp/news-corpus-tuning.log
python3 - <<'PY'
import json, pathlib
line = next(line for line in pathlib.Path('/tmp/news-corpus-tuning.log').read_text().splitlines()
            if line.startswith('CORPUS_PREDICTIONS '))
pathlib.Path('/tmp/news-corpus-predictions.json').write_text(line.removeprefix('CORPUS_PREDICTIONS '))
PY
python3 script/evaluation/evaluate.py --predictions /tmp/news-corpus-predictions.json
```

The native adapter calls the production `ArticleIdentity.publisherTextFingerprints` function. It evaluates **only that binary document signal**, not database ingestion, GUID/URL matching, or event clustering. Nonmatching same-event documents are correctly negative for document identity. Missing/short text, title or precise date produces an abstention. No publisher text is fetched. No user settings/database are read or changed.

For a private local publisher-text sidecar, add `--corpus-texts /absolute/path/texts.json` to the native command. Its dictionary keys must be corpus document IDs, with values `{ "title": "…", "body": "…", "publishedAt": "2016-04-08T12:30:00Z" }`. Use verified publisher timestamps, not synthetic midnight values. Include each independently validated variant's text. Keep this file outside the checkout. No text or hashes are emitted in predictions/reports. Byte-identical normalized bodies across splits fail closed.

For another evaluator, provide `{ "algorithm": "name/version", "task": "three_way", "predictions": { "pair-000": "same_event", "pair-001": null, "…": "different" } }`. Use `task: "document_identity"` for binary deduplication. IDs must cover exactly the selected split; null means abstention. Metrics include explicit denominators, abstentions, precision, recall among evaluated cases and recall across all labeled cases. Reports break down languages, paired publisher hosts and provenance; source pairs have small samples and unknown language remains explicit.

Holdout evaluation requires both `--corpus-holdout` in the native runner and `--holdout` in the scorer. It should occur once after labels and thresholds are frozen. This implementation has **not run holdout predictions**.

## Rebuild and remaining acceptance work

The builder uses Python's standard library and makes no network requests. Output must be a new `.json` file under the fixture directory or the system temporary directory; existing files and output symlinks are rejected. The parent directory must belong to the current user and be unwritable by other users. With the original input files (checksums in provenance):

```sh
CORPUS_REBUILD_DIRECTORY=$(mktemp -d)
python3 script/evaluation/build_corpus.py \
  --articles /tmp/news-w2e-topics.zip \
  --events /tmp/news-w2e-events.tsv \
  --groups /tmp/news-w2e-groups.txt \
  --output "$CORPUS_REBUILD_DIRECTORY/corpus-v1-rebuilt.json"
cmp Tests/Fixtures/story-corpus/corpus-v1.json "$CORPUS_REBUILD_DIRECTORY/corpus-v1-rebuilt.json"
```

Original URLs are linked from the W2E README: `topics.zip` (article URLs), `events_grouped_by_topic_with_manually_constructed_queries.csv` and `topicGroups.txt` (merged groups). Event prose is used only to count events/dates and is omitted from the output.

Before closing #102: independently adjudicate imported same-event/different labels, obtain real same-document variants and licensed/local text, verify languages and timestamps, record text-input provenance privately, and measure the frozen holdout. Require ≥99% real-publisher fingerprint precision with positive-support and coverage counts; authored positives alone cannot pass. Event-clustering predictions remain a separate evaluation. `releaseGatePassed` stays false in this candidate scorer to prevent a synthetic-only green report from being treated as acceptance. The fingerprint gate is measured with the private capture below, not with this URL corpus.

## Real-publisher capture for the fingerprint gate

This URL corpus cannot measure the fingerprint gate: it has no publisher text and no observed same-document variants. A library export cannot either, because the app folds a matched variant into the existing row and keeps only its URL as an alias. Capture parsed feed items before identity resolution instead, into a private directory:

```sh
mkdir -m 700 ~/NewsCorpusCapture
./test.sh --corpus-capture ~/NewsCorpusCapture   # repeat on several days; variants appear over time
./test.sh --corpus-capture ~/NewsCorpusCapture --corpus-feeds ~/NewsCorpusCapture/feeds.json   # optional own feeds
./test.sh --corpus-review ~/NewsCorpusCapture    # tuning sheet and report
```

- The directory must exist, belong to you, be closed to other users (`chmod 700`) and lie outside the checkout. Captures are written `0600` and never overwritten. The capture fetches the starter catalog (and optionally `[{"url": "…", "language": "en"}]` from `--corpus-feeds`) through the app's protected networking and parsers. It never opens the app's library or settings.
- The split is by publisher host: 30% holdout by a fixed hash. Fingerprints include the host, so every candidate family stays on one side and the holdout measures publishers not looked at during tuning.
- `review-<split>.json` lists each pair of distinct canonical URLs that share a fingerprint, with URLs, titles, sources, languages and dates, never body text. Open both URLs and record `{"<pair>": "same_document"}` or `"different"` in `labels.json` in the same directory. Same-URL pairs are counted but excluded: the URL already decides them.
- `CAPTURE_FINGERPRINT_REPORT` prints counts only: candidates, adjudications, abstentions, precision and its Wilson 95% lower bound, overall, per curated feed language and per source.
- Once tuning decisions are fixed, run the review once with `--corpus-holdout`. `releaseGatePassed` requires the holdout, every candidate adjudicated, at least 100 candidates and precision ≥ 99%. With fewer than 100, one error cannot be resolved against the 1% budget.

Limits: this measures the precision of different-URL fingerprint matches only, not recall or event clustering. Summary-only feeds rarely reach the 400-character text threshold, so support may stay low; the report then shows the gate unmet rather than passing. Language comes from the curated feed entry, not detection. The reviewer sees that each pair is a predicted match, so this verifies positives; it is not a blind three-way labeling.
