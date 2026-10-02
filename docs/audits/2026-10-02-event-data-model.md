# Event data model — 2 October 2026

## Scope

Implements #124 (Phase D, #94): stable event IDs, membership and membership versions. Matching, candidate generation and feed UI are separate tasks (#125–#129); event read/update semantics belong to #131 and the overview document to #133.

## Implementation

- Schema v13 adds `events` (ID, membership version, merge forward, timestamps) and `event_members` (article ID, event ID, version the article joined). `FeedArticle` and the article tables are unchanged. An article belongs to at most one event. Tables are created with `IF NOT EXISTS` inside one transaction with a cancellation check, like v8. Version 12 is left to the guarded FTS trigger (#192), which must merge first so libraries do not skip it.
- Members are stored by surviving article ID only: aliases and reconciled copies resolve to the stored document before membership is written, and unknown articles are rejected. No source text, title or passage is copied into an event.
- `DatabaseEngine` exposes `createEvent`, `addArticles`, `removeArticles`, `mergeEvents`, `splitEvent`, `fetchEvent`, `resolvedEventID` and `eventID(forArticle:)`. Each mutation is one transaction. Every change to an event's member set bumps its membership version once, including an event that loses an article to another; no-op changes do not. Existing overviews compare against this version (`EventOverviewDocument.isStale`).
- A merge moves the absorbed event's members into the survivor and keeps the absorbed row as a forward, re-pointing older forwards so they stay one hop deep; old event IDs open the survivor. A split creates a new event with a new ID for some (never all) current members; the original keeps its ID. Neither touches article rows, IDs or read/save state.
- Retention: membership follows article deletion (`ON DELETE CASCADE`), so saved and cited articles, which retention never prunes, stay members. After pruning, events with no members and no stored overview are dropped; a forward is dropped with its survivor. Pruning a member does not bump the version.

## Verification

No Swift toolchain was available in the authoring environment (Linux container), so nothing was compiled or run locally. The new `testEventDataModel` (full suite and `--story-regressions`) covers: a copied v11 library migrating to v13 with the original untouched, cancellation rolling back version and tables, preserved articles and read/save state, no text columns in the new tables, version bumps for add/move/merge/split and none for no-ops, forwards resolving after merge and split, rejected splits and unknown articles leaving the version unchanged, retention dropping emptied events and their forwards while keeping saved members and events with overviews, `quick_check` and `foreign_key_check`. The v4 and v8 migration fixtures now end at schema 13. Results come from macOS CI on the PR.

## Remaining

Nothing creates events yet; the matcher (#126) and incremental clustering (#128) will. Existing `event_overviews` rows are not linked to `events`: their IDs were opaque and no producer wrote them outside tests. Manual "different events" exclusions (#132) are not modeled here.
