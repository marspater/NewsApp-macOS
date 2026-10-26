# Architecture Overview

Examine the architectural layers, orchestration services, and concurrency model of News.

## Overview

News is architected into five distinct decoupled layers conforming strictly to Swift 6 complete concurrency checks:

1. **Coordinators (`Sources/Coordinators`)**: High-level orchestration services like ``FeedManager`` and `NotificationService` that oversee lifecycle, periodic refreshes, sleep/wake cycles, and user notifications.
2. **Views (`Sources/Views`)**: Pixel-perfect SwiftUI and AppKit views conforming to Apple Human Interface Guidelines and the project's design language (`docs/DESIGN.md`). Includes the Situation Board (``BriefingView``), ``ArticleListView``, reader modernizations (``ArticleDetailView``), and event overviews (``EventOverviewReaderView``).
3. **Intelligence (`Sources/Intelligence`)**: Bounded on-device NLP services including ``ArticleClassifier``, ``ArticleAnalyzer``, ``CoverageSentimentEvaluator``, and ``WorldTension``.
4. **Services (`Sources/Services`)**: Low-level networking, parsers (``FeedXMLParser``, ``JSONFeedParser``), and security boundaries (``SecureHTTPClient``).
5. **Storage (`Sources/Storage`)**: Local SQLite persistence (``DatabaseEngine``) with Write-Ahead Logging (WAL), full-text search (FTS5), and observable reactive view stores (``ArticleStore``).

## Concurrency Guarantees

All view coordination and observable state classes are strictly isolated with `@MainActor`. Asynchronous parsing, database mutations, and network operations execute on background tasks or dedicated actors, ensuring zero main thread stalls during heavy feed refreshes.
