# Persistent article aliases — 1 October 2026

## Reconciliation and scope

Fetched all remotes and inspected the live story-experience issues and PRs before implementation. Current main was `487888f`: PRs #86, #87, #88, #165 and #170 were merged. PRs #166 (image caching), #167 (document identity) and #168 (reader figures) remained open. Issue #105 was closed; phase A and phase B were not complete.

The primary checkout contained unrelated icon/changelog edits and was preserved. Work continued in the attached `story-aliases` worktree. The next unblocked slice was #108, extending the identity work in #167. Publication uses #167's branch as its base so the new PR contains only alias changes. Its base already includes current main; no existing published branch was rewritten.

## Implemented

- SQLite schema v5 adds indexed aliases for observed IDs and normalized document URLs. Existing article keys, read/save state and timestamps, enrichment, feed associations and FTS rows are retained.
- Migration and seeding are transactional. Aliases observed during refresh commit or roll back with the article batch.
- Repeated URL/GUID changes retain previously observed identifiers. A simultaneous change resolves only when an observed signal connects it to the stored document. Entirely unknown identifiers remain separate.
- Historical URLs pointing to multiple stored rows receive a NULL target. That ambiguity survives removal of a conflicting row; refresh and link-only navigation do not choose a guessed target. Contradictory known ID and URL targets reject the batch.
- ID/link notification lookups, single/batch read-save operations, toggles, enrichment and analysis resolve to the stored primary key. ArticleStore updates its visible caches using that same key.
- Homepage, missing and credential-bearing URLs do not become document aliases. Alias removal follows article deletion through foreign keys; clearing extracted content does not clear durable identity.

## Verification

Environment: macOS 27.0.1, Apple silicon, Xcode 27.0, Swift compiler 6.4. App build uses Swift 6 language mode and macOS 15 deployment target.

- Full `./test.sh` passed. The existing suite remains enabled; its old alias assertion now checks that lookup resolves the original primary key, alongside the existing single-document count assertion.
- New integration regression migrates a copy of a v4 fixture and confirms the original remains v4. Read/save flags and timestamps, primary keys and FTS survive.
- A cancelled migration rolls back the alias schema and user_version; subsequent initialization succeeds.
- Reopen, serial and simultaneous observed-ID/URL changes, notification routing, ambiguous historical URLs, deletion, contradictory signals, state toggles and visible enrichment/analysis caches are covered.
- An injected alias-write failure rolls back article changes, aliases and the FTS trigger. SQLite quick_check returns `ok`; foreign_key_check returns no rows.
- `./build.sh` passed in the isolated worktree. The resulting app is arm64, its Info.plist passes lint, and strict deep signature verification passes.
- `git diff --check` passed.

Full test and build logs: `/tmp/news-alias-tests.log` and `/tmp/news-alias-build.log`. The commit hook runs the full suite again at publication.

## Remaining boundaries

This finishes the minimal URL/observed-ID alias foundation in #108. Raw GUIDs still follow the current identity policy: feed scoping is #109. Content fingerprints (#110), validated redirect/canonical signals (#111) and historical row reconciliation (#112) remain separate. The migration deliberately retains existing duplicates and does not manufacture evidence for unrelated identifiers. No clustering precision, model quality or performance baseline is claimed; phase B's evaluation holdout remains pending.

The installed app and real user database were not modified. No live publisher extraction, UI launch, release packaging or notarization was required or performed for this storage slice. Hosted CI must be checked separately on the published PR.
