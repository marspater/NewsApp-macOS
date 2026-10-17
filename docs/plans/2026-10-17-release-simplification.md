# ADR: Release simplification with two parallel agents

Status: Accepted for implementation by Mars on 17 October 2026.
Base: origin/main 807e34e800fc48afd670fbcda8d320f6fb06d8e6.

## Decisions
- Ship publisher-excerpt overviews; retain deterministic timelines, perspectives and thematic sections with their validators.
- Make all stories visible. Remove importance-based expiry and ingestion suppression through old expiry tombstones. Preserve stored ratings and ordinary retention.
- Stop automatic event-judge promotion and refresh-time importance scoring.
- Keep Today/archive chronological. Within existing Briefing diversity priorities, rank by publisher coverage, existing stored importance, publication time and stable ID. Unrated importance is neutral; Briefing stays frozen until New Briefing.
- Reuse #102 tune/English holdout and #409 diagnostic inputs. No new annotation or multi-day collection. Preserve labels and hashes; reused results are regression evidence.
- Keep the 97% point-precision target with nonzero predictions; report recall, support, false merges and Wilson intervals separately. #409 labels remain provisional. No claim of fresh independent acceptance.
- #314 is parked and outside release; retain its backend and merged #438 changes. #313 stays closed. #334 remains deferred. SwiftSoup and external embedding models are postponed.

## Agent 1 — Codex
Own matching, all storage, FeedManager, EventFeed/Briefing, ArticleListView, shared Tests/NewsTests.swift and corpus runner, compilation/build scripts, CI, shared documentation and issue/project updates.

### Matching
- Remove production pair promotions, soft-conflict overrides and whole-coverage model overrides.
- Require known publication dates within the existing 36-hour maximum, sharedSpecific >= 1, and conflict == nil.
- Keep current score thresholds: sharedEvidence >= 2; beyond 12 hours sharedEvidence >= 3 plus the current stricter wording threshold.
- Keep changing casualty tolls separate from distinguishing headline figures.
- Compatibility requires a shared specific anchor, no conflict and the existing compatibility score.
- Carry shared-specific count in EventPairAssessment; no persisted format change.
- In formation/admission/fragment merges, every relevant pair needs shared-specific evidence and no conflict; retain one matching pair, two-thirds compatible pairs rounded upward and existing aggregate score thresholds. This mitigates chain drift, not guarantees identity.
- Bump matcher version; revalidate active events under the current 72-hour activity policy using deterministic publication-date/ID order. Earliest surviving subgroup keeps original event ID.
- Apply splits transactionally with membership-version checks and overview invalidation. Preserve article IDs, exclusions, read/save state and archived groups.

### Visibility/energy/Briefing
- Remove importance hiding from list queries, notification eligibility and image eligibility, plus waiting-story UI.
- Stop importance expiry and old tombstone suppression without deleting historical schema/data.
- Stop automatic importance scoring, including on access or Briefing creation.
- Preserve bounded image lookup and all muting, notification privacy and ordinary retention behavior.
- Fetch bounded Briefing metadata in one database read; diversity first, then coverage, stored importance, time and ID.

### Integration
- Own shared tests, build/CI wiring and documentation; update old overview expectations after Gemini handoff without weakening retained safeguards.
- Snapshot/unload the isolated relation collector and verify job/process absence; preserve its files and evidence.
- Recover original private #409 replay export. If unavailable, report missing input and leave that comparison/#307 incomplete; do not reconstruct labels from public aggregates.

## Agent 2 — Gemini
Own exclusively:
- Sources/Intelligence/Overview*.swift
- Sources/Intelligence/PassageFactExtractor.swift only for excerpt correctness
- Sources/Models/EventOverview.swift
- Sources/Views/EventOverviewReaderView.swift
- Tests/EventOverviewAccessibilityTests.swift
- new Tests/PublisherExcerptTests.swift

### Implementation
- Remove model-written introduction/fact generation from production overview requests; reuse deterministic passage selection/extraction/composition.
- Use a stored publisher headline and complete publisher sentences with source badges/citation links. Never combine sources into one assertion.
- Leave summary empty; omit repetitive stitched introduction. Do not add placeholder prose for old tests.
- Retain deterministic timelines/perspectives/thematic sections and validators.
- Keep existing excerpt provenance kind; show Publisher excerpts; bump analysis version so cached generated prose regenerates.
- Preserve citation IDs/fingerprints, publisher-input guards, cancellation, supersession and extraction limits.
- Separate energy/extraction eligibility from model availability: AI-disabled requests produce final deterministic excerpts.
- Preserve coordinator request/warm-up and persistence interfaces. Omit hidingWaitingStories from overview queries.
- Do not edit storage, FeedManager, ArticleListView, shared runners/scripts/CI/docs or issue status.

### Tests/handoff
- Supply standalone @main regression harness in Tests/PublisherExcerptTests.swift runnable with:
  NEWS_NATIVE_HARNESS=Tests/PublisherExcerptTests.swift ./script/native_performance_baseline.sh
- Cover exact excerpts/citations, attribution controls, empty-summary render/store, stale cache invalidation, AI-off, cancellation and retained deterministic sections.
- Return commits, changed files, commands/results and exact shared-test expectations for Codex to update.
- Do not publish PRs or alter issue/project status.

## Parallel working contract
- Use separate worktrees from the same pinned origin/main: mars/release-core (Codex), mars/release-excerpts (Gemini).
- Never edit another owner's files. Required cross-boundary edits go in handoff to their owner.
- Use isolated databases/preferences/build outputs/module caches; preserve original data and evidence packets.
- No label changes, new dependencies, installation, permission changes, notification delivery validation or production-library repair.
- Codex alone integrates finished Gemini commits, updates shared wiring, performs combined validation and publishes.
- Gemini is reserved/Ready until actually started; assignment is not execution.

## Validation
- Matcher regressions: separate acts with common actors, country-only overlap, contradictions, chains, two-thirds behavior, changing tolls, active upgrades, archived groups and saved/read preservation.
- Visibility: minor-rated stories remain visible beyond 24h; tombstones no longer suppress reingestion; images/notification eligibility retained.
- Energy: zero production event-judge/importance-rating calls after refresh while image lookup still runs.
- Briefing: ranking/diversity, unrated inputs, stable ties, frozen sessions.
- Overviews: Gemini harness and retained citation/lifecycle/security tests; storage round-trip with empty summary.
- Freeze revised source/settings before final #102 English holdout and #409 comparisons. Use production article budgets. Report results separately with provenance and limits.
- Use copied collector only for automated splitting/idempotence/budget/data-preservation checks; unlabeled data does not establish precision.
- Run full regressions, excerpt harness, SwiftPM compile, isolated arm64 build/signature, and affected native UI checks. Include design checklist in UI PRs.
- #307 remains open until measured target and Mars acceptance. #308/#309 close only after replacement behavior is validated and merged. Do not claim installation or OS-notification acceptance.

