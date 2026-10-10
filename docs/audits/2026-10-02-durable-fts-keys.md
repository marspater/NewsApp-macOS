# Durable FTS keys — 2 October 2026

Refs #153, #104, #90. Based on `c54141e`, after #223/#224. The only open PR at the start of this slice was #226 (source reader); its files do not overlap. Event-overview UI work in #155 remains separate. The earlier competing v12/v13 migrations are merged; this slice introduces v15 after the existing v14 event schema.

## Root cause and implementation

The previous profile put 58.5% of dense clustering samples under the candidate SQL query. Its join reads `articles_fts.article_id`, an UNINDEXED field in FTS content storage, for every matching document. Update/delete triggers also locate the old FTS entry by that field, scanning the virtual table.

V15 adds `article_fts_rows(fts_rowid INTEGER PRIMARY KEY, article_id TEXT NOT NULL UNIQUE REFERENCES articles(id) ON DELETE CASCADE)`. Search pages, their filtered counts and event candidates use this integer to join FTS without loading its content blob merely to resolve the article ID. Update/delete triggers likewise target one FTS row by key. The existing null-safe changed-text guard is preserved. A BEFORE DELETE trigger removes FTS while the mapping is still available, then removes the mapping; both operations roll back with the parent statement/transaction. New keys use SQLite's INTEGER PRIMARY KEY allocation; the key may be reused only after its old article/mapping/postings have been deleted.

The migration transaction drops/rebuilds only the derived search index and mapping, installs the three triggers and sets version 15. Articles, stable public IDs, aliases/reconciliations, reader documents, saved/read timestamps, event membership and exclusions are untouched. The retained UNINDEXED article ID also keeps the legacy query usable as a benchmark control. FTS5 Porter/unicode61 tokenization, BM25 ranking, ID tie order, pagination and visibility/active-event filters are unchanged.

A link to `articles.rowid` would be unsafe: [SQLite documents that hidden rowids may change during VACUUM](https://www.sqlite.org/rowidtable.html). The separate INTEGER PRIMARY KEY mapping is durable and joins through the stored article ID. The regression deliberately relocates an article's hidden rowid before VACUUM and verifies search and event-candidate membership afterwards.

## Integrated measurements

Run `./test.sh --performance-baseline`; [raw samples](../benchmarks/2026-10-02-fts-rowid-baseline.json). Apple M5 / 24 GiB, arm64, macOS 27.0.1, Xcode 27 / Swift 6.4, `-O`, minimum macOS 15; app SQLite 3.54.0. Temporary 10,250-row library, 20 publisher labels, five mocked feeds, 2,030-character bodies and a 500-row snapshot. The app build and benchmark compilation had finished before timing. No real storage/network/model is used.

The legacy candidate query and production mapped query run against the **same database and FTS index**, ten times each with alternating order. Every result asserts equality of all four ordered fields across the full 80-row cap; the control retains the original time/visibility/active-event filters and rank/ID order. The production path includes its actor hop; the legacy control uses a separate read-only SQLite handle. Both prepare/hydrate their results per call.

| Operation | Samples | Median ms | Sample p95 ms |
| --- | ---: | ---: | ---: |
| Legacy candidate ID join | 10 | 41.179 | 42.011 |
| Durable integer candidate join | 10 | 24.636 | 25.431 |
| FTS, first 100 | 10 | 43.786 | 49.014 |
| Dense clustering, 200 reset rows | 5 | 7,673.812 | 7,803.606 |
| Unchanged clustering | 10 | 12.089 | 12.407 |

The paired candidate-query median is **40.2% lower**. This is the primary speed comparison, avoiding the environmental variation of #224's separate runs. Dense-pass median is 7.674 s on this stress input; each pass resets the same 200 rows, asserts exactly 200 processed and drains pending work. Unchanged passes assert zero processed rows. Earlier #224 measured 13.496 s median / 16.409 s maximum, but that cross-run comparison is observational. Generic shared research wording is a stress workload, not a representative publisher corpus or holdout accuracy result. Nearest-rank p95 is the maximum for both five- and ten-sample series.

Peak benchmark-process RSS: 127.594 MiB, including fixture setup and the extra legacy-query comparison handle; this is not shipping-app memory. Existing provisional budgets remain investigation triggers; no timing assertion or matcher threshold was weakened.

## One-time rebuild and verification

[Five copied v14 SQL-migration samples](../benchmarks/2026-10-02-fts-rowid-migration.json) used 10,250 synthetic rows with the same body length, the exact v15 SQL, and the system SQLite CLI 3.54.0. CLI startup plus transaction/rebuild/commit: median 317.181 ms, maximum 358.614 ms. Source file 91,025,408 bytes; migrated file 91,488,256 bytes. Every copy retained 10,250 articles/mappings/FTS entries and passed quick_check/foreign_key_check. These are warm synthetic SQL measurements, not cold application launch or a universal migration-time guarantee. The one-time rebuild requires additional index/WAL disk space and can delay the next database open on larger libraries.

Full `./test.sh` passed. The new copied-v14 regression covers pre-cancellation, a failure injected after dropping the old index (DDL, triggers and old version roll back), successful retry, rank/ID order, saved/read timestamps, event members, relocated rowids/VACUUM, indexed deletion and rollback, SQLite quick_check, foreign_key_check and FTS integrity-check. Older migration tests now expect the current v15 endpoint; their assertions preserving originals, saved/read data and reconciliation remain intact. The unchanged-refresh test compares FTS segment data because a durable row key alone can no longer detect unnecessary reindexing. The mandatory commit hook reruns the full suite before publication.

The optimized baseline passed all workload/result assertions. An isolated optimized Swift 6 arm64 `./build.sh` passed with valid plist, strict ad-hoc signature and Hardened Runtime; no entitlements changed. The bundle is not installed or launched, and no real library is migrated. Shared architecture/changelog record the new index invariant; no reader UI or its dedicated tests were modified. Hosted CI remains separate.

#104/#153 stay open for cold application launch, real transport/active-work cancellation and shipping memory. Reader/event-overview native QA remains #123/#155; holdout quality remains #102. No merge is included in this slice.
