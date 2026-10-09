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
    let migrationCoordinator: MigrationCoordinator?
    
    @Published private(set) var articles: [FeedArticle] = []
    @Published private(set) var savedArticles: [FeedArticle] = []
    @Published private(set) var readArticleIDs: Set<String> = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var savedCount: Int = 0
    @Published private(set) var isReady: Bool = false
    
    @Published private(set) var revision: UInt64 = 0
    /// Bumped when clustering or the reader changes events; the feed regroups on it.
    @Published private(set) var eventRevision: UInt64 = 0
    @Published var operationError: String?

    init(database: DatabaseEngine? = nil, migrationCoordinator: MigrationCoordinator? = nil) {
        let db = database ?? DatabaseEngine.shared
        self.database = db
        self.migrationCoordinator = migrationCoordinator ?? (database == nil ? MigrationCoordinator(database: db) : nil)
        
        Task {
            await initialize()
        }
    }
    
    func initialize() async {
        do {
            try await database.open()
            _ = try await migrationCoordinator?.migrateIfNeeded()
            // Overviews and summaries from an earlier macOS model regenerate with the current one when next requested.
            // Only the app's own library tracks this; stores over other databases (tests, audits) are left as they are.
            if database === DatabaseEngine.shared {
                do {
                    try await database.reconcileModelGeneration(NewsTextModel.generation)
                } catch {
                    logger.error("Model generation check failed: \(error.localizedDescription)")
                }
            }
            self.isReady = await refreshState()
            if !isReady { operationError = "Stored articles could not be loaded. Please try again." }
        } catch {
            isReady = false
            operationError = "Article storage could not be opened. Please try again."
            logger.error("Failed to initialize ArticleStore: \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    func refreshState() async -> Bool {
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
            revision &+= 1
            return true
        } catch {
            logger.error("Failed to refresh ArticleStore state: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Article Ingestion & Upsert
    
    @discardableResult
    func batchUpsert(articles newArticles: [FeedArticle], feedUrl: String? = nil, validators: FeedValidators? = nil) async -> Set<String> {
        guard !newArticles.isEmpty else { return [] }
        do {
            let insertedIDs = try await database.upsertArticles(newArticles, feedUrl: feedUrl, validators: validators)
            await refreshState()
            return insertedIDs
        } catch is CancellationError {
            // Superseded refreshes must not publish stale snapshots.
        } catch {
            operationError = "Could not store fetched articles. Please try again."
            logger.error("Failed to batch upsert articles: \(error.localizedDescription)")
        }
        return []
    }
    
    // MARK: - Article Queries & Search
    
    func fetchArticles(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        limit: Int? = 500
    ) async throws -> [FeedArticle] {
        try await database.fetchArticles(section: section, isRead: isRead, isSaved: isSaved, limit: limit)
    }

    struct NavigationRequest: Equatable, Sendable {
        let token = UUID()
        let articleID: String?
        let link: String
    }

    @Published var pendingNavigation: NavigationRequest?

    func articleForNavigation(_ request: NavigationRequest) async throws -> FeedArticle? {
        if let id = request.articleID,
           let article = try await database.fetchArticles(limit: 1, id: id).first {
            return article
        }
        let link = ArticleIdentity.canonicalizeURL(request.link)
        guard !link.isEmpty else { return nil }
        return try await database.fetchArticles(limit: 1, canonicalURL: link).first
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
            let id = try await database.resolvedArticleID(id)
            try await database.markRead(articleId: id, isRead: isRead)
            if isRead {
                readArticleIDs.insert(id)
            } else {
                readArticleIDs.remove(id)
            }
            let counts = try await database.counts()
            self.unreadCount = counts.unread
            revision &+= 1
        } catch {
            operationError = "Could not save reading status. Please try again."
            await refreshState()
            logger.error("Failed to mark article read: \(error.localizedDescription)")
        }
    }
    
    func toggleRead(id: String) async {
        do {
            let id = try await database.resolvedArticleID(id)
            await markAsRead(id: id, isRead: !isRead(id))
        } catch {
            operationError = "Could not save reading history. Please try again."
            logger.error("Failed to resolve article read state: \(error.localizedDescription)")
        }
    }
    
    func markAllAsRead(feedUrl: String? = nil) async {
        do {
            try await database.markAllRead(feedUrl: feedUrl)
            await refreshState()
        } catch {
            operationError = "Could not mark articles as read. Please try again."
            logger.error("Failed to mark all as read: \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    func toggleSave(article: FeedArticle) async -> Bool {
        do {
            let id = try await database.resolvedArticleID(for: article)
            let nextState = try await !database.isSaved(articleId: id)
            return await setSaved(article: article, isSaved: nextState)
        } catch {
            operationError = "Could not update Saved Stories. Please try again."
            logger.error("Failed to resolve article saved state: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func setSaved(article: FeedArticle, isSaved nextState: Bool) async -> Bool {
        await setSaved(articles: [article], isSaved: nextState)
    }

    @discardableResult
    func setSaved(articles: [FeedArticle], isSaved nextState: Bool) async -> Bool {
        guard !articles.isEmpty else { return true }
        do {
            _ = try await database.upsertArticles(articles, preservingStoredContent: true)
            var storedArticles = [FeedArticle]()
            for article in articles {
                let id = try await database.resolvedArticleID(for: article)
                if let storedArticle = try await database.fetchArticles(limit: 1, id: id).first {
                    storedArticles.append(storedArticle)
                }
            }
            try await database.setSaved(articleIds: storedArticles.map { $0.id }, isSaved: nextState)
            if nextState {
                for storedArticle in storedArticles {
                    if !savedArticles.contains(where: { $0.id == storedArticle.id }) {
                        savedArticles.insert(storedArticle, at: 0)
                    }
                }
            } else {
                let idsToRemove = Set(storedArticles.map { $0.id })
                savedArticles.removeAll { idsToRemove.contains($0.id) }
            }
            let counts = try await database.counts()
            self.savedCount = counts.saved
            revision &+= 1
            return nextState
        } catch {
            operationError = "Could not update Saved Stories. Please try again."
            await refreshState()
            logger.error("Failed to toggle save: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Enrichment
    
    @discardableResult
    func updateEnrichment(
        id: String,
        summary: String? = nil,
        category: String? = nil,
        sentiment: Double? = nil,
        entities: [String]? = nil,
        topics: [String]? = nil,
        content: String? = nil,
        image: String? = nil,
        readerDocument: ReaderDocument? = nil,
        identityEvidence: DocumentIdentityEvidence? = nil,
        expectedInputHash: String? = nil
    ) async -> Bool {
        do {
            let id = try await database.resolvedArticleID(id)
            guard try await database.updateEnrichment(
                articleId: id,
                update: .init(summary: summary, category: category, sentiment: sentiment,
                              entities: entities, topics: topics, content: content,
                              image: image, readerDocument: readerDocument, expectedInputHash: expectedInputHash)
            ) else { return false }
            if let identityEvidence {
                do { try await database.recordDocumentIdentity(identityEvidence, articleID: id) }
                catch { logger.error("Failed to record document identity: \(error.localizedDescription)") }
            }
            try await publishStoredArticle(id)
            return true
        } catch {
            logger.error("Failed to update enrichment: \(error.localizedDescription)")
            return false
        }
    }

    /// Hydrate the persisted result, including fields invalidated by publisher-input changes.
    private func publishStoredArticle(_ id: String) async throws {
        guard let updated = try await database.fetchArticles(limit: 1, id: id).first else { return }
        if let index = articles.firstIndex(where: { $0.id == id }) { articles[index] = updated }
        if let index = savedArticles.firstIndex(where: { $0.id == id }) { savedArticles[index] = updated }
        revision &+= 1
    }

    // MARK: - Structured Article Analysis

    @discardableResult
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String, expectedInputHash: String? = nil) async -> Bool {
        do {
            let articleId = try await database.resolvedArticleID(articleId)
            guard try await database.saveArticleAnalysis(analysis, for: articleId, expectedInputHash: expectedInputHash) else { return false }
            try await publishStoredArticle(articleId)
            return true
        } catch {
            logger.error("Failed to save article analysis: \(error.localizedDescription)")
            return false
        }
    }

    func fetchArticleAnalysis(for articleId: String) async -> ArticleAnalysis? {
        await database.fetchArticleAnalysis(for: articleId)
    }

    // MARK: - Granular Cache Purging

    /// Purges all generated AI analysis data while preserving articles and subscriptions.
    func clearAIAnalysis() async throws {
        try await database.clearArticleEnrichment()
        await refreshState()
    }

    /// Clears cached full article content while preserving subscriptions, saved stories, and read history.
    func clearArticleCache() async throws {
        try await database.clearArticleCache()
        await refreshState()
    }

    /// Clears replaceable caches while preserving subscriptions, history and saved bodies.
    func clearAllDatabaseCache() async throws {
        try await database.clearAllDatabaseCache()
        await refreshState()
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

    // MARK: - Events

    func noteEventsChanged() {
        eventRevision &+= 1
    }

    func eventFeedSummaries(for articleIDs: [String]) async throws -> [EventFeedSummary] {
        try await database.eventFeedSummaries(forArticles: articleIDs)
    }

    func eventMemberArticles(eventID: String) async throws -> [FeedArticle] {
        try await database.fetchArticles(limit: nil, eventID: eventID)
    }

    /// Records the event version the reader has seen. Article read and saved state stay as they are.
    func markEventSeen(_ eventID: String) async {
        do {
            let before = try await database.eventSeenVersion(eventID)
            if try await database.markEventSeen(eventID) != before { eventRevision &+= 1 }
        } catch {
            logger.error("Failed to record event reading state: \(error.localizedDescription)")
        }
    }

    /// "These are different events": a local exclusion that later refreshes and passes respect.
    @discardableResult
    func separateArticle(_ articleID: String, fromEvent eventID: String) async -> Bool {
        do {
            try await database.separateArticle(articleID, fromEvent: eventID)
            eventRevision &+= 1
            return true
        } catch {
            operationError = "This article could not be separated from the event. Please try again."
            logger.error("Failed to separate article from event: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Event Overviews

    @discardableResult
    func recordVerifiedOverview(
        _ document: EventOverviewDocument,
        passages: [EvidencePassage],
        articles: [FeedArticle]
    ) async throws -> (saved: Bool, document: EventOverviewDocument) {
        try await database.recordVerifiedOverview(document, passages: passages, articles: articles)
    }

    @discardableResult
    func recordEventOverview(_ document: EventOverviewDocument, expectedArticleInputs: [String: String]? = nil) async throws -> Bool {
        try await database.recordEventOverview(document, expectedArticleInputs: expectedArticleInputs)
    }

    func fetchEventOverview(eventID: String) async throws -> EventOverviewDocument? {
        try await database.fetchEventOverview(eventID: eventID)
    }

    func fetchEventOverview(forArticleID articleID: String) async throws -> EventOverviewDocument? {
        try await database.fetchEventOverview(forArticleID: articleID)
    }

    @discardableResult
    func deleteEventOverview(eventID: String) async throws -> Bool {
        try await database.deleteEventOverview(eventID: eventID)
    }
}

