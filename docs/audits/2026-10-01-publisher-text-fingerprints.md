# Publisher text fingerprints — 1 October 2026

## Scope

Partial implementation of #110 on top of the merged feed-scoped GUID work (#173). The implementation is complete for conservative exact-text matching; acceptance against the labeled holdout is pending #102. Historical row merging remains #112. Mars handles GitHub merges.

## Implementation

- SHA-256 over framed fields: fingerprint version, exact article host and port, source label, text kind, normalized title, known publication timestamp and publisher text. Unicode canonical composition and whitespace normalization preserve case, punctuation and wording. Description and full-body evidence remain separate; generated summaries are never keys.
- Text must contain at least 400 characters and 40 whitespace-separated words and fit within 256 KiB. Short teasers, oversized text, unknown dates, missing titles, homepages and invalid/credential-bearing URLs produce no evidence. These conservative gates favor precision and need corpus calibration; they are not a measured precision guarantee and exclude some languages without word spaces.
- Indexed content aliases reuse the existing stable-ID and ambiguity mechanism. URL and feed-scoped GUID evidence takes precedence. Multiple targets or a NULL ambiguity tombstone prevent automatic text matching. Known metadata corrections can invalidate a previously unique text key without changing either stored primary key.
- Schema v7 extends alias kinds transactionally, preserves existing aliases and streams historical rows to index evidence without merging them. Historical shared fingerprints become ambiguous. Cancellation rolls back the schema/evidence change. Matching performs at most two indexed lookups per incoming document, with bounded text hashing, rather than archive comparisons.
- Ingestion records evidence in its existing transaction. On-demand publisher extraction records body evidence atomically with content and enrichment, reporting SQLite errors and rolling back failed writes. Old fingerprints remain observed historical evidence, including after content cache eviction; primary keys and user state remain intact.

## Verification

- Focused story regressions passed during implementation. Full regressions and the required commit hook run before publication; final results are logged on the PR.
- Isolated regressions cover normalized text with new URLs/GUIDs; distinct publishers, titles, times and changed text; short teasers, large text, undated items and generated-summary exclusion; full-body matching and on-demand extraction; authoritative GUID conflicts, persistent ambiguity, mixed body/description evidence and reopening; read/save preservation; v6 migration and cancellation; injected alias failure rolling back content and enrichment; actual FeedManager refresh and repeat-refresh notification counts.
- Isolated arm64 development build, plist/signature/architecture checks and diff review run before publication. No installation, production database changes, GUI or live publisher verification is claimed.

Logs: `/tmp/news-text-focused.log`, `/tmp/news-text-tests.log`, `/tmp/news-text-build.log` and `/tmp/news-text-commit.log`.

## Remaining

#110 stays open for the >=99% precision holdout acceptance. Exact host/source/title/time constraints deliberately miss uncertain duplicates, cross-host publisher variants and metadata changes lacking an established URL/GUID alias. No semantic similarity, event clustering, remote AI or automatic historical row merging is introduced. Phase B remains open; canonical/redirect signals (#111) are next.
