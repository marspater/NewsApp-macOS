import Foundation
import AppKit
import Combine
import NaturalLanguage
import UserNotifications
import os

/// Orchestration layer coordinating feed fetching, article caching, enrichment, and section filtering.
@MainActor
class FeedManager: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.marspater.news", category: "FeedManager")

    enum FeedStatus: Equatable, Sendable {
        case idle
        case loading
        case failed(FeedError)

        var errorMessage: String? {
            switch self {
            case .idle, .loading: return nil
            case .failed(let err): return err.localizedDescription
            }
        }
    }

    @Published var articles: [FeedArticle] = []
    @Published var feedStatuses: [String: FeedStatus] = [:]
    @Published var isAnyFeedLoading: Bool = false

    let appSettings: AppSettings
    let articleStore: ArticleStore

    typealias FeedBatch = [FeedFetchResult]
    private let fetchBatch: @Sendable ([String], Bool) async -> FeedBatch
    private let notifyBatch: @MainActor ([FeedArticle], AppSettings.NotificationMode) async -> Void
    private let enrichmentQueue: EnrichmentQueue
    private var isStopped = false
    private var storeUpdates: AnyCancellable?
    private var terminationObserver: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var refreshRunID: UUID?
    private var enrichmentTask: Task<Void, Never>?
    private var backgroundTimer: Timer?
    private var backgroundActivity: NSBackgroundActivityScheduler?

    // Backward-compatibility forwarders for existing UI / View bindings
    var feedURLs: [String] { appSettings.feedURLs }
    var userSections: [String] { appSettings.userSections }
    var fetchIntervalMinutes: Double { appSettings.fetchIntervalMinutes }
    var notificationsEnabled: Bool { appSettings.notificationsEnabled }
    var aiEnabled: Bool { appSettings.aiEnabled }

    init(settings: AppSettings? = nil, store: ArticleStore? = nil, schedulesRefresh: Bool = true,
         fetchBatch: (@Sendable ([String], Bool) async -> FeedBatch)? = nil,
         notifyBatch: @escaping @MainActor ([FeedArticle], AppSettings.NotificationMode) async -> Void = { articles, mode in
             await NotificationService.shared.triageAndNotify(newArticles: articles, mode: mode)
         }) {
        let store = store ?? ArticleStore.shared
        let state = store.database
        self.appSettings = settings ?? AppSettings.shared
        self.articleStore = store
        self.fetchBatch = fetchBatch ?? { urls, allowHTTP in
            await FeedFetcher.shared.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: state)
        }
        self.notifyBatch = notifyBatch
        self.enrichmentQueue = EnrichmentQueue(store: self.articleStore)
        super.init()
        storeUpdates = articleStore.$articles.sink { [weak self] articles in
            self?.articles = articles
        }
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stopBackgroundWork() }
            }
        loadCachedArticles()
        if schedulesRefresh { startBackgroundFetch() }
    }

    // MARK: - Feed URL Management (delegates to AppSettings)

    func addFeed(url: String) {
        if let added = appSettings.addFeed(url: url) {
            cancelRefresh()
            feedStatuses[added] = .idle
            fetchFeeds()
        }
    }

    func removeFeed(url: String) {
        cancelRefresh()
        appSettings.removeFeed(url: url)
        feedStatuses.removeValue(forKey: url)
        fetchFeeds()
    }

    // MARK: - OPML Portability

    @discardableResult
    func importFeeds(from opmlData: Data) -> Int {
        do { _ = try OPMLParser.parseValidated(data: opmlData) }
        catch {
            articleStore.operationError = "The OPML file could not be imported because it is incomplete or malformed. No subscriptions were changed."
            return 0
        }
        let count = appSettings.importFeeds(from: opmlData)
        if count > 0 {
            cancelRefresh()
            fetchFeeds()
        }
        return count
    }

    @discardableResult
    func importFeeds(fromFile url: URL) async -> Int {
        do {
            return importFeeds(from: try await OPMLFileReader.read(url))
        } catch {
            articleStore.operationError = "The OPML file could not be read. Please choose a readable file no larger than 5 MB."
            return 0
        }
    }

    func exportOPML() -> String {
        appSettings.exportOPML()
    }

    // MARK: - Section Management

    func addSection(_ name: String) {
        appSettings.addSection(name)
    }

    func removeSection(_ name: String) {
        appSettings.removeSection(name)
    }

    func setFetchInterval(minutes: Double) {
        appSettings.setFetchInterval(minutes: minutes)
        startBackgroundFetch()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        appSettings.setNotificationsEnabled(enabled)
    }

    func setAIEnabled(_ enabled: Bool) {
        appSettings.setAIEnabled(enabled)
    }

    func setPrivateNotificationsEnabled(_ enabled: Bool) {
        appSettings.setPrivateNotificationsEnabled(enabled)
    }

    // MARK: - Section Keyword Matching

    func articles(for section: String) -> [FeedArticle] {
        if section == "Today" || section == "Saved Stories" || section == "History" { return articles }

        guard let keywords = ArticleSection.keywords[section] else {
            return articles.filter { article in
                let text = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
                return text.contains(section.lowercased())
            }
        }

        return articles.filter { article in
            let text = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
            return keywords.contains { text.contains($0) }
        }
    }

    // MARK: - Caching & Persistence

    func loadCachedArticles() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let loaded = try await self.articleStore.fetchArticles()
                self.articles = loaded
            } catch {
                self.logger.error("Failed to load cached articles: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Background Scheduling
    // macOS schedules opportunistic background refreshes according to the configured interval and system conditions.

    func startBackgroundFetch() {
        guard !isStopped else { return }
        backgroundTimer?.invalidate()
        backgroundActivity?.invalidate()

        let intervalSeconds = appSettings.fetchIntervalMinutes * 60

        // 1. Foreground Timer: regular updates while application is active
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchFeedsAsync()
            }
        }

        // 2. NSBackgroundActivityScheduler: opportunistic background execution
        // Stable persistent identifier as required by Apple scheduling heuristics
        let activity = NSBackgroundActivityScheduler(identifier: "com.marspater.news.feed-refresh")
        activity.repeats = true
        activity.interval = intervalSeconds
        activity.tolerance = max(60, intervalSeconds * 0.2)
        activity.qualityOfService = .background

        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self = self else {
                    completion(.finished)
                    return
                }

                await self.fetchFeedsAsync()
                completion(.finished)
            }
        }
        self.backgroundActivity = activity
    }

    // MARK: - Ingestion Pipeline

    func fetchFeeds() {
        Task {
            await fetchFeedsAsync()
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRunID = nil
    }

    func stopBackgroundWork() {
        isStopped = true
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        backgroundActivity?.invalidate()
        backgroundActivity = nil
        cancelRefresh()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        isAnyFeedLoading = false
        let queue = enrichmentQueue
        Task { await queue.cancelAll(reason: .user) }
    }

    func fetchFeedsAsync() async {
        guard !isStopped else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let runID = UUID()
        refreshRunID = runID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefreshPipeline()
        }
        // Retain the work itself so subscription changes cancel ingestion as well as fetching.
        refreshTask = task
        await task.value
        if refreshRunID == runID {
            refreshTask = nil
            refreshRunID = nil
            isAnyFeedLoading = false
        }
    }

    private func performRefreshPipeline() async {
        let signpostState = NewsSignposts.begin(NewsSignposts.feeds, name: "RefreshFeeds", metadata: "feeds=\(appSettings.feedURLs.count)")
        defer { NewsSignposts.end(NewsSignposts.feeds, name: "RefreshFeeds", state: signpostState) }

        for url in appSettings.feedURLs {
            if case .failed(let err) = feedStatuses[url], case .blockedHost = err {
                continue
            }
            feedStatuses[url] = .loading
        }
        isAnyFeedLoading = true


        let results = await fetchBatch(appSettings.feedURLs, appSettings.allowInsecureHTTP)

        var insertedIDs = Set<String>()
        var allParsed = [FeedArticle]()
        for res in results {
            guard !Task.isCancelled else { return }
            guard appSettings.feedURLs.contains(res.urlString) else { continue }
            if let err = res.error {
                feedStatuses[res.urlString] = .failed(err)
            } else {
                feedStatuses[res.urlString] = .idle
                if let incoming = res.articles {
                    let arts = incoming.map { article in
                        var article = article
                        article.identityFeedURL = res.urlString
                        return article
                    }
                    allParsed.append(contentsOf: arts)
                    insertedIDs.formUnion(await articleStore.batchUpsert(articles: arts, feedUrl: res.urlString, validators: res.validators))
                }
            }
        }

        guard !Task.isCancelled else { return }
        allParsed.sort { $0.pubDate > $1.pubDate }

        var notifiedIDs = Set<String>()
        let newArticles = allParsed.filter { insertedIDs.contains($0.id) && notifiedIDs.insert($0.id).inserted }

        do {
            let stored = try await articleStore.fetchArticles()
            guard !Task.isCancelled else { return }
            self.articles = stored
        } catch {
            guard !Task.isCancelled else { return }
            articleStore.operationError = "Stored articles could not be loaded. Your current library has been retained."
            logger.error("Failed to reload articles after refresh: \(error.localizedDescription)")
        }

        if appSettings.notificationsEnabled && !newArticles.isEmpty {
            await notifyBatch(newArticles, appSettings.notificationMode)
        }

        guard !Task.isCancelled else { return }
        enrichArticlesInBackground()
    }

    // MARK: - Background Enrichment

    private func enrichArticlesInBackground() {
        enrichmentTask?.cancel()
        guard appSettings.aiEnabled else { return }

        let snapshot = articles
        let allowHTTP = appSettings.allowInsecureHTTP

        enrichmentTask = Task {
            // Cancel previous background backlog on new ingest
            await enrichmentQueue.cancelAll(reason: .superseded)

            // Cheap deterministic classification for ingestion; generative analysis stays on demand.
            for article in snapshot {
                guard !Task.isCancelled else { return }
                let priority: EnrichmentPriority = .background
                await enrichmentQueue.enqueue(
                    article: article,
                    priority: priority,
                    allowHTTP: allowHTTP
                )
            }
        }
    }

    // MARK: - Legacy Helper Forwarder

    nonisolated static func isBlockedLocalAddress(_ host: String) -> Bool {
        if case .blocked = IPAddressValidator.validateHost(host) { return true }
        return false
    }
}
