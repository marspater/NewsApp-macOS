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
import UserNotifications

/// Opt-in real OS delivery check. Uses temporary defaults/database and synthetic articles only.
@main
struct NativeNotificationQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = NotificationQADelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class NotificationQADelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var lookupStarted: Date?
    private var lookupFinished: Date?

    func applicationDidFinishLaunching(_: Notification) {
        Task {
            do {
                try await run()
                NSApplication.shared.terminate(nil)
            } catch {
                print("NOTIFICATION_QA_ERROR=\(error)")
                exit(1)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .list] }

    private func run() async throws {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let authorization = await center.notificationSettings().authorizationStatus
        print("NOTIFICATION_AUTHORIZATION=\(authorization.rawValue)")
        guard authorization == .authorized || authorization == .provisional else {
            throw AuditError.notificationsNotAuthorized
        }
        let suite = testDefaultsSuite("news.notification-live")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.feedURLs = ["https://notification-audit.invalid/feed.xml"]
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        settings.aiEnabled = false
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"))
        await store.initialize()
        let token = UUID().uuidString
        let reports = [
            FeedArticle(
                title: "National emergency declared after major earthquake",
                link: "https://httpbin.org/delay/12?notification-audit=\(token)",
                guid: "timing-\(token)",
                description: "A major earthquake disaster has caused an emergency and crisis across the region.",
                pubDate: Date(), source: "Notification timing audit"),
            FeedArticle(
                title: "President elected after national emergency crisis",
                link: "https://example.com/notification-image-audit/\(token)",
                guid: "image-\(token)",
                description: "The president was elected after the national emergency and a major political crisis.",
                pubDate: Date(), source: "Notification image audit",
                imageUrl: "https://www.gstatic.com/webp/gallery/1.webp"),
        ]
        let identifiers = Set(reports.map { "news-\($0.link.hashValue)" })
        defer { center.removeDeliveredNotifications(withIdentifiers: Array(identifiers)) }
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in [(urls[0], reports, nil, nil)] },
            imageFinder: StoryImageFinder { [weak self] link in
                await self?.recordLookupStart()
                let result = await StoryImageFinder.publisherPages.find(link)
                await self?.recordLookupFinish()
                return result
            }, allowsBackgroundWork: { true })
        let refresh = Task { await manager.fetchFeedsAsync() }
        let deadline = Date().addingTimeInterval(25)
        var delivered: [UNNotification] = []
        var observedOverlap = false
        var observedAt: Date?
        while Date() < deadline {
            delivered = await center.deliveredNotifications().filter { identifiers.contains($0.request.identifier) }
            if !delivered.isEmpty, lookupStarted != nil, lookupFinished == nil {
                observedOverlap = true
                observedAt = Date()
            }
            if observedOverlap, delivered.contains(where: { !$0.request.content.attachments.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await refresh.value
        manager.stopBackgroundWork()
        let withImage = delivered.filter { !$0.request.content.attachments.isEmpty }
        guard observedOverlap, withImage.count == 1 else { throw AuditError.deliveryOrImageMissing }
        let imageNotification = withImage[0].request.content
        guard let link = imageNotification.userInfo["articleLink"] as? String else {
            throw AuditError.wrongDestination
        }
        let destination = try await store.articleForNavigation(
            .init(
                articleID: imageNotification.userInfo["articleID"] as? String, link: link))
        guard imageNotification.attachments[0].type == "public.png",
            destination?.title == imageNotification.subtitle, destination?.link == reports[1].link
        else { throw AuditError.wrongDestination }
        let report: [String: Any] = [
            "delivered": delivered.count, "withImage": withImage.count,
            "lookupStarted": lookupStarted!.timeIntervalSince1970,
            "deliveredObserved": observedAt!.timeIntervalSince1970,
            "lookupFinishedAtObservation": false, "attachmentType": imageNotification.attachments[0].type,
            "destinationMatches": true, "authorization": authorization.rawValue,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("NOTIFICATION_QA_REPORT=\(String(decoding: data, as: UTF8.self))")
    }

    private func recordLookupStart() {
        lookupStarted = Date()
        print("LOOKUP_STARTED=\(lookupStarted!.timeIntervalSince1970)")
    }
    private func recordLookupFinish() {
        lookupFinished = Date()
        print("LOOKUP_FINISHED=\(lookupFinished!.timeIntervalSince1970)")
    }
    private enum AuditError: Error {
        case notificationsNotAuthorized, deliveryOrImageMissing, wrongDestination
    }
}
