# Jules Project Context

## What this app is
NewsApp is a native macOS RSS/news reader built with Swift and SwiftUI. It is intentionally local-first, privacy-oriented, ad-free, keyboard-friendly, and designed around native macOS interaction and visual language.

The current codebase already contains feed ingestion, SQLite persistence, FTS5 search, saved/read/history state, notifications, article extraction, WebKit reading, OPML import/export, a semantic design system, and an on-device intelligence pipeline. The README describes these capabilities and the major source-file responsibilities. 

## Current architecture map

### App / UI
- `NewsApp.swift`: application lifecycle, scenes, commands, notification routing, window configuration.
- `MainView.swift`: top-level UI coordinator.
- `SidebarView.swift`, `ArticleListView.swift`, `ArticleCardView.swift`: navigation and list presentation.
- `ArticleDetailView.swift`, `ArticleWebView.swift`: article reading and WebKit rendering.
- `SettingsView.swift`: user settings.
- `DesignSystem.swift`, `GlassSystem.swift`: semantic design tokens and Liquid Glass integration.
- `ThemeManager.swift`: appearance/theme state.

### Data / persistence
- `DatabaseEngine.swift`: SQLite engine, schema, WAL/FTS5 responsibilities.
- `ArticleStore.swift`: article domain persistence.
- `MigrationCoordinator.swift`: database migrations.
- `FeedArticle.swift`, `ArticleIdentity.swift`: article/domain identity models.
- `ReadManager.swift`, `SavedStoriesManager.swift`: reading and saved-story state.
- `CacheManager.swift`: HTTP cache, intentionally separate from durable user state.

### Feed / networking
- `FeedManager.swift`: feed orchestration and synchronization.
- `FeedFetcher.swift`, `SecureHTTPClient.swift`: network fetching and security boundaries.
- `FeedXMLParser.swift`, `JSONFeedParser.swift`, `DateParser.swift`: feed parsing.
- `IPAddressValidator.swift`: SSRF/IP validation.
- `OPMLManager.swift`: OPML portability.
- `RefreshCoordinator.swift`: refresh lifecycle.

### Content / intelligence
- `ContentExtractionPipeline.swift`, `WebContentExtractor.swift`: article content extraction.
- `ArticleIntelligence.swift`: article classification, sentiment, entities, summarization and content-cleaning capabilities.
- `EnrichmentQueue.swift`: actor-isolated background enrichment scheduling.
- `AIManager.swift`: compatibility adapter into `ArticleIntelligence`.
- Current intelligence code uses `NaturalLanguage` and conditionally `FoundationModels`, with typed `@Generable` outputs and a fixed 12-category taxonomy.

### Platform / distribution
- `News.entitlements`: sandbox/runtime capabilities.
- `build.sh`, `build_release.sh`, `package_dmg.sh`, `notarize.sh`, `test.sh`: build, release, packaging and validation pipeline.
- `.github/workflows/ci.yml`: CI.
- `PRIVACY.md`, `SECURITY.md`: privacy/security commitments.

## Product behavior priorities
1. Correctness of article classification is more important than aggressive enrichment.
2. RSS ingestion should remain inexpensive. Do not automatically perform expensive full article extraction/AI analysis on every item unless the product behavior explicitly calls for it.
3. Full summarization/key-point extraction should generally happen when the user chooses to inspect an article in detail or under a clearly defined, user-controlled background policy.
4. The UI should remain responsive during network, database, extraction, and intelligence work.
5. Persist only information necessary for the user's reading experience and product behavior.
6. Respect user settings immediately and consistently across fetch, notification, enrichment, and UI behavior.

## AI constraints
- Apple-native intelligence frameworks only.
- No custom model downloads, no external model providers, no OpenAI/Anthropic/Gemini/etc. APIs, no hosted inference.
- Use FoundationModels on supported systems where appropriate.
- Use NaturalLanguage and deterministic logic as native fallbacks where appropriate.
- Keep structured outputs constrained to the supported taxonomy/schema.
- Never silently substitute a different model/provider.
- Store model/version metadata needed to invalidate stale analysis.

## Performance expectations
- Swift concurrency must remain Swift 6-safe.
- Do not perform heavy SQLite/network work on the main actor.
- Keep background concurrency bounded.
- Make cancellation meaningful.
- Avoid retaining article bodies or large extracted documents longer than needed.
- Watch for timer/task/NotificationCenter/WebKit lifecycle leaks.
- Prefer incremental processing over repeatedly scanning the whole database.

## UX / Liquid Glass expectations
The visual target is a polished native macOS app, not generic cross-platform glassmorphism. Use semantic materials, native controls, proper vibrancy/contrast, and the existing design system. Avoid fake glass implemented through layers of arbitrary opacity, excessive blur, or hard-coded geometry.

Important UI qualities:
- consistent spacing/radius/typography tokens
- native toolbar/sidebar behavior
- keyboard navigation and shortcuts remain discoverable
- accessible labels for icon-only controls
- reduced-motion friendliness
- correct focus behavior
- dark/light appearance consistency
- no clipping or layout behavior tied to one screen size

## Security / privacy expectations
Feed and article URLs are hostile input. Preserve all existing SSRF and redirect defenses. Do not weaken sandboxing. Avoid leaking user/article content into logs. Do not introduce telemetry merely to diagnose a problem.

## Release expectations
The project targets Universal 2 distribution and Hardened Runtime signing. Release changes should preserve both Apple Silicon and Intel support where the current build configuration supports them. Do not casually raise the deployment target or add entitlements.

## Known historical issues
`PROJECT_REVIEW.md` documents previously identified areas such as settings wiring, background fetch cadence, feature flags, history behavior, service decomposition, deterministic parsing/categorization tests, loading/error states, URL identity stability, enrichment resource controls, accessibility, and security hardening. Treat that file as historical context, not permission to implement every recommendation blindly.

## How Jules should approach a task
Inspect the relevant files and existing abstractions first. Reuse the established path. Prefer a small coherent change over a broad rewrite. Add tests for behavior changes. Run the repository's validation scripts when the environment supports them. Review the resulting diff for concurrency, memory, security, accessibility, and regression risks before finishing.
