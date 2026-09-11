import Foundation
import NaturalLanguage
import UserNotifications

/// Orchestration layer coordinating feed fetching, article caching, enrichment, and section filtering.
@MainActor
class FeedManager: NSObject, ObservableObject {
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
    private var enrichmentTask: Task<Void, Never>?

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

    func startBackgroundFetch() {
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: appSettings.fetchIntervalMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchFeeds()
            }
        }
    }

    // MARK: - Ingestion Pipeline

    func fetchFeeds() {
        Task {
            await fetchFeedsAsync()
        }
    }

    func fetchFeedsAsync() async {
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
                privateNotificationsEnabled: appSettings.privateNotificationsEnabled
            )
        }

        enrichArticlesInBackground()
    }

    // MARK: - Background Enrichment

    struct EnrichedResult: Sendable {
        let articleId: String
        let summary: String?
        let category: String?
        let content: String?
        let image: String?
    }

    private func enrichArticlesInBackground() {
        guard appSettings.aiEnabled else { return }
        enrichmentTask?.cancel()

        let snapshot = articles
        let allowHTTP = appSettings.allowInsecureHTTP

        enrichmentTask = Task {
            let enrichedItems: [EnrichedResult] = await withTaskGroup(of: EnrichedResult?.self) { group in
                var activeCount = 0
                var collected = [EnrichedResult]()

                for article in snapshot {
                    if Task.isCancelled { break }
                    if activeCount >= 3 {
                        if let item = await group.next(), let val = item {
                            collected.append(val)
                        }
                        activeCount -= 1
                    }

                    activeCount += 1
                    group.addTask {
                        if Task.isCancelled { return nil }

                        let summary = await AIManager.shared.analyzeArticle(
                            title: article.title,
                            description: article.description
                        )
                        if Task.isCancelled { return nil }

                        let aiCategory = AIManager.shared.categorizeArticle(
                            title: article.title,
                            description: article.description,
                            rssCategory: article.category
                        )
                        if Task.isCancelled { return nil }

                        var fetchedContent: String?
                        var fetchedImage: String?
                        if article.fullContent == nil || article.fullContent!.isEmpty {
                            let fetchRes = await WebContentExtractor.fetchFullContentAndImage(for: article.link, allowHTTP: allowHTTP)
                            fetchedContent = fetchRes.0
                            fetchedImage = fetchRes.1
                        }

                        return EnrichedResult(
                            articleId: article.id,
                            summary: summary,
                            category: aiCategory,
                            content: fetchedContent,
                            image: fetchedImage
                        )
                    }
                }

                for await remaining in group {
                    if let val = remaining {
                        collected.append(val)
                    }
                }
                return collected
            }

            guard !Task.isCancelled else { return }

            for item in enrichedItems {
                await self.articleStore.updateEnrichment(
                    id: item.articleId,
                    summary: item.summary,
                    category: item.category,
                    content: item.content,
                    image: item.image
                )
                if let idx = self.articles.firstIndex(where: { $0.id == item.articleId }) {
                    var updated = self.articles[idx]
                    if let s = item.summary { updated.aiSummary = s }
                    if let c = item.category { updated.category = c }
                    if let cnt = item.content {
                        updated.fullContent = cnt
                        updated.contentFetched = true
                    }
                    if let img = item.image, updated.imageUrl == nil {
                        updated.imageUrl = img
                    }
                    self.articles[idx] = updated
                }
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
