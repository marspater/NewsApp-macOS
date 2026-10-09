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
    /// Operational health per subscription, refreshed after every refresh and when a view asks.
    @Published private(set) var feedHealth: [String: FeedHealth] = [:]

    let appSettings: AppSettings
    let articleStore: ArticleStore

    typealias FeedBatch = [FeedFetchResult]
    private let fetchBatch: @Sendable ([String], Bool) async -> FeedBatch
    private let notifyBatch: @MainActor ([FeedArticle], AppSettings.NotificationMode) async -> Void
    private let enrichmentQueue: EnrichmentQueue
    private let allowsBackgroundWork: @MainActor () -> Bool
    private let importanceJudge: StoryImportanceJudge
    private let imageFinder: StoryImageFinder
    private var isStopped = false
    private var storeUpdates: AnyCancellable?
    private var terminationObserver: AnyCancellable?
    /// Collection only: fetch, ingest and publish. Resolves to the newly stored articles.
    private var refreshTask: Task<[FeedArticle], Never>?
    private var refreshRunID: UUID?
    private var enrichmentTask: Task<Void, Never>?
    private var overviewWarmupTask: Task<Void, Never>?
    /// Publisher-page lead images, looked up after clustering so notifications never wait for page downloads.
    private var imageLookupTask: Task<Void, Never>?
    /// Event clustering after collection; one pass at a time, never part of the refresh itself.
    private var clusteringTask: Task<Void, Never>?
    private var clusteringRunID: UUID?
    private var needsClusteringPass = false
    private var backgroundTimer: Timer?
    private var backgroundActivity: NSBackgroundActivityScheduler?
    private var powerObservers: [AnyCancellable] = []
    private var wakeTask: Task<Void, Never>?
    private var refreshInterruptedBySleep = false
    /// When the latest refresh published its stories; shown in the list header.
    @Published private(set) var lastRefreshCompletedAt: Date?
    private let wakeRefreshDelay: Duration
    private let now: () -> Date

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
         },
         enrichmentQueue: EnrichmentQueue? = nil,
         importanceJudge: StoryImportanceJudge = .onDevice,
         imageFinder: StoryImageFinder = .publisherPages,
         allowsBackgroundWork: @escaping @MainActor () -> Bool = {
             let info = ProcessInfo.processInfo
             return !info.isLowPowerModeEnabled && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
         },
         powerEvents: NotificationCenter? = nil,
         wakeRefreshDelay: Duration = .seconds(10),
         now: @escaping () -> Date = { Date() }) {
        let store = store ?? ArticleStore.shared
        let state = store.database
        self.appSettings = settings ?? AppSettings.shared
        self.articleStore = store
        self.fetchBatch = fetchBatch ?? { urls, allowHTTP in
            await FeedFetcher.shared.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: state)
        }
        self.notifyBatch = notifyBatch
        self.enrichmentQueue = enrichmentQueue ?? EnrichmentQueue(store: store)
        self.importanceJudge = importanceJudge
        self.imageFinder = imageFinder
        self.allowsBackgroundWork = allowsBackgroundWork
        self.wakeRefreshDelay = wakeRefreshDelay
        self.now = now
        super.init()
        storeUpdates = articleStore.$articles.sink { [weak self] articles in
            self?.articles = articles
        }
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stopBackgroundWork() }
            }
        // NSWorkspace posts sleep and wake on the main thread.
        if let center = powerEvents ?? (schedulesRefresh ? NSWorkspace.shared.notificationCenter : nil) {
            powerObservers = [
                center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemWillSleep() }
                },
                center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemDidWake() }
                }
            ]
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

    /// Subscribes to catalog feeds the user chose; one refresh covers the whole batch.
    func addCatalogFeeds(_ feeds: [CatalogFeed]) {
        guard appSettings.addCatalogFeeds(feeds) > 0 else { return }
        cancelRefresh()
        fetchFeeds()
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

    func setTensionCollectionOptIn(_ enabled: Bool) {
        appSettings.setTensionCollectionOptIn(enabled)
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

    // MARK: - Feed Health

    func reloadFeedHealth() async {
        guard let states = try? await articleStore.database.feedFetchStates() else { return }
        let now = Date()
        feedHealth = Dictionary(appSettings.feedURLs.map { ($0, FeedHealth(states[$0], now: now)) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Caching & Persistence

    func loadCachedArticles() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let loaded = try await self.articleStore.fetchArticles()
                self.articles = loaded
                await self.reloadFeedHealth()
                // Catch up on articles a previous session collected but did not cluster.
                self.clusterEventsInBackground()
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
        scheduleForegroundTimer()

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
                // The system asks to defer when it is busy or saving energy; run at the next opportunity instead.
                if self.backgroundActivity?.shouldDefer == true {
                    completion(.deferred)
                    return
                }

                await self.fetchFeedsAsync()
                completion(.finished)
            }
        }
        self.backgroundActivity = activity
    }

    private func scheduleForegroundTimer() {
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: appSettings.fetchIntervalMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchFeedsAsync()
            }
        }
    }

    // MARK: - Sleep and Wake

    /// Requests cut off by sleep would be recorded as feed failures and back healthy feeds off.
    /// A cancelled refresh records nothing; it is repeated after wake.
    private func systemWillSleep() {
        wakeTask?.cancel()
        wakeTask = nil
        guard refreshTask != nil else { return }
        refreshInterruptedBySleep = true
        cancelRefresh()
    }

    /// Timers do not advance while the Mac sleeps. After wake, give the network a moment, refresh once if a
    /// refresh was interrupted or the last one is older than the interval, and count the next interval from there.
    private func systemDidWake() {
        guard !isStopped else { return }
        wakeTask?.cancel()
        wakeTask = Task { [weak self, wakeRefreshDelay] in
            try? await Task.sleep(for: wakeRefreshDelay)
            guard let self, !Task.isCancelled, !self.isStopped, self.needsRefreshAfterWake else { return }
            if self.backgroundTimer != nil { self.scheduleForegroundTimer() }
            await self.fetchFeedsAsync()
        }
    }

    private var needsRefreshAfterWake: Bool {
        guard !refreshInterruptedBySleep, let last = lastRefreshCompletedAt else { return true }
        return now().timeIntervalSince(last) >= appSettings.fetchIntervalMinutes * 60
    }

    /// Resolves once the check after the latest wake, and any refresh it started, has finished.
    func waitForWakeRefresh() async {
        await wakeTask?.value
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
        wakeTask?.cancel()
        wakeTask = nil
        cancelRefresh()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        overviewWarmupTask?.cancel()
        overviewWarmupTask = nil
        imageLookupTask?.cancel()
        imageLookupTask = nil
        clusteringTask?.cancel()
        clusteringTask = nil
        clusteringRunID = nil
        isAnyFeedLoading = false
        let queue = enrichmentQueue
        Task { await queue.cancelAll(reason: .user) }
    }

    /// Returns once new articles are collected and published. Notification triage and background classification
    /// follow for the caller that started the run, but never hold the refresh, its spinner or the next Cmd-R.
    func fetchFeedsAsync() async {
        guard !isStopped else { return }
        if let refreshTask {
            _ = await refreshTask.value
            return
        }
        let runID = UUID()
        refreshRunID = runID
        let task = Task<[FeedArticle], Never> { [weak self] in
            await self?.performRefreshPipeline() ?? []
        }
        // Retain the work itself so subscription changes cancel ingestion as well as fetching.
        refreshTask = task
        let newArticles = await task.value
        guard refreshRunID == runID else { return }
        refreshTask = nil
        refreshRunID = nil
        isAnyFeedLoading = false
        lastRefreshCompletedAt = now()
        refreshInterruptedBySleep = false

        guard !isStopped else { return }
        clusterEventsInBackground()
        // Rate before triage. Collection and its spinner have ended; another refresh can proceed.
        await waitForEventClustering()
        guard !Task.isCancelled, !isStopped else { return }
        guard let eligible = try? await articleStore.database.notificationStoryIDs(newArticles.map(\.id)) else { return }
        // Muted and waiting stories never notify, in any privacy mode.
        let muting = appSettings.muteRules
        let notifiable = newArticles.filter { eligible.contains($0.id) && !muting.mutes($0) }
        if appSettings.notificationsEnabled && !notifiable.isEmpty {
            await notifyBatch(notifiable, appSettings.notificationMode)
        }
        guard !Task.isCancelled, !isStopped else { return }
        enrichArticlesInBackground()
    }

    private func performRefreshPipeline() async -> [FeedArticle] {
        let targetURLs = appSettings.effectiveFeedURLs
        let signpostState = NewsSignposts.begin(NewsSignposts.feeds, name: "RefreshFeeds", metadata: "feeds=\(targetURLs.count)")
        defer { NewsSignposts.end(NewsSignposts.feeds, name: "RefreshFeeds", state: signpostState) }

        for url in targetURLs {
            if case .failed(let err) = feedStatuses[url], case .blockedHost = err {
                continue
            }
            feedStatuses[url] = .loading
        }
        isAnyFeedLoading = true


        let results = await fetchBatch(targetURLs, appSettings.allowInsecureHTTP)

        var insertedIDs = Set<String>()
        var allParsed = [FeedArticle]()
        for res in results {
            guard !Task.isCancelled else { return [] }
            guard targetURLs.contains(res.urlString) else { continue }
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

        guard !Task.isCancelled else { return [] }
        allParsed.sort { $0.pubDate > $1.pubDate }

        var notifiedIDs = Set<String>()
        let userSubscribed = Set(appSettings.feedURLs)
        let newArticles = allParsed.filter {
            insertedIDs.contains($0.id) &&
            userSubscribed.contains($0.identityFeedURL ?? "") &&
            notifiedIDs.insert($0.id).inserted
        }

        do {
            let stored = try await articleStore.fetchArticles()
            guard !Task.isCancelled else { return [] }
            self.articles = stored
            await reloadFeedHealth()
        } catch {
            guard !Task.isCancelled else { return [] }
            articleStore.operationError = "Stored articles could not be loaded. Your current library has been retained."
            logger.error("Failed to reload articles after refresh: \(error.localizedDescription)")
        }

        return newArticles
    }

    // MARK: - Event Clustering

    /// Groups new and changed articles into events once a refresh has published them. The pass runs
    /// off the main actor with cancellation; a request during a pass schedules exactly one more.
    func clusterEventsInBackground() {
        guard !isStopped else { return }
        guard clusteringTask == nil else {
            needsClusteringPass = true
            return
        }
        let database = articleStore.database
        let runID = UUID()
        clusteringRunID = runID
        clusteringTask = Task { [weak self] in
            repeat {
                self?.needsClusteringPass = false
                // The on-device judge follows the AI setting and, like classification, waits out Low Power Mode and heat.
                let backgroundAllowed = self.map { $0.allowsBackgroundWork() } == true
                let modelAllowed = backgroundAllowed && self?.appSettings.aiEnabled == true
                let importanceJudge = modelAllowed ? self?.importanceJudge ?? .unavailable : .unavailable
                let muting = self?.appSettings.muteRules ?? MuteRules()
                let work = Task.detached(priority: .utility) { () throws -> Bool in
                    let clustering = try await EventClusterer.run(in: database, judge: modelAllowed ? .onDevice : .unavailable)
                    // Importance is rated once clusters are known; waiting stories expire after their lifetime.
                    let curation = try await StoryCurator.run(in: database, judge: importanceJudge, muting: muting)
                    return !clustering.changedEvents.isEmpty || curation.changed
                }
                let result = await withTaskCancellationHandler {
                    await work.result
                } onCancel: {
                    work.cancel()
                }
                guard let self, self.clusteringRunID == runID, !Task.isCancelled else { return }
                switch result {
                case .success(let changed):
                    if changed { self.articleStore.noteEventsChanged() }
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.logger.error("Event clustering failed: \(error.localizedDescription)")
                    }
                }
            } while self?.needsClusteringPass == true && !Task.isCancelled
            guard let self, self.clusteringRunID == runID else { return }
            self.clusteringTask = nil
            self.clusteringRunID = nil
            self.overviewWarmupTask?.cancel()
            if self.appSettings.aiEnabled, self.allowsBackgroundWork() {
                let store = self.articleStore
                let muting = self.appSettings.muteRules
                self.overviewWarmupTask = Task {
                    await OverviewGenerationCoordinator.shared.warmVisibleOverviews(store: store, muting: muting)
                }
            }
            self.lookUpStoryImages()
        }
    }

    /// Looks up lead images for shown stories without any, after clustering and outside `waitForEventClustering`, so
    /// notification triage never waits for publisher pages. A later pass replaces a lookup still running.
    private func lookUpStoryImages() {
        imageLookupTask?.cancel()
        imageLookupTask = nil
        guard !isStopped, imageFinder.isAvailable, allowsBackgroundWork() else { return }
        let database = articleStore.database
        let finder = imageFinder
        let muting = appSettings.muteRules
        imageLookupTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                try await StoryCurator.run(in: database, judge: .unavailable, imageFinder: finder, muting: muting)
            }
            let result = await withTaskCancellationHandler {
                await work.result
            } onCancel: {
                work.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let report):
                if report.changed { self.articleStore.noteEventsChanged() }
            case .failure(let error):
                if !(error is CancellationError) {
                    self.logger.error("Story image lookup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Resolves once no clustering pass is running or scheduled.
    func waitForEventClustering() async {
        while let task = clusteringTask {
            await task.value
            if clusteringTask == task { return }
        }
    }

    // MARK: - Background Enrichment

    private func enrichArticlesInBackground() {
        enrichmentTask?.cancel()
        // Low Power Mode and thermal pressure defer classification; the next refresh picks the backlog up again.
        guard appSettings.aiEnabled, allowsBackgroundWork() else { return }

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
