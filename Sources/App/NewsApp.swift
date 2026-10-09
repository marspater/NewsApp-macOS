import SwiftUI
import AppKit
import UserNotifications

/// Notification posted when the user clicks a notification banner or uses keyboard navigation.
extension Notification.Name {
    static let openArticleFromNotification = Notification.Name("openArticleFromNotification")
    static let refreshFeedsCommand = Notification.Name("refreshFeedsCommand")
    static let nextArticleCommand = Notification.Name("nextArticleCommand")
    static let prevArticleCommand = Notification.Name("prevArticleCommand")
    static let toggleReadCommand = Notification.Name("toggleReadCommand")
    static let toggleSaveCommand = Notification.Name("toggleSaveCommand")
    static let openInBrowserCommand = Notification.Name("openInBrowserCommand")
    static let toggleViewModeCommand = Notification.Name("toggleViewModeCommand")
    static let showFeedUpdatesCommand = Notification.Name("showFeedUpdatesCommand")
}

@main
struct NewsApp: App {
    @FocusedValue(\.selectedStory) private var selectedStory
    @FocusedValue(\.readerActions) private var readerActions
    @FocusedValue(\.listActions) private var listActions
    @FocusedValue(\.addFeedSubscription) private var addFeedSubscription
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appContainer = AppContainer.shared
    @StateObject private var appSettings = AppSettings.shared
    @StateObject private var articleStore = ArticleStore.shared
    @StateObject private var feedManager = AppContainer.shared.feedManager
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var readManager = AppContainer.shared.readManager
    @StateObject private var savedStories = AppContainer.shared.savedStories
    
    var body: some Scene {
        Window("News", id: "main") {
            MainView()
                .environmentObject(appContainer)
                .environmentObject(appSettings)
                .environmentObject(articleStore)
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .environmentObject(savedStories)
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .modifier(SystemSettingsOverrideModifier())
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            KeyboardShortcutsCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { @MainActor in
                        await UpdateChecker.shared.checkForUpdates(userInitiated: true)
                        if UpdateChecker.shared.updateAvailable {
                            UpdateChecker.shared.openReleasePage()
                        }
                    }
                }
            }
            CommandGroup(replacing: .importExport) {
                Button("Add Feed Subscription…") { addFeedSubscription?() }
                    .disabled(addFeedSubscription == nil)
                Divider()
                Button("Import Subscriptions (OPML)...") {
                    OPMLDialogs.importOPML { data in
                        feedManager.importFeeds(from: data)
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export Subscriptions (OPML)...") {
                    let opml = feedManager.exportOPML()
                    OPMLDialogs.exportOPML(xmlString: opml)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            ListViewCommands(themeManager: themeManager)
            CommandGroup(after: .sidebar) {
                Button("Refresh Feeds") {
                    NotificationCenter.default.post(name: .refreshFeedsCommand, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Back to Stories") { readerActions?.back() }
                    .disabled(readerActions == nil)
                Button("New Briefing") { listActions?.newBriefing?() }
                    .disabled(listActions?.newBriefing == nil)
                Divider()
                Button("Today") {
                    NotificationCenter.default.post(name: .jumpToTodayCommand, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Unread") {
                    NotificationCenter.default.post(name: .jumpToUnreadCommand, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Saved Stories") {
                    NotificationCenter.default.post(name: .jumpToSavedCommand, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("History") {
                    NotificationCenter.default.post(name: .jumpToHistoryCommand, object: nil)
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("Next Article") {
                    NotificationCenter.default.post(name: .nextArticleCommand, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("Previous Article") {
                    NotificationCenter.default.post(name: .prevArticleCommand, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Show Queued Updates") {
                    NotificationCenter.default.post(name: .showFeedUpdatesCommand, object: nil)
                }
            }
            // Actions on the focused or open story, as Mail's Message menu (DESIGN.md 14).
            CommandMenu("Story") {
                Button("Mark as Read or Unread") {
                    NotificationCenter.default.post(name: .toggleReadCommand, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selectedStory == nil)

                Button("Save or Remove from Saved") {
                    NotificationCenter.default.post(name: .toggleSaveCommand, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(selectedStory == nil)

                Divider()

                Button("Open in Browser") {
                    NotificationCenter.default.post(name: .openInBrowserCommand, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(selectedStory == nil)

                if let story = selectedStory, let url = URL(string: story.link) {
                    ShareLink(item: url, subject: Text(story.title)) { Text("Share Story") }
                }

                // ⇧⌘W is Close Window in tabbed macOS apps, so Story / Web uses ⇧⌘R (design plan D5).
                Button("Switch Between Story and Web") {
                    NotificationCenter.default.post(name: .toggleViewModeCommand, object: nil)
                }
                .keyboardShortcut(ReaderMode.webShortcut, modifiers: ReaderMode.webShortcutModifiers)
                .disabled(readerActions == nil)

                if let actions = readerActions {
                    Picker("Reading Mode", selection: actions.mode) {
                        if actions.hasOverview { Text("Overview").tag(ReaderMode.overview) }
                        Text("Story").tag(ReaderMode.story)
                        Text("Web").tag(ReaderMode.web)
                    }
                    Button("Reload Reader Content") { actions.reload?() }
                        .disabled(actions.reload == nil)
                    Button("Copy Link", action: actions.copyLink)
                    Button("Web Back") { actions.webBack?() }.disabled(actions.webBack == nil)
                    Button("Web Forward") { actions.webForward?() }.disabled(actions.webForward == nil)
                }
            }
        }
        
        Window("Keyboard Shortcuts", id: KeyboardShortcutsCommands.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .modifier(SystemSettingsOverrideModifier())
        }
        .windowResizability(.contentSize)

        Window("News Tension", id: "tension") {
            TensionIndexView()
                .environmentObject(appSettings)
                .environmentObject(articleStore)
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .modifier(SystemSettingsOverrideModifier())
        }

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(articleStore)
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .environmentObject(savedStories)
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .modifier(SystemSettingsOverrideModifier())
        }
    }
}

/// View → as List, as Grid and Group Stories by Event, sharing the list toolbar's stored preferences.
struct ListViewCommands: Commands {
    @FocusedValue(\.listActions) private var listActions
    @FocusedValue(\.readerActions) private var readerActions
    @ObservedObject var themeManager: ThemeManager
    @AppStorage("articleGridLayout") private var gridLayout = false
    @AppStorage("groupsEventCoverage") private var groupsEvents = true

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Picker("Story Layout", selection: $gridLayout) {
                Text("As List").tag(false)
                Text("As Grid").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Toggle("Group Stories by Event", isOn: $groupsEvents)
                .disabled(listActions?.canGroupStories != true)

            if let actions = readerActions {
                Picker("Text Size", selection: actions.textScale) {
                    Text("Standard").tag(CGFloat(1))
                    Text("Large").tag(CGFloat(1.25))
                    Text("Extra Large").tag(CGFloat(1.5))
                }
                Picker("Reading Style", selection: $themeManager.articleTheme) {
                    ForEach(ArticleThemeType.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Divider()
        }
    }
}

/// Help → Keyboard Shortcuts opens the single-key shortcut list in its own window.
struct KeyboardShortcutsCommands: Commands {
    static let windowID = "keyboard-shortcuts"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                openWindow(id: Self.windowID)
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ _: Notification) {
        CacheManager.shared.configureOfflineCache()
        // Request Notification Permissions on App Launch
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            // Notification authorization handled silently
        }
        UNUserNotificationCenter.current().delegate = self
    }
    
    // Force macOS to show alert even if app is focused
    nonisolated func userNotificationCenter(_ _: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // Handle notification click — deep link to the article
    nonisolated func userNotificationCenter(_ _: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let articleID = userInfo["articleID"] as? String
        if let articleLink = userInfo["articleLink"] as? String {
            Task { @MainActor in
                // Bring app to front
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
                ArticleStore.shared.pendingNavigation = .init(
                    articleID: articleID,
                    link: articleLink
                )
            }
        }
        completionHandler()
    }
}
