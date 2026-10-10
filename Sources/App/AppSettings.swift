import Foundation
import SwiftUI

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
    static let tensionCollectionOptInKey = "tension_collection_opt_in"
    static let retiredFeedsVersionKey = "retired_feeds_version"
    static let dismissedAdvisoriesKey = "dismissed_advisories"

    enum NotificationMode: String, CaseIterable, Identifiable, Sendable {
        case full = "full"  // Headlines + snippets + images
        case privacy = "private"  // Generic non-identifying updates
        case minimal = "minimal"  // Aggregated count only

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .privacy:
                return "Private mode: Displays generic alerts with no identifying headlines, sources, or preview text."
            case .minimal:
                return "Minimal mode: Aggregates new stories into a single count summary (e.g., '5 new articles')."
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
        "Food", "Health & Wellness", "Lifestyle", "Science",
    ]

    static let defaultFeeds = [
        "https://feeds.arstechnica.com/arstechnica/index",
        "https://feeds.bbci.co.uk/news/rss.xml",
    ]

    /// Feeds the app no longer carries, with the retirement version that removed them. The app carries only free,
    /// open sources whose stories open in the reader. Subscriptions to a retired feed end once, when settings first
    /// load at or after its version; a later manual subscription stays.
    static let retiredFeeds: [(url: String, version: Int)] = [
        // Article pages answer HTTP 403 to automated readers, so stories only open in Web view.
        ("https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml", 1),
        // Removed from the catalog as low-quality news.
        ("https://wiadomosci.onet.pl/.feed", 2),
    ]
    static var retiredFeedsVersion: Int { retiredFeeds.map(\.version).max() ?? 0 }

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
    @Published var tensionCollectionOptIn: Bool
    /// The reader's muted publisher hosts and topics; empty unless the reader adds rules.
    @Published private(set) var muteRules: MuteRules
    /// Mapping of normalized feed URL to the latest advisory date dismissed by the reader.
    @Published private(set) var dismissedAdvisories: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let savedUrls = defaults.stringArray(forKey: Self.feedURLsKey) {
            // Catalog feeds in languages that are not supported yet are parked; earlier subscriptions to them end.
            let parked = Set(FeedCatalog.parkedFeeds.map(\.url))
            // Settings from the first retirement stored only a flag; it means version 1 was applied.
            let applied =
                defaults.object(forKey: Self.retiredFeedsVersionKey) as? Int
                ?? (defaults.bool(forKey: "retired_default_feeds_v1") ? 1 : 0)
            let retired = Set(Self.retiredFeeds.filter { $0.version > applied }.map(\.url))
            let kept = savedUrls.filter { !parked.contains($0) && !retired.contains($0) }
            if kept.count != savedUrls.count { defaults.set(kept, forKey: Self.feedURLsKey) }
            self.feedURLs = kept
        } else {
            self.feedURLs = Self.defaultFeeds
        }
        defaults.set(Self.retiredFeedsVersion, forKey: Self.retiredFeedsVersionKey)

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
            let mode = NotificationMode(rawValue: modeRaw)
        {
            self.notificationMode = mode
            self.privateNotificationsEnabled = (mode == .privacy)
        } else if defaults.object(forKey: Self.privateNotificationsEnabledKey) != nil
            && defaults.bool(forKey: Self.privateNotificationsEnabledKey)
        {
            self.notificationMode = .privacy
            self.privateNotificationsEnabled = true
            defaults.set(NotificationMode.privacy.rawValue, forKey: Self.notificationModeKey)
        } else {
            self.notificationMode = .full
            self.privateNotificationsEnabled = false
            defaults.set(NotificationMode.full.rawValue, forKey: Self.notificationModeKey)
        }

        self.allowInsecureHTTP = defaults.bool(forKey: Self.allowInsecureHTTPKey)
        self.tensionCollectionOptIn = defaults.bool(forKey: Self.tensionCollectionOptInKey)
        self.muteRules = MuteRules(
            sources: defaults.stringArray(forKey: Self.mutedSourcesKey) ?? [],
            topics: defaults.stringArray(forKey: Self.mutedTopicsKey) ?? [])
        self.dismissedAdvisories =
            (defaults.dictionary(forKey: Self.dismissedAdvisoriesKey) as? [String: String]) ?? [:]
    }

    /// Panel feeds whose stories must outlive waiting-story expiry, because the tension index rebuilds past days from them.
    var tensionRetainedFeedURLs: [String] {
        tensionCollectionOptIn ? TensionMethodology.v1.panel.map(\.url) : []
    }

    /// Feed URLs to fetch during refresh: user subscriptions, plus panel feeds when opted in to tension collection.
    var effectiveFeedURLs: [String] {
        guard tensionCollectionOptIn else { return feedURLs }
        var result = feedURLs
        let panelURLs = TensionMethodology.v1.panel.map(\.url)
        for url in panelURLs where !result.contains(url) {
            result.append(url)
        }
        return result
    }

    // MARK: - URL Normalization

    /// Normalizes and validates a feed subscription URL using URLComponents.
    /// Handles scheme upgrades, host lowercasing, and trailing slash cleanup without brittle string replacement.
    nonisolated static func normalizeFeedURL(_ raw: String, allowInsecureHTTP: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let hasScheme = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        let withScheme = hasScheme ? trimmed : "https://" + trimmed

        guard let url = URL(string: withScheme),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty
        else {
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

    // MARK: - Advisories

    /// Acknowledges and dismisses a dated advisory for a feed URL so the reader is not persistently nagged.
    func dismissAdvisory(for url: String, date: String) {
        guard let normalized = Self.normalizeFeedURL(url, allowInsecureHTTP: allowInsecureHTTP) else { return }
        var updated = dismissedAdvisories
        updated[normalized] = date
        dismissedAdvisories = updated
        defaults.set(updated, forKey: Self.dismissedAdvisoriesKey)
    }

    /// Whether an advisory dated on or before `date` has already been acknowledged by the reader.
    func isAdvisoryDismissed(for url: String, date: String) -> Bool {
        guard let normalized = Self.normalizeFeedURL(url, allowInsecureHTTP: allowInsecureHTTP) else { return false }
        guard let dismissedDate = dismissedAdvisories[normalized] else { return false }
        return dismissedDate >= date
    }

    /// The maintainer advisory to show for a feed URL unless the reader dismissed it; every view shows advisories through this.
    func visibleAdvisory(for url: String) -> FeedAdvisory? {
        guard let advisory = FeedCatalog.advisory(for: url), !isAdvisoryDismissed(for: url, date: advisory.date) else {
            return nil
        }
        return advisory
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

    func setTensionCollectionOptIn(_ enabled: Bool) {
        tensionCollectionOptIn = enabled
        defaults.set(enabled, forKey: Self.tensionCollectionOptInKey)
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

    /// The muting action for a story link's publisher host: unmute the rules covering it, or mute the host.
    func sourceMuting(for link: String) -> (title: String, apply: () -> Void)? {
        let covering = muteRules.matchedSources(link: link)
        if let rule = covering.first {
            return (
                "Unmute \(rule)",
                { [weak self] in
                    guard let self = self else { return }
                    for source in covering { self.unmuteSource(source) }
                }
            )
        }
        guard let host = MuteRules.host(link) else { return nil }
        return (
            "Mute \(host)",
            { [weak self] in
                _ = self?.muteSource(host)
            }
        )
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

        var knownFeeds = Set(feedURLs)
        var knownSections = Set(userSections)

        for item in items {
            guard let normalized = Self.normalizeFeedURL(item.url, allowInsecureHTTP: allowInsecureHTTP) else {
                continue
            }

            if !knownFeeds.contains(normalized) {
                knownFeeds.insert(normalized)
                feedURLs.append(normalized)
                addedCount += 1
            }
            if let folder = item.folder, !folder.isEmpty, !knownSections.contains(folder) {
                knownSections.insert(folder)
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

// MARK: - System Settings Overrides (Isolated QA & Audits)

/// System settings overrides for isolated native QA, accessibility audits, and automated runs.
/// Allows simulating VoiceOver, Increase Contrast, Reduce Motion, and Text Scaling
/// without altering global macOS system preferences.
public struct SystemSettingsOverrides: Sendable {
    public var contrast: ColorSchemeContrast?
    public var reduceMotion: Bool?
    public var voiceOverEnabled: Bool?
    public var textScale: CGFloat?

    public init(
        contrast: ColorSchemeContrast? = nil,
        reduceMotion: Bool? = nil,
        voiceOverEnabled: Bool? = nil,
        textScale: CGFloat? = nil
    ) {
        self.contrast = contrast
        self.reduceMotion = reduceMotion
        self.voiceOverEnabled = voiceOverEnabled
        self.textScale = textScale
    }

    public static func from(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> SystemSettingsOverrides {
        var overrides = SystemSettingsOverrides()

        // 1. UserDefaults check (handles -key value from standard macOS launch args)
        if defaults.object(forKey: "increase_contrast") != nil || defaults.object(forKey: "IncreaseContrast") != nil
            || defaults.object(forKey: "AppleIncreaseContrast") != nil
        {
            let val =
                defaults.bool(forKey: "increase_contrast") || defaults.bool(forKey: "IncreaseContrast")
                || defaults.bool(forKey: "AppleIncreaseContrast")
            overrides.contrast = val ? .increased : .standard
        }
        if defaults.object(forKey: "reduce_motion") != nil || defaults.object(forKey: "ReduceMotion") != nil
            || defaults.object(forKey: "AppleReduceMotion") != nil
        {
            overrides.reduceMotion =
                defaults.bool(forKey: "reduce_motion") || defaults.bool(forKey: "ReduceMotion")
                || defaults.bool(forKey: "AppleReduceMotion")
        }
        if defaults.object(forKey: "voice_over") != nil || defaults.object(forKey: "VoiceOver") != nil
            || defaults.object(forKey: "AppleAccessibilityVoiceOverEnabled") != nil
        {
            overrides.voiceOverEnabled =
                defaults.bool(forKey: "voice_over") || defaults.bool(forKey: "VoiceOver")
                || defaults.bool(forKey: "AppleAccessibilityVoiceOverEnabled")
        }
        if defaults.object(forKey: "text_scale") != nil {
            let scale = defaults.double(forKey: "text_scale")
            if scale > 0 { overrides.textScale = CGFloat(scale) }
        } else if defaults.object(forKey: "AppleTextScaleFactor") != nil {
            let scale = defaults.double(forKey: "AppleTextScaleFactor")
            if scale > 0 { overrides.textScale = CGFloat(scale) }
        }

        // 2. Direct CLI flags (--increase-contrast, --reduce-motion, etc.)
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--increase-contrast" {
                overrides.contrast = .increased
            } else if arg == "--standard-contrast" {
                overrides.contrast = .standard
            } else if arg == "--reduce-motion" {
                overrides.reduceMotion = true
            } else if arg == "--no-reduce-motion" {
                overrides.reduceMotion = false
            } else if arg == "--voice-over" || arg == "--simulate-voice-over" {
                overrides.voiceOverEnabled = true
            } else if arg == "--no-voice-over" {
                overrides.voiceOverEnabled = false
            } else if (arg == "--text-scale" || arg == "-text-scale") && i + 1 < arguments.count {
                if let val = Double(arguments[i + 1]), val > 0 {
                    overrides.textScale = CGFloat(val)
                }
                i += 1
            }
            i += 1
        }
        return overrides
    }
}

// MARK: - Effective Environment Keys for System Settings Overrides

private struct OverrideContrastKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}

private struct OverrideReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct OverrideVoiceOverKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    public var overrideContrast: ColorSchemeContrast? {
        get { self[OverrideContrastKey.self] }
        set { self[OverrideContrastKey.self] = newValue }
    }

    public var overrideReduceMotion: Bool? {
        get { self[OverrideReduceMotionKey.self] }
        set { self[OverrideReduceMotionKey.self] = newValue }
    }

    public var overrideVoiceOver: Bool? {
        get { self[OverrideVoiceOverKey.self] }
        set { self[OverrideVoiceOverKey.self] = newValue }
    }

    /// Effective contrast: uses override if set (e.g. via CLI / isolated build), otherwise system setting.
    public var effectiveContrast: ColorSchemeContrast {
        overrideContrast ?? colorSchemeContrast
    }

    /// Effective reduce motion: uses override if set, otherwise system setting.
    public var effectiveReduceMotion: Bool {
        overrideReduceMotion ?? accessibilityReduceMotion
    }

    /// Effective VoiceOver status: uses override if set, otherwise system setting.
    public var effectiveVoiceOver: Bool {
        overrideVoiceOver ?? accessibilityVoiceOverEnabled
    }
}

/// Applies simulated accessibility and display system settings to the SwiftUI environment.
public struct SystemSettingsOverrideModifier: ViewModifier {
    public let overrides: SystemSettingsOverrides

    public init(overrides: SystemSettingsOverrides = .from()) {
        self.overrides = overrides
    }

    public func body(content: Content) -> some View {
        var result = AnyView(content)
        if let contrast = overrides.contrast {
            result = AnyView(result.environment(\.overrideContrast, contrast))
        }
        if let reduceMotion = overrides.reduceMotion {
            result = AnyView(result.environment(\.overrideReduceMotion, reduceMotion))
        }
        if let voiceOver = overrides.voiceOverEnabled {
            result = AnyView(result.environment(\.overrideVoiceOver, voiceOver))
        }
        if let textScale = overrides.textScale {
            result = AnyView(result.environment(\.dynamicTypeSize, dynamicTypeSize(for: textScale)))
        }
        return result
    }

    private func dynamicTypeSize(for scale: CGFloat) -> DynamicTypeSize {
        if scale <= 0.85 { return .small }
        if scale <= 1.05 { return .large }
        if scale <= 1.20 { return .xLarge }
        if scale <= 1.35 { return .xxLarge }
        if scale <= 1.50 { return .xxxLarge }
        if scale <= 1.70 { return .accessibility1 }
        if scale <= 1.90 { return .accessibility2 }
        return .accessibility3
    }
}
