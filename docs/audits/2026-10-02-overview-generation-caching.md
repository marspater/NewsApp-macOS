# On-demand overview generation, caching and cancellation — 2 October 2026

## Scope

Issue #141 implements on-demand overview generation, caching, and cooperative cancellation for Phase E (Epic #95):
- Generate on request or for the visible event only.
- Cache results in memory and database; regenerate only after meaningful input changes (membership change or text change).
- Cancel when the reader closes or the event changes.
- A stale result never overwrites a newer version.
- Reuse the existing enrichment queue for bounded concurrency and system resource protection.

## Implementation

- **EnrichmentQueue Integration (`Sources/Intelligence/EnrichmentQueue.swift`)**:
  - Reused the existing priority-based, actor-isolated `EnrichmentQueue` rather than introducing a redundant scheduler.
  - Added `scheduleOverviewGeneration(eventID:priority:operation:)`: schedules overview generation respecting `maxConcurrency` (3 workers), tracks active tasks, and yields cooperatively if capacity is reached.
  - Added `cancelOverview(eventID:reason:)`: cooperatively cancels in-flight tasks when events change or readers close.
  - Updated `cancelAll(reason:)` to cancel active overview tasks during feed refreshes.
- **Overview Generation Coordinator (`Sources/Intelligence/OverviewGenerationCoordinator.swift`)**:
  - Actor-isolated coordinator providing `requestOverview(eventID:eventTitle:membershipVersion:articles:priority:)`.
  - **Caching & Staleness Detection**:
    - Derives deterministic `inputTextHash` from sorted passage fingerprints.
    - Inspects memory cache and persistent `ArticleStore` via `isStale(currentMembershipVersion:currentInputTextHash:)`.
    - Returns cached document immediately on cache hits without re-running token budgeting or fact extraction.
    - Triggers regeneration only when inputs change meaningfully (e.g. new articles join the cluster or `membershipVersion` bumps).
  - **Visible Event Management**:
    - `setVisibleEvent(eventID:eventTitle:membershipVersion:articles:)`: tracks current active event in the UI/reader.
    - When visible event changes, automatically cancels in-flight tasks for the previously visible event.
  - **Cooperative Cancellation**:
    - `cancel(eventID:reason:)`: cancels in-flight `Task` and underlying `EnrichmentQueue` task.
  - **Stale Supersession Protection**:
    - `commitGeneratedOverview`: verifies membership version against memory cache and atomic database constraint before committing. Stale results never overwrite newer versions.
- **Composer Fix (`Sources/Intelligence/OverviewComposer.swift`)**:
  - Reduced `composeFallbackOverview` parameter count to 7 for SonarCloud `swift:S107` compliance.

## Verification

- Full test suite (`./test.sh`) passed with 100% green tests.
- Staged arm64 application build (`./build.sh`) and hardened runtime verification (`./build_release.sh`) succeeded with code signatures verified.
- Unit tests in `Tests/NewsTests.swift` (`testOnDemandOverviewGenerationAndCaching`) cover:
  - On-demand generation producing grounded `EventOverviewDocument`.
  - Cache hits avoiding redundant generation (identical document ID and timestamp).
  - Regeneration triggered on meaningful input change (membership version bump 1 -> 2).
  - Visible event switching automatically cancelling previous event generation.
  - Explicit cancellation on reader close.
  - Stale version 1 rejection when version 2 is already stored.
- SonarCloud compliance: zero hardcoded URL strings (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), no single-case switches (`swift:S1301`).

## Limits

- Event overview reader mode UI (#140) and labeled quality audit gate (#142) remain tracked in separate issues.
