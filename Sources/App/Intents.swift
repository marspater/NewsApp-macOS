// Sources/App/Intents.swift
// App Intents and Shortcuts integration for NewsApp (Milestone M3 · #558)

import AppIntents
import Foundation

// MARK: - AppSection AppEnum

public enum AppSection: String, AppEnum, Sendable {
    case today = "Today"
    case unread = "Unread"
    case briefing = "Briefing"
    case savedStories = "Saved Stories"

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Section")

    public static let caseDisplayRepresentations: [AppSection: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today"),
        .unread: DisplayRepresentation(title: "Unread"),
        .briefing: DisplayRepresentation(title: "Briefing"),
        .savedStories: DisplayRepresentation(title: "Saved Stories"),
    ]
}

// MARK: - Dependency Resolver & Testable Container

@MainActor
enum IntentDependencyResolver {
    static var feedManagerOverride: FeedManager?
    static var articleStoreOverride: ArticleStore?
    static var appSettingsOverride: AppSettings?
    static var sectionNavigationHandler: (@MainActor @Sendable (AppSection) -> Void)?

    static func resolveFeedManager() -> FeedManager {
        feedManagerOverride ?? AppContainer.shared.feedManager
    }

    static func resolveArticleStore() -> ArticleStore {
        articleStoreOverride ?? ArticleStore.shared
    }

    static func resolveAppSettings() -> AppSettings {
        appSettingsOverride ?? AppSettings.shared
    }

    static func routeToSection(_ section: AppSection) {
        if let sectionNavigationHandler {
            sectionNavigationHandler(section)
            return
        }
        switch section {
        case .today:
            NotificationCenter.default.post(name: Notification.Name("jumpToTodayCommand"), object: nil)
        case .unread:
            NotificationCenter.default.post(name: Notification.Name("jumpToUnreadCommand"), object: nil)
        case .briefing:
            NotificationCenter.default.post(name: Notification.Name("jumpToBriefingCommand"), object: nil)
        case .savedStories:
            NotificationCenter.default.post(name: Notification.Name("jumpToSavedCommand"), object: nil)
        }
    }
}

// MARK: - 1. RefreshFeedsIntent

public struct RefreshFeedsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Refresh Feeds"
    public static let description = IntentDescription("Fetches latest stories from all subscribed feeds.")
    public static let openAppWhenRun: Bool = false

    private let feedManager: FeedManager?

    public init() {
        self.feedManager = nil
    }

    init(feedManager: FeedManager?) {
        self.feedManager = feedManager
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = feedManager ?? IntentDependencyResolver.resolveFeedManager()
        if let notice = await manager.readOnlyNotice() {
            return .result(dialog: "Feeds were not refreshed because the library is read-only. \(notice)")
        }
        await manager.fetchFeedsAsync()
        return .result(dialog: "Feeds refreshed successfully.")
    }
}

// MARK: - 2. AddFeedIntent

public struct AddFeedIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Feed"
    public static let description = IntentDescription("Subscribes to an RSS or Atom feed URL.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Feed URL")
    public var url: URL

    private let appSettings: AppSettings?

    public init() {
        self.appSettings = nil
        self.url = URL(string: "https://example.com")!
    }

    init(url: URL, appSettings: AppSettings? = nil) {
        self.appSettings = appSettings
        self.url = url
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .result(value: false, dialog: "Could not subscribe to feed. The URL scheme is invalid.")
        }
        let settings = appSettings ?? IntentDependencyResolver.resolveAppSettings()
        if let added = settings.addFeed(url: url.absoluteString) {
            return .result(value: true, dialog: "Subscribed to feed: \(added)")
        } else {
            return .result(
                value: false, dialog: "Could not subscribe to feed. The URL may be invalid or already subscribed.")
        }
    }
}

// MARK: - 3. OpenSectionIntent

public struct OpenSectionIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Section"
    public static let description = IntentDescription("Opens a specified section in News.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Section")
    public var section: AppSection

    private let navigationHandler: (@MainActor @Sendable (AppSection) -> Void)?

    public init() {
        self.navigationHandler = nil
        self.section = .today
    }

    init(section: AppSection, navigationHandler: (@MainActor @Sendable (AppSection) -> Void)? = nil) {
        self.navigationHandler = navigationHandler
        self.section = section
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        if let handler = navigationHandler {
            handler(section)
        } else {
            IntentDependencyResolver.routeToSection(section)
        }
        return .result()
    }
}

// MARK: - 4. MarkAllAsReadIntent

public struct MarkAllAsReadIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mark All as Read"
    public static let description = IntentDescription("Marks all stories in the library as read.")
    public static let openAppWhenRun: Bool = false

    private let articleStore: ArticleStore?

    public init() {
        self.articleStore = nil
    }

    init(articleStore: ArticleStore?) {
        self.articleStore = articleStore
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = articleStore ?? IntentDependencyResolver.resolveArticleStore()
        let marked = await store.markAllAsRead(muting: IntentDependencyResolver.resolveAppSettings().muteRules)
        return .result(
            dialog: marked ? "All visible stories marked as read." : "Could not mark stories as read. Try again.")
    }
}

// MARK: - 5. NewBriefingIntent

public struct NewBriefingIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Briefing"
    public static let description = IntentDescription("Generates a fresh daily briefing edition.")
    public static let openAppWhenRun: Bool = false

    private let appSettings: AppSettings?
    private let resetAction: (@MainActor @Sendable () -> Void)?

    public init() {
        self.appSettings = nil
        self.resetAction = nil
    }

    init(appSettings: AppSettings? = nil, resetAction: (@MainActor @Sendable () -> Void)? = nil) {
        self.appSettings = appSettings
        self.resetAction = resetAction
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let resetAction {
            resetAction()
        } else {
            _ = appSettings ?? IntentDependencyResolver.resolveAppSettings()
            let standardDefaults = UserDefaults.standard
            standardDefaults.setValue(Date().timeIntervalSince1970, forKey: "briefingEditionSelectedAt")
            standardDefaults.setValue("", forKey: "briefingEditionArticleIDs")
            NotificationCenter.default.post(name: Notification.Name("jumpToBriefingCommand"), object: nil)
        }
        return .result(dialog: "New briefing generated.")
    }
}

// MARK: - NewsShortcuts

public struct NewsShortcuts: AppShortcutsProvider {
    public static let shortcutTileColor: ShortcutTileColor = .navy

    @AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshFeedsIntent(),
            phrases: [
                "Refresh \(.applicationName)",
                "Refresh feeds in \(.applicationName)",
            ],
            shortTitle: "Refresh Feeds",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: AddFeedIntent(),
            phrases: [
                "Add feed \(\.$url) to \(.applicationName)",
                "Subscribe to \(\.$url) in \(.applicationName)",
            ],
            shortTitle: "Add Feed",
            systemImageName: "plus"
        )
        AppShortcut(
            intent: OpenSectionIntent(),
            phrases: [
                "Open \(\.$section) in \(.applicationName)",
                "Show \(\.$section) in \(.applicationName)",
            ],
            shortTitle: "Open Section",
            systemImageName: "sidebar.left"
        )
        AppShortcut(
            intent: MarkAllAsReadIntent(),
            phrases: [
                "Mark all stories as read in \(.applicationName)",
                "Mark all as read in \(.applicationName)",
            ],
            shortTitle: "Mark All as Read",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: NewBriefingIntent(),
            phrases: [
                "Start new briefing in \(.applicationName)",
                "Create new briefing in \(.applicationName)",
            ],
            shortTitle: "New Briefing",
            systemImageName: "text.book.closed"
        )
    }
}
