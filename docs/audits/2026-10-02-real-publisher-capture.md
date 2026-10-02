# Real-publisher capture for the fingerprint gate — 2 October 2026

Refs #102, #110, #91. Base: `10f6afe` (after #197 and #198).

## Why

The open #102 gate is ≥99% document-fingerprint precision on real publisher data. None of the existing tools could measure it:

- **URL corpus v1 (#197).** It has no publisher text, and its only same-document variants are derived tracking URLs. The imported W2E URLs are from 2016 and have no titles. The native fingerprint run abstains on all 280 imported pairs, and the event replay has nothing to cluster.
- **Library cache audit (#198, `--corpus-cache-audit`).** It compares rows of the `articles` table. When ingestion matches a variant by URL, GUID, validated alias or fingerprint, `upsertArticles` writes it into the existing row and keeps only the variant's URL in `article_aliases`. The variant's own text is gone. Fingerprint matches the app actually made are invisible to this audit; it sees only residual pairs that ingestion declined to merge.

Measuring the gate needs parsed feed items *before* identity resolution, kept privately.

## Implementation

Evaluation-only code in `Tests/StoryCorpus.swift`. No production source, schema or behaviour changed.

- `--corpus-capture DIR` fetches the starter catalog through `FeedFetcher` (protected networking and production parsers). With `--corpus-feeds FILE`, it also fetches `[{"url", "language"}]` entries. It writes one `capture-<ms>.json` with each item's feed, curated language, source, link, GUID, title, description, content and timestamp. The file is mode `0600`, created exclusively, and never overwritten. Neither the app's library nor its settings are opened.
- `--corpus-review DIR [--corpus-holdout]` loads all captures and removes repeated observations. It keeps one split and computes `ArticleIdentity.publisherTextFingerprints` on each item.
  - The split is by host (30% holdout, fixed SHA-256). Fingerprints include the host and canonical URLs never span hosts, so candidate families cannot cross splits. The split stays stable as captures accumulate.
  - **Candidates:** pairs of distinct canonical URLs that share a fingerprint. Their pair key is a hash of the two canonical URLs.
  - **Same-URL pairs:** counted separately, as sharing or not sharing a fingerprint, and excluded from the gate.
  - `review-<split>.json` lists URLs, titles, sources, languages and dates, never body text. Decisions go in `labels.json`; unknown label values are rejected.
  - `CAPTURE_FINGERPRINT_REPORT` gives counts, precision and the Wilson 95% lower bound, overall, per curated language and per source.
- **Gate:** holdout split, no unadjudicated candidate, at least 100 candidates and precision ≥ 99%, in integer arithmetic. With fewer than 100 candidates, one error cannot be resolved against the 1% budget. The tuning split never passes.
- **Private directory:** must be an absolute path to an existing directory owned by the current user, with no group or other permission bits, and outside the checkout.

## Verification

The authoring environment was a Linux container without a Swift toolchain, and its network policy blocked swift.org and publisher hosts. Nothing was compiled, run or fetched locally.

- Both changed Swift files parse with tree-sitter-swift. The three parser errors in `Tests/NewsTests.swift` are pre-existing false positives (`while await …`, `!`) and occur identically on the base.
- `python3 script/evaluation/evaluate.py` passed; the frozen corpus checksum is unchanged.
- `git diff --check` passed.
- New deterministic regression `testCapturedFingerprintReview`, in the full suite and `--story-regressions`, covers:
  - directory rejection: relative, missing, checkout and group/other-readable directories
  - `0600` captures that are never overwritten
  - capture round trip with production fingerprints and unknown dates
  - deduplication across captures
  - short and undated items left unfingerprinted
  - a stripped `utm_` URL treated as the same URL, and an edited body at the same URL losing its fingerprint
  - one different-URL candidate, no body text in the sheet, a sealed holdout
  - labels applied per split, per language and per source, and unknown labels rejected
  - gate boundaries (99/1 passes, 98/2, 99/0, an unlabeled candidate and tuning fail) and the Wilson bound

Compile and test results come from macOS CI on the PR. No live capture was run; how many real candidates the catalog yields is unknown.

## Remaining for #102

- Run captures on a Mac over several days. Review the tuning sheet, then run the holdout once.
- Summary-only catalog feeds rarely reach the 400-character threshold. If holdout support stays under 100, add private full-text feeds with `--corpus-feeds` rather than lowering the bar.
- Independent adjudication of the imported W2E event labels, real hard negatives and event-clustering holdout precision (#94's ≥97% target) remain open. The capture provides real titles, descriptions and languages for that later work; event labels do not exist yet.
- `--corpus-cache-audit` is unchanged; its counts describe only unmerged library rows.
