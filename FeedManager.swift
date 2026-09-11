import Foundation
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

    private var backgroundTimer: Timer?
    private var backgroundActivity: NSBackgroundActivityScheduler?

    // Backward-compatibility forwarders for existing UI / View bindings
    var feedURLs: [String] { appSettings.feedURLs }
    var userSections: [String] { appSettings.userSections }
    var fetchIntervalMinutes: Double { appSettings.fetchIntervalMinutes }
    var notificationsEnabled: Bool { appSettings.notificationsEnabled }
    var aiEnabled: Bool { appSettings.aiEnabled }
    var privateNotificationsEnabled: Bool { appSettings.privateNotificationsEnabled }

    init(settings: AppSettings? = nil, store: ArticleStore? = nil) {
        self.appSettings = settings ?? AppSettings.shared
        self.articleStore = store ?? ArticleStore.shared
        super.init()
        loadCachedArticles()
        startBackgroundFetch()
    }

    // MARK: - Feed URL Management (delegates to AppSettings)

    func addFeed(url: String) {
        if let added = appSettings.addFeed(url: url) {
            feedStatuses[added] = .idle
            fetchFeeds()
        }
    }

    func removeFeed(url: String) {
        appSettings.removeFeed(url: url)
        feedStatuses.removeValue(forKey: url)
        fetchFeeds()
    }

    // MARK: - OPML Portability

    @discardableResult
    func importFeeds(from opmlData: Data) -> Int {
        let count = appSettings.importFeeds(from: opmlData)
        if count > 0 {
            fetchFeeds()
        }
        return count
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

    private static let sectionKeywords: [String: [String]] = [
        "Entertainment": ["entertainment", "movie", "film", "celebrity", "music", "tv show", "television", "hollywood", "streaming", "netflix", "disney", "actor", "actress", "box office", "concert", "album", "grammy", "oscar", "emmy"],
        "Politics": ["politic", "congress", "senate", "democrat", "republican", "election", "vote", "legislation", "government", "white house", "parliament", "policy", "campaign", "liberal", "conservative"],
        "U.S. Politics": ["politic", "congress", "senate", "democrat", "republican", "election", "vote", "legislation", "white house", "biden", "trump", "campaign"],
        "Business": ["business", "market", "stock", "economy", "finance", "wall street", "investor", "startup", "venture", "ipo", "revenue", "profit", "earnings", "trade", "inflation", "bank"],
        "Tech": ["tech", "software", "hardware", "ai ", "artificial intelligence", "computer", "digital", "startup", "silicon valley", "apple", "google", "microsoft", "amazon", "cyber", "programming", "developer", "app ", "gadget", "robot", "machine learning", "chip", "semiconductor"],
        "Food": ["food", "recipe", "restaurant", "chef", "cooking", "culinary", "dining", "meal", "cuisine", "ingredient"],
        "Health & Wellness": ["health", "medical", "doctor", "hospital", "disease", "treatment", "vaccine", "mental health", "wellness", "fitness", "exercise", "nutrition", "diet", "therapy", "clinical"],
        "Lifestyle": ["lifestyle", "fashion", "travel", "home", "design", "decor", "beauty", "style", "trend", "luxury", "wellness"],
        "Science": ["science", "research", "study", "discovery", "space", "nasa", "physics", "biology", "chemistry", "climate", "environment", "species", "experiment", "laboratory", "quantum", "astronomy", "mars", "planet", "genome"],
        "Fashion": ["fashion", "style", "designer", "runway", "clothing", "brand", "trend", "model", "outfit", "accessory"],
        "Travel": ["travel", "flight", "airline", "hotel", "tourism", "destination", "vacation", "trip", "airport", "cruise"],
        "Sports": ["sport", "football", "basketball", "soccer", "baseball", "nfl", "nba", "mlb", "athlete", "championship", "match", "team", "league", "coach", "score", "olympic", "tennis", "golf"],
        "World": ["world", "international", "global", "europe", "asia", "africa", "foreign", "nation", "united nations", "war", "conflict", "diplomat", "treaty"]
    ]

    func articles(for section: String) -> [FeedArticle] {
        if section == "Today" || section == "Saved Stories" || section == "History" { return articles }

        guard let keywords = Self.sectionKeywords[section] else {
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
            let loaded = await self.articleStore.fetchArticles()
            if !loaded.isEmpty {
                self.articles = loaded
            }
        }
    }

    // MARK: - Background Scheduling
    // macOS schedules opportunistic background refreshes according to the configured interval and system conditions.

    func startBackgroundFetch() {
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

    func fetchFeedsAsync() async {
        do {
            try await RefreshCoordinator.shared.executeRefresh { @Sendable [weak self] in
                guard let self = self else { return }
                await self.performRefreshPipeline()
            }
        } catch {
            logger.error("Coordinated feed refresh failed: \(error.localizedDescription)")
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

        let results = await FeedFetcher.shared.fetchAllFeeds(
            urls: appSettings.feedURLs,
            allowHTTP: appSettings.allowInsecureHTTP
        )

        var allParsed = [FeedArticle]()
        for res in results {
            if let err = res.error {
                feedStatuses[res.urlString] = .failed(err)
            } else {
                feedStatuses[res.urlString] = .idle
                if let arts = res.articles {
                    allParsed.append(contentsOf: arts)
                }
            }
        }

        isAnyFeedLoading = false
        allParsed.sort { $0.pubDate > $1.pubDate }

        let existingIds = Set(articles.map { $0.id })
        let newArticles = allParsed.filter { !existingIds.contains($0.id) }

        await articleStore.batchUpsert(articles: allParsed)
        let stored = await articleStore.fetchArticles()
        self.articles = stored.isEmpty ? allParsed : stored

        if appSettings.notificationsEnabled && !newArticles.isEmpty {
            await NotificationService.shared.triageAndNotify(
                newArticles: newArticles,
                mode: appSettings.notificationMode
            )
        }

        enrichArticlesInBackground()
    }

    // MARK: - Background Enrichment

    private func enrichArticlesInBackground() {
        guard appSettings.aiEnabled else { return }

        let snapshot = articles
        let allowHTTP = appSettings.allowInsecureHTTP

        Task {
            // Cancel previous background backlog on new ingest
            await EnrichmentQueue.shared.cancelAll(reason: .superseded)

            // Enqueue top 5 unread articles as high priority, rest as background
            for (index, article) in snapshot.enumerated() {
                let priority: EnrichmentPriority = (index < 5) ? .high : .background
                await EnrichmentQueue.shared.enqueue(
                    article: article,
                    priority: priority,
                    allowHTTP: allowHTTP
                )
            }
        }
    }

    // MARK: - Legacy Helper Forwarder

    nonisolated static func isBlockedLocalAddress(_ host: String) -> Bool {
        switch IPAddressValidator.validateHost(host) {
        case .blocked: return true
        default: return false
        }
    }
}
