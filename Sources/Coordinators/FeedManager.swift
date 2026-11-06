// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
    /// The last finished clustering pass and image lookup of this launch, for the diagnostics export (#1006).
    struct ClusteringPass: Sendable {
        let report: EventClusteringReport
        let seconds: Double
        let finishedAt: Date
    }
    private(set) var lastClusteringPass: ClusteringPass?
    private(set) var lastImageLookup: StoryCurator.Report?

    let appSettings: AppSettings
    let articleStore: ArticleStore

    typealias FeedBatch = [FeedFetchResult]
    private let fetchBatch: @Sendable ([String], Bool) async -> FeedBatch
    private let notifyBatch: @MainActor ([FeedArticle], NotificationDelivery) async -> Void
    let enrichmentQueue: EnrichmentQueue
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
    private var runningRefreshIsScheduled = false
    /// Callers that asked for a manual refresh while a scheduled one was collecting: one more refresh runs after it,
    /// and they resume when that ends (#927).
    private(set) var manualRefreshWaiters: [CheckedContinuation<Void, Never>] = []
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
    /// The latest notification pass; the next one waits for it. Banners post minutes apart, so a pass outlives the
    /// refresh that started it; `stopBackgroundWork` cancels it.
    private(set) var notificationPass: Task<Void, Never>?
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
        // Clear AI Analysis (#805): the store refuses the in-flight writes; the session state resets here, before
        // the clear returns.
        store.analysisClearedHandler = { [weak self] in await self?.analysisCleared() }
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
    func addFeed(url: String) -> Bool { addFeedNormalized(url: url) != nil }

    /// Adds the feed and returns the address actually subscribed (insecure HTTP may have been upgraded).
    func addFeedNormalized(url: String) -> String? {
        guard let added = subscribe(url: url) else { return nil }
        fetchFeeds()
        return added
    }

    /// Like `addFeedNormalized`, but returns once the new feed has been collected, so a Shortcuts action that
    /// follows (Mark All as Read) sees its stories.
    func addFeedAndCollect(url: String) async -> String? {
        guard let added = subscribe(url: url) else { return nil }
        await fetchFeedsAsync()
        await waitForReplacementRefreshes()
        return added
    }

    /// Another subscription change may have cancelled the refresh a caller waited for and started a replacement;
    /// waits for that too.
    private func waitForReplacementRefreshes() async {
        for _ in 0..<5 {
            await Task.yield()
            guard let replacement = refreshTask else { break }
            _ = await replacement.value
        }
    }

    private func subscribe(url: String) -> String? {
        guard let added = appSettings.addFeed(url: url) else { return nil }
        cancelRefresh()
        feedStatuses[added] = .idle
        return added
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
            // The size limit and the guards name their reason (#928); anything else the XML parser rejected is
            // malformed.
            let error = error as NSError
            articleStore.operationError =
                error.domain == "OPML" && (error.code == 2 || error.code == 3)
                ? "The OPML file could not be imported. \(error.localizedDescription) No subscriptions were changed."
                : "The OPML file could not be imported because it is incomplete or malformed. No subscriptions were changed."
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

    /// One row per subscription for the Publisher Health inspector (#715). The database actor does the reading.
    func publisherHealthRows(now: Date = Date()) async throws -> [PublisherHealthRow] {
        let database = articleStore.database
        let metrics = try await database.feedHealthMetrics(now: now)
        let publishers = try await database.feedPublisherNames()
        let states = try await database.feedFetchStates()
        let empty = FeedHealthMetrics(FeedHealthObservations(), now: now)
        return appSettings.feedURLs.map { url in
            PublisherHealthRow(
                feedURL: url, storedPublisher: publishers[url], metrics: metrics[url] ?? empty,
                health: FeedHealth(states[url], now: now))
        }
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

                await self.fetchFeedsAsync(scheduled: true)
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
                await self?.fetchFeedsAsync(scheduled: true)
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
            await self.fetchFeedsAsync(scheduled: true)
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

    func fetchFeeds(scheduled: Bool = false) {
        Task {
            await fetchFeedsAsync(scheduled: scheduled)
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRunID = nil
        for waiter in manualRefreshWaiters { waiter.resume() }
        manualRefreshWaiters = []
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
        notificationPass?.cancel()
        notificationPass = nil
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

    /// Clear AI Analysis: the runs that would enqueue or warm from pre-clear inputs stop here, the queue and the
    /// coordinator drop their session state, and the store already refuses any write still in flight.
    private func analysisCleared() async {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        overviewWarmupTask?.cancel()
        overviewWarmupTask = nil
        clusteringTask?.cancel()
        clusteringTask = nil
        clusteringRunID = nil
        await enrichmentQueue.analysisCleared()
        await OverviewGenerationCoordinator.shared.analysisCleared()
        await WorldTensionService.shared.analysisCleared()
    }

    /// Why nothing can be stored, or nil while the library is writable: its read-only reason, or that it never opened.
    /// The store opens asynchronously at launch, so this waits for the startup open instead of trusting a notice that
    /// may not be set yet.
    func refreshBlockedReason() async -> String? {
        await articleStore.waitForStartup()
        if let notice = articleStore.databaseHealthNotice { return "The library is read-only. \(notice)" }
        return articleStore.isReady ? nil : "The library could not be opened."
    }

    /// True while nothing can be stored; a manual refresh then says why, once (#787).
    private func refusesCollectionWhileReadOnly(manual: Bool) async -> Bool {
        let reason = await refreshBlockedReason()
        // Stopped or cancelled while waiting for startup: do not report or start anything.
        guard !isStopped, !Task.isCancelled else { return true }
        guard let reason else { return false }
        if manual { articleStore.operationError = "Refresh is off. \(reason)" }
        return true
    }

    /// A feed that failed while a VPN or network switched is healthy, so asking for a refresh retries it at once (#927).
    private func retryConnectivityFailures() async {
        do {
            try await articleStore.database.clearConnectivityBackoff(at: now())
        } catch {
            logger.error("Could not lift connectivity backoff: \(error.localizedDescription)")
        }
    }

    /// Returns once new articles are collected, published and rated. Notification banners and background
    /// classification then run on their own: banners post minutes apart, so no caller waits for them.
    ///
    /// A read-only library (a notice is set) cannot store anything, so nothing is downloaded. A scheduled refresh
    /// skips quietly; a manual one says why once, in the alert where the user sees it (#787).
    func fetchFeedsAsync(scheduled: Bool = false) async {
        guard !isStopped else { return }
        if await refusesCollectionWhileReadOnly(manual: !scheduled) { return }
        if let refreshTask {
            if !scheduled, runningRefreshIsScheduled {
                // A scheduled refresh keeps connectivity backoff, so this request is answered by a refresh after it.
                await withCheckedContinuation { manualRefreshWaiters.append($0) }
            } else {
                _ = await refreshTask.value
            }
            return
        }
        let runID = UUID()
        refreshRunID = runID
        runningRefreshIsScheduled = scheduled
        let task = Task<[FeedArticle], Never> { [weak self] in
            if !scheduled { await self?.retryConnectivityFailures() }
            return await self?.performRefreshPipeline() ?? []
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

        // Taken here so that stopping now drops the request, and resumes its callers, instead of leaving it for later.
        let manualWaiters = manualRefreshWaiters
        manualRefreshWaiters = []
        defer { for waiter in manualWaiters { waiter.resume() } }

        guard !isStopped else { return }
        await pruneIfDue()
        clusterEventsInBackground()
        // Rate before triage. Collection and its spinner have ended; another refresh can proceed.
        await waitForEventClustering()
        if !Task.isCancelled, !isStopped { await notifyAndEnrich(newArticles) }
        // In a task of its own: cancelling this caller, a scheduled refresh, does not cancel the reader's request.
        if !manualWaiters.isEmpty { await Task { [weak self] in await self?.fetchFeedsAsync() }.value }
    }

    /// What Check for Updates found for an open story (#992).
    enum StoryUpdateResult: Equatable, Sendable {
        /// Nothing can be stored; the reason, as `refreshBlockedReason` gives it.
        case refused(String)
        /// Reports that joined the story during the check, subscriptions whose last fetch failed, and whether Low
        /// Power Mode or thermal pressure held back part of the matching.
        case checked(newReports: Int, failedFeeds: Int, deferredMatching: Bool)
    }

    /// Refreshes the subscriptions (or waits for the refresh already running), waits for clustering and compares the
    /// story's reports before and after (#992). Only reports that joined count: a regrouping that removes one adds none.
    func checkForUpdates(storyOf articleID: String) async -> StoryUpdateResult {
        if let reason = await refreshBlockedReason() { return .refused(reason) }
        func members() async -> Set<String> {
            let summary = (try? await articleStore.eventFeedSummaries(for: [articleID]))?.first
            return Set(summary?.members.map(\.articleID) ?? [articleID])
        }
        let before = await members()
        await fetchFeedsAsync()
        await waitForReplacementRefreshes()
        // A refresh that was already running returns before its own clustering starts; ask for one more pass.
        clusterEventsInBackground()
        await waitForEventClustering()
        let after = await members()
        let subscribed = Set(appSettings.effectiveFeedURLs)
        let failed = feedStatuses.filter { subscribed.contains($0.key) && $0.value.errorMessage != nil }.count
        return .checked(
            newReports: after.subtracting(before).count, failedFeeds: failed, deferredMatching: !allowsBackgroundWork())
    }

    /// Starts the notification pass for the new stories of a finished refresh and enriches in the background.
    private func notifyAndEnrich(_ newArticles: [FeedArticle]) async {
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
            // banners (#665). Nobody awaits a pass: its banners post minutes apart.
            let previous = notificationPass
            notificationPass = Task { [weak self] in
                // Cancelling the latest pass (stopBackgroundWork) cancels the one it waits for as well.
                await withTaskCancellationHandler {
                    await previous?.value
                } onCancel: {
                    previous?.cancel()
                }
                // The wait can last minutes: a pass queued before notifications were turned off posts nothing.
                guard await self?.notificationsStillEnabled() == true else { return }
                await self?.deliverNotifications(notifiable)
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
            delivery.continues = { [weak self] in
                await self?.allowsFullBanners() ?? false
            }
            delivery.record = { [weak self] banner in
                // Banners post minutes apart: a priority or normal banner is recorded when it posts, so its rolling
                // window measures from the banner the reader saw. A starred banner is recorded at the pass start,
                // the cutoff its pending stories were read at, so a starred story that arrives while the banner
                // waits is still pending for the next one.
                let at = banner.lane == .starred ? posted : (await self?.currentDate() ?? posted)
                try? await database.recordNotification(banner, at: at)
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

    /// The injected clock, read on the main actor so a `@Sendable` closure can ask for the time.
    private func currentDate() -> Date { now() }

    /// Whether a running full-mode pass may post its next banner: the live mode, not the one it started with.
    private func allowsFullBanners() -> Bool {
        appSettings.notificationsEnabled && appSettings.notificationMode == .full
    }

    /// Whether a queued pass may start at all once its wait ends; the mode it reads then is already live.
    private func notificationsStillEnabled() -> Bool {
        appSettings.notificationsEnabled && !isStopped
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
        // A future date (#981) must not put a story first in the notification order.
        let sortClock = Date()
        allParsed.sort { min($0.pubDate, sortClock) > min($1.pubDate, sortClock) }

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
                let work = Task.detached(priority: .utility) { () throws -> ClusteringPass in
                    let started = ProcessInfo.processInfo.systemUptime
                    let report = try await EventClusterer.run(in: database, allowsEnergy: allowsEnergy)
                    return ClusteringPass(
                        report: report, seconds: ProcessInfo.processInfo.systemUptime - started, finishedAt: Date())
                }
                let result = await withTaskCancellationHandler {
                    await work.result
                } onCancel: {
                    work.cancel()
                }
                guard let self, self.clusteringRunID == runID, !Task.isCancelled else { return }
                switch result {
                case .success(let pass):
                    self.lastClusteringPass = pass
                    if !pass.report.changedEvents.isEmpty { self.articleStore.noteEventsChanged() }
                case .failure(let error):
                    if !(error is CancellationError) {
                        self.logger.error("Event clustering failed: \(error.localizedDescription)")
                    }
                    // Memberships commit per article: a pass that stopped early may still have changed events.
                    self.articleStore.noteEventsChanged()
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
                self.lastImageLookup = report
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
