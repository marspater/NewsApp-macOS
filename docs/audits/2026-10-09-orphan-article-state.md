# Orphan article state in the installed-library backup — 9 October 2026

Refs #331, found during #305. Investigated on private copies of the read-only v16 backup; the installed library was not modified.

## The row

`PRAGMA foreign_key_check` reports exactly one violation: `article_state` rowid 204. Its `article_id` is the literal `test_non_existent`, with `is_saved = 1`, `is_read = 0` and both timestamps NULL. No `articles`, alias or reconciliation row references it, and it is invisible in the app because every list joins state to articles. The neighbouring rowids date its insertion to between 12 September 12:51 and 27 September 17:19 UTC.

## Trace

- **Not app code.** The string `test_non_existent` appears in no commit on any local branch (`git log --all -S`), and in no test, script or preference file on this machine.
- **Not producible by the app.** Every connection enables `PRAGMA foreign_keys = ON` before migration, so a state write for a missing article fails. Every saved-state write path since the first SQLite store (`setSaved`, `toggleSaved`, `batchMarkSaved`, legacy import) stores a `saved_at` timestamp. This is the only saved row in the library without one.
- **Deletion and reconciliation.** `article_state` cascades on article deletion. Retention pruning deletes articles, not state. Alias reconciliation merges state into the survivor and records the duplicate's row in the history table before removing it.

The row was most likely written by an external tool with foreign keys off (the `sqlite3` shell's default), for example an ad-hoc probe against the installed library. The exact writer cannot be identified from the available history.

## Regression

`testOrphanStateGuards` writes saved and read state for `test_non_existent` through every state API, prunes an old read story and keeps a saved one on a file-backed library. It then checks that `foreign_key_check` is empty, that no row exists for the missing ID and that no saved row lacks a timestamp.

## Repair, defined on a copy

```sql
DELETE FROM article_state
WHERE NOT EXISTS (SELECT 1 FROM articles a WHERE a.id = article_state.article_id)
  AND NOT EXISTS (SELECT 1 FROM article_aliases WHERE value = article_state.article_id)
  AND NOT EXISTS (SELECT 1 FROM article_reconciliations WHERE duplicate_id = article_state.article_id);
```

On a copy of the backup this deleted one row. Visible saved stories (2) and read stories (77) were unchanged, `foreign_key_check` became empty and `integrity_check` returned `ok`. No orphan was recoverable through an alias or a reconciliation. The repair has not been applied to the installed library; doing so is a production-data change that needs Mars's approval.
