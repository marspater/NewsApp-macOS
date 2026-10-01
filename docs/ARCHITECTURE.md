# Architecture

Native macOS, local-first RSS reader. This document defines the supported technology and implementation constraints for all contributors. Validation and contribution workflow live in [CONTRIBUTING.md](../CONTRIBUTING.md); security reporting and boundaries live in [SECURITY.md](../SECURITY.md).

## Technology and product constraints

- Swift 6, SwiftUI, and narrow AppKit/WebKit integration; minimum deployment target macOS 15. Gate newer APIs without raising the minimum casually.
- Native Apple frameworks: Foundation, Network, SQLite3, NaturalLanguage, conditional FoundationModels, OSLog/signposts and Swift Concurrency. Prefer existing services and native APIs; third-party dependencies need a concrete requirement without a reasonable native solution.
- Local-first storage, no cloud backend, remote AI, custom AI models, telemetry or analytics SDKs. OSLog/signposts are local diagnostics. See [PRIVACY.md](../PRIVACY.md).
- Current development and verification builds are Apple silicon (arm64), ad-hoc signed with App Sandbox and Hardened Runtime. Intel/universal builds and notarization are outside current development scope.
- Native keyboard and trackpad interaction, accessibility, shared semantic design tokens and restrained Liquid Glass. Avoid fixed-display layout hacks and gratuitous animation.

## Implementation invariants

- Keep UI concerns out of database, networking and domain layers. Preserve actor isolation, avoid main-actor database work, bound batch concurrency/memory, and avoid lifecycle retain cycles.
- Propagate cancellation through feed, extraction and enrichment work. Shared refresh work survives an individual waiter cancelling; explicit reset cancels that shared work. Unstructured tasks require explicit lifecycle ownership.
- Undated articles retain the unknown publication-date sentinel for identity/display; archive and filter-only search order and paginate by their original ingestion time. Retention uses the same date fallback.
- Stored article IDs remain stable when publisher metadata changes. Ingestion resolves incoming GUID variants against indexed canonical document URLs; homepage and missing URLs are not deduplication keys.
- Schema v5 keeps observed IDs and document URL aliases mapped to existing primary keys. Alias writes share the ingestion transaction; conflicting URL aliases retain a NULL target and cannot be revived automatically. Resolve state, enrichment and navigation through aliases. Raw GUID feed scoping and historical row reconciliation remain separate changes.
- Reader document v3 preserves publisher figures with captions and alt text separately from analysis prose. Remote image URLs retain the protected networking boundary; ImageIO decoding limits input dimensions and display resolution. Existing v2 text documents remain readable.
- SQLite schema changes require migrations. Preserve WAL/FTS5, saved stories, read history and user settings; use transactions where multi-step writes must be atomic.
- Publication dates that are missing or malformed use a stable `Date.distantPast` sentinel; undated stories order by their original ingestion time. Upserts apply valid URL/date corrections while retaining known values when incoming metadata is invalid. New-story notifications use IDs inserted by a committed SQLite transaction, not the 500-story UI snapshot.
- Notification navigation requests remain in `ArticleStore` until storage is ready and resolve via SQLite by stable ID, with canonical URL fallback for older notifications.
- Ingestion remains cheap. Expensive extraction and analysis run on demand or under explicit bounded enrichment rules. Prefer extracted publisher content; distinguish it from generated summaries and never invent article facts.
- FoundationModels classification uses structured outputs and the supported deterministic taxonomy. Preserve model identifiers/analysis versions and deterministic fallbacks when models are unavailable. Persist only intelligence required by product behavior.
- Image requests honor native HTTP freshness and no-store rules after destination validation; feed, article and update requests retain explicit reload behavior.
- Treat URLs, feed bodies, publisher HTML, redirects and OPML as untrusted. Route remote fetching through the shared protected networking path; preserve destination validation, numeric-IP pinning, response bounds and cancellation.
- Keep app entitlements intact. Render sanitized reader HTML; protected WebKit previews disable publisher scripts and block local resources. Do not log secrets, article contents, credentials or full sensitive URLs.

## Current architecture map

### App / UI (`Sources/App/`, `Sources/Views/`)
- `Sources/App/NewsApp.swift`: application lifecycle, scenes, commands, notification routing, window configuration.
- `Sources/App/AppContainer.swift`: app dependency injection container.
- `Sources/App/AppSettings.swift`: user settings and defaults persistence.
- `Sources/App/ThemeManager.swift`: appearance/theme state.
- `Sources/App/UpdateChecker.swift`: GitHub release version verification.
- `Sources/App/NewsSignposts.swift`: local OSLog performance signposts.
- `Sources/Views/MainView.swift`: top-level UI coordinator.
- `Sources/Views/SidebarView.swift`, `ArticleListView.swift`, `ArticleCardView.swift`: navigation and list presentation.
- `Sources/Views/ArticleDetailView.swift`, `ArticleWebView.swift`: article reading and WebKit rendering.
- `Sources/Views/SettingsView.swift`: user settings.
- `Sources/Views/DesignSystem.swift`, `GlassSystem.swift`: semantic design tokens and Liquid Glass integration.

### Data / persistence (`Sources/Storage/`, `Sources/Models/`)
- `Sources/Storage/DatabaseEngine.swift`: SQLite engine, schema, WAL/FTS5 responsibilities.
- `Sources/Storage/ArticleStore.swift`: article domain persistence.
- `Sources/Storage/MigrationCoordinator.swift`: database migrations.
- `Sources/Storage/ReadManager.swift`, `SavedStoriesManager.swift`: reading and saved-story state.
- `Sources/Storage/CacheManager.swift`: HTTP cache, intentionally separate from durable user state.
- `Sources/Models/FeedArticle.swift`, `ArticleIdentity.swift`: article/domain identity models.
- `Sources/Models/FeedError.swift`: feed error types.

### Feed / networking (`Sources/Services/`, `Sources/Coordinators/`)
- `Sources/Coordinators/FeedManager.swift`: feed orchestration and synchronization.
- `Sources/Coordinators/RefreshCoordinator.swift`: refresh lifecycle.
- `Sources/Coordinators/NotificationService.swift`: user notification triage.
- `Sources/Services/FeedFetcher.swift`, `SecureHTTPClient.swift`: network fetching and security boundaries.
- `Sources/Services/FeedXMLParser.swift`, `JSONFeedParser.swift`, `DateParser.swift`: feed parsing.
- `Sources/Services/IPAddressValidator.swift`: SSRF/IP validation.
- `Sources/Services/OPMLManager.swift`: OPML portability.

### Content / intelligence (`Sources/Intelligence/`)
- `Sources/Intelligence/ContentExtractionPipeline.swift`, `WebContentExtractor.swift`: article content extraction.
- `Sources/Intelligence/ArticleIntelligence.swift`: article classification, sentiment, entities, summarization and content-cleaning capabilities.
- `Sources/Intelligence/EnrichmentQueue.swift`: actor-isolated background enrichment scheduling.
- Current intelligence code uses `NaturalLanguage` and conditionally `FoundationModels`, with typed `@Generable` outputs and a fixed 12-category taxonomy.

### Tests (`Tests/`)
- `Tests/NewsTests.swift`: automated test runner and unit test suites.

### Platform / distribution
- `News.entitlements`: sandbox/runtime capabilities.
- `build.sh`, `build_release.sh`, `script/distribution/package_dmg.sh`, `script/distribution/notarize.sh`, `test.sh`: build, release, packaging and validation pipeline.
- `.github/workflows/ci.yml`: CI.
- `PRIVACY.md`, `SECURITY.md`: privacy/security commitments.

The network gateway validates public DNS answers and pins numeric upstream connections. URLSession and protected WebKit previews share this boundary; WebKit also blocks local resource forms and disables scripts.
