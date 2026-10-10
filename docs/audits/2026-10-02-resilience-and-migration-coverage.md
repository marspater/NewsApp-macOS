# Resilience and migration coverage — 2 October 2026

Refs #154, #152, #98. Base: `10f6afe`. Maps the Phase H criteria that do not depend on Phase E to deterministic regressions in `Tests/NewsTests.swift`. Phase E (overview generation) belongs to another workstream and is not assessed here.

## #154 Resilience matrix

| Case | Evidence | Status |
| --- | --- | --- |
| Offline | `testFeedBackoffAndHostLimits`: a batch where every request fails to connect records no failures; a feed failing while others succeed is backed off | Covered |
| HTTP 304 | `testConditionalFeedRequests`: 304 leaves stored articles untouched; validators persist atomically with ingestion | Covered |
| HTTP 429 | `testFeedBackoffAndHostLimits`: `Retry-After` becomes the persisted wait, manual refresh inside the wait sends nothing, a refusing host's queued feeds are skipped | Covered |
| HTTP 500 | `testFeedBackoffAndHostLimits`: exponential backoff 600/1200/2400 s; 503 without `Retry-After` is back-pressure | Covered |
| Cancelled refresh | `testFeedBackoffAndHostLimits`: cancellation records no failure; `testFeedRemovalAndShutdown`: late delivery after removal or shutdown is not stored | Covered |
| Sleep/wake | `testSleepAndWakeRefresh` (new, PR #199) | Added; implemented in `FeedManager` |
| Reader closed during generation, article changed during generation, model unavailable, context overflow, unsupported language | Phase E (#141 and related) | Not assessed |

**Sleep/wake before this change.** There was no handling at all. The foreground `Timer` does not advance while the Mac sleeps, so after a long sleep the feed stayed stale for up to a full interval. Requests cut off by sleep could be recorded as failures for feeds that otherwise succeeded, backing healthy feeds off.

**After.** Sleep cancels a refresh in flight, which records nothing. After wake and a 10-second delay, one refresh runs if the interrupted refresh needs repeating or the last completed refresh is older than the interval. The foreground timer then restarts from that refresh.

"A stale result never overwrites a newer version" applies to generated overviews and remains with Phase E. Feed ingestion already keeps the newer of conflicting signals as described in `docs/ARCHITECTURE.md`.

## #152 Migrations on database copies

Each fixture below is built by opening a current library, removing later schema objects and lowering `user_version`, all in an isolated temporary file. The v4, v5, v8, v11 and v13 tests migrate a copy and confirm the original stays untouched. The v1 and v6 tests migrate the isolated fixture in place.

| Start version | Test | What it checks |
| --- | --- | --- |
| v1 | `testStructuredReaderAndTags` | Body text, saved and read state survive v1 → current; reader structure survives reopen, feed refresh and FTS |
| v4 | `testPersistentArticleAliases` | Alias migration; cancellation leaves v4; `quick_check`, `foreign_key_check` |
| v5 | `testFeedScopedGUIDs` | Scoped GUID aliases; cancelled migration keeps v5 |
| v6 | `testPublisherTextFingerprints` | Publisher-text aliases; cancellation keeps v6; existing aliases and read state retained |
| v8 | `testHistoricalReconciliation` | Reconciliation; cancellation and injected failure roll back; overview citations protect reconciled families; integrity checks |
| v11 | `testEventDataModel`, `testUnchangedFTSRefresh` | Event tables; cancellation keeps v11; guarded FTS trigger; integrity checks |
| v13 | `testEventReadingState` | v14 event state; cancellation rollback; preserved events and saved state; `quick_check` |

The overview tables (v8) are created on every pre-v8 copy above. Migration v8 itself runs in one transaction but has no cancellation check of its own.

| Criterion | Evidence |
| --- | --- |
| Old reader documents | v2 (`testReaderFigures`) and v3 (`testReaderPhaseC`) JSON decode under the v4 model. Pre-v2 libraries keep their text body (`testStructuredReaderAndTags`). |
| Saved stories and read history | Asserted in the v1, v4, v8, v11 and v13 copies |
| Settings | `UserDefaults`, not touched by schema migrations; isolation in `testAppSettingsIsolationAndURLNormalization` |
| Retention and evidence links | `pruneOldArticles` never deletes an article cited by `event_overview_citations`, including any original of a reconciled family (`testHistoricalReconciliation`, `testEventDataModel`). Saved articles are never pruned. |

## Limits

- Not compiled or run locally: the authoring container is Linux without a Swift toolchain. Evidence is macOS CI on PR #199.
- #152 and Phase H as a whole must be re-verified once Phase E adds schema changes (for example, overview caching). This table describes schema v14 only.
- No real sleep/wake cycle, native UI or real library was exercised.
