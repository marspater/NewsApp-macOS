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
    let spotlightIndexer: any SpotlightIndexing

    @Published private(set) var articles: [FeedArticle] = []
    @Published private(set) var savedArticles: [FeedArticle] = []
    @Published private(set) var savedArticleIDs: Set<String> = []
    @Published private(set) var readArticleIDs: Set<String> = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var savedCount: Int = 0
    @Published private(set) var isReady: Bool = false

    @Published private(set) var revision: UInt64 = 0
    /// Bumped when clustering or the reader changes events; the feed regroups on it.
    @Published private(set) var eventRevision: UInt64 = 0
    /// Bumped when an event overview is stored; the Briefing reloads its cited facts on it.
    @Published private(set) var overviewRevision: UInt64 = 0
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

        Task {
            await initialize()
        }
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
            if loaded, database === DatabaseEngine.shared { await rebuildSpotlightIndex() }
        } catch {
            self.databaseHealthNotice = await database.databaseHealthNotice()
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
            self.savedArticleIDs = Set(saved.map { $0.id })
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

    func markAsRead(ids: [String]) async {
        do {
            try await database.markReadBatch(articleIds: ids, isRead: true)
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

    /// Removes all saved stories from the database and clears the local Spotlight saved-stories domain (#559).
    func removeAllSavedStories() async {
        let currentSaved = savedArticles
        for article in currentSaved {
            _ = try? await database.setSaved(articleId: article.id, isSaved: false)
        }
        await serialSpotlight { await $0.removeAllSavedArticles() }
        await refreshState()
    }

    /// Replaces the saved-stories Spotlight domain with exactly the stories the open library holds (#812).
    /// Run at launch, which is also where a restored library first opens, so entries of the previous library go.
    func rebuildSpotlightIndex() async {
        await serialSpotlight { indexer in
            await indexer.removeAllSavedArticles()
            // Read when it runs, so a story unsaved while this waited is not re-added.
            for article in self.savedArticles { await indexer.indexSavedArticle(article) }
        }
    }

    private var spotlightTail: Task<Void, Never>?

    /// Runs Spotlight updates one at a time in call order, so a rebuild and a save or unsave cannot interleave (#812).
    private func serialSpotlight(_ operation: @escaping @MainActor (any SpotlightIndexing) async -> Void) async {
        let previous = spotlightTail
        let indexer = spotlightIndexer
        let task = Task { @MainActor in
            await previous?.value
            await operation(indexer)
        }
        spotlightTail = task
        await task.value
    }

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
                        image: image, readerDocument: readerDocument, expectedInputHash: expectedInputHash)
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
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String, expectedInputHash: String? = nil) async
        -> Bool
    {
        do {
            let articleId = try await database.resolvedArticleID(articleId)
            guard try await database.saveArticleAnalysis(analysis, for: articleId, expectedInputHash: expectedInputHash)
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

    /// Every visible report of the story the event leads (#581), for the expanded story card, whose coverage counts
    /// the whole story.
    func storyMemberArticles(eventID: String) async throws -> [FeedArticle] {
        try await database.fetchArticles(limit: nil, eventID: eventID, wholeStory: true)
    }

    /// Earlier events of the same developing story, shown under "Earlier in This Story": every earlier event of the
    /// story itself (#581), then up to `EventStoryRelation.linkLimit` other links, the lexical relation's (#314) before
    /// related acts the matcher kept apart (#522).
    func relatedStoryEvents(eventID: String) async throws -> [RelatedStoryEvent] {
        let lexical = try await EventStoryRelation.find(eventID: eventID, in: database)
        let members = try await database.fetchArticles(limit: nil, eventID: eventID)
        guard let start = members.map(\.pubDate).min() else { return lexical }
        // Every related act and story event, earlier and later: the earlier-only filter comes first.
        let earlier = try await database.relatedActEvents(eventID: eventID, limit: .max)
            .filter { $0.firstPublishedAt < start }
        let story = Set(try await database.storyEventIDs(eventID))
        return Self.earlierLinks(
            story: earlier.filter { story.contains($0.eventID) },
            others: lexical + earlier.filter { !story.contains($0.eventID) })
    }

    /// The story's own events, all of them and in the given order, then other links up to the cap. Three lexical
    /// links used to fill the list before the story's own earlier events were reached (#671).
    nonisolated static func earlierLinks(
        story: [RelatedStoryEvent], others: [RelatedStoryEvent], cap: Int = EventStoryRelation.linkLimit
    ) -> [RelatedStoryEvent] {
        var seen = Set(story.map(\.eventID))
        let extra = others.filter { seen.insert($0.eventID).inserted }.prefix(cap)
        return story + extra
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

    /// "Same event": the related event joins this one, and later passes keep them together (#524).
    @discardableResult
    func includeEvent(_ relatedEventID: String, inEvent eventID: String) async -> Bool {
        do {
            let combined = try await database.includeEvent(relatedEventID, inEvent: eventID)
            // The reader made this change: it is no new reporting to flag as "Updated".
            _ = try? await database.markEventSeen(combined.id)
            eventRevision &+= 1
            return true
        } catch {
            operationError = "These events could not be combined. Please try again."
            logger.error("Failed to combine events: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Event Overviews

    @discardableResult
    func recordEventOverview(_ document: EventOverviewDocument, expectedArticleInputs: [String: String]? = nil)
        async throws -> Bool
    {
        let stored = try await database.recordEventOverview(document, expectedArticleInputs: expectedArticleInputs)
        if stored { overviewRevision &+= 1 }
        return stored
    }

    func fetchEventOverview(eventID: String) async throws -> EventOverviewDocument? {
        try await database.fetchEventOverview(eventID: eventID)
    }

    func fetchEventOverview(forArticleID articleID: String) async throws -> EventOverviewDocument? {
        try await database.fetchEventOverview(forArticleID: articleID)
    }
}
