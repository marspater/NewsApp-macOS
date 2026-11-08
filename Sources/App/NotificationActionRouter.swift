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

/// Asks for notification permission once per launch (#562), never at launch: only once a refresh has completed and
/// the reader has stories, the first-launch sheet is closed and notifications are on. Whichever comes last asks:
/// a later refresh that brings the first stories, or turning notifications on.
@MainActor
final class NotificationPermissionRequest {
    private(set) var hasRequested = false
    private var subscription: AnyCancellable?

    init(feedManager: FeedManager, settings: AppSettings, request: @escaping () -> Void) {
        // Stories are checked when a refresh completes, never while one is still publishing its first stories.
        let refreshedWithStories = feedManager.$lastRefreshCompletedAt
            .compactMap { $0 }
            .filter { [weak feedManager] _ in feedManager?.articles.isEmpty == false }
            .first()
        subscription =
            refreshedWithStories
            .combineLatest(settings.$notificationsEnabled, settings.$firstLaunchCompleted)
            .sink { [weak self] _, enabled, onboarded in
                guard let self, !self.hasRequested, enabled, onboarded else { return }
                self.hasRequested = true
                self.subscription?.cancel()
                self.subscription = nil
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
            await articleStore.waitForStartup()
            await handleSave(target: target, store: articleStore, savedStories: savedStories)
        case NotificationActionIdentifier.markRead:
            await articleStore.waitForStartup()
            await handleMarkRead(target: target, store: articleStore, readManager: readManager)
        case NotificationActionIdentifier.open, UNNotificationDefaultActionIdentifier:
            await handleOpen(target: target, store: articleStore, activateApp: activateApp)
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
        // A link matches only when the banner carries no ID: stories can share a URL, and an ID outside the loaded
        // list is resolved by `articleForNavigation`, not by another story's link.
        if let id = target.articleID, let article = store.articles.first(where: { $0.id == id }) {
            savedStories.save(article)
        } else if target.articleID == nil, let link = target.articleLink,
            let article = store.articles.first(where: {
                $0.link == link || $0.normalizedLink == ArticleIdentity.canonicalizeURL(link)
            })
        {
            savedStories.save(article)
        } else if let id = target.articleID, let article = savedStories.savedArticles.first(where: { $0.id == id }) {
            savedStories.save(article)
        } else if target.articleID == nil, let link = target.articleLink,
            let article = savedStories.savedArticles.first(where: {
                $0.link == link || $0.normalizedLink == ArticleIdentity.canonicalizeURL(link)
            })
        {
            savedStories.save(article)
        } else {
            do {
                // An ID never falls back to a link here, for the same reason as above.
                let link = target.articleID == nil ? target.articleLink ?? "" : ""
                if let resolved = try await store.articleForNavigation(.init(articleID: target.articleID, link: link)) {
                    savedStories.save(resolved)
                } else {
                    store.operationError = "This story is no longer available in your archive."
                }
            } catch {
                store.operationError = "The notification story could not be loaded. Please try again."
            }
        }
    }

    private static func handleMarkRead(
        target: NotificationTarget,
        store: ArticleStore,
        readManager: ReadManager
    ) async {
        do {
            let link = target.articleID == nil ? target.articleLink ?? "" : ""
            if let resolved = try await store.articleForNavigation(
                .init(articleID: target.articleID, link: link)
            ) {
                readManager.markAsRead(resolved.id)
            }
        } catch {
            store.operationError = "The notification story could not be loaded. Please try again."
        }
    }

    private static func handleOpen(
        target: NotificationTarget,
        store: ArticleStore,
        activateApp: @MainActor () -> Void
    ) async {
        activateApp()
        // Set without waiting for startup: MainView opens it once the store is ready, and a link opened meanwhile
        // replaces it instead of being overwritten when startup ends.
        store.pendingNavigation = .init(
            articleID: target.articleID,
            link: target.articleLink ?? ""
        )
    }
}
