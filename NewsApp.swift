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
}

@main
struct NewsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appSettings = AppSettings.shared
    @StateObject private var articleStore = ArticleStore.shared
    @StateObject private var feedManager = FeedManager()
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var readManager = ReadManager.shared
    
    var body: some Scene {
        Window("News", id: "main") {
            MainView()
                .environmentObject(appSettings)
                .environmentObject(articleStore)
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .background(WindowAccessor().frame(width: 0, height: 0))
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .importExport) {
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
            CommandGroup(after: .sidebar) {
                Button("Refresh Feeds") {
                    NotificationCenter.default.post(name: .refreshFeedsCommand, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Navigate") {
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

                Divider()

                Button("Toggle Read / Unread") {
                    NotificationCenter.default.post(name: .toggleReadCommand, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("Save / Bookmark Article") {
                    NotificationCenter.default.post(name: .toggleSaveCommand, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Open in Browser") {
                    NotificationCenter.default.post(name: .openInBrowserCommand, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Toggle Reader / Web View") {
                    NotificationCenter.default.post(name: .toggleViewModeCommand, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .preferredColorScheme(themeManager.appearance.colorScheme)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CacheManager.shared.configureOfflineCache()
        // Request Notification Permissions on App Launch
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            // Notification authorization handled silently
        }
        UNUserNotificationCenter.current().delegate = self
    }
    
    // Force macOS to show alert even if app is focused
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // Handle notification click — deep link to the article
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let articleLink = userInfo["articleLink"] as? String {
            Task { @MainActor in
                // Bring app to front
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Post notification for MainView to pick up
                try? await Task.sleep(nanoseconds: 300_000_000)
                NotificationCenter.default.post(
                    name: .openArticleFromNotification,
                    object: nil,
                    userInfo: ["articleLink": articleLink]
                )
            }
        }
        completionHandler()
    }
}

// Accessor to deeply customize the NSWindow for Glassmorphism & Edge-to-Edge feel
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none
            
            // Force the sidebar divider to render cleanly
            if let splitView = findSplitView(in: window.contentView) {
                splitView.dividerStyle = .thin
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    
    private func findSplitView(in view: NSView?) -> NSSplitView? {
        guard let view = view else { return nil }
        if let splitView = view as? NSSplitView { return splitView }
        for subview in view.subviews {
            if let found = findSplitView(in: subview) { return found }
        }
        return nil
    }
}
