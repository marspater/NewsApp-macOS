# ``News``

A native, local-first RSS, Atom, and JSON Feed reader for macOS Sequoia.

## Overview

News is an open, high-performance feed reader and news intelligence application engineered in Swift 6. It combines an editorial presentation with deterministic on-device intelligence, strict user privacy, and Apple platform citizenship.

### Key Capabilities

- **Situation Board & Briefing**: A focused daily edition featuring an auto-advancing 45-second hero carousel, World Tension trendlines, and dense categorized story tiles (Epic R).
- **Event Clustering**: Deterministic lexical and embedding-based grouping of stories into cohesive multi-source events with timeline overviews and diverse perspectives.
- **Local-First SQLite Engine**: All feed subscriptions, articles, read state, bookmarks, and full-text search indexes reside in local SQLite storage using WAL mode and FTS5.
- **On-Device Machine Learning**: Topic classification, entity extraction, and summarization run on-device via Apple's `NaturalLanguage` and `FoundationModels` frameworks with zero cloud AI telemetry.
- **Security Boundary**: An ephemeral loopback proxy bound strictly to `127.0.0.1` that validates resolved addresses and pins connections to numeric public endpoints, preventing SSRF and DNS rebinding attacks.

## Topics

### Architecture & Conceptual Guides
- <doc:ArchitectureOverview>
- <doc:SituationBoardGuide>
- <doc:OnDeviceIntelligence>
- <doc:LocalPrivacySecurity>

### Application Essentials
- ``AppContainer``
- ``AppSettings``
- ``AppDelegate``
- ``ThemeManager``

### Situation Board & User Interface
- ``BriefingView``
- ``BriefingHeroCarouselView``
- ``BriefingTileView``
- ``BriefingTensionStripView``
- ``ArticleListView``
- ``ArticleDetailView``
- ``EventOverviewReaderView``
- ``TensionIndexView``

### Feed Ingestion & Parsing
- ``FeedManager``
- ``FeedFetcher``
- ``FeedXMLParser``
- ``JSONFeedParser``
- ``SecureHTTPClient``

### Storage & Data Management
- ``DatabaseEngine``
- ``ArticleStore``
- ``SavedStoriesManager``
- ``CacheManager``
- ``SpotlightIndexer``

### On-Device Intelligence & NLP
- ``CoverageSentimentEvaluator``
- ``ArticleAnalyzer``
- ``ArticleClassifier``
- ``EnrichmentQueue``
- ``WorldTension``

### System Integration & Utilities
- ``NewsURLParser``
- ``NotificationActionRouter``
- ``UpdateChecker``
- ``CarouselClock``
- ``BriefingCitedFact``
