import Combine
import Foundation
import SwiftUI
import os

/// High-level, observable application store managing article persistence,
/// reactive UI state, full-text search, and legacy migration.
@MainActor
final class ArticleStore: ObservableObject {
    static let shared = ArticleStore()
    let logger = Logger(subsystem: "com.marspater.news", category: "ArticleStore")

    let database: DatabaseEngine
    let migrationCoordinator: MigrationCoordinator?
    /// Runs after a clear of derived data and before the clear returns, so the queues and caches that hold session
    /// state about that data (the enrichment queue, the overview coordinator) have reset by then (#805).
    var analysisClearedHandler: (@MainActor () async -> Void)?
    let spotlightIndexer: any SpotlightIndexing

    @Published private(set) var articles: [FeedArticle] = []
    @Published private(set) var savedArticles: [FeedArticle] = []
    @Published private(set) var savedArticleIDs: Set<String> = []
    @Published private(set) var readArticleIDs: Set<String> = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var savedCount: Int = 0
    @Published private(set) var isReady: Bool = false
    /// The reader's mute rules; `unreadCount` leaves out the stories they hide, as the Unread list does (#785).
    private(set) var muting = MuteRules()
    private var muteObservation: AnyCancellable?
    /// Numbers every count request, mute-rule changes included; only the latest request's result is published, so
    /// neither older rules nor an older count that finishes last can overwrite a newer one.
    private var countSequence = 0
    private func newCountRequest() -> Int {
        countSequence &+= 1
        return countSequence
    }

    @Published private(set) var revision: UInt64 = 0
    /// Bumped when clustering or the reader changes events; the feed regroups on it.
    @Published var eventRevision: UInt64 = 0
    /// Bumped when an event overview is stored; the Briefing reloads its cited facts on it.
    @Published var overviewRevision: UInt64 = 0
    @Published var operationError: String?
    @Published private(set) var databaseHealthNotice: String?

    init(
        database: DatabaseEngine? = nil,
        migrationCoordinator: MigrationCoordinator? = nil,
        spotlightIndexer: any SpotlightIndexing = SystemSpotlightIndexer.shared
    ) {
        let db = database ?? DatabaseEngine.shared
        self.database = db
        self.migrationCoordinator = migrationCoordinator ?? (database == nil ? MigrationCoordinator(database: db) : nil)
        self.spotlightIndexer = spotlightIndexer
        if database == nil {
            muting = AppSettings.shared.muteRules
            // Applied synchronously, in the order the rules change; only the recount is a task.
            muteObservation = AppSettings.shared.$muteRules.dropFirst().sink { [weak self] rules in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyMuting(rules)
                    Task { await self.recountUnread() }
                }
            }
        }

        startup = Task {
            await initialize()
        }
    }

    /// The task the initializer started; it ends when the library has opened or failed to, ready or not.
    private var startup: Task<Void, Never>?

    /// Resolves once the startup open has finished, so the health notice is settled. A damaged library never
    /// becomes `isReady`, so callers wait on this instead.
    func waitForStartup() async {
        await startup?.value
    }

    func initialize() async {
        do {
            try await database.open()
            self.databaseHealthNotice = await database.databaseHealthNotice()
            if self.databaseHealthNotice == nil {
                _ = try await migrationCoordinator?.migrateIfNeeded()
                // Overviews and summaries from an earlier macOS model regenerate with the current one when next requested.
                // Only the app's own library tracks this; stores over other databases (tests, audits) are left as they are.
                if database === DatabaseEngine.shared {
                    do {
                        try await database.reconcileModelGeneration(NewsTextModel.generation)
                    } catch {
                        logger.error("Model generation check failed: \(error.localizedDescription)")
                    }
                    // The first snapshot already leaves out World Tension panel feeds the reader has not subscribed to;
                    // FeedManager keeps this current afterwards.
                    let hidden = Set(TensionMethodology.v1.panel.map(\.url)).subtracting(AppSettings.shared.feedURLs)
                    await database.setCollectionOnlyFeedURLs(Array(hidden))
                }
            }
            let loaded = await refreshState()
            self.isReady = loaded
            if !loaded { operationError = "Stored articles could not be loaded. Please try again." }
            // Only the app's own library owns the Spotlight domain; a restore relaunches into this path (#812).
            // It runs after startup is signalled, so a large saved library never delays the first refresh.
            if loaded, database === DatabaseEngine.shared {
                Task { [weak self] in await self?.rebuildSpotlightIndex() }
            }
        } catch {
            self.databaseHealthNotice = await database.databaseHealthNotice()
            isReady = false
            operationError = "Article storage could not be opened. Please try again."
            logger.error("Failed to initialize ArticleStore: \(error.localizedDescription)")
        }
    }

    /// Bumped whenever a read or save change lands in memory, so a refresh that loaded around it can tell (#786).
    private var stateChanges: UInt = 0
    /// Runs after `refreshState` has loaded and before it assigns; lets a test land a change in between.
    var refreshLoadedHook: (@MainActor () async -> Void)?

    /// Recounts unread stories under new mute rules.
    func setMuting(_ rules: MuteRules) async {
        applyMuting(rules)
        await recountUnread()
    }

    private func applyMuting(_ rules: MuteRules) {
        muting = rules
        countSequence &+= 1
    }

    /// Counts under the current rules and publishes only if they did not change meanwhile.
    private func recountUnread() async {
        let generation = newCountRequest()
        guard let counts = try? await database.counts(muting: muting), generation == countSequence else { return }
        unreadCount = counts.unread
        savedCount = counts.saved
        revision &+= 1
    }

    @discardableResult
    func refreshState() async -> Bool {
        do {
            // A read or save change that lands while this loads makes the loaded read and saved state stale: load again
            // instead of overwriting it. ponytail: three tries, then it reports failure; a retry loop with backoff if
            // changes ever arrive faster than a load.
            var published = false
            for _ in 1...3 {
                let changesAtStart = stateChanges
                let generation = newCountRequest()
                let fetched = try await database.fetchArticles(limit: 500)
                let readIDs = try await database.getReadArticleIDs()
                let saved = try await database.getSavedArticles()
                let counts = try await database.counts(muting: muting)
                await refreshLoadedHook?()
                self.articles = fetched
                guard changesAtStart == stateChanges else { continue }
                self.readArticleIDs = readIDs
                self.savedArticles = saved
                self.savedArticleIDs = Set(saved.map { $0.id })
                if generation == countSequence {
                    self.unreadCount = counts.unread
                    self.savedCount = counts.saved
                }
                published = true
                break
            }
            revision &+= 1
            if !published { logger.error("Refresh kept being overtaken by read or save changes") }
            return published
        } catch {
            logger.error("Failed to refresh ArticleStore state: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Article Ingestion & Upsert

    @discardableResult
    func batchUpsert(
        articles newArticles: [FeedArticle], feedUrl: String? = nil, validators: FeedValidators? = nil,
        publish: Bool = true
    )
        async -> Set<String>
    {
        guard !newArticles.isEmpty || validators != nil else { return [] }
        do {
            let insertedIDs = try await database.upsertArticles(newArticles, feedUrl: feedUrl, validators: validators)
            if publish, !newArticles.isEmpty { await refreshState() }
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
            let article = try await database.fetchArticles(limit: 1, id: id).first
        {
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
                $0.title.lowercased().contains(lower) || $0.description.lowercased().contains(lower)
                    || $0.source.lowercased().contains(lower)
            }
        }
    }

    // MARK: - Read & Saved State Management

    func isRead(_ id: String) -> Bool {
        readArticleIDs.contains(id)
    }

    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticleIDs.contains(article.id)
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
            stateChanges &+= 1
            let generation = newCountRequest()
            let counts = try await database.counts(muting: muting)
            if generation == countSequence {
                self.unreadCount = counts.unread
                self.savedCount = counts.saved
            }
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

    func markAsRead(ids: [String]) async {
        do {
            try await database.markReadBatch(articleIds: ids, isRead: true)
            stateChanges &+= 1
            await refreshState()
        } catch {
            operationError = "Could not mark stories as read. Please try again."
            logger.error("Failed to mark \(ids.count) stories as read: \(error.localizedDescription)")
        }
    }

    /// Returns whether the stories were marked, so a Shortcut can report a failure.
    @discardableResult
    func markAllAsRead(feedUrl: String? = nil, muting: MuteRules = MuteRules()) async -> Bool {
        // A Shortcut can run during launch: wait for initialize to set the collection-only feeds, or panel reports
        // would be marked read and surface in History. ponytail: polls up to 10 s; await the init task if it grows.
        for _ in 0..<100 where !isReady { try? await Task.sleep(for: .milliseconds(100)) }
        guard isReady else {
            operationError = "Could not mark articles as read. Please try again."
            return false
        }
        do {
            try await database.markAllRead(feedUrl: feedUrl, muting: muting)
            stateChanges &+= 1
            await refreshState()
            return true
        } catch {
            operationError = "Could not mark articles as read. Please try again."
            logger.error("Failed to mark all as read: \(error.localizedDescription)")
            return false
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
        do {
            _ = try await database.upsertArticles([article], preservingStoredContent: true)
            let id = try await database.resolvedArticleID(for: article)
            guard let storedArticle = try await database.fetchArticles(limit: 1, id: id).first else { return false }
            try await database.setSaved(articleId: storedArticle.id, isSaved: nextState)
            stateChanges &+= 1
            if nextState {
                if !savedArticleIDs.contains(storedArticle.id) {
                    savedArticles.insert(storedArticle, at: 0)
                    savedArticleIDs.insert(storedArticle.id)
                }
                await serialSpotlight { await $0.indexSavedArticle(storedArticle) }
            } else {
                savedArticles.removeAll { $0.id == storedArticle.id }
                savedArticleIDs.remove(storedArticle.id)
                await serialSpotlight { await $0.removeSavedArticle(id: storedArticle.id) }
            }
            // Unsaving a panel-only story also hides it from the unread count.
            let generation = newCountRequest()
            let counts = try await database.counts(muting: muting)
            if generation == countSequence {
                self.unreadCount = counts.unread
                self.savedCount = counts.saved
            }
            revision &+= 1
            return nextState
        } catch {
            operationError = "Could not update Saved Stories. Please try again."
            await refreshState()
            logger.error("Failed to toggle save: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes all saved stories from the database and clears the local Spotlight saved-stories domain (#559).
    func removeAllSavedStories() async {
        let currentSaved = savedArticles
        for article in currentSaved {
            _ = try? await database.setSaved(articleId: article.id, isSaved: false)
        }
        stateChanges &+= 1
        await serialSpotlight { await $0.removeAllSavedArticles() }
        await refreshState()
    }

    var spotlightTail: Task<Void, Never>?

    // MARK: - Enrichment

    /// Background classification results not yet published; they go out together (#778).
    private var pendingPublicationIDs: Set<String> = []
    private var publicationTask: Task<Void, Never>?
    /// The latest publication; the next one waits for it, so a batch read before a newer write never lands after it.
    private var lastPublication: Task<Void, Never>?
    /// How long background classification results wait to be published together. An enrichment burst after a
    /// refresh writes hundreds of stories; publishing each one re-rendered every list, card and the open reader.
    /// Tests lengthen it and publish with `flushPendingPublications()`.
    var coalescedPublicationDelay: Duration = .seconds(1)

    /// `coalescesPublication`: background classification, published with the other results of the next second
    /// instead of at once. Writes the reader waits for publish at once.
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
        expectedInputHash: String? = nil,
        expectedGeneration: Int? = nil,
        coalescesPublication: Bool = false
    ) async -> Bool {
        do {
            let id = try await database.resolvedArticleID(id)
            guard
                try await database.updateEnrichment(
                    articleId: id,
                    update: .init(
                        summary: summary, category: category, sentiment: sentiment,
                        entities: entities, topics: topics, content: content,
                        image: image, readerDocument: readerDocument, expectedInputHash: expectedInputHash,
                        expectedGeneration: expectedGeneration)
                )
            else { return false }
            if let identityEvidence {
                do { try await database.recordDocumentIdentity(identityEvidence, articleID: id) } catch {
                    logger.error("Failed to record document identity: \(error.localizedDescription)")
                }
            }
            if coalescesPublication {
                schedulePublication([id])
            } else {
                try await publishStoredArticles([id])
            }
            return true
        } catch {
            logger.error("Failed to update enrichment: \(error.localizedDescription)")
            return false
        }
    }

    /// Publishes `ids` with every other background result of the next `coalescedPublicationDelay`. The stored rows are
    /// read when the batch goes out, so the published state is the latest one.
    private func schedulePublication(_ ids: some Sequence<String>) {
        pendingPublicationIDs.formUnion(ids)
        guard publicationTask == nil, !pendingPublicationIDs.isEmpty else { return }
        publicationTask = Task { [weak self] in
            guard let delay = self?.coalescedPublicationDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushPendingPublications()
        }
    }

    /// Publishes the waiting background results now. Stories whose rows could not be read wait for the next batch.
    func flushPendingPublications() async {
        publicationTask?.cancel()
        publicationTask = nil
        let ids = pendingPublicationIDs
        pendingPublicationIDs = []
        guard !ids.isEmpty else { return }
        let failed = await publishInOrder(ids)
        if !failed.isEmpty {
            logger.error("Failed to publish enrichment of \(failed.count) stories; retrying with the next batch")
            schedulePublication(failed)
        }
    }

    /// Hydrate the persisted results, including fields invalidated by publisher-input changes, in one publication.
    private func publishStoredArticles(_ ids: Set<String>) async throws {
        let failed = await publishInOrder(ids)
        if !failed.isEmpty {
            throw NSError(
                domain: "ArticleStore", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Stored story could not be read"])
        }
    }

    /// Runs one publication after the previous one has applied (#778): rows are read inside the queue, so a later
    /// publication always reads at least as new a state. Returns the IDs whose rows could not be read.
    private func publishInOrder(_ ids: Set<String>) async -> Set<String> {
        let previous = lastPublication
        let current = Task { [weak self] () -> Set<String> in
            await previous?.value
            return await self?.applyStoredArticles(ids) ?? []
        }
        lastPublication = Task { _ = await current.value }
        return await current.value
    }

    private func applyStoredArticles(_ ids: Set<String>) async -> Set<String> {
        var stored: [FeedArticle] = []
        var failed = Set<String>()
        for id in ids {
            do {
                if let updated = try await database.fetchArticles(limit: 1, id: id).first { stored.append(updated) }
            } catch {
                failed.insert(id)
            }
        }
        var listed = articles
        var saved = savedArticles
        var listChanged = false
        var savedChanged = false
        var revised = false
        for updated in stored {
            let index = listed.firstIndex { $0.id == updated.id }
            let savedIndex = saved.firstIndex { $0.id == updated.id }
            // Reclassifying an unchanged story must not invalidate every feed card and the open reader.
            if let index, listed[index] == updated, savedIndex.map({ saved[$0] == updated }) ?? true { continue }
            revised = true
            if let index, listed[index] != updated {
                listed[index] = updated
                listChanged = true
            }
            if let savedIndex, saved[savedIndex] != updated {
                saved[savedIndex] = updated
                savedChanged = true
                savedArticleIDs.insert(updated.id)
            }
        }
        guard revised else { return failed }
        if listChanged { articles = listed }
        if savedChanged { savedArticles = saved }
        revision &+= 1
        return failed
    }

    // MARK: - Structured Article Analysis

    @discardableResult
    func saveArticleAnalysis(
        _ analysis: ArticleAnalysis, for articleId: String, expectedInputHash: String? = nil,
        expectedGeneration: Int? = nil
    ) async
        -> Bool
    {
        do {
            let articleId = try await database.resolvedArticleID(articleId)
            guard
                try await database.saveArticleAnalysis(
                    analysis, for: articleId, expectedInputHash: expectedInputHash,
                    expectedGeneration: expectedGeneration)
            else { return false }
            try await publishStoredArticles([articleId])
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
        // Running work is refused at commit by the generation bump; its session state is reset here (#805).
        await analysisClearedHandler?()
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
        // This clear removes enrichment too, so running work and its session state are reset the same way (#805).
        await analysisClearedHandler?()
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
}
