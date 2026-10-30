import AppIntents
import AppKit
import SwiftUI
import UserNotifications

/// Notification posted when the user clicks a notification banner or uses keyboard navigation.
extension Notification.Name {
    static let refreshFeedsCommand = Notification.Name("refreshFeedsCommand")
    static let markAllReadCommand = Notification.Name("markAllReadCommand")
    static let nextArticleCommand = Notification.Name("nextArticleCommand")
    static let prevArticleCommand = Notification.Name("prevArticleCommand")
    static let toggleReadCommand = Notification.Name("toggleReadCommand")
    static let toggleSaveCommand = Notification.Name("toggleSaveCommand")
    static let openInBrowserCommand = Notification.Name("openInBrowserCommand")
    static let showFeedUpdatesCommand = Notification.Name("showFeedUpdatesCommand")
}

@main
struct NewsApp: App {
    @FocusedValue(\.archiveSearch) private var archiveSearch
    @FocusedValue(\.selectedStory) private var selectedStory
    @FocusedValue(\.readerActions) private var readerActions
    @FocusedValue(\.listActions) private var listActions
    @FocusedValue(\.addFeedSubscription) private var addFeedSubscription
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appContainer = AppContainer.shared
    @StateObject private var appSettings = AppSettings.shared
    @StateObject private var articleStore = ArticleStore.shared
    @StateObject private var feedManager = AppContainer.shared.feedManager
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var readManager = AppContainer.shared.readManager
    @StateObject private var savedStories = AppContainer.shared.savedStories
    @State private var onboardingClosed = false

    @MainActor private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

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
                // First launch only (#562); closing the sheet any way completes it, after it has gone, so the
                // notification prompt that completion can trigger never appears over the sheet.
                .sheet(
                    isPresented: Binding(
                        get: { !appSettings.firstLaunchCompleted && !onboardingClosed },
                        set: { if !$0 { onboardingClosed = true } }),
                    onDismiss: { appSettings.completeFirstLaunch() }
                ) {
                    OnboardingView()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            KeyboardShortcutsCommands()
            CommandGroup(after: .textEditing) {
                Button("Search Archive") { archiveSearch?() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(archiveSearch == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { @MainActor in
                        await UpdateChecker.shared.checkForUpdates(userInitiated: true)
                        if UpdateChecker.shared.updateAvailable {
                            UpdateChecker.shared.openReleasePage()
                        } else if let message = UpdateChecker.shared.statusMessage {
                            Self.showAlert(message)
                        }
                    }
                }
            }
            CommandGroup(replacing: .importExport) {
                Button("Add Feed…") { addFeedSubscription?() }
                    .disabled(addFeedSubscription == nil)
                Divider()
                Button("Import Subscriptions (OPML)…") {
                    OPMLDialogs.importOPML { data in
                        let count = feedManager.importFeeds(from: data)
                        // A malformed file already surfaces its own error through operationError.
                        if count > 0 || (try? OPMLParser.parseValidated(data: data)) != nil {
                            let noun = count == 1 ? "feed" : "feeds"
                            Self.showAlert(count > 0 ? "Imported \(count) \(noun)" : "No new feeds")
                        }
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export Subscriptions (OPML)…") {
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

                Button("Next Story") {
                    NotificationCenter.default.post(name: .nextArticleCommand, object: nil)
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("Previous Story") {
                    NotificationCenter.default.post(name: .prevArticleCommand, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Show New Stories") {
                    NotificationCenter.default.post(name: .showFeedUpdatesCommand, object: nil)
                }
            }
            // Actions on the focused or open story, as Mail's Message menu (DESIGN.md 14).
            CommandMenu("Story") {
                Button(selectedStory.map { readManager.isRead($0.id) } == true ? "Mark as Unread" : "Mark as Read") {
                    NotificationCenter.default.post(name: .toggleReadCommand, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selectedStory == nil)

                Button("Mark All as Read") {
                    NotificationCenter.default.post(name: .markAllReadCommand, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(listActions == nil)

                Button(
                    selectedStory.map { savedStories.isSaved($0) } == true ? "Remove from Saved Stories" : "Save Story"
                ) {
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
                    if let actions = readerActions {
                        actions.mode.wrappedValue = actions.mode.wrappedValue.toggledPublicationMode
                    }
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
                    Button("Web Back") { actions.webBack?() }
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(actions.webBack == nil)
                    Button("Web Forward") { actions.webForward?() }
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(actions.webForward == nil)
                }
            }
        }

        Window("Keyboard Shortcuts", id: KeyboardShortcutsCommands.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .modifier(SystemSettingsOverrideModifier())
        }
        .windowResizability(.contentSize)

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

        MenuBarExtra(
            isInserted: Binding(
                get: { appSettings.showsMenuBarExtra },
                set: { appSettings.setShowsMenuBarExtra($0) }
            )
        ) {
            Text(menuBarStatusCopy)
                .monospacedDigit()

            Divider()

            Button("Refresh") {
                NotificationCenter.default.post(name: .refreshFeedsCommand, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Open News") {
                NSApp.activate()
                openWindow(id: "main")
            }
        } label: {
            Label {
                if let badgeText = menuBarBadgeCopy {
                    Text(badgeText).monospacedDigit()
                } else {
                    Text("News")
                }
            } icon: {
                Image(systemName: "newspaper")
            }
        }
    }

    private var menuBarBadgeCopy: String? {
        let unread = articleStore.unreadCount
        return unread > 0 ? "\(unread)" : nil
    }

    private var menuBarStatusCopy: String {
        let unread = articleStore.unreadCount
        guard unread > 0 else { return "No Unread Stories" }
        return "\(unread) Unread \(unread == 1 ? "Story" : "Stories")"
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

            Button("New Briefing") { listActions?.newBriefing?() }
                .disabled(listActions?.newBriefing == nil)

            Button("World Tension…") {
                NotificationCenter.default.post(name: .showNewsTensionCommand, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Make Text Bigger") {
                if let actions = readerActions {
                    actions.textScale.wrappedValue = ReaderTextSize.adjusted(actions.textScale.wrappedValue, by: 1)
                }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(readerActions == nil || (readerActions?.textScale.wrappedValue ?? 1) >= ReaderTextSize.maximum)
            Button("Make Text Smaller") {
                if let actions = readerActions {
                    actions.textScale.wrappedValue = ReaderTextSize.adjusted(actions.textScale.wrappedValue, by: -1)
                }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(readerActions == nil || (readerActions?.textScale.wrappedValue ?? 1) <= ReaderTextSize.minimum)
            Button("Actual Size") { readerActions?.textScale.wrappedValue = 1 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(readerActions == nil)
            if let actions = readerActions {
                Picker("Reading Style", selection: $themeManager.articleTheme) {
                    ForEach(ArticleThemeType.allCases) { Text($0.displayName).tag($0) }
                }
                Button("Reading Options…", action: actions.showReadingOptions)
            }

            Divider()
        }
    }
}

/// Help → Keyboard Shortcuts opens the single-key shortcut list in its own window.
struct KeyboardShortcutsCommands: Commands {
    static let windowID = "keyboard-shortcuts"
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                openWindow(id: Self.windowID)
            }
            if updateChecker.updateAvailable {
                Divider()
                Button(updateMenuItemTitle) {
                    updateChecker.openReleasePage()
                }
            }
        }
    }

    private var updateMenuItemTitle: String {
        if let version = updateChecker.latestVersionString {
            let formatted = version.hasPrefix("v") || version.hasPrefix("V") ? version : "v\(version)"
            return "Update Available (\(formatted))…"
        }
        return "Update Available…"
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var notificationPermission: NotificationPermissionRequest?

    func applicationDidFinishLaunching(_ _: Notification) {
        CacheManager.shared.configureOfflineCache()
        NotificationActionIdentifier.registerCategories()
        UNUserNotificationCenter.current().delegate = self
        // Permission is asked once stories have arrived, not at launch (#562).
        notificationPermission = NotificationPermissionRequest(
            feedManager: AppContainer.shared.feedManager, settings: AppSettings.shared
        ) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
                // Delivery checks the authorization when it posts; the answer itself needs no handling here.
            }
        }

        NewsShortcuts.updateAppShortcutParameters()

        Task { @MainActor in
            await UpdateChecker.shared.checkForUpdates(userInitiated: false)
        }
    }

    func applicationDidBecomeActive(_ _: Notification) {
        Task { @MainActor in
            await UpdateChecker.shared.checkForUpdates(userInitiated: false)
        }
    }

    func applicationWillTerminate(_ _: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await DatabaseEngine.shared.checkpointAndOptimize()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(2))
    }

    // Force macOS to show alert even if app is focused
    nonisolated func userNotificationCenter(
        _ _: UNUserNotificationCenter, willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Handle notification actions and default click (#560)
    nonisolated func userNotificationCenter(
        _ _: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        var sendableUserInfo: [String: String] = [:]
        if let id = userInfo["articleID"] as? String {
            sendableUserInfo["articleID"] = id
        }
        if let link = userInfo["articleLink"] as? String {
            sendableUserInfo["articleLink"] = link
        }
        Task { @MainActor in
            await NotificationActionRouter.route(
                actionIdentifier: actionIdentifier,
                userInfo: sendableUserInfo,
                articleStore: ArticleStore.shared,
                readManager: AppContainer.shared.readManager,
                savedStories: AppContainer.shared.savedStories
            )
        }
        completionHandler()
    }
}
