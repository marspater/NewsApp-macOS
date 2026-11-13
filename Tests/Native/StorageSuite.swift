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
import PDFKit
import SQLite3
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Native port of the `StorageTests` atom (#1070): the same sixteen tests, in the runner's order, with each
/// `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of NativeExpectations.swift, each caught `recordFailure` into `expectTrue(false, ...)` (the runner log is invisible to Swift Testing),
/// each force unwrap into `#require`, so a failure is recorded and later tests still run. The runner keeps its copy
/// until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.storage, .integration)) struct StorageSuite {
        @Test func databaseEnginePersistence() async { await Self.testDatabaseEnginePersistence() }
        @Test @MainActor func cancelledBulkMarkDoesNotWrite() async throws {
            try await Self.testCancelledBulkMarkDoesNotWrite()
        }
        @Test func fts5SearchAndOperators() async { await Self.testFTS5SearchAndOperators() }
        @Test func unchangedFTSRefresh() async throws { try await Self.testUnchangedFTSRefresh() }
        @Test func searchSpellingSuggestion() async throws { try await Self.testSearchSpellingSuggestion() }
        @Test func refreshStateKeepsChangesMadeWhileLoading() async throws {
            try await Self.testRefreshStateKeepsChangesMadeWhileLoading()
        }
        @Test func countsStayExactAcrossToggleAndBulkChanges() async throws {
            try await Self.testCountsStayExactAcrossToggleAndBulkChanges()
        }
        @Test func unreadCountAndSavedStateCoverTheLibrary() async throws {
            try await Self.testUnreadCountAndSavedStateCoverTheLibrary()
        }
        @Test func unreadCountsStoriesNotReports() async throws { try await Self.testUnreadCountsStoriesNotReports() }
        @Test @MainActor func libraryStatusFollowsTheOpenState() async throws {
            try await Self.testLibraryStatusFollowsTheOpenState()
        }
        @Test func databaseHealthAndDerivedRetention() async throws {
            try await Self.testDatabaseHealthAndDerivedRetention()
        }
        @Test func libraryBackupAndFutureSchemaGuard() async throws {
            try await Self.testLibraryBackupAndFutureSchemaGuard()
        }
        @Test func readOnlyLibraryRefresh() async throws { try await Self.testReadOnlyLibraryRefresh() }
        @Test func libraryBackupRestore() async throws { try await Self.testLibraryBackupRestore() }
        @Test func sqliteFailuresAreNotEmptyResults() async throws {
            try await Self.testSQLiteFailuresAreNotEmptyResults()
        }
        @Test func articleRetentionPolicy() async { await Self.testArticleRetentionPolicy() }
        @Test func userNotesStorageAndFTS() async throws { try await Self.testUserNotesStorageAndFTS() }
        @Test func publisherRevisionTextStorage() async throws { try await Self.testPublisherRevisionTextStorage() }
        @Test func granularCacheClearingAndRetention() async throws {
            try await Self.testGranularCacheClearingAndRetention()
        }
        @Test func worldTensionBackupAndRestoreSafety() async throws {
            try await Self.testWorldTensionBackupAndRestoreSafety()
        }
        @Test @MainActor func pruneResilienceWhenVacuumFails() async throws {
            try await Self.testPruneResilienceWhenVacuumFails()
        }
        @Test @MainActor func storageHardeningItems() async throws {
            try await Self.testStorageHardeningItems()
        }
        @Test @MainActor func movedFeedSubscriptionMigration() async throws {
            try await Self.testMovedFeedSubscriptionMigration()
        }
        @Test func seededLaunchLibraryIsClassified() async throws {
            try await Self.testSeededLaunchLibraryIsClassified()
        }
    }
}

extension NativeSuites.StorageSuite {
    static func testSeededLaunchLibraryIsClassified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("launch.sqlite3").path
        try await NewsTests.seedLaunchLibrary(path: path, stories: 50)
        // Opening with DatabaseEngine would run the backfill this test checks for.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw StoryCorpus.Failure.invalid("Cannot open \(path)")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(
                handle, "SELECT count(*), sum(category IS NULL) FROM article_enrichment;", -1, &statement, nil)
                == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW
        else { throw StoryCorpus.Failure.invalid("Cannot count enrichment rows") }
        expectEqual(sqlite3_column_int64(statement, 0), 50, "Every seeded story has an enrichment row")
        expectEqual(sqlite3_column_int64(statement, 1), 0, "No seeded story waits for the open-time topic backfill")
    }

    @MainActor
    static func testCancelledBulkMarkDoesNotWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = DatabaseEngine(path: directory.appendingPathComponent("cancelled.sqlite3").path)
        let store = ArticleStore(database: db)
        await store.waitForStartup()
        expectTrue(store.isReady, "The isolated library opens before the cancellation test")

        let article = FeedArticle(
            title: "Unmarked story", link: "https://example.com/cancelled", guid: "cancelled-mark",
            description: "", pubDate: Date(), source: "Test Publisher")
        try await db.upsertArticles([article])

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.markAllAsRead()
        }
        expectFalse(await cancelled.value, "Cancelled Mark All as Read reports no write")
        expectEqual(store.operationError, nil, "Cancellation is not reported as a storage error")
        expectTrue(try await db.getReadArticleIDs().isEmpty, "Cancellation preserves the unread story")

        let cancelledDatabaseCall = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await db.markAllRead()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        expectTrue(
            await cancelledDatabaseCall.value,
            "A cancelled caller waiting for the database actor cannot begin the bulk update")
        expectTrue(try await db.getReadArticleIDs().isEmpty, "Cancelled database updates preserve unread state")
        await db.close()
    }

    static func testUnchangedFTSRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fts.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let first = FeedArticle(
            title: "Original research", link: "https://example.com/fts", guid: "fts",
            description: "Initial description", pubDate: Date(), source: "Publisher", fullContent: "Originalbodytoken")
        try await db.upsertArticles([first])
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated FTS observation")
        defer { sqlite3_close(handle) }
        expectEqual(
            sqlite3_create_function_v2(
                handle, "news_publisher_input", 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, publisherInputFunction, nil,
                nil, nil), SQLITE_OK, "Register publisher hashing on the isolated FTS writer")
        func rowID() -> Int64 {
            var statement: OpaquePointer?
            expectEqual(
                sqlite3_prepare_v2(
                    handle, "SELECT rowid FROM articles_fts WHERE article_id='fts';", -1, &statement, nil), SQLITE_OK,
                "Observe FTS row")
            defer { sqlite3_finalize(statement) }
            expectEqual(sqlite3_step(statement), SQLITE_ROW, "FTS retains its row")
            return sqlite3_column_int64(statement, 0)
        }
        func indexData() -> String {
            var statement: OpaquePointer?
            expectEqual(
                sqlite3_prepare_v2(
                    handle,
                    "SELECT group_concat(id || ':' || hex(block), '|') FROM (SELECT id, block FROM articles_fts_data ORDER BY id);",
                    -1, &statement, nil), SQLITE_OK, "Observe FTS segments")
            defer { sqlite3_finalize(statement) }
            expectEqual(sqlite3_step(statement), SQLITE_ROW, "FTS has segment data")
            return String(cString: sqlite3_column_text(statement, 0))
        }
        // Segment data, unlike a durable row key, detects unnecessary delete/reindex work.
        let other = FeedArticle(
            title: "Other story", link: "https://example.com/other", guid: "other", description: "", pubDate: Date(),
            source: "Publisher")
        try await db.upsertArticles([other])
        let initialID = rowID()
        let initialIndex = indexData()
        try await db.upsertArticles([first])
        expectEqual(rowID(), initialID, "Identical refresh keeps the FTS key")
        expectEqual(indexData(), initialIndex, "Identical refresh does not delete/reinsert FTS")
        var metadata = first
        metadata.imageUrl = "https://example.com/new-photo.jpg"
        try await db.upsertArticles([metadata])
        expectEqual(rowID(), initialID, "Image-only metadata keeps the FTS key")
        expectEqual(indexData(), initialIndex, "Image-only metadata does not rebuild searchable text")
        expectEqual(
            sqlite3_exec(
                handle,
                "UPDATE articles SET title='Updated research', content=NULL, category='Science' WHERE id='fts';", nil,
                nil, nil), SQLITE_OK, "Change searchable fields including NULL")
        expectEqual(rowID(), initialID, "Changed searchable fields retain the durable FTS key")
        expectTrue(indexData() != initialIndex, "Changed searchable fields rebuild FTS")
        expectEqual(try await db.searchArticles(query: "Updated").count, 1, "Updated title is searchable")
        expectTrue(
            try await db.searchArticles(query: "Originalbodytoken").isEmpty, "Cleared NULL content removes old terms")
        expectEqual(try await db.searchArticles(query: "Science").count, 1, "Updated category is indexed")
        try await db.upsertArticles([
            FeedArticle(
                title: "Migration anchor", link: "https://example.com/anchor", guid: "anchor", description: "",
                pubDate: Date(), source: "Publisher")
        ])
        await db.close()
        expectEqual(
            sqlite3_exec(
                handle,
                "DROP TRIGGER trg_articles_au; CREATE TRIGGER trg_articles_au AFTER UPDATE ON articles BEGIN DELETE FROM articles_fts WHERE article_id=old.id; INSERT INTO articles_fts(article_id,title,description,content,source,category) VALUES(new.id,new.title,coalesce(new.description,''),coalesce(new.content,''),new.source,coalesce(new.category,'')); END; PRAGMA user_version=11;",
                nil, nil, nil), SQLITE_OK, "Reconstruct v11 trigger fixture")
        try await db.open()
        let migratedID = rowID()
        let migratedIndex = indexData()
        expectEqual(
            sqlite3_exec(handle, "UPDATE articles SET updated_at=updated_at+1 WHERE id='fts';", nil, nil, nil),
            SQLITE_OK, "Exercise migrated metadata update")
        expectEqual(rowID(), migratedID, "Existing v11 database receives a durable FTS key")
        expectEqual(indexData(), migratedIndex, "Existing v11 database receives the guarded trigger")
        expectEqual(try await db.searchArticles(query: "Updated").count, 1, "Migration preserves searchable rows")
        await db.close()
    }

    /// #786: a read or save change that lands while `refreshState` loads is not overwritten by the older snapshot.
    @MainActor static func testRefreshStateKeepsChangesMadeWhileLoading() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let stories = (0..<3).map { index in
            FeedArticle(
                title: "Race story \(index)", link: "https://example.com/race-\(index)", guid: "race-\(index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60),
                source: "Publisher")
        }
        try await db.upsertArticles(stories)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        await store.markAsRead(id: stories[0].id)
        expectTrue(store.readArticleIDs.contains(stories[0].id), "The story starts read")

        var landed = false
        store.refreshLoadedHook = {
            guard !landed else { return }
            landed = true
            await store.markAsRead(id: stories[0].id, isRead: false)
            _ = await store.setSaved(article: stories[1], isSaved: true)
        }
        await store.refreshState()
        store.refreshLoadedHook = nil
        expectFalse(store.readArticleIDs.contains(stories[0].id), "A read change made while loading survives")
        expectTrue(store.savedArticleIDs.contains(stories[1].id), "A save made while loading survives")
        expectEqual(store.unreadCount, 3, "The unread count follows the change")
        expectEqual(store.savedCount, 1, "The saved count follows the change")

        // A bulk change made while an older refresh loads: the older snapshot must not overwrite it.
        landed = false
        store.refreshLoadedHook = {
            guard !landed else { return }
            landed = true
            await store.markAsRead(ids: [stories[2].id])
        }
        let refreshed = await store.refreshState()
        store.refreshLoadedHook = nil
        expectTrue(refreshed, "The refresh publishes after reloading")
        expectTrue(store.readArticleIDs.contains(stories[2].id), "A bulk read change made while loading survives")

        // An article analysis publication that lands while refreshState loads must not be overwritten (#888).
        let analysis = ArticleAnalysis(
            summary: "Enriched summary", keyPoints: ["Point 1"], entities: [], category: "World",
            modelIdentifier: "test", analysisVersion: 1)
        landed = false
        store.refreshLoadedHook = {
            guard !landed else { return }
            landed = true
            _ = await store.saveArticleAnalysis(analysis, for: stories[0].id)
        }
        let categoryRefreshed = await store.refreshState()
        store.refreshLoadedHook = nil
        expectTrue(categoryRefreshed, "The refresh publishes after reloading on publication")
        expectEqual(
            store.articles.first { $0.id == stories[0].id }?.category, "World",
            "Category publication that landed while loading survives (#888)")

        // Overtaken on every try: the refresh reports failure and a follow-up publishes what was stored.
        let late = FeedArticle(
            title: "Late story", link: "https://example.org/late", guid: "late", description: "",
            pubDate: Date(timeIntervalSince1970: 1_700_000_100), source: "Publisher")
        try await db.upsertArticles([late])
        var overtakes = 0
        store.refreshLoadedHook = {
            guard overtakes < 3 else { return }
            overtakes += 1
            await store.markAsRead(id: stories[2].id, isRead: overtakes % 2 == 0)
        }
        let overtaken = await store.refreshState()
        expectFalse(overtaken, "A refresh overtaken on every try reports failure")
        for _ in 0..<40 where !store.articles.contains(where: { $0.id == late.id }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        store.refreshLoadedHook = nil
        expectTrue(store.articles.contains { $0.id == late.id }, "A follow-up refresh publishes the stored story")

        // An older refresh that finishes after a newer one published does not replace it (a prune or any second caller).
        let newest = FeedArticle(
            title: "Newest story", link: "https://example.org/newest", guid: "newest", description: "",
            pubDate: Date(timeIntervalSince1970: 1_700_000_200), source: "Publisher")
        var interleaved = false
        store.refreshLoadedHook = {
            guard !interleaved else { return }
            interleaved = true
            _ = try? await db.upsertArticles([newest])
            await store.refreshState()
        }
        await store.refreshState()
        store.refreshLoadedHook = nil
        expectTrue(
            store.articles.contains { $0.id == newest.id }, "An older snapshot does not replace a newer refresh")
        await db.close()
    }

    /// #839: counts are cached and adjusted per read toggle, and every other write refreshes them.
    static func testCountsStayExactAcrossToggleAndBulkChanges() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func story(_ index: Int, _ host: String = "other.org") -> FeedArticle {
            FeedArticle(
                title: "Counted story \(index)", link: "https://\(host)/\(index)", guid: "count-\(index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60),
                source: "Publisher")
        }
        let stories = (0..<5).map { story($0) }
        try await db.upsertArticles(stories)
        let muting = MuteRules(sources: ["muted.example"])
        expectEqual(try await db.counts().unread, 5, "Every story starts unread")
        expectEqual(try await db.mutedArticleCount(muting: muting), 0, "Nothing is muted yet")

        try await db.markRead(articleId: stories[0].id, isRead: true)
        expectEqual(try await db.counts().unread, 4, "A read toggle lowers the unread count")
        try await db.markRead(articleId: stories[0].id, isRead: true)
        expectEqual(try await db.counts().unread, 4, "Marking a read story read again changes nothing")
        try await db.markRead(articleId: stories[0].id, isRead: false)
        expectEqual(try await db.counts().unread, 5, "Marking it unread raises the count back")
        try await db.setSaved(articleId: stories[1].id, isSaved: true)
        expectEqual(try await db.counts().saved, 1, "A save is counted after cached counts")

        try await db.markReadBatch(articleIds: stories.prefix(3).map(\.id), isRead: true)
        expectEqual(try await db.counts().unread, 2, "A bulk change refreshes the counts")
        try await db.markRead(articleId: stories[4].id, isRead: true)
        expectEqual(try await db.counts().unread, 1, "A toggle after a bulk change adjusts the fresh counts")

        try await db.upsertArticles([story(9, "muted.example")])
        expectEqual(try await db.counts().total, 6, "New stories refresh the total")
        expectEqual(try await db.counts().unread, 2, "New stories refresh the unread count")
        expectEqual(try await db.mutedArticleCount(muting: muting), 1, "A new muted story refreshes the muted count")
        expectEqual(try await db.mutedArticleCount(muting: muting), 1, "The cached muted count repeats")

        // A muted story is outside the unread count under rules, so toggling it leaves the cached count alone.
        let mutedID = story(9, "muted.example").id
        expectEqual(try await db.counts(muting: muting).unread, 1, "The muted story is outside the unread count")
        try await db.markRead(articleId: mutedID, isRead: true)
        expectEqual(try await db.counts(muting: muting).unread, 1, "Reading a muted story leaves the cached count")
        try await db.markRead(articleId: mutedID, isRead: false)
        expectEqual(try await db.counts(muting: muting).unread, 1, "Unreading it leaves the cached count too")
        expectEqual(try await db.counts().unread, 2, "Without rules the muted story counts again")

        // A collection-only story is counted only while read: marking it unread leaves the counts.
        let panelURL = "https://example.com/panel-counts.xml"
        let panelStory = story(20)
        try await db.upsertArticles([panelStory], feedUrl: panelURL)
        let panelChanged = await db.setCollectionOnlyFeedURLs([panelURL])
        let panelRepeated = await db.setCollectionOnlyFeedURLs([panelURL])
        expectEqual([panelChanged, panelRepeated], [true, false], "The same hidden feeds again change nothing (#937)")
        try await db.markRead(articleId: panelStory.id, isRead: true)
        let withPanelRead = try await db.counts()
        try await db.markRead(articleId: panelStory.id, isRead: false)
        let withPanelUnread = try await db.counts()
        expectEqual(withPanelRead.total, withPanelUnread.total + 1, "An unread collection-only story leaves the total")
        expectEqual(withPanelRead.unread, withPanelUnread.unread, "It never joins the unread count")
        await db.close()
    }

    /// The unread count is the Unread list's cards: a story several reports cover counts once, a report no story
    /// groups counts on its own, and reading the last unread report of a story clears its card.
    static func testUnreadCountsStoriesNotReports() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let stories = (0..<6).map { index in
            FeedArticle(
                title: "Card story \(index)", link: "https://other.org/card-\(index)", guid: "card-\(index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60),
                source: "Publisher \(index)")
        }
        try await db.upsertArticles(stories)
        // Stories 0, 1 and 2 are one story, 3 and 4 another, and 5 stands alone.
        _ = try await db.applyEventMatch(
            stories[0].id, .create(with: [stories[1].id, stories[2].id]), matcherVersion: EventMatcher.version)
        _ = try await db.applyEventMatch(
            stories[3].id, .create(with: [stories[4].id]), matcherVersion: EventMatcher.version)
        let counts = try await db.counts()
        expectEqual(counts.unread, 3, "Two stories and a single report are three cards")
        expectEqual(counts.total, 6, "The total still counts reports")
        let list = try await db.fetchArticles(section: "Unread", isRead: false, limit: nil)
        let cards = EventFeedGrouping.entries(
            for: list, events: try await db.eventFeedSummaries(forArticles: list.map(\.id)), mode: .events)
        expectEqual(cards.count, counts.unread, "The badge equals the cards the list shows")

        try await db.markRead(articleId: stories[0].id, isRead: true)
        expectEqual(try await db.counts().unread, 3, "A story with unread reports left is still one unread card")
        try await db.markReadBatch(articleIds: [stories[1].id, stories[2].id], isRead: true)
        expectEqual(try await db.counts().unread, 2, "Reading the last report of a story clears its card")
        try await db.markRead(articleId: stories[5].id, isRead: true)
        expectEqual(try await db.counts().unread, 1, "A report no story groups moves the count by one")
        try await db.markRead(articleId: stories[3].id, isRead: true)
        expectEqual(try await db.counts().unread, 1, "The story's other report keeps its card unread")
        try await db.markRead(articleId: stories[4].id, isRead: true)
        expectEqual(try await db.counts().unread, 0, "Nothing is left to read")
        try await db.markRead(articleId: stories[4].id, isRead: false)
        expectEqual(try await db.counts().unread, 1, "One unread report brings its story back as one card")
        try await db.markRead(articleId: stories[1].id, isRead: false)
        try await db.markRead(articleId: stories[2].id, isRead: false)
        expectEqual(try await db.counts().unread, 2, "A second story's reports are one card, not two")
        await db.close()
    }

    /// What Settings › Storage says about the library follows the store: opening, then active, read-only or
    /// unavailable.
    @MainActor static func testLibraryStatusFollowsTheOpenState() async throws {
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        expectEqual(store.libraryStatus, .opening, "The library is opening until startup finishes")
        await store.waitForStartup()
        expectEqual(store.libraryStatus, .active, "An opened, loaded library is active")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-library-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let seed = DatabaseEngine(path: path)
        try await seed.open()
        await seed.close()
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the seeded library")
        sqlite3_exec(handle, "PRAGMA user_version = \(DatabaseEngine.schemaVersion + 1);", nil, nil, nil)
        sqlite3_close(handle)
        let newer = ArticleStore(database: DatabaseEngine(path: path), spotlightIndexer: MockSpotlightIndexer())
        await newer.waitForStartup()
        expectEqual(newer.libraryStatus, .readOnly, "A library saved by a newer build opens read-only")

        // A path under a file cannot be opened at all.
        let broken = ArticleStore(
            database: DatabaseEngine(path: "/dev/null/library.sqlite3"), spotlightIndexer: MockSpotlightIndexer())
        await broken.waitForStartup()
        expectEqual(broken.libraryStatus, .unavailable, "A library that cannot be opened is unavailable")
    }

    /// #785: the unread count is one SQL count over the whole library with muting applied, and saved state has no
    /// 500-story cap.
    @MainActor static func testUnreadCountAndSavedStateCoverTheLibrary() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        var stories = (0..<600).map { index in
            FeedArticle(
                title: "Library story \(index)", link: "https://other.org/\(index)", guid: "lib-\(index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60),
                source: "Publisher")
        }
        stories.append(
            FeedArticle(
                title: "Muted story", link: "https://muted.example/1", guid: "lib-muted", description: "",
                pubDate: Date(timeIntervalSince1970: 1_600_000_000), source: "Publisher"))
        try await db.upsertArticles(stories)
        let muting = MuteRules(sources: ["muted.example"])

        expectEqual(try await db.counts().unread, 601, "Without rules every unread story counts")
        expectEqual(
            try await db.counts(muting: muting).unread, 600,
            "The unread count spans the whole library, beyond the 500-story window, and leaves muted stories out")
        let unreadList = try await db.fetchArticles(
            isRead: false, limit: nil, options: ArticleFetchOptions(muting: muting))
        expectEqual(unreadList.count, 600, "The Unread list agrees with the count")

        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        // The store's own launch task also refreshes; the latest refresh publishes, so wait for it to settle.
        for _ in 0..<100 where store.unreadCount != 601 { try await Task.sleep(for: .milliseconds(50)) }
        expectEqual(store.unreadCount, 601, "The store counts everything while nothing is muted")
        await store.setMuting(muting)
        expectEqual(store.unreadCount, 600, "The menu bar and sidebar count follows the mute rules")
        await store.markAsRead(id: stories[0].id)
        expectEqual(store.unreadCount, 599, "A read toggle keeps muting applied")

        for story in stories.prefix(501) { try await db.setSaved(articleId: story.id, isSaved: true) }
        await store.refreshState()
        expectEqual(store.savedArticles.count, 501, "Saved stories are not capped at 500")
        expectEqual(store.savedArticleIDs.count, 501, "Every saved story reads as saved")
        expectEqual(store.savedCount, 501, "The saved count agrees")
        await store.removeAllSavedStories()
        expectEqual(try await db.counts().saved, 0, "Remove All unsaves every saved story")
        expectTrue(store.savedArticles.isEmpty, "Nothing stays saved in memory")
        await db.close()
    }

    static func testSearchSpellingSuggestion() async throws {
        func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }
        expectEqual(SearchSpelling.distance(scalars("nvida"), scalars("nvidia")), 1, "One deletion is one edit")
        expectEqual(SearchSpelling.distance(scalars("teh"), scalars("the")), 1, "An adjacent swap is one edit")
        expectEqual(SearchSpelling.distance(scalars("kitten"), scalars("sitting")), 3, "Classic distance")
        let vocabulary = ["nvidia": 3, "chips": 2, "election": 4, "elections": 1, "artificial": 2, "2026": 5]
        func correction(_ term: String) -> String? { SearchSpelling.correction(for: term, in: vocabulary) }
        expectEqual(correction("nvida"), "nvidia", "A typo maps to the library word")
        expectEqual(correction("chps"), "chips", "Four characters allow one edit")
        expectEqual(correction("nvid"), nil, "A word's start is not a typo")
        expectEqual(correction("chp"), nil, "Under four characters is never changed")
        expectEqual(correction("electionz"), "election", "Ties go to the commoner word")
        expectEqual(correction("zebra"), nil, "Nothing close, no correction")
        expectEqual(correction("2027"), nil, "A number is never corrected to another number")
        expectEqual(
            SearchSpelling.corrected("Nvida \"artifical\" source:reuters", vocabulary: vocabulary),
            "nvidia \"artificial\" source:reuters", "Misspelled terms change; quotes and operators stay")
        expectEqual(SearchSpelling.corrected("nvidia chips", vocabulary: vocabulary), nil, "Known words, no suggestion")
        expectEqual(
            SearchSpelling.corrected("\"nvida chps\" is:unread", vocabulary: vocabulary),
            "\"nvidia chips\" is:unread", "Corrections retain phrase boundaries and filters")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = DatabaseEngine(path: directory.appendingPathComponent("spelling.sqlite3").path)
        try await db.open()
        try await db.upsertArticles([
            FeedArticle(
                title: "Nvidia unveils new chips", link: "https://example.com/nvidia", guid: "nvidia",
                description: "The chipmaker raised its forecast", pubDate: Date(), source: "Publisher")
        ])
        expectTrue(try await db.searchArticles(query: "nvida chips").isEmpty, "The typo finds nothing")
        expectEqual(
            try await db.searchSuggestion(query: "nvida chips"), "nvidia chips", "The suggestion fixes the typo")
        expectEqual(
            try await db.searchSuggestion(query: "nvidia tariffs"), nil, "A word with nothing close gets no suggestion")
        expectEqual(
            try await db.searchSuggestion(query: "\"nvida unveils\""), "\"nvidia unveils\"",
            "A corrected phrase remains a phrase in a search suggestion")
        // A re-worded headline keeps the story count and rowid; the cached word list must still see the new words.
        try await db.upsertArticles([
            FeedArticle(
                title: "Nvidia unveils new processors", link: "https://example.com/nvidia", guid: "nvidia",
                description: "The chipmaker raised its forecast", pubDate: Date(), source: "Publisher")
        ])
        expectEqual(
            try await db.searchSuggestion(query: "procesors"), "processors", "An edited headline refreshes the words")
        await db.close()
    }

    @MainActor
    static func testDatabaseHealthAndDerivedRetention() async throws {
        print(
            "  - Testing database health (v26 auto_vacuum, quick_check, checkpoint, derived retention) (#536, #537)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-db-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func value(_ file: String, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            expectEqual(sqlite3_open(file, &handle), SQLITE_OK, "Open SQLite file for inspection")
            defer { sqlite3_close(handle) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }

        // 1. Fresh DB starts at v26 with incremental auto_vacuum (2), and shrinks after pruneOldArticles (#536).
        let shrinkPath = directory.appendingPathComponent("shrink.sqlite3").path
        let shrinkDB = DatabaseEngine(path: shrinkPath)
        try await shrinkDB.open()
        expectEqual(
            value(shrinkPath, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "New database opens at the current schema")
        expectEqual(value(shrinkPath, "PRAGMA auto_vacuum;"), "2", "New database uses incremental auto_vacuum (2)")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredDate = now.addingTimeInterval(-45 * 86_400)
        let paddingBody = String(repeating: "Detailed archival paragraph text for vacuum verification. ", count: 120)
        let bulkyArticles = (0..<250).map { idx in
            FeedArticle(
                storedID: "bulky-\(idx)",
                title: "Bulky archival report \(idx)",
                link: "https://example.com/bulky/\(idx)",
                guid: "bulky-\(idx)",
                description: "Archival summary \(idx)",
                pubDate: expiredDate,
                source: "Archival Press",
                fullContent: paddingBody
            )
        }
        try await shrinkDB.upsertArticles(bulkyArticles)
        // A feed item, identified by its feed-scoped GUID, that the feed keeps serving after it is pruned (#783).
        let servedFeed = "https://example.com/archive.xml"
        let served = FeedArticle(
            title: "Still served report", link: "https://example.com/served/report", guid: "served-guid",
            description: "Served long after reading", pubDate: expiredDate, source: "Archival Press")
        let servedID = try await shrinkDB.upsertArticles([served], feedUrl: servedFeed)
        try await shrinkDB.markReadBatch(articleIds: bulkyArticles.map(\.id) + Array(servedID), isRead: true)
        await shrinkDB.checkpointAndOptimize()
        let sizeBeforePrune =
            (try? FileManager.default.attributesOfItem(atPath: shrinkPath)[.size] as? Int64) ?? 0
        let prunedCount = try await shrinkDB.pruneOldArticles(keepReadDays: 30, now: now)
        expectEqual(prunedCount, 251, "Prunes all 251 expired read articles")
        expectTrue(
            try await shrinkDB.upsertArticles([served], feedUrl: servedFeed).isEmpty,
            "A pruned story its feed still serves is not stored again as new (#783)")
        expectTrue(
            try await shrinkDB.upsertArticles([bulkyArticles[0]]).isEmpty,
            "A pruned story keeps its stored ID's tombstone")
        expectTrue(try await shrinkDB.fetchArticles(limit: 10).isEmpty, "Pruned stories stay out of every list")
        let sameAddress = FeedArticle(
            title: "Next edition", link: served.link, guid: "served-guid-2", description: "A new edition",
            pubDate: now, source: "Archival Press")
        expectEqual(
            try await shrinkDB.upsertArticles([sameAddress], feedUrl: servedFeed).count, 1,
            "A new story at a pruned story's address still arrives")
        try await shrinkDB.upsertArticles([bulkyArticles[1]], preservingStoredContent: true)
        expectTrue(
            try await shrinkDB.fetchArticles(limit: 10).contains { $0.id == bulkyArticles[1].id },
            "Saving a pruned story explicitly stores it again")
        await shrinkDB.checkpointAndOptimize()
        await shrinkDB.close()
        let sizeAfterPrune =
            (try? FileManager.default.attributesOfItem(atPath: shrinkPath)[.size] as? Int64) ?? 0
        expectTrue(
            sizeAfterPrune < sizeBeforePrune,
            "Incremental vacuum + checkpoint shrinks the SQLite file on disk (\(sizeBeforePrune) -> \(sizeAfterPrune))"
        )

        // 2. Derived intelligence row retention (#537):
        //    - 40-day-old singleton's pair_assessments, article_features, and article_embeddings are removed on prune.
        //    - Event member's features and embeddings stay even when older than 72h.
        //    - Re-clustering recomputes features deterministically if needed.
        let retentionPath = directory.appendingPathComponent("derived-retention.sqlite3").path
        let retentionDB = DatabaseEngine(path: retentionPath)
        try await retentionDB.open()
        let singletonOld = FeedArticle(
            storedID: "singleton-40d",
            title: "Central Bank Holds Rates Steady in Frankfurt Meeting",
            link: "https://example.com/singleton-40d",
            guid: "singleton-40d",
            description: "Policymakers left benchmark interest rates unchanged on Thursday.",
            pubDate: now.addingTimeInterval(-40 * 86_400),
            source: "Finance Wire"
        )
        let eventMemberA = FeedArticle(
            storedID: "event-member-a",
            title: "Volcano Erupts Near Reykjanes Peninsula in Iceland",
            link: "https://example.com/event-member-a",
            guid: "event-member-a",
            description: "Lava fountains opened along a four-kilometer fissure overnight.",
            pubDate: now.addingTimeInterval(-10 * 86_400),
            source: "Nordic News"
        )
        let eventMemberB = FeedArticle(
            storedID: "event-member-b",
            title: "Iceland Evacuates Grindavik After New Volcanic Fissure Opens",
            link: "https://example.com/event-member-b",
            guid: "event-member-b",
            description: "Emergency crews evacuated residents near the Reykjanes eruption.",
            pubDate: now.addingTimeInterval(-10 * 86_400 + 600),
            source: "Atlantic Dispatch"
        )
        try await retentionDB.upsertArticles([singletonOld, eventMemberA, eventMemberB])
        _ = try await retentionDB.createEvent(
            memberArticleIDs: [eventMemberA.id, eventMemberB.id], at: now.addingTimeInterval(-10 * 86_400))

        let singletonFeatures = EventFeatures(
            title: singletonOld.title, description: singletonOld.description, date: singletonOld.pubDate)
        let memberFeatures = EventFeatures(
            title: eventMemberA.title, description: eventMemberA.description, date: eventMemberA.pubDate)
        try await retentionDB.upsertArticleFeatures(
            [singletonOld.id: singletonFeatures, eventMemberA.id: memberFeatures],
            version: EventFeatures.storageVersion,
            at: now.addingTimeInterval(-40 * 86_400)
        )
        let syntheticVector = Array(repeating: Float(0.1), count: 384)
        try await retentionDB.upsertArticleEmbeddings(
            [singletonOld.id: syntheticVector, eventMemberA.id: syntheticVector],
            modelVersion: SentenceEmbedder.modelVersion
        )
        try await retentionDB.upsertPairDecisions(
            [
                DatabaseEngine.PairDecision(
                    articleID: eventMemberA.id,
                    otherArticleID: singletonOld.id,
                    decision: "borderline",
                    reason: "test-old-pair",
                    score: 0.42
                )
            ],
            matcherVersion: EventMatcher.version,
            at: now.addingTimeInterval(-40 * 86_400)
        )
        try await retentionDB.upsertPairDecisions(
            [
                DatabaseEngine.PairDecision(
                    articleID: eventMemberA.id,
                    otherArticleID: eventMemberB.id,
                    decision: "match",
                    reason: "test-recent-pair",
                    score: 0.88
                )
            ],
            matcherVersion: EventMatcher.version,
            at: now.addingTimeInterval(-5 * 86_400)
        )

        _ = try await retentionDB.pruneOldArticles(keepReadDays: 30, now: now)
        let remainingFeatures = try await retentionDB.fetchArticleFeatures(
            articleIDs: [singletonOld.id, eventMemberA.id], version: EventFeatures.storageVersion)
        expectTrue(
            remainingFeatures[singletonOld.id] == nil,
            "40-day-old singleton's article_features row is pruned (#537)"
        )
        expectEqual(
            remainingFeatures[eventMemberA.id], memberFeatures,
            "Event member's article_features row is retained outside 72h window (#537)"
        )
        let remainingEmbeddings = try await retentionDB.fetchArticleEmbeddings(
            articleIDs: [singletonOld.id, eventMemberA.id], modelVersion: SentenceEmbedder.modelVersion)
        expectTrue(
            remainingEmbeddings[singletonOld.id] == nil,
            "40-day-old singleton's article_embeddings row is pruned (#537)"
        )
        expectTrue(
            remainingEmbeddings[eventMemberA.id] != nil,
            "Event member's article_embeddings row is retained (#537)"
        )
        await retentionDB.close()
        expectEqual(
            value(retentionPath, "SELECT count(*) FROM pair_assessments;"), "1",
            "Pair assessment older than 30 days is pruned while recent pair assessment stays (#537)"
        )
        let recomputedFeatures = EventFeatures(
            title: singletonOld.title, description: singletonOld.description, date: singletonOld.pubDate)
        expectEqual(
            recomputedFeatures, singletonFeatures,
            "Recomputing pruned EventFeatures produces identical deterministic signals (#537)"
        )

        // 3. Corrupted SQLite fixture surfaces databaseHealthNotice without crashing (#536).
        let corruptPath = directory.appendingPathComponent("corrupt.sqlite3").path
        try Data("not a valid sqlite3 header at all - corrupted payload bytes".utf8).write(
            to: URL(fileURLWithPath: corruptPath))
        let corruptDB = DatabaseEngine(path: corruptPath)
        let corruptStore = ArticleStore(database: corruptDB, spotlightIndexer: MockSpotlightIndexer())
        await corruptStore.initialize()
        expectTrue(
            corruptStore.databaseHealthNotice != nil,
            "Corrupted database surfaces a user-visible health notice on ArticleStore (#536)"
        )
        await corruptDB.close()
    }

    @MainActor
    static func testReadOnlyLibraryRefresh() async throws {
        print("  - Testing a read-only library skips scheduled refreshes and explains a manual one (#787)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-readonly-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        // A readable library saved by a newer build opens read-only, and loads without any startup error.
        let seed = DatabaseEngine(path: path)
        try await seed.open()
        await seed.close()
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the seeded library")
        sqlite3_exec(handle, "PRAGMA user_version = \(DatabaseEngine.schemaVersion + 1);", nil, nil, nil)
        sqlite3_close(handle)
        let engine = DatabaseEngine(path: path)
        let store = ArticleStore(database: engine, spotlightIndexer: MockSpotlightIndexer())
        await store.waitForStartup()
        expectTrue(store.databaseHealthNotice != nil, "The newer library opens read-only with a notice")

        let suite = testDefaultsSuite("test.readonly.refresh")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        _ = settings.addFeed(url: "https://example.com/readonly.xml")
        let fetches = TestRecorder()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await fetches.record(urls)
                return urls.map { ($0, [], nil, nil) }
            })
        defer { manager.stopBackgroundWork() }

        expectTrue(store.operationError == nil, "A readable read-only library starts without an alert")
        await manager.fetchFeedsAsync(scheduled: true)
        expectEqual(await fetches.batches.count, 0, "A scheduled refresh downloads nothing while read-only")
        expectTrue(store.operationError == nil, "A scheduled refresh raises no alert while read-only")

        let refreshDialog = try await RefreshFeedsIntent(feedManager: manager).perform()
        expectTrue(
            NewsTests.extractDialogText(from: refreshDialog)?.contains("read-only") == true
                && NewsTests.extractDialogText(from: refreshDialog)?.contains(store.databaseHealthNotice ?? "?")
                    == true,
            "The Refresh Feeds shortcut reports the read-only library and its notice instead of success")
        await manager.fetchFeedsAsync()
        expectEqual(await fetches.batches.count, 0, "A manual refresh downloads nothing while read-only")
        expectTrue(
            store.operationError?.contains("read-only") == true
                && store.operationError?.contains(store.databaseHealthNotice ?? "?") == true,
            "A manual refresh says why, with the library's own notice")
        // Check for Updates (#992) refuses the same way and downloads nothing.
        let check = await manager.checkForUpdates(storyOf: "readonly-story")
        if case .refused(let reason) = check {
            expectTrue(reason.contains(store.databaseHealthNotice ?? "?"), "Check for Updates names the library notice")
        } else {
            expectTrue(false, "Check for Updates is refused while read-only, got \(check)")
        }
        expectEqual(await fetches.batches.count, 0, "Check for Updates downloads nothing while read-only")
        await engine.close()
    }

    static func testLibraryBackupAndFutureSchemaGuard() async throws {
        print("  - Testing the pre-migration backup and the newer-library guard (#746, #747)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func value(_ file: URL, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            expectEqual(
                sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK, "Inspect backup fixture")
            defer { sqlite3_close(handle) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        func files(_ prefix: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(prefix) }.sorted()
        }
        let current = String(DatabaseEngine.schemaVersion)
        let library = directory.appendingPathComponent("news.sqlite3")
        let creator = DatabaseEngine(path: library.path)
        try await creator.open()
        try await creator.upsertArticles(
            ["a", "b", "c"].map { name in
                FeedArticle(
                    storedID: "backup-\(name)", title: "Backup report \(name)",
                    link: "https://backup.test/\(name)", guid: "backup-guid-\(name)",
                    description: "Backup body \(name)", pubDate: Date(), source: "Backup Publisher")
            })
        await creator.close()
        expectEqual(value(library, "PRAGMA user_version;"), current, "A fresh library is written at schemaVersion")
        expectEqual(try files("news-before-"), [], "A fresh library is never backed up")
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(library.path, &handle), SQLITE_OK, "Open v25 backup fixture")
        expectEqual(
            sqlite3_exec(
                handle,
                "DROP INDEX idx_events_story; ALTER TABLE events DROP COLUMN story_id; PRAGMA user_version = 25;",
                nil, nil, nil), SQLITE_OK, "Reconstruct a v25 library")
        sqlite3_close(handle)

        // A backup that cannot be written leaves the library unmigrated and read-only.
        var holder: OpaquePointer?
        expectEqual(sqlite3_open(library.path, &holder), SQLITE_OK, "Hold the v25 fixture's WAL files open")
        expectEqual(
            sqlite3_exec(holder, "SELECT count(*) FROM articles;", nil, nil, nil), SQLITE_OK, "Read v25 fixture")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let blocked = DatabaseEngine(path: library.path)
        try await blocked.open()
        let blockedNotice = await blocked.databaseHealthNotice()
        await blocked.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        sqlite3_close(holder)
        expectTrue(blockedNotice?.contains("couldn't back up") == true, "A failed backup surfaces the health notice")
        expectEqual(value(library, "PRAGMA user_version;"), "25", "A failed backup stops the migration")

        // Two engines opening one v25 library together: one backup, one migration, no error.
        let race = directory.appendingPathComponent("race", isDirectory: true)
        try FileManager.default.createDirectory(at: race, withIntermediateDirectories: true)
        let raceLibrary = race.appendingPathComponent("news.sqlite3")
        try FileManager.default.copyItem(at: library, to: raceLibrary)
        let racers = [DatabaseEngine(path: raceLibrary.path), DatabaseEngine(path: raceLibrary.path)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for racer in racers { group.addTask { try await racer.open() } }
            try await group.waitForAll()
        }
        for racer in racers {
            let raceNotice = await racer.databaseHealthNotice()
            expectEqual(raceNotice, nil, "Both concurrent opens end writable")
            await racer.close()
        }
        expectEqual(value(raceLibrary, "PRAGMA user_version;"), current, "Concurrent opens migrate the library once")
        expectEqual(
            try FileManager.default.contentsOfDirectory(atPath: race.path).filter { $0.hasPrefix("news-before-") }
                .count,
            1, "Concurrent opens back the library up once")

        // Two older copies exist; the migration keeps the newer one and its own.
        for (name, age) in [
            ("news-before-v20-2026-01-01.sqlite3", 200.0), ("news-before-v21-2026-02-01.sqlite3", 100.0),
        ] {
            let url = directory.appendingPathComponent(name)
            try Data("old copy".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age * 86400)], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: library.path)
        let db = DatabaseEngine(path: library.path)
        try await db.open()
        let notice = await db.databaseHealthNotice()
        expectEqual(notice, nil, "A backed-up migration opens writable without a notice")
        expectEqual(value(library, "PRAGMA user_version;"), current, "The v25 library migrates to schemaVersion")
        expectEqual(try await db.fetchArticles(limit: nil).count, 3, "The migration keeps every article")
        // A write waits for another connection's lock instead of failing busy.
        var locker: OpaquePointer?
        expectEqual(sqlite3_open(library.path, &locker), SQLITE_OK, "Open a second connection")
        expectEqual(
            sqlite3_exec(locker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK, "A second connection takes the lock")
        nonisolated(unsafe) let held = locker
        // The lock stays held for a second, far longer than the write takes to reach SQLite; without the busy
        // timeout the write fails at once instead of waiting.
        let lockedAt = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            sqlite3_exec(held, "COMMIT;", nil, nil, nil)
            sqlite3_close(held)
        }
        try await db.markRead(articleId: "backup-a", isRead: true)
        let waited = Date().timeIntervalSince(lockedAt)
        expectTrue(waited >= 0.9, "A write waits for another connection's lock (waited \(waited) s)")
        expectTrue(try await db.isRead(articleId: "backup-a"), "A write waits out another connection's lock")
        await db.close()
        let backups = try files("news-before-")
        let day = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let backup = "news-before-v25-\(day).sqlite3"
        expectEqual(backups, ["news-before-v21-2026-02-01.sqlite3", backup], "Only the newest two backups are kept")
        let backupURL = directory.appendingPathComponent(backup)
        let backupMode = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? Int
        expectEqual(backupMode, 0o600, "The backup keeps the library's file permissions")
        expectEqual(value(backupURL, "PRAGMA user_version;"), "25", "The backup keeps the old schema version")
        expectEqual(value(backupURL, "SELECT count(*) FROM articles;"), "3", "The backup keeps every article")
        expectEqual(value(backupURL, "PRAGMA quick_check;"), "ok", "The backup is a sound database")
        expectEqual(try files(".news-before-"), [], "No partial backup is left behind")

        let reopened = DatabaseEngine(path: library.path)
        try await reopened.open()
        await reopened.close()
        expectEqual(try files("news-before-"), backups, "A current library opens without a new backup")

        // A library from a newer build opens read-only and stays byte-identical.
        let future = directory.appendingPathComponent("future.sqlite3")
        try FileManager.default.copyItem(at: library, to: future)
        expectEqual(sqlite3_open(future.path, &handle), SQLITE_OK, "Open future fixture")
        expectEqual(
            sqlite3_exec(handle, "PRAGMA user_version = \(DatabaseEngine.schemaVersion + 1);", nil, nil, nil),
            SQLITE_OK, "Reconstruct a library from a newer build")
        sqlite3_close(handle)
        let futureBytes = try Data(contentsOf: future)
        let sideFile = URL(fileURLWithPath: future.path + ".world-tension-v2.json")
        try Data("[]".utf8).write(to: sideFile)
        let newer = DatabaseEngine(path: future.path)
        try await newer.open()
        let futureNotice = await newer.databaseHealthNotice()
        expectTrue(futureNotice?.contains("newer version") == true, "A newer library surfaces the health notice")
        expectEqual(try await newer.fetchArticles(limit: nil).count, 3, "A newer library stays readable")
        do {
            try await newer.markRead(articleId: "backup-a", isRead: true)
            expectTrue(false, "A newer library refuses writes")
        } catch {}
        let reading = WorldTensionReading(
            evaluatedAt: Date(), inputHash: "", modelGeneration: "", headlines: [],
            assessment: WorldTensionAssessment(score: 1, summary: "", reasons: []))
        for (name, write) in [
            ("saving a World Tension reading", { _ = try await newer.saveWorldTensionReading(reading) }),
            ("clearing enrichment", { try await newer.clearArticleEnrichment() }),
            ("clearing the article cache", { try await newer.clearArticleCache() }),
            ("clearing the database cache", { try await newer.clearAllDatabaseCache() }),
        ] as [(String, () async throws -> Void)] {
            do {
                try await write()
                expectTrue(false, "A newer library refuses \(name)")
            } catch let error as CocoaError {
                expectEqual(error.code, .fileWriteVolumeReadOnly, "A newer library refuses \(name) as read-only")
            } catch {
                expectTrue(false, "A newer library refuses \(name) as read-only, not with \(error)")
            }
        }
        expectEqual(try Data(contentsOf: sideFile), Data("[]".utf8), "A newer library's side files stay untouched")
        await newer.close()
        expectEqual(try Data(contentsOf: future), futureBytes, "A newer library is never migrated or written")
        expectEqual(try files("future-before-"), [], "A newer library is never backed up")
    }

    @MainActor
    static func testLibraryBackupRestore() async throws {
        print("  - Testing library backup and restore (#563)...")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-restore-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("test.backup")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            removeTestDefaults(suite)
            try? fileManager.removeItem(at: directory)
        }
        func article(_ name: String) -> FeedArticle {
            FeedArticle(
                storedID: "restore-\(name)", title: "Restore report \(name)", link: "https://restore.test/\(name)",
                guid: "restore-guid-\(name)", description: "Restore body \(name)", pubDate: Date(),
                source: "Restore Publisher")
        }
        let library = directory.appendingPathComponent("news.sqlite3")
        let sideFile = URL(fileURLWithPath: library.path + ".world-tension-v2.json")
        let db = DatabaseEngine(path: library.path)
        try await db.open()
        try await db.upsertArticles([article("a"), article("b")])
        try await db.markRead(articleId: "restore-a", isRead: true)
        try await db.setSaved(articleId: "restore-b", isSaved: true)
        try Data("[\"before\"]".utf8).write(to: sideFile)
        defaults.set(["https://restore.test/feed"], forKey: AppSettings.feedURLsKey)
        defaults.set(["Tech"], forKey: AppSettings.userSectionsKey)
        defaults.set(["muted.test"], forKey: AppSettings.mutedSourcesKey)
        defaults.set(["https://restore.test/feed"], forKey: AppSettings.starredFeedURLsKey)
        defaults.set(["https://restore.test/feed": 1_700_000_000.0], forKey: AppSettings.starredFeedTimesKey)
        defaults.set(AppSettings.NotificationMode.minimal.rawValue, forKey: AppSettings.notificationModeKey)

        let archive = directory.appendingPathComponent("News Backup.sqlite3")
        try Data("an older file the reader chose to replace".utf8).write(to: archive)
        try await db.writeBackup(to: archive, settings: AppSettings.backupSettings(from: defaults))
        func permissions(_ file: URL) throws -> Int? {
            try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        }
        expectEqual(try permissions(archive), 0o600, "A backup is readable by its owner only")
        func value(_ file: URL, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            defer { sqlite3_close(handle) }
            guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }

        // A backup is never written over the live library, its WAL files, or a link to the library.
        let link = directory.appendingPathComponent("link.sqlite3")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: library)
        for destination in [library, URL(fileURLWithPath: library.path + "-wal"), link] {
            do {
                try await db.writeBackup(to: destination, settings: Data())
                expectTrue(false, "A backup over the library itself is refused (\(destination.lastPathComponent))")
            } catch {
                expectTrue(
                    error.localizedDescription.contains("library itself"),
                    "A backup over the library is refused with a plain message (\(destination.lastPathComponent))")
            }
        }
        try fileManager.removeItem(at: link)
        expectEqual(try await db.fetchArticles(limit: nil).count, 2, "A refused destination leaves the library intact")
        // A hard link is checked on a closed library: SQLite fails writes on an open file that gains a second link.
        let closedLibrary = directory.appendingPathComponent("closed.sqlite3")
        try fileManager.copyItem(at: archive, to: closedLibrary)
        let hardLink = directory.appendingPathComponent("hard-link.sqlite3")
        try fileManager.linkItem(at: closedLibrary, to: hardLink)
        do {
            try await DatabaseEngine(path: closedLibrary.path).writeBackup(to: hardLink, settings: Data())
            expectTrue(false, "A backup over a hard link to the library is refused")
        } catch {
            expectTrue(error.localizedDescription.contains("library itself"), "A hard link to the library is refused")
        }
        for file in [hardLink, closedLibrary] { try fileManager.removeItem(at: file) }

        // Everything changes after the backup.
        try await db.upsertArticles([article("c")])
        try await db.markRead(articleId: "restore-a", isRead: false)
        try await db.markRead(articleId: "restore-b", isRead: true)
        try await db.setSaved(articleId: "restore-b", isSaved: false)
        try Data("[\"after\"]".utf8).write(to: sideFile)
        defaults.set(["https://other.test/feed"], forKey: AppSettings.feedURLsKey)
        defaults.removeObject(forKey: AppSettings.userSectionsKey)
        defaults.set(true, forKey: AppSettings.allowInsecureHTTPKey)
        defaults.set(AppSettings.NotificationMode.full.rawValue, forKey: AppSettings.notificationModeKey)

        // A damaged file, a foreign file with an articles table this build can't migrate, and a backup from a newer build
        // are refused; the live library stays open and unchanged.
        let foreign = directory.appendingPathComponent("foreign.sqlite3")
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(foreign.path, &handle), SQLITE_OK, "Create the foreign fixture")
        expectEqual(
            sqlite3_exec(handle, "CREATE TABLE articles (headline TEXT);", nil, nil, nil), SQLITE_OK,
            "Give the foreign fixture an articles table with other columns")
        sqlite3_close(handle)
        let corrupt = directory.appendingPathComponent("corrupt.sqlite3")
        try Data(repeating: 0x5A, count: 8192).write(to: corrupt)
        // A real SQLite file with a valid header and a damaged b-tree: the articles table's root page header is
        // overwritten, so the file opens but fails integrity_check.
        let damagedPages = directory.appendingPathComponent("damaged-pages.sqlite3")
        var pages = try Data(contentsOf: archive)
        let rawPageSize = Int(pages[16]) << 8 | Int(pages[17])
        let pageSize = rawPageSize == 1 ? 65_536 : rawPageSize
        let root = Int(value(archive, "SELECT rootpage FROM sqlite_master WHERE name = 'articles';") ?? "") ?? 0
        expectTrue(root > 1, "The archive's articles table has a root page past the header")
        let offset = (root - 1) * pageSize
        pages.replaceSubrange(offset..<(offset + 12), with: Data(repeating: 0xFF, count: 12))
        try pages.write(to: damagedPages)
        expectTrue(
            value(damagedPages, "SELECT count(*) FROM sqlite_master;") != nil,
            "The damaged-page fixture still opens as SQLite")
        expectTrue(
            value(damagedPages, "PRAGMA integrity_check(1);") != "ok", "The damaged-page fixture fails integrity_check")
        let newer = directory.appendingPathComponent("newer.sqlite3")
        try fileManager.copyItem(at: archive, to: newer)
        expectEqual(sqlite3_open(newer.path, &handle), SQLITE_OK, "Open the newer-backup fixture")
        expectEqual(
            sqlite3_exec(handle, "PRAGMA user_version = \(DatabaseEngine.schemaVersion + 1);", nil, nil, nil),
            SQLITE_OK, "Mark the fixture as saved by a newer build")
        sqlite3_close(handle)
        let liveSymlink = directory.appendingPathComponent("symlink-to-live.sqlite3")
        try fileManager.createSymbolicLink(at: liveSymlink, withDestinationURL: library)
        for (name, file, message) in [
            ("damaged", corrupt, "damaged"), ("damaged-page", damagedPages, "damaged"),
            ("foreign", foreign, "damaged"), ("newer", newer, "newer version"),
            ("live", library, "News library itself"), ("live-symlink", liveSymlink, "News library itself"),
        ] {
            do {
                _ = try await db.restoreBackup(from: file)
                expectTrue(false, "A \(name) backup is refused")
            } catch {
                expectTrue(
                    error.localizedDescription.contains(message), "A \(name) backup is refused with a plain message")
            }
            expectEqual(
                try await db.fetchArticles(limit: nil).count, 3, "A refused \(name) backup leaves the library open")
        }
        expectTrue(try await db.isRead(articleId: "restore-b"), "A refused backup leaves read state alone")
        expectEqual(
            try Data(contentsOf: sideFile), Data("[\"after\"]".utf8), "A refused backup leaves side files alone")
        expectEqual(defaults.stringArray(forKey: AppSettings.feedURLsKey), ["https://other.test/feed"], "Settings kept")

        // A side file that can't be written stops the restore before the swap: the library stays open and unchanged.
        try fileManager.removeItem(at: sideFile)
        try fileManager.createDirectory(at: sideFile, withIntermediateDirectories: false)
        do {
            _ = try await db.restoreBackup(from: archive)
            expectTrue(false, "A restore whose side file can't be written fails")
        } catch {}
        expectEqual(try await db.fetchArticles(limit: nil).count, 3, "A failed side file leaves the library in place")
        try fileManager.removeItem(at: sideFile)
        try Data("[\"after\"]".utf8).write(to: sideFile)
        func keptCopies() throws -> [String] {
            try fileManager.contentsOfDirectory(atPath: directory.path).filter {
                $0.contains(".restoring") || ($0.hasPrefix("news-before-restore-") && $0.hasSuffix(".sqlite3"))
            }.sorted()
        }
        // The failed attempt's own kept copy is set aside so the pruning below starts from known copies.
        for name in try keptCopies() { try fileManager.removeItem(at: directory.appendingPathComponent(name)) }

        // The restore swaps the backup in, closes the library and hands back the settings. Two older copies of replaced libraries exist; the restore keeps the newer one and its own.
        for (name, age) in [
            ("news-before-restore-2026-01-01.sqlite3", 200.0), ("news-before-restore-2026-02-01.sqlite3", 100.0),
        ] {
            let url = directory.appendingPathComponent(name)
            try Data("old copy".utf8).write(to: url)
            try fileManager.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age * 86400)], ofItemAtPath: url.path)
        }
        let settings = try await db.restoreBackup(from: archive)
        try AppSettings.restoreSettings(settings ?? Data(), to: defaults)
        let afterFirst = try keptCopies()
        expectEqual(afterFirst.count, 2, "A restore keeps the replaced library and prunes to the newest two copies")
        expectEqual(afterFirst.first, "news-before-restore-2026-02-01.sqlite3", "Pruning keeps the newer old copy")
        let kept = directory.appendingPathComponent(afterFirst.last ?? "")
        let day = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        expectTrue(kept.lastPathComponent.hasPrefix("news-before-restore-\(day)-"), "The kept copy is time-stamped")
        expectEqual(try permissions(kept), 0o600, "The kept library is readable by its owner only")
        let undo = DatabaseEngine(path: kept.path)
        try await undo.open()
        expectEqual(
            try await undo.fetchArticles(limit: nil).count, 3, "The kept copy holds the replaced library, for undo")
        expectTrue(try await undo.isRead(articleId: "restore-b"), "The kept copy holds the replaced read state")
        await undo.close()
        let restored = DatabaseEngine(path: library.path)
        try await restored.open()
        let notice = await restored.databaseHealthNotice()
        expectEqual(notice, nil, "A restored library opens writable")
        expectEqual(
            Set(try await restored.fetchArticles(limit: nil).map(\.id)), ["restore-a", "restore-b"],
            "The restore brings back the backed-up stories")
        expectTrue(try await restored.isRead(articleId: "restore-a"), "The restore brings back read state")
        expectTrue(!(try await restored.isRead(articleId: "restore-b")), "The restore brings back unread state")
        expectTrue(try await restored.isSaved(articleId: "restore-b"), "The restore brings back saved state")
        await restored.close()
        expectEqual(try Data(contentsOf: sideFile), Data("[\"before\"]".utf8), "The restore brings back World Tension")
        expectEqual(sqlite3_open_v2(library.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK, "Inspect restore")
        expectEqual(
            sqlite3_exec(handle, "SELECT * FROM \(DatabaseEngine.backupExtrasTable);", nil, nil, nil) == SQLITE_OK,
            false, "The restored library doesn't keep the backup's extras table")
        sqlite3_close(handle)
        let reloaded = AppSettings(defaults: defaults)
        expectEqual(reloaded.feedURLs, ["https://restore.test/feed"], "The restore brings back subscriptions")
        expectEqual(reloaded.userSections, ["Tech"], "The restore brings back sections")
        expectEqual(reloaded.muteRules.sources, ["muted.test"], "The restore brings back mute rules")
        expectEqual(reloaded.starredFeedURLs, ["https://restore.test/feed"], "The restore brings back starred feeds")
        expectEqual(reloaded.notificationMode, .minimal, "The restore brings back the notification mode")
        expectEqual(reloaded.allowInsecureHTTP, false, "A setting the backup lacked returns to its default")

        // A second restore the same day keeps its own copy beside the first one instead of replacing it.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let again = DatabaseEngine(path: library.path)
        try await again.open()
        _ = try await again.restoreBackup(from: archive)
        let afterSecond = try keptCopies()
        expectEqual(afterSecond.count, 2, "Two restores in one day keep two copies")
        expectTrue(afterSecond.contains(kept.lastPathComponent), "The second restore keeps the first restore's copy")
        expectEqual(
            value(kept, "SELECT count(*) FROM articles;"), "3", "The first copy still holds the original library")
        let second = directory.appendingPathComponent(afterSecond.first { $0 != kept.lastPathComponent } ?? "")
        expectEqual(value(second, "SELECT count(*) FROM articles;"), "2", "The second copy holds the restored library")
    }

    static func testSQLiteFailuresAreNotEmptyResults() async throws {
        print("  - Testing that SQLite failures never read as empty results (#946)...")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-sqlite-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        func value(_ file: URL, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            defer { sqlite3_close(handle) }
            guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }

        // The file-level safety copy keeps commits that are still only in the write-ahead log.
        let walLibrary = directory.appendingPathComponent("wal.sqlite3")
        var writer: OpaquePointer?
        expectEqual(sqlite3_open(walLibrary.path, &writer), SQLITE_OK, "Open the WAL fixture")
        for sql in [
            "PRAGMA journal_mode = WAL;", "PRAGMA wal_autocheckpoint = 0;", "CREATE TABLE notes (body TEXT);",
            "INSERT INTO notes VALUES ('one'), ('two'), ('three');",
        ] {
            expectEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK, "WAL fixture: \(sql)")
        }
        let mainOnly = directory.appendingPathComponent("main-only.sqlite3")
        try fileManager.copyItem(at: walLibrary, to: mainOnly)
        expectTrue(
            value(mainOnly, "SELECT count(*) FROM notes;") == nil,
            "The fixture's commits are only in the log, so a main-file copy misses them")
        let kept = directory.appendingPathComponent("kept.sqlite3")
        try DatabaseEngine.copyLibraryFiles(of: walLibrary.path, to: kept)
        sqlite3_close(writer)
        expectEqual(value(kept, "SELECT count(*) FROM notes;"), "3", "The file-level copy keeps every commit")
        expectEqual(value(kept, "PRAGMA journal_mode;"), "delete", "The log is folded into one self-contained file")
        expectTrue(!fileManager.fileExists(atPath: kept.path + "-wal"), "No log is left beside a folded copy")

        // Stored overview data that doesn't decode is a cache miss, never an overview without its facts.
        let library = directory.appendingPathComponent("news.sqlite3")
        let db = DatabaseEngine(path: library.path)
        try await db.open()
        func article(_ name: String) -> FeedArticle {
            FeedArticle(
                storedID: "sqlite-\(name)", title: "SQLite report \(name)", link: "https://sqlite.test/\(name)",
                guid: "sqlite-guid-\(name)", description: "SQLite body \(name)", pubDate: Date(),
                source: "SQLite Publisher")
        }
        try await db.upsertArticles([article("a"), article("b")])
        try await db.setSaved(articleId: "sqlite-a", isSaved: true)
        guard
            case .created(let eventID) = try await db.applyEventMatch(
                "sqlite-a", .create(with: ["sqlite-b"]), matcherVersion: EventMatcher.version)
        else { return expectTrue(false, "Create the fixture event") }
        let version = try await db.fetchEvent(id: eventID)?.membershipVersion ?? 1
        let overview = EventOverviewDocument(
            eventID: eventID,
            version: OverviewVersionContext(membershipVersion: version, inputTextHash: "sqlite-input"),
            content: OverviewContent(title: "Overview", summary: "", facts: [], citations: []),
            provenance: OverviewProvenance(memberArticleIDs: ["sqlite-a", "sqlite-b"], kind: .fallbackExcerpts))
        expectTrue(try await db.recordEventOverview(overview), "Store the fixture overview")
        expectTrue(try await db.fetchEventOverview(eventID: eventID) != nil, "The stored overview reads back")
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(library.path, &handle), SQLITE_OK, "Open a second connection")
        sqlite3_busy_timeout(handle, 5000)
        expectEqual(
            sqlite3_exec(handle, "UPDATE event_overviews SET facts_json = 'not json';", nil, nil, nil), SQLITE_OK,
            "Damage the stored facts")
        expectTrue(
            try await db.fetchEventOverview(eventID: eventID) == nil, "Undecodable facts read as a cache miss")
        expectTrue(try await db.recordEventOverview(overview), "A rebuilt overview replaces the damaged row")
        expectTrue(try await db.fetchEventOverview(eventID: eventID) != nil, "The rebuilt overview reads back")

        // A restore is refused while another connection has the library open: its writes would be lost in the swap.
        let archive = directory.appendingPathComponent("backup.sqlite3")
        try await db.writeBackup(to: archive, settings: Data())
        var reader: OpaquePointer?
        expectEqual(sqlite3_open(library.path, &reader), SQLITE_OK, "Open another connection")
        expectEqual(
            sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM articles;", nil, nil, nil), SQLITE_OK,
            "Hold a read on the library")
        let edition = Data("{\"lanes\":[]}".utf8)
        try await db.storeTodayEdition(edition)
        do {
            _ = try await db.restoreBackup(from: archive)
            expectTrue(false, "A restore while another connection uses the library is refused")
        } catch {
            expectTrue(error.localizedDescription.contains("still in use"), "The refusal says the library is in use")
        }
        expectEqual(await db.storedTodayEdition(), edition, "A refused restore keeps the stored Today edition")
        sqlite3_exec(reader, "ROLLBACK;", nil, nil, nil)
        sqlite3_close(reader)
        expectTrue(
            try await db.isSaved(articleId: "sqlite-a"), "A refused restore leaves the library open and writable")
        try await db.setSaved(articleId: "sqlite-b", isSaved: true)

        // Remove All Saved is one statement: every saved story is unsaved, or none is.
        expectEqual(try await db.counts().saved, 2, "Two stories are saved before Remove All")
        try await db.removeAllSaved()
        expectEqual(try await db.counts().saved, 0, "Remove All unsaves every story")
        try await db.setSaved(articleId: "sqlite-a", isSaved: true)

        // Nothing cached survives a close: a library swapped in while closed reports its own counts.
        expectEqual(try await db.counts().saved, 1, "Counts are cached for the open library")
        await db.close()
        var swapper: OpaquePointer?
        expectEqual(sqlite3_open(library.path, &swapper), SQLITE_OK, "Open the closed library directly")
        expectEqual(
            sqlite3_exec(swapper, "UPDATE article_state SET is_saved = 1;", nil, nil, nil), SQLITE_OK,
            "Change the library while the engine is closed")
        sqlite3_close(swapper)
        try await db.open()
        expectEqual(try await db.counts().saved, 2, "A reopened library is counted afresh")

        // A query that fails throws instead of answering zero or false.
        expectTrue(try await db.isSaved(articleId: "sqlite-a"), "Saved state reads before the failure")
        expectEqual(
            sqlite3_exec(handle, "ALTER TABLE article_state RENAME TO article_state_hidden;", nil, nil, nil),
            SQLITE_OK, "Hide the state table from the engine")
        sqlite3_close(handle)
        for (name, read) in [
            ("isSaved", { _ = try await db.isSaved(articleId: "sqlite-a") }),
            ("isRead", { _ = try await db.isRead(articleId: "sqlite-a") }),
            ("counts", { _ = try await db.counts() }),
        ] as [(String, () async throws -> Void)] {
            do {
                try await read()
                expectTrue(false, "\(name) throws when its query fails")
            } catch {}
        }
        await db.close()
    }

    static func testDatabaseEnginePersistence() async {
        print("  - Testing DatabaseEngine Persistence & Conflict Resolution...")

        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()

            let art1 = FeedArticle(
                title: "Original Title",
                link: "https://example.com/item1",
                guid: "item-1",
                description: "Original description",
                pubDate: Date(timeIntervalSince1970: 1_700_000_000),
                source: "TechBlog",
                category: "Tech"
            )

            try await db.upsertArticles([art1], feedUrl: "https://example.com/feed.xml")

            // Mark read and saved
            try await db.markRead(articleId: art1.id, isRead: true)
            let isSaved = try await db.toggleSaved(articleId: art1.id)
            expectTrue(isSaved, "Article should now be saved")

            let fetched1 = try await db.fetchArticles()
            expectEqual(fetched1.count, 1, "Should fetch 1 article")
            expectEqual(fetched1[0].title, "Original Title", "Title should match")

            let isReadBefore = try await db.isRead(articleId: art1.id)
            expectTrue(isReadBefore, "Article should be read")

            // Re-ingest with updated title and enriched content
            var art1Updated = art1
            art1Updated.fullContent = "Detailed full content scraped from web"

            try await db.upsertArticles([art1Updated], feedUrl: "https://example.com/feed.xml")

            // Verify read state and saved state are STRICTLY PRESERVED after upsert conflict!
            let isReadAfter = try await db.isRead(articleId: art1.id)
            let isSavedAfter = try await db.isSaved(articleId: art1.id)
            expectTrue(isReadAfter, "Read status must be preserved after re-ingestion")
            expectTrue(isSavedAfter, "Saved status must be preserved after re-ingestion")

            let counts = try await db.counts()
            expectEqual(counts.total, 1, "Total count should be 1")
            expectEqual(counts.saved, 1, "Saved count should be 1")
            expectEqual(counts.unread, 0, "Unread count should be 0 because it was marked read")

            // Test batch operations with explicit transactions
            let art2 = FeedArticle(
                title: "Batch Article 2", link: "https://example.com/art2", guid: "g2", description: "",
                pubDate: Date(), source: "Test")
            let art3 = FeedArticle(
                title: "Batch Article 3", link: "https://example.com/art3", guid: "g3", description: "",
                pubDate: Date(), source: "Test")
            try await db.upsertArticles([art2, art3], feedUrl: "https://example.com/feed.xml")

            try await db.markReadBatch(articleIds: [art2.id, art3.id], isRead: true)
            expectTrue(try await db.isRead(articleId: art2.id), "art2 should be marked read via batch")
            expectTrue(try await db.isRead(articleId: art3.id), "art3 should be marked read via batch")

            try await db.batchMarkSaved([art2.id, art3.id])
            expectTrue(try await db.isSaved(articleId: art2.id), "art2 should be marked saved via batch")
            expectTrue(try await db.isSaved(articleId: art3.id), "art3 should be marked saved via batch")

            // Verify query-condition helpers and combined criteria in fetchArticles
            let queryArticle1 = FeedArticle(
                title: "Alpha Article",
                link: "https://example.com/alpha",
                guid: "alpha-guid",
                description: "Alpha desc",
                pubDate: Date(timeIntervalSince1970: 1_700_000_100),
                source: "SourceA",
                category: "Tech"
            )
            let queryArticle2 = FeedArticle(
                title: "Beta Article",
                link: "https://example.com/beta",
                guid: "beta-guid",
                description: "Beta desc",
                pubDate: Date(timeIntervalSince1970: 1_700_000_200),
                source: "SourceB",
                category: "General"
            )
            try await db.upsertArticles([queryArticle1, queryArticle2], feedUrl: "https://example.com/feed2.xml")

            // 1. ID filtering (preserves includingOriginals and parameter binding)
            let byID = try await db.fetchArticles(id: queryArticle1.id)
            expectEqual(byID.count, 1, "fetchArticles by ID should return exactly 1 article")
            expectEqual(byID.first?.id, queryArticle1.id, "ID filter returned correct article")

            let byIDWithOriginals = try await db.fetchArticles(
                id: queryArticle1.id, options: ArticleFetchOptions(includingOriginals: true))
            expectEqual(byIDWithOriginals.count, 1, "fetchArticles with includingOriginals: true returns article")

            let byNonexistentID = try await db.fetchArticles(id: "nonexistent-id")
            expectTrue(byNonexistentID.isEmpty, "Nonexistent ID returns empty results")

            // 2. Canonical URL filtering (handles unique canonical URLs and unmatched URLs)
            let byCanonical = try await db.fetchArticles(
                options: ArticleFetchOptions(canonicalURL: queryArticle2.normalizedLink))
            expectEqual(byCanonical.count, 1, "fetchArticles by canonicalURL returns matching article")
            expectEqual(byCanonical.first?.id, queryArticle2.id, "Canonical URL filter matched expected article")

            let byNonexistentCanonical = try await db.fetchArticles(
                options: ArticleFetchOptions(canonicalURL: "https://example.com/nonexistent"))
            expectTrue(byNonexistentCanonical.isEmpty, "Nonexistent canonical URL returns empty")

            // 3. Event filtering (binds event members and handles nonexistent event IDs)
            let storyEvent = try await db.createEvent(memberArticleIDs: [queryArticle1.id])
            let byEvent = try await db.fetchArticles(options: ArticleFetchOptions(eventID: storyEvent.id))
            expectEqual(byEvent.count, 1, "fetchArticles by eventID returns event members")
            expectEqual(byEvent.first?.id, queryArticle1.id, "fetchArticles by eventID matches queryArticle1")

            let byNonexistentEvent = try await db.fetchArticles(
                options: ArticleFetchOptions(eventID: "nonexistent-event"))
            expectTrue(byNonexistentEvent.isEmpty, "Nonexistent event ID returns empty")

            // 4. Publication window filtering (inclusive bounds and parameter typing)
            let windowBoth = try await db.fetchArticles(
                options: ArticleFetchOptions(
                    publicationWindow: Date(
                        timeIntervalSince1970: 1_700_000_050)...Date(timeIntervalSince1970: 1_700_000_250))
            )
            let windowBothIDs = Set(windowBoth.map(\.id))
            expectTrue(windowBothIDs.contains(queryArticle1.id), "Window includes queryArticle1")
            expectTrue(windowBothIDs.contains(queryArticle2.id), "Window includes queryArticle2")

            let windowUpperOnly = try await db.fetchArticles(
                options: ArticleFetchOptions(
                    publicationWindow: Date(
                        timeIntervalSince1970: 1_700_000_150)...Date(timeIntervalSince1970: 1_700_000_250))
            )
            let windowUpperIDs = Set(windowUpperOnly.map(\.id))
            expectFalse(windowUpperIDs.contains(queryArticle1.id), "Window excludes queryArticle1 before lowerBound")
            expectTrue(windowUpperIDs.contains(queryArticle2.id), "Window includes queryArticle2")

            // 5. Cursor filtering (preserves ordering conditions and excludes cursor article)
            let cursor = ArticleQueryCursor(queryArticle2)
            let afterCursor = try await db.fetchArticles(options: ArticleFetchOptions(after: cursor))
            expectTrue(
                afterCursor.allSatisfy { $0.id != queryArticle2.id }, "Cursor excludes the cursor article itself")

            // 6. Combined criteria (combining section, id, and publicationWindow)
            let combined = try await db.fetchArticles(
                section: "Tech",
                id: queryArticle1.id,
                options: ArticleFetchOptions(
                    publicationWindow: Date(
                        timeIntervalSince1970: 1_700_000_000)...Date(timeIntervalSince1970: 1_700_000_300))
            )
            expectEqual(combined.count, 1, "Combined criteria returns exact matching article")
            expectEqual(combined.first?.id, queryArticle1.id, "Combined criteria returned expected article")

            // Verify closed database contract
            let closedDB = DatabaseEngine(path: ":memory:")
            do {
                _ = try await closedDB.searchArticles(query: "")
                expectTrue(false, "searchArticles on closed db with empty query must throw")
            } catch {
                expectTrue(
                    error.localizedDescription.contains("Database not open"),
                    "Empty search throws Database not open on closed db")
            }
            do {
                _ = try await closedDB.searchArticles(query: "search term")
                expectTrue(false, "searchArticles on closed db with non-empty query must throw")
            } catch {
                expectTrue(
                    error.localizedDescription.contains("Database not open"),
                    "Non-empty search throws Database not open on closed db")
            }
            do {
                _ = try await closedDB.fetchArticles()
                expectTrue(false, "fetchArticles on closed db must throw")
            } catch {
                expectTrue(
                    error.localizedDescription.contains("Database not open"),
                    "fetchArticles throws Database not open on closed db")
            }
        } catch {
            expectTrue(false, "DatabaseEngine test failed: \(error.localizedDescription)")
        }
    }

    static func testFTS5SearchAndOperators() async {
        print("  - Testing FTS5 Full-Text Search & Operators...")

        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()

            let artA = FeedArticle(
                title: "Quantum Computing Leap Announced",
                link: "https://example.com/quantum",
                guid: "q-1",
                description: "Physicists achieve breakthrough in qubit coherence",
                pubDate: Date(timeIntervalSince1970: 1_700_001_000),
                source: "Nature",
                category: "Science"
            )
            let artB = FeedArticle(
                title: "Stock Markets Rally on Tech Surge",
                link: "https://example.com/market",
                guid: "m-1",
                description: "Wall Street gains led by semiconductor shares",
                pubDate: Date(timeIntervalSince1970: 1_700_002_000),
                source: "Bloomberg",
                category: "Business"
            )

            try await db.upsertArticles([artA, artB])

            expectEqual(
                try await db.searchArticles(query: "Bloomberg").map(\.id), [artB.id],
                "Plain search indexes publisher names as well as story text")
            expectEqual(
                try await db.searchArticles(query: "source:Bloomberg").map(\.id), [artB.id],
                "Publisher operator searches the source field")

            // Plain FTS match
            let search1 = try await db.searchArticles(query: "qubit")
            expectEqual(search1.count, 1, "Should find quantum article matching 'qubit'")
            expectEqual(search1[0].id, artA.id, "Matched article ID must match")

            let search2 = try await db.searchArticles(query: "shares")
            expectEqual(search2.count, 1, "Should find market article matching 'shares'")
            expectEqual(search2[0].id, artB.id, "Matched article ID must match")

            // Words match independently, with or without operators
            expectEqual(
                try await db.searchArticles(query: "qubit quantum").map(\.id), [artA.id],
                "Non-adjacent words match without operators")
            expectEqual(
                try await db.searchArticles(query: "qubit quantum is:unread").map(\.id), [artA.id],
                "Same words match with an operator")
            expectTrue(try await db.searchArticles(query: "qubit shares").isEmpty, "Every word must match")
            expectTrue(ArticleFilterQuery.parse("\"").terms.isEmpty, "A quote-only token is not a search term")
            expectEqual(
                try await db.searchArticles(query: "\"").count, 2,
                "A quote-only term is ignored instead of becoming an empty FTS5 phrase")
            expectEqual(
                try await db.searchArticles(query: "qubit \"\"").map(\.id), [artA.id],
                "An empty quoted term beside a real one is ignored")

            let adjacent = FeedArticle(
                title: "Cold Fusion research", link: "https://example.com/adjacent", guid: "adjacent",
                description: "A new experiment.", pubDate: Date(), source: "Science", category: "Science")
            let separated = FeedArticle(
                title: "A cold morning", link: "https://example.com/separated", guid: "separated",
                description: "The temperature dropped. Later, fusion researchers met.", pubDate: Date(),
                source: "Science")
            let splitFields = FeedArticle(
                title: "A cold", link: "https://example.com/fields", guid: "fields",
                description: "Fusion research", pubDate: Date(), source: "Science")
            let phrase = ArticleFilterQuery.parse(ArticleSearchState.entityQuery(for: "Cold Fusion"))
            expectTrue(
                phrase.matches(article: adjacent, isRead: false, isSaved: false), "Adjacent entity matches in memory")
            expectFalse(
                phrase.matches(article: separated, isRead: false, isSaved: false), "Separate sentences do not match")
            expectFalse(
                phrase.matches(article: splitFields, isRead: false, isSaved: false), "A phrase cannot span fields")
            let phraseDB = DatabaseEngine(path: ":memory:")
            try await phraseDB.open()
            try await phraseDB.upsertArticles([adjacent, separated])
            expectEqual(
                try await phraseDB.searchArticles(query: "\"Cold Fusion\"").map(\.id), [adjacent.id],
                "Entity phrase excludes words in separate sentences from FTS results")
            expectEqual(
                Set(try await phraseDB.searchArticles(query: "cold fusion").map(\.id)),
                Set([adjacent.id, separated.id]),
                "Unquoted terms still match independently")
            expectEqual(
                try await phraseDB.searchArticles(query: "\"Cold Fusion\" category:Science").map(\.id), [adjacent.id],
                "Phrase and operator work together")
            let wellness = FeedArticle(
                title: "Sleep study", link: "https://example.com/wellness", guid: "wellness",
                description: "Rest matters.", pubDate: Date(), source: "Clinic", category: "Health & Wellness")
            try await phraseDB.upsertArticles([wellness])
            let wellnessTag = ArticleSearchState.categoryToken(for: "Health & Wellness").expression
            expectTrue(
                ArticleFilterQuery.parse(wellnessTag).matches(article: wellness, isRead: false, isSaved: false),
                "A multiword category tag matches its story in memory")
            expectEqual(
                try await phraseDB.searchArticles(query: wellnessTag).map(\.id), [wellness.id],
                "A multiword category tag finds its story")
            // The reader shows a feed's "medical" as Health; the Health tag must still find that story.
            let medical = FeedArticle(
                title: "Clinic hours", link: "https://example.com/medical", guid: "medical",
                description: "Longer opening.", pubDate: Date(), source: "Clinic", category: "medical")
            try await phraseDB.upsertArticles([medical])
            let healthTag = ArticleSearchState.categoryToken(for: "Health").expression
            expectTrue(
                ArticleFilterQuery.parse(healthTag).matches(article: medical, isRead: false, isSaved: false),
                "A reader category tag matches the stored label it shows in memory")
            expectEqual(
                Set(try await phraseDB.searchArticles(query: healthTag).map(\.id)), [medical.id, wellness.id],
                "A reader category tag finds the story filed under a synonym")
            expectEqual(
                try await phraseDB.searchArticles(query: "category:medical").map(\.id), [medical.id],
                "A raw label still matches as typed")
            let longerWord = FeedArticle(
                title: "Cold Fusionary art", link: "https://example.com/fusionary", guid: "fusionary",
                description: "A gallery.", pubDate: Date(), source: "Arts")
            let hyphenated = FeedArticle(
                title: "Cold-fusion claims", link: "https://example.com/hyphen", guid: "hyphen",
                description: "A lab.", pubDate: Date(), source: "Science")
            expectFalse(
                phrase.matches(article: longerWord, isRead: false, isSaved: false),
                "A phrase matches whole words only, as FTS5 does")
            expectTrue(
                phrase.matches(article: hyphenated, isRead: false, isSaved: false),
                "A phrase spans punctuation between its words, as FTS5 does")
            await phraseDB.close()

            // Operator searches
            let searchSource = try await db.searchArticles(query: "source:Nature")
            expectEqual(searchSource.count, 1, "Should match source operator")

            let searchCategory = try await db.searchArticles(query: "category:Business")
            expectEqual(searchCategory.count, 1, "Should match category operator")

            // is:unread operator
            let searchUnread = try await db.searchArticles(query: "is:unread")
            expectEqual(searchUnread.count, 2, "Both articles should be unread initially")

            try await db.markRead(articleId: artA.id, isRead: true)
            let searchAfterRead = try await db.searchArticles(query: "is:read")
            expectEqual(searchAfterRead.count, 1, "Should find 1 read article")
            expectEqual(searchAfterRead[0].id, artA.id, "Read article ID should match")
            let guardian = FeedArticle(
                title: "Publisher search fixture", link: "https://www.theguardian.com/world/2026/oct/18/search-fixture",
                guid: "publisher-search", description: "Independent publisher report. Get our free app.",
                pubDate: Date(),
                source: "World news", category: "Health")
            _ = try await db.upsertArticles([guardian])
            expectEqual(
                try await db.searchArticles(query: "Guardian").map(\.id), [guardian.id],
                "Plain search finds the publisher name displayed on cards")
            expectEqual(
                try await db.searchArticles(query: "source:Guardian").map(\.id), [guardian.id],
                "Publisher filters use the canonical publisher name")

            expectFalse(
                try await db.fetchArticles(section: "Tech").contains { $0.id == guardian.id },
                "A free-app promotion cannot override a Health category")
            _ = try await db.updateEnrichment(articleId: guardian.id, update: .init(category: "Health"))
            var publisherRefresh = guardian
            publisherRefresh.category = "World"
            _ = try await db.upsertArticles([publisherRefresh])
            expectTrue(
                try await db.fetchArticles(section: "Health & Wellness").contains { $0.id == guardian.id },
                "Feed metadata cannot override the displayed classified category")
            expectEqual(
                try await db.searchArticles(query: "category:Health").map(\.id), [guardian.id],
                "Category search and section membership use the same stored classification")
            expectEqual(
                try await db.mutedArticleCount(section: "Health & Wellness", muting: MuteRules(topics: ["publisher"])),
                1, "Muted counts use the classified category without multiplying joined rows")
            let financialTimes = FeedArticle(
                storedID: "ft-publisher", title: "A section feed report",
                link: "https://www.ft.com/content/publisher-search-fixture", guid: "ft-publisher",
                description: "Publisher name is absent from the story text", pubDate: Date(), source: "World")
            _ = try await db.upsertArticles([financialTimes])
            for query in ["ft", "source:ft", "Financial Times"] {
                expectEqual(
                    try await db.searchArticles(query: query).map(\.id), [financialTimes.id],
                    "FT section feeds remain searchable by publisher: \(query)")
            }
            expectTrue(
                ArticleFilterQuery.parse("ft").matches(article: financialTimes, isRead: false, isSaved: false),
                "In-memory filters include displayed publisher names")
            expectTrue(
                ArticleFilterQuery.parse("source:ft").matches(article: financialTimes, isRead: false, isSaved: false),
                "In-memory publisher operators use the displayed name")
            let panelURL = TensionMethodology.v1.panel[8].url
            let panelOnly = FeedArticle(
                storedID: "panel-only", title: "Panel-only regional report", link: "https://example.com/panel-only",
                guid: "panel-only", description: "Stored for analysis", pubDate: Date(), source: "Panel")
            let shared = FeedArticle(
                storedID: "shared-subscription", title: "Report on two feeds",
                link: "https://example.com/shared-subscription", guid: "shared-subscription",
                description: "A subscribed report", pubDate: Date(), source: "Panel")
            _ = try await db.upsertArticles([panelOnly, shared], feedUrl: panelURL)
            _ = try await db.upsertArticles([shared], feedUrl: "https://example.com/subscribed.xml")
            await db.setCollectionOnlyFeedURLs([panelURL])
            let scoped = try await db.fetchArticles(limit: nil)
            expectFalse(
                scoped.contains { $0.id == panelOnly.id }, "Analysis-only feeds do not enter Today or section pages")
            expectTrue(scoped.contains { $0.id == shared.id }, "A report on a subscribed feed remains visible")
            expectTrue(
                try await db.searchArticles(query: "regional").isEmpty,
                "Analysis-only feeds stay out of ordinary search")
            expectEqual(try await db.counts().unread, 4, "Unread counts exclude the panel-only report")
            expectEqual(
                try await db.tensionCorpus(
                    day: DateInterval(start: Date().addingTimeInterval(-3600), duration: 7200), feedURLs: [panelURL]
                ).count, 2, "Tension retains analysis-only source evidence")
            try await db.setSaved(articleId: panelOnly.id, isSaved: true)
            expectTrue(
                try await db.fetchArticles(isSaved: true).contains { $0.id == panelOnly.id },
                "Saved panel reports remain accessible")
            expectTrue(
                try await db.searchArticles(query: "regional").contains { $0.id == panelOnly.id },
                "Saved panel reports remain searchable")

            let repairPath = FileManager.default.temporaryDirectory.appendingPathComponent(
                "news-topic-repair-\(UUID().uuidString).sqlite3"
            ).path
            defer { removeTemporaryLibrary(atPath: repairPath) }
            let legacyTopics = DatabaseEngine(path: repairPath)
            try await legacyTopics.open()
            let mislabeled = FeedArticle(
                storedID: "old-topic", title: "Dubai GDP rises as trade expands",
                link: "https://www.theguardian.com/business/2026/oct/18/topic-fixture", guid: "old-topic",
                description: "Officials said the economy grew.", pubDate: Date(), source: "World news",
                fullContent: "Preserved publisher text", category: "Technology")
            _ = try await legacyTopics.upsertArticles([mislabeled])
            try await legacyTopics.markRead(articleId: mislabeled.id, isRead: true)
            try await legacyTopics.setSaved(articleId: mislabeled.id, isSaved: true)
            await legacyTopics.close()
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(repairPath, &handle), SQLITE_OK, "Open copied legacy topic fixture")
            expectEqual(
                sqlite3_exec(
                    handle,
                    "UPDATE articles SET source='World news'; UPDATE article_enrichment SET category='Technology'; PRAGMA user_version=21;",
                    nil, nil, nil), SQLITE_OK, "Seed the old generated category and publisher label")
            sqlite3_close(handle)
            let repaired = DatabaseEngine(path: repairPath)
            try await repaired.open()
            let fixed = try await repaired.fetchArticles(limit: 1, id: mislabeled.id).first
            expectEqual(fixed?.category, "Business", "The migration repairs stored substring misclassifications")
            expectEqual(fixed?.fullContent, mislabeled.fullContent, "Topic repair preserves publisher text")
            expectTrue(try await repaired.isRead(articleId: mislabeled.id), "Topic repair preserves read history")
            expectTrue(try await repaired.isSaved(articleId: mislabeled.id), "Topic repair preserves saved stories")
            expectEqual(
                try await repaired.searchArticles(query: "Guardian").count, 1,
                "Migration repairs the publisher search index")
            await repaired.close()

        } catch {
            expectTrue(false, "FTS5 test failed: \(error.localizedDescription)")
        }
    }

    static func testArticleRetentionPolicy() async {
        print("  - Testing Article Retention Policy...")

        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()

            let oldDate = Date(timeIntervalSinceNow: -40 * 86400)  // 40 days old
            let recentDate = Date(timeIntervalSinceNow: -5 * 86400)  // 5 days old

            // 1. Old read article (should be pruned)
            let oldRead = FeedArticle(
                title: "Old Read Article",
                link: "https://example.com/old-read",
                guid: "old-read-1",
                description: "Old read story",
                pubDate: oldDate,
                source: "Source"
            )
            // 2. Old unread article (must NEVER be pruned)
            let oldUnread = FeedArticle(
                title: "Old Unread Article",
                link: "https://example.com/old-unread",
                guid: "old-unread-1",
                description: "Old unread story",
                pubDate: oldDate,
                source: "Source"
            )
            // 3. Old saved article (must NEVER be pruned)
            let oldSaved = FeedArticle(
                title: "Old Saved Article",
                link: "https://example.com/old-saved",
                guid: "old-saved-1",
                description: "Old saved story",
                pubDate: oldDate,
                source: "Source"
            )
            // 4. Recent read article (should NOT be pruned, under 30 days)
            let recentRead = FeedArticle(
                title: "Recent Read Article",
                link: "https://example.com/recent-read",
                guid: "recent-read-1",
                description: "Recent read story",
                pubDate: recentDate,
                source: "Source"
            )

            try await db.upsertArticles([oldRead, oldUnread, oldSaved, recentRead])

            try await db.markRead(articleId: oldRead.id, isRead: true)
            try await db.markRead(articleId: oldSaved.id, isRead: true)
            _ = try await db.toggleSaved(articleId: oldSaved.id)
            try await db.markRead(articleId: recentRead.id, isRead: true)

            // Run pruning with 30-day retention
            let prunedCount = try await db.pruneOldArticles(keepReadDays: 30)
            expectEqual(prunedCount, 1, "Only the old read article should be pruned")

            let remaining = try await db.fetchArticles()
            expectEqual(remaining.count, 3, "3 articles should remain in database")

            let ids = remaining.map { $0.id }
            expectFalse(ids.contains(oldRead.id), "Old read article must be removed")
            expectTrue(ids.contains(oldUnread.id), "Old unread article must remain")
            expectTrue(ids.contains(oldSaved.id), "Old saved article must remain")
            expectTrue(ids.contains(recentRead.id), "Recent read article must remain")
        } catch {
            expectTrue(false, "Retention test failed: \(error.localizedDescription)")
        }
    }

    /// Highlights and notes: storage, FTS5, VACUUM, retention, cascade and the store's revision counter (#711).
    @MainActor static func testUserNotesStorageAndFTS() async throws {
        print("  - Testing highlights and notes: storage, FTS5, VACUUM, retention and cascade (#711)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        try await database.open()
        expectEqual(
            try await database.storedSchemaVersion(), DatabaseEngine.schemaVersion,
            "The library migrates to the current schema")

        // Rows of the index itself: a listing joins the notes table and would hide a row a trigger left behind.
        /// How many index rows match the word.
        func indexRows(_ word: String) async throws -> Int {
            Int(
                try await database.eventRows(
                    "SELECT count(*) FROM user_notes_fts WHERE user_notes_fts MATCH ?;", [.text(word)]
                )
                .first?.first.flatMap { $0 } ?? "") ?? -1
        }
        /// Runs FTS5's integrity check of the note index against the notes.
        func checkIndex(_ moment: String) async throws {
            do {
                try await database.eventRows(
                    "INSERT INTO user_notes_fts(user_notes_fts, rank) VALUES ('integrity-check', 1);")
            } catch { expectTrue(false, "The note index matches the notes \(moment)") }
        }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let first = FeedArticle(
            title: "Superconductor claim tested", link: "https://example.com/sc", guid: "note-1",
            description: "Lab replicates zero resistance", pubDate: old, source: "Physics Daily")
        let second = FeedArticle(
            title: "Quantum chip benchmark", link: "https://example.com/qc", guid: "note-2",
            description: "A chip with fault-tolerant qubits", pubDate: old, source: "Quantum Review")
        _ = try await database.upsertArticles([first, second])
        let paragraphs = ["The lab replicates zero resistance at ambient pressure.", "Reviewers want a second lab."]
        /// A note on `quote` in the fixture paragraphs.
        func note(_ article: FeedArticle, _ index: Int, _ start: Int, _ quote: String, body: String = "") -> UserNote {
            NoteAnchor.note(
                articleID: article.id, paragraphs: paragraphs, index: index, start: start, quote: quote, body: body)
        }
        let resistance = note(first, 0, 19, "zero resistance", body: "Follow up with the authors")
        let reviewers = note(first, 1, 0, "Reviewers want")
        let chip = note(second, 0, 4, "lab replicates", body: "Hardware roadmap")
        try await database.saveNotes([chip, reviewers, resistance])

        expectEqual(
            try await database.fetchNotes(for: first.id).map(\.id), [resistance.id, reviewers.id],
            "A story's notes come in reading order")
        let stored = try await database.fetchNotes(for: first.id).first
        expectEqual(
            [stored?.selectedText, stored?.prefix, stored?.suffix, stored?.noteBody],
            [resistance.selectedText, resistance.prefix, resistance.suffix, resistance.noteBody],
            "A note reads back as it was saved")
        expectEqual(
            [stored?.paragraphIndex, stored?.charStart], [0, 19], "With the place it had")
        expectEqual(try await database.noteListings().count, 3, "The Library lists every note")
        expectEqual(
            try await database.noteListings().first?.articleTitle, "Quantum chip benchmark",
            "The newest note is first and names its story")

        expectEqual(
            try await database.noteListings(matching: "resist").map(\.note.id), [resistance.id],
            "FTS5 finds a quote by a word prefix")
        expectEqual(
            try await database.noteListings(matching: "roadmap").map(\.note.id), [chip.id],
            "FTS5 finds a note by its text")
        expectEqual(
            try await database.noteListings(matching: "\"unbalanced (").count, 0,
            "Typed punctuation cannot break a search")

        var edited = resistance
        edited.noteBody = "Confirmed by an independent lab"
        try await database.saveNotes([edited])
        expectEqual(try await database.noteListings(matching: "independent").count, 1, "An edit is searchable")
        expectEqual(try await database.noteListings(matching: "authors").count, 0, "The replaced text is not")
        expectEqual(
            try await database.fetchNotes(for: first.id).count, 2, "Saving the same note again does not copy it")

        // The index survives a rebuild of the file (the hidden rowid of a TEXT-keyed table may change on VACUUM).
        try await database.deleteNote(id: reviewers.id)
        try await database.executeSimple("VACUUM;")
        expectEqual(
            try await database.noteListings(matching: "independent").map(\.note.id), [resistance.id],
            "FTS5 still finds the note after VACUUM")
        expectEqual(try await indexRows("reviewers"), 0, "A deleted note leaves the index")
        expectEqual(try await indexRows("independent"), 1, "The index holds the edited text once")
        try await checkIndex("after VACUUM")

        // The store reloads its readers through one revision counter.
        let store = ArticleStore(database: database)
        let revision = store.userNotesRevision
        let storeNote = UserNote(
            articleID: second.id, paragraphIndex: 0, charStart: 0, selectedText: "A chip", prefix: "", suffix: " with")
        expectTrue(await store.saveNotes([storeNote]), "The store saves a note")
        expectEqual(store.userNotesRevision, revision + 1, "Saving bumps the revision")
        expectEqual(await store.notes(for: second.id).count, 2, "The store reads a story's notes")
        expectEqual(await store.noteListings(matching: "chip").count, 1, "The store searches notes")
        expectTrue(await store.deleteNote(id: storeNote.id), "The store deletes a note")
        expectEqual(store.userNotesRevision, revision + 2, "Deleting bumps the revision")

        // Retention keeps a read story that has a note; another read story of the same age goes (#711).
        try await database.markReadBatch(articleIds: [first.id, second.id], isRead: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await database.executeSimple("DELETE FROM user_notes WHERE id = '\(chip.id)';")
        expectEqual(try await database.pruneOldArticles(keepReadDays: 30, now: now), 1, "One old read story is pruned")
        expectEqual(try await database.fetchArticles(id: first.id).count, 1, "The story with a note is kept")
        expectEqual(try await database.fetchNotes(for: first.id).count, 1, "Its note is kept")

        // Deleting a story deletes its notes and their index rows.
        try await database.executeSimple("DELETE FROM articles WHERE id = '\(first.id)';")
        expectEqual(try await database.fetchNotes(for: first.id).count, 0, "Deleting a story deletes its notes")
        expectEqual(try await indexRows("independent"), 0, "And their index rows")
        try await checkIndex("after the cascade")
    }

    /// The text kept for publisher updates: the chain, the summary-only and title-only cases, the size limit, the cache purge and the schema 30 migration (#712).
    static func testPublisherRevisionTextStorage() async throws {
        print("  - Testing the text kept for publisher updates, its limits and its migration (#712)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-revision-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        /// Runs SQL on the fixture file outside the engine.
        func execute(_ sql: String) {
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the revision fixture")
            defer { sqlite3_close(handle) }
            expectEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Run \(sql.prefix(40))")
        }
        let db = DatabaseEngine(path: path)
        try await db.open()
        let article = FeedArticle(
            storedID: "evolving", title: "Bus hits bridge", link: "https://example.com/evolving", guid: "evolving",
            description: "A bus hit a bridge.", pubDate: Date(), source: "Harbor News")
        _ = try await db.upsertArticles([article])
        let saved = FeedArticle(
            storedID: "kept", title: "Kept story", link: "https://example.com/kept", guid: "kept",
            description: "Kept summary.", pubDate: Date(), source: "Harbor News")
        _ = try await db.upsertArticles([saved])
        try await db.setSaved(articleId: saved.id, isSaved: true)

        /// A story's stored revisions, newest first.
        func revisions(_ id: String = "evolving") async throws -> [PublisherContentRevision] {
            try await db.publisherContentRevisions(for: id)
        }
        expectEqual(try await revisions().first?.previousText, nil, "A first sight keeps no text")
        let one = "The bus hit the rail on Monday. Police closed the road."
        let two = one + " The driver was taken to hospital."
        let three = "The bus hit the rail on Monday. The road reopened. The driver was taken to hospital."
        try await db.updateEnrichment(articleId: article.id, update: .init(content: one))
        expectEqual(try await revisions().first?.kind, .extraction, "The first body is an extraction")
        expectEqual(try await revisions().first?.previousText, nil, "An extraction keeps no text")
        try await db.updateEnrichment(articleId: article.id, update: .init(content: two))
        try await db.updateEnrichment(articleId: article.id, update: .init(content: three))
        let chain = try await revisions().filter { $0.kind == .publisherUpdate }
        expectEqual(chain.map(\.previousText), [two, one], "Each update keeps the text it replaced, newest first")

        // A summary-only story compares summaries; a title-only change replaces no text.
        let summaryOnly = FeedArticle(
            storedID: "summary", title: "Summary story", link: "https://example.com/summary", guid: "summary",
            description: "Before.", pubDate: Date(), source: "Harbor News")
        _ = try await db.upsertArticles([summaryOnly])
        let changed = FeedArticle(
            storedID: "summary", title: "Summary story", link: summaryOnly.link, guid: "summary",
            description: "After.", pubDate: summaryOnly.pubDate, source: "Harbor News")
        _ = try await db.upsertArticles([changed])
        expectEqual(
            try await revisions("summary").first?.previousText, "Before.", "Summaries are compared without a body")
        let retitled = FeedArticle(
            storedID: "summary", title: "Summary story, updated", link: summaryOnly.link, guid: "summary",
            description: "After.", pubDate: summaryOnly.pubDate, source: "Harbor News")
        _ = try await db.upsertArticles([retitled])
        let titleOnly = try await revisions("summary").first
        expectEqual(titleOnly?.kind, .publisherUpdate, "A new headline is an update")
        expectEqual(titleOnly?.previousText, nil, "But it replaced no text, so none is kept")

        // A text too long to keep whole is not kept: a cut text would show invented changes.
        let huge = String(repeating: "A long sentence about the bridge. ", count: 1_600)
        try await db.updateEnrichment(articleId: article.id, update: .init(content: huge))
        try await db.updateEnrichment(articleId: article.id, update: .init(content: huge + " More."))
        let hugeRevisions = try await revisions()
        expectEqual(hugeRevisions[1].previousText, three, "The update that replaced a short text keeps it")
        expectEqual(hugeRevisions[0].previousText, nil, "An over-limit text is not kept")

        // Clear Article Cache removes the kept text of stories whose bodies it clears, not of saved ones.
        try await db.updateEnrichment(articleId: saved.id, update: .init(content: "Saved body one."))
        try await db.updateEnrichment(articleId: saved.id, update: .init(content: "Saved body two."))
        try await db.clearArticleCache()
        expectTrue(
            try await revisions().allSatisfy { $0.previousText == nil }, "A cache purge drops the text it kept")
        expectEqual(try await revisions("kept").first?.previousText, "Saved body one.", "A saved story keeps its text")
        await db.close()

        // A library at schema 30 (no column, the v16 triggers) migrates: rows stay, new updates keep text.
        execute(
            """
            DROP TRIGGER trg_publisher_content_insert; DROP TRIGGER trg_publisher_content_update;
            ALTER TABLE publisher_content_revisions DROP COLUMN previous_text;
            CREATE TRIGGER trg_publisher_content_insert AFTER INSERT ON articles BEGIN
                INSERT INTO publisher_content_revisions VALUES (new.id, 1, new.created_at, 'snapshot', 0,
                    news_publisher_input(new.title, coalesce(new.description, ''), new.content));
            END;
            CREATE TRIGGER trg_publisher_content_update AFTER UPDATE OF title, description, content ON articles
            WHEN old.title IS NOT new.title OR old.description IS NOT new.description OR old.content IS NOT new.content
            BEGIN
                UPDATE article_enrichment SET summary = NULL, key_points = NULL, sentiment = NULL,
                    entities = NULL, topics = NULL, category = NULL, confidence = NULL,
                    model_identifier = NULL, analysis_version = NULL, input_content_version = NULL, input_text_hash = NULL
                    WHERE article_id = new.id;
                DELETE FROM event_overviews WHERE event_id IN (SELECT event_id FROM event_members WHERE article_id = new.id)
                    OR id IN (SELECT overview_id FROM event_overview_citations WHERE article_id = new.id);
                INSERT INTO publisher_content_revisions
                SELECT new.id, coalesce(max(version), 0) + 1, new.updated_at,
                    CASE WHEN old.title IS NOT new.title OR old.description IS NOT new.description OR coalesce(old.content, '') != ''
                         THEN 'publisher_update' ELSE 'extraction' END,
                    (old.title IS NOT new.title) + 2 * (old.description IS NOT new.description) + 4 * (old.content IS NOT new.content),
                    news_publisher_input(new.title, coalesce(new.description, ''), new.content)
                FROM publisher_content_revisions WHERE article_id = new.id
                HAVING old.title IS NOT new.title OR old.description IS NOT new.description OR new.content IS NOT NULL;
                DELETE FROM publisher_content_revisions WHERE article_id = new.id AND version <
                    (SELECT max(version) - 19 FROM publisher_content_revisions WHERE article_id = new.id);
            END;
            PRAGMA user_version = 30;
            """)
        let migrated = DatabaseEngine(path: path)
        try await migrated.open()
        expectEqual(
            try await migrated.storedSchemaVersion(), DatabaseEngine.schemaVersion,
            "A schema 30 library migrates to the current schema")
        expectEqual(
            try await migrated.publisherContentRevisions(for: article.id).count, hugeRevisions.count,
            "Revisions survive the migration")
        expectTrue(
            try await migrated.publisherContentRevisions(for: article.id).allSatisfy { $0.previousText == nil },
            "Earlier revisions have no text")
        try await migrated.updateEnrichment(articleId: article.id, update: .init(content: three))
        try await migrated.updateEnrichment(articleId: article.id, update: .init(content: two))
        expectEqual(
            try await migrated.publisherContentRevisions(for: article.id).first?.previousText, three,
            "Updates after the migration keep the text they replace")
        await migrated.close()
    }

    static func testGranularCacheClearingAndRetention() async throws {
        print("  - Testing Granular Cache Purging (Selective Deletes & Feed Preservation)...")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }

        // 1. Populate feeds and articles
        let testFeed = "https://example.com/tech.xml"
        let article1 = FeedArticle(
            title: "Article One", link: "https://example.com/1", guid: "art-1", description: "Desc 1", pubDate: Date(),
            source: "Test Feed", fullContent: "Content One")
        let article2 = FeedArticle(
            title: "Article Two", link: "https://example.com/2", guid: "art-2", description: "Desc 2", pubDate: Date(),
            source: "Test Feed", fullContent: "Content Two")

        try await db.upsertArticles([article1, article2], feedUrl: testFeed)
        _ = try await db.toggleSaved(articleId: article1.id)  // article1 is saved!

        // Save AI enrichment for both
        let analysis = ArticleAnalysis(
            summary: "Summary text", keyPoints: ["Point 1", "Point 2"], entities: [], category: "Technology",
            sentiment: nil, modelIdentifier: "test", analysisVersion: 1)
        try await db.saveArticleAnalysis(analysis, for: article1.id)
        try await db.saveArticleAnalysis(analysis, for: article2.id)

        // Verify initial state
        let initialAnalysis1 = await db.fetchArticleAnalysis(for: article1.id)
        expectTrue(initialAnalysis1 != nil, "Article 1 should have analysis")
        let initialAnalysis2 = await db.fetchArticleAnalysis(for: article2.id)
        expectTrue(initialAnalysis2 != nil, "Article 2 should have analysis")

        try await db.upsertArticleEmbeddings([article2.id: [0.5, 0.25]], modelVersion: 1)
        let event = try await db.createEvent(memberArticleIDs: [article2.id])
        _ = try await db.recordEventOverview(
            EventOverviewDocument(
                eventID: event.id,
                version: OverviewVersionContext(membershipVersion: event.membershipVersion, inputTextHash: "hash"),
                content: OverviewContent(
                    title: "Event", summary: "Summary",
                    citations: [
                        OverviewCitation(
                            id: "citation", articleID: article2.id, passageID: "p", passageFingerprint: "f",
                            quote: "Quote")
                    ])))

        // 2. Test clearArticleEnrichment(): clears AI analysis, overviews and embeddings, keeps articles and events
        try await db.clearArticleEnrichment()
        let clearedAnalysis1 = await db.fetchArticleAnalysis(for: article1.id)
        expectTrue(clearedAnalysis1 == nil, "Article 1 enrichment must be purged")
        let clearedAnalysis2 = await db.fetchArticleAnalysis(for: article2.id)
        expectTrue(clearedAnalysis2 == nil, "Article 2 enrichment must be purged")
        expectTrue(
            try await db.fetchArticleEmbeddings(articleIDs: [article2.id], modelVersion: 1).isEmpty,
            "Clearing AI analysis removes story embeddings")
        expectTrue(try await db.fetchEventOverview(eventID: event.id) == nil, "Clearing AI analysis removes overviews")
        expectTrue(try await db.fetchEvent(id: event.id) != nil, "Events themselves are kept")

        let articlesAfterEnrichmentClear = try await db.fetchArticles(limit: 10)
        expectEqual(articlesAfterEnrichmentClear.count, 2, "Articles must remain intact after enrichment purge")

        // 3. Test clearArticleCache(): clears non-saved article bodies, keeps saved stories intact
        let genBeforeContentClear = await db.analysisGeneration
        try await db.clearArticleCache()
        expectEqual(
            await db.analysisGeneration, genBeforeContentClear + 1,
            "Clearing article text bumps analysis generation (#886)")
        let articlesAfterContentClear = try await db.fetchArticles(limit: 10)
        let savedArticle = articlesAfterContentClear.first { $0.id == article1.id }
        expectEqual(savedArticle?.fullContent, "Content One", "Saved article content must NOT be cleared")
        let unsavedArticle = articlesAfterContentClear.first { $0.id == article2.id }
        expectTrue(unsavedArticle?.fullContent == nil, "Non-saved article content must be set to nil")

        // Cache cleanup must not delete user history.
        try await db.markRead(articleId: article2.id, isRead: true)
        try await db.clearAllDatabaseCache()
        let remainingArticles = try await db.fetchArticles(limit: 10)
        expectEqual(remainingArticles.count, 2, "Cache cleanup must preserve article headers and history")
        expectEqual(
            remainingArticles.first(where: { $0.id == article1.id })?.fullContent, "Content One",
            "Saved body survives cache cleanup")
        expectTrue(try await db.getReadArticleIDs().contains(article2.id), "Read history survives cache cleanup")

        // Clear All Caches removes everything Clear Analysis removes (#811)
        try await db.upsertArticleEmbeddings([article2.id: [0.5, 0.25]], modelVersion: 1)
        try await db.upsertArticleFeatures(
            [article2.id: EventFeatures(title: article2.title, description: "", date: Date(timeIntervalSince1970: 0))],
            version: EventFeatures.storageVersion)
        try await db.upsertPairDecisions(
            [
                DatabaseEngine.PairDecision(
                    articleID: article1.id, otherArticleID: article2.id, decision: "related-act",
                    reason: "differentAct", score: 0.4, features: #"{"cosine":0.7}"#)
            ], matcherVersion: EventMatcher.version)
        _ = try await db.recordEventOverview(
            EventOverviewDocument(
                eventID: event.id,
                version: OverviewVersionContext(membershipVersion: event.membershipVersion, inputTextHash: "hash"),
                content: OverviewContent(
                    title: "Event", summary: "Summary",
                    citations: [
                        OverviewCitation(
                            id: "citation", articleID: article2.id, passageID: "p", passageFingerprint: "f",
                            quote: "Quote")
                    ])))
        try await db.clearAllDatabaseCache()
        expectTrue(
            try await db.fetchArticleEmbeddings(articleIDs: [article2.id], modelVersion: 1).isEmpty,
            "Clear All Caches removes story embeddings (#811)")
        expectTrue(
            try await db.fetchArticleFeatures(articleIDs: [article2.id], version: EventFeatures.storageVersion).isEmpty,
            "Clear All Caches removes matcher features (#811)")
        let pairRows = try await db.eventRows("SELECT features FROM pair_assessments;")
        expectEqual(pairRows.count, 1, "Clear All Caches keeps the pair decision (#811)")
        expectTrue(
            (pairRows.first?.first ?? nil) == nil, "Clear All Caches clears the pair decision's features (#811)")
        expectTrue(
            try await db.fetchEventOverview(eventID: event.id) == nil, "Clear All Caches removes overviews (#811)")

        // 5. Test CacheManager methods
        // Do not clear the user's WebKit cache from a unit test.
    }

    static func testWorldTensionBackupAndRestoreSafety() async throws {
        print("  - Testing World Tension backup and restore safety (#1203)...")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-tension-safe-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let library = directory.appendingPathComponent("news.sqlite3")
        let sideFile = URL(fileURLWithPath: library.path + ".world-tension-v2.json")
        let db = DatabaseEngine(path: library.path)
        try await db.open()

        // 1. Unreadable side file at backup time fails the backup cleanly (#1203).
        try fileManager.createDirectory(at: sideFile, withIntermediateDirectories: false)
        let archive = directory.appendingPathComponent("backup.sqlite3")
        var backupFailed = false
        do {
            try await db.writeBackup(to: archive, settings: Data())
        } catch {
            backupFailed = true
        }
        expectTrue(backupFailed, "Backup fails cleanly when the side file exists but cannot be read as data")
        try fileManager.removeItem(at: sideFile)

        // 2. Restoring a backup without tension entry keeps current local tension (#1203).
        try Data("[\"local-history\"]".utf8).write(to: sideFile)
        let cleanArchive = directory.appendingPathComponent("clean-backup.sqlite3")
        let emptyDb = DatabaseEngine(path: directory.appendingPathComponent("empty.sqlite3").path)
        try await emptyDb.open()
        try await emptyDb.writeBackup(to: cleanArchive, settings: Data())
        await emptyDb.close()

        _ = try await db.restoreBackup(from: cleanArchive)
        expectEqual(
            try Data(contentsOf: sideFile), Data("[\"local-history\"]".utf8),
            "Restoring a backup without tension entry preserves existing local history")
    }

    @MainActor
    static func testPruneResilienceWhenVacuumFails() async throws {
        print("  - Testing prune resilience when incremental vacuum fails (#1204)...")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-prune-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("prune.sqlite3").path
        let db = DatabaseEngine(path: dbPath)
        try await db.open()
        let store = ArticleStore(database: db)
        await store.initialize()

        let now = Date()
        let oldDate = now.addingTimeInterval(-40 * 86400)
        let oldArticle = FeedArticle(
            storedID: "old-1", title: "Old report", link: "https://test.com/old",
            guid: "old-1", description: "desc", pubDate: oldDate, source: "Source")
        try await db.upsertArticles([oldArticle])
        try await db.markRead(articleId: "old-1", isRead: true)

        await store.refreshState()
        expectEqual(store.articles.count, 1, "Store has 1 article before prune")

        // Set vacuum failure hook
        await db.setPostPruneVacuumAction {
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated vacuum busy"])
        }

        let pruned = await store.pruneOldArticles(keepReadDays: 30)
        expectEqual(pruned, 1, "Committed prune count is returned even when vacuum fails")
        expectEqual(store.articles.count, 0, "Store state is refreshed after prune with vacuum failure")
        expectEqual(try await db.fetchArticles(limit: nil).count, 0, "Old article was deleted from database")
    }

    @MainActor
    static func testStorageHardeningItems() async throws {
        print("  - Testing storage hardening items (#1205)...")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-hardening-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("test.sqlite3").path
        let db = DatabaseEngine(path: dbPath)
        try await db.open()

        // 1. Foreign-key check on restored copy (#1205)
        let orphanArchive = directory.appendingPathComponent("orphan-backup.sqlite3")
        try await db.writeBackup(to: orphanArchive, settings: Data())
        var handle: OpaquePointer?
        expectEqual(sqlite3_open_v2(orphanArchive.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        expectEqual(sqlite3_exec(handle, "PRAGMA foreign_keys = OFF;", nil, nil, nil), SQLITE_OK)
        expectEqual(
            sqlite3_exec(
                handle,
                "INSERT INTO article_feeds (article_id, feed_url) VALUES ('orphan-story', 'https://orphan.test');",
                nil, nil, nil), SQLITE_OK)
        let detectedOrphans = DatabaseEngine.foreignKeyCheck(on: handle!)
        expectEqual(detectedOrphans.count, 1, "Foreign key check detects orphan row")
        sqlite3_close(handle)

        var restoreFailed = false
        do {
            _ = try await db.restoreBackup(from: orphanArchive)
        } catch {
            restoreFailed = true
        }
        expectTrue(restoreFailed, "Restoring a backup with foreign-key orphans is refused")

        // 2. Bind parameter error handling (#1205)
        var bindFailed = false
        var testStmt: OpaquePointer?
        expectEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        expectEqual(sqlite3_prepare_v2(handle, "SELECT ?;", -1, &testStmt, nil), SQLITE_OK)
        // The statement is used again only after the engine has returned.
        nonisolated(unsafe) let statement = testStmt
        do {
            try await db.bind([("unknownType", 123)], to: statement)
        } catch {
            bindFailed = true
        }
        sqlite3_finalize(testStmt)
        sqlite3_close(handle)
        expectTrue(bindFailed, "bind throws on unsupported parameter type")

        // 3. Exact embedding blob size: 1537 bytes rejected (#1205)
        let rawDb = directory.appendingPathComponent("embeddings.sqlite3").path
        let embedDb = DatabaseEngine(path: rawDb)
        try await embedDb.open()
        let sampleArticle = FeedArticle(
            storedID: "oversized", title: "Oversized report", link: "https://test.com/oversized",
            guid: "oversized", description: "desc", pubDate: Date(), source: "Source")
        try await embedDb.upsertArticles([sampleArticle])
        var memDb: OpaquePointer?
        expectEqual(sqlite3_open_v2(rawDb, &memDb, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        var insertStmt: OpaquePointer?
        expectEqual(
            sqlite3_prepare_v2(
                memDb,
                "INSERT INTO article_embeddings (article_id, model_version, vector) VALUES ('oversized', 1, ?);",
                -1, &insertStmt, nil), SQLITE_OK)
        let oversizedData = Data(repeating: 0x3F, count: 1537)
        _ = oversizedData.withUnsafeBytes { raw in
            sqlite3_bind_blob(insertStmt, 1, raw.baseAddress, 1537, DatabaseEngine.sqliteTransient)
        }
        expectEqual(sqlite3_step(insertStmt), SQLITE_DONE)
        sqlite3_finalize(insertStmt)
        sqlite3_close(memDb)

        let fetchedOversized = try await embedDb.fetchArticleEmbeddings(articleIDs: ["oversized"], modelVersion: 1)
        expectTrue(
            fetchedOversized["oversized"] == nil, "A 1537-byte embedding blob is ignored by exact byte count check")
        await embedDb.close()

        // 4. Atomic toggles (#1205)
        let store = ArticleStore(database: db)
        await store.initialize()
        let testArticle = FeedArticle(
            storedID: "toggle-test", title: "Toggle report", link: "https://test.com/toggle",
            guid: "toggle-guid", description: "desc", pubDate: Date(), source: "Source")
        try await db.upsertArticles([testArticle])

        expectFalse(store.isRead("toggle-test"))
        await store.toggleRead(id: "toggle-test")
        expectTrue(store.isRead("toggle-test"), "Atomic toggleRead marks article read")
        await store.toggleRead(id: "toggle-test")
        expectFalse(store.isRead("toggle-test"), "Atomic toggleRead marks article unread")

        let saved1 = await store.toggleSave(article: testArticle)
        expectTrue(saved1, "Atomic toggleSave saves article")
        let saved2 = await store.toggleSave(article: testArticle)
        expectFalse(saved2, "Atomic toggleSave unsaves article")
    }

    @MainActor
    static func testMovedFeedSubscriptionMigration() async throws {
        print("  - Testing Phys.org catalog feed address and moved feed migration (#1213)...")
        // 1. Catalog entry is https://phys.org/rss-feed/
        let catalog = FeedCatalog.allFeeds
        let physOrg = catalog.first { $0.id == "phys-org" }
        expectEqual(
            physOrg?.url, "https://phys.org/rss-feed/", "Catalog entry uses direct HTTPS URL with trailing slash")

        // 2. Settings automatically migrates old URL
        let suite = "test.moved.feed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["https://phys.org/rss-feed"], forKey: AppSettings.feedURLsKey)
        defaults.set(["https://phys.org/rss-feed"], forKey: AppSettings.starredFeedURLsKey)
        defaults.set(["https://phys.org/rss-feed": 1_700_000_000.0], forKey: AppSettings.starredFeedTimesKey)

        let settings = AppSettings(defaults: defaults)
        expectTrue(settings.feedURLs.contains("https://phys.org/rss-feed/"), "feedURLs migrated to new URL")
        expectFalse(settings.feedURLs.contains("https://phys.org/rss-feed"), "Old URL removed from feedURLs")
        expectTrue(
            settings.starredFeedURLs.contains("https://phys.org/rss-feed/"), "starredFeedURLs migrated to new URL")
        expectEqual(
            settings.starredFeedTimes["https://phys.org/rss-feed/"], Date(timeIntervalSince1970: 1_700_000_000.0),
            "Star time preserved")

        // 3. Database moveFeed moves articles and article_feeds
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("news-move-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("move.sqlite3").path
        let db = DatabaseEngine(path: dbPath)
        try await db.open()

        let article = FeedArticle(
            storedID: "phys-1", identityFeedURL: "https://phys.org/rss-feed", title: "Quantum physics update",
            link: "https://phys.org/news/1", guid: "phys-1", description: "desc", pubDate: Date(), source: "Phys.org")
        try await db.upsertArticles([article])
        let beforeArticles = try await db.eventRows(
            "SELECT id FROM articles WHERE feed_url = ?;", [.text("https://phys.org/rss-feed")])
        expectEqual(beforeArticles.count, 1)

        try await db.moveFeed(from: "https://phys.org/rss-feed", to: "https://phys.org/rss-feed/")
        let afterArticles = try await db.eventRows(
            "SELECT id FROM articles WHERE feed_url = ?;", [.text("https://phys.org/rss-feed/")])
        expectEqual(afterArticles.count, 1, "Articles moved to new feed URL")
        let oldArticles = try await db.eventRows(
            "SELECT id FROM articles WHERE feed_url = ?;", [.text("https://phys.org/rss-feed")])
        expectEqual(oldArticles.count, 0, "No articles under old URL")

        // 4. A story read and pruned under the old address is not stored again as unread by the moved feed (#1213).
        let movedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let prunedStory = FeedArticle(
            title: "Pruned physics report", link: "https://phys.org/news/pruned", guid: "phys-pruned",
            description: "Served long after reading", pubDate: movedNow.addingTimeInterval(-45 * 86_400),
            source: "Phys.org")
        let prunedIDs = try await db.upsertArticles([prunedStory], feedUrl: "https://phys.org/rss-feed")
        try await db.markReadBatch(articleIds: Array(prunedIDs), isRead: true)
        _ = try await db.pruneOldArticles(keepReadDays: 30, now: movedNow)
        try await db.moveFeed(from: "https://phys.org/rss-feed", to: "https://phys.org/rss-feed/")
        expectTrue(
            try await db.upsertArticles([prunedStory], feedUrl: "https://phys.org/rss-feed/").isEmpty,
            "A story pruned under the old address stays pruned when the moved feed serves it")
    }

}
