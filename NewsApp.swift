import SwiftUI
import AppKit
import UserNotifications

@main
struct NewsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var feedManager = FeedManager()
    
    var body: some Scene {
        Window("News", id: "main") {
            MainView()
                .environmentObject(feedManager)
                .preferredColorScheme(.dark)
                .background(WindowAccessor().frame(width: 0, height: 0))
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            SidebarCommands()
        }
        
        Settings {
            SettingsView()
                .environmentObject(feedManager)
                .preferredColorScheme(.dark)
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
    
    // Force macOS to show alert even if app is focused (useful for our background tests)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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
