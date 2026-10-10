# Feed-scoped GUIDs — 1 October 2026

## Scope and branch reconciliation

Task #109 extends the merged identity and alias work (#167/#171). Started a fresh `codex/feed-scoped-guids` branch in the existing isolated worktree from main `4835e66`, preserving the original checkout and the user-managed PR branches. While implementation was running, the user merged reader PR #168 and UI PR #89. Rebased the unpublished commit onto main `aa7d915`; retained both reader v3 and identity invariants in the sole documentation conflict. No GitHub merges or force pushes were performed.

## Implementation

- Incoming subscription articles carry their configured feed URL. GUID identity uses SHA-256 over an unambiguously framed feed URL and the existing normalized GUID representation. Scheme and all query parameters in the configured subscription remain significant; article URL tracking rules are not applied to feed namespaces.
- FeedManager carries scoped IDs into both ingestion and notification matching, so committed new IDs still notify exactly once, including when unrelated feeds reuse a GUID.
- Database resolution uses a scoped GUID alias when feed context exists. A known document URL can still connect different feeds to the same stored article. Hydrated articles retain stored primary keys.
- Schema v6 seeds aliases without rewriting article keys, state, enrichment or FTS. Only single-feed rows whose current GUID still matches their original primary key are seeded: multi-feed histories and unattributed later GUID variants do not establish ownership. Existing URL aliases remain usable.
- Alias and feed-association writes use the supplied feed context, including incoming model context in a save operation. Direct legacy callers supplying an unscoped model retain an unused old key; a collision receives a scoped key instead of overwriting another feed's document.

## Verification

- Full `./test.sh` passed after rebase, including merged reader v3 tests. The pre-commit hook also runs the full suite.
- The new regression is included in both the full runner and `--story-regressions`. It covers two feeds with the same GUID, title, source label and publication time; separate read/save state; same-feed URL correction; exact document URLs across feeds; missing URLs; scheme/query namespace differences; RSS XML parsing through refresh and repeat-refresh notification counts, including a shared document in overlapping feeds.
- A copied v5 fixture upgrades without rewriting its saved/read article ID. A colliding GUID in another feed inserts a separate document. Multi-feed ownership and later unscoped GUID variants are not guessed.
- Cancelled v6 migration leaves user_version at 5 and commits no scoped aliases; a subsequent open succeeds. Existing v4 migration/rollback, FTS, timestamps and alias tests remain enabled.
- Isolated arm64 `./build.sh` passed after rebase. Info.plist lint, strict deep signature verification and architecture inspection passed.
- `git diff --check` passed.

Logs: `/tmp/news-guid-tests.log`, `/tmp/news-guid-focused.log`, `/tmp/news-guid-build.log` and `/tmp/news-guid-commit.log`.

## Remaining

Legacy history did not record ownership of every GUID variant. Uncertain variants are resolved through known URLs when possible and otherwise kept separate. Existing corrupted cross-feed records cannot be reconstructed from absent original content; historical reconciliation remains #112.

Phase B remains open: content fingerprint #110, validated redirect/canonical signals #111 and historical reconciliation #112 remain separate. Precision against the evaluation holdout is not claimed. The installed app and real user database were untouched. This is a storage and refresh integration change, with isolated deterministic verification; no live publisher or GUI launch claim is made. Hosted CI/security results are tracked separately on the new PR. Merging remains with Mars.
