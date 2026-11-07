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

/// Native port of the `MigrationTests` atom (#1070): the same eight tests, in the runner's order, with each
/// `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of NativeExpectations.swift, so a
/// failure is recorded and later tests still run. The runner keeps its copy until CI shows parity.
@Suite(.serialized) struct MigrationSuite {
    @Test func feedFailureKindMigration() async throws { try await Self.testFeedFailureKindMigration() }
    @Test func persistentArticleAliases() async throws {
        try await Self.testPersistentArticleAliases(fixtureRoot: NewsTests.defaultFixtureRoot)
    }
    @Test func batchStateAliasResolution() async throws { try await Self.testBatchStateAliasResolution() }
    @Test func identityBaselineScenarios() async throws {
        try await Self.testIdentityBaselineScenarios(fixtureRoot: NewsTests.defaultFixtureRoot)
    }
    @Test func historicalReconciliation() async throws {
        try await Self.testHistoricalReconciliation(fixtureRoot: NewsTests.defaultFixtureRoot)
    }
    @Test func ftsRowIDMigration() async throws { try await Self.testFTSRowIDMigration() }
    @Test func realLibraryMigrationFixture() async throws { try await Self.testRealLibraryMigrationFixture() }
    @Test func migrationCoordinatorAtomicity() async throws { try await Self.testMigrationCoordinatorAtomicity() }
}

extension MigrationSuite {
    static func testFTSRowIDMigration() async throws {
        print("  - Testing durable FTS keys, copied v14 migration, rollback, VACUUM and deletion...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-fts-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("original.sqlite3").path
        let copy = directory.appendingPathComponent("copy.sqlite3").path
        func execute(_ file: String, _ sql: String) {
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(file, &handle), SQLITE_OK, "Open isolated FTS fixture")
            defer { sqlite3_close(handle) }
            expectEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Prepare FTS fixture")
        }
        func value(_ file: String, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            expectEqual(sqlite3_open(file, &handle), SQLITE_OK, "Inspect isolated FTS fixture")
            defer { sqlite3_close(handle) }
            expectEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "Prepare FTS inspection")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        let seed = DatabaseEngine(path: path)
        try await seed.open()
        let now = Date()
        let articles = ["one", "two", "three"].map { (id: String) in
            FeedArticle(
                storedID: id, title: "Research evidence \(id)", link: "https://example.com/fts-keys/\(id)",
                guid: id, description: "Independent report", pubDate: now, source: "Publisher \(id)")
        }
        try await seed.upsertArticles(articles)
        try await seed.markRead(articleId: "one", isRead: true)
        try await seed.setSaved(articleId: "two", isSaved: true)
        let event = try await seed.createEvent(memberArticleIDs: ["one", "two"], at: now)
        let originalOrder = try await seed.searchArticles(query: "Research").map(\.id)
        await seed.close()
        // Restore the actual v14 derived index and triggers; its rowids need not equal article rowids.
        execute(
            path,
            """
            DROP TRIGGER trg_articles_ai; DROP TRIGGER trg_articles_ad; DROP TRIGGER trg_articles_au;
            DROP TABLE articles_fts; DROP TABLE article_fts_rows;
            CREATE VIRTUAL TABLE articles_fts USING fts5(article_id UNINDEXED,title,description,content,source,category,tokenize='porter unicode61');
            INSERT INTO articles_fts(article_id,title,description,content,source,category)
            SELECT id,title,coalesce(description,''),coalesce(content,''),source,coalesce(category,'') FROM articles ORDER BY id DESC;
            CREATE TRIGGER trg_articles_ai AFTER INSERT ON articles BEGIN
                INSERT INTO articles_fts(article_id,title,description,content,source,category)
                VALUES(new.id,new.title,coalesce(new.description,''),coalesce(new.content,''),new.source,coalesce(new.category,''));
            END;
            CREATE TRIGGER trg_articles_ad AFTER DELETE ON articles BEGIN
                DELETE FROM articles_fts WHERE article_id=old.id;
            END;
            CREATE TRIGGER trg_articles_au AFTER UPDATE ON articles
            WHEN old.title IS NOT new.title OR old.description IS NOT new.description OR old.content IS NOT new.content
              OR old.source IS NOT new.source OR old.category IS NOT new.category
            BEGIN
                DELETE FROM articles_fts WHERE article_id=old.id;
                INSERT INTO articles_fts(article_id,title,description,content,source,category)
                VALUES(new.id,new.title,coalesce(new.description,''),coalesce(new.content,''),new.source,coalesce(new.category,''));
            END;
            PRAGMA user_version=14;
            """)
        let readAt = value(path, "SELECT read_at FROM article_state WHERE article_id='one';")
        let savedAt = value(path, "SELECT saved_at FROM article_state WHERE article_id='two';")
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        let cancelledDB = DatabaseEngine(path: copy)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cancelledDB.open()
        }
        do {
            try await cancelled.value
            expectTrue(false, "Cancelled FTS migration must throw")
        } catch is CancellationError {}
        expectEqual(value(copy, "PRAGMA user_version;"), "14", "Cancellation keeps the old version")
        expectEqual(value(copy, "SELECT count(*) FROM articles_fts;"), "3", "Cancellation preserves the old FTS index")

        // Fail after the old FTS table has been dropped, exercising transactional DDL rollback.
        execute(copy, "CREATE VIEW article_fts_rows AS SELECT 1;")
        let db = DatabaseEngine(path: copy)
        do {
            try await db.open()
            expectTrue(false, "Injected migration failure must throw")
        } catch {}
        expectEqual(value(copy, "PRAGMA user_version;"), "14", "Failed rebuild keeps the old version")
        expectEqual(
            value(copy, "SELECT count(*) FROM articles_fts WHERE articles_fts MATCH 'Research';"), "3",
            "Failed rebuild restores the old searchable index")
        expectEqual(
            value(
                copy,
                "SELECT count(*) FROM sqlite_master WHERE name IN ('trg_articles_ai','trg_articles_ad','trg_articles_au');"
            ), "3", "Failed rebuild restores the old triggers")
        execute(copy, "DROP VIEW article_fts_rows;")
        try await db.open()
        expectEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v14 library upgrades through v15 to the current schema")
        expectEqual(
            value(copy, "SELECT count(*) FROM articles WHERE category IS NOT NULL;"), "0",
            "A library from before v22 keeps none of the classifier labels v22 wrote into the publisher column (#817)")
        expectEqual(
            value(
                copy,
                "SELECT count(*) FROM articles a WHERE NOT EXISTS (SELECT 1 FROM article_enrichment ae WHERE ae.article_id = a.id AND ae.category IS NOT NULL);"
            ), "0", "Every article from before v22 keeps a classifier category in article_enrichment (#817)")
        expectEqual(value(path, "PRAGMA user_version;"), "14", "Original library stays untouched")
        expectEqual(
            try await db.searchArticles(query: "Research").map(\.id), originalOrder,
            "Migration preserves ranks and ID tie order")
        expectEqual(
            value(copy, "SELECT read_at FROM article_state WHERE article_id='one';"), readAt,
            "Migration preserves read timestamps")
        expectEqual(
            value(copy, "SELECT saved_at FROM article_state WHERE article_id='two';"), savedAt,
            "Migration preserves saved timestamps")
        expectEqual(
            try await db.fetchEvent(id: event.id)?.memberArticleIDs.count, 2, "Migration preserves event membership")
        let key = value(copy, "SELECT fts_rowid FROM article_fts_rows WHERE article_id='one';")
        await db.close()
        // Explicitly relocate an article's hidden rowid: the mapping must use its durable ID.
        execute(copy, "UPDATE articles SET rowid=rowid+100 WHERE id='one'; VACUUM;")
        try await db.open()
        expectEqual(
            value(copy, "SELECT fts_rowid FROM article_fts_rows WHERE article_id='one';"), key,
            "Durable FTS key survives rowid relocation and VACUUM")
        expectEqual(
            try await db.searchArticles(query: "Research").map(\.id), originalOrder,
            "Search still joins the correct publications")
        let candidates = try await db.eventCandidateRows(
            matching: "Research", around: now, window: 48 * 3600,
            activeSince: now.addingTimeInterval(-72 * 3600), excluding: "one", limit: 10)
        expectEqual(Set(candidates.map(\.id)), ["two", "three"], "Candidate joins survive VACUUM")
        await db.close()
        execute(copy, "PRAGMA foreign_keys=ON; DELETE FROM articles WHERE id='three';")
        expectEqual(value(copy, "SELECT count(*) FROM article_fts_rows;"), "2", "Deletion removes the mapping")
        expectEqual(
            value(copy, "SELECT count(*) FROM articles_fts WHERE article_id='three';"), "0",
            "Deletion removes FTS postings")
        execute(copy, "BEGIN; DELETE FROM articles WHERE id='one'; ROLLBACK;")
        expectEqual(
            value(copy, "SELECT fts_rowid FROM article_fts_rows WHERE article_id='one';"), key,
            "Rolled-back deletion restores the mapping")
        expectEqual(
            value(copy, "SELECT count(*) FROM articles_fts WHERE article_id='one';"), "1",
            "Rolled-back deletion restores FTS")
        expectEqual(value(copy, "PRAGMA quick_check;"), "ok", "Migrated database passes quick_check")
        expectEqual(value(copy, "PRAGMA foreign_key_check;"), nil, "Migrated database has no dangling references")
        execute(copy, "INSERT INTO articles_fts(articles_fts) VALUES('integrity-check');")
    }

    static func testRealLibraryMigrationFixture() async throws {
        print("  - Testing real-library v14 migration fixture in CI (#539)...")
        let fixtureSource = nativeRepositoryRoot.appendingPathComponent("Tests/Fixtures/legacy-library-v14.sqlite3")
        expectTrue(
            FileManager.default.fileExists(atPath: fixtureSource.path),
            "Sanitized legacy library fixture must exist at Tests/Fixtures/legacy-library-v14.sqlite3"
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-real-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workingCopy = directory.appendingPathComponent("library.sqlite3")
        try FileManager.default.copyItem(at: fixtureSource, to: workingCopy)

        func value(_ file: String, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            expectEqual(sqlite3_open(file, &handle), SQLITE_OK, "Open migrated fixture for inspection")
            defer { sqlite3_close(handle) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }

        expectEqual(value(workingCopy.path, "PRAGMA user_version;"), "14", "Fixture starts at schema v14")
        let db = DatabaseEngine(path: workingCopy.path)
        try await db.open()
        expectEqual(
            value(workingCopy.path, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Fixture migrates cleanly to current schema v26 (#539)"
        )
        expectEqual(
            value(workingCopy.path, "PRAGMA auto_vacuum;"), "2",
            "Migrated fixture enables incremental auto_vacuum (#536)"
        )
        expectEqual(
            value(workingCopy.path, "PRAGMA quick_check;"), "ok",
            "Migrated fixture passes PRAGMA quick_check (#539)"
        )
        expectEqual(
            value(workingCopy.path, "PRAGMA foreign_key_check;"), nil,
            "Migrated fixture passes PRAGMA foreign_key_check (#539)"
        )

        let counts = try await db.counts()
        expectEqual(counts.total, 200, "Migrated fixture preserves all 200 articles")
        expectEqual(counts.unread, 150, "Migrated fixture preserves unread count (150)")
        expectEqual(counts.saved, 20, "Migrated fixture preserves saved count (20)")

        let fetched = try await db.fetchArticles(limit: 500)
        expectEqual(fetched.count, 200, "fetchArticles(limit: 500) returns all 200 migrated stories")
        let searchResults = try await db.searchArticles(query: "Observatory", limit: 500)
        expectEqual(searchResults.count, 200, "Migrated FTS5 index searches all 200 stories")
        let event = try await db.fetchEvent(id: "legacy-event-00")
        expectEqual(event?.memberArticleIDs.count, 3, "Migrated fixture preserves event memberships")
        await db.close()
    }

    /// The kind survives a reopen, and a failure recorded before schema 32 never qualifies for the retry (#927).
    static func testFeedFailureKindMigration() async throws {
        print("  - Testing the stored failure kind across a reopen and the schema 31 migration (#927)...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let feed = "https://8.8.8.8/feed.xml"
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var db = DatabaseEngine(path: path)
        try await db.open()
        let retryAt = try await db.recordFeedFailure(feed, kind: .timeout, retryAfter: nil, at: t0)
        await db.close()

        db = DatabaseEngine(path: path)
        try await db.open()
        var stored = try await db.feedFetchStates()[feed]
        expectEqual(stored?.lastFailureKind, .timeout, "The kind survives a reopen")
        expectEqual(stored?.retryAt, retryAt, "The wait survives a reopen")
        try await db.clearConnectivityBackoff(at: t0)
        stored = try await db.feedFetchStates()[feed]
        expectEqual(stored?.retryAt, t0, "The retry ends a connectivity failure's wait after a reopen")
        expectEqual(stored?.failures, 1, "The retry keeps the failure count")

        // A lifted or expired wait still dates the failure, so a failure long after it starts the schedule again.
        let muchLater = t0.addingTimeInterval(FeedRetryPolicy.maximumDelay + 3600)
        try await db.clearConnectivityBackoff(at: muchLater)
        expectEqual(try await db.feedFetchStates()[feed]?.retryAt, t0, "An expired wait is left as it is")
        expectEqual(
            try await db.recordFeedFailure(feed, kind: .timeout, retryAfter: nil, at: muchLater),
            muchLater.addingTimeInterval(FeedRetryPolicy.baseDelay),
            "A failed retry long after the last one backs off from the start")
        expectEqual(try await db.feedFetchStates()[feed]?.failures, 1, "Old failures are forgiven")

        let legacyRetryAt = try await db.recordFeedFailure(feed, kind: .timeout, retryAfter: nil, at: t0)
        await db.close()

        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the fixture library")
        expectEqual(
            sqlite3_exec(
                handle, "ALTER TABLE feeds DROP COLUMN last_failure_kind; PRAGMA user_version = 31;", nil, nil, nil),
            SQLITE_OK, "Take the library back to schema 31")
        sqlite3_close(handle)

        db = DatabaseEngine(path: path)
        try await db.open()
        expectEqual(
            try await db.storedSchemaVersion(), DatabaseEngine.schemaVersion, "A schema 31 library migrates")
        stored = try await db.feedFetchStates()[feed]
        expectEqual(stored?.failures, 2, "The migration keeps the failure count")
        expectEqual(stored?.retryAt, legacyRetryAt, "The migration keeps the wait")
        expectEqual(stored?.lastFailureKind, nil, "A failure from before the migration has no kind")
        try await db.clearConnectivityBackoff(at: t0)
        expectEqual(
            try await db.feedFetchStates()[feed]?.retryAt, legacyRetryAt,
            "A failure from before the migration is not retried early")
        await db.close()
    }

    static func testBatchStateAliasResolution() async throws {
        print("  - Testing bounded batch aliases, state preservation and rollback...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let articles = ["batch-first", "batch-second"].map {
            FeedArticle(title: $0, link: "", guid: $0, description: "", pubDate: Date(), source: "Fixture")
        }
        try await db.upsertArticles(articles)
        func execute(_ sql: String) {
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated batch fixture")
            defer { sqlite3_close(handle) }
            expectEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Modify isolated batch fixture")
        }
        let aliases = (0..<405).map { "batch-alias-\($0)" }
        execute(
            aliases.enumerated().map { index, alias in
                "INSERT INTO article_aliases(kind, value, article_id) VALUES ('id', '\(alias)', '\(articles[index % 2].id)');"
            }.joined() + "INSERT INTO article_aliases(kind, value, article_id) VALUES ('id', 'batch-ambiguous', NULL);")
        let composed = "batch-caf\u{00E9}"
        let decomposed = "batch-cafe\u{0301}"
        expectTrue(composed == decomposed, "Swift considers the two Unicode spellings equal")
        expectFalse(Data(composed.utf8) == Data(decomposed.utf8), "SQLite BINARY keys distinguish their bytes")
        execute(
            "INSERT INTO article_aliases VALUES ('id', '\(composed)', 'batch-first'); INSERT INTO article_aliases VALUES ('id', '\(decomposed)', 'batch-second');"
        )
        expectEqual(
            try await db.resolvedArticleID(composed), articles[0].id,
            "The single-ID lookup distinguishes the first spelling")
        expectEqual(
            try await db.resolvedArticleID(decomposed), articles[1].id,
            "The single-ID lookup distinguishes the second spelling")
        let input =
            Array(aliases.reversed()) + [
                aliases[0], "batch-missing", "batch-ambiguous", composed, decomposed, composed,
            ]
        let expected =
            (0..<405).reversed().map { articles[$0 % 2].id } + [
                articles[0].id, "batch-missing", "batch-ambiguous", articles[0].id, articles[1].id, articles[0].id,
            ]
        expectEqual(
            try await db.resolvedArticleIDs(input), expected,
            "Chunks preserve order, duplicates and absent/NULL fallbacks")
        expectEqual(try await db.resolvedArticleIDs([]), [], "Empty resolution needs no query")
        try await db.markReadBatch(articleIds: [], isRead: true)
        try await db.batchMarkSaved([])
        try await db.markReadBatch(articleIds: aliases, isRead: true)
        try await db.batchMarkSaved(Set(aliases))
        for article in articles {
            expectTrue(try await db.isRead(articleId: article.id), "Batch reads reach the alias target")
            expectTrue(try await db.isSaved(articleId: article.id), "Batch saves preserve read state")
        }
        execute(
            "CREATE TRIGGER fail_batch BEFORE INSERT ON article_state WHEN NEW.article_id = 'batch-second' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"
        )
        do {
            try await db.markReadBatch(articleIds: [aliases[0], aliases[1]], isRead: false)
            expectTrue(false, "A failed write must abort the read batch")
        } catch {
            expectTrue(try await db.isRead(articleId: articles[0].id), "An earlier read update rolls back")
        }
        execute("DROP TRIGGER fail_batch;")
        for article in articles { try await db.setSaved(articleId: article.id, isSaved: false) }
        execute(
            "CREATE TRIGGER fail_batch BEFORE INSERT ON article_state WHEN NEW.article_id = 'batch-second' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"
        )
        do {
            try await db.batchMarkSaved(Set(aliases))
            expectTrue(false, "A failed write must abort the saved batch")
        } catch {
            for article in articles {
                expectFalse(try await db.isSaved(articleId: article.id), "No failed batch save persists")
            }
        }
        execute("DROP TRIGGER fail_batch; DROP TABLE article_aliases;")
        do {
            _ = try await db.resolvedArticleIDs(aliases)
            expectTrue(false, "Alias query errors must propagate")
        } catch {
            expectTrue(
                error.localizedDescription.contains("article_aliases"), "The alias lookup reports its database error")
        }
        await db.close()
    }

    @MainActor
    static func testPersistentArticleAliases(fixtureRoot: URL) async throws {
        print("  - Testing durable aliases, copied v4 migration, ambiguity and rollback...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalPath = directory.appendingPathComponent("original.sqlite3").path
        let copyPath = directory.appendingPathComponent("copy.sqlite3").path
        func execute(_ path: String, _ sql: String) {
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated alias fixture")
            defer { sqlite3_close(handle) }
            expectEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Modify isolated alias fixture")
        }
        func value(_ path: String, _ sql: String) -> String? {
            var handle: OpaquePointer?
            expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated alias verification")
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            expectEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "Prepare alias verification")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        let original = DatabaseEngine(path: originalPath)
        try await original.open()
        let first = FeedArticle(
            title: "Original report", link: fixtureRoot.appendingPathComponent("aliases/original").absoluteString,
            guid: "alias-first", description: "Report", pubDate: Date(timeIntervalSince1970: 100), source: "Publisher")
        let duplicateA = FeedArticle(
            title: "Historical A", link: fixtureRoot.appendingPathComponent("aliases/ambiguous").absoluteString,
            guid: "historical-a", description: "Report", pubDate: Date(), source: "Publisher")
        let duplicateB = FeedArticle(
            title: "Historical B", link: fixtureRoot.appendingPathComponent("aliases/other").absoluteString,
            guid: "historical-b", description: "Report", pubDate: Date(), source: "Publisher")
        try await original.upsertArticles([first, duplicateA, duplicateB], feedUrl: "test-feed")
        try await original.markRead(articleId: first.id, isRead: true)
        try await original.setSaved(articleId: first.id, isSaved: true)
        await original.close()
        // Reconstruct a genuine v4 library, including duplicates that predate URL resolution.
        execute(
            originalPath,
            """
            UPDATE articles SET canonical_url = (SELECT canonical_url FROM articles WHERE id = 'historical-a') WHERE id = 'historical-b';
            DROP TABLE article_aliases;
            DROP TABLE article_reconciliation_history; DROP TABLE article_reconciliations; PRAGMA user_version = 4;
            """)
        let originalReadAt = value(originalPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';")
        let originalSavedAt = value(
            originalPath, "SELECT saved_at FROM article_state WHERE article_id = 'alias-first';")
        try FileManager.default.copyItem(atPath: originalPath, toPath: copyPath)
        let cancelledPath = directory.appendingPathComponent("cancelled.sqlite3").path
        try FileManager.default.copyItem(atPath: originalPath, toPath: cancelledPath)
        let cancelledDB = DatabaseEngine(path: cancelledPath)
        let migration = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cancelledDB.open()
        }
        do {
            try await migration.value
            expectTrue(false, "Cancelled migration must be reported")
        } catch is CancellationError {
            expectEqual(value(cancelledPath, "PRAGMA user_version;"), "4", "Cancelled migration leaves the old version")
            expectEqual(
                value(cancelledPath, "SELECT count(*) FROM sqlite_master WHERE name = 'article_aliases';"), "0",
                "Cancelled migration rolls back the alias schema")
            expectEqual(
                value(cancelledPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';"),
                originalReadAt, "Cancelled migration preserves history")
        }
        try await cancelledDB.open()
        await cancelledDB.close()
        let db = DatabaseEngine(path: copyPath)
        try await db.open()
        expectEqual(
            value(copyPath, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v4 library upgrades to the current schema")
        expectEqual(value(originalPath, "PRAGMA user_version;"), "4", "Original fixture stays untouched")
        expectEqual(try await db.fetchArticles(limit: nil).count, 3, "Migration keeps historical rows")
        expectEqual(
            value(copyPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';"), originalReadAt,
            "Migration preserves read history timestamp")
        expectEqual(
            value(copyPath, "SELECT saved_at FROM article_state WHERE article_id = 'alias-first';"), originalSavedAt,
            "Migration preserves bookmark timestamp")
        expectTrue(try await db.isRead(articleId: first.id), "Migration preserves read state")
        expectTrue(try await db.isSaved(articleId: first.id), "Migration preserves saved state")
        expectEqual(try await db.searchArticles(query: "Original").first?.id, first.id, "Migration preserves FTS")
        expectEqual(
            value(copyPath, "SELECT count(*) FROM article_aliases WHERE kind = 'url' AND article_id IS NULL;"), "1",
            "Conflicting historical URL is marked ambiguous")
        let unknown = FeedArticle(
            title: "Unknown identity", link: duplicateA.link, guid: "unknown-guid", description: "Report",
            pubDate: Date(), source: "Publisher")
        expectEqual(
            try await db.resolvedArticleID(for: unknown), unknown.id, "Ambiguous URL never selects a historical row")
        expectTrue(
            try await db.fetchArticles(limit: 1, canonicalURL: duplicateA.normalizedLink).isEmpty,
            "Ambiguous notification URL must not choose a document")
        execute(copyPath, "PRAGMA foreign_keys = ON; DELETE FROM articles WHERE id = 'historical-a';")
        expectTrue(
            try await db.fetchArticles(limit: 1, canonicalURL: duplicateA.normalizedLink).isEmpty,
            "Removing a conflicting row must not revive an ambiguous URL")
        expectEqual(
            try await db.resolvedArticleID(for: unknown), unknown.id, "Ambiguous URL remains unusable after deletion")

        func variant(_ guid: String, _ link: String, _ title: String) -> FeedArticle {
            var article = FeedArticle(
                title: title, link: link, guid: guid, description: first.description, pubDate: first.pubDate,
                source: first.source)
            article.identityFeedURL = "test-feed"
            return article
        }
        let second = variant("alias-second", first.link, first.title)
        expectTrue(
            try await db.upsertArticles([second], feedUrl: "test-feed").isEmpty, "Same URL registers a new observed ID")
        let moved = variant(
            "alias-second", fixtureRoot.appendingPathComponent("aliases/moved").absoluteString, "Migrated report")
        expectTrue(
            try await db.upsertArticles([moved], feedUrl: "test-feed").isEmpty,
            "Observed replacement GUID carries a URL change")
        await db.close()
        try await db.open()
        expectEqual(try await db.fetchArticles(limit: 1, id: second.id).first?.id, first.id, "ID alias survives reopen")
        expectEqual(
            try await db.fetchArticles(limit: 1, canonicalURL: first.normalizedLink).first?.id, first.id,
            "Previous URL survives replacement and reopen")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let navigation = ArticleStore.NavigationRequest(articleID: second.id, link: "")
        expectEqual(
            try await store.articleForNavigation(navigation)?.id, first.id,
            "Old notification ID resolves to stored article")
        await store.markAsRead(id: second.id, isRead: false)
        expectFalse(store.readArticleIDs.contains(first.id), "Read cache changes the stored ID")
        await store.toggleRead(id: second.id)
        expectTrue(store.readArticleIDs.contains(first.id), "Read toggle resolves alias before consulting cached state")
        await store.toggleRead(id: second.id)
        expectFalse(try await db.isRead(articleId: first.id), "Second alias toggle marks the original unread")
        expectFalse(await store.toggleSave(article: moved), "Saved toggle through an alias unsaves the original")
        expectTrue(await store.toggleSave(article: moved), "Second saved toggle restores the original bookmark")
        try await db.markReadBatch(articleIds: [second.id], isRead: true)
        try await db.setSaved(articleId: second.id, isSaved: false)
        try await db.batchMarkSaved([second.id])
        expectTrue(try await db.isRead(articleId: second.id), "Batch read and lookup resolve aliases")
        expectTrue(try await db.isSaved(articleId: second.id), "Batch saved and lookup resolve aliases")
        expectEqual(
            try await db.searchArticles(query: "Migrated").first?.id, first.id,
            "Updated FTS uses the original primary key")
        await store.refreshState()
        await store.updateEnrichment(id: second.id, content: "Verified evidence")
        expectEqual(
            store.articles.first(where: { $0.id == first.id })?.fullContent, "Verified evidence",
            "Alias enrichment updates the visible stored article")
        expectEqual(
            try await db.fetchArticles(id: first.id).first?.fullContent, "Verified evidence",
            "Enrichment through an alias updates the original")
        let analysis = ArticleAnalysis(
            summary: "Cited summary", keyPoints: ["Finding"], entities: [], category: "Science", sentiment: nil,
            modelIdentifier: "test", analysisVersion: 1)
        await store.saveArticleAnalysis(analysis, for: second.id)
        expectEqual(
            store.savedArticles.first(where: { $0.id == first.id })?.aiSummary, analysis.summary,
            "Alias analysis updates the saved article cache")
        expectEqual(
            await db.fetchArticleAnalysis(for: second.id)?.summary, analysis.summary,
            "Analysis persistence and lookup resolve aliases")
        let returned = variant("alias-third", first.link, "Returned report")
        expectTrue(try await db.upsertArticles([returned]).isEmpty, "Old URL recognizes a further GUID change")
        let simultaneous = variant(
            "alias-second", fixtureRoot.appendingPathComponent("aliases/third-location").absoluteString, first.title)
        expectTrue(try await db.upsertArticles([simultaneous]).isEmpty, "Known ID and changed URL resolve together")
        let unrelated = variant(
            "never-observed", fixtureRoot.appendingPathComponent("aliases/unrelated").absoluteString, first.title)
        expectEqual(
            try await db.resolvedArticleID(for: unrelated), unrelated.id, "No known signal means no guessed merge")

        // When known ID and URL conflict, the conflicting item is skipped inside the batch rather than aborting the feed (#885).
        let separate = variant(
            "separate-guid", fixtureRoot.appendingPathComponent("aliases/separate").absoluteString, "Separate report")
        try await db.upsertArticles([separate])
        let contradictory = variant(first.id, separate.link, "Contradictory report")
        let batchItem = variant(
            "batch-guid", fixtureRoot.appendingPathComponent("aliases/valid-batch-item").absoluteString,
            "Valid batch report")
        let inserted = try await db.upsertArticles([contradictory, batchItem])
        expectTrue(
            inserted.contains(batchItem.id),
            "Valid batch items are stored when a conflicting item is in the batch (#885)")
        expectEqual(
            try await db.fetchArticles(id: first.id).first?.title, "Original report",
            "Conflicting signals must not overwrite the original")
        expectEqual(
            try await db.fetchArticles(id: separate.id).first?.title, separate.title,
            "Conflicting signals must not overwrite the other document")

        // An alias write failure must roll back the article update and its FTS trigger too.
        execute(
            copyPath,
            "CREATE TRIGGER fail_alias BEFORE INSERT ON article_aliases BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"
        )
        let failed = variant("failed-alias", returned.link, "Must rollback")
        do {
            try await db.upsertArticles([failed])
            expectTrue(false, "Alias failure must be reported")
        } catch {
            expectEqual(
                try await db.fetchArticles(limit: 1, id: first.id).first?.title, "Original report",
                "Failed alias update restores the previous article")
            expectTrue(try await db.searchArticles(query: "rollback").isEmpty, "Failed alias write rolls back FTS")
            expectEqual(try await db.resolvedArticleID(failed.id), failed.id, "Failed alias is never committed")
        }
        execute(copyPath, "DROP TRIGGER fail_alias;")
        expectEqual(value(copyPath, "PRAGMA quick_check;"), "ok", "Migrated alias library passes quick_check")
        expectTrue(value(copyPath, "PRAGMA foreign_key_check;") == nil, "Migrated aliases have no dangling targets")
        await db.close()
    }

    static func testHistoricalReconciliation(fixtureRoot: URL) async throws {
        print("  - Testing copied-library historical reconciliation and preserved originals...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("original.sqlite3").path
        let copy = directory.appendingPathComponent("copy.sqlite3").path
        let failure = directory.appendingPathComponent("failure.sqlite3").path
        let creator = DatabaseEngine(path: path)
        try await creator.open()
        await creator.close()
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated historical fixture")
        func execute(_ sql: String) {
            expectEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Execute historical fixture SQL")
        }
        let body = (1...65).map { "Historical evidence \($0) preserves the publisher's distinctive reporting." }.joined(
            separator: " ")
        let url = fixtureRoot.appendingPathComponent("historical/story").absoluteString
        execute(
            "DROP TRIGGER trg_publisher_content_insert; DROP TRIGGER trg_publisher_content_update; DROP TABLE publisher_content_revisions; DROP TABLE article_reconciliation_history; DROP TABLE article_reconciliations; PRAGMA user_version = 8;"
        )
        let rows = [
            ("historical-a", url, body), ("historical-b", url, body), ("historical-c", url, body),
            ("uncertain", url, body + " Different reporting."), ("short-body", url, "Short body"),
            ("reprint", fixtureRoot.appendingPathComponent("another/story").absoluteString, body),
            ("homepage-a", fixtureRoot.absoluteString, body), ("homepage-b", fixtureRoot.absoluteString, body),
        ]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, row) in rows.enumerated() {
            var statement: OpaquePointer?
            let sql =
                "INSERT INTO articles(id,guid,canonical_url,title,description,content,published_at,source,created_at,updated_at) VALUES(?,?,?,'Historical report',?,?,100,'Publisher',?,50);"
            expectEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "Prepare original article")
            for (column, value) in [row.0, row.0, row.1, body, row.2].enumerated() {
                sqlite3_bind_text(statement, Int32(column + 1), value, -1, transient)
            }
            sqlite3_bind_double(statement, 6, Double(index + 10))
            expectEqual(sqlite3_step(statement), SQLITE_DONE, "Insert historical article without modern deduplication")
            sqlite3_finalize(statement)
            execute(
                "INSERT INTO article_state VALUES ('\(row.0)',0,0,NULL,NULL); INSERT INTO article_aliases VALUES ('id','\(row.0)','\(row.0)');"
            )
        }
        execute(
            "UPDATE article_state SET is_read=1,read_at=11 WHERE article_id='historical-a'; UPDATE article_state SET is_saved=1,saved_at=22 WHERE article_id='historical-b'; UPDATE article_state SET is_read=1,is_saved=1,read_at=33,saved_at=44 WHERE article_id='historical-c';"
        )
        execute(
            "INSERT INTO article_feeds VALUES ('historical-a','feed-a'),('historical-b','feed-b'); INSERT INTO article_enrichment(article_id,summary) VALUES ('historical-b','Original generated summary'); INSERT INTO article_aliases VALUES ('id','observed-variant-b','historical-b');"
        )
        var alias: OpaquePointer?
        expectEqual(
            sqlite3_prepare_v2(handle, "INSERT INTO article_aliases VALUES ('url',?,NULL);", -1, &alias, nil),
            SQLITE_OK, "Prepare ambiguous URL")
        sqlite3_bind_text(alias, 1, url, -1, transient)
        expectEqual(sqlite3_step(alias), SQLITE_DONE, "Retain uncertain shared URL")
        sqlite3_finalize(alias)
        let historical = FeedArticle(
            title: "Historical report", link: url, guid: nil,
            description: body, pubDate: Date(timeIntervalSince1970: 100), source: "Publisher", fullContent: body)
        for fingerprint in ArticleIdentity.publisherTextFingerprints(historical) {
            expectEqual(
                sqlite3_prepare_v2(handle, "INSERT INTO article_aliases VALUES ('content',?,NULL);", -1, &alias, nil),
                SQLITE_OK, "Prepare ambiguous historical content")
            sqlite3_bind_text(alias, 1, fingerprint, -1, transient)
            expectEqual(sqlite3_step(alias), SQLITE_DONE, "Retain content ambiguity")
            sqlite3_finalize(alias)
        }
        sqlite3_close(handle)
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        try FileManager.default.copyItem(atPath: path, toPath: failure)
        let migrated = DatabaseEngine(path: copy)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await migrated.open()
        }
        do {
            try await cancelled.value
            expectTrue(false, "Cancelled reconciliation must throw")
        } catch is CancellationError {}
        func value(_ file: String, _ sql: String) -> String? {
            var connection: OpaquePointer?
            var statement: OpaquePointer?
            expectEqual(sqlite3_open(file, &connection), SQLITE_OK, "Inspect copied fixture")
            defer { sqlite3_close(connection) }
            expectEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare inspection")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        expectEqual(value(copy, "PRAGMA user_version;"), "8", "Cancellation rolls back the schema version")
        expectEqual(
            value(copy, "SELECT count(*) FROM sqlite_master WHERE name='article_reconciliations';"), "0",
            "Cancellation rolls back newly created reconciliation tables")
        expectEqual(sqlite3_open(failure, &handle), SQLITE_OK, "Inject copied-library failure")
        execute(
            "CREATE TRIGGER fail_reconciliation BEFORE UPDATE ON article_aliases WHEN old.article_id='historical-b' BEGIN SELECT RAISE(ABORT,'fixture'); END;"
        )
        sqlite3_close(handle)
        let failed = DatabaseEngine(path: failure)
        do {
            try await failed.open()
            expectTrue(false, "Failed alias retargeting must abort migration")
        } catch {}
        expectEqual(value(failure, "PRAGMA user_version;"), "8", "Injected failure rolls back migration version")
        expectEqual(
            value(failure, "SELECT is_saved FROM article_state WHERE article_id='historical-a';"), "0",
            "Injected failure rolls back survivor state union")
        expectEqual(
            value(failure, "SELECT article_id FROM article_aliases WHERE value='observed-variant-b';"), "historical-b",
            "Injected failure preserves old aliases")
        try await migrated.open()
        expectEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied library upgrades to the current schema")
        expectEqual(value(path, "PRAGMA user_version;"), "8", "Original fixture remains untouched")
        expectEqual(
            try await migrated.fetchArticles(limit: nil).count, 6, "Only confident same-URL text copies are hidden")
        expectEqual(
            try await migrated.fetchArticles(limit: nil, includingOriginals: true).count, 8,
            "Every stored original remains reachable")
        expectEqual(
            try await migrated.fetchArticles(id: "historical-b").first?.id, "historical-a",
            "Old IDs navigate to the survivor")
        expectEqual(
            try await migrated.fetchArticles(id: "observed-variant-b").first?.id, "historical-a",
            "Observed old ID aliases follow the survivor")
        expectEqual(
            try await migrated.fetchArticles(id: "historical-b", includingOriginals: true).first?.aiSummary, nil,
            "Unversioned original analysis is invalidated by the provenance migration")
        expectEqual(
            try await migrated.fetchArticles(id: "historical-b", includingOriginals: true).first?.fullContent, body,
            "Original publisher text is retained")
        expectTrue(try await migrated.isRead(articleId: "historical-b"), "Read flags are unioned")
        expectTrue(try await migrated.isSaved(articleId: "historical-a"), "Saved flags are unioned")
        expectEqual(
            value(copy, "SELECT read_at || ':' || saved_at FROM article_state WHERE article_id='historical-a';"),
            "33.0:44.0", "Survivor carries latest known history timestamps")
        expectEqual(
            value(copy, "SELECT read_at FROM article_reconciliation_history WHERE article_id='historical-a';"), "11.0",
            "Survivor's original read timestamp remains intact")
        expectEqual(
            value(copy, "SELECT saved_at FROM article_reconciliation_history WHERE article_id='historical-b';"), "22.0",
            "Duplicate's original bookmark timestamp remains intact")
        expectEqual(
            value(copy, "SELECT count(*) FROM article_feeds WHERE article_id='historical-a';"), "2",
            "Feed associations are unioned without multiplying articles")
        expectEqual(try await migrated.counts().total, 6, "Counts hide reconciled copies")
        expectEqual(try await migrated.counts().saved, 1, "Bookmarks count surviving documents")
        expectEqual(try await migrated.getReadArticleIDs(), Set(["historical-a"]), "Read cache uses surviving IDs")
        expectEqual(try await migrated.searchArticles(query: "Historical").count, 6, "FTS hides reconciled copies")
        expectEqual(
            value(copy, "SELECT count(*) FROM article_feeds WHERE article_id='historical-a' AND feed_url='feed-b';"),
            "1", "Other original feed remains associated with the survivor")
        let incoming = FeedArticle(
            title: "Historical report", link: url, guid: "fresh-guid", description: body,
            pubDate: Date(timeIntervalSince1970: 100), source: "Publisher", fullContent: body)
        expectTrue(
            try await migrated.upsertArticles([incoming]).isEmpty,
            "Proven family evidence prevents refreshed variants from reappearing")
        expectTrue(
            try await migrated.fetchArticles(canonicalURL: url).isEmpty, "Uncertain URL tombstone is never revived")
        expectEqual(
            value(copy, "SELECT count(*) FROM article_aliases WHERE kind='content' AND article_id IS NULL;"), "2",
            "Historical evidence never revives ambiguous content aliases")
        try await migrated.clearArticleCache()
        expectEqual(
            try await migrated.fetchArticles(id: "historical-b", includingOriginals: true).first?.fullContent, body,
            "Saved family originals survive content cache purging")
        await migrated.close()
        try await migrated.open()
        expectEqual(
            try await migrated.fetchArticles(id: "historical-c").first?.id, "historical-a",
            "Reconciled identities survive reopening")
        try await migrated.setSaved(articleId: "historical-b", isSaved: false)
        expectFalse(
            try await migrated.isSaved(articleId: "historical-a"), "Old-ID actions update the surviving bookmark")
        expectEqual(sqlite3_open(copy, &handle), SQLITE_OK, "Add an overview citing a retained original")
        execute(
            "PRAGMA foreign_keys = ON; INSERT INTO event_overviews VALUES ('history-overview','history-event',1,'hash',1,1,'Title','Summary','[]',NULL,'[]','synthesized',1,1); INSERT INTO event_overview_citations(id,overview_id,article_id,passage_id,passage_fingerprint,quote) VALUES ('history-citation','history-overview','historical-b','passage','fingerprint','Quoted original');"
        )
        sqlite3_close(handle)
        expectEqual(
            try await migrated.pruneOldArticles(keepReadDays: 30), 0,
            "A citation to any original protects the entire reconciled family")
        expectEqual(
            try await migrated.fetchArticles(limit: nil, includingOriginals: true).count, 8,
            "Citation retention preserves all family originals")
        try await migrated.deleteEventOverview(eventID: "history-event")
        expectEqual(
            try await migrated.pruneOldArticles(keepReadDays: 30), 3,
            "Retention removes an expired original family together")
        expectEqual(try await migrated.fetchArticles(limit: nil).count, 5, "Pruning never resurrects hidden originals")
        expectTrue(
            try await migrated.fetchArticles(id: "historical-b").isEmpty,
            "Pruned old IDs cannot point at resurrected copies")
        expectEqual(value(copy, "PRAGMA quick_check;"), "ok", "Migrated library passes quick_check")
        expectTrue(value(copy, "PRAGMA foreign_key_check;") == nil, "Reconciled families have no dangling foreign keys")
        await migrated.close()
    }

    @MainActor
    static func testIdentityBaselineScenarios(fixtureRoot: URL) async throws {
        print("  - Testing baseline query, mobile/AMP and publisher reprint scenarios...")
        func feedArticle(_ link: String, guid: String, feed: String) throws -> FeedArticle {
            let xml =
                "<rss><channel><title>Baseline publisher</title><item><title>Same headline</title><link><![CDATA[\(link)]]></link><guid>\(guid)</guid><description>Short publisher teaser.</description><pubDate>Thu, 01 Oct 2026 12:00:00 GMT</pubDate></item></channel></rss>"
            var article = try #require(FeedXMLParser(data: Data(xml.utf8), feedURL: feed).parse().first)
            article.identityFeedURL = feed
            return article
        }
        let feed = fixtureRoot.appendingPathComponent("baseline/feed").absoluteString
        for (index, key) in ["page", "article_id", "post", "lang", "reference"].enumerated() {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            let base = fixtureRoot.appendingPathComponent("baseline/query-\(index)").absoluteString
            let first = try feedArticle(base + "?\(key)=1&utm_source=rss", guid: "query-first", feed: feed)
            try await db.upsertArticles([first], feedUrl: feed)
            try await db.markRead(articleId: first.id, isRead: true)
            try await db.setSaved(articleId: first.id, isSaved: true)
            let trackingVariant = try feedArticle(base + "?\(key)=1&fbclid=changed", guid: "query-variant", feed: feed)
            expectTrue(
                try await db.upsertArticles([trackingVariant], feedUrl: feed).isEmpty,
                "Tracking-only \(key) variant reuses one document")
            let otherDocument = try feedArticle(base + "?\(key)=2&utm_medium=feed", guid: "query-other", feed: feed)
            try await db.upsertArticles([otherDocument], feedUrl: feed)
            expectEqual(
                try await db.fetchArticles(limit: nil).count, 2,
                "Meaningful \(key) value distinguishes documents with identical titles")
            expectTrue(try await db.isRead(articleId: trackingVariant.id), "Tracking variant resolves read history")
            expectTrue(try await db.isSaved(articleId: trackingVariant.id), "Tracking variant resolves saved history")
            expectFalse(
                try await db.isRead(articleId: otherDocument.id), "Different document has independent read state")
            expectEqual(
                ArticleIdentity.canonicalizeURL(base + "?\(key)=&\(key)=2&utm_campaign=test"),
                base + "?\(key)=&\(key)=2", "Empty and repeated meaningful query values survive")
            await db.close()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let pipeline = ContentExtractionPipeline(client: NewsTests.mockHTTPClient(configuration: configuration))
        defer { MockURLProtocol.requestHandler = nil }
        let desktop = fixtureRoot.appendingPathComponent("baseline/desktop/story")
        let prose = (1...65).map {
            "Baseline fact \($0) provides distinctive publisher evidence for the same document."
        }.joined(separator: " ")
        MockURLProtocol.requestHandler = { request in
            let html = "<html><body><article><p>\(prose)</p></article></body></html>"
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: request.url?.scheme == "https" ? 200 : 404, httpVersion: nil,
                    headerFields: nil)!, Data(html.utf8)
            )
        }
        var insecureStory = URLComponents(url: desktop, resolvingAgainstBaseURL: false)!
        insecureStory.scheme = "http"
        expectTrue(
            await pipeline.extractArticleWithIdentity(from: insecureStory.url!.absoluteString).outcome.isSuccess,
            "An http:// story link is read over https")
        for (status, expected) in [
            (401, ExtractionOutcome.subscriberOnly), (402, .subscriberOnly), (403, .httpError(status: 403)),
        ] {
            MockURLProtocol.requestHandler = { request in
                // A paywall page announcing more than the article limit still reports its status (#816).
                (
                    HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Length": "\(SecureHTTPClient.defaultArticleLimit + 1)"])!,
                    Data("<html><body>Subscribe</body></html>".utf8)
                )
            }
            expectEqual(
                await pipeline.extractArticleWithIdentity(from: desktop.absoluteString).outcome, expected,
                "HTTP \(status) from the publisher maps to its reader state over the network path")
        }
        for path in ["baseline/mobile/story", "baseline/amp/story"] {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            let requested = fixtureRoot.appendingPathComponent(path)
            let original = try feedArticle(requested.absoluteString, guid: "format-original", feed: feed)
            try await db.upsertArticles([original], feedUrl: feed)
            try await db.markRead(articleId: original.id, isRead: true)
            try await db.setSaved(articleId: original.id, isSaved: true)
            let variant = try feedArticle(desktop.absoluteString, guid: "format-variant", feed: feed)
            expectTrue(
                original.normalizedLink != variant.normalizedLink,
                "Mobile/AMP paths are not guessed equivalent by normalization")
            MockURLProtocol.requestHandler = { request in
                let html =
                    "<html><head><title>Same headline</title><link rel='canonical' href='\(desktop.absoluteString)'></head><body><article><p>\(prose)</p></article></body></html>"
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8)
                )
            }
            let result = await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
            let evidence = try #require(
                result.evidence, "Matching protected format fixture must produce evidence")
            expectTrue(evidence.urls.contains(desktop.absoluteString), "Matching format canonical is verified")
            try await db.recordDocumentIdentity(evidence, articleID: original.id)
            expectTrue(
                try await db.upsertArticles([variant], feedUrl: feed).isEmpty,
                "Verified mobile/AMP variant retains one document")
            expectEqual(try await db.fetchArticles(limit: nil).count, 1, "Format alias does not create a second card")
            expectTrue(try await db.isRead(articleId: variant.id), "Format alias retains reading history")
            expectTrue(try await db.isSaved(articleId: variant.id), "Format alias retains saved history")
            await db.close()
        }

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        var wire = try feedArticle(
            "https://wire.example/report", guid: "syndicated-guid", feed: "https://wire.example/rss")
        var reprint = try feedArticle(
            "https://outlet.example/report", guid: "syndicated-guid", feed: "https://outlet.example/rss")
        wire.fullContent = prose
        reprint.fullContent = prose
        // Use the same label too: host and subscription identity must still distinguish publishers.
        try await db.upsertArticles([wire], feedUrl: wire.identityFeedURL)
        try await db.upsertArticles([reprint], feedUrl: reprint.identityFeedURL)
        let stored = try await db.fetchArticles(limit: nil)
        expectEqual(
            stored.count, 2,
            "Identical wire text, headline, date and raw GUID across publishers remain two source documents")
        let wireID = try #require(stored.first { $0.link == wire.link }).id
        let reprintID = try #require(stored.first { $0.link == reprint.link }).id
        try await db.markRead(articleId: wireID, isRead: true)
        try await db.setSaved(articleId: wireID, isSaved: true)
        expectFalse(try await db.isRead(articleId: reprintID), "Reprint reading state stays independent")
        expectFalse(try await db.isSaved(articleId: reprintID), "Reprint saved state stays independent")
        await db.close()
    }

    static func testMigrationCoordinatorAtomicity() async throws {
        print("  - Testing MigrationCoordinator Atomic Transaction & ID Reconciliation...")

        let suiteName = testDefaultsSuite("com.marspater.news.test")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }

        let db = DatabaseEngine(path: ":memory:")
        try? await db.open()

        let coordinator = MigrationCoordinator(
            database: db,
            userDefaults: tempDefaults,
            fileManager: .default
        )

        // Check migration needed
        let neededBefore = await coordinator.isMigrationNeeded()
        expectTrue(neededBefore, "Migration should be needed initially")

        // Test isMigrationNeeded explicitly across various version states (unmigrated, current, future)
        let v0Suite = testDefaultsSuite("com.marspater.news.test")
        let version0Defaults = UserDefaults(suiteName: v0Suite)!
        defer { removeTestDefaults(v0Suite) }
        let coordinatorV0 = MigrationCoordinator(database: db, userDefaults: version0Defaults, fileManager: .default)
        expectTrue(
            await coordinatorV0.isMigrationNeeded(), "Migration should be needed when version is lower than current")

        let currentSuite = testDefaultsSuite("com.marspater.news.test")
        let currentDefaults = UserDefaults(suiteName: currentSuite)!
        defer { removeTestDefaults(currentSuite) }
        currentDefaults.set(
            MigrationCoordinator.currentMigrationVersion, forKey: MigrationCoordinator.migrationVersionKey)
        let coordinatorCurrent = MigrationCoordinator(
            database: db, userDefaults: currentDefaults, fileManager: .default)
        expectFalse(
            await coordinatorCurrent.isMigrationNeeded(), "Migration should not be needed when version equals current")

        let futureSuite = testDefaultsSuite("com.marspater.news.test")
        let futureDefaults = UserDefaults(suiteName: futureSuite)!
        defer { removeTestDefaults(futureSuite) }
        futureDefaults.set(
            MigrationCoordinator.currentMigrationVersion + 1, forKey: MigrationCoordinator.migrationVersionKey)
        let coordinatorFuture = MigrationCoordinator(database: db, userDefaults: futureDefaults, fileManager: .default)
        expectFalse(
            await coordinatorFuture.isMigrationNeeded(), "Migration should not be needed when version exceeds current")

        // Execute migration
        let stats = try? await coordinator.migrateIfNeeded()
        expectTrue(stats != nil, "Migration should succeed")

        // Check migration no longer needed
        let neededAfter = await coordinator.isMigrationNeeded()
        expectFalse(neededAfter, "Migration should no longer be needed after execution")

        let version = tempDefaults.integer(forKey: MigrationCoordinator.migrationVersionKey)
        expectEqual(version, MigrationCoordinator.currentMigrationVersion, "Migration version must be set to 1")

        // Legacy data that exists but can't be decoded is not a fresh install: the migration stays open (#946).
        let unreadableSuite = suiteName + ".unreadable"
        let unreadableDefaults = UserDefaults(suiteName: unreadableSuite)!
        defer { removeTestDefaults(unreadableSuite) }
        unreadableDefaults.set(Data("not json".utf8), forKey: "com.marspater.news.savedStories")
        let unreadableCoordinator = MigrationCoordinator(
            database: db, userDefaults: unreadableDefaults, fileManager: .default)
        let unreadableStats = try await unreadableCoordinator.migrateIfNeeded()
        expectEqual(unreadableStats.failures, 1, "Unreadable legacy data counts as a failure")
        expectTrue(
            await unreadableCoordinator.isMigrationNeeded(), "Unreadable legacy data keeps the migration open")
        expectTrue(
            unreadableDefaults.data(forKey: "com.marspater.news.savedStories") != nil, "Unreadable legacy data is kept")
        // With readable legacy data beside it, the import completes, so a later launch never replays stale state.
        unreadableDefaults.set(["legacy-read-only"], forKey: "com.marspater.news.readArticlesList")
        let partialStats = try await unreadableCoordinator.migrateIfNeeded()
        expectEqual(partialStats.failures, 1, "The unreadable part is still reported")
        expectFalse(
            await unreadableCoordinator.isMigrationNeeded(), "A migration that imported readable data completes")
        expectTrue(
            unreadableDefaults.data(forKey: "com.marspater.news.savedStories") != nil,
            "Unreadable legacy data is still kept")

        // Real legacy data: a saved story, and a read list that also names a story no longer cached.
        let legacySuite = suiteName + ".legacy"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { removeTestDefaults(legacySuite) }
        let savedStory = FeedArticle(
            title: "Legacy saved story", link: "https://news.example/legacy-saved", guid: "legacy-saved",
            description: "", pubDate: Date(), source: "Legacy")
        legacyDefaults.set(try JSONEncoder().encode([savedStory]), forKey: "com.marspater.news.savedStories")
        legacyDefaults.set(
            [savedStory.id, "legacy-story-no-longer-cached"], forKey: "com.marspater.news.readArticlesList")
        let legacyDB = DatabaseEngine(path: ":memory:")
        try await legacyDB.open()
        let legacyStats = try await MigrationCoordinator(
            database: legacyDB, userDefaults: legacyDefaults, fileManager: .default
        ).migrateIfNeeded()
        expectEqual(legacyStats.articlesImported, 1, "Legacy saved stories are imported")
        expectTrue(try await legacyDB.isSaved(articleId: savedStory.id), "Legacy saved state survives migration")
        expectTrue(try await legacyDB.isRead(articleId: savedStory.id), "Legacy read state survives migration")
        expectEqual(
            legacyDefaults.integer(forKey: MigrationCoordinator.migrationVersionKey),
            MigrationCoordinator.currentMigrationVersion,
            "A read entry without a cached story does not block migration")
        await legacyDB.close()
    }
}
