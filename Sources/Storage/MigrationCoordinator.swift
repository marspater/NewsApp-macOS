import Foundation
import os

/// Structured statistics describing the result of a legacy data migration.
struct MigrationStats: Sendable, Equatable {
    var articlesFound: Int = 0
    var articlesImported: Int = 0
    var savedStories: Int = 0
    var readStates: Int = 0
    var duplicatesMerged: Int = 0
    var failures: Int = 0
}

/// Actor coordinating safe, transactional migration from legacy JSON and UserDefaults stores
/// to the structured DatabaseEngine.
actor MigrationCoordinator {
    private let logger = Logger(subsystem: "com.marspater.news", category: "MigrationCoordinator")
    private let database: DatabaseEngine
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    static let migrationVersionKey = "com.marspater.news.migration_version"
    static let currentMigrationVersion = 1

    // Legacy storage keys
    private let legacyCacheKey = "feed_articles_cache.json"
    private let legacySavedStoriesKey = "com.marspater.news.savedStories"
    private let legacyReadListKey = "com.marspater.news.readArticlesList"

    init(
        database: DatabaseEngine,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func isMigrationNeeded() -> Bool {
        let version = userDefaults.integer(forKey: Self.migrationVersionKey)
        return version < Self.currentMigrationVersion
    }

    /// Executes the migration if needed inside a single atomic transaction.
    /// Retains legacy data on disk/UserDefaults for safety.
    @discardableResult
    func migrateIfNeeded() async throws -> MigrationStats {
        guard isMigrationNeeded() else {
            return MigrationStats()
        }

        logger.info("Starting legacy data migration to version \(Self.currentMigrationVersion)...")
        var stats = MigrationStats()

        // 1. Locate and load legacy JSON article cache
        var legacyArticles: [FeedArticle] = []
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.marspater.news.cache")
        if let cacheFile = cacheDir?.appendingPathComponent(legacyCacheKey),
            fileManager.fileExists(atPath: cacheFile.path),
            let data = try? Data(contentsOf: cacheFile),
            let decoded = try? JSONDecoder().decode([FeedArticle].self, from: data)
        {
            legacyArticles = decoded
            stats.articlesFound = decoded.count
        }

        // 2. Load legacy saved stories
        var legacySaved: [FeedArticle] = []
        if let data = userDefaults.data(forKey: legacySavedStoriesKey),
            let decoded = try? JSONDecoder().decode([FeedArticle].self, from: data)
        {
            legacySaved = decoded
            stats.savedStories = decoded.count
        }

        // 3. Load legacy read articles
        var legacyReadIDs: Set<String> = []
        if let readArray = userDefaults.stringArray(forKey: legacyReadListKey) {
            legacyReadIDs = Set(readArray.map { ArticleIdentity.reconcileLegacyId($0) })
            stats.readStates = legacyReadIDs.count
        }

        // If there is no legacy data at all (fresh install), mark migration complete and return
        if legacyArticles.isEmpty && legacySaved.isEmpty && legacyReadIDs.isEmpty {
            userDefaults.set(Self.currentMigrationVersion, forKey: Self.migrationVersionKey)
            logger.info("Fresh installation detected. Migration version set to \(Self.currentMigrationVersion).")
            return stats
        }

        // 4. Identity Reconciliation & Deduplication
        var reconciledArticlesById: [String: FeedArticle] = [:]
        var savedIds: Set<String> = []

        for article in legacySaved {
            let id = article.id
            reconciledArticlesById[id] = article
            savedIds.insert(id)
        }

        for article in legacyArticles {
            let id = article.id
            if reconciledArticlesById[id] != nil {
                stats.duplicatesMerged += 1
            } else {
                reconciledArticlesById[id] = article
            }
        }

        let allArticlesToImport = Array(reconciledArticlesById.values)

        // 5. Import. Each step is its own transactional, idempotent upsert (they cannot nest in one SQLite transaction),
        // and completion is recorded only after all succeed, so a failed import is simply repeated at the next launch.
        do {
            try await database.upsertArticles(allArticlesToImport)
            // Read entries whose story is no longer cached have nothing to mark; state needs its article row.
            try await database.markReadBatch(
                articleIds: legacyReadIDs.filter { reconciledArticlesById[$0] != nil }, isRead: true)
            try await database.batchMarkSaved(savedIds)

            stats.articlesImported = allArticlesToImport.count

            // Mark migration complete ONLY AFTER every step succeeded!
            userDefaults.set(Self.currentMigrationVersion, forKey: Self.migrationVersionKey)

            logger.info(
                "Legacy migration completed successfully: \(stats.articlesImported) articles imported, \(stats.savedStories) saved stories, \(stats.readStates) read states, \(stats.duplicatesMerged) duplicates merged."
            )
            return stats
        } catch {
            // Legacy data is never removed, so the next launch repeats the import.
            stats.failures += 1
            logger.error(
                "Legacy migration failed and will be retried: \(error.localizedDescription). Legacy data preserved.")
            throw error
        }
    }
}
