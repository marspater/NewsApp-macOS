import Foundation

/// Centralized application settings and user preference store.
/// Decouples persistence and configuration state from feed ingestion and network services.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Persistence Keys
    static let feedURLsKey = "saved_feed_urls"
    static let userSectionsKey = "user_sections"
    static let fetchIntervalKey = "feed_fetch_interval_minutes"
    static let notificationsEnabledKey = "notifications_enabled"
    static let aiEnabledKey = "ai_enabled"
    static let privateNotificationsEnabledKey = "private_notifications_enabled"
    static let notificationModeKey = "notification_mode"
    static let allowInsecureHTTPKey = "allow_insecure_http"
    static let mutedSourcesKey = "muted_sources"
    static let mutedTopicsKey = "muted_topics"

    enum NotificationMode: String, CaseIterable, Identifiable, Sendable {
        case full = "full"         // Headlines + snippets + images
        case privacy = "private" // Generic non-identifying updates
        case minimal = "minimal"   // Aggregated count only

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .privacy: return "Private mode: Displays generic alerts with no identifying headlines, sources, or preview text."
            case .minimal: return "Minimal mode: Aggregates new stories into a single count summary (e.g., '5 new articles')."
            case .full: return "Full mode: Displays article headline, source publication, and lead image banner."
            }
        }

        var displayName: String {
            switch self {
            case .full: return "Full (Headlines & Images)"
            case .privacy: return "Private (Generic Alerts)"
            case .minimal: return "Minimal (Count Only)"
            }
        }
    }

    static let defaultSections = [
        "Entertainment", "Politics", "Business", "Tech",
        "Food", "Health & Wellness", "Lifestyle", "Science"
    ]

    static let defaultFeeds = [
        "https://feeds.arstechnica.com/arstechnica/index",
        "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml",
        "https://feeds.bbci.co.uk/news/rss.xml"
    ]

    // MARK: - Published Properties

    private let defaults: UserDefaults

    @Published var feedURLs: [String]
    @Published var userSections: [String]
    @Published var fetchIntervalMinutes: Double
    @Published var notificationsEnabled: Bool
    @Published var aiEnabled: Bool
    @Published var privateNotificationsEnabled: Bool
    @Published var notificationMode: NotificationMode
    @Published var allowInsecureHTTP: Bool
    /// The reader's muted publisher hosts and topics; empty unless the reader adds rules.
    @Published private(set) var muteRules: MuteRules

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let savedUrls = defaults.stringArray(forKey: Self.feedURLsKey) {
            self.feedURLs = savedUrls
        } else {
            self.feedURLs = Self.defaultFeeds
        }

        if let savedSections = defaults.stringArray(forKey: Self.userSectionsKey) {
            self.userSections = savedSections
        } else {
            self.userSections = Self.defaultSections
        }

        if defaults.object(forKey: Self.fetchIntervalKey) != nil {
            self.fetchIntervalMinutes = defaults.double(forKey: Self.fetchIntervalKey)
        } else {
            self.fetchIntervalMinutes = 15.0
        }

        if defaults.object(forKey: Self.notificationsEnabledKey) != nil {
            self.notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
        } else {
            self.notificationsEnabled = true
        }

        if defaults.object(forKey: Self.aiEnabledKey) != nil {
            self.aiEnabled = defaults.bool(forKey: Self.aiEnabledKey)
        } else {
            self.aiEnabled = true
        }

        // Migration semantics:
        // 1. If notificationMode exists -> use it
        // 2. If absent and privateNotificationsEnabled == true -> .privacy
        // 3. If absent and privateNotificationsEnabled == false -> .full
        // 4. Persist migrated key to prevent repeating fallback
        if let modeRaw = defaults.string(forKey: Self.notificationModeKey),
           let mode = NotificationMode(rawValue: modeRaw) {
            self.notificationMode = mode
            self.privateNotificationsEnabled = (mode == .privacy)
        } else if defaults.object(forKey: Self.privateNotificationsEnabledKey) != nil && defaults.bool(forKey: Self.privateNotificationsEnabledKey) {
            self.notificationMode = .privacy
            self.privateNotificationsEnabled = true
            defaults.set(NotificationMode.privacy.rawValue, forKey: Self.notificationModeKey)
        } else {
            self.notificationMode = .full
            self.privateNotificationsEnabled = false
            defaults.set(NotificationMode.full.rawValue, forKey: Self.notificationModeKey)
        }

        self.allowInsecureHTTP = defaults.bool(forKey: Self.allowInsecureHTTPKey)
        self.muteRules = MuteRules(sources: defaults.stringArray(forKey: Self.mutedSourcesKey) ?? [],
                                   topics: defaults.stringArray(forKey: Self.mutedTopicsKey) ?? [])
    }

    // MARK: - URL Normalization

    /// Normalizes and validates a feed subscription URL using URLComponents.
    /// Handles scheme upgrades, host lowercasing, and trailing slash cleanup without brittle string replacement.
    static func normalizeFeedURL(_ raw: String, allowInsecureHTTP: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let hasScheme = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        let withScheme = hasScheme ? trimmed : "https://" + trimmed

        guard let url = URL(string: withScheme),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        if !allowInsecureHTTP && components.scheme == "http" {
            components.scheme = "https"
        }

        var path = components.path
        if path == "/" {
            path = ""
            components.path = path
        } else if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
            components.path = path
        }

        return components.url?.absoluteString
    }


    // MARK: - Mutation APIs

    func addFeed(url: String) -> String? {
        guard let normalized = Self.normalizeFeedURL(url, allowInsecureHTTP: allowInsecureHTTP) else {
            return nil
        }

        guard !feedURLs.contains(normalized) else { return nil }
        feedURLs.append(normalized)
        saveFeeds()
        return normalized
    }

    func removeFeed(url: String) {
        feedURLs.removeAll { $0 == url }
        saveFeeds()
    }

    // MARK: - Catalog

    func isSubscribed(_ feed: CatalogFeed) -> Bool {
        feedURLs.contains(feed.url)
    }

    /// Subscribes to feeds the user chose from the catalog, skipping any already subscribed. Returns how many were added.
    @discardableResult
    func addCatalogFeeds(_ feeds: [CatalogFeed]) -> Int {
        let added = feeds.map(\.url).filter { !feedURLs.contains($0) }
        guard !added.isEmpty else { return 0 }
        feedURLs.append(contentsOf: added)
        saveFeeds()
        return added.count
    }

    func addSection(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !userSections.contains(trimmed) else { return }
        userSections.append(trimmed)
        saveSections()
    }

    func removeSection(_ name: String) {
        userSections.removeAll { $0 == name }
        saveSections()
    }

    func setFetchInterval(minutes: Double) {
        fetchIntervalMinutes = minutes
        defaults.set(minutes, forKey: Self.fetchIntervalKey)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: Self.notificationsEnabledKey)
    }

    func setAIEnabled(_ enabled: Bool) {
        aiEnabled = enabled
        defaults.set(enabled, forKey: Self.aiEnabledKey)
    }

    func setNotificationMode(_ mode: NotificationMode) {
        notificationMode = mode
        privateNotificationsEnabled = (mode == .privacy)
        defaults.set(mode.rawValue, forKey: Self.notificationModeKey)
        defaults.set(mode == .privacy, forKey: Self.privateNotificationsEnabledKey)
    }

    func setPrivateNotificationsEnabled(_ enabled: Bool) {
        setNotificationMode(enabled ? .privacy : .full)
    }

    func setAllowInsecureHTTP(_ allowed: Bool) {
        allowInsecureHTTP = allowed
        defaults.set(allowed, forKey: Self.allowInsecureHTTPKey)
    }

    // MARK: - Muting

    /// Mutes a publisher host given as a hostname or URL. Returns the stored host, or nil if nothing was added.
    @discardableResult
    func muteSource(_ raw: String) -> String? {
        var rules = muteRules
        guard let host = rules.addSource(raw) else { return nil }
        setMuteRules(rules)
        return host
    }

    /// Mutes a topic word or phrase. Returns the stored topic, or nil if nothing was added.
    @discardableResult
    func muteTopic(_ raw: String) -> String? {
        var rules = muteRules
        guard let topic = rules.addTopic(raw) else { return nil }
        setMuteRules(rules)
        return topic
    }

    func unmuteSource(_ host: String) {
        var rules = muteRules
        rules.removeSource(host)
        setMuteRules(rules)
    }

    func unmuteTopic(_ topic: String) {
        var rules = muteRules
        rules.removeTopic(topic)
        setMuteRules(rules)
    }

    /// Removes every muting rule.
    func clearMuting() {
        setMuteRules(MuteRules())
    }

    private func setMuteRules(_ rules: MuteRules) {
        muteRules = rules
        defaults.set(rules.sources, forKey: Self.mutedSourcesKey)
        defaults.set(rules.topics, forKey: Self.mutedTopicsKey)
    }

    // MARK: - OPML Portability

    @discardableResult
    func importFeeds(from opmlData: Data) -> Int {
        let items = OPMLParser.parse(data: opmlData)
        var addedCount = 0
        var sectionsChanged = false
        for item in items {
            guard let normalized = Self.normalizeFeedURL(item.url, allowInsecureHTTP: allowInsecureHTTP) else {
                continue
            }

            if !feedURLs.contains(normalized) {
                feedURLs.append(normalized)
                addedCount += 1
            }
            if let folder = item.folder, !folder.isEmpty, !userSections.contains(folder) {
                userSections.append(folder)
                sectionsChanged = true
            }
        }
        if addedCount > 0 {
            saveFeeds()
        }
        if sectionsChanged { saveSections() }
        return addedCount
    }

    func exportOPML() -> String {
        return OPMLExporter.generateOPML(feedURLs: feedURLs)
    }

    private func saveFeeds() {
        defaults.set(feedURLs, forKey: Self.feedURLsKey)
    }

    private func saveSections() {
        defaults.set(userSections, forKey: Self.userSectionsKey)
    }
}

