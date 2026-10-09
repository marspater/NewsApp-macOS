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

Before closing #102: independently adjudicate imported same-event/different labels, obtain real same-document variants and licensed/local text, verify languages and timestamps, record text-input provenance privately, and measure the frozen holdout. Require the real-publisher fingerprint gate below (false merges at most 1% of eligible holdout documents, and ≥99% precision once there are 100 candidates) with support and coverage counts; authored positives alone cannot pass. Event-clustering predictions remain a separate evaluation. `releaseGatePassed` stays false in this candidate scorer to prevent a synthetic-only green report from being treated as acceptance. The fingerprint gate is measured with the private capture below, not with this URL corpus.

## Real-publisher capture for the fingerprint gate

This URL corpus cannot measure the fingerprint gate: it has no publisher text and no observed same-document variants. A library export cannot either, because the app folds a matched variant into the existing row and keeps only its URL as an alias. Capture parsed feed items before identity resolution instead, into a private directory:

```sh
mkdir -m 700 ~/NewsCorpusCapture
./test.sh --corpus-capture ~/NewsCorpusCapture --corpus-feeds Tests/Fixtures/story-corpus/fingerprint-feeds.json   # repeat on several days
./test.sh --corpus-review ~/NewsCorpusCapture    # tuning sheet and report
```

- The directory must exist, belong to you, be closed to other users (`chmod 700`) and lie outside the checkout. Captures are written `0600` and never overwritten. The capture fetches the starter catalog plus `[{"url": "…", "language": "en"}]` entries from `--corpus-feeds` through the app's protected networking and parsers. It never opens the app's library or settings.
- `fingerprint-feeds.json` fixes the targeted sample: 40 sibling feeds of 14 catalog publishers, chosen because they share a feed title or carry long text, where one document is most likely to appear under two URLs.
- The split is by publisher host: 30% holdout by a fixed hash. Fingerprints include the host, so every candidate family stays on one side and the holdout measures publishers not looked at during tuning.
- `review-<split>.json` lists each pair of distinct canonical URLs that share a fingerprint, with URLs, titles, sources, languages and dates, never body text. Open both URLs and record `{"<pair>": "same_document"}` or `"different"` in `labels.json` in the same directory. Same-URL pairs are counted but excluded: the URL already decides them.
- `CAPTURE_FINGERPRINT_REPORT` prints counts only: candidates, adjudications, abstentions, precision and its Wilson 95% lower bound, and the Wilson 95% upper bound on falsely merged documents among all fingerprint-eligible documents (distinct canonical URLs), overall, per curated feed language and per source.
- Once tuning decisions are fixed, run the review once with `--corpus-holdout` on a new private directory of captures taken from 4 October 2026 on. `releaseGatePassed` requires the holdout, every candidate adjudicated, falsely merged documents at most 1% of eligible documents at the Wilson 95% upper bound, counting repeated observations of one canonical URL once (with no false merge, at least 381 eligible documents), and precision ≥ 99% once there are at least 100 candidates.

The gate bounds false merges instead of waiting for 100 matches because matches do not occur. A different-URL candidate needs the same host, feed title, title, timestamp and at least 400 characters of identical text. Two captures on 3 October, of the catalog and of the targeted feeds, held 3,021 unique observations (1,089 eligible) and no pair sharing host, feed title, title and timestamp under different links in either split, even before the text threshold. Precision of a signal that never fires can neither pass nor fail. Those captures were inspected for support counts on both splits, so they are not acceptance evidence.

Limits: this measures false merges and the precision of different-URL fingerprint matches only, not recall or event clustering. A fingerprint that never fires passes the false-merge bound: the gate shows that text fingerprints are safe, not that they find copies. On 3 October none of the 13 eligible same-URL copies on tuning shared a fingerprint either, because sibling feeds carry different feed titles. Language comes from the curated feed entry, not detection. The reviewer sees that each pair is a predicted match, so this verifies positives; it is not a blind three-way labeling.

## Source-review batch v2 — 3 October 2026

`publisher-review-v2.json` is a **provisional annotation proposal**, separate from the immutable W2E candidate. It records 400 proposed pairs from 183 live-captured observations: 6 observed same-URL copies, 199 proposed same-event pairs and 195 proposed negatives. The 100 proposed occurrence IDs include 40 with multiple observations and 60 singletons; they are not 100 independently adjudicated multi-source events. All seven catalog languages occur, but multilingual positive support remains uneven.

The fixed family hash assigns 263 pairs to `tune` and 137 to `holdout`. Related actions stay in one family: the Spanish housing vote/rally, the failed execution/resignation and the two Kyiv bridge strikes. This is a fresh current-publisher sample, not a correction to v1's imported labels. No matcher or embedding predictions were viewed during proposal preparation, and no holdout predictions have been run. The Spanish housing rally contributes 36 of 74 proposed holdout event-positive pairs, so this batch must not be presented as broad event-accuracy evidence. Expand the positive-event diversity before using it as a release gate.

### Event-boundary rules

These rules apply to v2 and later batches. A reviewer who disagrees records the change in a new manifest version.

1. An event is one concrete occurrence: who did what, where and when. A family groups related occurrences; a shared family never makes a pair `same_event`.
2. Label each document by the occurrence its headline and lead report as news. Earlier or later developments mentioned as background do not change the label.
3. An occurrence includes its direct consequences and state updates (casualties, injuries, a victim's condition, damage, closures at the scene), new facts about what happened (investigation findings, identities, video, eyewitness and first-person accounts), explainers and profiles pegged to it, and reactions that are only words (condemnation, praise, conditional threats, calls for action).
4. A new act starts a new occurrence, even when the earlier one caused it: a vote, ruling or appointment; a resignation; an arrest, charge, court hearing or bail decision; a decided policy, rule or plan; a protest; a new attack.
5. Repetition starts new occurrences: another protest day, another day's strikes, another quarter or reporting month. One attack wave (one attacker, one area, one night or day) is one occurrence for all its targets; one coordinated protest day is one occurrence for all its cities.
6. For an ongoing process (an epidemic, a war, a housing crisis), the occurrence is the reported development, such as a toll milestone, a battle or a decision, never the process as a whole.
7. Reports of the same publication (an official report, study, poll, leak or another outlet's investigation) are one occurrence.
8. A roundup, live page or tally is a singleton when its headline joins several occurrences without a lead; otherwise it belongs to the occurrence its headline leads with.
9. Label the captured version. If the publisher page has changed since (headline, slug or date), note it for the reviewer instead of relabeling silently.

Under these rules the parliamentary housing vote and the Saturday rallies are different events, the failed execution and its medical aftermath are one event while the commissioner's resignation is another, and the Northern Bridge strike, the earlier Southern Bridge strikes and the new bridge traffic rules are three events. All 29 proposed assignments in those families follow the rules ([audit](../../../docs/audits/2026-10-03-event-boundaries-fingerprint-scope.md)); this was a second copilot pass, not independent adjudication.

The public manifest contains URLs, feed metadata, proposed assignments and reasons only. Captured titles, descriptions and bodies stay in Mars's private folder, `/Users/marspater/Documents/NewsHoldout-2026-10-03/`, with directory mode 0700 and file mode 0600. Feed timestamps are captured values; they have not been independently verified on publisher pages. Proposals and singleton boundaries still need independent adjudication. Real quarterly-report and identical-headline hard negatives remain missing.

Validate the manifest and prepare a fresh private review directory:

```sh
python3 script/evaluation/publisher_review.py
mkdir -m 700 /tmp/news-publisher-review
python3 script/evaluation/publisher_review.py \
  --capture /Users/marspater/Documents/NewsHoldout-2026-10-03/capture-1791053699105.json \
  --output /tmp/news-publisher-review
```

`review.md` groups the publisher evidence by proposed occurrence; `pairs.csv` leaves `accepted_label` blank. Files are created exclusively and never overwritten. The frozen manifest checksum and capture checksum are checked, along with references, proposed-label consistency, split isolation and absence of publisher text in the public records.

After independent review, a private JSON file has this shape (IDs abbreviated here):

```json
{
  "reviewer": "reviewer name",
  "reviewedAt": "ISO 8601 review date",
  "allEventAssignmentsReviewed": true,
  "verifiedTimestampIDs": ["doc-0000", "... every document ID ..."],
  "labels": {"... every pair ID ...": "same_event"}
}
```

Run the preparation command with `--labels /private/path/reviewed-labels.json` and a fresh output directory to export `reviewed-event-corpus.json` in the native evaluator format, including observed publisher URLs for real identity resolution. Export refuses missing decisions, unverified timestamps and unreviewed event assignments. A changed decision requires a reviewed new manifest version with corrected event assignments; it must not silently relabel this frozen batch. This exporter does not run predictions or claim either acceptance gate.

Tune with `NEWS_EVENT_CORPUS=/private/path/reviewed-event-corpus.json ./test.sh --event-corpus`. Fix the embedding cutoff and deterministic settings on tune before the one holdout run. Record per-language/source support, false merges and recall; same-document copies and correlated pairs must not inflate the event gate.

For an English-only event replay, set `NEWS_EVENT_LANGUAGE=en`; filtering happens before ingestion. `NEWS_EVENT_JUDGE=1` enables the on-device judge with the existing evaluation-only unlimited pass budget; unset it for deterministic matching. `NEWS_EVENT_OUTPUT=/private/new-directory` saves memberships and clustering pass counts as `event-replay-<split>.json`, without publisher text or labels. The directory must already exist with mode 0700 outside the checkout; an existing receipt is rejected before scoring. Counts of settled judgements show whether the judge actually answered; requesting it alone is not proof of availability. Precision and recall include Wilson 95% intervals. Freeze code and settings first, run each agreed judge mode once in a separate fresh process/directory, and review saved memberships without replaying. This event replay is separate from the fingerprint holdout gate.

The six same-URL copies in this proposal do not measure the fingerprint gate. Neither the catalog nor the targeted sibling feeds produced a different-URL candidate, so that gate now bounds false merges over all eligible holdout documents (see the fingerprint section above) and stays open until a fresh holdout capture is reviewed.

## Publisher date and URL evidence follow-up — 4 October 2026

The frozen `publisher-timestamps-v2.json` sidecar records original publisher date fields and response hashes for all 183 v2 observations without rewriting their captured feed timestamps. It distinguishes publication, modification, video upload and unresolved contradictory metadata. Publication dates inform event boundaries; production replay must retain the dates the feed parser actually supplied. Source metadata extraction is not independent label adjudication.

`publisher-review-supplement-v1.json` proposes 62 additional pairs, bringing the review pool to 462, and adds 52 document IDs. It includes nine new multi-source occurrence proposals, real quarterly/reporting-period and repeated-headline negatives, and six publisher-advertised same-origin URL pairs. Episode/edition and URL pairs have a separate document-only scope. One proposed singleton correction is explicit; existing document splits and v2 bytes remain unchanged. Only one fresh positive occurrence lands in holdout: this expansion does not solve holdout event diversity. The event-boundary rules above still apply, including a reviewer's final lead/occurrence decision for the counterstrike report.

`publisher-url-investigation-v1.json` records unscored URL discovery, protected retrieval and normalized readability-text hashes, plus substantial feed-text coverage and the **tuning-only** October 3 two-capture report. Publisher-page probes are not second feed observations and cannot be counted toward the feed-capture fingerprint gate. This follow-up does not run holdout predictions. As #251 records, October 3 captures were inspected for support on both splits and are not fresh acceptance evidence.

To repeat source-page evidence collection, use a new private directory and a JSON array of `{"id":"doc-0001","url":"https://publisher.example/article"}` requests (at most 500, unique ASCII letter/number/hyphen IDs). Requests use `SecureHTTPClient`, bounded responses, cancellation and HTTPS with one request per host, at most six hosts. The mode writes HTML and `pages.json` privately and never opens the app library. Offline extraction creates a separate private `page-texts.json` with the production readability output; it computes no fingerprints or event predictions:

```sh
./test.sh --corpus-pages /private/evidence --corpus-urls /private/requests.json
./test.sh --corpus-page-texts /private/evidence
python3 script/evaluation/publisher_dates.py --manifest Tests/Fixtures/story-corpus/publisher-review-v2.json \
  --pages /private/evidence --output /private/evidence/timestamp-evidence.json
```

The Python date parser checks response hashes, scopes JSON-LD to the requested/publisher-canonical page, ignores nested recommendation dates and refuses dates without a timezone. Raw fields and unresolved cases stay visible. Frozen follow-up manifests are checked by `test.sh` for checksums, references, pending approvals, split isolation, declared corrections and absence of public publisher text. The two malformed Africanews records, video upload evidence and date-only primary releases require explicit reviewer treatment; never invent precise timestamps. The private supplemental review packet and blank approvals are in `/Users/marspater/Documents/NewsHoldout-2026-10-03/supplement-review-v2.md` and `supplement-pairs.csv`.

## Additional event diversity — 4 October 2026

`publisher-diversity-v1.json` adds 26 proposals (14 same-event, 12 different), using 26 new captured observations and 11 references to earlier observations. The combined review pool has 261 distinct observation IDs and 488 pairs. Twelve subject/action groups were selected before inspecting their fixed family split. Existing related families, observed URLs, feed dates, v2 and the earlier supplement are unchanged. The new sheet has 16 tuning and ten holdout pairs; four new occurrences contribute positive holdout pairs: the Renee Good family lawsuits, France/Italy football draw, Ethiopia/Eritrea diplomatic severance and Cornell consent-law pledge. These remain proposals, not accepted labels.

The France/Italy pair shares one publisher; French UK/EU poll coverage cites the Guardian, and trial coverage can share AP reporting. Treat these as correlated reports, not independent corroboration. The pool still concentrates 36 of 79 proposed positive holdout pairs in the Spanish housing rally (about 46%); four added occurrences reduce that concentration but do not establish broad release support. The DW diesel-reversal observation supplied no feed date, so it is excluded from replay proposals, recorded in `excludedCandidates`, and retained privately as context. Publisher metadata must not invent an input the app never received.

`publisher-date-resolutions-v1.json` records a pending interpretation of the two Africanews conflicts from the same preserved response bytes. Only the page's `jsMainMediaArticle` CMS data with a canonical URL matching the requested document is read. CMS first/publication/last-publication fields agree; JSON-LD's `datePublished` equals CMS creation, while the feed equals CMS update. The malformed OpenGraph publication fields also agree with CMS publication after replacing their literal `CEST` separator with `T`. The original timestamp artifact remains immutable; publication interpretations and independent approvals stay separate from captured replay dates.

The existing preparation tool now accepts an explicit frozen manifest:

```sh
python3 script/evaluation/publisher_review.py \
  --manifest Tests/Fixtures/story-corpus/publisher-diversity-v1.json \
  --capture /private/path/capture-1791053699105.json --output /private/new-review-directory
```

Every private evidence writer requires an existing output directory owned by the user with mode 0700 outside Git, including the date tool's `--output` parent. Parent traversal is rejected; files are created exclusively with mode 0600 relative to a checked directory descriptor, without following a destination symlink. The tool leaves decisions blank and rejects undated replay inputs even if a reviewer file claims verification. This command prepares only this batch, not a combined acceptance corpus. All batch labels and event assignments need independent review; the supplements' explicit corrections and document-only comparisons must be reconciled before a combined export. The new private packet is at `/Users/marspater/Documents/NewsHoldout-2026-10-03/diversity-review/`: `review.md`, `pairs.csv`, and `publisher-context.md` (captured input separated from later page text). No fingerprint or event holdout predictions were run.

## Independent diversity pair adjudication — 4 October 2026

Mars submitted decisions for the 26 diversity pairs and clarified `diversity-024` as `same_event` for clustering, with possible timeline context. `publisher-diversity-v2.json` supersedes v1 by checksum, assigns `doc-0931` to `g7-reserve-release`, and removes the now-empty reversal singleton. It retains every captured input, family split and other pair label. This is a reviewer-approved exception grouping related fuel-policy decisions; the general separate-action rule remains unchanged. Original v1 bytes and the submitted CSV are preserved.

The private receipt records 26 accepted pair decisions (15 same-event, 11 different; 16 tune, ten holdout), original approval wording/comments and the later clarification. “Hard accepted” denotes approval strength; the two cross-topic negatives remain easy negatives. Timeline suggestions on other negative pairs do not change their `different` labels or implement a new feature.

The original 400 and supplemental 62 review sheets still have blank decisions. This diversity submission provides neither timestamp attestations nor a review of all event/singleton memberships. In the combined corpus, joining the existing G7 group also implies links to `doc-0234`, `doc-0908` and `doc-1390`; those boundaries still need independent review with that group. Keep acceptance labels private, use the v2 manifest for subsequent diversity export, and require the existing exporter confirmations before replay. The combined pool still has 488 pairs; v1 and v2 are alternative versions, never additive batches. No acceptance predictions have been run.

## Accepted original pair review and singleton correction — 4 October 2026

Mars submitted the reviewed `v2-pair-review-2026-10-04/` packet. Its 400 concrete decisions match every frozen v2 pair ID, side, split, proposed label and reason: 199 same-event, 195 different and six same-document (263 tune, 137 holdout). The receipt retains the declared copilot authorship and subsequent user acceptance; this is not described as blind independent annotation. Combined with the diversity sheet, 426 of 488 sampled pair decisions are accepted. The 62 supplemental pairs remain unreviewed.

The accepted review identifies two singleton reports of the same October 2 terror charge against Joshua Kerry, including the planned attack on Nigel Farage. Captured inputs and preserved publisher text support the same-occurrence assignment. `publisher-review-v3.json` supersedes v2 by checksum, moves `doc-0305` into `occurrence-0091`, and removes the empty `occurrence-0305`. The base now has 99 proposed occurrences; every sampled label, capture field and document split is unchanged. Validation checks the exact declared correction, including with a recomputed artifact hash. Original v2, timestamp evidence and supplement/diversity predecessor references remain immutable.

Use the explicit v3 manifest for a subsequent base export. V2/v3 are alternative versions of the same 400 pairs; never count both. The exporter still requires timestamp verification and complete membership review. The private accepted receipt is in `/Users/marspater/Documents/NewsHoldout-2026-10-03/v2-pair-adjudication-2026-10-04/`; exact submitted bytes and notes remain private. Related-negative timeline notes preserve their accepted `different` labels. The diversity fuel-policy decision remains scoped and is not a new blanket rule for all reactions.

No real-publisher export, tuning or holdout predictions were run. Remaining work: supplemental adjudication, verified timestamps (including the two proposed CMS resolutions), implied G7 links, complete singleton/event review and one combined reviewed corpus. Publisher page evidence may verify provenance or occurrence boundaries; it never replaces the captured production replay timestamp.

## Supplemental pair adjudication complete — 4 October 2026

The accepted supplement contains 62 decisions: 31 same-event, 25 different and six same-document (55 tune, seven holdout). `extra-044` changes from different to same-event: the reviewed occurrence includes the suspected Irkutsk laboratory-worker death and quarantine, with subsequent information-removal reporting treated as context. `publisher-review-supplement-v2.json` supersedes v1 by checksum, joins `doc-1207` to `irkutsk-lab-death`, removes the empty information-removal singleton, and changes only that pair label/reason and occurrence assignment/reason. Captured fields, scopes, splits and every other pair remain unchanged. The earlier `doc-0273` pontoon-plan correction is accepted in the private receipt; frozen proposal flags remain separate from approvals.

All three sampled batches now have 488 accepted decisions: 245 same-event, 231 different and 12 same-document; 334 tune and 154 holdout. Fourteen pairs have document-only scope (eight different editions/episodes and six fetched URL variants). Scope and provenance remain visible, and publisher-page URL variants are not extra feed observations for the fingerprint gate. Copilot-authored reviews followed by user acceptance remain distinct from blind independent annotation.

Private reconciliation of base v3, supplement v2 and diversity v2 validates 261 unique document IDs and 488 unique, label-consistent edges while applying the charge, pontoon, Irkutsk and fuel-policy assignments. It produces a membership/timestamp confirmation packet, not a native replay corpus. The metadata groups include singletons, document-only records and auxiliary publisher-page inputs; none establish completed occurrence review. The original submitted sheets, all predecessor artifacts and capture bytes remain intact.

Remaining decisions are explicit: `doc-0308` has no captured feed date and requires a reviewed exclusion; six event-scope publisher-page inputs need separate auxiliary treatment; Apple dates retain day precision, and old Apple/FOMC examples cannot test the production matching window. Document-only examples stay outside the event gate. Publisher timestamps, two proposed Africanews CMS interpretations and all final memberships/singleton boundaries (including G7-implied links) still need confirmation. The ANSA extracted page is a consent screen; the Irkutsk label is supported by captured headline/description and other preserved reporting, without claiming successful ANSA full-text extraction. No combined native export, tuning or real-publisher holdout predictions have run.
