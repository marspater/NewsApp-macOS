# Architecture and data flow

Follow one refresh from a due feed to a published library snapshot, and see which layer owns what.

## Overview

The source tree is divided by responsibility, and `News.xcodeproj` compiles it through synchronized folders, so a new Swift file needs no project entry.

| Folder | Owns |
|---|---|
| `Sources/App` | ``NewsApp`` scenes and commands, ``AppContainer`` dependency injection, ``AppSettings`` |
| `Sources/Coordinators` | ``FeedManager`` orchestration and lifecycle, ``NotificationService`` triage |
| `Sources/Services` | ``FeedFetcher``, ``SecureHTTPClient``, parsers, the ``NetworkBoundaryProxy`` gateway |
| `Sources/Storage` | ``DatabaseEngine`` schema and SQL, ``ArticleStore``, ``MigrationCoordinator``, ``CacheManager`` |
| `Sources/Intelligence` | ``ContentExtractionPipeline``, ``EnrichmentQueue``, ``EventClusterer``, ``EventMatcher``, overviews, World Tension |
| `Sources/Models` | ``FeedArticle``, ``FeedCatalog``, ``MuteRules``, ``FiniteBriefing``, overview documents |
| `Sources/Views` | ``MainView`` and every other SwiftUI surface |

Views hold no database or networking logic, and database work stays off the main actor.

### One refresh

``FeedManager`` starts a refresh from its timer, background activity, wake from sleep or a manual command.

1. ``FeedFetcher`` requests the due feeds, with at most six requests in flight and at most two per host. Requests are conditional, so an unchanged feed costs a 304.
2. ``FeedXMLParser`` or ``JSONFeedParser`` turns each body into articles, inside bounds that treat the input as untrusted.
3. ``DatabaseEngine`` commits one transaction per feed, holding its articles and validators together.
4. ``FeedManager`` publishes one library snapshot. The refresh ends here.

Follow-up work never holds the refresh or its loading state: ``NotificationService`` triages the new stories, ``EnrichmentQueue`` classifies under bounded rules, and ``EventClusterer`` runs a clustering pass off the main actor, after which ``StoryCurator`` looks up missing lead images.

### Opening a story

The reader asks ``ContentExtractionPipeline`` for the page only when a story is opened and its stored text is not enough. The page arrives through ``SecureHTTPClient``, is scored and repaired with SwiftSoup, and is stored as a reader document. Ingestion itself stays cheap: extraction and analysis run on demand or under the enrichment rules.

### Storage

The library is one SQLite file in WAL mode with FTS5 search. Changes ship as migrations up to ``DatabaseEngine/schemaVersion``. Before the first step, an existing library is copied beside itself; if the copy fails, or the library comes from a newer build, it opens read-only. Read history, saved stories and settings survive every migration.

Stored article IDs never change when publisher metadata does. An article belongs to at most one event, and events never copy source text.

## Topics

### Orchestration

- ``FeedManager``
- ``NotificationService``
- ``AppContainer``

### Storage

- ``DatabaseEngine``
- ``ArticleStore``
- ``MigrationCoordinator``
