import AppKit
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
        let rawID = (userInfo["articleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let articleID = (rawID?.isEmpty == false) ? rawID : nil
        let rawLink = (userInfo["articleLink"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let articleLink = (rawLink?.isEmpty == false) ? rawLink : nil

        guard articleID != nil || articleLink != nil else { return }

        switch actionIdentifier {
        case NotificationActionIdentifier.save:
            if let id = articleID, let article = articleStore.articles.first(where: { $0.id == id }) {
                savedStories.save(article)
            } else if let link = articleLink,
                let article = articleStore.articles.first(where: {
                    $0.link == link || $0.normalizedLink == ArticleIdentity.canonicalizeURL(link)
                })
            {
                savedStories.save(article)
            } else if let resolved = try? await articleStore.articleForNavigation(
                .init(articleID: articleID, link: articleLink ?? "")
            ) {
                savedStories.save(resolved)
            } else if let id = articleID {
                let fallback = FeedArticle(
                    storedID: id,
                    title: "Saved Story",
                    link: articleLink ?? "",
                    guid: id,
                    description: "",
                    pubDate: Date(),
                    source: "Notification"
                )
                savedStories.save(fallback)
            }
        case NotificationActionIdentifier.markRead:
            if let id = articleID {
                readManager.markAsRead(id)
            } else if let link = articleLink,
                let article = articleStore.articles.first(where: {
                    $0.link == link || $0.normalizedLink == ArticleIdentity.canonicalizeURL(link)
                })
            {
                readManager.markAsRead(article.id)
            } else if let resolved = try? await articleStore.articleForNavigation(
                .init(articleID: nil, link: articleLink ?? "")
            ) {
                readManager.markAsRead(resolved.id)
            }
        case NotificationActionIdentifier.open, UNNotificationDefaultActionIdentifier:
            activateApp()
            articleStore.pendingNavigation = .init(
                articleID: articleID,
                link: articleLink ?? ""
            )
        default:
            break
        }
    }
}
