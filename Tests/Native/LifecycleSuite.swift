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
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Native port of the `LifecycleTests` atom (#1070): the same 41 tests, in the runner's order, with each
/// `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of NativeExpectations.swift and each
/// force unwrap in a throwing scope into `#require` (the runner log is invisible to Swift Testing), so a failure is
/// recorded and later tests still run. Settings, audit and refresh regressions, the enrichment queue, distribution
/// integrity, the update checker, notification triage, shutdown, sleep and wake, and retention live in this file;
/// notification delivery, banners and their photos, store resilience, container wiring, read reconciliation, image
/// memory and notification actions in LifecycleSuite+Notifications.swift. `FeedDeliveryGate`, `RefreshCalls` and the
/// other shared doubles stay in the runner files and are reached through `NewsTests`. The runner keeps its copy until
/// CI shows parity.
extension NativeSuites {
    @Suite(.tags(.lifecycle, .integration)) struct LifecycleSuite {
        @Test @MainActor func appSettingsDecoupling() async { await Self.testAppSettingsDecoupling() }
        @Test @MainActor func auditPersistenceAndRoutingRegressions() async throws {
            try await Self.testAuditPersistenceAndRoutingRegressions(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test @MainActor func auditRefreshRegressions() async throws {
            try await Self.testAuditRefreshRegressions(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test @MainActor func refreshEndsAtCollection() async throws { try await Self.testRefreshEndsAtCollection() }
        @Test @MainActor func productionFollowupRegressions() async throws {
            try await Self.testProductionFollowupRegressions()
        }
        @Test @MainActor func offlineCacheAndResilience() async { await Self.testOfflineCacheAndResilience() }
        @Test func enrichmentQueueSchedulingAndPromotion() async {
            await Self.testEnrichmentQueueSchedulingAndPromotion()
        }
        @Test func enrichmentQueueCancelledJobsNotRetained() async {
            await Self.testEnrichmentQueueCancelledJobsNotRetained()
        }
        @Test func distributionAndEntitlementsIntegrity() async {
            await Self.testDistributionAndEntitlementsIntegrity()
        }
        @Test func strictSemVerAndReleaseSecurity() async { await Self.testStrictSemVerAndReleaseSecurity() }
        @Test @MainActor func updateCheckerObservation() async { await Self.testUpdateCheckerObservation() }
        @Test @MainActor func updateCheckerThrottleWithClock() async { await Self.testUpdateCheckerThrottleWithClock() }
        @Test @MainActor func updateCheckerFailureBackoff() async { await Self.testUpdateCheckerFailureBackoff() }
        @Test @MainActor func updateCheckerVersionComparisonAndErrors() async {
            await Self.testUpdateCheckerVersionComparisonAndErrors()
        }
        @Test @MainActor func updateCheckerAdversarialEdgeCases() async {
            await Self.testUpdateCheckerAdversarialEdgeCases()
        }
        @Test @MainActor func notificationActionsAndRouting() async { await Self.testNotificationActionsAndRouting() }
        @Test @MainActor func markReadPrunedStoryBannerRaisesNoOperationError() async {
            await Self.testMarkReadPrunedStoryBannerRaisesNoOperationError()
        }
        @Test @MainActor func notificationModeTriageAndGrammar() async {
            await Self.testNotificationModeTriageAndGrammar()
        }
        @Test @MainActor func feedRemovalAndShutdown() async throws { try await Self.testFeedRemovalAndShutdown() }
        @Test @MainActor func sleepAndWakeRefresh() async throws { try await Self.testSleepAndWakeRefresh() }
        @Test @MainActor func retentionPruneAfterRefresh() async throws {
            try await Self.testRetentionPruneAfterRefresh()
        }
        @Test @MainActor func cancelledRefreshCarriesNotifications() async throws {
            try await Self.testCancelledRefreshCarriesNotifications()
        }
        @Test func undatedStoriesInPublicationWindow() async throws {
            try await Self.testUndatedStoriesInPublicationWindow()
        }
        @Test @MainActor func appSettingsIsolationAndURLNormalization() async {
            await Self.testAppSettingsIsolationAndURLNormalization()
        }
        @Test func notificationServiceErrorLogging() async { await Self.testNotificationServiceErrorLogging() }
        @Test @MainActor func settingsOPMLImportStatus() async { await Self.testSettingsOPMLImportStatus() }
        @Test @MainActor func notificationDedupeAcrossRefreshes() async throws {
            try await Self.testNotificationDedupeAcrossRefreshes(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test @MainActor func notificationLanesAcrossRefreshes() async throws {
            try await Self.testNotificationLanesAcrossRefreshes(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test @MainActor func notifyBeforeClustering() async throws { try await Self.testNotifyBeforeClustering() }
        @Test @MainActor func bannerTakesRecordedPhoto() async throws { try await Self.testBannerTakesRecordedPhoto() }
        @Test @MainActor func firstBannerWaitsForPageImage() async throws {
            try await Self.testFirstBannerWaitsForPageImage()
        }
        @Test @MainActor func bannerPriorityAcrossLookupReplacement() async throws {
            try await Self.testBannerPriorityAcrossLookupReplacement()
        }
        @Test func bannerImageWaitTimeoutAndCancellation() async {
            await Self.testBannerImageWaitTimeoutAndCancellation()
        }
        @Test func priorityImageLookupSurvivesCancellation() async throws {
            try await Self.testPriorityImageLookupSurvivesCancellation()
        }
        @Test @MainActor func imageLookupDatabaseFailureDoesNotSpin() async throws {
            try await Self.testImageLookupDatabaseFailureDoesNotSpin()
        }
        @Test func firstIndividualBannerAfterGroupedWaitsForPhoto() async {
            await Self.testFirstIndividualBannerAfterGroupedWaitsForPhoto()
        }
        @Test @MainActor func articleStoreErrorResilience() async { await Self.testArticleStoreErrorResilience() }
        @Test @MainActor func systemErrorHardeningAndResilience() async {
            await Self.testSystemErrorHardeningAndResilience()
        }
        @Test @MainActor func appContainerWiring() async { await Self.testAppContainerWiring() }
        @Test @MainActor func readManagerReconciliationCache() async throws {
            try await Self.testReadManagerReconciliationCache()
        }
        @Test func memoryLeakMitigationsAndErrorHandling() async throws {
            try await Self.testMemoryLeakMitigationsAndErrorHandling()
        }
    }
}

extension NativeSuites.LifecycleSuite {
    /// `NewsTests.eventually`, recording its timeout through Swift Testing instead of the runner's failure log.
    static func eventually(
        _ message: String, timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                expectTrue(false, message)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
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
        expectTrue(store.migrationCoordinator == nil, "Injected stores must not migrate real user defaults or caches")
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
        expectTrue(try await db.isSaved(articleId: article.id), "Latest rapid save intent persists")
        expectTrue(try await db.getReadArticleIDs().contains(article.id), "Latest rapid read intent persists")
        let analysis = ArticleAnalysis(
            summary: "New summary", keyPoints: ["Finding"], entities: [], category: "Science", sentiment: nil,
            modelIdentifier: "test", analysisVersion: 2)
        await store.saveArticleAnalysis(analysis, for: article.id)
        expectEqual(store.savedArticles.first?.aiSummary, "New summary", "Saved snapshot receives new analysis")
        await store.setSaved(article: article, isSaved: false)
        var connection: OpaquePointer?
        expectEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated failure-injection database")
        defer { sqlite3_close(connection) }
        expectEqual(
            sqlite3_exec(
                connection,
                "CREATE TRIGGER fail_cache BEFORE DELETE ON article_enrichment BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;",
                nil, nil, nil), SQLITE_OK, "Install rollback regression trigger")
        do {
            try await store.clearArticleCache()
            expectTrue(false, "Cache failures must reach the caller")
        } catch {
            // Failure is expected: the preceding assertion rejects an unexpected success.
        }
        let restored = try await db.fetchArticles(limit: 10)
        expectEqual(
            restored.first?.fullContent, "Preserve this body", "Failed cleanup rolls back the preceding content update")
        expectEqual(
            sqlite3_exec(connection, "DROP TRIGGER fail_cache;", nil, nil, nil), SQLITE_OK,
            "Remove isolated failure trigger")
        try await store.clearAllDatabaseCache()
        expectTrue(try await db.getReadArticleIDs().contains(article.id), "All-cache cleanup preserves read history")
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
        expectTrue(
            history.contains(where: { $0.id == article.id }), "History queries include stories beyond the recent 500")
        let found = try await db.searchArticles(query: "Archived", limit: 200)
        expectEqual(found.first?.id, article.id, "Search reaches archived stories")
        expectEqual(
            try await db.searchArticles(query: "Archiv", limit: 200).first?.id, article.id,
            "FTS prefix search matches unfinished words")
        try await db.markRead(articleId: article.id, isRead: false)
        try await db.upsertArticles([article], feedUrl: "https://example.com/second-rss")
        try await db.markAllRead(feedUrl: "https://example.com/rss")
        expectTrue(
            try await db.getReadArticleIDs().contains(article.id),
            "Duplicate ingestion preserves original feed provenance")
        try await db.markRead(articleId: article.id, isRead: false)
        try await db.markAllRead(feedUrl: "https://example.com/second-rss")
        expectTrue(
            try await db.getReadArticleIDs().contains(article.id), "Shared stories belong to every originating feed")
        let firstPage = try await db.fetchArticles(limit: 200)
        let secondPage = try await db.fetchArticles(
            limit: 200, options: ArticleFetchOptions(after: ArticleQueryCursor(try #require(firstPage.last))))
        let thirdPage = try await db.fetchArticles(
            limit: 200, options: ArticleFetchOptions(after: ArticleQueryCursor(try #require(secondPage.last))))
        expectEqual(
            Set((firstPage + secondPage + thirdPage).map(\.id)).count, 511,
            "Keyset pages include all stories without duplicates at tied dates")
        let searchPage = try await db.searchArticles(query: "Recent", limit: 200)
        let searchNext = try await db.searchArticles(
            query: "Recent", limit: 400, after: ArticleQueryCursor(try #require(searchPage.last)))
        expectEqual(
            Set((searchPage + searchNext).map(\.id)).count, 510, "FTS rank cursor handles tied ranks without omissions")
        await db.close()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = NewsTests.mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        // The runner has no Info.plist, so its checker falls back to 0.0.0; xctest's bundle reports 16.0, which is not
        // a SemVer triple and would refuse every release. Pin the runner's version.
        let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "0.0.0")
        checker.updateAvailable = true
        checker.verifiedReleaseURL = URL(string: "https://github.com/marspater/NewsApp-macOS/releases/latest")
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await checker.checkForUpdates(userInitiated: true)
        expectFalse(checker.updateAvailable, "Failed update checks clear stale availability")
        expectTrue(checker.verifiedReleaseURL == nil, "Failed update checks clear stale release links")
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        await checker.checkForUpdates(userInitiated: true)
        expectEqual(
            checker.statusMessage, "No published release is available to compare.",
            "Missing releases are not reported as up to date")

        let expectedUserAgent = "NewsApp/\(checker.currentAppVersion)"
        MockURLProtocol.requestHandler = { request in
            expectEqual(request.url?.host, "api.github.com", "Updates use the GitHub API")
            expectEqual(
                request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json",
                "Protected update requests preserve JSON negotiation")
            expectEqual(
                request.value(forHTTPHeaderField: "User-Agent"), expectedUserAgent,
                "Protected update requests preserve the app user agent")
            expectEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, "Updates do not replay cached responses")
            expectEqual(request.timeoutInterval, 10, "Update requests retain their timeout")
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
        expectTrue(checker.updateAvailable, "A valid newer release is offered through the protected client")
        expectEqual(checker.latestVersionString, "v999.0.0", "New release version is retained")
        expectEqual(checker.releaseNotes, "Release notes", "New release notes are retained")
        expectTrue(checker.verifiedReleaseURL != nil, "A trusted release link is retained")
        MockURLProtocol.requestHandler = { _ in
            expectTrue(false, "Automatic checks within 72 hours must not make another request")
            throw URLError(.cancelled)
        }
        await checker.checkForUpdates()
        expectTrue(checker.updateAvailable, "Throttling preserves the last successful result")

        MockURLProtocol.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.3)
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let running = Task { await checker.checkForUpdates(userInitiated: true) }
        while !checker.isChecking { await Task.yield() }
        await checker.checkForUpdates(userInitiated: true)
        expectEqual(
            checker.statusMessage, "Update check failed (HTTP 503)",
            "A manual check during a running one returns with its result, not the interim state")
        await running.value
        expectEqual(
            checker.statusMessage, "Update check failed (HTTP 503)",
            "Protected client HTTP failures retain their status")
        expectFalse(checker.updateAvailable, "HTTP failures clear stale availability")
        expectTrue(checker.verifiedReleaseURL == nil, "HTTP failures clear stale release links")

        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Content-Length": "1048577"])!, Data()
            )
        }
        await checker.checkForUpdates(userInitiated: true)
        expectEqual(checker.statusMessage, "Unable to check for updates", "Oversized update responses are rejected")
        expectFalse(checker.updateAvailable, "Oversized responses cannot offer an update")

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
        expectEqual(checker.statusMessage, "Received untrusted release URL", "Untrusted release links are rejected")
        expectFalse(checker.updateAvailable, "Untrusted release links cannot offer an update")
        expectTrue(checker.verifiedReleaseURL == nil, "Untrusted release links are never retained")
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
        expectTrue(rejected.failed, "Settings rejects malformed OPML rather than reporting no additions")
        expectTrue(rejected.message.contains("could not be imported"), "Settings shows the import error")
        expectTrue(store.operationError != nil, "Malformed OPML retains the operation error")

        store.operationError = nil
        let empty = Data("<opml><body></body></opml>".utf8)
        let noChanges = SettingsView.opmlImportStatus(for: empty, using: manager)
        expectFalse(noChanges.failed, "A valid empty OPML import is not an error")
        expectEqual(noChanges.message, "No new feeds imported", "Valid OPML with no additions reports no changes")
    }

    @MainActor
    static func testAppSettingsDecoupling() async {
        print("  - Testing AppSettings isolation and persistence...")

        let settings = AppSettings()
        let testFeed = "https://example.com/unique-test-feed.xml"

        _ = settings.addFeed(url: testFeed)
        expectTrue(settings.feedURLs.contains(testFeed), "AppSettings should add feed URL")

        settings.removeFeed(url: testFeed)
        expectFalse(settings.feedURLs.contains(testFeed), "AppSettings should remove feed URL")

        settings.setFetchInterval(minutes: 30)
        expectEqual(settings.fetchIntervalMinutes, 30.0, "AppSettings should update fetch interval")

        settings.setNotificationsEnabled(false)
        expectFalse(settings.notificationsEnabled, "AppSettings should update notifications toggle")
        settings.setNotificationsEnabled(true)

        settings.setAllowInsecureHTTP(true)
        expectTrue(settings.allowInsecureHTTP, "AppSettings should update allowInsecureHTTP")
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
        expectEqual(store.pendingNavigation, pending, "Initialization retains requests received before the UI mounts")
        expectEqual(
            try await db.upsertArticles([original, original]), Set([original.id]),
            "Duplicate batch rows count as one insertion")
        try await db.markRead(articleId: original.id, isRead: true)
        try await db.setSaved(articleId: original.id, isSaved: true)
        let corrected = FeedArticle(
            title: original.title, link: fixtureRoot.appendingPathComponent("corrected").absoluteString,
            guid: original.guid,
            description: original.description, pubDate: Date(timeIntervalSince1970: 200), source: original.source)
        expectTrue(
            try await db.upsertArticles([corrected]).isEmpty, "Corrected GUID metadata is an update, not a new story")
        let restored = try #require(try await db.fetchArticles(id: original.id).first)
        expectEqual(restored.link, corrected.link, "Corrected URL is persisted")
        expectEqual(restored.pubDate, corrected.pubDate, "Corrected publication date is persisted")
        expectTrue(try await db.isRead(articleId: original.id), "Metadata correction preserves reading history")
        expectTrue(try await db.isSaved(articleId: original.id), "Metadata correction preserves saved state")
        let incomplete = FeedArticle(
            title: original.title, link: "javascript:broken", guid: original.guid,
            description: original.description, pubDate: DateParser.unknownDate, source: original.source)
        try await db.upsertArticles([incomplete])
        let retained = try #require(try await db.fetchArticles(id: original.id).first)
        expectEqual(retained.link, corrected.link, "Malformed incoming URL cannot erase a working URL")
        expectEqual(retained.pubDate, corrected.pubDate, "Unknown incoming date cannot erase a known publication date")
        let archive = (0..<501).map { index in
            FeedArticle(
                title: "Recent \(index)", link: "https://example.com/recent/\(index)", guid: "recent-\(index)",
                description: "Preview", pubDate: Date(timeIntervalSince1970: Double(1000 + index)), source: "Publisher")
        }
        try await db.upsertArticles(archive)
        await store.refreshState()
        expectFalse(
            store.articles.contains { $0.id == original.id }, "Notification fixture lies outside the 500-story snapshot"
        )
        expectEqual(
            try await store.articleForNavigation(pending)?.id, original.id,
            "Stable ID routes old notifications after URL corrections")
        let legacyRequest = ArticleStore.NavigationRequest(articleID: nil, link: corrected.link + "?utm_source=rss")
        expectEqual(
            try await store.articleForNavigation(legacyRequest)?.id, original.id,
            "Old link-only notifications resolve normalized URLs")
        let saves = SavedStoriesManager(articleStore: store)
        let alias = FeedArticle(
            title: "Alias", link: corrected.link + "?utm_source=alias", guid: "different-guid",
            description: "Preview", pubDate: corrected.pubDate, source: "Other publisher")
        expectTrue(saves.isSaved(alias), "URL-equivalent feed records share visible bookmark state")
        saves.remove(alias)
        await saves.waitForPendingChanges()
        expectFalse(try await db.isSaved(articleId: original.id), "Removing alias unsaves the actual saved database ID")
        expectFalse(saves.isSaved(alias), "Alias bookmark does not bounce back after reconciliation")
        saves.save(corrected)
        saves.remove(alias)
        saves.save(alias)
        await saves.waitForPendingChanges()
        expectTrue(try await db.isSaved(articleId: original.id), "Latest alias save applies to the existing document")
        expectEqual(
            try await db.fetchArticles(id: alias.id).first?.id, original.id,
            "Alias save resolves the original document without a new primary key")
        expectEqual(
            try await db.fetchArticles(options: ArticleFetchOptions(canonicalURL: corrected.link)).count, 1,
            "Rapid save changes preserve one URL-equivalent document")
        let emptyLink = FeedArticle(
            title: "No link", link: "", guid: "empty-one", description: "", pubDate: .distantPast, source: "Publisher")
        let otherEmptyLink = FeedArticle(
            title: "Different story", link: "", guid: "empty-two", description: "", pubDate: .distantPast,
            source: "Publisher")
        saves.save(emptyLink)
        expectFalse(saves.isSaved(otherEmptyLink), "Missing URLs do not alias unrelated stories")
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
            expectFalse(saves.isSaved(second), "Generic or invalid links do not alias separate bookmarks")
            saves.save(second)
            await saves.waitForPendingChanges()
            expectTrue(try await db.isSaved(articleId: first.id), "First bookmark persists independently")
            expectTrue(try await db.isSaved(articleId: second.id), "Second bookmark persists independently")
            let restoredSaves = SavedStoriesManager(articleStore: store)
            restoredSaves.remove(first)
            await restoredSaves.waitForPendingChanges()
            expectFalse(try await db.isSaved(articleId: first.id), "Selected bookmark is removed")
            expectTrue(
                restoredSaves.isSaved(second), "Removing one homepage story keeps the other saved in the restored UI")
            expectTrue(
                try await db.isSaved(articleId: second.id),
                "Removing one homepage story keeps the other saved in SQLite")
        }
        await db.close()
        do {
            _ = try await store.fetchArticles()
            expectTrue(false, "Storage read failure must propagate rather than return an empty library")
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
        let freshID = try #require(ArticleIdentity.scopedGUID(fresh.guid, feedURL: settings.feedURLs[0]))
        expectTrue(
            manager.articles.contains { $0.id == freshID }, "Notified undated story remains in the visible snapshot")
        expectEqual(notified, [freshID], "Only committed new IDs notify once, across duplicate rows and feeds")
        await manager.fetchFeedsAsync()
        expectEqual(notified, [freshID], "Repeat refresh does not re-notify stored stories")
        manager.stopBackgroundWork()
        var connection: OpaquePointer?
        expectEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated refresh failure fixture")
        defer { sqlite3_close(connection) }
        expectEqual(
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
        expectEqual(notified, [freshID], "Failed ingestion cannot send new-story notifications")
        expectFalse(
            failureManager.articles.contains { $0.id == failed.id },
            "Failed ingestion cannot replace the library with parsed data")
        // Drain the startup cache read before forcing a read failure.
        _ = try await store.fetchArticles()
        let snapshot = failureManager.articles
        await db.close()
        await failureManager.fetchFeedsAsync()
        await failureManager.notificationPass?.value
        expectEqual(failureManager.articles, snapshot, "Refresh read errors retain the visible library")
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
        let counter = NewsTests.TestCounter()
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
        expectFalse(manager.isAnyFeedLoading, "The spinner ends when collection ends, not when triage ends")
        expectEqual(manager.articles.count, 1, "Collected articles are published while triage is still running")
        expectEqual(manager.feedStatuses[feed], .idle, "The feed reports a finished refresh")
        let second = Task { await manager.fetchFeedsAsync() }  // Cmd-R during triage
        await eventually("A refresh requested during triage collects again") { await counter.value == 2 }
        await eventually("Cmd-R publishes new articles immediately") { manager.articles.count == 2 }
        expectEqual(await gate.arrivals, 1, "Its notification pass waits for the one in progress (#665)")
        await gate.open()
        await first.value
        await second.value
        await manager.notificationPass?.value
        expectEqual(await gate.arrivals, 2, "Then its notification pass runs")
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
            return expectTrue(false, "The refreshed article is stored")
        }
        expectEqual(await queue.state(for: storedID), nil, "Energy saving schedules no classification")
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
        expectTrue(size >= 0, "Cache directory byte calculation should succeed")

        CacheManager.shared.clearWebCache()
        let sizeAfter = CacheManager.shared.calculateTotalCacheSize()
        expectTrue(sizeAfter >= 0, "Cache clear should succeed non-destructively")

        // Test Clear All Caches clears DecodedImageCache as well as database and web caches (#media-cache-leak)
        let dummyImageURL = URL(string: "https://example.com/clear_all_test_\(UUID().uuidString).jpg")!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dummyImage = ctx.makeImage()!
        DecodedImageCache.images.setObject(dummyImage, forKey: dummyImageURL as NSURL)
        expectTrue(
            DecodedImageCache.images.object(forKey: dummyImageURL as NSURL) != nil,
            "Precondition: dummy image is cached in DecodedImageCache"
        )

        let testDB = DatabaseEngine(path: ":memory:")
        let testStore = ArticleStore(database: testDB, spotlightIndexer: MockSpotlightIndexer())
        await testStore.initialize()
        let settingsView = SettingsView()
        let clearTask = settingsView.clearEverythingData(articleStore: testStore)
        await clearTask.value

        expectTrue(
            DecodedImageCache.images.object(forKey: dummyImageURL as NSURL) == nil,
            "Clear All Caches must clear DecodedImageCache"
        )
        await testDB.close()
    }

    static func testEnrichmentQueueSchedulingAndPromotion() async {
        print("  - Testing EnrichmentQueue Scheduling, Promotion & Cancellation...")

        // Opened here, so the setup write below cannot race the store's own initialisation.
        let database = DatabaseEngine(path: ":memory:")
        do { try await database.open() } catch { return expectTrue(false, "The queue test database opens") }
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
        expectFalse(await queue.retainsJob(for: articleB.id), "Article B is evicted from jobs on cancel (#986)")
        expectEqual(await queue.state(for: articleB.id), nil, "Article B state is nil after eviction (#986)")

        // 5. Cancel all
        await queue.cancelAll(reason: .superseded)
        expectFalse(await queue.retainsJob(for: articleA.id), "Article A is evicted from jobs on cancelAll (#986)")
        let stateA = await queue.state(for: articleA.id)
        expectTrue(
            stateA == nil || stateA == .completed,
            "Article A is evicted unless it already finished (#986)")
        for _ in 0..<10 {
            await queue.enqueue(article: articleA, priority: .background)
            await queue.cancelAll(reason: .superseded)
            let active = await queue.activeJobCount()
            expectTrue(active <= 3, "Rapid replacement cannot exceed the concurrency bound")
        }

        await hold.open()

        // Finished work is not superseded or repeated by the next refresh, and its full FeedArticle job is released (#535).
        let articleC = FeedArticle(
            title: "Quarterly Earnings Beat Expectations", link: "https://example.com/earnings", guid: "eq-3",
            description: "Revenue and profit exceed analyst forecasts", pubDate: Date(), source: "Markets")
        // Only a stored classification counts as finished (#820).
        do { _ = try await database.upsertArticles([articleC]) } catch {
            expectTrue(false, "Article C is stored before it is classified: \(error)")
        }
        await queue.enqueue(article: articleC, priority: .interactive)
        await eventually("Article C finishes classification") { await queue.state(for: articleC.id) == .completed }
        expectFalse(
            await queue.retainsJob(for: articleC.id),
            "Completed job is removed from EnrichmentQueue.jobs so full FeedArticle payloads are not retained (#535)"
        )
        await queue.cancelAll(reason: .superseded)
        expectEqual(await queue.state(for: articleC.id), .completed, "Superseding the backlog keeps finished work")
        await queue.enqueue(article: articleC, priority: .background)
        expectEqual(await queue.state(for: articleC.id), .completed, "A finished article is not classified again")
        expectFalse(
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
            expectTrue(state != nil, "Batch enqueued article \(article.id) should exist in queue")
        }
        await batchHold.open()

        // Empty snapshot handling does not crash or create jobs
        await queue.enqueue(articles: [], priority: .background, allowHTTP: false)
    }

    static func testEnrichmentQueueCancelledJobsNotRetained() async {
        print("  - Testing EnrichmentQueue does not retain cancelled jobs or payloads (#986)...")
        let database = DatabaseEngine(path: ":memory:")
        do { try await database.open() } catch { return expectTrue(false, "The queue test database opens") }
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
            expectTrue(await queue.retainsJob(for: article.id), "Queued article is initially retained")
        }

        await queue.cancelAll(reason: .superseded)

        for article in articles {
            expectFalse(
                await queue.retainsJob(for: article.id),
                "Cancelled job \(article.id) is evicted from EnrichmentQueue.jobs so FeedArticle is not retained (#986)"
            )
        }
        expectEqual(
            await queue.stateCounts()["cancelled (superseded)"], 5,
            "Diagnostics still count the cancelled jobs without holding them (#986)")

        // An article enqueued again after the cancel is a new job and stays retained until it runs.
        await queue.enqueue(articles: [articles[0]], priority: .background)
        expectTrue(await queue.retainsJob(for: articles[0].id), "A re-enqueued article is retained again (#986)")
        await queue.cancel(articleId: articles[0].id, reason: .user)
        expectFalse(await queue.retainsJob(for: articles[0].id), "Cancelling one article evicts its job (#986)")
        await hold.open()
    }

    static func testDistributionAndEntitlementsIntegrity() async {
        print("  - Testing Distribution, Entitlements & Privacy Manifest Integrity...")

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let entitlementsPath = (currentDir as NSString).appendingPathComponent("News.entitlements")

        expectTrue(fileManager.fileExists(atPath: entitlementsPath), "News.entitlements must exist in project root")
        for file in ["PrivacyInfo.xcprivacy", "container-migration.plist"] {
            let data = fileManager.contents(atPath: (currentDir as NSString).appendingPathComponent(file))
            let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            expectTrue(plist is [String: Any], "Distribution manifest must be a valid property list: \(file)")
        }

        let infoPlist = fileManager.contents(atPath: (currentDir as NSString).appendingPathComponent("Info.plist"))
            .flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            }
        expectTrue(
            (infoPlist?["NSFocusStatusUsageDescription"] as? String)?.isEmpty == false,
            "Info.plist explains the Focus status request, or macOS aborts the app when it asks")

        guard let data = fileManager.contents(atPath: entitlementsPath) else {
            expectEqual(true, false, "Failed to read News.entitlements data")
            return
        }

        do {
            guard
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any]
            else {
                expectEqual(true, false, "News.entitlements is not a valid dictionary plist")
                return
            }

            expectEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "Sandbox must be enabled")
            // Validate minimal required entitlements
            expectEqual(
                plist["com.apple.security.network.client"] as? Bool, true,
                "com.apple.security.network.client must be enabled")
            expectEqual(
                plist["com.apple.security.files.user-selected.read-write"] as? Bool, true,
                "com.apple.security.files.user-selected.read-write must be enabled")

            // Validate that unnecessary/unsafe entitlements are NOT present
            expectEqual(
                plist["com.apple.security.network.server"] as? Bool, true,
                "Loopback gateway requires listener permission")
            expectFalse(
                plist.keys.contains("com.apple.security.device.camera"), "Camera entitlement should not be granted")
            expectFalse(
                plist.keys.contains("com.apple.security.device.microphone"),
                "Microphone entitlement should not be granted")
            expectFalse(
                plist.keys.contains("com.apple.security.personal-information.location"),
                "Location entitlement should not be granted")
            expectFalse(
                plist.keys.contains("com.apple.security.personal-information.addressbook"),
                "Contacts entitlement should not be granted")
            expectFalse(
                plist.keys.contains("com.apple.security.files.all"), "All files entitlement should not be granted")
        } catch {
            expectEqual(true, false, "Failed to parse News.entitlements: \(error)")
        }

        // Validate release packaging files exist
        let releaseBuildScript = (currentDir as NSString).appendingPathComponent("build_release.sh")
        let packageDmgScript = (currentDir as NSString).appendingPathComponent("script/distribution/package_dmg.sh")
        let notarizeScript = (currentDir as NSString).appendingPathComponent("script/distribution/notarize.sh")
        let packageSwift = (currentDir as NSString).appendingPathComponent("Package.swift")
        let privacyDoc = (currentDir as NSString).appendingPathComponent("PRIVACY.md")

        expectTrue(fileManager.fileExists(atPath: releaseBuildScript), "build_release.sh must exist")
        expectTrue(fileManager.isExecutableFile(atPath: releaseBuildScript), "build_release.sh must be executable")

        expectTrue(fileManager.fileExists(atPath: packageDmgScript), "package_dmg.sh must exist")
        expectTrue(fileManager.isExecutableFile(atPath: packageDmgScript), "package_dmg.sh must be executable")

        expectTrue(fileManager.fileExists(atPath: notarizeScript), "notarize.sh must exist")
        expectTrue(fileManager.isExecutableFile(atPath: notarizeScript), "notarize.sh must be executable")

        expectTrue(fileManager.fileExists(atPath: packageSwift), "Package.swift must exist")
        expectTrue(fileManager.fileExists(atPath: privacyDoc), "PRIVACY.md must exist")
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
        expectTrue(changed.withLock { $0 }, "UpdateChecker changes invalidate Observation tracking")
    }

    static func testStrictSemVerAndReleaseSecurity() async {
        print("  - Testing Strict SemVer Parsing & Release URL Security...")

        // 1. Valid SemVer strings
        expectEqual(
            SemanticVersion.parse("v2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1), "v2.0.1 should parse")
        expectEqual(SemanticVersion.parse("2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1), "2.0.1 should parse")
        expectEqual(
            SemanticVersion.parse("3.4.5"[...]), SemanticVersion(major: 3, minor: 4, patch: 5),
            "A Substring parses without an intermediate String")
        expectEqual(SemanticVersion.parse("١.2.3"), nil, "SemVer only accepts ASCII digits")
        expectEqual(
            SemanticVersion.parse("10.12.3"), SemanticVersion(major: 10, minor: 12, patch: 3), "10.12.3 should parse")
        expectEqual(SemanticVersion.parse("0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0), "0.1.0 should parse")
        expectEqual(
            SemanticVersion.parse("v0.0.1"), SemanticVersion(major: 0, minor: 0, patch: 1), "v0.0.1 should parse")

        // 2. Invalid tags should be rejected (ignored)
        expectEqual(SemanticVersion.parse("release-2.0.1"), nil, "release- prefix should be rejected")
        expectEqual(SemanticVersion.parse("v2.0"), nil, "Missing patch should be rejected")
        expectEqual(SemanticVersion.parse("2"), nil, "Single integer should be rejected")
        expectEqual(SemanticVersion.parse("foo"), nil, "Arbitrary string should be rejected")
        expectEqual(SemanticVersion.parse("v2.0.1-beta"), nil, "Non-numeric suffix should be rejected")

        // 3. Leading zeros must be rejected per SemVer 2.0.0
        expectEqual(SemanticVersion.parse("001.002.003"), nil, "Components with leading zeros must be rejected")
        expectEqual(SemanticVersion.parse("01.0.0"), nil, "Major with leading zero must be rejected")
        expectEqual(SemanticVersion.parse("1.02.0"), nil, "Minor with leading zero must be rejected")
        expectEqual(SemanticVersion.parse("1.0.03"), nil, "Patch with leading zero must be rejected")

        // 4. Numeric tuple comparison
        expectTrue(
            SemanticVersion(major: 2, minor: 0, patch: 1) > SemanticVersion(major: 2, minor: 0, patch: 0),
            "2.0.1 > 2.0.0")
        expectTrue(
            SemanticVersion(major: 2, minor: 1, patch: 0) > SemanticVersion(major: 2, minor: 0, patch: 9),
            "2.1.0 > 2.0.9")
        expectTrue(
            SemanticVersion(major: 3, minor: 0, patch: 0) > SemanticVersion(major: 2, minor: 9, patch: 9),
            "3.0.0 > 2.9.9")
        expectFalse(
            SemanticVersion(major: 2, minor: 0, patch: 0) > SemanticVersion(major: 2, minor: 0, patch: 1),
            "2.0.0 is not > 2.0.1")
        expectEqual(
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

        expectTrue(UpdateChecker.isValidReleaseURL(validURL1), "Valid release URL should be approved")
        expectTrue(UpdateChecker.isValidReleaseURL(validURL2), "Valid latest URL should be approved")
        expectTrue(UpdateChecker.isValidReleaseURL(validURL3), "Exact releases URL should be approved")
        expectFalse(UpdateChecker.isValidReleaseURL(invalidPrefix), "Sibling path /releasesomething must be rejected")
        expectFalse(UpdateChecker.isValidReleaseURL(invalidScheme), "Insecure HTTP release URL must be rejected")
        expectFalse(UpdateChecker.isValidReleaseURL(evilDomain), "Spoofed domain must be rejected")
        expectFalse(UpdateChecker.isValidReleaseURL(otherRepo), "Non-matching repository path must be rejected")
    }

    @MainActor
    static func testUpdateCheckerThrottleWithClock() async {
        print("  - Testing UpdateChecker 72-Hour Throttle Advancement with TestClock...")

        let baseEpoch = Date(timeIntervalSince1970: 1_700_000_000)
        let testClock = TestClock(baseEpoch)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = NewsTests.mockHTTPClient(configuration: config)
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
        expectTrue(checker.lastCheckDate == nil, "Initial checker has nil lastCheckDate")
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
        expectEqual(networkRequestCount, 1, "Initial automatic check executes network request")
        expectEqual(checker.lastCheckDate, baseEpoch, "Initial check sets lastCheckDate to clock.now")
        expectFalse(checker.updateAvailable, "v2.0.0 matches currentAppVersion 2.0.0 -> no update")
        expectEqual(checker.statusMessage, "NewsApp is up to date (v2.0.0)", "Status confirms up to date")

        // 2. Check one minute before the window ends is skipped (throttled)
        testClock.advance(by: UpdateChecker.automaticCheckInterval - 60)
        MockURLProtocol.requestHandler = { _ in
            expectTrue(false, "Throttled automatic check within 72 hours must not make network request")
            throw URLError(.cancelled)
        }
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 1, "Network request count remains 1 (skipped)")
        expectEqual(checker.lastCheckDate, baseEpoch, "lastCheckDate remains baseEpoch when throttled")

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
        expectEqual(networkRequestCount, 2, "User-initiated check bypasses 72-hour throttle")
        expectEqual(checker.lastCheckDate, userCheckTime, "User check updates lastCheckDate to current time")

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
        expectEqual(networkRequestCount, 3, "Automatic check after the window executes network request")
        expectEqual(checker.lastCheckDate, nextCheckTime, "lastCheckDate updates to new check time")

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
        expectEqual(networkRequestCount, 4, "Automatic check after the window executes network request")
        expectEqual(checker.lastCheckDate, updateCheckTime, "lastCheckDate updates on successful update detection")
        expectTrue(checker.updateAvailable, "Automatic check detects newer release v2.1.0")
        expectEqual(checker.latestVersionString, "v2.1.0", "Latest version string set")
        expectEqual(checker.statusMessage, "Version v2.1.0 available", "Status indicates version available")
        expectEqual(
            checker.verifiedReleaseURL?.absoluteString,
            "https://github.com/marspater/NewsApp-macOS/releases/tag/v2.1.0", "Release URL verified")
    }

    @MainActor
    static func testUpdateCheckerFailureBackoff() async {
        print("  - Testing UpdateChecker throttles after a failed attempt and across relaunch (#798)...")
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = NewsTests.mockHTTPClient(configuration: config)
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
        expectEqual(requests, 1, "First automatic check sends one request")
        expectTrue(checker.lastCheckDate == nil, "A failed check is not a successful check")
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(requests, 1, "A rate-limited check does not retry on the next activation")

        let relaunched = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: defaults)
        await relaunched.checkForUpdates(userInitiated: false)
        expectEqual(requests, 1, "A relaunch keeps the failed attempt throttled")

        await relaunched.checkForUpdates(userInitiated: true)
        expectEqual(requests, 2, "A manual check still bypasses the throttle after a failure")

        clock.advance(by: UpdateChecker.automaticCheckInterval + 1)
        await relaunched.checkForUpdates(userInitiated: false)
        expectEqual(requests, 3, "The next automatic check runs once the window has passed")

        // A backward clock correction leaves the saved attempt in the future; it counts as expired.
        clock.advance(by: -(UpdateChecker.automaticCheckInterval + 86400))
        await relaunched.checkForUpdates(userInitiated: false)
        expectEqual(requests, 4, "A saved attempt in the future does not suppress checks")

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
        expectTrue(finder.updateAvailable, "The check finds the newer release")
        let restored = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: foundDefaults)
        expectTrue(restored.updateAvailable, "A relaunch inside the window still offers the found update")
        expectEqual(restored.latestVersionString, "v2.1.0", "The restored update names its version")
        let upgraded = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.1.0", defaults: foundDefaults)
        expectFalse(upgraded.updateAvailable, "Once the app has that version, nothing is offered")

        // A later check that finds nothing (here a 404) removes the saved release.
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        clock.advance(by: UpdateChecker.automaticCheckInterval + 3600)
        await finder.checkForUpdates(userInitiated: false)
        let withdrawn = UpdateChecker(
            httpClient: client, now: { clock.now }, currentAppVersion: "2.0.0", defaults: foundDefaults)
        expectFalse(withdrawn.updateAvailable, "A withdrawn release is not restored on relaunch")
    }

    @MainActor
    static func testUpdateCheckerVersionComparisonAndErrors() async {
        print("  - Testing UpdateChecker Version Comparison Against Release 2.0.0 & Error States...")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let testClient = NewsTests.mockHTTPClient(configuration: config)
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
            expectFalse(checker.updateAvailable, "Local 2.0.0 vs Remote 2.0.0 must report up to date")
            expectEqual(checker.statusMessage, "NewsApp is up to date (v2.0.0)", "Status confirms up to date")
            expectTrue(checker.verifiedReleaseURL == nil, "Release URL is nil when up to date")
            expectTrue(checker.latestVersionString == nil, "Version string is nil when up to date")
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
            expectFalse(checker.updateAvailable, "Local 2.0.0 vs Remote v2.0.0 must report up to date")
            expectEqual(
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
            expectTrue(checker.updateAvailable, "Local 1.9.0 vs Remote 2.0.0 must report update available")
            expectEqual(checker.latestVersionString, "2.0.0", "Latest version is 2.0.0")
            expectEqual(checker.releaseNotes, "Release notes for 2.0.0", "Release notes captured")
            expectEqual(
                checker.verifiedReleaseURL?.absoluteString,
                "https://github.com/marspater/NewsApp-macOS/releases/tag/2.0.0", "Release URL matches")
            expectEqual(checker.statusMessage, "Version 2.0.0 available", "Status message indicates update")
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
            expectTrue(checker.updateAvailable, "Local 1.9.9 vs Remote v2.0.0 must report update available")
            expectEqual(checker.latestVersionString, "v2.0.0", "Latest version is v2.0.0")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "Local 2.1.0 vs Remote 2.0.0 must report up to date")
            expectEqual(
                checker.statusMessage, "NewsApp is up to date (v2.1.0)", "Status confirms up to date for 2.1.0")
            expectTrue(checker.verifiedReleaseURL == nil, "Release URL is nil when 2.1.0 is up to date")
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
            expectFalse(checker.updateAvailable, "Local 2.0.1 vs Remote 2.0.0 must report up to date")
            expectEqual(
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
            expectFalse(
                checker.updateAvailable, "Invalid remote tag '\(invalidTag)' must not flag update available")
            expectEqual(checker.statusMessage, "No valid updates found", "Status indicates no valid updates")
            expectTrue(checker.latestVersionString == nil, "Latest version is nil for invalid SemVer")
            expectTrue(checker.verifiedReleaseURL == nil, "Release URL is nil for invalid SemVer")
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
            expectFalse(checker.updateAvailable, "Invalid local version must not flag update available")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "404 response must not flag update available")
            expectEqual(
                checker.statusMessage, "No published release is available to compare.",
                "Status indicates 404 missing release")
            expectTrue(checker.lastCheckDate != nil, "404 updates lastCheckDate to throttle retries")
        }

        // 7. Network Failure State: HTTP 500 / 503
        do {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            let checker = UpdateChecker(httpClient: testClient, currentAppVersion: "2.0.0")
            await checker.checkForUpdates(userInitiated: true)
            expectFalse(checker.updateAvailable, "503 response must not flag update available")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "Oversized Content-Length must not flag update available")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "Oversized stream must not flag update available")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "Timeout must not flag update available")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "HTML content type must be rejected")
            expectEqual(
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
            expectFalse(checker.updateAvailable, "Untrusted release URL must not be accepted")
            expectEqual(
                checker.statusMessage, "Received untrusted release URL",
                "Status indicates untrusted release URL rejected")
            expectTrue(checker.verifiedReleaseURL == nil, "Untrusted release URL is not stored")
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
            expectTrue(checker.updateAvailable, "Initial check finds update available")

            MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
            await checker.checkForUpdates(userInitiated: true)
            expectFalse(checker.updateAvailable, "Failed subsequent check clears updateAvailable")
            expectTrue(checker.verifiedReleaseURL == nil, "Release URL cleared after failure")
            expectTrue(
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
        let testClient = NewsTests.mockHTTPClient(configuration: config)
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
        expectEqual(networkRequestCount, 1, "Baseline automatic check succeeds")
        expectEqual(checker.lastCheckDate, baseEpoch, "lastCheckDate is set to baseEpoch")

        // ====================================================================
        // 1. Time Leaps Backwards (DST rollback, clock drift, NTP adjustments)
        // ====================================================================

        // 1a. Clock drifts 1 hour backwards (DST rollback)
        testClock.advance(by: -3600)
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 1, "Automatic check is throttled during 1-hour backward DST drift")
        expectEqual(checker.lastCheckDate, baseEpoch, "lastCheckDate remains unchanged during backward drift")

        // Clock advances one second past the window after baseEpoch (from the current -1h time)
        testClock.advance(by: 3600 + UpdateChecker.automaticCheckInterval + 1)
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 2, "Automatic check executes once clock advances past 72-hour threshold")

        // 1b. Severe backward leap (30 days in the past)
        testClock.advance(by: -(30 * 86400))
        let rolledBackTime = testClock.now
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 3, "A saved attempt far in the future counts as expired")
        expectEqual(checker.lastCheckDate, rolledBackTime, "lastCheckDate resynchronizes to the rolled-back clock")

        // Check within 72 hours of new rolled-back time is throttled
        testClock.advance(by: 3600)
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 3, "Subsequent check is throttled relative to resynchronized clock")

        // ====================================================================
        // 2. Time Leaps Far Forward (30 days, 10 years)
        // ====================================================================

        // 2a. Leap 30 days forward
        testClock.advance(by: 30 * 86400)
        let forward30Time = testClock.now
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 4, "Automatic check executes after 30-day forward leap")
        expectEqual(checker.lastCheckDate, forward30Time, "lastCheckDate updates to 30-day future date")

        // Check 1 minute later is throttled
        testClock.advance(by: 60)
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 4, "Check 1 minute after 30-day leap is throttled")

        // 2b. Leap 10 years forward
        testClock.advance(by: 10 * 365 * 86400)
        let forward10yTime = testClock.now
        await checker.checkForUpdates(userInitiated: false)
        expectEqual(networkRequestCount, 5, "Automatic check executes after 10-year leap without overflow")
        expectEqual(checker.lastCheckDate, forward10yTime, "lastCheckDate updates to 10-year future date")

        // ====================================================================
        // 3. Rapid Successive Checks
        // ====================================================================

        let countBeforeLoop = networkRequestCount
        for _ in 0..<100 {
            await checker.checkForUpdates(userInitiated: false)
        }
        expectEqual(networkRequestCount, countBeforeLoop, "Rapid automatic checks in tight loop are 100% throttled")

        for _ in 0..<5 {
            await checker.checkForUpdates(userInitiated: true)
        }
        expectEqual(networkRequestCount, countBeforeLoop + 5, "Rapid sequential manual checks bypass throttle")

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
        expectTrue(checker.isChecking, "isChecking is true while in-flight network call is pending")
        expectEqual(checker.statusMessage, "Checking for updates...", "statusMessage indicates checking in-flight")

        // Concurrent automatic check while in-flight returns immediately without duplicate network call
        await checker.checkForUpdates(userInitiated: false)

        // Concurrent user-initiated check while in-flight also returns immediately
        await checker.checkForUpdates(userInitiated: true)

        // Release the network mock
        gateSemaphore.signal()
        _ = await inFlightTask.value

        expectFalse(checker.isChecking, "isChecking is false after in-flight check completes")
        expectTrue(checker.updateAvailable, "Update detected by in-flight check")
        expectEqual(
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
        expectEqual(
            networkRequestCount, countBeforeLoop + 7,
            "20 concurrent foregrounding events produce exactly 1 network request")
    }

    @MainActor
    static func testNotificationModeTriageAndGrammar() async {
        print("  - Testing NotificationMode Triage, Privacy & Singular/Plural Grammar...")

        var identified = FeedArticle(
            title: "Story", link: "https://example.com/a", guid: "a", description: "", pubDate: Date(), source: "P")
        identified.storedID = "stable-id"
        expectEqual(
            NotificationService.notificationIdentifier(for: identified), "news-stable-id",
            "Notification identifiers come from the stored story identity, not the per-process hash seed")

        // 1. Singular/Plural grammar helper
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 1),
            "1 new article from 1 source", "Singular article and source")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 2, uniqueSourcesCount: 1),
            "2 new articles from 1 source", "Plural articles, singular source")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 3, uniqueSourcesCount: 2),
            "3 new articles across 2 sources", "Plural articles, plural sources")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 10, uniqueSourcesCount: 4),
            "10 new articles across 4 sources", "Multi-source plural formatting")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 0),
            "1 new article across 0 sources", "Edge case: 1 article, 0 sources")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 0),
            "0 new articles across 0 sources", "Edge case: 0 articles, 0 sources")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 1),
            "0 new articles from 1 source", "Edge case: 0 articles, 1 source")

        // 2. AppSettings Migration Semantics
        let suiteName = testDefaultsSuite("test.notifications.migration")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }

        // Case A: legacy privateNotificationsEnabled = true -> migrates to .private
        tempDefaults.set(true, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsA = AppSettings(defaults: tempDefaults)
        expectEqual(
            settingsA.notificationMode, AppSettings.NotificationMode.privacy,
            "Legacy private flag should migrate to .private mode")
        expectEqual(
            tempDefaults.string(forKey: AppSettings.notificationModeKey), "private",
            "Migrated key should be written to defaults")

        // Case B: legacy privateNotificationsEnabled = false -> migrates to .full
        let suiteNameB = testDefaultsSuite("test.notifications.migration.b")
        let tempDefaultsB = UserDefaults(suiteName: suiteNameB)!
        defer { removeTestDefaults(suiteNameB) }
        tempDefaultsB.set(false, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsB = AppSettings(defaults: tempDefaultsB)
        expectEqual(
            settingsB.notificationMode, AppSettings.NotificationMode.full,
            "Legacy non-private flag should migrate to .full mode")
        expectEqual(
            tempDefaultsB.string(forKey: AppSettings.notificationModeKey), "full",
            "Migrated key should be written to defaults")

        // Case C: mutation API updates both mode and legacy private flag
        settingsB.setNotificationMode(.minimal)
        expectEqual(settingsB.notificationMode, AppSettings.NotificationMode.minimal, "Mode should update to .minimal")
        expectEqual(
            tempDefaultsB.string(forKey: AppSettings.notificationModeKey), "minimal", "Key should update to minimal")

        // Starred feeds persist and go with an unsubscribed feed (#588).
        settingsB.feedURLs = ["https://example.com/feed"]
        settingsB.setFeedStarred("https://example.com/feed", true)
        expectEqual(
            AppSettings(defaults: tempDefaultsB).starredFeedURLs, ["https://example.com/feed"], "A star is stored")
        settingsB.setFeedStarred("https://example.com/feed", false)
        expectTrue(AppSettings(defaults: tempDefaultsB).starredFeedURLs.isEmpty, "Unstarring is stored")
        settingsB.setFeedStarred("https://example.com/feed", true)
        settingsB.removeFeed(url: "https://example.com/feed")
        expectTrue(settingsB.starredFeedURLs.isEmpty, "Unsubscribing removes the star")

        // At most three feeds are starred: a fourth star is refused, not swapped in (#588).
        let capped = (1...4).map { "https://cap\($0).invalid/feed" }
        for url in capped.prefix(3) { expectTrue(settingsB.setFeedStarred(url, true), "Stars up to the limit") }
        expectFalse(settingsB.setFeedStarred(capped[3], true), "A fourth star is refused")
        expectEqual(settingsB.starredFeedURLs, Set(capped.prefix(3)), "The three stars stay; none is replaced")
        expectEqual(
            AppSettings(defaults: tempDefaultsB).starredFeedURLs, Set(capped.prefix(3)),
            "The refused star is not stored")
        expectTrue(settingsB.setFeedStarred(capped[0], true), "Re-starring a starred feed at the limit is fine")
        settingsB.setFeedStarred(capped[0], false)
        expectTrue(settingsB.setFeedStarred(capped[3], true), "Unstarring frees a place")
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
            let gate = NewsTests.FeedDeliveryGate()
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
            expectTrue(
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
        expectTrue(await cancelled.value, "Cancelled database ingestion propagates cancellation")
        expectTrue(try await db.fetchArticles().isEmpty, "Cancelled ingestion rolls back its transaction")
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
        expectFalse(
            try await db.fetchArticles().contains { $0.id == panelArticle.id },
            "Stopped managers no longer observe subscription changes")
        await db.close()
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
        let calls = NewsTests.RefreshCalls()
        let gate = NewsTests.FeedDeliveryGate()
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
        expectFalse(manager.isAnyFeedLoading, "Sleep ends the loading state of the refresh it cancels")
        expectFalse(manager.feedStatuses.values.contains(.loading), "No feed stays marked as loading after sleep")
        await gate.deliver()
        await interrupted.value
        expectTrue(try await db.fetchArticles().isEmpty, "A refresh cut off by sleep stores nothing")

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await manager.waitForWakeRefresh()
        expectEqual(await calls.count, 1, "Sleeping again before the wake delay ends refreshes nothing")

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await manager.waitForWakeRefresh()
        expectEqual(await calls.count, 2, "An interrupted refresh is repeated after wake")
        expectEqual(try await db.fetchArticles().map(\.title), ["Overnight report"], "The wake refresh stores the feed")
        expectFalse(manager.isAnyFeedLoading, "The wake refresh ends the loading state")

        clock = clock.addingTimeInterval(5 * 60)
        await sleepAndWake()
        expectEqual(await calls.count, 2, "A refresh newer than the interval is not repeated after wake")
        clock = clock.addingTimeInterval(31 * 60)
        await sleepAndWake()
        expectEqual(await calls.count, 3, "A feed older than the interval refreshes after wake")

        manager.stopBackgroundWork()
        clock = clock.addingTimeInterval(60 * 60)
        await sleepAndWake()
        expectEqual(await calls.count, 3, "A stopped manager ignores wake")
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
        expectEqual(settings.articleRetentionDays, 30, "Read stories are kept for 30 days by default")
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
                expectTrue(false, "Stored the \(name) story")
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
        expectFalse(try await stored(read), "A read, unsaved story older than 30 days is deleted after the refresh")
        let savedKept = try await stored(saved)
        let unreadKept = try await stored(unread)
        expectTrue(savedKept && unreadKept, "Saved and unread stories are kept")

        let later = try await storeOldStory("later", read: true)
        clock = clock.addingTimeInterval(6 * 3600)
        await manager.fetchFeedsAsync()
        expectTrue(try await stored(later), "Retention runs at most once a day")
        clock = clock.addingTimeInterval(19 * 3600)
        await manager.fetchFeedsAsync()
        expectFalse(try await stored(later), "The next day's refresh prunes again")

        settings.setArticleRetentionDays(0)
        expectEqual(AppSettings(defaults: defaults).articleRetentionDays, 0, "The retention setting persists")
        let kept = try await storeOldStory("kept", read: true)
        clock = clock.addingTimeInterval(25 * 3600)
        await manager.fetchFeedsAsync()
        expectTrue(try await stored(kept), "Never keeps every story")
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
        expectFalse(manager.isAnyFeedLoading, "Cancelling a refresh ends its loading state")
        await first.value
        // The subscription change started the next refresh; its caller runs triage after clustering.
        for _ in 0..<2000 where notified.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        let expected = try stories.map { try #require(ArticleIdentity.scopedGUID($0.value, feedURL: $0.key)) }
        expectEqual(Set(notified), Set(expected), "Stories stored by the cancelled run and by the new run are notified")
        expectEqual(notified.count, 3, "Each story is notified once")
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
        expectEqual(
            window.map(\.title), ["Undated"],
            "An undated story stored now is within the last hour; a three-day-old story is not")
        expectTrue(
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
        expectTrue(AppSettings(defaults: badgeDefaults).showsDockBadge, "The Dock badge is on by default")
        AppSettings(defaults: badgeDefaults).setShowsDockBadge(false)
        expectFalse(AppSettings(defaults: badgeDefaults).showsDockBadge, "Turning the Dock badge off persists")

        // 1. URLComponents Normalization
        let httpFeed = "http://feeds.arstechnica.com/arstechnica/index"
        let normalizedHTTPS = AppSettings.normalizeFeedURL(httpFeed, allowInsecureHTTP: false)
        expectEqual(
            normalizedHTTPS, "https://feeds.arstechnica.com/arstechnica/index",
            "Should upgrade http to https when allowInsecureHTTP is false")

        let preservedHTTP = AppSettings.normalizeFeedURL(httpFeed, allowInsecureHTTP: true)
        expectEqual(
            preservedHTTP, "http://feeds.arstechnica.com/arstechnica/index",
            "Should preserve http when allowInsecureHTTP is true")

        let upperHost = "HTTPS://FEEDS.BBCO.CO.UK/NEWS/RSS.XML/"
        let normalizedUpper = AppSettings.normalizeFeedURL(upperHost)
        expectEqual(
            normalizedUpper, "https://feeds.bbco.co.uk/NEWS/RSS.XML/",
            "Host must be lowercased; a meaningful trailing slash is kept")

        for slashed in [
            "https://www.japantimes.co.jp/feed/", "https://www.eurointegration.com.ua/rss/",
            "https://phys.org/rss-feed/",
            "https://www.theatlantic.com/feed/channel/culture/", "https://www.scmp.com/rss/91/feed/",
        ] {
            expectEqual(
                AppSettings.normalizeFeedURL(slashed), slashed,
                "Feeds served only with a trailing slash keep it: \(slashed)")
        }
        expectEqual(
            AppSettings.normalizeFeedURL("http://phys.org/rss-feed/"), "https://phys.org/rss-feed/",
            "HTTPS upgrade still applies to slashed paths")
        expectEqual(
            AppSettings.normalizeFeedURL("https://example.com/feed/?a=1"), "https://example.com/feed/?a=1",
            "Query follows the kept slash")
        expectEqual(
            AppSettings.normalizeFeedURL("https://example.com/a%2Fb/"), "https://example.com/a%2Fb/",
            "Encoded path is not rewritten")

        let bareDomain = "example.com/"
        let normalizedBare = AppSettings.normalizeFeedURL(bareDomain)
        expectEqual(
            normalizedBare, "https://example.com", "Bare domain should gain https scheme and drop the root slash")

        // #797: a pasted feed: address is unwrapped; any other explicit scheme is refused, not prefixed.
        expectEqual(
            AppSettings.normalizeFeedURL("feed://example.com/rss"), "https://example.com/rss",
            "feed:// addresses are unwrapped")
        expectEqual(
            AppSettings.normalizeFeedURL("feed:https://example.com/rss"), "https://example.com/rss",
            "feed:https:// addresses are unwrapped")
        for refused in [
            "ftp://example.com/rss", "webcal://example.com/cal", "file:///etc/passwd", "javascript:alert(1)",
        ] {
            expectTrue(AppSettings.normalizeFeedURL(refused) == nil, "\(refused) is not a feed address")
        }
        expectEqual(
            AppSettings.normalizeFeedURL("example.com:8443/feed"), "https://example.com:8443/feed",
            "A host with a port still gets https")
        expectEqual(
            AppSettings.normalizeFeedURL("feed: https://example.com/rss"), "https://example.com/rss",
            "A space after feed: is ignored")
        expectEqual(
            AppSettings.normalizeFeedURL("user:pass@example.com/rss"), "https://user:pass@example.com/rss",
            "Credentials without a scheme are not mistaken for a scheme")
        expectTrue(AppSettings.normalizeFeedURL("[2001:db8::1]/feed") != nil, "A bracketed IPv6 host is accepted")
        expectTrue(
            AppSettings.normalizeFeedURL("ftp:user:pass@example.com/rss") == nil,
            "An explicit unsupported scheme is refused before credentials are read")
        expectEqual(
            AppSettings.addFeedFailureMessage(for: "ftp://example.com/rss"),
            "Feed not added. ftp: addresses are not supported. Use an http or https feed address.",
            "Add Feed names a refused scheme")
        expectEqual(
            AppSettings.addFeedFailureMessage(for: "https://example.com/rss"),
            "Feed not added. Check the URL or whether you already subscribe.",
            "A web address keeps the generic failure text")
        expectEqual(
            AppSettings.normalizeFeedURL("feed:8443/rss"), "https://feed:8443/rss",
            "feed: followed by a port is a host named feed, not a wrapper")
        let invalidURL = AppSettings.normalizeFeedURL("")
        expectEqual(invalidURL, nil, "Empty string should return nil")

        // 2. Injected UserDefaults Isolation
        let suiteName = testDefaultsSuite("test.settings.isolation")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }

        let settings = AppSettings(defaults: tempDefaults)
        _ = settings.addFeed(url: "https://isolated.example.com/rss.xml")
        settings.addSection("IsolatedSection")

        // Verify stored in tempDefaults
        let storedFeeds = tempDefaults.stringArray(forKey: AppSettings.feedURLsKey) ?? []
        expectTrue(
            storedFeeds.contains("https://isolated.example.com/rss.xml"),
            "Injected defaults must receive feedURLs mutations")

        let storedSections = tempDefaults.stringArray(forKey: AppSettings.userSectionsKey) ?? []
        expectTrue(storedSections.contains("IsolatedSection"), "Injected defaults must receive userSections mutations")

        expectEqual(AppSettings.feedKey("https://example.com"), "https://example.com", "A root URL is its own key")
        expectEqual(
            AppSettings.feedKey("https://example.com/feed/"), "https://example.com/feed",
            "One trailing slash is ignored")
        expectEqual(
            AppSettings.feedKey("https://example.com/feed//"), "https://example.com/feed/",
            "Only one trailing slash is ignored")
        expectEqual(
            AppSettings.feedKey("https://example.com/feed/?a=1"), "https://example.com/feed?a=1",
            "The query stays in the key")
        // 3. Slash variants are one subscription; the URL is stored as given and stored subscriptions are never rewritten
        let slashSuite = testDefaultsSuite("test.settings.slash")
        let slashDefaults = UserDefaults(suiteName: slashSuite)!
        defer { removeTestDefaults(slashSuite) }
        slashDefaults.set(["https://legacy.example.com/feed"], forKey: AppSettings.feedURLsKey)
        let slashSettings = AppSettings(defaults: slashDefaults)
        expectEqual(
            slashSettings.feedURLs, ["https://legacy.example.com/feed"], "Stored subscriptions are not migrated")
        expectEqual(
            slashSettings.addFeed(url: "https://legacy.example.com/feed/"), nil,
            "Slash variant of a stored subscription is a duplicate")
        expectEqual(
            slashSettings.addFeed(url: "https://Slash.example.com/feed/"), "https://slash.example.com/feed/",
            "Slashed feed is stored as given")
        expectEqual(
            slashSettings.addFeed(url: "https://slash.example.com/feed"), nil,
            "Slashless variant of a slashed subscription is a duplicate")
        expectEqual(
            slashSettings.addFeed(url: "https://slash.example.com/feed//"), "https://slash.example.com/feed//",
            "Only one trailing slash is insignificant")
        let opml = Data(
            "<opml><body><outline xmlUrl=\"https://opml.example.com/rss/\"/><outline xmlUrl=\"https://opml.example.com/rss\"/><outline xmlUrl=\"https://legacy.example.com/feed/\"/></body></opml>"
                .utf8)
        expectEqual(
            slashSettings.importFeeds(from: opml), 1,
            "OPML import adds one of two slash variants and skips subscribed ones")
        expectEqual(
            slashSettings.feedURLs.suffix(1), ["https://opml.example.com/rss/"],
            "OPML import keeps the first form as given")
        slashSettings.removeFeed(url: "https://legacy.example.com/feed")
        expectEqual(
            slashSettings.addFeed(url: "https://legacy.example.com/feed/"), "https://legacy.example.com/feed/",
            "Removing the stored form frees the slash variant")
        _ = slashSettings.addFeed(url: "https://removal.example.com/feed/")
        slashSettings.removeFeed(url: "https://removal.example.com/feed")
        expectFalse(
            slashSettings.feedURLs.contains { AppSettings.feedKey($0) == "https://removal.example.com/feed" },
            "Removing the slashless form removes a slash-stored subscription")
        _ = slashSettings.addFeed(url: "https://removal.example.com/plain")
        slashSettings.removeFeed(url: "https://removal.example.com/plain/")
        expectFalse(
            slashSettings.feedURLs.contains { AppSettings.feedKey($0) == "https://removal.example.com/plain" },
            "Removing the slash form removes a slashless subscription")
        expectEqual(
            slashDefaults.stringArray(forKey: AppSettings.feedURLsKey), slashSettings.feedURLs,
            "Slash-preserving subscriptions persist as given")
        if let catalogFeed = FeedCatalog.feeds.first(where: { !$0.url.contains("?") && !$0.url.hasSuffix("/") }) {
            _ = slashSettings.addFeed(url: catalogFeed.url + "/")
            expectTrue(
                slashSettings.isSubscribed(catalogFeed), "A slash variant of a catalog feed counts as subscribed")
            expectEqual(
                slashSettings.addCatalogFeeds([catalogFeed, catalogFeed]), 0, "Catalog subscribe skips slash variants")
            expectTrue(
                !CatalogReviewEngine.detectTopicGaps(subscribedURLs: [catalogFeed.url + "/"]).contains {
                    $0.catalogSet == catalogFeed.set
                }, "A slash variant covers its catalog set")
        }
    }
}
