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
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import Observation
import PDFKit
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// The Lifecycle suites of the regression runner; `LifecycleTests.run()` is this atom's entry point.
enum LifecycleTests {
    static func run() async throws { try await NewsTests.runLifecycleTests() }
}

extension NewsTests {
    static func runLifecycleTests() async throws {
        let fixtureRoot = defaultFixtureRoot
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testAppSettingsDecoupling", { await testAppSettingsDecoupling() }),
            (
                "testAuditPersistenceAndRoutingRegressions",
                { try await testAuditPersistenceAndRoutingRegressions(fixtureRoot: fixtureRoot) }
            ),
            ("testAuditRefreshRegressions", { try await testAuditRefreshRegressions(fixtureRoot: fixtureRoot) }),
            ("testRefreshEndsAtCollection", { try await testRefreshEndsAtCollection() }),
            ("testProductionFollowupRegressions", { try await testProductionFollowupRegressions() }),
            ("testOfflineCacheAndResilience", { await testOfflineCacheAndResilience() }),
            ("testEnrichmentQueueSchedulingAndPromotion", { await testEnrichmentQueueSchedulingAndPromotion() }),
            ("testEnrichmentQueueCancelledJobsNotRetained", { await testEnrichmentQueueCancelledJobsNotRetained() }),
            ("testDistributionAndEntitlementsIntegrity", { await testDistributionAndEntitlementsIntegrity() }),
            ("testStrictSemVerAndReleaseSecurity", { await testStrictSemVerAndReleaseSecurity() }),
            ("testUpdateCheckerObservation", { await testUpdateCheckerObservation() }),
            ("testUpdateCheckerThrottleWithClock", { await testUpdateCheckerThrottleWithClock() }),
            ("testUpdateCheckerFailureBackoff", { await testUpdateCheckerFailureBackoff() }),
            ("testUpdateCheckerVersionComparisonAndErrors", { await testUpdateCheckerVersionComparisonAndErrors() }),
            ("testUpdateCheckerAdversarialEdgeCases", { await testUpdateCheckerAdversarialEdgeCases() }),
            ("testNotificationActionsAndRouting", { await testNotificationActionsAndRouting() }),
            (
                "testMarkReadPrunedStoryBannerRaisesNoOperationError",
                { await testMarkReadPrunedStoryBannerRaisesNoOperationError() }
            ),
            ("testNotificationModeTriageAndGrammar", { await testNotificationModeTriageAndGrammar() }),
            ("testFeedRemovalAndShutdown", { try await testFeedRemovalAndShutdown() }),
            ("testSleepAndWakeRefresh", { try await testSleepAndWakeRefresh() }),
            ("testRetentionPruneAfterRefresh", { try await testRetentionPruneAfterRefresh() }),
            ("testCancelledRefreshCarriesNotifications", { try await testCancelledRefreshCarriesNotifications() }),
            ("testUndatedStoriesInPublicationWindow", { try await testUndatedStoriesInPublicationWindow() }),
            ("testAppSettingsIsolationAndURLNormalization", { await testAppSettingsIsolationAndURLNormalization() }),
            ("testNotificationServiceErrorLogging", { await testNotificationServiceErrorLogging() }),
            ("testSettingsOPMLImportStatus", { await testSettingsOPMLImportStatus() }),
            (
                "testNotificationDedupeAcrossRefreshes",
                { try await testNotificationDedupeAcrossRefreshes(fixtureRoot: fixtureRoot) }
            ),
            (
                "testNotificationLanesAcrossRefreshes",
                { try await testNotificationLanesAcrossRefreshes(fixtureRoot: fixtureRoot) }
            ),
            ("testNotifyBeforeClustering", { try await testNotifyBeforeClustering() }),
            ("testBannerTakesRecordedPhoto", { try await testBannerTakesRecordedPhoto() }),
            ("testArticleStoreErrorResilience", { await testArticleStoreErrorResilience() }),
            ("testSystemErrorHardeningAndResilience", { await testSystemErrorHardeningAndResilience() }),
            ("testAppContainerWiring", { await testAppContainerWiring() }),
            ("testReadManagerReconciliationCache", { try await testReadManagerReconciliationCache() }),
            ("testMemoryLeakMitigationsAndErrorHandling", { try await testMemoryLeakMitigationsAndErrorHandling() }),
        ]
        try await runSuite(tests)
    }

    @MainActor
    static func testProductionFollowupRegressions() async throws {
        print("  - Testing cache rollback, ordered mutations, saved analysis and update failures...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("regression.sqlite").path
        let db = DatabaseEngine(path: path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        assertTrue(store.migrationCoordinator == nil, "Injected stores must not migrate real user defaults or caches")
        let article = FeedArticle(
            title: "Archived report", link: "https://example.com/archive", guid: "archived", description: "Preview",
            pubDate: .distantPast, source: "Publisher", fullContent: "Preserve this body")
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/rss")
        let reads = ReadManager(articleStore: store)
        let saves = SavedStoriesManager(articleStore: store)
        for _ in 0..<20 {
            reads.toggleRead(article.id)
            saves.save(article)
            saves.remove(article)
        }
        reads.markAsRead(article.id)
        saves.save(article)
        await reads.waitForPendingChanges()
        await saves.waitForPendingChanges()
        assertTrue(try await db.isSaved(articleId: article.id), "Latest rapid save intent persists")
        assertTrue(try await db.getReadArticleIDs().contains(article.id), "Latest rapid read intent persists")
        let analysis = ArticleAnalysis(
            summary: "New summary", keyPoints: ["Finding"], entities: [], category: "Science", sentiment: nil,
            modelIdentifier: "test", analysisVersion: 2)
        await store.saveArticleAnalysis(analysis, for: article.id)
        assertEqual(store.savedArticles.first?.aiSummary, "New summary", "Saved snapshot receives new analysis")
        await store.setSaved(article: article, isSaved: false)
        var connection: OpaquePointer?
        assertEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated failure-injection database")
        defer { sqlite3_close(connection) }
        assertEqual(
            sqlite3_exec(
                connection,
                "CREATE TRIGGER fail_cache BEFORE DELETE ON article_enrichment BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;",
                nil, nil, nil), SQLITE_OK, "Install rollback regression trigger")
        do {
            try await store.clearArticleCache()
            assertTrue(false, "Cache failures must reach the caller")
        } catch {
            // Failure is expected: the preceding assertion rejects an unexpected success.
        }
        let restored = try await db.fetchArticles(limit: 10)
        assertEqual(
            restored.first?.fullContent, "Preserve this body", "Failed cleanup rolls back the preceding content update")
        assertEqual(
            sqlite3_exec(connection, "DROP TRIGGER fail_cache;", nil, nil, nil), SQLITE_OK,
            "Remove isolated failure trigger")
        try await store.clearAllDatabaseCache()
        assertTrue(try await db.getReadArticleIDs().contains(article.id), "All-cache cleanup preserves read history")
        try await db.markAllRead(feedUrl: "https://example.com/rss")

        var recent: [FeedArticle] = []
        for number in 0..<510 {
            recent.append(
                FeedArticle(
                    title: "Recent \(number)", link: "https://example.com/\(number)", guid: "recent-\(number)",
                    description: "Recent", pubDate: Date(), source: "Publisher"))
        }
        try await db.upsertArticles(recent)
        let history = try await db.fetchArticles(isRead: true, limit: 200)
        assertTrue(
            history.contains(where: { $0.id == article.id }), "History queries include stories beyond the recent 500")
        let found = try await db.searchArticles(query: "Archived", limit: 200)
        assertEqual(found.first?.id, article.id, "Search reaches archived stories")
        assertEqual(
            try await db.searchArticles(query: "Archiv", limit: 200).first?.id, article.id,
            "FTS prefix search matches unfinished words")
        try await db.markRead(articleId: article.id, isRead: false)
        try await db.upsertArticles([article], feedUrl: "https://example.com/second-rss")
        try await db.markAllRead(feedUrl: "https://example.com/rss")
        assertTrue(
            try await db.getReadArticleIDs().contains(article.id),
            "Duplicate ingestion preserves original feed provenance")
        try await db.markRead(articleId: article.id, isRead: false)
        try await db.markAllRead(feedUrl: "https://example.com/second-rss")
        assertTrue(
            try await db.getReadArticleIDs().contains(article.id), "Shared stories belong to every originating feed")
        let firstPage = try await db.fetchArticles(limit: 200)
        let secondPage = try await db.fetchArticles(
            limit: 200, options: ArticleFetchOptions(after: ArticleQueryCursor(firstPage.last!)))
        let thirdPage = try await db.fetchArticles(
            limit: 200, options: ArticleFetchOptions(after: ArticleQueryCursor(secondPage.last!)))
        assertEqual(
            Set((firstPage + secondPage + thirdPage).map(\.id)).count, 511,
            "Keyset pages include all stories without duplicates at tied dates")
        let searchPage = try await db.searchArticles(query: "Recent", limit: 200)
        let searchNext = try await db.searchArticles(
            query: "Recent", limit: 400, after: ArticleQueryCursor(searchPage.last!))
        assertEqual(
            Set((searchPage + searchNext).map(\.id)).count, 510, "FTS rank cursor handles tied ranks without omissions")
        await db.close()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        let checker = UpdateChecker(httpClient: testClient)
        checker.updateAvailable = true
        checker.verifiedReleaseURL = URL(string: "https://github.com/marspater/NewsApp-macOS/releases/latest")
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await checker.checkForUpdates(userInitiated: true)
        assertFalse(checker.updateAvailable, "Failed update checks clear stale availability")
        assertTrue(checker.verifiedReleaseURL == nil, "Failed update checks clear stale release links")
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        await checker.checkForUpdates(userInitiated: true)
        assertEqual(
            checker.statusMessage, "No published release is available to compare.",
            "Missing releases are not reported as up to date")

        let expectedUserAgent = "NewsApp/\(checker.currentAppVersion)"
        MockURLProtocol.requestHandler = { request in
            assertEqual(request.url?.host, "api.github.com", "Updates use the GitHub API")
            assertEqual(
                request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json",
                "Protected update requests preserve JSON negotiation")
            assertEqual(
                request.value(forHTTPHeaderField: "User-Agent"), expectedUserAgent,
                "Protected update requests preserve the app user agent")
            assertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, "Updates do not replay cached responses")
            assertEqual(request.timeoutInterval, 10, "Update requests retain their timeout")
            let payload = GitHubReleasePayload(
                tagName: "v999.0.0", name: nil,
                htmlUrl: "https://github.com/marspater/NewsApp-macOS/releases/tag/v999.0.0",
                body: "Release notes", publishedAt: nil)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, try JSONEncoder().encode(payload)
            )
        }
        await checker.checkForUpdates(userInitiated: true)
        assertTrue(checker.updateAvailable, "A valid newer release is offered through the protected client")
        assertEqual(checker.latestVersionString, "v999.0.0", "New release version is retained")
        assertEqual(checker.releaseNotes, "Release notes", "New release notes are retained")
        assertTrue(checker.verifiedReleaseURL != nil, "A trusted release link is retained")
        MockURLProtocol.requestHandler = { _ in
            assertTrue(false, "Automatic checks within 72 hours must not make another request")
            throw URLError(.cancelled)
        }
        await checker.checkForUpdates()
        assertTrue(checker.updateAvailable, "Throttling preserves the last successful result")

        MockURLProtocol.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.3)
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let running = Task { await checker.checkForUpdates(userInitiated: true) }
        while !checker.isChecking { await Task.yield() }
        await checker.checkForUpdates(userInitiated: true)
        assertEqual(
            checker.statusMessage, "Update check failed (HTTP 503)",
            "A manual check during a running one returns with its result, not the interim state")
        await running.value
        assertEqual(
            checker.statusMessage, "Update check failed (HTTP 503)",
            "Protected client HTTP failures retain their status")
        assertFalse(checker.updateAvailable, "HTTP failures clear stale availability")
        assertTrue(checker.verifiedReleaseURL == nil, "HTTP failures clear stale release links")

        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Content-Length": "1048577"])!, Data()
            )
        }
        await checker.checkForUpdates(userInitiated: true)
        assertEqual(checker.statusMessage, "Unable to check for updates", "Oversized update responses are rejected")
        assertFalse(checker.updateAvailable, "Oversized responses cannot offer an update")

        MockURLProtocol.requestHandler = { request in
            let payload = GitHubReleasePayload(
                tagName: "v999.0.0", name: nil,
                htmlUrl: "https://example.com/releases/tag/v999.0.0", body: nil, publishedAt: nil)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, try JSONEncoder().encode(payload)
            )
        }
        await checker.checkForUpdates(userInitiated: true)
        assertEqual(checker.statusMessage, "Received untrusted release URL", "Untrusted release links are rejected")
        assertFalse(checker.updateAvailable, "Untrusted release links cannot offer an update")
        assertTrue(checker.verifiedReleaseURL == nil, "Untrusted release links are never retained")
    }

    @MainActor
    static func testSettingsOPMLImportStatus() async {
        let suiteName = testDefaultsSuite("test.settings-opml-import")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }

        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let manager = FeedManager(
            settings: AppSettings(defaults: defaults), store: store, schedulesRefresh: false)

        let malformed = Data("<opml><body><outline".utf8)
        let rejected = SettingsView.opmlImportStatus(for: malformed, using: manager)
        assertTrue(rejected.failed, "Settings rejects malformed OPML rather than reporting no additions")
        assertTrue(rejected.message.contains("could not be imported"), "Settings shows the import error")
        assertTrue(store.operationError != nil, "Malformed OPML retains the operation error")

        store.operationError = nil
        let empty = Data("<opml><body></body></opml>".utf8)
        let noChanges = SettingsView.opmlImportStatus(for: empty, using: manager)
        assertFalse(noChanges.failed, "A valid empty OPML import is not an error")
        assertEqual(noChanges.message, "No new feeds imported", "Valid OPML with no additions reports no changes")
    }

    @MainActor
    static func testAppSettingsDecoupling() async {
        print("  - Testing AppSettings isolation and persistence...")

        let settings = AppSettings()
        let testFeed = "https://example.com/unique-test-feed.xml"

        _ = settings.addFeed(url: testFeed)
        assertTrue(settings.feedURLs.contains(testFeed), "AppSettings should add feed URL")

        settings.removeFeed(url: testFeed)
        assertFalse(settings.feedURLs.contains(testFeed), "AppSettings should remove feed URL")

        settings.setFetchInterval(minutes: 30)
        assertEqual(settings.fetchIntervalMinutes, 30.0, "AppSettings should update fetch interval")

        settings.setNotificationsEnabled(false)
        assertFalse(settings.notificationsEnabled, "AppSettings should update notifications toggle")
        settings.setNotificationsEnabled(true)

        settings.setAllowInsecureHTTP(true)
        assertTrue(settings.allowInsecureHTTP, "AppSettings should update allowInsecureHTTP")
        settings.setAllowInsecureHTTP(false)
    }

    @MainActor
    static func testAuditPersistenceAndRoutingRegressions(fixtureRoot: URL) async throws {
        print("  - Testing corrected metadata, alias saves and startup notification requests...")
        let db = DatabaseEngine(path: ":memory:")
        // Saves and unsaves queue Spotlight updates; the test checks persistence, not the host's Spotlight service.
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let original = FeedArticle(
            title: "Story", link: fixtureRoot.appendingPathComponent("old").absoluteString, guid: "stable-guid",
            description: "Preview", pubDate: Date(timeIntervalSince1970: 100), source: "Publisher")
        let pending = ArticleStore.NavigationRequest(articleID: original.id, link: original.link)
        store.pendingNavigation = pending
        await store.initialize()
        assertEqual(store.pendingNavigation, pending, "Initialization retains requests received before the UI mounts")
        assertEqual(
            try await db.upsertArticles([original, original]), Set([original.id]),
            "Duplicate batch rows count as one insertion")
        try await db.markRead(articleId: original.id, isRead: true)
        try await db.setSaved(articleId: original.id, isSaved: true)
        let corrected = FeedArticle(
            title: original.title, link: fixtureRoot.appendingPathComponent("corrected").absoluteString,
            guid: original.guid,
            description: original.description, pubDate: Date(timeIntervalSince1970: 200), source: original.source)
        assertTrue(
            try await db.upsertArticles([corrected]).isEmpty, "Corrected GUID metadata is an update, not a new story")
        let restored = try await db.fetchArticles(id: original.id).first!
        assertEqual(restored.link, corrected.link, "Corrected URL is persisted")
        assertEqual(restored.pubDate, corrected.pubDate, "Corrected publication date is persisted")
        assertTrue(try await db.isRead(articleId: original.id), "Metadata correction preserves reading history")
        assertTrue(try await db.isSaved(articleId: original.id), "Metadata correction preserves saved state")
        let incomplete = FeedArticle(
            title: original.title, link: "javascript:broken", guid: original.guid,
            description: original.description, pubDate: DateParser.unknownDate, source: original.source)
        try await db.upsertArticles([incomplete])
        let retained = try await db.fetchArticles(id: original.id).first!
        assertEqual(retained.link, corrected.link, "Malformed incoming URL cannot erase a working URL")
        assertEqual(retained.pubDate, corrected.pubDate, "Unknown incoming date cannot erase a known publication date")
        let archive = (0..<501).map { index in
            FeedArticle(
                title: "Recent \(index)", link: "https://example.com/recent/\(index)", guid: "recent-\(index)",
                description: "Preview", pubDate: Date(timeIntervalSince1970: Double(1000 + index)), source: "Publisher")
        }
        try await db.upsertArticles(archive)
        await store.refreshState()
        assertFalse(
            store.articles.contains { $0.id == original.id }, "Notification fixture lies outside the 500-story snapshot"
        )
        assertEqual(
            try await store.articleForNavigation(pending)?.id, original.id,
            "Stable ID routes old notifications after URL corrections")
        let legacyRequest = ArticleStore.NavigationRequest(articleID: nil, link: corrected.link + "?utm_source=rss")
        assertEqual(
            try await store.articleForNavigation(legacyRequest)?.id, original.id,
            "Old link-only notifications resolve normalized URLs")
        let saves = SavedStoriesManager(articleStore: store)
        let alias = FeedArticle(
            title: "Alias", link: corrected.link + "?utm_source=alias", guid: "different-guid",
            description: "Preview", pubDate: corrected.pubDate, source: "Other publisher")
        assertTrue(saves.isSaved(alias), "URL-equivalent feed records share visible bookmark state")
        saves.remove(alias)
        await saves.waitForPendingChanges()
        assertFalse(try await db.isSaved(articleId: original.id), "Removing alias unsaves the actual saved database ID")
        assertFalse(saves.isSaved(alias), "Alias bookmark does not bounce back after reconciliation")
        saves.save(corrected)
        saves.remove(alias)
        saves.save(alias)
        await saves.waitForPendingChanges()
        assertTrue(try await db.isSaved(articleId: original.id), "Latest alias save applies to the existing document")
        assertEqual(
            try await db.fetchArticles(id: alias.id).first?.id, original.id,
            "Alias save resolves the original document without a new primary key")
        assertEqual(
            try await db.fetchArticles(options: ArticleFetchOptions(canonicalURL: corrected.link)).count, 1,
            "Rapid save changes preserve one URL-equivalent document")
        let emptyLink = FeedArticle(
            title: "No link", link: "", guid: "empty-one", description: "", pubDate: .distantPast, source: "Publisher")
        let otherEmptyLink = FeedArticle(
            title: "Different story", link: "", guid: "empty-two", description: "", pubDate: .distantPast,
            source: "Publisher")
        saves.save(emptyLink)
        assertFalse(saves.isSaved(otherEmptyLink), "Missing URLs do not alias unrelated stories")
        await saves.waitForPendingChanges()
        for (index, link) in ["https://example.com/", "https://example.com/?utm_source=rss", "javascript:publisher"]
            .enumerated()
        {
            let first = FeedArticle(
                title: "First homepage story", link: link, guid: "home-first-\(index)",
                description: "First report", pubDate: Date(timeIntervalSince1970: 100), source: "Publisher")
            let second = FeedArticle(
                title: "Second homepage story", link: link, guid: "home-second-\(index)",
                description: "Second report", pubDate: Date(timeIntervalSince1970: 200), source: "Publisher")
            saves.save(first)
            assertFalse(saves.isSaved(second), "Generic or invalid links do not alias separate bookmarks")
            saves.save(second)
            await saves.waitForPendingChanges()
            assertTrue(try await db.isSaved(articleId: first.id), "First bookmark persists independently")
            assertTrue(try await db.isSaved(articleId: second.id), "Second bookmark persists independently")
            let restoredSaves = SavedStoriesManager(articleStore: store)
            restoredSaves.remove(first)
            await restoredSaves.waitForPendingChanges()
            assertFalse(try await db.isSaved(articleId: first.id), "Selected bookmark is removed")
            assertTrue(
                restoredSaves.isSaved(second), "Removing one homepage story keeps the other saved in the restored UI")
            assertTrue(
                try await db.isSaved(articleId: second.id),
                "Removing one homepage story keeps the other saved in SQLite")
        }
        await db.close()
        do {
            _ = try await store.fetchArticles()
            assertTrue(false, "Storage read failure must propagate rather than return an empty library")
        } catch {
            // Expected closed-database error.
        }
    }

    @MainActor
    static func testAuditRefreshRegressions(fixtureRoot: URL) async throws {
        print("  - Testing notification deduplication beyond the snapshot and failed refresh storage...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("audit.sqlite").path
        let db = DatabaseEngine(path: path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let archived = FeedArticle(
            title: "Archive", link: fixtureRoot.appendingPathComponent("archive").absoluteString, guid: "archive",
            description: "", pubDate: Date(timeIntervalSince1970: 0), source: "Publisher")
        let recent = (0..<501).map { index in
            FeedArticle(
                title: "Recent \(index)", link: "https://example.com/\(index)", guid: "item-\(index)",
                description: "", pubDate: Date(timeIntervalSince1970: Double(index)), source: "Publisher")
        }
        await store.batchUpsert(articles: [archived] + recent)
        let fresh = FeedArticle(
            title: "Fresh", link: fixtureRoot.appendingPathComponent("fresh").absoluteString, guid: "fresh",
            description: "", pubDate: DateParser.unknownDate, source: "Publisher")
        let suite = testDefaultsSuite("test.audit.refresh")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = [
            fixtureRoot.appendingPathComponent("rss").absoluteString,
            fixtureRoot.appendingPathComponent("second").absoluteString,
        ]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        var notified: [String] = []
        // No image lookup: stopBackgroundWork only cancels it, so its write transaction could still block the trigger below.
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [archived, fresh, fresh], nil, nil) } },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map { $0.id }) },
            dependencies: FeedManager.Dependencies(imageFinder: .unavailable))
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        let freshID = ArticleIdentity.scopedGUID(fresh.guid, feedURL: settings.feedURLs[0])!
        assertTrue(
            manager.articles.contains { $0.id == freshID }, "Notified undated story remains in the visible snapshot")
        assertEqual(notified, [freshID], "Only committed new IDs notify once, across duplicate rows and feeds")
        await manager.fetchFeedsAsync()
        assertEqual(notified, [freshID], "Repeat refresh does not re-notify stored stories")
        manager.stopBackgroundWork()
        var connection: OpaquePointer?
        assertEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated refresh failure fixture")
        defer { sqlite3_close(connection) }
        assertEqual(
            sqlite3_exec(
                connection,
                "CREATE TRIGGER fail_ingest BEFORE INSERT ON articles BEGIN SELECT RAISE(ABORT, 'simulated ingestion failure'); END;",
                nil, nil, nil), SQLITE_OK, "Install failed-ingestion trigger")
        let failed = FeedArticle(
            title: "Failed", link: fixtureRoot.appendingPathComponent("failed").absoluteString, guid: "failed",
            description: "", pubDate: Date(), source: "Publisher")
        let failureManager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [failed], nil, nil) } },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map { $0.id }) })
        await failureManager.fetchFeedsAsync()
        await failureManager.notificationPass?.value
        assertEqual(notified, [freshID], "Failed ingestion cannot send new-story notifications")
        assertFalse(
            failureManager.articles.contains { $0.id == failed.id },
            "Failed ingestion cannot replace the library with parsed data")
        // Drain the startup cache read before forcing a read failure.
        _ = try await store.fetchArticles()
        let snapshot = failureManager.articles
        await db.close()
        await failureManager.fetchFeedsAsync()
        await failureManager.notificationPass?.value
        assertEqual(failureManager.articles, snapshot, "Refresh read errors retain the visible library")
        failureManager.stopBackgroundWork()
    }

    @MainActor
    static func testRefreshEndsAtCollection() async throws {
        print("  - Testing that refresh ends at collection and background work follows energy state...")
        let suite = testDefaultsSuite("test.refresh-collection")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feed = "https://8.8.8.8/news.xml"
        settings.feedURLs = [feed]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()

        // Notification triage is follow-up work: it must not hold the spinner, the published articles or the next refresh.
        let gate = OpenGate()
        let counter = TestCounter()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await counter.increment()
                let n = await counter.value
                let article = FeedArticle(
                    title: "Report \(n)", link: "https://example.com/report-\(n)", guid: "report-\(n)",
                    description: "Publisher report", pubDate: Date(), source: "Test")
                return urls.map { ($0, [article], nil, nil) }
            },
            notifyBatch: { _, _ in await gate.wait() })
        let first = Task { await manager.fetchFeedsAsync() }
        await eventually("Triage starts after collection") { await gate.arrivals == 1 }
        assertFalse(manager.isAnyFeedLoading, "The spinner ends when collection ends, not when triage ends")
        assertEqual(manager.articles.count, 1, "Collected articles are published while triage is still running")
        assertEqual(manager.feedStatuses[feed], .idle, "The feed reports a finished refresh")
        let second = Task { await manager.fetchFeedsAsync() }  // Cmd-R during triage
        await eventually("A refresh requested during triage collects again") { await counter.value == 2 }
        await eventually("Cmd-R publishes new articles immediately") { manager.articles.count == 2 }
        assertEqual(await gate.arrivals, 1, "Its notification pass waits for the one in progress (#665)")
        await gate.open()
        await first.value
        await second.value
        await manager.notificationPass?.value
        assertEqual(await gate.arrivals, 2, "Then its notification pass runs")
        manager.stopBackgroundWork()

        // Background classification stops under Low Power Mode or thermal pressure, and otherwise runs through the shared queue.
        settings.aiEnabled = true
        settings.notificationsEnabled = false
        let queue = EnrichmentQueue(store: store)
        var energySaving = true
        let article = FeedArticle(
            title: "Superconductor Breakthrough Confirmed", link: "https://example.com/classify", guid: "classify",
            description: "Independent labs replicate zero resistance", pubDate: Date(), source: "Physics Journal")
        let background = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [article], nil, nil) } },
            notifyBatch: { _, _ in },
            dependencies: FeedManager.Dependencies(enrichmentQueue: queue, allowsBackgroundWork: { !energySaving }))
        await background.fetchFeedsAsync()
        guard let storedID = background.articles.first?.id else {
            return assertTrue(false, "The refreshed article is stored")
        }
        assertEqual(await queue.state(for: storedID), nil, "Energy saving schedules no classification")
        energySaving = false
        await background.fetchFeedsAsync()
        await eventually("Classification runs once energy saving ends") {
            await queue.state(for: storedID) == .completed
        }
        background.stopBackgroundWork()
    }

    @MainActor
    static func testOfflineCacheAndResilience() async {
        print("  - Testing Offline Cache & Resilience...")

        CacheManager.shared.configureOfflineCache()
        let size = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(size >= 0, "Cache directory byte calculation should succeed")

        CacheManager.shared.clearWebCache()
        let sizeAfter = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(sizeAfter >= 0, "Cache clear should succeed non-destructively")

        // Test Clear All Caches clears DecodedImageCache as well as database and web caches (#media-cache-leak)
        let dummyImageURL = URL(string: "https://example.com/clear_all_test_\(UUID().uuidString).jpg")!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dummyImage = ctx.makeImage()!
        DecodedImageCache.images.setObject(dummyImage, forKey: dummyImageURL as NSURL)
        assertTrue(
            DecodedImageCache.images.object(forKey: dummyImageURL as NSURL) != nil,
            "Precondition: dummy image is cached in DecodedImageCache"
        )

        let testDB = DatabaseEngine(path: ":memory:")
        let testStore = ArticleStore(database: testDB, spotlightIndexer: MockSpotlightIndexer())
        await testStore.initialize()
        let settingsView = SettingsView()
        let clearTask = settingsView.clearEverythingData(articleStore: testStore)
        await clearTask.value

        assertTrue(
            DecodedImageCache.images.object(forKey: dummyImageURL as NSURL) == nil,
            "Clear All Caches must clear DecodedImageCache"
        )
        await testDB.close()
    }

    static func testEnrichmentQueueSchedulingAndPromotion() async {
        print("  - Testing EnrichmentQueue Scheduling, Promotion & Cancellation...")

        // Opened here, so the setup write below cannot race the store's own initialisation.
        let database = DatabaseEngine(path: ":memory:")
        do { try await database.open() } catch { return assertTrue(false, "The queue test database opens") }
        let store = await ArticleStore(database: database, spotlightIndexer: MockSpotlightIndexer())
        let queue = EnrichmentQueue(store: store)

        let articleA = FeedArticle(
            title: "Artificial Intelligence in Healthcare Diagnosis",
            link: "https://example.com/ai-health",
            guid: "eq-1",
            description: "Doctors evaluate deep learning tools for radiology",
            pubDate: Date(),
            source: "MedTech"
        )
        let articleB = FeedArticle(
            title: "Superconductor Breakthrough Confirmed",
            link: "https://example.com/superconductor",
            guid: "eq-2",
            description: "Independent labs replicate zero resistance",
            pubDate: Date(),
            source: "Physics Journal"
        )

        // Fill the bounded queue first, so A and B stay queued and the cancellations below cannot race a job that
        // already finished (a refused write leaves no job behind, #820).
        let hold = OpenGate()
        for index in 0..<3 {
            Task {
                _ = await queue.scheduleOverviewGeneration(eventID: "hold-\(index)") {
                    await hold.wait()
                    return nil
                }
            }
        }
        await eventually("Held generations fill the queue") { await queue.activeJobCount() == 3 }

        // 1. Enqueue background
        await queue.enqueue(article: articleA, priority: .background)

        // 2. Duplicate prevention & promotion
        await queue.enqueue(article: articleA, priority: .interactive)

        // 3. Enqueue second article
        await queue.enqueue(article: articleB, priority: .high)

        // 4. Cancel articleB
        await queue.cancel(articleId: articleB.id, reason: .user)
        assertFalse(await queue.retainsJob(for: articleB.id), "Article B is evicted from jobs on cancel (#986)")
        assertEqual(await queue.state(for: articleB.id), nil, "Article B state is nil after eviction (#986)")

        // 5. Cancel all
        await queue.cancelAll(reason: .superseded)
        assertFalse(await queue.retainsJob(for: articleA.id), "Article A is evicted from jobs on cancelAll (#986)")
        let stateA = await queue.state(for: articleA.id)
        assertTrue(
            stateA == nil || stateA == .completed,
            "Article A is evicted unless it already finished (#986)")
        for _ in 0..<10 {
            await queue.enqueue(article: articleA, priority: .background)
            await queue.cancelAll(reason: .superseded)
            let active = await queue.activeJobCount()
            assertTrue(active <= 3, "Rapid replacement cannot exceed the concurrency bound")
        }

        await hold.open()

        // Finished work is not superseded or repeated by the next refresh, and its full FeedArticle job is released (#535).
        let articleC = FeedArticle(
            title: "Quarterly Earnings Beat Expectations", link: "https://example.com/earnings", guid: "eq-3",
            description: "Revenue and profit exceed analyst forecasts", pubDate: Date(), source: "Markets")
        // Only a stored classification counts as finished (#820).
        do { _ = try await database.upsertArticles([articleC]) } catch {
            assertTrue(false, "Article C is stored before it is classified: \(error)")
        }
        await queue.enqueue(article: articleC, priority: .interactive)
        await eventually("Article C finishes classification") { await queue.state(for: articleC.id) == .completed }
        assertFalse(
            await queue.retainsJob(for: articleC.id),
            "Completed job is removed from EnrichmentQueue.jobs so full FeedArticle payloads are not retained (#535)"
        )
        await queue.cancelAll(reason: .superseded)
        assertEqual(await queue.state(for: articleC.id), .completed, "Superseding the backlog keeps finished work")
        await queue.enqueue(article: articleC, priority: .background)
        assertEqual(await queue.state(for: articleC.id), .completed, "A finished article is not classified again")
        assertFalse(
            await queue.retainsJob(for: articleC.id),
            "Re-enqueuing a completed article stays deduplicated without re-inserting a Job entry (#535)"
        )

        // 6. Batch enqueue articles in a single operation
        let batchArticles = (0..<10).map { i in
            FeedArticle(
                title: "Batch Story \(i)",
                link: "https://example.com/batch-\(i)",
                guid: "batch-\(i)",
                description: "Batch description \(i)",
                pubDate: Date(),
                source: "BatchNews"
            )
        }
        await queue.cancelAll(reason: .superseded)
        // A job that runs and finishes leaves the queue, so held work keeps every slot and the batch stays queued.
        await eventually("The cancelled work has left its slots") { await queue.activeJobCount() == 0 }
        let batchHold = OpenGate()
        for index in 0..<3 {
            Task {
                _ = await queue.scheduleOverviewGeneration(eventID: "batch-hold-\(index)") {
                    await batchHold.wait()
                    return nil
                }
            }
        }
        await eventually("Held generations fill the queue") { await queue.activeJobCount() == 3 }
        await queue.enqueue(articles: batchArticles, priority: .background, allowHTTP: false)
        for article in batchArticles {
            let state = await queue.state(for: article.id)
            assertTrue(state != nil, "Batch enqueued article \(article.id) should exist in queue")
        }
        await batchHold.open()

        // Empty snapshot handling does not crash or create jobs
        await queue.enqueue(articles: [], priority: .background, allowHTTP: false)
    }

    static func testEnrichmentQueueCancelledJobsNotRetained() async {
        print("  - Testing EnrichmentQueue does not retain cancelled jobs or payloads (#986)...")
        let database = DatabaseEngine(path: ":memory:")
        do { try await database.open() } catch { return assertTrue(false, "The queue test database opens") }
        let store = await ArticleStore(database: database, spotlightIndexer: MockSpotlightIndexer())
        let queue = EnrichmentQueue(store: store)

        let hold = OpenGate()
        for index in 0..<3 {
            Task {
                _ = await queue.scheduleOverviewGeneration(eventID: "hold-\(index)") {
                    await hold.wait()
                    return nil
                }
            }
        }
        await eventually("Held generations fill the queue") { await queue.activeJobCount() == 3 }

        let articles = (0..<5).map { index in
            FeedArticle(
                title: "Headline \(index)",
                link: "https://example.com/\(index)",
                guid: "leak-\(index)",
                description: "Summary \(index)",
                pubDate: Date(),
                source: "Source",
                fullContent: "Very long body text for article \(index)"
            )
        }
        await queue.enqueue(articles: articles, priority: .background)
        for article in articles {
            assertTrue(await queue.retainsJob(for: article.id), "Queued article is initially retained")
        }

        await queue.cancelAll(reason: .superseded)

        for article in articles {
            assertFalse(
                await queue.retainsJob(for: article.id),
                "Cancelled job \(article.id) is evicted from EnrichmentQueue.jobs so FeedArticle is not retained (#986)"
            )
        }
        assertEqual(
            await queue.stateCounts()["cancelled (superseded)"], 5,
            "Diagnostics still count the cancelled jobs without holding them (#986)")

        // An article enqueued again after the cancel is a new job and stays retained until it runs.
        await queue.enqueue(articles: [articles[0]], priority: .background)
        assertTrue(await queue.retainsJob(for: articles[0].id), "A re-enqueued article is retained again (#986)")
        await queue.cancel(articleId: articles[0].id, reason: .user)
        assertFalse(await queue.retainsJob(for: articles[0].id), "Cancelling one article evicts its job (#986)")
        await hold.open()
    }

    static func testDistributionAndEntitlementsIntegrity() async {
        print("  - Testing Distribution, Entitlements & Privacy Manifest Integrity...")

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let entitlementsPath = (currentDir as NSString).appendingPathComponent("News.entitlements")

        assertTrue(fileManager.fileExists(atPath: entitlementsPath), "News.entitlements must exist in project root")
        for file in ["PrivacyInfo.xcprivacy", "container-migration.plist"] {
            let data = fileManager.contents(atPath: (currentDir as NSString).appendingPathComponent(file))
            let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            assertTrue(plist is [String: Any], "Distribution manifest must be a valid property list: \(file)")
        }

        let infoPlist = fileManager.contents(atPath: (currentDir as NSString).appendingPathComponent("Info.plist"))
            .flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            }
        assertTrue(
            (infoPlist?["NSFocusStatusUsageDescription"] as? String)?.isEmpty == false,
            "Info.plist explains the Focus status request, or macOS aborts the app when it asks")

        guard let data = fileManager.contents(atPath: entitlementsPath) else {
            assertEqual(true, false, "Failed to read News.entitlements data")
            return
        }

        do {
            guard
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any]
            else {
                assertEqual(true, false, "News.entitlements is not a valid dictionary plist")
                return
            }

            assertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "Sandbox must be enabled")
            // Validate minimal required entitlements
            assertEqual(
                plist["com.apple.security.network.client"] as? Bool, true,
                "com.apple.security.network.client must be enabled")
            assertEqual(
                plist["com.apple.security.files.user-selected.read-write"] as? Bool, true,
                "com.apple.security.files.user-selected.read-write must be enabled")

            // Validate that unnecessary/unsafe entitlements are NOT present
            assertEqual(
                plist["com.apple.security.network.server"] as? Bool, true,
                "Loopback gateway requires listener permission")
            assertFalse(
                plist.keys.contains("com.apple.security.device.camera"), "Camera entitlement should not be granted")
            assertFalse(
                plist.keys.contains("com.apple.security.device.microphone"),
                "Microphone entitlement should not be granted")
            assertFalse(
                plist.keys.contains("com.apple.security.personal-information.location"),
                "Location entitlement should not be granted")
            assertFalse(
                plist.keys.contains("com.apple.security.personal-information.addressbook"),
                "Contacts entitlement should not be granted")
            assertFalse(
                plist.keys.contains("com.apple.security.files.all"), "All files entitlement should not be granted")
        } catch {
            assertEqual(true, false, "Failed to parse News.entitlements: \(error)")
        }

        // Validate release packaging files exist
        let releaseBuildScript = (currentDir as NSString).appendingPathComponent("build_release.sh")
        let packageDmgScript = (currentDir as NSString).appendingPathComponent("script/distribution/package_dmg.sh")
        let notarizeScript = (currentDir as NSString).appendingPathComponent("script/distribution/notarize.sh")
        let packageSwift = (currentDir as NSString).appendingPathComponent("Package.swift")
        let privacyDoc = (currentDir as NSString).appendingPathComponent("PRIVACY.md")

        assertTrue(fileManager.fileExists(atPath: releaseBuildScript), "build_release.sh must exist")
        assertTrue(fileManager.isExecutableFile(atPath: releaseBuildScript), "build_release.sh must be executable")

        assertTrue(fileManager.fileExists(atPath: packageDmgScript), "package_dmg.sh must exist")
        assertTrue(fileManager.isExecutableFile(atPath: packageDmgScript), "package_dmg.sh must be executable")

        assertTrue(fileManager.fileExists(atPath: notarizeScript), "notarize.sh must exist")
        assertTrue(fileManager.isExecutableFile(atPath: notarizeScript), "notarize.sh must be executable")

        assertTrue(fileManager.fileExists(atPath: packageSwift), "Package.swift must exist")
        assertTrue(fileManager.fileExists(atPath: privacyDoc), "PRIVACY.md must exist")
    }

    @MainActor
    static func testUpdateCheckerObservation() async {
        let checker = UpdateChecker(currentAppVersion: "1.0.0")
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = checker.statusMessage
        } onChange: {
            changed.withLock { $0 = true }
        }
        checker.statusMessage = "Checking for updates..."
        assertTrue(changed.withLock { $0 }, "UpdateChecker changes invalidate Observation tracking")
    }

    static func testStrictSemVerAndReleaseSecurity() async {
        print("  - Testing Strict SemVer Parsing & Release URL Security...")

        // 1. Valid SemVer strings
        assertEqual(
            SemanticVersion.parse("v2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1), "v2.0.1 should parse")
        assertEqual(SemanticVersion.parse("2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1), "2.0.1 should parse")
        assertEqual(
            SemanticVersion.parse("3.4.5"[...]), SemanticVersion(major: 3, minor: 4, patch: 5),
            "A Substring parses without an intermediate String")
        assertEqual(SemanticVersion.parse("١.2.3"), nil, "SemVer only accepts ASCII digits")
        assertEqual(
            SemanticVersion.parse("10.12.3"), SemanticVersion(major: 10, minor: 12, patch: 3), "10.12.3 should parse")
        assertEqual(SemanticVersion.parse("0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0), "0.1.0 should parse")
        assertEqual(
            SemanticVersion.parse("v0.0.1"), SemanticVersion(major: 0, minor: 0, patch: 1), "v0.0.1 should parse")

        // 2. Invalid tags should be rejected (ignored)
        assertEqual(SemanticVersion.parse("release-2.0.1"), nil, "release- prefix should be rejected")
        assertEqual(SemanticVersion.parse("v2.0"), nil, "Missing patch should be rejected")
        assertEqual(SemanticVersion.parse("2"), nil, "Single integer should be rejected")
        assertEqual(SemanticVersion.parse("foo"), nil, "Arbitrary string should be rejected")
        assertEqual(SemanticVersion.parse("v2.0.1-beta"), nil, "Non-numeric suffix should be rejected")

        // 3. Leading zeros must be rejected per SemVer 2.0.0
        assertEqual(SemanticVersion.parse("001.002.003"), nil, "Components with leading zeros must be rejected")
        assertEqual(SemanticVersion.parse("01.0.0"), nil, "Major with leading zero must be rejected")
        assertEqual(SemanticVersion.parse("1.02.0"), nil, "Minor with leading zero must be rejected")
        assertEqual(SemanticVersion.parse("1.0.03"), nil, "Patch with leading zero must be rejected")

        // 4. Numeric tuple comparison
        assertTrue(
            SemanticVersion(major: 2, minor: 0, patch: 1) > SemanticVersion(major: 2, minor: 0, patch: 0),
            "2.0.1 > 2.0.0")
        assertTrue(
            SemanticVersion(major: 2, minor: 1, patch: 0) > SemanticVersion(major: 2, minor: 0, patch: 9),
            "2.1.0 > 2.0.9")
        assertTrue(
            SemanticVersion(major: 3, minor: 0, patch: 0) > SemanticVersion(major: 2, minor: 9, patch: 9),
            "3.0.0 > 2.9.9")
        assertFalse(
            SemanticVersion(major: 2, minor: 0, patch: 0) > SemanticVersion(major: 2, minor: 0, patch: 1),
            "2.0.0 is not > 2.0.1")
        assertEqual(
            SemanticVersion(major: 2, minor: 0, patch: 0), SemanticVersion(major: 2, minor: 0, patch: 0),
            "Equality check")

        // 5. Release URL Domain & Path Prefix Security
        let validURL1 = URL(string: "https://github.com/marspater/NewsApp-macOS/releases/tag/v2.1.0")!
        let validURL2 = URL(string: "https://github.com/marspater/NewsApp-macOS/releases/latest")!
        let validURL3 = URL(string: "https://github.com/marspater/NewsApp-macOS/releases")!
        let invalidPrefix = URL(string: "https://github.com/marspater/NewsApp-macOS/releasesomething")!
        let invalidScheme = URL(string: "http://github.com/marspater/NewsApp-macOS/releases/tag/v2.1.0")!
        let evilDomain = URL(string: "https://evil-github.com/marspater/NewsApp-macOS/releases/tag/v2.1.0")!
        let otherRepo = URL(string: "https://github.com/malicious/phishing/releases/tag/v2.1.0")!

        assertTrue(UpdateChecker.isValidReleaseURL(validURL1), "Valid release URL should be approved")
        assertTrue(UpdateChecker.isValidReleaseURL(validURL2), "Valid latest URL should be approved")
        assertTrue(UpdateChecker.isValidReleaseURL(validURL3), "Exact releases URL should be approved")
        assertFalse(UpdateChecker.isValidReleaseURL(invalidPrefix), "Sibling path /releasesomething must be rejected")
        assertFalse(UpdateChecker.isValidReleaseURL(invalidScheme), "Insecure HTTP release URL must be rejected")
        assertFalse(UpdateChecker.isValidReleaseURL(evilDomain), "Spoofed domain must be rejected")
        assertFalse(UpdateChecker.isValidReleaseURL(otherRepo), "Non-matching repository path must be rejected")
    }

    @MainActor
    static func testUpdateCheckerThrottleWithClock() async {
        print("  - Testing UpdateChecker 72-Hour Throttle Advancement with TestClock...")

        let baseEpoch = Date(timeIntervalSince1970: 1_700_000_000)
        let testClock = TestClock(baseEpoch)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        nonisolated(unsafe) var networkRequestCount = 0
        let makeReleasePayload: @Sendable (String) -> Data = { versionTag in
            let payload = GitHubReleasePayload(
                tagName: versionTag,
                name: "Release \(versionTag)",
                htmlUrl: "https://github.com/marspater/NewsApp-macOS/releases/tag/\(versionTag)",
                body: "Release notes for \(versionTag)",
                publishedAt: nil
            )
            return try! JSONEncoder().encode(payload)
        }

        let checker = UpdateChecker(
            httpClient: testClient,
            now: { testClock.now },
            currentAppVersion: "2.0.0"
        )

        // 1. Initial check updates lastCheckDate
        assertTrue(checker.lastCheckDate == nil, "Initial checker has nil lastCheckDate")
        MockURLProtocol.requestHandler = { request in
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.0.0")
            )
        }
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 1, "Initial automatic check executes network request")
        assertEqual(checker.lastCheckDate, baseEpoch, "Initial check sets lastCheckDate to clock.now")
        assertFalse(checker.updateAvailable, "v2.0.0 matches currentAppVersion 2.0.0 -> no update")
        assertEqual(checker.statusMessage, "NewsApp is up to date (v2.0.0)", "Status confirms up to date")

        // 2. Check one minute before the window ends is skipped (throttled)
        testClock.advance(by: UpdateChecker.automaticCheckInterval - 60)
        MockURLProtocol.requestHandler = { _ in
            assertTrue(false, "Throttled automatic check within 72 hours must not make network request")
            throw URLError(.cancelled)
        }
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 1, "Network request count remains 1 (skipped)")
        assertEqual(checker.lastCheckDate, baseEpoch, "lastCheckDate remains baseEpoch when throttled")

        // 3. User-initiated check inside the window executes immediately
        let userCheckTime = testClock.now
        MockURLProtocol.requestHandler = { request in
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.0.0")
            )
        }
        await checker.checkForUpdates(userInitiated: true)
        assertEqual(networkRequestCount, 2, "User-initiated check bypasses 72-hour throttle")
        assertEqual(checker.lastCheckDate, userCheckTime, "User check updates lastCheckDate to current time")

        // 4. Automatic check one minute after the window executes
        testClock.advance(by: UpdateChecker.automaticCheckInterval + 60)
        let nextCheckTime = testClock.now
        MockURLProtocol.requestHandler = { request in
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.0.0")
            )
        }
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 3, "Automatic check after the window executes network request")
        assertEqual(checker.lastCheckDate, nextCheckTime, "lastCheckDate updates to new check time")

        // 5. Automatic check when update is available updates state non-modally
        testClock.advance(by: UpdateChecker.automaticCheckInterval + 1)
        let updateCheckTime = testClock.now
        MockURLProtocol.requestHandler = { request in
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.1.0")
            )
        }
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 4, "Automatic check after the window executes network request")
        assertEqual(checker.lastCheckDate, updateCheckTime, "lastCheckDate updates on successful update detection")
        assertTrue(checker.updateAvailable, "Automatic check detects newer release v2.1.0")
        assertEqual(checker.latestVersionString, "v2.1.0", "Latest version string set")
        assertEqual(checker.statusMessage, "Version v2.1.0 available", "Status indicates version available")
        assertEqual(
            checker.verifiedReleaseURL?.absoluteString,
            "https://github.com/marspater/NewsApp-macOS/releases/tag/v2.1.0", "Release URL verified")
    }

    @MainActor
    static func testUpdateCheckerFailureBackoff() async {
        print("  - Testing UpdateChecker throttles after a failed attempt and across relaunch (#798)...")
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        let suite = testDefaultsSuite("test.updatechecker.backoff")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }

        nonisolated(unsafe) var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return (
                HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data()
            )
        }
        let checker = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: defaults)
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(requests, 1, "First automatic check sends one request")
        assertTrue(checker.lastCheckDate == nil, "A failed check is not a successful check")
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(requests, 1, "A rate-limited check does not retry on the next activation")

        let relaunched = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: defaults)
        await relaunched.checkForUpdates(userInitiated: false)
        assertEqual(requests, 1, "A relaunch keeps the failed attempt throttled")

        await relaunched.checkForUpdates(userInitiated: true)
        assertEqual(requests, 2, "A manual check still bypasses the throttle after a failure")

        clock.advance(by: UpdateChecker.automaticCheckInterval + 1)
        await relaunched.checkForUpdates(userInitiated: false)
        assertEqual(requests, 3, "The next automatic check runs once the window has passed")

        // A backward clock correction leaves the saved attempt in the future; it counts as expired.
        clock.advance(by: -(UpdateChecker.automaticCheckInterval + 86400))
        await relaunched.checkForUpdates(userInitiated: false)
        assertEqual(requests, 4, "A saved attempt in the future does not suppress checks")

        // An update found before a relaunch stays available while the throttle skips the launch check.
        let foundSuite = testDefaultsSuite("test.updatechecker.found")
        let foundDefaults = UserDefaults(suiteName: foundSuite)!
        defer { removeTestDefaults(foundSuite) }
        MockURLProtocol.requestHandler = { request in
            let payload = GitHubReleasePayload(
                tagName: "v2.1.0", name: nil,
                htmlUrl: "https://github.com/marspater/NewsApp-macOS/releases/tag/v2.1.0", body: "notes",
                publishedAt: nil)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, try! JSONEncoder().encode(payload)
            )
        }
        let finder = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: foundDefaults)
        await finder.checkForUpdates(userInitiated: false)
        assertTrue(finder.updateAvailable, "The check finds the newer release")
        let restored = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: foundDefaults)
        assertTrue(restored.updateAvailable, "A relaunch inside the window still offers the found update")
        assertEqual(restored.latestVersionString, "v2.1.0", "The restored update names its version")
        let upgraded = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.1.0", defaults: foundDefaults)
        assertFalse(upgraded.updateAvailable, "Once the app has that version, nothing is offered")

        // A later check that finds nothing (here a 404) removes the saved release.
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        clock.advance(by: UpdateChecker.automaticCheckInterval + 3600)
        await finder.checkForUpdates(userInitiated: false)
        let withdrawn = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: foundDefaults)
        assertFalse(withdrawn.updateAvailable, "A withdrawn release is not restored on relaunch")
    }

    @MainActor
    static func testUpdateCheckerVersionComparisonAndErrors() async {
        print("  - Testing UpdateChecker Version Comparison Against Release 2.0.0 & Error States...")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        let basePayload = { (tag: String, url: String) in
            GitHubReleasePayload(
                tagName: tag,
                name: "Release \(tag)",
                htmlUrl: url,
                body: "Release notes for \(tag)",
                publishedAt: "2026-10-25T12:00:00Z"
            )
        }

        // 1. Local 2.0.0 vs Remote 2.0.0 -> Up to date (updateAvailable == false)
        do {
            let payload = basePayload("2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Local 2.0.0 vs Remote 2.0.0 must report up to date")
            assertEqual(checker.statusMessage, "NewsApp is up to date (v2.0.0)", "Status confirms up to date")
            assertTrue(checker.verifiedReleaseURL == nil, "Release URL is nil when up to date")
            assertTrue(checker.latestVersionString == nil, "Version string is nil when up to date")
        }

        // 1b. Local 2.0.0 vs Remote v2.0.0 (with 'v' prefix) -> Up to date
        do {
            let payload = basePayload("v2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/v2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Local 2.0.0 vs Remote v2.0.0 must report up to date")
            assertEqual(
                checker.statusMessage, "NewsApp is up to date (v2.0.0)", "Status confirms up to date for v2.0.0")
        }

        // 2. Local 1.9.0 vs Remote 2.0.0 -> Update available (updateAvailable == true)
        do {
            let payload = basePayload("2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "1.9.0")
            await checker.checkForUpdates(userInitiated: true)
            assertTrue(checker.updateAvailable, "Local 1.9.0 vs Remote 2.0.0 must report update available")
            assertEqual(checker.latestVersionString, "2.0.0", "Latest version is 2.0.0")
            assertEqual(checker.releaseNotes, "Release notes for 2.0.0", "Release notes captured")
            assertEqual(
                checker.verifiedReleaseURL?.absoluteString,
                "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0", "Release URL matches")
            assertEqual(checker.statusMessage, "Version 2.0.0 available", "Status message indicates update")
        }

        // 2b. Local 1.9.9 vs Remote v2.0.0 -> Update available
        do {
            let payload = basePayload("v2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/v2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "1.9.9")
            await checker.checkForUpdates(userInitiated: true)
            assertTrue(checker.updateAvailable, "Local 1.9.9 vs Remote v2.0.0 must report update available")
            assertEqual(checker.latestVersionString, "v2.0.0", "Latest version is v2.0.0")
            assertEqual(
                checker.statusMessage, "Version v2.0.0 available", "Status message indicates update for v2.0.0")
        }

        // 3. Local 2.1.0 vs Remote 2.0.0 -> Up to date (updateAvailable == false)
        do {
            let payload = basePayload("2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.1.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Local 2.1.0 vs Remote 2.0.0 must report up to date")
            assertEqual(
                checker.statusMessage, "NewsApp is up to date (v2.1.0)", "Status confirms up to date for 2.1.0")
            assertTrue(checker.verifiedReleaseURL == nil, "Release URL is nil when 2.1.0 is up to date")
        }

        // 3b. Local 2.0.1 vs Remote 2.0.0 -> Up to date (updateAvailable == false)
        do {
            let payload = basePayload("2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.1")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Local 2.0.1 vs Remote 2.0.0 must report up to date")
            assertEqual(
                checker.statusMessage, "NewsApp is up to date (v2.0.1)", "Status confirms up to date for 2.0.1")
        }

        // 4. Remote Invalid SemVer Tags (Leading zeros, non-conforming formats)
        let invalidTags = [
            "02.0.0",  // leading zero in major
            "2.00.0",  // leading zero in minor
            "2.0.01",  // leading zero in patch
            "001.002.003",  // leading zeros in all parts
            "release-2.0.0",  // non-conforming prefix
            "v2.0",  // missing patch
            "2",  // single integer
            "v2.0.0-beta",  // non-numeric suffix
            "2.0.0-rc1",  // prerelease string
            "foo",  // arbitrary string
            "2..0",  // empty component
        ]

        for invalidTag in invalidTags {
            let payload = basePayload(
                invalidTag, "https://github.com/marspater/NewsApp-macOS/releases/tag/\(invalidTag)")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "1.9.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(
                checker.updateAvailable, "Invalid remote tag '\(invalidTag)' must not flag update available")
            assertEqual(checker.statusMessage, "No valid updates found", "Status indicates no valid updates")
            assertTrue(checker.latestVersionString == nil, "Latest version is nil for invalid SemVer")
            assertTrue(checker.verifiedReleaseURL == nil, "Release URL is nil for invalid SemVer")
        }

        // 5. Local Invalid SemVer (Configuration error)
        do {
            let payload = basePayload("2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0-beta")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Invalid local version must not flag update available")
            assertEqual(
                checker.statusMessage, "App version configuration error",
                "Status indicates configuration error for invalid local version")
        }

        // 6. Network Failure State: HTTP 404 (No published release available)
        do {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "404 response must not flag update available")
            assertEqual(
                checker.statusMessage, "No published release is available to compare.",
                "Status indicates 404 missing release")
            assertTrue(checker.lastCheckDate != nil, "404 updates lastCheckDate to throttle retries")
        }

        // 7. Network Failure State: HTTP 500 / 503
        do {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "503 response must not flag update available")
            assertEqual(
                checker.statusMessage, "Update check failed (HTTP 503)", "Status indicates HTTP 503")
        }

        // 8. Network Failure State: Payload > 1MB via Content-Length header
        do {
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json", "Content-Length": "1048577"])!,
                    Data()
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Oversized Content-Length must not flag update available")
            assertEqual(
                checker.statusMessage, "Unable to check for updates",
                "Status indicates oversized response rejected")
        }

        // 8b. Network Failure State: Payload > 1MB via streaming body
        do {
            let oversizedData = Data(repeating: 0x20, count: 1024 * 1024 + 1)
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    oversizedData
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Oversized stream must not flag update available")
            assertEqual(
                checker.statusMessage, "Unable to check for updates",
                "Status indicates oversized stream rejected")
        }

        // 9. Network Failure State: Timeout
        do {
            MockURLProtocol.requestHandler = { _ in
                throw URLError(.timedOut)
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Timeout must not flag update available")
            assertEqual(
                checker.statusMessage, "Unable to check for updates", "Status indicates timeout")
        }

        // 10. Content-Type Mismatch: Non-JSON response
        do {
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"])!,
                    Data("<html>Portal</html>".utf8)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "HTML content type must be rejected")
            assertEqual(
                checker.statusMessage, "Invalid response content type", "Status indicates HTML rejected")
        }

        // 11. Untrusted Release URL Security
        do {
            let maliciousPayload = basePayload("2.0.0", "https://malicious.example.com/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(maliciousPayload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "1.9.0")
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Untrusted release URL must not be accepted")
            assertEqual(
                checker.statusMessage, "Received untrusted release URL",
                "Status indicates untrusted release URL rejected")
            assertTrue(checker.verifiedReleaseURL == nil, "Untrusted release URL is not stored")
        }

        // 12. State Cleanup on Failure: Stale availability reset
        do {
            let payload = basePayload("2.0.0", "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0")
            MockURLProtocol.requestHandler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!,
                    try! JSONEncoder().encode(payload)
                )
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "1.9.0")
            await checker.checkForUpdates(userInitiated: true)
            assertTrue(checker.updateAvailable, "Initial check finds update available")

            MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
            await checker.checkForUpdates(userInitiated: true)
            assertFalse(checker.updateAvailable, "Failed subsequent check clears updateAvailable")
            assertTrue(checker.verifiedReleaseURL == nil, "Release URL cleared after failure")
            assertTrue(
                checker.latestVersionString == nil, "Latest version cleared after failure")
        }
    }

    @MainActor
    static func testUpdateCheckerAdversarialEdgeCases() async {
        print("  - Testing UpdateChecker Adversarial Edge Cases (Time Leaps, Concurrency, Loops)...")

        let baseEpoch = Date(timeIntervalSince1970: 1_700_000_000)
        let testClock = TestClock(baseEpoch)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        nonisolated(unsafe) var networkRequestCount = 0
        let makeReleasePayload: @Sendable (String) -> Data = { versionTag in
            let payload = GitHubReleasePayload(
                tagName: versionTag,
                name: "Release \(versionTag)",
                htmlUrl: "https://github.com/marspater/NewsApp-macOS/releases/tag/\(versionTag)",
                body: "Release notes for \(versionTag)",
                publishedAt: nil
            )
            return try! JSONEncoder().encode(payload)
        }

        MockURLProtocol.requestHandler = { request in
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.0.0")
            )
        }

        let checker = UpdateChecker(
            httpClient: testClient,
            now: { testClock.now },
            currentAppVersion: "2.0.0"
        )

        // Baseline initial check
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 1, "Baseline automatic check succeeds")
        assertEqual(checker.lastCheckDate, baseEpoch, "lastCheckDate is set to baseEpoch")

        // ====================================================================
        // 1. Time Leaps Backwards (DST rollback, clock drift, NTP adjustments)
        // ====================================================================

        // 1a. Clock drifts 1 hour backwards (DST rollback)
        testClock.advance(by: -3600)
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 1, "Automatic check is throttled during 1-hour backward DST drift")
        assertEqual(checker.lastCheckDate, baseEpoch, "lastCheckDate remains unchanged during backward drift")

        // Clock advances one second past the window after baseEpoch (from the current -1h time)
        testClock.advance(by: 3600 + UpdateChecker.automaticCheckInterval + 1)
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 2, "Automatic check executes once clock advances past 72-hour threshold")

        // 1b. Severe backward leap (30 days in the past)
        testClock.advance(by: -(30 * 86400))
        let rolledBackTime = testClock.now
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 3, "A saved attempt far in the future counts as expired")
        assertEqual(checker.lastCheckDate, rolledBackTime, "lastCheckDate resynchronizes to the rolled-back clock")

        // Check within 72 hours of new rolled-back time is throttled
        testClock.advance(by: 3600)
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 3, "Subsequent check is throttled relative to resynchronized clock")

        // ====================================================================
        // 2. Time Leaps Far Forward (30 days, 10 years)
        // ====================================================================

        // 2a. Leap 30 days forward
        testClock.advance(by: 30 * 86400)
        let forward30Time = testClock.now
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 4, "Automatic check executes after 30-day forward leap")
        assertEqual(checker.lastCheckDate, forward30Time, "lastCheckDate updates to 30-day future date")

        // Check 1 minute later is throttled
        testClock.advance(by: 60)
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 4, "Check 1 minute after 30-day leap is throttled")

        // 2b. Leap 10 years forward
        testClock.advance(by: 10 * 365 * 86400)
        let forward10yTime = testClock.now
        await checker.checkForUpdates(userInitiated: false)
        assertEqual(networkRequestCount, 5, "Automatic check executes after 10-year leap without overflow")
        assertEqual(checker.lastCheckDate, forward10yTime, "lastCheckDate updates to 10-year future date")

        // ====================================================================
        // 3. Rapid Successive Checks
        // ====================================================================

        let countBeforeLoop = networkRequestCount
        for _ in 0..<100 {
            await checker.checkForUpdates(userInitiated: false)
        }
        assertEqual(networkRequestCount, countBeforeLoop, "Rapid automatic checks in tight loop are 100% throttled")

        for _ in 0..<5 {
            await checker.checkForUpdates(userInitiated: true)
        }
        assertEqual(networkRequestCount, countBeforeLoop + 5, "Rapid sequential manual checks bypass throttle")

        // ====================================================================
        // 4. Concurrent Checks & In-Flight Gate Deduplication
        // ====================================================================

        testClock.advance(by: UpdateChecker.automaticCheckInterval + 3600)  // Expire throttle
        let gateSemaphore = DispatchSemaphore(value: 0)

        MockURLProtocol.requestHandler = { request in
            _ = gateSemaphore.wait(timeout: .now() + 5.0)
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.1.0")
            )
        }

        // Launch background check task
        let inFlightTask = Task { @MainActor in
            await checker.checkForUpdates(userInitiated: false)
        }

        // Wait until task is suspended waiting on gateSemaphore
        for _ in 0..<100 {
            if checker.isChecking { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        assertTrue(checker.isChecking, "isChecking is true while in-flight network call is pending")
        assertEqual(checker.statusMessage, "Checking for updates...", "statusMessage indicates checking in-flight")

        // Concurrent automatic check while in-flight returns immediately without duplicate network call
        await checker.checkForUpdates(userInitiated: false)

        // Concurrent user-initiated check while in-flight also returns immediately
        await checker.checkForUpdates(userInitiated: true)

        // Release the network mock
        gateSemaphore.signal()
        _ = await inFlightTask.value

        assertFalse(checker.isChecking, "isChecking is false after in-flight check completes")
        assertTrue(checker.updateAvailable, "Update detected by in-flight check")
        assertEqual(
            networkRequestCount, countBeforeLoop + 6, "In-flight deduplication prevented duplicate network calls")

        // ====================================================================
        // 5. Immediate Foregrounding Loops
        // ====================================================================

        testClock.advance(by: UpdateChecker.automaticCheckInterval + 3600)  // Expire throttle
        MockURLProtocol.requestHandler = { request in
            networkRequestCount += 1
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                makeReleasePayload("v2.1.0")
            )
        }

        // Simulate 20 foreground events fired concurrently
        // Unstructured tasks: Swift 6's region checker cannot check a main-actor child task added to a group here.
        let foregroundings = (0..<20).map { _ in
            Task { @MainActor in await checker.checkForUpdates(userInitiated: false) }
        }
        for foregrounding in foregroundings { await foregrounding.value }
        assertEqual(
            networkRequestCount, countBeforeLoop + 7,
            "20 concurrent foregrounding events produce exactly 1 network request")
    }

    @MainActor
    static func testNotificationModeTriageAndGrammar() async {
        print("  - Testing NotificationMode Triage, Privacy & Singular/Plural Grammar...")

        var identified = FeedArticle(
            title: "Story", link: "https://example.com/a", guid: "a", description: "", pubDate: Date(), source: "P")
        identified.storedID = "stable-id"
        assertEqual(
            NotificationService.notificationIdentifier(for: identified), "news-stable-id",
            "Notification identifiers come from the stored story identity, not the per-process hash seed")

        // 1. Singular/Plural grammar helper
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 1),
            "1 new article from 1 source", "Singular article and source")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 2, uniqueSourcesCount: 1),
            "2 new articles from 1 source", "Plural articles, singular source")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 3, uniqueSourcesCount: 2),
            "3 new articles across 2 sources", "Plural articles, plural sources")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 10, uniqueSourcesCount: 4),
            "10 new articles across 4 sources", "Multi-source plural formatting")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 0),
            "1 new article across 0 sources", "Edge case: 1 article, 0 sources")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 0),
            "0 new articles across 0 sources", "Edge case: 0 articles, 0 sources")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 1),
            "0 new articles from 1 source", "Edge case: 0 articles, 1 source")

        // 2. AppSettings Migration Semantics
        let suiteName = testDefaultsSuite("test.notifications.migration")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }

        // Case A: legacy privateNotificationsEnabled = true -> migrates to .private
        tempDefaults.set(true, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsA = AppSettings(defaults: tempDefaults)
        assertEqual(
            settingsA.notificationMode, AppSettings.NotificationMode.privacy,
            "Legacy private flag should migrate to .private mode")
        assertEqual(
            tempDefaults.string(forKey: AppSettings.notificationModeKey), "private",
            "Migrated key should be written to defaults")

        // Case B: legacy privateNotificationsEnabled = false -> migrates to .full
        let suiteNameB = testDefaultsSuite("test.notifications.migration.b")
        let tempDefaultsB = UserDefaults(suiteName: suiteNameB)!
        defer { removeTestDefaults(suiteNameB) }
        tempDefaultsB.set(false, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsB = AppSettings(defaults: tempDefaultsB)
        assertEqual(
            settingsB.notificationMode, AppSettings.NotificationMode.full,
            "Legacy non-private flag should migrate to .full mode")
        assertEqual(
            tempDefaultsB.string(forKey: AppSettings.notificationModeKey), "full",
            "Migrated key should be written to defaults")

        // Case C: mutation API updates both mode and legacy private flag
        settingsB.setNotificationMode(.minimal)
        assertEqual(settingsB.notificationMode, AppSettings.NotificationMode.minimal, "Mode should update to .minimal")
        assertEqual(
            tempDefaultsB.string(forKey: AppSettings.notificationModeKey), "minimal", "Key should update to minimal")

        // Starred feeds persist and go with an unsubscribed feed (#588).
        settingsB.feedURLs = ["https://example.com/feed"]
        settingsB.setFeedStarred("https://example.com/feed", true)
        assertEqual(
            AppSettings(defaults: tempDefaultsB).starredFeedURLs, ["https://example.com/feed"], "A star is stored")
        settingsB.setFeedStarred("https://example.com/feed", false)
        assertTrue(AppSettings(defaults: tempDefaultsB).starredFeedURLs.isEmpty, "Unstarring is stored")
        settingsB.setFeedStarred("https://example.com/feed", true)
        settingsB.removeFeed(url: "https://example.com/feed")
        assertTrue(settingsB.starredFeedURLs.isEmpty, "Unsubscribing removes the star")

        // At most three feeds are starred: a fourth star is refused, not swapped in (#588).
        let capped = (1...4).map { "https://cap\($0).invalid/feed" }
        for url in capped.prefix(3) { assertTrue(settingsB.setFeedStarred(url, true), "Stars up to the limit") }
        assertFalse(settingsB.setFeedStarred(capped[3], true), "A fourth star is refused")
        assertEqual(settingsB.starredFeedURLs, Set(capped.prefix(3)), "The three stars stay; none is replaced")
        assertEqual(
            AppSettings(defaults: tempDefaultsB).starredFeedURLs, Set(capped.prefix(3)),
            "The refused star is not stored")
        assertTrue(settingsB.setFeedStarred(capped[0], true), "Re-starring a starred feed at the limit is fine")
        settingsB.setFeedStarred(capped[0], false)
        assertTrue(settingsB.setFeedStarred(capped[3], true), "Unstarring frees a place")
    }

    actor FeedDeliveryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var started = false
        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func deliver() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    static func testFeedRemovalAndShutdown() async throws {
        let suite = testDefaultsSuite("test.feed-lifecycle")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = ["https://example.com/feed"]
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let article = FeedArticle(
            title: "Late delivery", link: "https://example.com/late", guid: "late", description: "Report",
            pubDate: Date(), source: "Test")
        for shutdown in 0...2 {
            settings.feedURLs = ["https://example.com/feed"]
            let gate = FeedDeliveryGate()
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in
                    guard let url = urls.first else { return [] }
                    await gate.wait()
                    return [(url, [article], nil, nil)]
                })
            let refresh = Task { await manager.fetchFeedsAsync() }
            while !(await gate.started) { await Task.yield() }
            switch shutdown {
            case 0: manager.removeFeed(url: "https://example.com/feed")
            case 1: manager.stopBackgroundWork()
            default: NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            }
            await gate.deliver()
            await refresh.value
            assertTrue(
                try await db.fetchArticles().isEmpty, "Late feed delivery after removal or shutdown must not be stored")
            manager.stopBackgroundWork()
        }
        let cancelled = Task {
            do {
                try await db.upsertArticles([article])
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        cancelled.cancel()
        assertTrue(await cancelled.value, "Cancelled database ingestion propagates cancellation")
        assertTrue(try await db.fetchArticles().isEmpty, "Cancelled ingestion rolls back its transaction")
        let panelURL = TensionMethodology.v1.panel[0].url
        let panelArticle = FeedArticle(
            storedID: "subscription-scope", title: "Subscription scope fixture",
            link: "https://example.com/subscription-scope", guid: "subscription-scope",
            description: "Panel report", pubDate: Date(), source: "Test")
        _ = try await db.upsertArticles([panelArticle], feedUrl: panelURL)
        settings.feedURLs = []
        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false)
        await eventually("Initial subscription scope hides panel-only reports") {
            (try? await db.fetchArticles())?.contains { $0.id == panelArticle.id } == false
        }
        settings.feedURLs = [panelURL]
        await eventually("Adding a subscription reveals its previously collected panel reports") {
            (try? await db.fetchArticles())?.contains { $0.id == panelArticle.id } == true
        }
        settings.feedURLs = []
        settings.feedURLs = [panelURL]
        settings.feedURLs = []
        await eventually("Rapid subscription changes apply the latest panel scope") {
            (try? await db.fetchArticles())?.contains { $0.id == panelArticle.id } == false
        }
        manager.stopBackgroundWork()
        settings.feedURLs = [panelURL]
        await manager.fetchFeedsAsync()
        assertFalse(
            try await db.fetchArticles().contains { $0.id == panelArticle.id },
            "Stopped managers no longer observe subscription changes")
        await db.close()
    }

    actor RefreshCalls {
        private(set) var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    @MainActor
    static func testSleepAndWakeRefresh() async throws {
        print("  - Testing sleep and wake: interrupted refreshes store nothing, stale feeds refresh after wake...")
        let suite = testDefaultsSuite("test.sleep-wake")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = ["https://example.com/feed"]
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        settings.fetchIntervalMinutes = 30
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let article = FeedArticle(
            title: "Overnight report", link: "https://example.com/overnight", guid: "overnight",
            description: "Report", pubDate: Date(), source: "Test")
        let center = NotificationCenter()
        let calls = RefreshCalls()
        let gate = FeedDeliveryGate()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                guard let url = urls.first else { return [] }
                if await calls.next() == 1 { await gate.wait() }
                return [(url, [article], nil, nil)]
            },
            dependencies: FeedManager.Dependencies(
                powerEvents: center, wakeRefreshDelay: .milliseconds(10), now: { clock }))
        func sleepAndWake() async {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            await manager.waitForWakeRefresh()
        }

        let interrupted = Task { await manager.fetchFeedsAsync() }
        while !(await gate.started) { await Task.yield() }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        assertFalse(manager.isAnyFeedLoading, "Sleep ends the loading state of the refresh it cancels")
        assertFalse(manager.feedStatuses.values.contains(.loading), "No feed stays marked as loading after sleep")
        await gate.deliver()
        await interrupted.value
        assertTrue(try await db.fetchArticles().isEmpty, "A refresh cut off by sleep stores nothing")

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await manager.waitForWakeRefresh()
        assertEqual(await calls.count, 1, "Sleeping again before the wake delay ends refreshes nothing")

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await manager.waitForWakeRefresh()
        assertEqual(await calls.count, 2, "An interrupted refresh is repeated after wake")
        assertEqual(try await db.fetchArticles().map(\.title), ["Overnight report"], "The wake refresh stores the feed")
        assertFalse(manager.isAnyFeedLoading, "The wake refresh ends the loading state")

        clock = clock.addingTimeInterval(5 * 60)
        await sleepAndWake()
        assertEqual(await calls.count, 2, "A refresh newer than the interval is not repeated after wake")
        clock = clock.addingTimeInterval(31 * 60)
        await sleepAndWake()
        assertEqual(await calls.count, 3, "A feed older than the interval refreshes after wake")

        manager.stopBackgroundWork()
        clock = clock.addingTimeInterval(60 * 60)
        await sleepAndWake()
        assertEqual(await calls.count, 3, "A stopped manager ignores wake")
        await db.close()
    }

    @MainActor
    static func testRetentionPruneAfterRefresh() async throws {
        print(
            "  - Testing retention: read, unsaved stories older than the setting are deleted once a day after a refresh..."
        )
        let suite = testDefaultsSuite("test.retention")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        assertEqual(settings.articleRetentionDays, 30, "Read stories are kept for 30 days by default")
        settings.feedURLs = ["https://example.com/feed"]
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        // Pruning compares against the wall clock; the injected clock only drives the once-a-day throttle.
        var clock = Date()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [], nil, nil) } },
            dependencies: FeedManager.Dependencies(imageFinder: .unavailable, now: { clock }))
        func storeOldStory(_ name: String, read: Bool, saved: Bool = false) async throws -> String {
            let article = FeedArticle(
                title: name, link: "https://example.com/\(name)", guid: name, description: name,
                pubDate: clock.addingTimeInterval(-40 * 86400), source: "Test")
            await store.batchUpsert(articles: [article], feedUrl: settings.feedURLs[0])
            guard let id = try await db.fetchArticles().first(where: { $0.title == name })?.id else {
                assertTrue(false, "Stored the \(name) story")
                return ""
            }
            if read { try await db.markRead(articleId: id, isRead: true) }
            if saved { _ = try await db.toggleSaved(articleId: id) }
            return id
        }
        func stored(_ id: String) async throws -> Bool { try await db.fetchArticles().contains { $0.id == id } }

        let read = try await storeOldStory("read", read: true)
        let saved = try await storeOldStory("saved", read: true, saved: true)
        let unread = try await storeOldStory("unread", read: false)
        await manager.fetchFeedsAsync()
        assertFalse(try await stored(read), "A read, unsaved story older than 30 days is deleted after the refresh")
        let savedKept = try await stored(saved)
        let unreadKept = try await stored(unread)
        assertTrue(savedKept && unreadKept, "Saved and unread stories are kept")

        let later = try await storeOldStory("later", read: true)
        clock = clock.addingTimeInterval(6 * 3600)
        await manager.fetchFeedsAsync()
        assertTrue(try await stored(later), "Retention runs at most once a day")
        clock = clock.addingTimeInterval(19 * 3600)
        await manager.fetchFeedsAsync()
        assertFalse(try await stored(later), "The next day's refresh prunes again")

        settings.setArticleRetentionDays(0)
        assertEqual(AppSettings(defaults: defaults).articleRetentionDays, 0, "The retention setting persists")
        let kept = try await storeOldStory("kept", read: true)
        clock = clock.addingTimeInterval(25 * 3600)
        await manager.fetchFeedsAsync()
        assertTrue(try await stored(kept), "Never keeps every story")
        manager.stopBackgroundWork()
        await db.close()
    }

    @MainActor
    static func testCancelledRefreshCarriesNotifications() async throws {
        print(
            "  - Testing a refresh cancelled by a subscription change: stories it stored are notified by the next run..."
        )
        let suite = testDefaultsSuite("test.cancelled-refresh-notifications")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = ["https://example.com/one", "https://example.com/two"]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let stories = [
            "https://example.com/one": "first", "https://example.com/two": "second",
            "https://example.com/three": "third",
        ]
        var notified: [String] = []
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                urls.map { url in
                    let name = stories[url] ?? "other"
                    let article = FeedArticle(
                        title: name, link: "https://example.com/\(name)", guid: name, description: name,
                        pubDate: Date(),
                        source: "Test")
                    return (url, [article], nil, nil)
                }
            },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map(\.id)) },
            dependencies: FeedManager.Dependencies(imageFinder: .unavailable))

        let first = Task { await manager.fetchFeedsAsync() }
        // Cancel once the first feed's story is committed and before the run can notify it.
        while try await db.fetchArticles().isEmpty { await Task.yield() }
        manager.addFeed(url: "https://example.com/three")
        assertFalse(manager.isAnyFeedLoading, "Cancelling a refresh ends its loading state")
        await first.value
        // The subscription change started the next refresh; its caller runs triage after clustering.
        for _ in 0..<2000 where notified.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        let expected = stories.map { ArticleIdentity.scopedGUID($0.value, feedURL: $0.key)! }
        assertEqual(Set(notified), Set(expected), "Stories stored by the cancelled run and by the new run are notified")
        assertEqual(notified.count, 3, "Each story is notified once")
        manager.stopBackgroundWork()
        await db.close()
    }

    static func testUndatedStoriesInPublicationWindow() async throws {
        print("  - Testing undated stories fall into a publication window by ingestion time...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let undated = FeedArticle(
            title: "Undated", link: "https://example.com/undated", guid: "undated", description: "",
            pubDate: DateParser.unknownDate, source: "Test")
        let old = FeedArticle(
            title: "Old", link: "https://example.com/old", guid: "old", description: "",
            pubDate: Date().addingTimeInterval(-3 * 86400), source: "Test")
        try await db.upsertArticles([undated, old], feedUrl: "https://example.com/feed")
        let now = Date()
        let window = try await db.fetchArticles(
            options: ArticleFetchOptions(publicationWindow: now.addingTimeInterval(-3600)...now.addingTimeInterval(60)))
        assertEqual(
            window.map(\.title), ["Undated"],
            "An undated story stored now is within the last hour; a three-day-old story is not")
        assertTrue(
            window.first.map { abs($0.orderDate.timeIntervalSince(now)) < 60 } ?? false,
            "orderDate falls back to ingestion time for an undated story")
        await db.close()
    }

    @MainActor
    static func testAppSettingsIsolationAndURLNormalization() async {
        print("  - Testing AppSettings UserDefaults Isolation & URLComponents Normalization...")

        let badgeSuite = testDefaultsSuite("test.dock-badge")
        let badgeDefaults = UserDefaults(suiteName: badgeSuite)!
        defer { removeTestDefaults(badgeSuite) }
        assertTrue(AppSettings(defaults: badgeDefaults).showsDockBadge, "The Dock badge is on by default")
        AppSettings(defaults: badgeDefaults).setShowsDockBadge(false)
        assertFalse(AppSettings(defaults: badgeDefaults).showsDockBadge, "Turning the Dock badge off persists")

        // 1. URLComponents Normalization
        let httpFeed = "http://feeds.arstechnica.com/arstechnica/index"
        let normalizedHTTPS = AppSettings.normalizeFeedURL(httpFeed, allowInsecureHTTP: false)
        assertEqual(
            normalizedHTTPS, "https://feeds.arstechnica.com/arstechnica/index",
            "Should upgrade http to https when allowInsecureHTTP is false")

        let preservedHTTP = AppSettings.normalizeFeedURL(httpFeed, allowInsecureHTTP: true)
        assertEqual(
            preservedHTTP, "http://feeds.arstechnica.com/arstechnica/index",
            "Should preserve http when allowInsecureHTTP is true")

        let upperHost = "HTTPS://FEEDS.BBCO.CO.UK/NEWS/RSS.XML/"
        let normalizedUpper = AppSettings.normalizeFeedURL(upperHost)
        assertEqual(
            normalizedUpper, "https://feeds.bbco.co.uk/NEWS/RSS.XML/",
            "Host must be lowercased; a meaningful trailing slash is kept")

        for slashed in [
            "https://www.japantimes.co.jp/feed/", "https://www.eurointegration.com.ua/rss/",
            "https://phys.org/rss-feed/",
            "https://www.theatlantic.com/feed/channel/culture/", "https://www.scmp.com/rss/91/feed/",
        ] {
            assertEqual(
                AppSettings.normalizeFeedURL(slashed), slashed,
                "Feeds served only with a trailing slash keep it: \(slashed)")
        }
        assertEqual(
            AppSettings.normalizeFeedURL("http://phys.org/rss-feed/"), "https://phys.org/rss-feed/",
            "HTTPS upgrade still applies to slashed paths")
        assertEqual(
            AppSettings.normalizeFeedURL("https://example.com/feed/?a=1"), "https://example.com/feed/?a=1",
            "Query follows the kept slash")
        assertEqual(
            AppSettings.normalizeFeedURL("https://example.com/a%2Fb/"), "https://example.com/a%2Fb/",
            "Encoded path is not rewritten")

        let bareDomain = "example.com/"
        let normalizedBare = AppSettings.normalizeFeedURL(bareDomain)
        assertEqual(
            normalizedBare, "https://example.com", "Bare domain should gain https scheme and drop the root slash")

        // #797: a pasted feed: address is unwrapped; any other explicit scheme is refused, not prefixed.
        assertEqual(
            AppSettings.normalizeFeedURL("feed://example.com/rss"), "https://example.com/rss",
            "feed:// addresses are unwrapped")
        assertEqual(
            AppSettings.normalizeFeedURL("feed:https://example.com/rss"), "https://example.com/rss",
            "feed:https:// addresses are unwrapped")
        for refused in [
            "ftp://example.com/rss", "webcal://example.com/cal", "file:///etc/passwd", "javascript:alert(1)",
        ] {
            assertTrue(AppSettings.normalizeFeedURL(refused) == nil, "\(refused) is not a feed address")
        }
        assertEqual(
            AppSettings.normalizeFeedURL("example.com:8443/feed"), "https://example.com:8443/feed",
            "A host with a port still gets https")
        assertEqual(
            AppSettings.normalizeFeedURL("feed: https://example.com/rss"), "https://example.com/rss",
            "A space after feed: is ignored")
        assertEqual(
            AppSettings.normalizeFeedURL("user:pass@example.com/rss"), "https://user:pass@example.com/rss",
            "Credentials without a scheme are not mistaken for a scheme")
        assertTrue(AppSettings.normalizeFeedURL("[2001:db8::1]/feed") != nil, "A bracketed IPv6 host is accepted")
        assertTrue(
            AppSettings.normalizeFeedURL("ftp:user:pass@example.com/rss") == nil,
            "An explicit unsupported scheme is refused before credentials are read")
        assertEqual(
            AppSettings.addFeedFailureMessage(for: "ftp://example.com/rss"),
            "Feed not added. ftp: addresses are not supported. Use an http or https feed address.",
            "Add Feed names a refused scheme")
        assertEqual(
            AppSettings.addFeedFailureMessage(for: "https://example.com/rss"),
            "Feed not added. Check the URL or whether you already subscribe.",
            "A web address keeps the generic failure text")
        assertEqual(
            AppSettings.normalizeFeedURL("feed:8443/rss"), "https://feed:8443/rss",
            "feed: followed by a port is a host named feed, not a wrapper")
        let invalidURL = AppSettings.normalizeFeedURL("")
        assertEqual(invalidURL, nil, "Empty string should return nil")

        // 2. Injected UserDefaults Isolation
        let suiteName = testDefaultsSuite("test.settings.isolation")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }

        let settings = AppSettings(defaults: tempDefaults)
        _ = settings.addFeed(url: "https://isolated.example.com/rss.xml")
        settings.addSection("IsolatedSection")

        // Verify stored in tempDefaults
        let storedFeeds = tempDefaults.stringArray(forKey: AppSettings.feedURLsKey) ?? []
        assertTrue(
            storedFeeds.contains("https://isolated.example.com/rss.xml"),
            "Injected defaults must receive feedURLs mutations")

        let storedSections = tempDefaults.stringArray(forKey: AppSettings.userSectionsKey) ?? []
        assertTrue(storedSections.contains("IsolatedSection"), "Injected defaults must receive userSections mutations")

        assertEqual(AppSettings.feedKey("https://example.com"), "https://example.com", "A root URL is its own key")
        assertEqual(
            AppSettings.feedKey("https://example.com/feed/"), "https://example.com/feed",
            "One trailing slash is ignored")
        assertEqual(
            AppSettings.feedKey("https://example.com/feed//"), "https://example.com/feed/",
            "Only one trailing slash is ignored")
        assertEqual(
            AppSettings.feedKey("https://example.com/feed/?a=1"), "https://example.com/feed?a=1",
            "The query stays in the key")
        // 3. Slash variants are one subscription; the URL is stored as given and stored subscriptions are never rewritten
        let slashSuite = testDefaultsSuite("test.settings.slash")
        let slashDefaults = UserDefaults(suiteName: slashSuite)!
        defer { removeTestDefaults(slashSuite) }
        slashDefaults.set(["https://legacy.example.com/feed"], forKey: AppSettings.feedURLsKey)
        let slashSettings = AppSettings(defaults: slashDefaults)
        assertEqual(
            slashSettings.feedURLs, ["https://legacy.example.com/feed"], "Stored subscriptions are not migrated")
        assertEqual(
            slashSettings.addFeed(url: "https://legacy.example.com/feed/"), nil,
            "Slash variant of a stored subscription is a duplicate")
        assertEqual(
            slashSettings.addFeed(url: "https://Slash.example.com/feed/"), "https://slash.example.com/feed/",
            "Slashed feed is stored as given")
        assertEqual(
            slashSettings.addFeed(url: "https://slash.example.com/feed"), nil,
            "Slashless variant of a slashed subscription is a duplicate")
        assertEqual(
            slashSettings.addFeed(url: "https://slash.example.com/feed//"), "https://slash.example.com/feed//",
            "Only one trailing slash is insignificant")
        let opml = Data(
            "<opml><body><outline xmlUrl=\"https://opml.example.com/rss/\"/><outline xmlUrl=\"https://opml.example.com/rss\"/><outline xmlUrl=\"https://legacy.example.com/feed/\"/></body></opml>"
                .utf8)
        assertEqual(
            slashSettings.importFeeds(from: opml), 1,
            "OPML import adds one of two slash variants and skips subscribed ones")
        assertEqual(
            slashSettings.feedURLs.suffix(1), ["https://opml.example.com/rss/"],
            "OPML import keeps the first form as given")
        slashSettings.removeFeed(url: "https://legacy.example.com/feed")
        assertEqual(
            slashSettings.addFeed(url: "https://legacy.example.com/feed/"), "https://legacy.example.com/feed/",
            "Removing the stored form frees the slash variant")
        _ = slashSettings.addFeed(url: "https://removal.example.com/feed/")
        slashSettings.removeFeed(url: "https://removal.example.com/feed")
        assertFalse(
            slashSettings.feedURLs.contains { AppSettings.feedKey($0) == "https://removal.example.com/feed" },
            "Removing the slashless form removes a slash-stored subscription")
        _ = slashSettings.addFeed(url: "https://removal.example.com/plain")
        slashSettings.removeFeed(url: "https://removal.example.com/plain/")
        assertFalse(
            slashSettings.feedURLs.contains { AppSettings.feedKey($0) == "https://removal.example.com/plain" },
            "Removing the slash form removes a slashless subscription")
        assertEqual(
            slashDefaults.stringArray(forKey: AppSettings.feedURLsKey), slashSettings.feedURLs,
            "Slash-preserving subscriptions persist as given")
        if let catalogFeed = FeedCatalog.feeds.first(where: { !$0.url.contains("?") && !$0.url.hasSuffix("/") }) {
            _ = slashSettings.addFeed(url: catalogFeed.url + "/")
            assertTrue(
                slashSettings.isSubscribed(catalogFeed), "A slash variant of a catalog feed counts as subscribed")
            assertEqual(
                slashSettings.addCatalogFeeds([catalogFeed, catalogFeed]), 0, "Catalog subscribe skips slash variants")
            assertTrue(
                !CatalogReviewEngine.detectTopicGaps(subscribedURLs: [catalogFeed.url + "/"]).contains {
                    $0.catalogSet == catalogFeed.set
                }, "A slash variant covers its catalog set")
        }
    }

    static func testNotificationServiceErrorLogging() async {
        print("  - Testing NotificationService Formatting & Robust Dispatching...")

        let service = NotificationService.shared

        // 1. Singular grammar
        let singularSummary = NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 1)
        assertEqual(singularSummary, "1 new article from 1 source", "Singular grammar check")

        // 2. Plural grammar
        let pluralSummary = NotificationService.formatMinimalSummary(articleCount: 5, uniqueSourcesCount: 3)
        assertEqual(pluralSummary, "5 new articles across 3 sources", "Plural grammar check")

        // Edge cases
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 0),
            "1 new article across 0 sources", "Edge case: 1 article, 0 sources")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 0),
            "0 new articles across 0 sources", "Edge case: 0 articles, 0 sources")
        assertEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 1),
            "0 new articles from 1 source", "Edge case: 0 articles, 1 source")

        // 3. Importance computation range [0.0, 1.0]
        assertEqual(
            NotificationService.breakingSignalWeight(in: "Studies show diesel bodies replacement"), 0,
            "Signal words match whole words only")
        assertEqual(
            NotificationService.breakingSignalWeight(in: "Man dies in attack, police say"), 2,
            "Whole-word breaking signals weigh a point each")
        assertEqual(
            NotificationService.breakingSignalWeight(in: "President announces the company launches a fund"), 1.5,
            "Announcement and office-holder words weigh half (#545)")
        let score = service.computeImportance(
            title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response.")
        assertTrue(score >= 0.0 && score <= 1.0, "Score must be bounded between 0.0 and 1.0")
        // The score is remembered per text (#937): a second service works it out afresh and must agree.
        assertEqual(
            service.computeImportance(
                title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response."),
            score, "A remembered score is the score")
        assertEqual(
            NotificationService().computeImportance(
                title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response."),
            score, "A remembered score equals a fresh one")

        // One banner per event (#523): the strongest report represents its event; singles stand alone.
        func report(_ id: Int, _ title: String) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://notify.invalid/\(id)", guid: "notify-\(id)", description: "",
                pubDate: Date(timeIntervalSince1970: 1_700_000_000), source: "Publisher \(id)")
        }
        let quiet = report(1, "Council meets on Tuesday")
        let loud = report(
            2,
            "Breaking: explosion kills dozens in Paris, London, Berlin, Madrid, Rome, Vienna, Lisbon and Dublin; emergency declared"
        )
        let third = report(3, "Explosion reported downtown")
        let single = report(4, "Local library extends opening hours")
        let events = [quiet.id: "event-a", loud.id: "event-a", third.id: "event-a"]
        let chosen = await NotificationService.representatives(of: [quiet, loud, third, single], events: events)
        assertEqual(
            chosen.map(\.article.id), [loud.id, single.id], "One report per event, the strongest, then the single")
        let alone = await NotificationService.representatives(of: [quiet, single], events: [:])
        assertEqual(alone.map(\.article.id), [quiet.id, single.id], "Without events every story stands alone in order")

        // 4. Robust dispatching (no crashes across all 3 notification tiers)
        let sampleArticle = FeedArticle(
            title: "Urgent Update", link: "https://example.com/urgent", guid: "sample-guid",
            description: "Details follow", pubDate: Date(), source: "Wire Service")
        await service.triageAndNotify(newArticles: [sampleArticle], delivery: .init(mode: .minimal))
        await service.triageAndNotify(newArticles: [sampleArticle], delivery: .init(mode: .privacy))
        await service.triageAndNotify(newArticles: [sampleArticle], delivery: .init(mode: .full))

        // 5. Banners arrive one at a time, a pause apart, threaded per story (#587): two new reports of one event are
        // one banner; three events are three spaced banners with their own threads. A breaking story is an active
        // banner with sound; a lesser one is silent.
        struct Posted: Sendable {
            let at = ContinuousClock.now
            let thread: String
            let sound: Bool
            let body: String
            let actions: Bool
            init(_ banner: StoryBanner) {
                thread = banner.thread
                sound = banner.sound
                body = banner.body
                actions = banner.actions
            }
        }
        actor Recorder {
            var posted: [Posted] = []
            func record(_ item: Posted) { posted.append(item) }
        }
        let recorder = Recorder()
        let spaced = NotificationService(post: { await recorder.record(Posted($0)) }, spacing: .milliseconds(60))
        // Three signal words and six named places put a score at 0.75 before sentiment, so these are breaking
        // whatever the sentiment tagger says.
        let fourth = report(
            5,
            "Earthquake kills hundreds in Tokyo, Osaka, Kyoto, Nagoya, Sapporo, Kobe and Sendai; emergency declared as crisis deepens"
        )
        let fifth = report(
            6,
            "Explosion at a refinery in Houston, Dallas, Austin, Denver, Phoenix, Tucson and Boise, dozens killed; urgent evacuation"
        )
        let pairEvents = [quiet.id: "event-a", loud.id: "event-a", fourth.id: "event-b", fifth.id: "event-c"]
        await spaced.triageAndNotify(
            newArticles: [quiet, loud, fourth, fifth], delivery: .init(mode: .full, events: pairEvents))
        let posted = await recorder.posted
        assertEqual(posted.count, 3, "Two reports of one event and two other events are three banners")
        assertEqual(
            Set(posted.map(\.thread)), ["event-a", "event-b", "event-c"], "Each banner is threaded under its event")
        assertTrue(
            zip(posted, posted.dropFirst()).allSatisfy { $1.at - $0.at >= .milliseconds(60) },
            "Banners of one refresh are posted at least the spacing apart")
        assertTrue(posted.allSatisfy(\.sound), "Breaking stories are banners with sound")
        assertTrue(posted.allSatisfy(\.actions), "A story's banner carries Save, Mark as Read and Open (#560)")
        // Banners are minutes apart, so the pass asks before each one whether full banners are still allowed.
        let haltedRecorder = Recorder()
        let halted = NotificationService(post: { await haltedRecorder.record(Posted($0)) }, spacing: .zero)
        var haltedDelivery = NotificationDelivery(mode: .full, events: pairEvents)
        let asked = TestCounter()
        // Allowed for the first banner's check (right before it shows), refused from then on.
        haltedDelivery.continues = {
            await asked.increment()
            return await asked.value <= 1
        }
        await halted.triageAndNotify(newArticles: [quiet, loud, fourth, fifth], delivery: haltedDelivery)
        assertEqual(
            (await haltedRecorder.posted).count, 1,
            "Once the settings no longer allow full banners, the pass stops after the banner already posting")
        assertEqual(await asked.value, 2, "A halt ends the pass: no further gap is waited out and asked again")
        let quietRecorder = Recorder()
        let quietService = NotificationService(post: { await quietRecorder.record(Posted($0)) }, spacing: .zero)
        await quietService.triageAndNotify(newArticles: [quiet], delivery: .init(mode: .full))
        assertTrue(
            (await quietRecorder.posted).allSatisfy { !$0.sound },
            "A story below the breaking score is silent when it notifies")
        let minimalRecorder = Recorder()
        let minimal = NotificationService(post: { await minimalRecorder.record(Posted($0)) }, spacing: .zero)
        await minimal.triageAndNotify(
            newArticles: [quiet, loud, third, single], delivery: .init(mode: .minimal, events: events))
        assertEqual(
            (await minimalRecorder.posted).first?.body, "2 new articles across 2 sources",
            "Summary modes count one report per event too")
        assertFalse((await minimalRecorder.posted).first?.actions ?? true, "A summary banner has no story actions")

        // 6. Normal lane (#588, #665): of 100 new stories, three are breaking, every fourth is Technology (a top
        // interest) and every tenth event has three publishers. At most five normal banners in the rolling hour.
        var seeded: [(article: FeedArticle, score: Double)] = []
        var seededEvents: [String: String] = [:]
        var publishers: [String: Int] = [:]
        for index in 0..<100 {
            var article = report(100 + index, "Story \(index)")
            article.category = ["Technology", "Food", "Travel", "Sports"][index % 4]
            article.identityFeedURL = "https://other.invalid/feed"
            seededEvents[article.id] = "seeded-\(index)"
            publishers["seeded-\(index)"] = index % 10 == 0 ? 3 : 1
            seeded.append((article, index < 3 ? 0.7 : 0.3))
        }
        var delivery = NotificationDelivery(mode: .full, events: seededEvents)
        delivery.publishers = publishers
        delivery.interests = NotificationService.topInterests(["technology": 9, "politics": 4, "world": 2, "food": 1])
        assertEqual(
            NotificationService.rankedInterests(["technology": 9, "politics": 4, "world": 2, "food": 1]),
            ["technology", "politics", "world"], "The top three interests by weight")
        func planned(_ delivery: NotificationDelivery, pending: [String: [(article: FeedArticle, score: Double)]] = [:])
            -> [String]
        {
            NotificationService.plan(new: seeded, pending: pending, delivery: delivery).banners.map {
                $0.article?.title ?? NotificationService.groupedBody($0)
            }
        }
        assertEqual(
            planned(delivery), ["Story 0", "Story 1", "Story 2", "Story 20", "Story 40"],
            "Breaking stories and top-interest stories with three publishers notify, strongest first, five at most")
        delivery.ledger.normalLastHour = 3
        assertEqual(planned(delivery), ["Story 0", "Story 1"], "The rolling hour's earlier banners use the allowance")
        delivery.ledger.normalLastHour = 5
        assertTrue(planned(delivery).isEmpty, "A full hour posts no normal banner")
        delivery.ledger.normalLastHour = 0
        delivery.interests = []
        assertEqual(
            planned(delivery), ["Story 0", "Story 1", "Story 2"], "Without interests only breaking stories notify")

        // 7. Repeated events (#545, #665): an event announced today stays quiet while its lead headline is the one
        // announced, unless it rises to a higher lane; a new lead headline notifies again.
        delivery.leadTitles = ["seeded-1": "Story 1 lead"]
        delivery.ledger.announced = [
            "seeded-1": .init(leadKey: EventFeedSummary.titleKey("Story 1 lead"), lane: .normal)
        ]
        assertEqual(planned(delivery), ["Story 0", "Story 2"], "A second report of an announced event does not notify")
        delivery.ledger.announced["seeded-1"]?.leadKey = EventFeedSummary.titleKey("An earlier lead")
        assertEqual(planned(delivery), ["Story 0", "Story 1", "Story 2"], "A changed lead headline notifies again")

        // 8. Starred lane: one banner per feed and 20 minutes, standing for every pending story (#665).
        let starredFeed = "https://starred.invalid/feed"
        func starredStory(_ index: Int, event: String? = nil) -> (article: FeedArticle, score: Double) {
            var article = FeedArticle(
                title: "Starred \(index)", link: "https://notify.invalid/\(500 + index)", guid: "notify-\(500 + index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_700_000_000), source: "Starred Daily")
            article.identityFeedURL = starredFeed
            if let event { delivery.events[article.id] = event }
            return (article, 0.3)
        }
        delivery.starredFeedURLs = [starredFeed]
        delivery.ledger.announced = [:]
        let one = [starredFeed: [starredStory(1)]]
        assertTrue(planned(delivery, pending: one).contains("Starred 1"), "One pending story is an individual banner")
        let burst = (0..<20).map { starredStory($0) }
        let grouped = NotificationService.plan(new: seeded, pending: [starredFeed: burst], delivery: delivery).banners
            .filter { $0.lane == .starred }
        assertEqual(grouped.count, 1, "Twenty stories from a starred feed are one banner, not twenty")
        assertEqual(grouped.first?.title, "Starred Daily", "A grouped starred banner is titled with the feed")
        assertEqual(grouped.first?.thread, "starred-\(starredFeed)", "Grouped starred banners share a feed thread")
        assertTrue(
            grouped.first.map(NotificationService.groupedBody)?.hasPrefix("20 new stories\nStarred ") == true,
            "The grouped body counts the stories, then two headlines")
        delivery.ledger.lastStarred[starredFeed] = delivery.now.addingTimeInterval(-10 * 60)
        assertFalse(planned(delivery, pending: one).contains("Starred 1"), "Within 20 minutes the feed stays pending")
        delivery.ledger.lastStarred[starredFeed] = delivery.now.addingTimeInterval(-21 * 60)
        assertTrue(planned(delivery, pending: one).contains("Starred 1"), "After 20 minutes its pending stories post")
        delivery.starredFeedURLs = []
        assertFalse(planned(delivery, pending: one).contains("Starred 1"), "Unstarring stops the feed's banners")
        delivery.starredFeedURLs = [starredFeed]

        // B: an event announced only as normal rises to starred; one announced as starred posts no individual banner,
        // but its story still counts in the feed's next group.
        let risen = [starredFeed: [starredStory(30, event: "known")]]
        delivery.ledger.announced = ["known": .init(leadKey: EventFeedSummary.titleKey("Starred 30"), lane: .normal)]
        assertTrue(planned(delivery, pending: risen).contains("Starred 30"), "Normal → starred notifies")
        delivery.ledger.announced["known"]?.lane = .starred
        assertFalse(planned(delivery, pending: risen).contains("Starred 30"), "A starred event does not repeat")
        let mixed = NotificationService.plan(
            new: seeded, pending: [starredFeed: [starredStory(30, event: "known"), starredStory(31)]],
            delivery: delivery
        ).banners.filter { $0.lane == .starred }
        assertEqual(mixed.first?.count, 2, "N counts the announced event's story as well")
        assertEqual(mixed.first?.headlines.first, "Starred 31", "Headlines prefer the unannounced story")
        delivery.ledger.announced = [:]

        // 9. Priority lane: exceptional news, the highest lane, coalesced in bursts and never silenced.
        assertTrue(
            NotificationService.isPriority(title: "Earthquake kills hundreds", score: 0.8, publishers: 4),
            "A full-weight signal, a high score and four publishers are priority")
        assertFalse(
            NotificationService.isPriority(title: "Earthquake kills hundreds", score: 0.8, publishers: 3),
            "Three publishers are not enough")
        assertFalse(
            NotificationService.isPriority(title: "President announces a fund", score: 0.9, publishers: 6),
            "Half-weight words never make priority")
        var majors: [(article: FeedArticle, score: Double)] = []
        for index in 0..<5 {
            let article = report(700 + index, "Explosion \(index)")
            delivery.events[article.id] = "major-\(index)"
            delivery.publishers["major-\(index)"] = 5
            majors.append((article, 0.9 - Double(index) / 100))
        }
        var priority = NotificationService.plan(new: majors, pending: [:], delivery: delivery)
        assertEqual(
            priority.banners.map { $0.article?.title ?? NotificationService.groupedBody($0) },
            ["Explosion 0", "Explosion 1", "Explosion 2", "2 more major stories\nExplosion 3\nExplosion 4"],
            "A priority burst posts three banners, then one grouped banner")
        assertTrue(priority.banners.allSatisfy { $0.lane == .priority && $0.sound }, "Priority banners sound")
        delivery.ledger.priorityLastHalfHour = 3
        delivery.ledger.priorityGroupLastHalfHour = true
        priority = NotificationService.plan(new: majors, pending: [:], delivery: delivery)
        assertTrue(priority.banners.isEmpty, "Past both limits nothing posts now")
        assertEqual(priority.queued.map(\.event), (0..<5).map { "major-\($0)" }, "Every key waits; none is silenced")
        delivery.ledger.priorityGroupLastHalfHour = false
        delivery.ledger.priorityQueue = priority.queued
        priority = NotificationService.plan(new: [], pending: [:], delivery: delivery)
        assertEqual(priority.banners.map(\.count), [5], "The waiting keys arrive in the next grouped banner")
        assertEqual(
            Set(priority.banners.first.map { Array($0.announces.keys) } ?? []),
            Set((0..<5).map { "major-\($0)" } + (priority.banners.first?.members ?? [])),
            "The grouped banner announces every waiting key and each key's own report (#790)")
        delivery.ledger.priorityLastHalfHour = 0
        delivery.ledger.priorityQueue = []

        // A higher lane wins: an event that is priority and has a starred report posts one priority banner.
        var starredMajor = majors[0].article
        starredMajor.identityFeedURL = starredFeed
        delivery.events[starredMajor.id] = "major-0"
        let both = NotificationService.plan(
            new: [majors[0], (starredMajor, 0.3)], pending: [starredFeed: [(starredMajor, 0.3)]], delivery: delivery)
        assertEqual(
            both.banners.map(\.lane), [.priority], "The same event qualifying twice posts once, in the higher lane")
        let together = NotificationService.plan(
            new: seeded + [majors[1]], pending: [starredFeed: [starredStory(40), starredStory(41)]], delivery: delivery)
        assertEqual(
            together.banners.map(\.lane), [.priority, .starred, .normal, .normal, .normal],
            "Simultaneous arrivals post priority, then the starred group, then normal stories")

        // Two events of one story (#740): one banner per pass, threaded by the story; a later event of an announced
        // story adds to it without notifying again, unless it reaches a higher lane.
        var storyDelivery = NotificationDelivery(mode: .full)
        let stormFirst = report(800, "Storm reaches the coast")
        let stormSecond = report(801, "Storm leaves thousands without power")
        let stormMajor = report(802, "Explosion at a storm shelter")
        storyDelivery.events = [stormFirst.id: "storm-a", stormSecond.id: "storm-b", stormMajor.id: "storm-c"]
        storyDelivery.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        storyDelivery.publishers = ["storm-c": 5]
        let storyPass = NotificationService.plan(
            new: [(stormFirst, 0.7), (stormSecond, 0.75)], pending: [:], delivery: storyDelivery
        ).banners
        assertEqual(
            storyPass.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "Two events of one story post one banner, by the stronger report")
        assertEqual(storyPass.first?.thread, "storm-a", "A story's banners share the story's thread")
        storyDelivery.ledger.announced["storm-a"] = .init(
            leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .normal)
        assertTrue(
            NotificationService.plan(new: [(stormSecond, 0.75)], pending: [:], delivery: storyDelivery).banners
                .isEmpty,
            "A new event of an announced story does not notify again")
        assertEqual(
            NotificationService.plan(new: [(stormMajor, 0.9)], pending: [:], delivery: storyDelivery).banners.map(
                \.lane), [.priority],
            "A new event of an announced story notifies when it reaches a higher lane")
        // Both events announced: the stronger one unchanged, the other with a new lead headline. The new lead posts.
        var bothAnnounced = storyDelivery
        bothAnnounced.ledger.announced["storm-b"] = .init(leadKey: "an older lead", lane: .normal)
        bothAnnounced.ledger.announced["storm-a"] = .init(
            leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .normal)
        assertEqual(
            NotificationService.plan(
                new: [(stormFirst, 0.8), (stormSecond, 0.75)], pending: [:], delivery: bothAnnounced
            ).banners.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "An unchanged event of a story does not hide the other event's new lead")
        // A waiting priority key of the story drops out when another of its events gets a banner this pass.
        var queuedStory = NotificationDelivery(mode: .full)
        let shelterBlast = report(803, "Explosion at a storm shelter kills four")
        queuedStory.events = [shelterBlast.id: "storm-c"]
        queuedStory.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        queuedStory.publishers = ["storm-c": 5]
        queuedStory.ledger.priorityQueue = [
            QueuedPriority(event: "storm-b", title: "Storm leaves thousands without power", score: 0.8, leadKey: "x")
        ]
        let queuedPass = NotificationService.plan(new: [(shelterBlast, 0.9)], pending: [:], delivery: queuedStory)
        assertEqual(
            queuedPass.banners.map(\.grouped), [false],
            "A story's waiting key is covered by its new individual banner, not grouped beside it")
        // Two waiting keys of one story, left by earlier passes, count once in the next grouped banner.
        var twoQueued = NotificationDelivery(mode: .full)
        twoQueued.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        twoQueued.ledger.priorityQueue = [
            QueuedPriority(event: "storm-c", title: "Explosion at a storm shelter", score: 0.9, leadKey: "c"),
            QueuedPriority(event: "storm-b", title: "Storm leaves thousands without power", score: 0.8, leadKey: "b"),
            QueuedPriority(event: "quake", title: "Earthquake strikes the north", score: 0.85, leadKey: "q"),
        ]
        let groupedOnce = NotificationService.plan(new: [], pending: [:], delivery: twoQueued).banners
        assertEqual(groupedOnce.map(\.count), [2], "A story queued twice counts once in the grouped banner")
        assertEqual(
            Set(groupedOnce.first.map { Array($0.announces.keys) } ?? []), ["storm-b", "storm-c", "quake"],
            "The grouped banner still announces every waiting key")
        // A waiting key whose own event was announced under another lead still posts after a priority announcement.
        twoQueued.ledger.priorityQueue = [
            QueuedPriority(event: "storm-b", title: "Storm death toll rises", score: 0.8, leadKey: "new lead")
        ]
        twoQueued.ledger.announced["storm-b"] = .init(leadKey: "old lead", lane: .priority)
        assertEqual(
            NotificationService.plan(new: [], pending: [:], delivery: twoQueued).banners.map(\.count), [1],
            "A waiting key with a changed lead survives the story's priority announcement")
        // An event announced in the normal lane whose story another event announced in priority does not post again
        // in the starred lane without a new lead.
        var laneDelivery = NotificationDelivery(mode: .full)
        var starredStorm = stormFirst
        starredStorm.identityFeedURL = "https://starred.invalid/feed"
        laneDelivery.starredFeedURLs = ["https://starred.invalid/feed"]
        laneDelivery.events = [starredStorm.id: "storm-a"]
        laneDelivery.stories = ["storm-c": "storm-a"]
        laneDelivery.ledger.announced = [
            "storm-a": .init(leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .normal),
            "storm-c": .init(leadKey: "c", lane: .priority),
        ]
        assertTrue(
            NotificationService.plan(
                new: [(starredStorm, 0.5)], pending: ["https://starred.invalid/feed": [(starredStorm, 0.5)]],
                delivery: laneDelivery
            ).banners.isEmpty,
            "A story announced in priority does not post again in the starred lane")
        // A stale starred event does not hide a fresh normal event of the same story.
        var staleStarred = NotificationDelivery(mode: .full)
        staleStarred.starredFeedURLs = ["https://starred.invalid/feed"]
        staleStarred.events = [starredStorm.id: "storm-a", stormSecond.id: "storm-b"]
        staleStarred.stories = ["storm-b": "storm-a"]
        staleStarred.ledger.announced = [
            "storm-a": .init(leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .starred),
            "storm-b": .init(leadKey: "an older lead", lane: .normal),
        ]
        assertEqual(
            NotificationService.plan(
                new: [(starredStorm, 0.5), (stormSecond, 0.75)],
                pending: ["https://starred.invalid/feed": [(starredStorm, 0.5)]], delivery: staleStarred
            ).banners.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "A fresh normal event posts beside a stale starred sibling")
        // A stale priority event does not hide a fresh normal event of the same story.
        var stalePriority = NotificationDelivery(mode: .full)
        stalePriority.events = [stormMajor.id: "storm-c", stormSecond.id: "storm-b"]
        stalePriority.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        stalePriority.publishers = ["storm-c": 5]
        stalePriority.ledger.announced = [
            "storm-c": .init(leadKey: EventFeedSummary.titleKey(stormMajor.title), lane: .priority),
            "storm-b": .init(leadKey: "an older lead", lane: .normal),
        ]
        assertEqual(
            NotificationService.plan(
                new: [(stormMajor, 0.9), (stormSecond, 0.75)], pending: [:], delivery: stalePriority
            ).banners.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "A fresh normal event posts beside a stale priority sibling with a new lead")

        // Three publishers on arrival give a normal banner; a fourth makes it priority once, and never a third time.
        let rising = report(800, "Explosion levels block")
        delivery.events[rising.id] = "rising"
        delivery.publishers["rising"] = 3
        delivery.leadTitles["rising"] = rising.title
        let first = NotificationService.plan(new: [(rising, 0.9)], pending: [:], delivery: delivery).banners
        assertEqual(first.map(\.lane), [.normal], "Three publishers: a normal banner")
        let lead = EventFeedSummary.titleKey(rising.title)
        delivery.ledger.announced["rising"] = .init(leadKey: lead, lane: .normal)
        delivery.publishers["rising"] = 4
        let follow = report(801, "Explosion toll rises")
        delivery.events[follow.id] = "rising"
        assertEqual(
            NotificationService.plan(new: [(follow, 0.9)], pending: [:], delivery: delivery).banners.map(\.lane),
            [.priority], "The fourth publisher raises the event to one priority banner")
        delivery.ledger.announced["rising"]?.lane = .priority
        let later = report(802, "Explosion inquiry")
        delivery.events[later.id] = "rising"
        assertTrue(
            NotificationService.plan(new: [(later, 0.9)], pending: [:], delivery: delivery).banners.isEmpty,
            "An event announced as priority never posts a third banner")

        // Storage (#545, #665): the ledger reads what was recorded, keeps the highest lane, clamps a clock set back and
        // prunes old rows.
        do {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            let opener = report(300, "Lead report opens the event")
            let joiner = report(301, "Later report joins the event")
            try await db.upsertArticles([opener, joiner])
            let event = try await db.createEvent(memberArticleIDs: [opener.id])
            _ = try await db.addArticles([joiner.id], toEvent: event.id)
            assertEqual(
                try await db.eventLeadTitles([event.id]), [event.id: opener.title],
                "The lead story is the one that opened the event, not the newest member")
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let key = EventFeedSummary.titleKey(opener.title)
            try await db.recordNotification(
                PlannedBanner(
                    lane: .priority, grouped: false, thread: event.id, sound: true, announces: [event.id: key]),
                at: now)
            try await db.recordNotification(
                PlannedBanner(
                    lane: .normal, grouped: false, thread: event.id, sound: false, announces: [event.id: key]),
                at: now)
            try await db.recordNotification(
                PlannedBanner(lane: .starred, grouped: true, count: 4, feedURL: starredFeed, thread: "s", sound: false),
                at: now)
            try await db.queuePriority(
                [QueuedPriority(event: "waiting", title: "W", score: 0.8, leadKey: "w")], at: now)
            var ledger = try await db.notificationLedger(now: now.addingTimeInterval(60))
            assertEqual(ledger.announced[event.id], .init(leadKey: key, lane: .priority), "The highest lane is kept")
            assertEqual(ledger.normalLastHour, 1, "Normal banners count in the rolling hour")
            assertEqual(ledger.priorityLastHalfHour, 1, "Individual priority banners count in the half hour")
            assertEqual(ledger.lastStarred[starredFeed], now, "The feed's last starred banner is kept")
            assertEqual(ledger.priorityQueue.map(\.event), ["waiting"], "Waiting priority keys are read back")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(3601))
            assertEqual(ledger.normalLastHour, 0, "The hour rolls")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(-7200))
            assertEqual(ledger.normalLastHour, 1, "A clock set back clamps the later rows to now")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(-7200 + 3601))
            assertEqual(ledger.normalLastHour, 0, "So the window lasts at most its length from the change")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(2 * 86400))
            assertTrue(
                ledger.announced.isEmpty && ledger.priorityQueue.isEmpty, "A day later nothing is announced or waiting")
            try await db.recordNotification(
                PlannedBanner(lane: .normal, grouped: false, thread: "x", sound: false),
                at: now.addingTimeInterval(8 * 86400))
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(8 * 86400))
            assertTrue(ledger.lastStarred.isEmpty, "Rows older than a week are pruned")
            await db.close()
        } catch {
            assertTrue(false, "Notification delivery storage failed: \(error)")
        }

        // Settings › Notifications › Send Test Notification (#926): a random story with a photo, and a status line
        // that names the reason nothing showed.
        let plain = FeedArticle(
            title: "No photo", link: "https://example.com/plain", guid: "sample-plain", description: "Summary",
            pubDate: Date(), source: "Publisher")
        let photo = FeedArticle(
            title: "Photo", link: "https://example.com/photo", guid: "sample-photo", description: "Summary",
            pubDate: Date(), source: "Publisher", imageUrl: "https://example.com/photo.jpg")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<10 {
            assertEqual(
                NotificationService.sampleStory(from: [plain, photo, plain], using: &generator)?.id, photo.id,
                "The test banner prefers a story with a photo")
        }
        assertEqual(
            NotificationService.sampleStory(from: [plain], using: &generator)?.id, plain.id,
            "Without any photo, any story serves as the test banner")
        assertTrue(NotificationService.sampleStory(from: []) == nil, "No stories, no test banner")
        func status(
            _ outcome: NotificationService.PostOutcome, authorization: UNAuthorizationStatus = .authorized,
            alert: UNNotificationSetting = .enabled, style: UNAlertStyle = .banner,
            previews: UNShowPreviewsSetting = .always
        ) -> String {
            NotificationService.sampleStatus(
                outcome, authorization: authorization, alert: alert, style: style, previews: previews)
        }
        assertTrue(status(.halted).hasPrefix("Not shown:"), "A halted test names the mode setting")
        assertTrue(
            status(.failed(domain: "Other", code: 7)).contains("Other 7"),
            "A banner that cannot draw shows domain and code")
        assertTrue(
            status(.suppressed(.notAuthorized), authorization: .denied).contains("turned off"),
            "Denied permission is named")
        assertTrue(
            status(.suppressed(.notAuthorized), authorization: .notDetermined).contains("not asked"),
            "Permission not yet asked is named")
        assertTrue(status(.suppressed(.styleNone), style: .none).contains("None"), "Alert style None is named")
        assertTrue(
            status(.suppressed(.alertsOff), alert: .disabled).contains("alerts for News are off"), "Alerts off is named"
        )
        assertTrue(status(.suppressed(.focus)).contains("Focus"), "A Focus is named")
        assertTrue(status(.posted, previews: .never).contains("story hidden"), "Hidden previews are named")
        assertTrue(
            status(.posted, style: .alert).contains("until you close it"), "The Alerts style is named after a banner")
        assertEqual(status(.posted), "Shown.", "A plain success says so")
    }

    /// #1201: a pass plans its banners from the stories as triage saw them and posts minutes later. A story from a feed
    /// without images, or whose feed image is a logo, posts with the photo the page lookup recorded in the library,
    /// the way FeedManager wires `curated`; a story with a photo of its own keeps it.
    @MainActor
    static func testBannerTakesRecordedPhoto() async throws {
        print("  - Testing a banner posts the photo the page lookup recorded (#1201)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func story(_ id: String, image: String?) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Explosion at a refinery in Houston, dozens killed; urgent evacuation",
                link: "https://photo.invalid/\(id)", guid: id, description: "", pubDate: Date(),
                source: "Publisher \(id)", imageUrl: image)
        }
        let bare = story("bare", image: nil)
        let logo = story("branded", image: "https://photo.invalid/static/logo.png")
        let own = story("own", image: "https://photo.invalid/own/lead.jpg")
        _ = try await db.upsertArticles([bare, logo, own])
        for item in [bare, logo, own] {
            _ = try await db.recordStoryImage(item.id, imageURL: "https://cdn.invalid/\(item.id)/found.jpg")
        }
        actor Recorder {
            var images: [String: [URL]] = [:]
            func record(_ banner: StoryBanner) { images[banner.articleID ?? ""] = banner.imageURLs }
        }
        let recorder = Recorder()
        let service = NotificationService(post: { await recorder.record($0) }, spacing: .zero)
        for item in [bare, logo, own] {
            var delivery = NotificationDelivery(mode: .full)
            delivery.curated = { story in (try? await db.curateImages(in: [story]))?.first ?? story }
            await service.triageAndNotify(newArticles: [item], delivery: delivery)
        }
        let images = await recorder.images
        assertEqual(
            images[bare.id]?.first?.absoluteString, "https://cdn.invalid/bare/found.jpg",
            "A story its feed gave no image posts with the recorded photo")
        assertEqual(
            images[logo.id]?.first?.absoluteString, "https://cdn.invalid/branded/found.jpg",
            "A story whose feed image is a logo posts with the recorded photo")
        assertEqual(
            images[own.id]?.first?.absoluteString, own.imageUrl, "A story with a photo of its own keeps it")
        await db.close()
    }

    /// #790: a banner for a report outside any event records the report itself. When another outlet's report later
    /// clusters with it, the event counts as announced, so the new report posts no second banner on another thread.
    @MainActor
    static func testNotifyBeforeClustering() async throws {
        print("  - Testing a report notified before clustering announces its later event (#790)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func report(_ id: String, _ title: String, hoursAgo: Double, source: String) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title, link: "https://notify.invalid/\(id)", guid: id, description: "",
                pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source)
        }
        let first = report("n790-a", "Breaking: Mosul dam failure, emergency declared", hoursAgo: 2, source: "Wire One")
        let second = report(
            "n790-b", "Breaking: Mosul dam bursts, emergency declared", hoursAgo: 1, source: "Daily Two")
        _ = try await db.upsertArticles([first, second])

        let alone = NotificationService.plan(
            new: [(article: first, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(mode: .full, now: now, ledger: try await db.notificationLedger(now: now)))
        assertEqual(alone.banners.count, 1, "The report alone posts a banner")
        assertEqual(
            alone.banners.first?.announces, [first.id: EventFeedSummary.titleKey(first.title)],
            "A report outside any event is announced under its own ID")
        for banner in alone.banners { try await db.recordNotification(banner, at: now) }
        var ledger = try await db.notificationLedger(now: now.addingTimeInterval(60))
        assertTrue(
            NotificationService.plan(
                new: [(article: first, score: 0.9)], pending: [:],
                delivery: NotificationDelivery(mode: .full, now: now.addingTimeInterval(60), ledger: ledger)
            ).banners.isEmpty, "The announced report alone does not post again")

        let event = try await db.createEvent(memberArticleIDs: [first.id, second.id], at: now)
        let later = now.addingTimeInterval(600)
        ledger = try await db.notificationLedger(now: later)
        let announced = NotificationLedger.Announcement(leadKey: EventFeedSummary.titleKey(first.title), lane: .normal)
        assertEqual(
            ledger.announced, [event.id: announced, first.id: announced],
            "The report's announcement is copied to the event it joined, under the event's lead headline, and kept")
        let clustered = NotificationService.plan(
            new: [(article: second, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(
                mode: .full, events: [first.id: event.id, second.id: event.id], publishers: [event.id: 2],
                leadTitles: [event.id: first.title], now: later, ledger: ledger))
        assertTrue(clustered.banners.isEmpty, "The second outlet's report of the announced event posts no banner")

        // The report keeps its own row: separated into another event, it makes that event announced too.
        let third = report("n790-c", "Breaking: Mosul dam failure floods villages", hoursAgo: 0.5, source: "Post")
        _ = try await db.upsertArticles([third])
        _ = try await db.separateArticle(first.id, fromEvent: event.id)
        let moved = try await db.createEvent(memberArticleIDs: [first.id, third.id], at: later)
        ledger = try await db.notificationLedger(now: later.addingTimeInterval(60))
        assertEqual(
            ledger.announced[moved.id]?.lane, .normal, "The event the separated report joins inherits its announcement")
        let separated = NotificationService.plan(
            new: [(article: third, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(
                mode: .full, events: [first.id: moved.id, third.id: moved.id], publishers: [moved.id: 2],
                leadTitles: [moved.id: first.title], now: later.addingTimeInterval(60), ledger: ledger))
        assertTrue(separated.banners.isEmpty, "The separated report's new event posts no duplicate banner")
        await db.close()
    }

    /// Notification lanes through `FeedManager` (#665): the normal limit rolls across refreshes and a relaunch, delivery
    /// never removes a story, starring a feed brings up no backlog, and a starred burst is one banner.
    @MainActor
    static func testNotificationLanesAcrossRefreshes(fixtureRoot: URL) async throws {
        print("  - Testing notification lanes across refreshes and relaunch...")
        // Three full-weight signal words and six named places: each is breaking, and alone it is never priority.
        let headlines = [
            "Breaking: earthquake in Tokyo, Osaka, Kyoto, Nagoya, Sapporo and Kobe; emergency declared",
            "Breaking: explosion in Houston, Dallas, Austin, Denver, Phoenix and Tucson; emergency declared",
            "Breaking: attack in Paris, Lyon, Marseille, Nice, Lille and Bordeaux; emergency declared",
            "Breaking: crisis in Lagos, Abuja, Kano, Ibadan, Accra and Lome; emergency declared",
            "Breaking: mayors arrested in Madrid, Seville, Valencia, Bilbao, Malaga and Zaragoza; emergency session",
            "Breaking: dozens killed in Lima, Quito, Bogota, Caracas, Santiago and Montevideo; emergency declared",
            "Breaking: minister resigns in Cairo, Alexandria, Giza, Luxor, Aswan and Suez; emergency session",
            "Breaking: cars recalled in Berlin, Munich, Hamburg, Cologne, Frankfurt and Stuttgart; emergency checks",
            "Breaking: governors indicted in Sydney, Melbourne, Brisbane, Perth, Adelaide and Hobart; emergency sitting",
        ]
        let start = Date()
        func story(_ id: String, _ title: String, source: String) -> FeedArticle {
            FeedArticle(
                title: title, link: fixtureRoot.appendingPathComponent("lanes/\(id)").absoluteString, guid: id,
                description: "", pubDate: start, source: source)
        }
        let loud = headlines.indices.map { story("loud-\($0)", headlines[$0], source: "Wire \($0)") }
        let plainFeed = fixtureRoot.appendingPathComponent("lanes-plain").absoluteString
        let starredFeed = fixtureRoot.appendingPathComponent("lanes-starred").absoluteString
        let suite = testDefaultsSuite("test.notification.lanes")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = [plainFeed, starredFeed]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        struct Posted: Sendable {
            let title: String
            let body: String
            let thread: String
            let actions: Bool
        }
        actor Recorder {
            var posted: [Posted] = []
            func record(_ banner: StoryBanner) {
                posted.append(
                    Posted(title: banner.title, body: banner.body, thread: banner.thread, actions: banner.actions))
            }
        }
        let recorder = Recorder()
        let service = NotificationService(post: { await recorder.record($0) }, spacing: .zero)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-\(UUID().uuidString).sqlite3")
            .path
        defer { removeTemporaryLibrary(atPath: path) }
        var store = ArticleStore(database: DatabaseEngine(path: path), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        // A refresh without a clock reads the real one at the pass, as the app does, after its stories are stored. It
        // returns the titles of the stories its banners covered (#584).
        @discardableResult
        func refresh(plain: [FeedArticle] = [], starred: [FeedArticle] = [], at clock: Date? = nil) async -> Set<String>
        {
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in urls.map { ($0, $0 == starredFeed ? starred : plain, nil, nil) } },
                notifyBatch: { articles, delivery in
                    await service.triageAndNotify(newArticles: articles, delivery: delivery)
                }, dependencies: FeedManager.Dependencies(imageFinder: .unavailable, now: { clock ?? Date() }))
            await manager.fetchFeedsAsync()
            // The pass runs on after the refresh returns; this waits for its banners before reading them.
            _ = await manager.notificationPass?.value
            manager.stopBackgroundWork()
            return Set(store.articles.filter { manager.notifiedStoryIDs.contains($0.id) }.map(\.title))
        }

        // The normal limit rolls: five of six post, a refresh 30 minutes later after a relaunch posts none, and one 61
        // minutes after the first posts again.
        let firstNotified = await refresh(plain: Array(loud.prefix(6)), at: start)
        assertEqual(await recorder.posted.count, 5, "Five normal banners in the first hour")
        assertEqual(firstNotified.count, 5, "The five posted stories count as notified, the sixth does not")
        assertTrue(firstNotified.isSubset(of: Set(headlines.prefix(6))), "Only this refresh's stories are notified")
        await store.database.close()
        store = ArticleStore(database: DatabaseEngine(path: path), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        await refresh(plain: Array(loud[6...7]), at: start.addingTimeInterval(30 * 60))
        assertEqual(await recorder.posted.count, 5, "Thirty minutes later, after a relaunch, the hour is still full")
        await refresh(plain: [loud[8]], at: start.addingTimeInterval(61 * 60))
        assertEqual(await recorder.posted.count, 6, "Sixty-one minutes after the first banners, one posts again")
        let stored = Set(try await store.database.fetchArticles(limit: nil).map(\.title))
        assertTrue(Set(headlines).isSubset(of: stored), "Every story is stored, notified or not")
        assertTrue(
            Set(headlines).isSubset(of: Set(store.articles.map(\.title))), "Every story stays in the reader's feed")

        // Starring a feed brings up none of its backlog; its next new story notifies, and a burst 21 minutes later is
        // one grouped banner.
        let backlog = (0..<5).map {
            story("backlog-\($0)", "Starred column \($0) on garden design", source: "Starred Daily")
        }
        await refresh(starred: backlog)
        let before = await recorder.posted.count
        assertTrue(settings.setFeedStarred(starredFeed, true), "The feed is starred")
        await refresh(plain: [story("quiet", "Library extends opening hours", source: "Town Paper")])
        assertEqual(await recorder.posted.count, before, "Starring a feed posts nothing for its backlog")
        await refresh(
            starred: backlog + [story("fresh", "Starred column on winter bulbs", source: "Starred Daily")])
        let single = await recorder.posted.dropFirst(before)
        assertEqual(single.map(\.title), ["Starred Daily"], "The feed's first new story is one starred banner")
        assertEqual(
            single.map(\.actions), [true], "A starred story's banner has story actions")
        let burst = (0..<20).map { story("burst-\($0)", "Starred note \($0) about orchards", source: "Starred Daily") }
        let burstNotified = await refresh(starred: burst, at: Date().addingTimeInterval(21 * 60))
        assertEqual(burstNotified, Set(burst.map(\.title)), "A grouped banner's stories all count as notified")
        let grouped = await recorder.posted.dropFirst(before + 1)
        assertEqual(grouped.count, 1, "Twenty new starred stories are one banner: \(grouped.map(\.body))")
        assertEqual(grouped.first?.thread, "starred-\(starredFeed)", "The burst is threaded under the feed")
        assertTrue(
            grouped.first?.body.hasPrefix("20 new stories\n") == true,
            "The burst counts every story: \(grouped.first?.body ?? "")")
        assertEqual(grouped.first?.actions, false, "A grouped banner has no story actions")
        await store.database.close()
    }

    /// Cross-refresh dedupe through `FeedManager` (#545): the first refresh announces an event; a report that joins it
    /// in the next refresh posts no second banner; once the recorded lead headline differs, a new report notifies.
    @MainActor
    static func testNotificationDedupeAcrossRefreshes(fixtureRoot: URL) async throws {
        print("  - Testing notification dedupe across refreshes...")
        let now = Date()
        func report(_ id: String, _ title: String, hoursAgo: Double, source: String) -> FeedArticle {
            FeedArticle(
                title: title, link: fixtureRoot.appendingPathComponent("dedupe/\(id)").absoluteString, guid: id,
                description:
                    "The disaster agency AFAD said buildings collapsed in Malatya, Ankara and Istanbul after the earthquake struck eastern Turkey.",
                pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source)
        }
        // Three signal words and the named places make every report breaking, so only the dedupe keeps one quiet.
        let quake = [
            report(
                "d1", "Breaking: earthquake strikes Malatya in eastern Turkey, emergency declared", hoursAgo: 3,
                source: "Wire One"),
            report(
                "d2", "Breaking: Malatya earthquake, emergency declared as AFAD says buildings collapsed",
                hoursAgo: 2.5,
                source: "Daily Two"),
            report(
                "d3", "Breaking: rescuers search collapsed buildings after Malatya earthquake, emergency declared",
                hoursAgo: 2, source: "Herald Three"),
            report(
                "d4", "Breaking: eastern Turkey earthquake, emergency declared as buildings collapse in Malatya",
                hoursAgo: 1.5, source: "Courier Four"),
        ]
        let feeds = (1...4).map { fixtureRoot.appendingPathComponent("dedupe-feed-\($0)").absoluteString }
        let suite = testDefaultsSuite("test.notification.dedupe")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = feeds
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        actor Recorder {
            var threads: [String] = []
            func record(_ thread: String) { threads.append(thread) }
        }
        let recorder = Recorder()
        let service = NotificationService(
            post: { await recorder.record($0.thread) }, spacing: .zero)
        // Each refresh is a manager over the same library whose feeds carry the first `count` reports, one per feed.
        func refresh(_ count: Int) async {
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in
                    urls.map { url in
                        let index = feeds.firstIndex(of: url) ?? count
                        return (url, index < count ? [quake[index]] : [], nil, nil)
                    }
                },
                notifyBatch: { articles, delivery in
                    await service.triageAndNotify(newArticles: articles, delivery: delivery)
                }, dependencies: FeedManager.Dependencies(imageFinder: .unavailable))
            await manager.fetchFeedsAsync()
            _ = await manager.notificationPass?.value
            manager.stopBackgroundWork()
        }

        await refresh(2)
        let first = await recorder.threads
        assertEqual(first.count, 1, "Two reports of one new event are one banner: \(first)")
        let ids = store.articles.map(\.id)
        let event = try await store.database.eventIDs(forArticles: ids)
        assertEqual(Set(event.values).count, 1, "The first refresh groups both reports into one event: \(event)")

        await refresh(3)
        let joined = try await store.database.eventIDs(forArticles: store.articles.map(\.id))
        assertEqual(Set(joined.values).count, 1, "The third report joins the announced event: \(joined)")
        assertEqual(await recorder.threads, first, "A report joining an event announced today posts no second banner")

        guard let announced = joined.values.first else { return }
        try await store.database.recordNotification(
            PlannedBanner(
                lane: .normal, grouped: false, thread: announced, sound: false,
                announces: [announced: EventFeedSummary.titleKey("An earlier lead headline")]), at: Date())
        await refresh(4)
        assertEqual(
            await recorder.threads, first + [announced], "A new report notifies once the lead headline changed")
        await store.database.close()

        // A merge never makes an announced story new again: the absorbed event's announcement and waiting priority key
        // move to the event it joined, keyed to that event's lead headline, so its next report stays quiet.
        let merges = DatabaseEngine(path: ":memory:")
        try await merges.open()
        let lead = report("m1", "Dam bursts near Mosul as floodwater reaches villages", hoursAgo: 4, source: "Wire One")
        let fragment = report("m2", "Breaking: Mosul dam failure, emergency declared", hoursAgo: 3, source: "Daily Two")
        let waiting = report("m3", "Breaking: Mosul flood toll rises, emergency declared", hoursAgo: 2, source: "Post")
        let later = report("m4", "Breaking: Mosul evacuations widen, emergency declared", hoursAgo: 1, source: "Times")
        _ = try await merges.upsertArticles([lead, fragment, waiting, later])
        let survivor = try await merges.createEvent(memberArticleIDs: [lead.id]).id
        let absorbed = try await merges.createEvent(memberArticleIDs: [fragment.id]).id
        let queued = try await merges.createEvent(memberArticleIDs: [waiting.id]).id
        try await merges.recordNotification(
            PlannedBanner(
                lane: .priority, grouped: false, thread: absorbed, sound: true,
                announces: [absorbed: EventFeedSummary.titleKey(fragment.title)]), at: now)
        let stale = QueuedPriority(event: queued, title: waiting.title, score: 0.8, leadKey: "old", story: waiting.id)
        try await merges.queuePriority([stale], at: now)
        _ = try await merges.mergeEvents(absorbed, into: survivor)
        _ = try await merges.mergeEvents(queued, into: survivor)
        let ledger = try await merges.notificationLedger(now: now)
        let leadKey = EventFeedSummary.titleKey(lead.title)
        assertEqual(
            ledger.announced, [survivor: .init(leadKey: leadKey, lane: .priority)],
            "The survivor inherits the absorbed announcement and its lane, under its own lead headline")
        assertEqual(
            ledger.priorityQueue,
            [QueuedPriority(event: survivor, title: waiting.title, score: 0.8, leadKey: leadKey, story: waiting.id)],
            "A waiting priority key moves to the survivor with its story")
        let quiet = NotificationService.plan(
            new: [(article: later, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(
                mode: .full, events: [later.id: survivor], publishers: [survivor: 2],
                leadTitles: [survivor: lead.title], now: now, ledger: ledger))
        assertTrue(quiet.banners.isEmpty, "A breaking report of the merged event posts no second banner")
        await merges.close()
    }

    @MainActor
    static func testArticleStoreErrorResilience() async {
        print("  - Testing ArticleStore Error Resilience & Database Failures...")

        let db = DatabaseEngine(path: ":memory:")
        try? await db.open()
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()

        let article = FeedArticle(
            title: "Test Error Article", link: "https://example.com/error", guid: "test-err-guid", description: "Test",
            pubDate: Date(), source: "Test")
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/feed")

        // Force close the database to trigger failure scenarios
        await db.close()

        // 1. toggleSave returns false on failure (PR #18)
        let savedResult = await store.toggleSave(article: article)
        assertFalse(savedResult, "toggleSave should return false when database throws an error")

        // 2. markAsRead catches error and does not mutate in-memory read state (PR #19)
        await store.markAsRead(id: "test-err-guid", isRead: true)
        assertFalse(
            store.readArticleIDs.contains("test-err-guid"),
            "readArticleIDs should not contain ID when DB markRead fails")

        // 3. markAllAsRead catches error gracefully without crashing (PR #20)
        await store.markAllAsRead()
    }

    @MainActor
    static func testSystemErrorHardeningAndResilience() async {
        print("  - Testing System Error Hardening & Resilience across Coordinators and Views...")

        // 1. FeedManager.addFeed Boolean feedback
        let suite = testDefaultsSuite("test.error.feedmanager")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [], nil, nil) } },
            notifyBatch: { _, _ in })

        let validURL = "https://example.com/feed.xml"
        let addedFirst = manager.addFeed(url: validURL)
        assertTrue(addedFirst, "Adding a new valid feed returns true")
        let addedDuplicate = manager.addFeed(url: validURL)
        assertFalse(addedDuplicate, "Adding a duplicate feed returns false")
        let addedInvalid = manager.addFeed(url: "https://")
        assertFalse(addedInvalid, "Adding an invalid scheme-only URL returns false")
        let addedEmpty = manager.addFeed(url: "   ")
        assertFalse(addedEmpty, "Adding an empty/whitespace URL returns false")
        manager.stopBackgroundWork()

        // 2. MigrationCoordinator corrupt legacy data handling
        let migrationSuite = testDefaultsSuite("test.error.migration")
        let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
        defer { removeTestDefaults(migrationSuite) }
        migrationDefaults.set(Data("corrupted JSON content".utf8), forKey: "saved_articles")
        let migrationCoordinator = MigrationCoordinator(database: db, userDefaults: migrationDefaults)
        do {
            let stats = try await migrationCoordinator.migrateIfNeeded()
            assertEqual(stats.savedStories, 0, "Corrupted legacy saved stories are gracefully skipped")
        } catch {
            assertTrue(false, "migrateIfNeeded should not rethrow legacy JSON parsing failure: \(error)")
        }

        // 3. SentenceEmbedder corrupt file handling
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let corruptVocab = tempDir.appendingPathComponent("vocab.txt")
        try? "invalid vocab file".write(to: corruptVocab, atomically: true, encoding: .utf8)
        let corruptModel = tempDir.appendingPathComponent("minilm.mlmodelc")
        try? "invalid coreml model".write(to: corruptModel, atomically: true, encoding: .utf8)
        let embedder = SentenceEmbedder(modelURL: corruptModel, vocabURL: corruptVocab)
        let available = await embedder.isAvailable
        assertFalse(available, "SentenceEmbedder with corrupted files gracefully sets isAvailable to false")

        // 4. OverviewGenerationCoordinator graceful error handling when database closed
        let failingDb = DatabaseEngine(path: ":memory:")
        let failingStore = ArticleStore(database: failingDb, spotlightIndexer: MockSpotlightIndexer())
        let coordinator = OverviewGenerationCoordinator(
            store: failingStore, queue: EnrichmentQueue(store: failingStore))
        await failingDb.close()
        let result = await coordinator.requestOverview(
            eventID: "err-event", eventTitle: "Error Event", membershipVersion: 1,
            articles: [
                FeedArticle(
                    title: "Test", link: "https://example.com/item", guid: "g1",
                    description: "Desc", pubDate: Date(), source: "Src")
            ])
        assertTrue(result == nil, "requestOverview with failing database returns nil without crashing")
    }

    @MainActor
    static func testAppContainerWiring() async {
        print("  - Testing AppContainer wiring...")

        let suite = testDefaultsSuite("test.container")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        let feeds = FeedManager(settings: settings, store: store, schedulesRefresh: false)
        let reads = ReadManager(articleStore: store)
        let saved = SavedStoriesManager(articleStore: store)
        let container = AppContainer(
            appSettings: settings, articleStore: store, feedManager: feeds, readManager: reads, savedStories: saved)
        assertTrue(container.appSettings === settings, "Injected settings wired")
        assertTrue(container.articleStore === store, "Injected store wired")
        assertTrue(container.readManager === reads, "Injected read manager wired")
        assertTrue(container.savedStories === saved, "Injected saved manager wired")
    }

    @MainActor
    static func testReadManagerReconciliationCache() async throws {
        print("  - Testing ReadManager Reconciliation Cache...")
        // Saves and unsaves queue Spotlight updates; the test checks persistence, not the host's Spotlight service.
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let rm = ReadManager(articleStore: store)
        let rawId = "http://example.com/test-article-perf?utm_source=news&utm_medium=rss"
        await store.batchUpsert(articles: [
            FeedArticle(
                title: "Read", link: rawId, guid: ArticleIdentity.reconcileLegacyId(rawId), description: "Text",
                pubDate: Date(), source: "Test")
        ])
        let isReadInitial = rm.isRead(rawId)
        // Repeat query to verify cached resolution works idempotently
        assertEqual(rm.isRead(rawId), isReadInitial, "Cached resolution matches initial read state")
        rm.markAsRead(rawId)
        assertTrue(rm.isRead(rawId), "Marked as read should reflect in cached lookup")
        for _ in 0..<100 {
            if store.isRead(ArticleIdentity.reconcileLegacyId(rawId)) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assertTrue(store.isRead(ArticleIdentity.reconcileLegacyId(rawId)), "Read writes use the injected store")

        // Mark All as Read: one batch write, already-read stories untouched, the cache answers at once.
        let batch = ["batch-a", "batch-b", "batch-c"].map {
            FeedArticle(
                title: $0, link: "https://example.com/\($0)", guid: $0, description: "Text", pubDate: Date(),
                source: "Test")
        }
        await store.batchUpsert(articles: batch)
        rm.markAsRead(ids: batch.map(\.id) + [rawId])
        assertTrue(batch.allSatisfy { rm.isRead($0.id) }, "A batch marks every listed story read immediately")
        await rm.waitForPendingChanges()
        assertTrue(batch.allSatisfy { store.isRead($0.id) }, "The batch is persisted through the injected store")
        assertTrue(store.isRead(ArticleIdentity.reconcileLegacyId(rawId)), "Stories already read stay read")

        let article = FeedArticle(
            title: "Saved", link: "https://example.com/saved", guid: "isolated-save", description: "Text",
            pubDate: Date(), source: "Test")
        let saved = SavedStoriesManager(articleStore: store)
        saved.save(article)
        for _ in 0..<100 {
            if store.isSaved(article) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assertTrue(store.isSaved(article), "Save writes use the injected store")
        saved.remove(article)
        saved.remove(article)
        for _ in 0..<100 {
            if !store.isSaved(article) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assertFalse(store.isSaved(article), "Repeated removal cannot re-save an article")
        _ = await store.setSaved(article: article, isSaved: false)
        let persistedSaved = try await store.database.isSaved(articleId: article.id)
        assertFalse(persistedSaved, "Explicit unsave is idempotent in SQLite")
    }

    static func testMemoryLeakMitigationsAndErrorHandling() async throws {
        print("  - Testing Resource Leak Mitigations & Error Resilience...")

        // 1. DecodedImageCache bounds and clear
        await MainActor.run {
            DecodedImageCache.clear()
            assertEqual(DecodedImageCache.images.countLimit, 24, "The full-size cache bounds its image count")
            assertEqual(DecodedImageCache.cardImages.countLimit, 90, "The card cache bounds its image count")
            assertEqual(
                DecodedImageCache.images.totalCostLimit + DecodedImageCache.cardImages.totalCostLimit,
                192 * 1024 * 1024, "Card and full-size caches together keep the 192 MB ceiling")
        }

        // Test that clear() cancels pending tasks and prevents insertion
        let slowLoader: @Sendable (URL, Int) async throws -> CGImage = { _, _ in
            try await Task.sleep(for: .milliseconds(500))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        let testURL = URL(string: "https://example.com/slow_image_\(UUID().uuidString).jpg")!
        let loadTask = Task { @MainActor in
            _ = try? await DecodedImageCache.load(testURL, using: slowLoader)
        }
        try await Task.sleep(for: .milliseconds(30))
        await MainActor.run {
            DecodedImageCache.clear()
        }
        _ = await loadTask.value
        await MainActor.run {
            assertTrue(
                DecodedImageCache.images.object(forKey: testURL as NSURL) == nil,
                "DecodedImageCache must not contain image from cancelled load")
        }

        // Cancelling the only waiter stops the shared download; a clear() does not let a finished old load
        // remove a newer load's entry.
        final class LoaderProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var startedCount = 0
            private var cancelledCount = 0
            var started: Int { lock.withLock { startedCount } }
            var cancelled: Int { lock.withLock { cancelledCount } }
            func recordStart() { lock.withLock { startedCount += 1 } }
            func recordCancel() { lock.withLock { cancelledCount += 1 } }
            var loader: @Sendable (URL, Int) async throws -> CGImage {
                { [self] _, _ in
                    recordStart()
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        recordCancel()
                        throw error
                    }
                    throw CancellationError()
                }
            }
        }
        let probe = LoaderProbe()
        let cancelURL = URL(string: "https://example.com/cancel_\(UUID().uuidString).jpg")!
        let first = Task { @MainActor in _ = try? await DecodedImageCache.load(cancelURL, using: probe.loader) }
        let second = Task { @MainActor in _ = try? await DecodedImageCache.load(cancelURL, using: probe.loader) }
        await eventually("Both waiters join the shared download") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: cancelURL)?.waiters == 2 }
        }
        first.cancel()
        await eventually("The first cancellation is recorded") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: cancelURL)?.cancelledWaiters == 1 }
        }
        assertEqual(probe.cancelled, 0, "A shared download keeps running while a waiter is left")
        second.cancel()
        _ = await first.value
        _ = await second.value
        assertEqual(probe.started, 1, "Two waiters on one URL share one download")
        assertEqual(probe.cancelled, 1, "The shared download stops once its last waiter cancels")
        await MainActor.run {
            assertTrue(
                DecodedImageCache.sharedLoad(for: cancelURL) == nil, "A cancelled shared download leaves the table")
        }

        // A finished old load must not delete the entry of the load that replaced it after a clear().
        let oldProbe = LoaderProbe()
        let newProbe = LoaderProbe()
        let thirdProbe = LoaderProbe()
        let replaceURL = URL(string: "https://example.com/replace_\(UUID().uuidString).jpg")!
        let oldCaller = Task { @MainActor in _ = try? await DecodedImageCache.load(replaceURL, using: oldProbe.loader) }
        await eventually("The old load registers") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL)?.waiters == 1 }
        }
        await MainActor.run { DecodedImageCache.clear() }
        let newCaller = Task { @MainActor in _ = try? await DecodedImageCache.load(replaceURL, using: newProbe.loader) }
        await eventually("The replacement registers") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL)?.waiters == 1 }
        }
        _ = await oldCaller.value  // the old load finishes, cancelled by clear()
        let replacement = await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL) }
        assertTrue(replacement != nil, "A finished old load leaves the replacement registered")
        let thirdCaller = Task { @MainActor in
            _ = try? await DecodedImageCache.load(replaceURL, using: thirdProbe.loader)
        }
        await eventually("A third caller joins the replacement") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL)?.waiters == 2 }
        }
        await MainActor.run {
            assertTrue(
                DecodedImageCache.sharedLoad(for: replaceURL) === replacement, "The third caller shares the replacement"
            )
        }
        assertEqual(thirdProbe.started, 0, "The third caller starts no download of its own")
        newCaller.cancel()
        thirdCaller.cancel()
        _ = await newCaller.value
        _ = await thirdCaller.value
        assertEqual(newProbe.started, 1, "The replacement downloads once")

        await MainActor.run {
            let oldLoad = DecodedImageCache.SharedLoad(task: Task { throw CancellationError() })
            oldLoad.join()
            oldLoad.join()
            assertFalse(oldLoad.leave(), "One of two waiters cancelling keeps the download")
            assertTrue(oldLoad.leave(), "The last waiter cancelling stops the download")
        }

        // 2. DatabaseEngine directory creation on custom path & deinit safety
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news_test_dir_\(UUID().uuidString)")
        let nestedDBPath = tempDir.appendingPathComponent("nested/deep/test.sqlite3").path
        do {
            let engine = DatabaseEngine(path: nestedDBPath)
            try await engine.open()
            assertTrue(
                FileManager.default.fileExists(atPath: nestedDBPath),
                "open() must create parent directories if missing")
            await engine.close()
        }
        try? FileManager.default.removeItem(at: tempDir)

        // A fetch of nothing, long after startup, returns nothing and does not trip over the cooldown pruning.
        let clock = TestClock(Date())
        let fetcher = FeedFetcher(now: { clock.now })
        clock.advance(by: 86400)
        assertEqual(await fetcher.fetchAllFeeds(urls: []).count, 0, "Fetching no feeds returns no results")
    }

    // MARK: - Epic N (#559, #560, #561) System Integration Unit Tests

    @MainActor
    static func testNotificationActionsAndRouting() async {
        print("  - Testing Notification actions and routing (#560)...")
        let category = NotificationActionIdentifier.makeCategory()
        assertEqual(category.identifier, "ARTICLE_ACTIONS", "Category identifier is ARTICLE_ACTIONS (#560)")
        assertEqual(category.actions.map(\.identifier), ["SAVE_ACTION", "MARK_READ_ACTION", "OPEN_ACTION"])
        assertEqual(category.actions.map(\.title), ["Save", "Mark as Read", "Open"])
        assertTrue(category.actions[2].options.contains(.foreground), "Open action brings app to foreground")

        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let readManager = ReadManager(articleStore: store)
        let savedManager = SavedStoriesManager(articleStore: store)

        let article = FeedArticle(
            storedID: "notif-story-1",
            title: "Mars Sample Return Update",
            link: "https://example.com/mars-1",
            guid: "notif-story-1",
            description: "Orbiter rendezvous confirmed.",
            pubDate: Date(),
            source: "Space Wire"
        )
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/rss")

        // 1. SAVE_ACTION saves the story
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.save,
            userInfo: ["articleID": article.id, "articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await savedManager.waitForPendingChanges()
        assertTrue(savedManager.isSaved(article), "SAVE_ACTION routes to SavedStoriesManager (#560)")

        // 2. MARK_READ_ACTION marks the story as read
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.markRead,
            userInfo: ["articleID": article.id, "articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await readManager.waitForPendingChanges()
        assertTrue(readManager.isRead(article.id), "MARK_READ_ACTION routes to ReadManager (#560)")

        // 3. OPEN_ACTION activates app and sets pendingNavigation
        var activatedBeforeNavigation = false
        var activated = false
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.open,
            userInfo: ["articleID": article.id, "articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {
                activated = true
                if store.pendingNavigation == nil {
                    activatedBeforeNavigation = true
                }
            }
        )
        assertTrue(activated, "OPEN_ACTION activates the application (#560)")
        assertTrue(activatedBeforeNavigation, "OPEN_ACTION activates app before pendingNavigation is set")
        assertEqual(store.pendingNavigation?.articleID, article.id, "OPEN_ACTION sets pendingNavigation articleID")
        assertEqual(store.pendingNavigation?.link, article.link, "OPEN_ACTION sets pendingNavigation link")

        // 4. Fallback by articleLink when articleID is missing
        store.pendingNavigation = nil
        await NotificationActionRouter.route(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        assertEqual(store.pendingNavigation?.link, article.link, "Default action falls back to articleLink")

        // 5. Missing userInfo is ignored safely
        store.pendingNavigation = nil
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.open,
            userInfo: [:],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        assertTrue(store.pendingNavigation == nil, "Empty userInfo is ignored safely")

        // 6. Save action on a pruned story does not insert placeholder (#890)
        let prunedID = "pruned-story-id"
        let savedCountBefore = savedManager.savedArticles.count
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.save,
            userInfo: ["articleID": prunedID, "articleLink": "https://example.com/pruned"],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await savedManager.waitForPendingChanges()
        assertEqual(
            savedManager.savedArticles.count, savedCountBefore,
            "Pruned story is not saved as a placeholder (#890)")
        assertEqual(
            store.operationError, "This story is no longer available in your archive.",
            "Missing story reports clear error message (#890)")

        // 7. Save action on storage failure reports load failure rather than pruned story
        let errorDB = DatabaseEngine(path: ":memory:")
        let errorStore = ArticleStore(database: errorDB, spotlightIndexer: MockSpotlightIndexer())
        await errorStore.initialize()
        await errorStore.waitForStartup()
        await errorDB.close()
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.save,
            userInfo: ["articleID": "error-id", "articleLink": "https://example.com/error"],
            articleStore: errorStore,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        assertEqual(
            errorStore.operationError, "The notification story could not be loaded. Please try again.",
            "Storage lookup failure is distinguished from a pruned story")

        // 8. Mark as read on a deleted or pruned story returns quietly without error (#1144)
        store.operationError = nil
        let deletedID = "deleted-story-id"
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.markRead,
            userInfo: ["articleID": deletedID, "articleLink": "https://example.com/deleted"],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await readManager.waitForPendingChanges()
        assertFalse(readManager.isRead(deletedID), "Pruned story is not marked as read")
        assertTrue(store.operationError == nil, "Mark as read on a deleted story raises no operationError (#1144)")
        await db.close()
    }

    /// #1144: Mark as Read on a banner for a deleted story returns quietly without operationError.
    @MainActor
    static func testMarkReadPrunedStoryBannerRaisesNoOperationError() async {
        print("  - Testing Mark as Read on a banner for a deleted story raises no error (#1144)...")
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let readManager = ReadManager(articleStore: store)
        let savedManager = SavedStoriesManager(articleStore: store)

        store.operationError = nil
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.markRead,
            userInfo: ["articleID": "nonexistent-id", "articleLink": "https://example.com/nonexistent"],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await readManager.waitForPendingChanges()
        assertFalse(readManager.isRead("nonexistent-id"), "Nonexistent story is not marked as read")
        assertTrue(store.operationError == nil, "Mark as read for an ID with no row raises no operationError (#1144)")
        await db.close()
    }

}
