# Overview document model bound to inputs and versions — 1 October 2026

## Scope

Issue #133 defines the derived event overview document model and SQLite storage contract for Phase E (Epic #95).
All tasks within this slice are self-contained and unblocked by external dependencies:
- Derived overview document tied to membership version, input text hashes, schema version and analysis version.
- Citations store article ID and evidence passage ID/fingerprint.
- Changed inputs mark the overview stale.
- An older result never overwrites a newer version.
- Retention never leaves citations pointing nowhere.

Subsequent generative extraction (#135), clustering (#94) and reader mode UI (#140) remain deferred pending external blockers (#94, #103).

## Implementation

- **Data Models (`Sources/Models/EventOverview.swift`)**:
  - `EvidencePassage`: represents extracted evidence passages anchored by deterministic SHA-256 fingerprint.
  - `OverviewSourceMetadata`: encapsulates source title, publisher name, source URL and publication timestamp.
  - `OverviewCitation`: binds claims to stored article IDs and passage fingerprints, with parameter count bounded for code health.
  - `OverviewFact`: maps verified claims to citation IDs.
  - `OverviewLeadImage`: stores lead image URL, caption, credit and origin article ID.
  - `OverviewVersionContext`: binds membership version, input text hash, schema version, and analysis version.
  - `OverviewContent`: encapsulates narrative title, summary, facts, citations and lead image.
  - `OverviewProvenance`: tracks member article IDs, kind, and lifecycle timestamps.
  - `EventOverviewDocument`: aggregate root with deterministic `isStale(...)` evaluation. Flat JSON encoding and decoding preserved.
- **SQLite Storage Contract (`Sources/Storage/DatabaseEngine.swift`)**:
  - Incremented schema `user_version` to 8.
  - Added table `event_overviews` with unique `event_id`, versioning metadata, JSON projections, and index.
  - Added table `event_overview_citations` with foreign key `ON DELETE CASCADE` to overview and `ON DELETE RESTRICT` to `articles(id)`, plus indexes.
  - `recordEventOverview`: atomic transaction enforcing version supersession (rejecting older membership versions from overwriting newer ones).
  - `fetchEventOverview`: reconstructs complete document with citations.
  - `pruneOldArticles`: updated retention policy with `AND a.id NOT IN (SELECT article_id FROM event_overview_citations)` to ensure cited articles are never pruned.
- **Store Interface (`Sources/Storage/ArticleStore.swift`)**:
  - Added asynchronous pass-through helpers `recordEventOverview`, `fetchEventOverview`, and `deleteEventOverview`.

## Verification

- Full test suite (`./test.sh`) and focused story regressions (`./test.sh --story-regressions`) passed with 100% green tests.
- Isolated arm64 `./build.sh` application build completed and signed.
- Pre-commit hook validation succeeded without errors.
- SonarCloud analysis issues resolved:
  - `swift:S107`: Initializer parameter counts refactored with typed parameter objects (`OverviewSourceMetadata`, `OverviewVersionContext`, `OverviewContent`, `OverviewProvenance`) to keep all constructors <= 7 parameters.
  - `swift:S1075`: Hardcoded test URLs parameterized using existing `fixtureHost`.

## Limits

- No AI generation, token budgeting, prompt injection defenses, or reader UI are included in this PR; those belong to subsequent Phase E sub-issues (#134–#142) and will be implemented once Phase D (#94) and model probe (#103) land.
- PR: #176 (`Fixes #133`, `Refs #95`).
