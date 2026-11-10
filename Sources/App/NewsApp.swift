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

import AppIntents
import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

#if NEWS_SENTRY
    import OSLog
    import Sentry

    /// Dev builds only: forwards this app's warning, error and fault log entries to Sentry Logs every 30 seconds.
    enum SentryLogForwarder {
        static func start() {
            Task.detached(priority: .utility) {
                let subsystem = NSPredicate(format: "subsystem == %@", "com.marspater.news")
                var since = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    // Opened per pass: Apple does not document whether a store sees entries logged after it opened.
                    guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
                        let entries = try? store.getEntries(at: store.position(date: since), matching: subsystem)
                    else { continue }
                    var newest = since
                    // With Sentry running the store can return one entry twice; each is sent once.
                    var sent = Set<String>()
                    for case let entry as OSLogEntryLog in entries
                    where entry.date > since && entry.level.rawValue >= OSLogEntryLog.Level.error.rawValue {
                        let key = "\(entry.date.timeIntervalSince1970) \(entry.category) \(entry.composedMessage)"
                        guard sent.insert(key).inserted else { continue }
                        newest = max(newest, entry.date)
                        let attributes: [String: Any] = [
                            "category": entry.category, loggedAtKey: entry.date.timeIntervalSince1970,
                        ]
                        let message = DiagnosticsExport.redacted(entry)
                        if entry.level == .fault {
                            SentrySDK.logger.fatal(message, attributes: attributes)
                        } else {
                            SentrySDK.logger.error(message, attributes: attributes)
                        }
                    }
                    since = newest
                }
            }
        }

        /// Seconds since 1970 when the entry was logged; `stamp` moves it onto the Sentry log, which is otherwise dated
        /// when this forwarder sends it, up to 30 seconds later.
        static let loggedAtKey = "os_log.timestamp"

        static func stamp(_ log: SentryLog) -> SentryLog {
            if let loggedAt = log.attributes[loggedAtKey]?.value as? Double {
                log.timestamp = Date(timeIntervalSince1970: loggedAt)
            }
            return log
        }
    }
#endif

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
    static let newSmartBinderCommand = Notification.Name("newSmartBinderCommand")
}

struct NewsApp: App {
    @FocusedValue(\.archiveSearch) private var archiveSearch
    @FocusedValue(\.selectedStory) private var selectedStory
    @FocusedValue(\.readerActions) private var readerActions
    @FocusedValue(\.knowledgeExport) private var knowledgeExport
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

    @MainActor private func exportStories(saved: Bool, markdown: Bool) {
        Task { @MainActor in
            do {
                let entries = try await articleStore.database.exportedStories(saved: saved)
                OPMLDialogs.exportStories(entries, title: saved ? "Saved Stories" : "History", markdown: markdown)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
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
                    // A sheet reads the environment where it is attached, outside the objects given to MainView,
                    // so the ones the sheet reads are given again here.
                    OnboardingView()
                        .environmentObject(appSettings)
                        .environmentObject(feedManager)
                        .modifier(SystemSettingsOverrideModifier())
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            KeyboardShortcutsCommands()
            CommandGroup(after: .textEditing) {
                Button("Search Archive") { archiveSearch?.perform() }
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
            FileCommands()
            CommandGroup(replacing: .importExport) {
                Button("Add Feed…") { addFeedSubscription?.perform() }
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
                Divider()
                Menu("Export Story or Briefing") {
                    Button("Export as Markdown…") { knowledgeExport?.markdown() }
                    Button("Compile to EPUB…") { knowledgeExport?.epub() }
                    Button("Add to Apple Notes…") { knowledgeExport?.notes() }
                }
                .disabled(knowledgeExport == nil)
                Menu("Export Saved Stories") {
                    Button("JSON…") { exportStories(saved: true, markdown: false) }
                    Button("Markdown…") { exportStories(saved: true, markdown: true) }
                }
                Menu("Export History") {
                    Button("JSON…") { exportStories(saved: false, markdown: false) }
                    Button("Markdown…") { exportStories(saved: false, markdown: true) }
                }
            }
            ListViewCommands(themeManager: themeManager)
            CommandGroup(after: .sidebar) {
                Button("Refresh Feeds") {
                    NotificationCenter.default.post(name: .refreshFeedsCommand, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button(readerActions == nil && listActions?.back != nil ? "Back" : "Back to Stories") {
                    if let readerActions { readerActions.back() } else { listActions?.back?() }
                }
                .disabled(readerActions == nil && listActions?.back == nil)
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

                // Finder's Quick Look shortcut; Space does the same while the list has focus.
                Button("Quick Look") {
                    NotificationCenter.default.post(name: .quickLookCommand, object: nil)
                }
                // ⌘Y highlights the selection while a story is open (Edit › Highlight Selection); a disabled item
                // still holds its key, so Quick Look gives ⌘Y up there.
                .keyboardShortcut(readerActions == nil ? KeyboardShortcut("y", modifiers: .command) : nil)
                .disabled(listActions == nil || readerActions != nil)

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

                Button("Check for Updates") { readerActions?.checkForUpdates?() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(readerActions?.checkForUpdates == nil)

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
        // The commands builder takes ten entries under Xcode 26's SDK, which CI compiles with; the Log window's
        // commands, and the reader's annotation commands, go in a second call rather than an eleventh entry.
        .commands {
            LogWindowCommands()
            AnnotationCommands()
        }
        .windowResizability(.contentSize)

        // Development builds only (#1005): Help › Show Log opens it; it has no Window menu item and is not restored.
        Window("Log", id: LogWindowModel.windowID) {
            if LogWindowModel.isAvailable {
                LogWindowView()
                    .preferredColorScheme(themeManager.appearance.colorScheme)
                    .modifier(SystemSettingsOverrideModifier())
            }
        }
        .defaultSize(width: 900, height: 560)
        .commandsRemoved()
        .restorationBehavior(.disabled)

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

    private var menuBarBadgeCopy: String? { AppSettings.menuBarBadgeCopy(unread: articleStore.unreadCount) }

    private var menuBarStatusCopy: String { AppSettings.menuBarStatusCopy(unread: articleStore.unreadCount) }
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

            Button("Customize Briefing…") { listActions?.customizeBriefing?() }
                .disabled(listActions?.customizeBriefing == nil)

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
                Picker("Reading Style", selection: themeManager.binding(\.articleTheme)) {
                    ForEach(ArticleThemeType.allCases) { Text($0.displayName).tag($0) }
                }
                Button("Reading Options…", action: actions.showReadingOptions)
            }

            Divider()
        }
    }
}

/// Edit › Copy Log and Clear Log for the development Log window in front (#1005); absent in release builds.
struct LogWindowCommands: Commands {
    @FocusedObject private var log: LogWindowModel?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            if LogWindowModel.isAvailable {
                Divider()
                Button("Copy Log") { log?.copyVisible() }
                    .disabled(log?.visible.isEmpty ?? true)
                Button("Clear Log") { log?.clear() }
                    .disabled(log?.entries.isEmpty ?? true)
            }
        }
    }
}

struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Smart Binder…") {
                NotificationCenter.default.post(name: .newSmartBinderCommand, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .importExport) {
            Divider()
            Button("Back Up Library…") { LibraryBackup.backUpLibrary() }
            Button("Restore Library…") { LibraryBackup.restoreLibrary() }
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
            Button("Show Sample Notification") {
                // A random story with a photo, through the real path: the app draws its banner.
                guard let story = NotificationService.sampleStory(from: ArticleStore.shared.articles) else { return }
                Task {
                    await NotificationService.shared.postSample(story) {
                        await MainActor.run {
                            AppSettings.shared.notificationsEnabled && AppSettings.shared.notificationMode == .full
                        }
                    }
                }
            }
            Button("Export Diagnostics…") {
                DiagnosticsExport.run(
                    settings: AppSettings.shared, feedManager: AppContainer.shared.feedManager,
                    articleStore: ArticleStore.shared)
            }
            if LogWindowModel.isAvailable {
                Button("Show Log") { openWindow(id: LogWindowModel.windowID) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
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

    // The Quick Look panel looks up the responder chain for its controller; the app delegate ends that chain (#707).
    nonisolated override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { StoryQuickLookCoordinator.shared.hasPreview }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { StoryQuickLookCoordinator.shared.control(panel) }
    }

    nonisolated override func endPreviewPanelControl(_: QLPreviewPanel!) {
        // The coordinator stays the data source until the next begin call replaces it; nothing to undo.
    }

    func applicationDidFinishLaunching(_ _: Notification) {
        #if NEWS_SENTRY
            // Dev builds only (script/sentry_dev.sh); release builds never link Sentry.
            if let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String {
                SentrySDK.start { options in
                    options.dsn = dsn
                    options.environment = "development"
                    options.sendDefaultPii = false
                    // Feed URLs can carry tokens: keep them out of breadcrumbs and failed-request events.
                    options.enableNetworkBreadcrumbs = false
                    options.enableCaptureFailedRequests = false
                    // Publishers must never receive sentry-trace or baggage headers.
                    options.tracePropagationTargets = []
                    options.tracesSampleRate = 1.0
                    options.configureProfiling = { profiling in
                        profiling.sessionSampleRate = 1.0
                        profiling.lifecycle = .trace
                    }
                    options.enableLogs = true
                    options.beforeSendLog = SentryLogForwarder.stamp
                }
                SentryLogForwarder.start()
            }
        #endif
        CacheManager.shared.configureOfflineCache()
        NotificationActionIdentifier.registerCategories()
        UNUserNotificationCenter.current().delegate = self
        // Permission is asked once stories have arrived, not at launch (#562).
        notificationPermission = NotificationPermissionRequest(
            feedManager: AppContainer.shared.feedManager, settings: AppSettings.shared
        ) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
                // The banner reads the settings when it is drawn; the answer itself needs no handling here.
            }
            // The only way to honour Focus; the banner reads the answer when it is drawn.
            FocusStatus.requestAuthorization()
        }

        #if !DEBUG
            NewsShortcuts.updateAppShortcutParameters()
        #endif

        Task { @MainActor in
            await UpdateChecker.shared.checkForUpdates(userInitiated: false)
        }
    }

    func applicationDidBecomeActive(_ _: Notification) {
        Task { @MainActor in
            await UpdateChecker.shared.checkForUpdates(userInitiated: false)
        }
    }

    private var terminationReplied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationReplied = false
        Task.detached(priority: .userInitiated) {
            await DatabaseEngine.shared.checkpointAndOptimize()
            await MainActor.run { [weak self] in
                self?.finishTermination(sender)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ _: Notification) {
        // Asynchronous checkpoint and optimize completes in applicationShouldTerminate.
    }

    // A click or action on a notification an earlier build left in Notification Center (#560); News adds none now.
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
