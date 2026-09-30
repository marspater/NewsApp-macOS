# Architecture

Native macOS, local-first RSS reader. Project policy lives in [AGENTS.md](../AGENTS.md).

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
