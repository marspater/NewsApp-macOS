import Foundation
import SwiftUI
import os

/// High-level, observable application store managing article persistence,
/// reactive UI state, full-text search, and legacy migration.
@MainActor
final class ArticleStore: ObservableObject {
    static let shared = ArticleStore()
    private let logger = Logger(subsystem: "com.marspater.news", category: "ArticleStore")
    
    let database: DatabaseEngine
    let migrationCoordinator: MigrationCoordinator
    
    @Published private(set) var articles: [FeedArticle] = []
    @Published private(set) var savedArticles: [FeedArticle] = []
    @Published private(set) var readArticleIDs: Set<String> = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var savedCount: Int = 0
    @Published private(set) var isReady: Bool = false
    
    init(database: DatabaseEngine? = nil) {
        let db = database ?? DatabaseEngine.shared
        self.database = db
        self.migrationCoordinator = MigrationCoordinator(database: db)
        
        Task {
            await initialize()
        }
    }
    
    func initialize() async {
        do {
            try await database.open()
            _ = try await migrationCoordinator.migrateIfNeeded()
            await refreshState()
            self.isReady = true
        } catch {
            logger.error("Failed to initialize ArticleStore: \(error.localizedDescription)")
        }
    }
    
    func refreshState() async {
        do {
            let fetched = try await database.fetchArticles(limit: 500)
            let readIDs = try await database.getReadArticleIDs()
            let saved = try await database.getSavedArticles()
            let counts = try await database.counts()
            
            self.articles = fetched
            self.readArticleIDs = readIDs
            self.savedArticles = saved
            self.unreadCount = counts.unread
            self.savedCount = counts.saved
        } catch {
            logger.error("Failed to refresh ArticleStore state: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Article Ingestion & Upsert
    
    func batchUpsert(articles newArticles: [FeedArticle], feedUrl: String? = nil) async {
        guard !newArticles.isEmpty else { return }
        do {
            try await database.upsertArticles(newArticles, feedUrl: feedUrl)
            await refreshState()
        } catch {
            logger.error("Failed to batch upsert articles: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Article Queries & Search
    
    func fetchArticles(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        limit: Int? = 500
    ) async -> [FeedArticle] {
        do {
            return try await database.fetchArticles(section: section, isRead: isRead, isSaved: isSaved, limit: limit)
        } catch {
            logger.error("Failed to fetch articles: \(error.localizedDescription)")
            return []
        }
    }
    
    func search(query: String, limit: Int = 100) async -> [FeedArticle] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return articles
        }
        let signpostState = NewsSignposts.begin(NewsSignposts.database, name: "FTSSearch", metadata: "limit=\(limit)")
        defer { NewsSignposts.end(NewsSignposts.database, name: "FTSSearch", state: signpostState) }

        do {
            return try await database.searchArticles(query: query, limit: limit)
        } catch {
            logger.error("Failed to search articles via FTS: \(error.localizedDescription)")
            // Fallback to in-memory filter
            let lower = query.lowercased()
            return articles.filter {
                $0.title.lowercased().contains(lower) ||
                $0.description.lowercased().contains(lower) ||
                $0.source.lowercased().contains(lower)
            }
        }
    }
    
    // MARK: - Read & Saved State Management
    
    func isRead(_ id: String) -> Bool {
        readArticleIDs.contains(id)
    }
    
    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticles.contains { $0.id == article.id }
    }
    
    func markAsRead(id: String, isRead: Bool = true) async {
        do {
            try await database.markRead(articleId: id, isRead: isRead)
            if isRead {
                readArticleIDs.insert(id)
            } else {
                readArticleIDs.remove(id)
            }
            let counts = try await database.counts()
            self.unreadCount = counts.unread
        } catch {
            logger.error("Failed to mark article read: \(error.localizedDescription)")
        }
    }
    
    func toggleRead(id: String) async {
        let current = isRead(id)
        await markAsRead(id: id, isRead: !current)
    }
    
    func markAllAsRead(feedUrl: String? = nil) async {
        do {
            try await database.markAllRead(feedUrl: feedUrl)
            await refreshState()
        } catch {
            logger.error("Failed to mark all as read: \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    func toggleSave(article: FeedArticle) async -> Bool {
        do {
            try await database.upsertArticles([article], feedUrl: nil)
            let nextState = try await database.toggleSaved(articleId: article.id)
            if nextState {
                if !savedArticles.contains(where: { $0.id == article.id }) {
                    savedArticles.insert(article, at: 0)
                }
            } else {
                savedArticles.removeAll { $0.id == article.id }
            }
            let counts = try await database.counts()
            self.savedCount = counts.saved
            return nextState
        } catch {
            logger.error("Failed to toggle save: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Enrichment
    
    func updateEnrichment(
        id: String,
        summary: String? = nil,
        category: String? = nil,
        sentiment: Double? = nil,
        entities: [String]? = nil,
        topics: [String]? = nil,
        content: String? = nil,
        image: String? = nil
    ) async {
        do {
            try await database.updateEnrichment(
                articleId: id,
                summary: summary,
                category: category,
                sentiment: sentiment,
                entities: entities,
                topics: topics,
                content: content,
                image: image
            )
            
            // Update in-memory articles array
            if let idx = articles.firstIndex(where: { $0.id == id }) {
                var updated = articles[idx]
                if let s = summary { updated.aiSummary = s }
                if let c = content {
                    updated.fullContent = c
                    updated.contentFetched = true
                }
                if let img = image, updated.imageUrl == nil {
                    updated.imageUrl = img
                }
                articles[idx] = updated
            }
        } catch {
            logger.error("Failed to update enrichment: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Structured Article Analysis
    
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String) async {
        do {
            try await database.saveArticleAnalysis(analysis, for: articleId)
            if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                var updated = articles[idx]
                updated.aiSummary = analysis.summary
                updated.keyPoints = analysis.keyPoints
                updated.entities = analysis.entities
                if let s = analysis.sentiment {
                    updated.sentimentScore = s.score
                    updated.sentimentLabel = s.label
                }
                if let cat = analysis.category {
                    updated.category = cat
                }
                articles[idx] = updated
            }
        } catch {
            logger.error("Failed to save article analysis: \(error.localizedDescription)")
        }
    }
    
    func fetchArticleAnalysis(for articleId: String) async -> ArticleAnalysis? {
        await database.fetchArticleAnalysis(for: articleId)
    }

    // MARK: - Granular Cache Purging

    /// Purges all generated AI analysis data while preserving articles and subscriptions.
    func clearAIAnalysis() async {
        do {
            try await database.clearArticleEnrichment()
            await refreshState()
            logger.info("Cleared all AI analysis in ArticleStore.")
        } catch {
            logger.error("Failed to clear AI analysis: \(error.localizedDescription)")
        }
    }

    /// Clears cached full article content while preserving subscriptions, saved stories, and read history.
    func clearArticleCache() async {
        do {
            try await database.clearArticleCache()
            await refreshState()
            logger.info("Cleared article cache in ArticleStore.")
        } catch {
            logger.error("Failed to clear article cache: \(error.localizedDescription)")
        }
    }

    /// Completely purges all cached articles, state, and enrichment while preserving feeds.
    func clearAllDatabaseCache() async {
        do {
            try await database.clearAllDatabaseCache()
            await refreshState()
            logger.info("Cleared all database cache in ArticleStore.")
        } catch {
            logger.error("Failed to clear all database cache: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Retention Pruning
    
    @discardableResult
    func pruneOldArticles(keepReadDays: Int = 30) async -> Int {
        do {
            let count = try await database.pruneOldArticles(keepReadDays: keepReadDays)
            if count > 0 {
                await refreshState()
            }
            return count
        } catch {
            logger.error("Failed to prune old articles: \(error.localizedDescription)")
            return 0
        }
    }
}
