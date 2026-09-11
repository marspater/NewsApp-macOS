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
    static let allowInsecureHTTPKey = "allow_insecure_http"

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

    @Published var feedURLs: [String]
    @Published var userSections: [String]
    @Published var fetchIntervalMinutes: Double
    @Published var notificationsEnabled: Bool
    @Published var aiEnabled: Bool
    @Published var privateNotificationsEnabled: Bool
    @Published var allowInsecureHTTP: Bool

    init() {
        let defaults = UserDefaults.standard

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

        if defaults.object(forKey: Self.privateNotificationsEnabledKey) != nil {
            self.privateNotificationsEnabled = defaults.bool(forKey: Self.privateNotificationsEnabledKey)
        } else {
            self.privateNotificationsEnabled = false
        }

        self.allowInsecureHTTP = defaults.bool(forKey: Self.allowInsecureHTTPKey)
    }

    // MARK: - Mutation APIs

    func addFeed(url: String) -> String? {
        var finalURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalURL.hasPrefix("https://") && !finalURL.hasPrefix("http://") {
            finalURL = "https://" + finalURL
        }
        guard let nsURL = URL(string: finalURL), nsURL.host != nil else {
            return nil
        }

        // Scheme check
        if !allowInsecureHTTP && nsURL.scheme?.lowercased() == "http" {
            finalURL = finalURL.replacingOccurrences(of: "http://", with: "https://")
        }

        guard !feedURLs.contains(finalURL) else { return finalURL }
        feedURLs.append(finalURL)
        saveFeeds()
        return finalURL
    }

    func removeFeed(url: String) {
        feedURLs.removeAll { $0 == url }
        saveFeeds()
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
        UserDefaults.standard.set(minutes, forKey: Self.fetchIntervalKey)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.notificationsEnabledKey)
    }

    func setAIEnabled(_ enabled: Bool) {
        aiEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.aiEnabledKey)
    }

    func setPrivateNotificationsEnabled(_ enabled: Bool) {
        privateNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.privateNotificationsEnabledKey)
    }

    func setAllowInsecureHTTP(_ allowed: Bool) {
        allowInsecureHTTP = allowed
        UserDefaults.standard.set(allowed, forKey: Self.allowInsecureHTTPKey)
    }

    // MARK: - OPML Portability

    @discardableResult
    func importFeeds(from opmlData: Data) -> Int {
        let items = OPMLParser.parse(data: opmlData)
        var addedCount = 0
        for item in items {
            var finalURL = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalURL.hasPrefix("https://") && !finalURL.hasPrefix("http://") {
                finalURL = "https://" + finalURL
            }
            if !allowInsecureHTTP && finalURL.hasPrefix("http://") {
                finalURL = finalURL.replacingOccurrences(of: "http://", with: "https://")
            }
            guard let nsURL = URL(string: finalURL), let host = nsURL.host else { continue }
            _ = host

            if !feedURLs.contains(finalURL) {
                feedURLs.append(finalURL)
                addedCount += 1
            }
            if let folder = item.folder, !folder.isEmpty, !userSections.contains(folder) {
                userSections.append(folder)
            }
        }
        if addedCount > 0 {
            saveFeeds()
            saveSections()
        }
        return addedCount
    }

    func exportOPML() -> String {
        return OPMLExporter.generateOPML(feedURLs: feedURLs)
    }

    private func saveFeeds() {
        UserDefaults.standard.set(feedURLs, forKey: Self.feedURLsKey)
    }

    private func saveSections() {
        UserDefaults.standard.set(userSections, forKey: Self.userSectionsKey)
    }
}
