import SwiftUI
import AppKit
import UserNotifications

/// Notification posted when the user clicks a notification banner to open an article.
extension Notification.Name {
    static let openArticleFromNotification = Notification.Name("openArticleFromNotification")
}

@main
struct NewsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var feedManager = FeedManager()
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var readManager = ReadManager.shared
    
    var body: some Scene {
        Window("News", id: "main") {
            MainView()
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .preferredColorScheme(themeManager.appearance.colorScheme)
                .background(WindowAccessor().frame(width: 0, height: 0))
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            SidebarCommands()
        }
        
        Settings {
            SettingsView()
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .preferredColorScheme(themeManager.appearance.colorScheme)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request Notification Permissions on App Launch
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            // Notification authorization handled silently
        }
        UNUserNotificationCenter.current().delegate = self
    }
    
    // Force macOS to show alert even if app is focused
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // Handle notification click — deep link to the article
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let articleLink = userInfo["articleLink"] as? String {
            // Bring app to front
            NSApp.activate(ignoringOtherApps: true)
            // Post notification for MainView to pick up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
