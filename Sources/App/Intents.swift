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

// Sources/App/Intents.swift
// App Intents and Shortcuts integration for NewsApp (Milestone M3 · #558)

import AppIntents
import Foundation

// MARK: - AppSection AppEnum

/// A sidebar section that Shortcuts can open.
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

/// Where the intents find the app's stores; tests set the overrides and the navigation handler.
@MainActor
enum IntentDependencyResolver {
    /// Replaces `AppContainer.shared.feedManager`.
    static var feedManagerOverride: FeedManager?
    /// Replaces `ArticleStore.shared`.
    static var articleStoreOverride: ArticleStore?
    /// Replaces `AppSettings.shared`.
    static var appSettingsOverride: AppSettings?
    /// Replaces posting a jump command in `routeToSection(_:)`.
    static var sectionNavigationHandler: (@MainActor @Sendable (AppSection) -> Void)?

    /// The override, else the app's feed manager.
    static func resolveFeedManager() -> FeedManager {
        feedManagerOverride ?? AppContainer.shared.feedManager
    }

    /// The override, else the shared article store.
    static func resolveArticleStore() -> ArticleStore {
        articleStoreOverride ?? ArticleStore.shared
    }

    /// The override, else the shared settings.
    static func resolveAppSettings() -> AppSettings {
        appSettingsOverride ?? AppSettings.shared
    }

    /// Calls the navigation handler, else posts the section's jump command for the main window.
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

/// Refreshes every subscribed feed in the background, or reports why a refresh is blocked.
public struct RefreshFeedsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Refresh Feeds"
    public static let description = IntentDescription("Fetches latest stories from all subscribed feeds.")
    public static let openAppWhenRun: Bool = false
    /// macOS 26 and later read this instead of `openAppWhenRun`, which stays for macOS 15.
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .background }

    private let feedManager: FeedManager?

    public init() {
        self.feedManager = nil
    }

    /// Creates an intent that refreshes through `feedManager`, or the resolved one when nil.
    init(feedManager: FeedManager?) {
        self.feedManager = feedManager
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = feedManager ?? IntentDependencyResolver.resolveFeedManager()
        if let reason = await manager.refreshBlockedReason() {
            return .result(dialog: "Feeds were not refreshed. \(reason)")
        }
        await manager.fetchFeedsAsync()
        return .result(dialog: "Feeds refreshed successfully.")
    }
}

// MARK: - 2. AddFeedIntent

/// Subscribes to an `http` or `https` feed URL through the feed manager, which fetches it at once; returns whether it
/// was added.
public struct AddFeedIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Feed"
    public static let description = IntentDescription("Subscribes to an RSS or Atom feed URL.")
    public static let openAppWhenRun: Bool = false
    /// macOS 26 and later read this instead of `openAppWhenRun`, which stays for macOS 15.
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .background }

    /// The feed to subscribe to.
    @Parameter(title: "Feed URL")
    public var url: URL

    private let feedManager: FeedManager?

    public init() {
        self.feedManager = nil
        self.url = URL(string: "https://example.com")!
    }

    /// Creates an intent for `url` that subscribes through `feedManager`, or the resolved one when nil.
    init(url: URL, feedManager: FeedManager? = nil) {
        self.feedManager = feedManager
        self.url = url
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .result(value: false, dialog: "Could not subscribe to feed. The URL scheme is invalid.")
        }
        // Through the manager, like the app's own Add Feed, so the feed is fetched at once and gets a status entry.
        let manager = feedManager ?? IntentDependencyResolver.resolveFeedManager()
        if let added = await manager.addFeedAndCollect(url: url.absoluteString) {
            return .result(value: true, dialog: "Subscribed to feed: \(added)")
        } else {
            return .result(
                value: false, dialog: "Could not subscribe to feed. The URL may be invalid or already subscribed.")
        }
    }
}

// MARK: - 3. OpenSectionIntent

/// Brings News forward on a sidebar section.
public struct OpenSectionIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Section"
    public static let description = IntentDescription("Opens a specified section in News.")
    public static let openAppWhenRun: Bool = true
    /// macOS 26 and later read this instead of `openAppWhenRun`, which stays for macOS 15.
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .foreground }

    /// The section to open.
    @Parameter(title: "Section")
    public var section: AppSection

    private let navigationHandler: (@MainActor @Sendable (AppSection) -> Void)?

    public init() {
        self.navigationHandler = nil
        self.section = .today
    }

    /// Creates an intent for `section`; `navigationHandler` replaces the resolver's routing.
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

/// Marks every story the mute rules leave visible as read.
public struct MarkAllAsReadIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mark All as Read"
    public static let description = IntentDescription("Marks all stories in the library as read.")
    public static let openAppWhenRun: Bool = false
    /// macOS 26 and later read this instead of `openAppWhenRun`, which stays for macOS 15.
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .background }

    private let articleStore: ArticleStore?

    public init() {
        self.articleStore = nil
    }

    /// Creates an intent that marks through `articleStore`, or the resolved one when nil.
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

/// Starts a new Briefing edition by clearing the stored edition and jumping to Briefing.
public struct NewBriefingIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Briefing"
    public static let description = IntentDescription("Generates a fresh daily briefing edition.")
    public static let openAppWhenRun: Bool = false
    /// macOS 26 and later read this instead of `openAppWhenRun`, which stays for macOS 15.
    @available(macOS 26.0, *) public static var supportedModes: IntentModes { .background }

    private let appSettings: AppSettings?
    private let resetAction: (@MainActor @Sendable () -> Void)?

    public init() {
        self.appSettings = nil
        self.resetAction = nil
    }

    /// Creates an intent; `resetAction` replaces clearing the stored edition, for tests.
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

/// The App Shortcuts News offers in Shortcuts and Spotlight.
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
                "Add a feed to \(.applicationName)",
                "Subscribe to a feed in \(.applicationName)",
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
