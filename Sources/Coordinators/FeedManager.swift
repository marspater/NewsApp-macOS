import AppKit
import Combine
import Foundation
import NaturalLanguage
import UserNotifications
import os

/// Orchestration layer coordinating feed fetching, article caching, enrichment, and section filtering.
@MainActor
class FeedManager: NSObject, ObservableObject {
    private let logger = NewsSignposts.feedsLog

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
    private let notifyBatch: @MainActor ([FeedArticle], NotificationDelivery) async -> Void
    private let enrichmentQueue: EnrichmentQueue
    private let allowsBackgroundWork: @MainActor () -> Bool
    private let imageFinder: StoryImageFinder
    private var isStopped = false
    private var storeUpdates: AnyCancellable?
    private var subscriptionUpdates: AnyCancellable?
    private var subscriptionTask: Task<Void, Never>?
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
    /// Stories a cancelled refresh had already committed; the next completed refresh notifies them.
    private var pendingNotificationArticles: [FeedArticle] = []
    /// The latest notification pass; the next one waits for it.
    private var notificationPass: Task<Void, Never>?
    /// Stories a full-mode banner has covered since launch (`PlannedBanner.stories`), for the Dock badge (#584).
    @Published private(set) var notifiedStoryIDs: Set<String> = []
    /// Retention runs at most once a day per launch, after a completed refresh.
    private var lastPruneAt: Date?
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

    init(
        settings: AppSettings? = nil, store: ArticleStore? = nil, schedulesRefresh: Bool = true,
        fetchBatch: (@Sendable ([String], Bool) async -> FeedBatch)? = nil,
        notifyBatch: @escaping @MainActor ([FeedArticle], NotificationDelivery) async -> Void = {
            articles, delivery in
            await NotificationService.shared.triageAndNotify(newArticles: articles, delivery: delivery)
        },
        enrichmentQueue: EnrichmentQueue? = nil,
        imageFinder: StoryImageFinder = .publisherPages,
        allowsBackgroundWork: @escaping @MainActor () -> Bool = { IntelligencePolicy.allowsEnergy() },
        powerEvents: NotificationCenter? = nil,
        wakeRefreshDelay: Duration = .seconds(10),
        now: @escaping () -> Date = { Date() }
    ) {
        let store = store ?? ArticleStore.shared
        let state = store.database
        self.appSettings = settings ?? AppSettings.shared
        self.articleStore = store
        self.fetchBatch =
            fetchBatch ?? { urls, allowHTTP in
                await FeedFetcher.shared.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: state)
            }
        self.notifyBatch = notifyBatch
        self.enrichmentQueue = enrichmentQueue ?? EnrichmentQueue(store: store)
        self.imageFinder = imageFinder
        self.allowsBackgroundWork = allowsBackgroundWork
        self.wakeRefreshDelay = wakeRefreshDelay
        self.now = now
        super.init()
        observeArticles()
        observeSubscriptions()
        observeLifecycle(powerEvents: powerEvents, schedulesRefresh: schedulesRefresh)
        loadCachedArticles()
        if schedulesRefresh { startBackgroundFetch() }
    }

    private func observeArticles() {
        storeUpdates = articleStore.$articles.sink { [weak self] articles in
            self?.articles = articles
        }
    }

    private func observeSubscriptions() {
        subscriptionUpdates = appSettings.$feedURLs
            .sink { [weak self] subscriptions in
                guard let self, !isStopped else { return }
                let hidden = Set(TensionMethodology.v1.panel.map(\.url)).subtracting(subscriptions)
                subscriptionTask?.cancel()
                subscriptionTask = Task { [articleStore] in
                    guard !Task.isCancelled else { return }
                    await articleStore.database.setCollectionOnlyFeedURLs(Array(hidden))
                    guard !Task.isCancelled else { return }
                    await articleStore.refreshState()
                }
            }
    }

    private func observeLifecycle(powerEvents: NotificationCenter?, schedulesRefresh: Bool) {
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
                },
            ]
        }
    }

    // MARK: - Feed URL Management (delegates to AppSettings)

    @discardableResult
    func addFeed(url: String) -> Bool {
        if let added = appSettings.addFeed(url: url) {
            cancelRefresh()
            feedStatuses[added] = .idle
            fetchFeeds()
            return true
        }
        return false
    }

    /// Subscribes to catalog feeds the user chose; one refresh covers the whole batch.
    @discardableResult
    func addCatalogFeeds(_ feeds: [CatalogFeed]) -> Int {
        let added = appSettings.addCatalogFeeds(feeds)
        guard added > 0 else { return 0 }
        cancelRefresh()
        fetchFeeds()
        return added
    }

    /// The health entry for a feed, found by its slash-insensitive key so a stored trailing slash still matches.
    func feedHealth(for url: String) -> FeedHealth? { Self.health(for: url, in: feedHealth) }

    static func health(for url: String, in entries: [String: FeedHealth]) -> FeedHealth? {
        if let exact = entries[url] { return exact }
        let key = AppSettings.feedKey(url)
        return entries.first { AppSettings.feedKey($0.key) == key }?.value
    }

    func removeFeed(url: String) {
        cancelRefresh()
        appSettings.removeFeed(url: url)
        let key = AppSettings.feedKey(url)
        for stored in feedStatuses.keys where AppSettings.feedKey(stored) == key {
            feedStatuses.removeValue(forKey: stored)
        }
        fetchFeeds()
    }

    // MARK: - OPML Portability

    @discardableResult
    func importFeeds(from opmlData: Data) -> Int {
        do { _ = try OPMLParser.parseValidated(data: opmlData) } catch {
            articleStore.operationError =
                "The OPML file could not be imported because it is incomplete or malformed. No subscriptions were changed."
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
            articleStore.operationError =
                "The OPML file could not be read. Please choose a readable file no larger than 5 MB."
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

    func setTensionCollectionOptIn(_ enabled: Bool) {
        appSettings.setTensionCollectionOptIn(enabled)
    }

    // MARK: - Section Keyword Matching

    func articles(for section: String) -> [FeedArticle] {
        if section == "Today" || section == "Saved Stories" || section == "History" { return articles }

        return articles.filter { article in
            ArticleSection.matches(
                section, title: article.title, description: article.description, category: article.category)
        }
    }

    // MARK: - Feed Health

    func reloadFeedHealth() async {
        let states: [String: FeedFetchState]
        do {
            states = try await articleStore.database.feedFetchStates()
        } catch {
            if !(error is CancellationError) {
                logger.error("Failed to load feed fetch states: \(error.localizedDescription)")
            }
            return
        }
        let now = Date()
        feedHealth = Dictionary(
            appSettings.feedURLs.map { ($0, FeedHealth(states[$0], now: now)) }, uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Caching & Persistence

    func loadCachedArticles() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let loaded = try await self.articleStore.fetchArticles()
                self.articles = loaded
                await self.reloadFeedHealth()
                // Catch-up clustering of what a previous session left waits for the list's first frame (#602).
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
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: appSettings.fetchIntervalMinutes * 60, repeats: true) {
            [weak self] _ in
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
        // The waiting caller returns without finishing the run, so the loading state ends here.
        for (url, status) in feedStatuses where status == .loading { feedStatuses[url] = .idle }
        isAnyFeedLoading = false
    }

    func stopBackgroundWork() {
        isStopped = true
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionUpdates?.cancel()
        subscriptionUpdates = nil
        storeUpdates?.cancel()
        storeUpdates = nil
        terminationObserver?.cancel()
        terminationObserver = nil
        for observer in powerObservers {
            observer.cancel()
        }
        powerObservers.removeAll()
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
        guard refreshRunID == runID else {
            // Cancelled between the pipeline's return and this resumption: the next run notifies these.
            pendingNotificationArticles.append(contentsOf: newArticles)
            return
        }
        refreshTask = nil
        refreshRunID = nil
        isAnyFeedLoading = false
        lastRefreshCompletedAt = now()
        refreshInterruptedBySleep = false

        guard !isStopped else { return }
        await pruneIfDue()
        clusterEventsInBackground()
        // Rate before triage. Collection and its spinner have ended; another refresh can proceed.
        await waitForEventClustering()
        guard !Task.isCancelled, !isStopped else { return }
        let eligible: Set<String>
        do {
            eligible = try await articleStore.database.notificationStoryIDs(newArticles.map(\.id))
        } catch {
            if !(error is CancellationError) {
                logger.error("Failed to load notification-eligible story IDs: \(error.localizedDescription)")
            }
            return
        }
        // Muting applies in every notification privacy mode; stored importance does not hide stories.
        let muting = appSettings.muteRules
        let notifiable = newArticles.filter { eligible.contains($0.id) && !muting.mutes($0) }
        if appSettings.notificationsEnabled && !notifiable.isEmpty {
            // Passes run one at a time: each reads the delivery tables only after the previous one has recorded its
            // banners (#665).
            let previous = notificationPass
            let pass = Task { [weak self] in
                await previous?.value
                await self?.deliverNotifications(notifiable)
            }
            notificationPass = pass
            await withTaskCancellationHandler {
                await pass.value
            } onCancel: {
                pass.cancel()
            }
        }
        guard !Task.isCancelled, !isStopped else { return }
        enrichArticlesInBackground()
    }

    /// One notification pass. Clustering has run: reports of one event notify once, by their strongest report, in
    /// every mode (#523, #587). Full mode reads what the lanes need (#665, docs/notifications.md); delivery only reads
    /// stories, and writes nothing but its own tables.
    /// The reading interests notification triage ranks by; a Reset Reading Interests ignores earlier history.
    nonisolated static func triageInterests(database: DatabaseEngine, now: Date, resetAt: Date?) async -> Set<String> {
        NotificationService.topInterests((try? await database.briefingInterests(now: now, resetAt: resetAt)) ?? [:])
    }

    private func deliverNotifications(_ notifiable: [FeedArticle]) async {
        let database = articleStore.database
        var delivery = NotificationDelivery(mode: appSettings.notificationMode)
        var storyIDs = notifiable.map(\.id)
        if delivery.mode == .full {
            let posted = now()
            delivery.now = posted
            delivery.ledger = (try? await database.notificationLedger(now: posted)) ?? NotificationLedger()
            delivery.starredFeedURLs = appSettings.starredFeedURLs
            // Pending starred stories start at the latest of the feed's last starred banner, its star time and a day
            // ago, so starring a feed never brings up its backlog.
            var since: [String: Date] = [:]
            for feed in delivery.starredFeedURLs {
                since[feed] = max(
                    delivery.ledger.lastStarred[feed] ?? .distantPast,
                    min(appSettings.starredFeedTimes[feed] ?? posted, posted), posted.addingTimeInterval(-86400))
            }
            delivery.starredPending =
                (try? await database.feedStories(since: since, muting: appSettings.muteRules)) ?? [:]
            storyIDs += delivery.starredPending.values.flatMap { $0.map(\.id) }
            delivery.interests = await Self.triageInterests(
                database: database, now: posted, resetAt: appSettings.readingInterestsResetDate)
            delivery.record = { [weak self] banner in
                try? await database.recordNotification(banner, at: posted)
                await self?.markNotified(banner.stories)
            }
            delivery.queue = { waiting in
                try? await database.queuePriority(waiting, at: posted)
            }
        }
        delivery.events = (try? await database.eventIDs(forArticles: storyIDs)) ?? [:]
        delivery.stories =
            (try? await database.storyIDs(
                forEvents: Set(delivery.events.values).union(delivery.ledger.announced.keys)
                    .union(delivery.ledger.priorityQueue.map(\.event)))) ?? [:]
        if delivery.mode == .full {
            let events = Set(delivery.events.values)
            delivery.publishers = (try? await database.eventPublisherCounts(events)) ?? [:]
            delivery.leadTitles = (try? await database.eventLeadTitles(events)) ?? [:]
        }
        guard !Task.isCancelled, !isStopped else { return }
        await notifyBatch(notifiable, delivery)
    }

    private func markNotified(_ stories: [String]) {
        notifiedStoryIDs.formUnion(stories)
    }

    /// Deletes read, unsaved stories older than the retention setting, once a day after a completed refresh.
    private func pruneIfDue() async {
        let days = appSettings.articleRetentionDays
        guard days > 0 else { return }
        let current = now()
        if let last = lastPruneAt, current.timeIntervalSince(last) < 24 * 3600 { return }
        lastPruneAt = current
        await articleStore.pruneOldArticles(keepReadDays: days)
    }

    private func performRefreshPipeline() async -> [FeedArticle] {
        let targetURLs = appSettings.effectiveFeedURLs
        let signpostState = NewsSignposts.begin(
            NewsSignposts.feeds, name: "RefreshFeeds", metadata: "feeds=\(targetURLs.count)")
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
        // Collected statuses are published together after ingestion: one change per feed re-rendered every view that
        // observes the manager once per feed (#778).
        var statuses: [String: FeedStatus] = [:]
        for res in results {
            guard !Task.isCancelled else { break }
            guard targetURLs.contains(res.urlString) else { continue }
            if let err = res.error {
                statuses[res.urlString] = .failed(err)
            } else {
                statuses[res.urlString] = .idle
                if let incoming = res.articles {
                    let arts = incoming.map { article in
                        var article = article
                        article.identityFeedURL = res.urlString
                        return article
                    }
                    allParsed.append(contentsOf: arts)
                    insertedIDs.formUnion(
                        await articleStore.batchUpsert(
                            articles: arts, feedUrl: res.urlString, validators: res.validators, publish: false))
                }
            }
        }
        // A cancelled run leaves the statuses to the run that replaced it; a feed removed meanwhile keeps no status.
        if !Task.isCancelled {
            var updatedStatuses = feedStatuses
            for (url, status) in statuses where updatedStatuses[url] != nil { updatedStatuses[url] = status }
            feedStatuses = updatedStatuses
        }

        // Publish one coherent snapshot per collection, including any committed prefix if it was cancelled.
        await articleStore.refreshState()
        allParsed.sort { $0.pubDate > $1.pubDate }

        // Stories a cancelled run had committed come first; the next run sees them as existing rows.
        var notifiedIDs = Set<String>()
        let userSubscribed = Set(appSettings.feedURLs)
        let pendingIDs = Set(pendingNotificationArticles.map(\.id))
        let newArticles = (pendingNotificationArticles + allParsed).filter {
            (insertedIDs.contains($0.id) || pendingIDs.contains($0.id))
                && userSubscribed.contains($0.identityFeedURL ?? "") && notifiedIDs.insert($0.id).inserted
        }
        guard !Task.isCancelled else {
            pendingNotificationArticles = newArticles
            return []
        }
        pendingNotificationArticles = []

        do {
            let stored = try await articleStore.fetchArticles()
            guard !Task.isCancelled else {
                pendingNotificationArticles = newArticles
                return []
            }
            self.articles = stored
            await reloadFeedHealth()
        } catch {
            guard !Task.isCancelled else {
                pendingNotificationArticles = newArticles
                return []
            }
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
                let allowsEnergy = self?.allowsBackgroundWork() ?? true
                let work = Task.detached(priority: .utility) { () throws -> Bool in
                    let clustering = try await EventClusterer.run(in: database, allowsEnergy: allowsEnergy)
                    return !clustering.changedEvents.isEmpty
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
            if self.allowsBackgroundWork() {
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
        let retained = appSettings.tensionRetainedFeedURLs
        imageLookupTask = Task { [weak self] in
            self?.logger.info("Story image lookup started")
            defer { self?.logger.info("Story image lookup finished") }
            let work = Task.detached(priority: .utility) {
                try await StoryCurator.run(
                    in: database, imageFinder: finder, muting: muting,
                    keepingFeedURLs: retained)
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
            guard !Task.isCancelled else { return }
            await enrichmentQueue.enqueue(
                articles: snapshot,
                priority: .background,
                allowHTTP: allowHTTP
            )
        }
    }

    // MARK: - Legacy Helper Forwarder

    nonisolated static func isBlockedLocalAddress(_ host: String) -> Bool {
        if case .blocked = IPAddressValidator.validateHost(host) { return true }
        return false
    }
}
