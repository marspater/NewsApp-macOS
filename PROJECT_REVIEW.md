# Project Analysis and Improvement Proposal

## Current strengths

- The app has a clean SwiftUI structure with centralized state through `FeedManager`, `ThemeManager`, and `ReadManager` injected from `NewsApp`.  
- Feed ingestion already supports both RSS/XML and JSON Feed formats and includes local cache persistence.  
- There is meaningful product polish: saved stories, read-state, notifications, and per-article detail rendering.

## Key issues identified

1. **Settings toggles were not wired to app behavior**  
   - The Settings screen exposed controls for fetch interval, notifications, and AI analysis, but those values were local-only state in `SettingsView` and had no effect on runtime behavior.

2. **Background fetch interval was fixed**  
   - Feed polling used a hardcoded 15-minute timer, regardless of user selection.

3. **Notification and AI controls had no runtime guardrails**  
   - Notifications were always eligible when new articles were found.
   - AI enrichment ran unconditionally, even if users would prefer reduced processing.

4. **History navigation path was incomplete**  
   - The app had a “History” section but did not filter articles into read-history content.

## Improvements implemented in this update

### 1) Functional settings persistence and runtime wiring

- Added persisted, observable settings to `FeedManager`:
  - `fetchIntervalMinutes`
  - `notificationsEnabled`
  - `aiEnabled`
- Added setter APIs to persist and apply changes immediately.

### 2) Dynamic background fetch cadence

- `startBackgroundFetch()` now re-creates the timer using the selected `fetchIntervalMinutes` value instead of a hardcoded interval.

### 3) Feature flags for notifications and AI

- Notification triage is now gated behind `notificationsEnabled`.
- Background AI enrichment is now gated behind `aiEnabled`.

### 4) History section behavior

- `MainView` now populates “History” with articles marked as read.

## Additional recommendations (next steps)

1. **Split `FeedManager` into smaller services**  
   Move parsing, enrichment, notifications, and persistence into dedicated components to reduce coupling and improve testability.

2. **Introduce deterministic tests for parsing and categorization**  
   Add unit tests for feed parsing edge cases (missing dates, malformed enclosures, duplicate entries) and category assignment.

3. **Add explicit loading/error states in UI**  
   Today failures can silently result in empty feeds. Introduce per-feed diagnostics, retry controls, and user-facing error states.

4. **Improve identifier stability**  
   `FeedArticle.id` currently maps to `link`. Consider canonical URL normalization (or feed GUID fallback) to reduce accidental duplication.

5. **Resource controls for enrichment**  
   AI/content enrichment currently iterates through all articles. A queue with concurrency limits and cancellation on refresh would improve responsiveness and battery behavior.

6. **Accessibility pass**  
   Add VoiceOver labels for icon-only controls, improved color contrast checks, and Dynamic Type support where feasible.

7. **Security & privacy hardening**  
   Add host allow/block policy for fetches, stricter URL validation, and optional private-mode behavior around notification content.

## Suggested roadmap

- **Phase 1 (quick wins):** tests, error handling, URL normalization, accessibility labels.  
- **Phase 2 (architecture):** service decomposition + protocol-based dependency injection.  
- **Phase 3 (quality/perf):** enrichment queue, instrumentation, and crash/error analytics hooks.
