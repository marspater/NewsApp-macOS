# Unchanged refresh FTS cost — 2 October 2026

## Cause

`trg_articles_au` rebuilt FTS after every article update, including metadata-only and identical refreshes. Its `DELETE FROM articles_fts WHERE article_id = old.id` filters an UNINDEXED FTS column. SQLite `EXPLAIN QUERY PLAN` on the equivalent isolated FTS table reports `SCAN ... VIRTUAL TABLE INDEX 0:`. Each unchanged row caused another scan and tokenization of identical text.

## Correction

Schema v12 transactionally replaces only the update trigger. Null-safe `IS NOT` comparisons for title, description, content, source and category guard reindexing. These are exactly the indexed article fields; article IDs remain immutable. Changed searchable text still removes old terms and inserts new terms in the same transaction. Insert/delete behavior and original article/history storage are unchanged.

The scan still exists for changed text and actual deletions. A durable FTS rowid mapping is a larger change, deferred until those workloads justify it. This patch removes unnecessary scans without a new index/storage model or skipped metadata updates.

## Controlled comparison

Same Apple M5/24 GiB, macOS 27.0.1, Xcode 27/Swift 6.4, optimized benchmark. Same temporary 10,000-story initial library / 20 publisher labels / five mocked feeds of 50 stories each / 500-row snapshot; final 10,250 rows. First refresh inserts rows, nine subsequent refreshes repeat the same batches. Existing image curation and fallback analysis remain enabled exactly as in the baseline.

| Refresh workload | Before | Guarded trigger |
|---|---:|---:|
| First ingestion, one sample | 709.732 ms | 700.669 ms |
| Repeated ingestion, median of nine | 2,975.689 ms | 526.517 ms |
| Repeated ingestion range | 2,845.508–4,029.390 ms | 519.273–549.336 ms |

The repeated median improves about 5.65× (82.3% lower latency); first ingestion is effectively unchanged. These sequential controlled runs support the mechanism, not a universal speedup across hardware/library sizes. Raw [before](../benchmarks/2026-10-02-core-baseline.json) and [after](../benchmarks/2026-10-02-guarded-fts.json) samples are retained. Peak benchmark process RSS after: 107.44 MiB, essentially unchanged.

A provisional repeated-ingestion investigation budget for this exact workload is 700 ms (about 25% above the observed maximum, rounded upward), superseding the earlier 5.1 s baseline trigger for comparable runs only. Rendered first-card, real transport and model budgets remain open in #104/#153.

## Correctness and scope

The regression observes stable FTS rowid for identical and image-only updates, checks new title/category search and removal of NULL-cleared content terms, and reconstructs a v11 library to verify the migration preserves existing search rows and installs the guard. A separate anchor row prevents rowid reuse from hiding a delete/reinsert. Copied-library tests now expect schema v12; their state-preservation assertions remain unchanged.

Optimized comparison completed. Focused regression, full mandatory commit-hook suite, arm64 build and signature results are logged on the PR/issues. No installed app or production library is modified. E and G are unchanged. The benchmark harness comes from PR #190; this correction is published separately to keep review scope focused.
