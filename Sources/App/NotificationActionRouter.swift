import AppKit
import Combine
import Foundation
import UserNotifications

/// Notification category and action identifiers for interactive story alerts (#560).
enum NotificationActionIdentifier {
    static let category = "ARTICLE_ACTIONS"
    static let save = "SAVE_ACTION"
    static let markRead = "MARK_READ_ACTION"
    static let open = "OPEN_ACTION"

    static func makeCategory() -> UNNotificationCategory {
        let saveAction = UNNotificationAction(
            identifier: save,
            title: "Save",
            options: []
        )
        let markReadAction = UNNotificationAction(
            identifier: markRead,
            title: "Mark as Read",
            options: []
        )
        let openAction = UNNotificationAction(
            identifier: open,
            title: "Open",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: category,
            actions: [saveAction, markReadAction, openAction],
            intentIdentifiers: [],
            options: []
        )
    }

    static func registerCategories(center: UNUserNotificationCenter = .current()) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        center.setNotificationCategories([makeCategory()])
    }
}

/// Asks for notification permission once per launch (#562), never at launch: only after the first refresh has
/// completed, the first-launch sheet is done and notifications are on. Turning notifications on later asks then.
@MainActor
final class NotificationPermissionRequest {
    private(set) var hasRequested = false
    private var subscription: AnyCancellable?

    init(feedManager: FeedManager, settings: AppSettings, request: @escaping () -> Void) {
        subscription = feedManager.$lastRefreshCompletedAt
            .combineLatest(settings.$notificationsEnabled, settings.$firstLaunchCompleted)
            .sink { [weak self] refreshed, enabled, onboarded in
                guard let self, !self.hasRequested, refreshed != nil, enabled, onboarded else { return }
                self.hasRequested = true
                request()
            }
    }
}

/// Routes notification action responses (`Save`, `Mark as Read`, `Open`, and default banner click)
/// to `ArticleStore`, `ReadManager`, and `SavedStoriesManager` (#560).
@MainActor
enum NotificationActionRouter {
    static func route(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        articleStore: ArticleStore,
        readManager: ReadManager,
        savedStories: SavedStoriesManager,
        activateApp: @MainActor () -> Void = { NSApp?.activate() }
    ) async {
        guard let target = resolveTarget(from: userInfo) else { return }

        switch actionIdentifier {
        case NotificationActionIdentifier.save:
            await handleSave(target: target, store: articleStore, savedStories: savedStories)
        case NotificationActionIdentifier.markRead:
            await handleMarkRead(target: target, store: articleStore, readManager: readManager)
        case NotificationActionIdentifier.open, UNNotificationDefaultActionIdentifier:
            handleOpen(target: target, store: articleStore, activateApp: activateApp)
        default:
            break
        }
    }

    // MARK: - Private Helpers

    private struct NotificationTarget {
        let articleID: String?
        let articleLink: String?
    }

    private static func resolveTarget(from userInfo: [AnyHashable: Any]) -> NotificationTarget? {
        let rawID = (userInfo["articleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let articleID = (rawID?.isEmpty == false) ? rawID : nil
        let rawLink = (userInfo["articleLink"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let articleLink = (rawLink?.isEmpty == false) ? rawLink : nil
        guard articleID != nil || articleLink != nil else { return nil }
        return NotificationTarget(articleID: articleID, articleLink: articleLink)
    }

    private static func handleSave(
        target: NotificationTarget,
        store: ArticleStore,
        savedStories: SavedStoriesManager
    ) async {
        if let id = target.articleID, let article = store.articles.first(where: { $0.id == id }) {
            savedStories.save(article)
        } else if let link = target.articleLink,
            let article = store.articles.first(where: {
                $0.link == link || $0.normalizedLink == ArticleIdentity.canonicalizeURL(link)
            })
        {
            savedStories.save(article)
        } else if let resolved = try? await store.articleForNavigation(
            .init(articleID: target.articleID, link: target.articleLink ?? "")
        ) {
            savedStories.save(resolved)
        } else if let id = target.articleID {
            let fallback = FeedArticle(
                storedID: id,
                title: "Saved Story",
                link: target.articleLink ?? "",
                guid: id,
                description: "",
                pubDate: Date(),
                source: "Notification"
            )
            savedStories.save(fallback)
        }
    }

    private static func handleMarkRead(
        target: NotificationTarget,
        store: ArticleStore,
        readManager: ReadManager
    ) async {
        if let id = target.articleID {
            readManager.markAsRead(id)
        } else if let link = target.articleLink,
            let article = store.articles.first(where: {
                $0.link == link || $0.normalizedLink == ArticleIdentity.canonicalizeURL(link)
            })
        {
            readManager.markAsRead(article.id)
        } else if let resolved = try? await store.articleForNavigation(
            .init(articleID: nil, link: target.articleLink ?? "")
        ) {
            readManager.markAsRead(resolved.id)
        }
    }

    private static func handleOpen(
        target: NotificationTarget,
        store: ArticleStore,
        activateApp: @MainActor () -> Void
    ) {
        activateApp()
        store.pendingNavigation = .init(
            articleID: target.articleID,
            link: target.articleLink ?? ""
        )
    }
}
