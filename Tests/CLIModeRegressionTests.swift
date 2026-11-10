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
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// The migration and feed-parsing runner tests the CLI modes still call (`--story-regressions`,
/// `--fts-refresh-regression` in NewsTests.swift). Their atoms moved to Tests/Native (MigrationSuite,
/// FeedParsingSuite) under #1070; this file has no entry point and no atom of its own.
extension NewsTests {
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
            assertEqual(sqlite3_open(file, &handle), SQLITE_OK, "Open isolated FTS fixture")
            defer { sqlite3_close(handle) }
            assertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Prepare FTS fixture")
        }
        func value(_ file: String, _ sql: String) -> String? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            assertEqual(sqlite3_open(file, &handle), SQLITE_OK, "Inspect isolated FTS fixture")
            defer { sqlite3_close(handle) }
            assertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "Prepare FTS inspection")
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
            assertTrue(false, "Cancelled FTS migration must throw")
        } catch is CancellationError {}
        assertEqual(value(copy, "PRAGMA user_version;"), "14", "Cancellation keeps the old version")
        assertEqual(value(copy, "SELECT count(*) FROM articles_fts;"), "3", "Cancellation preserves the old FTS index")

        // Fail after the old FTS table has been dropped, exercising transactional DDL rollback.
        execute(copy, "CREATE VIEW article_fts_rows AS SELECT 1;")
        let db = DatabaseEngine(path: copy)
        do {
            try await db.open()
            assertTrue(false, "Injected migration failure must throw")
        } catch {}
        assertEqual(value(copy, "PRAGMA user_version;"), "14", "Failed rebuild keeps the old version")
        assertEqual(
            value(copy, "SELECT count(*) FROM articles_fts WHERE articles_fts MATCH 'Research';"), "3",
            "Failed rebuild restores the old searchable index")
        assertEqual(
            value(
                copy,
                "SELECT count(*) FROM sqlite_master WHERE name IN ('trg_articles_ai','trg_articles_ad','trg_articles_au');"
            ), "3", "Failed rebuild restores the old triggers")
        execute(copy, "DROP VIEW article_fts_rows;")
        try await db.open()
        assertEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v14 library upgrades through v15 to the current schema")
        assertEqual(
            value(copy, "SELECT count(*) FROM articles WHERE category IS NOT NULL;"), "0",
            "A library from before v22 keeps none of the classifier labels v22 wrote into the publisher column (#817)")
        assertEqual(
            value(
                copy,
                "SELECT count(*) FROM articles a WHERE NOT EXISTS (SELECT 1 FROM article_enrichment ae WHERE ae.article_id = a.id AND ae.category IS NOT NULL);"
            ), "0", "Every article from before v22 keeps a classifier category in article_enrichment (#817)")
        assertEqual(value(path, "PRAGMA user_version;"), "14", "Original library stays untouched")
        assertEqual(
            try await db.searchArticles(query: "Research").map(\.id), originalOrder,
            "Migration preserves ranks and ID tie order")
        assertEqual(
            value(copy, "SELECT read_at FROM article_state WHERE article_id='one';"), readAt,
            "Migration preserves read timestamps")
        assertEqual(
            value(copy, "SELECT saved_at FROM article_state WHERE article_id='two';"), savedAt,
            "Migration preserves saved timestamps")
        assertEqual(
            try await db.fetchEvent(id: event.id)?.memberArticleIDs.count, 2, "Migration preserves event membership")
        let key = value(copy, "SELECT fts_rowid FROM article_fts_rows WHERE article_id='one';")
        await db.close()
        // Explicitly relocate an article's hidden rowid: the mapping must use its durable ID.
        execute(copy, "UPDATE articles SET rowid=rowid+100 WHERE id='one'; VACUUM;")
        try await db.open()
        assertEqual(
            value(copy, "SELECT fts_rowid FROM article_fts_rows WHERE article_id='one';"), key,
            "Durable FTS key survives rowid relocation and VACUUM")
        assertEqual(
            try await db.searchArticles(query: "Research").map(\.id), originalOrder,
            "Search still joins the correct publications")
        let candidates = try await db.eventCandidateRows(
            matching: "Research", around: now, window: 48 * 3600,
            activeSince: now.addingTimeInterval(-72 * 3600), excluding: "one", limit: 10)
        assertEqual(Set(candidates.map(\.id)), ["two", "three"], "Candidate joins survive VACUUM")
        await db.close()
        execute(copy, "PRAGMA foreign_keys=ON; DELETE FROM articles WHERE id='three';")
        assertEqual(value(copy, "SELECT count(*) FROM article_fts_rows;"), "2", "Deletion removes the mapping")
        assertEqual(
            value(copy, "SELECT count(*) FROM articles_fts WHERE article_id='three';"), "0",
            "Deletion removes FTS postings")
        execute(copy, "BEGIN; DELETE FROM articles WHERE id='one'; ROLLBACK;")
        assertEqual(
            value(copy, "SELECT fts_rowid FROM article_fts_rows WHERE article_id='one';"), key,
            "Rolled-back deletion restores the mapping")
        assertEqual(
            value(copy, "SELECT count(*) FROM articles_fts WHERE article_id='one';"), "1",
            "Rolled-back deletion restores FTS")
        assertEqual(value(copy, "PRAGMA quick_check;"), "ok", "Migrated database passes quick_check")
        assertEqual(value(copy, "PRAGMA foreign_key_check;"), nil, "Migrated database has no dangling references")
        execute(copy, "INSERT INTO articles_fts(articles_fts) VALUES('integrity-check');")
    }

    static func testRealLibraryMigrationFixture() async throws {
        print("  - Testing real-library v14 migration fixture in CI (#539)...")
        let fixtureSource = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/legacy-library-v14.sqlite3")
        assertTrue(
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
            assertEqual(sqlite3_open(file, &handle), SQLITE_OK, "Open migrated fixture for inspection")
            defer { sqlite3_close(handle) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }

        assertEqual(value(workingCopy.path, "PRAGMA user_version;"), "14", "Fixture starts at schema v14")
        let db = DatabaseEngine(path: workingCopy.path)
        try await db.open()
        assertEqual(
            value(workingCopy.path, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Fixture migrates cleanly to current schema v26 (#539)"
        )
        assertEqual(
            value(workingCopy.path, "PRAGMA auto_vacuum;"), "2",
            "Migrated fixture enables incremental auto_vacuum (#536)"
        )
        assertEqual(
            value(workingCopy.path, "PRAGMA quick_check;"), "ok",
            "Migrated fixture passes PRAGMA quick_check (#539)"
        )
        assertEqual(
            value(workingCopy.path, "PRAGMA foreign_key_check;"), nil,
            "Migrated fixture passes PRAGMA foreign_key_check (#539)"
        )

        let counts = try await db.counts()
        assertEqual(counts.total, 200, "Migrated fixture preserves all 200 articles")
        assertEqual(
            try await db.fetchArticles(isRead: false, limit: nil).count, 150,
            "Migrated fixture preserves unread reports (150)")
        assertEqual(counts.saved, 20, "Migrated fixture preserves saved count (20)")

        let fetched = try await db.fetchArticles(limit: 500)
        assertEqual(fetched.count, 200, "fetchArticles(limit: 500) returns all 200 migrated stories")
        let searchResults = try await db.searchArticles(query: "Observatory", limit: 500)
        assertEqual(searchResults.count, 200, "Migrated FTS5 index searches all 200 stories")
        let event = try await db.fetchEvent(id: "legacy-event-00")
        assertEqual(event?.memberArticleIDs.count, 3, "Migrated fixture preserves event memberships")
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
            assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated batch fixture")
            defer { sqlite3_close(handle) }
            assertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Modify isolated batch fixture")
        }
        let aliases = (0..<405).map { "batch-alias-\($0)" }
        execute(
            aliases.enumerated().map { index, alias in
                "INSERT INTO article_aliases(kind, value, article_id) VALUES ('id', '\(alias)', '\(articles[index % 2].id)');"
            }.joined() + "INSERT INTO article_aliases(kind, value, article_id) VALUES ('id', 'batch-ambiguous', NULL);")
        let composed = "batch-caf\u{00E9}"
        let decomposed = "batch-cafe\u{0301}"
        assertTrue(composed == decomposed, "Swift considers the two Unicode spellings equal")
        assertFalse(Data(composed.utf8) == Data(decomposed.utf8), "SQLite BINARY keys distinguish their bytes")
        execute(
            "INSERT INTO article_aliases VALUES ('id', '\(composed)', 'batch-first'); INSERT INTO article_aliases VALUES ('id', '\(decomposed)', 'batch-second');"
        )
        assertEqual(
            try await db.resolvedArticleID(composed), articles[0].id,
            "The single-ID lookup distinguishes the first spelling")
        assertEqual(
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
        assertEqual(
            try await db.resolvedArticleIDs(input), expected,
            "Chunks preserve order, duplicates and absent/NULL fallbacks")
        assertEqual(try await db.resolvedArticleIDs([]), [], "Empty resolution needs no query")
        try await db.markReadBatch(articleIds: [], isRead: true)
        try await db.batchMarkSaved([])
        try await db.markReadBatch(articleIds: aliases, isRead: true)
        try await db.batchMarkSaved(Set(aliases))
        for article in articles {
            assertTrue(try await db.isRead(articleId: article.id), "Batch reads reach the alias target")
            assertTrue(try await db.isSaved(articleId: article.id), "Batch saves preserve read state")
        }
        execute(
            "CREATE TRIGGER fail_batch BEFORE INSERT ON article_state WHEN NEW.article_id = 'batch-second' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"
        )
        do {
            try await db.markReadBatch(articleIds: [aliases[0], aliases[1]], isRead: false)
            assertTrue(false, "A failed write must abort the read batch")
        } catch {
            assertTrue(try await db.isRead(articleId: articles[0].id), "An earlier read update rolls back")
        }
        execute("DROP TRIGGER fail_batch;")
        for article in articles { try await db.setSaved(articleId: article.id, isSaved: false) }
        execute(
            "CREATE TRIGGER fail_batch BEFORE INSERT ON article_state WHEN NEW.article_id = 'batch-second' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;"
        )
        do {
            try await db.batchMarkSaved(Set(aliases))
            assertTrue(false, "A failed write must abort the saved batch")
        } catch {
            for article in articles {
                assertFalse(try await db.isSaved(articleId: article.id), "No failed batch save persists")
            }
        }
        execute("DROP TRIGGER fail_batch; DROP TABLE article_aliases;")
        do {
            _ = try await db.resolvedArticleIDs(aliases)
            assertTrue(false, "Alias query errors must propagate")
        } catch {
            assertTrue(
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
            assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated alias fixture")
            defer { sqlite3_close(handle) }
            assertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Modify isolated alias fixture")
        }
        func value(_ path: String, _ sql: String) -> String? {
            var handle: OpaquePointer?
            assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated alias verification")
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            assertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "Prepare alias verification")
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
            assertTrue(false, "Cancelled migration must be reported")
        } catch is CancellationError {
            assertEqual(value(cancelledPath, "PRAGMA user_version;"), "4", "Cancelled migration leaves the old version")
            assertEqual(
                value(cancelledPath, "SELECT count(*) FROM sqlite_master WHERE name = 'article_aliases';"), "0",
                "Cancelled migration rolls back the alias schema")
            assertEqual(
                value(cancelledPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';"),
                originalReadAt, "Cancelled migration preserves history")
        }
        try await cancelledDB.open()
        await cancelledDB.close()
        let db = DatabaseEngine(path: copyPath)
        try await db.open()
        assertEqual(
            value(copyPath, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied v4 library upgrades to the current schema")
        assertEqual(value(originalPath, "PRAGMA user_version;"), "4", "Original fixture stays untouched")
        assertEqual(try await db.fetchArticles(limit: nil).count, 3, "Migration keeps historical rows")
        assertEqual(
            value(copyPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';"), originalReadAt,
            "Migration preserves read history timestamp")
        assertEqual(
            value(copyPath, "SELECT saved_at FROM article_state WHERE article_id = 'alias-first';"), originalSavedAt,
            "Migration preserves bookmark timestamp")
        assertTrue(try await db.isRead(articleId: first.id), "Migration preserves read state")
        assertTrue(try await db.isSaved(articleId: first.id), "Migration preserves saved state")
        assertEqual(try await db.searchArticles(query: "Original").first?.id, first.id, "Migration preserves FTS")
        assertEqual(
            value(copyPath, "SELECT count(*) FROM article_aliases WHERE kind = 'url' AND article_id IS NULL;"), "1",
            "Conflicting historical URL is marked ambiguous")
        let unknown = FeedArticle(
            title: "Unknown identity", link: duplicateA.link, guid: "unknown-guid", description: "Report",
            pubDate: Date(), source: "Publisher")
        assertEqual(
            try await db.resolvedArticleID(for: unknown), unknown.id, "Ambiguous URL never selects a historical row")
        assertTrue(
            try await db.fetchArticles(limit: 1, options: ArticleFetchOptions(canonicalURL: duplicateA.normalizedLink))
                .isEmpty,
            "Ambiguous notification URL must not choose a document")
        execute(copyPath, "PRAGMA foreign_keys = ON; DELETE FROM articles WHERE id = 'historical-a';")
        assertTrue(
            try await db.fetchArticles(limit: 1, options: ArticleFetchOptions(canonicalURL: duplicateA.normalizedLink))
                .isEmpty,
            "Removing a conflicting row must not revive an ambiguous URL")
        assertEqual(
            try await db.resolvedArticleID(for: unknown), unknown.id, "Ambiguous URL remains unusable after deletion")

        func variant(_ guid: String, _ link: String, _ title: String) -> FeedArticle {
            var article = FeedArticle(
                title: title, link: link, guid: guid, description: first.description, pubDate: first.pubDate,
                source: first.source)
            article.identityFeedURL = "test-feed"
            return article
        }
        let second = variant("alias-second", first.link, first.title)
        assertTrue(
            try await db.upsertArticles([second], feedUrl: "test-feed").isEmpty, "Same URL registers a new observed ID")
        let moved = variant(
            "alias-second", fixtureRoot.appendingPathComponent("aliases/moved").absoluteString, "Migrated report")
        assertTrue(
            try await db.upsertArticles([moved], feedUrl: "test-feed").isEmpty,
            "Observed replacement GUID carries a URL change")
        await db.close()
        try await db.open()
        assertEqual(try await db.fetchArticles(limit: 1, id: second.id).first?.id, first.id, "ID alias survives reopen")
        assertEqual(
            try await db.fetchArticles(limit: 1, options: ArticleFetchOptions(canonicalURL: first.normalizedLink))
                .first?.id, first.id,
            "Previous URL survives replacement and reopen")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let navigation = ArticleStore.NavigationRequest(articleID: second.id, link: "")
        assertEqual(
            try await store.articleForNavigation(navigation)?.id, first.id,
            "Old notification ID resolves to stored article")
        await store.markAsRead(id: second.id, isRead: false)
        assertFalse(store.readArticleIDs.contains(first.id), "Read cache changes the stored ID")
        await store.toggleRead(id: second.id)
        assertTrue(store.readArticleIDs.contains(first.id), "Read toggle resolves alias before consulting cached state")
        await store.toggleRead(id: second.id)
        assertFalse(try await db.isRead(articleId: first.id), "Second alias toggle marks the original unread")
        assertFalse(await store.toggleSave(article: moved), "Saved toggle through an alias unsaves the original")
        assertTrue(await store.toggleSave(article: moved), "Second saved toggle restores the original bookmark")
        try await db.markReadBatch(articleIds: [second.id], isRead: true)
        try await db.setSaved(articleId: second.id, isSaved: false)
        try await db.batchMarkSaved([second.id])
        assertTrue(try await db.isRead(articleId: second.id), "Batch read and lookup resolve aliases")
        assertTrue(try await db.isSaved(articleId: second.id), "Batch saved and lookup resolve aliases")
        assertEqual(
            try await db.searchArticles(query: "Migrated").first?.id, first.id,
            "Updated FTS uses the original primary key")
        await store.refreshState()
        await store.updateEnrichment(id: second.id, content: "Verified evidence")
        assertEqual(
            store.articles.first(where: { $0.id == first.id })?.fullContent, "Verified evidence",
            "Alias enrichment updates the visible stored article")
        assertEqual(
            try await db.fetchArticles(id: first.id).first?.fullContent, "Verified evidence",
            "Enrichment through an alias updates the original")
        let analysis = ArticleAnalysis(
            summary: "Cited summary", keyPoints: ["Finding"], entities: [], category: "Science", sentiment: nil,
            modelIdentifier: "test", analysisVersion: 1)
        await store.saveArticleAnalysis(analysis, for: second.id)
        assertEqual(
            store.savedArticles.first(where: { $0.id == first.id })?.aiSummary, analysis.summary,
            "Alias analysis updates the saved article cache")
        assertEqual(
            await db.fetchArticleAnalysis(for: second.id)?.summary, analysis.summary,
            "Analysis persistence and lookup resolve aliases")
        let returned = variant("alias-third", first.link, "Returned report")
        assertTrue(try await db.upsertArticles([returned]).isEmpty, "Old URL recognizes a further GUID change")
        let simultaneous = variant(
            "alias-second", fixtureRoot.appendingPathComponent("aliases/third-location").absoluteString, first.title)
        assertTrue(try await db.upsertArticles([simultaneous]).isEmpty, "Known ID and changed URL resolve together")
        let unrelated = variant(
            "never-observed", fixtureRoot.appendingPathComponent("aliases/unrelated").absoluteString, first.title)
        assertEqual(
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
        assertTrue(
            inserted.contains(batchItem.id),
            "Valid batch items are stored when a conflicting item is in the batch (#885)")
        assertEqual(
            try await db.fetchArticles(id: first.id).first?.title, "Original report",
            "Conflicting signals must not overwrite the original")
        assertEqual(
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
            assertTrue(false, "Alias failure must be reported")
        } catch {
            assertEqual(
                try await db.fetchArticles(limit: 1, id: first.id).first?.title, "Original report",
                "Failed alias update restores the previous article")
            assertTrue(try await db.searchArticles(query: "rollback").isEmpty, "Failed alias write rolls back FTS")
            assertEqual(try await db.resolvedArticleID(failed.id), failed.id, "Failed alias is never committed")
        }
        execute(copyPath, "DROP TRIGGER fail_alias;")
        assertEqual(value(copyPath, "PRAGMA quick_check;"), "ok", "Migrated alias library passes quick_check")
        assertTrue(value(copyPath, "PRAGMA foreign_key_check;") == nil, "Migrated aliases have no dangling targets")
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
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated historical fixture")
        func execute(_ sql: String) {
            assertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "Execute historical fixture SQL")
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
            assertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "Prepare original article")
            for (column, value) in [row.0, row.0, row.1, body, row.2].enumerated() {
                sqlite3_bind_text(statement, Int32(column + 1), value, -1, transient)
            }
            sqlite3_bind_double(statement, 6, Double(index + 10))
            assertEqual(sqlite3_step(statement), SQLITE_DONE, "Insert historical article without modern deduplication")
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
        assertEqual(
            sqlite3_prepare_v2(handle, "INSERT INTO article_aliases VALUES ('url',?,NULL);", -1, &alias, nil),
            SQLITE_OK, "Prepare ambiguous URL")
        sqlite3_bind_text(alias, 1, url, -1, transient)
        assertEqual(sqlite3_step(alias), SQLITE_DONE, "Retain uncertain shared URL")
        sqlite3_finalize(alias)
        let historical = FeedArticle(
            title: "Historical report", link: url, guid: nil,
            description: body, pubDate: Date(timeIntervalSince1970: 100), source: "Publisher", fullContent: body)
        for fingerprint in ArticleIdentity.publisherTextFingerprints(historical) {
            assertEqual(
                sqlite3_prepare_v2(handle, "INSERT INTO article_aliases VALUES ('content',?,NULL);", -1, &alias, nil),
                SQLITE_OK, "Prepare ambiguous historical content")
            sqlite3_bind_text(alias, 1, fingerprint, -1, transient)
            assertEqual(sqlite3_step(alias), SQLITE_DONE, "Retain content ambiguity")
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
            assertTrue(false, "Cancelled reconciliation must throw")
        } catch is CancellationError {}
        func value(_ file: String, _ sql: String) -> String? {
            var connection: OpaquePointer?
            var statement: OpaquePointer?
            assertEqual(sqlite3_open(file, &connection), SQLITE_OK, "Inspect copied fixture")
            defer { sqlite3_close(connection) }
            assertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare inspection")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        assertEqual(value(copy, "PRAGMA user_version;"), "8", "Cancellation rolls back the schema version")
        assertEqual(
            value(copy, "SELECT count(*) FROM sqlite_master WHERE name='article_reconciliations';"), "0",
            "Cancellation rolls back newly created reconciliation tables")
        assertEqual(sqlite3_open(failure, &handle), SQLITE_OK, "Inject copied-library failure")
        execute(
            "CREATE TRIGGER fail_reconciliation BEFORE UPDATE ON article_aliases WHEN old.article_id='historical-b' BEGIN SELECT RAISE(ABORT,'fixture'); END;"
        )
        sqlite3_close(handle)
        let failed = DatabaseEngine(path: failure)
        do {
            try await failed.open()
            assertTrue(false, "Failed alias retargeting must abort migration")
        } catch {}
        assertEqual(value(failure, "PRAGMA user_version;"), "8", "Injected failure rolls back migration version")
        assertEqual(
            value(failure, "SELECT is_saved FROM article_state WHERE article_id='historical-a';"), "0",
            "Injected failure rolls back survivor state union")
        assertEqual(
            value(failure, "SELECT article_id FROM article_aliases WHERE value='observed-variant-b';"), "historical-b",
            "Injected failure preserves old aliases")
        try await migrated.open()
        assertEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Copied library upgrades to the current schema")
        assertEqual(value(path, "PRAGMA user_version;"), "8", "Original fixture remains untouched")
        assertEqual(
            try await migrated.fetchArticles(limit: nil).count, 6, "Only confident same-URL text copies are hidden")
        assertEqual(
            try await migrated.fetchArticles(limit: nil, options: ArticleFetchOptions(includingOriginals: true)).count,
            8,
            "Every stored original remains reachable")
        assertEqual(
            try await migrated.fetchArticles(id: "historical-b").first?.id, "historical-a",
            "Old IDs navigate to the survivor")
        assertEqual(
            try await migrated.fetchArticles(id: "observed-variant-b").first?.id, "historical-a",
            "Observed old ID aliases follow the survivor")
        assertEqual(
            try await migrated.fetchArticles(id: "historical-b", options: ArticleFetchOptions(includingOriginals: true))
                .first?.aiSummary, nil,
            "Unversioned original analysis is invalidated by the provenance migration")
        assertEqual(
            try await migrated.fetchArticles(id: "historical-b", options: ArticleFetchOptions(includingOriginals: true))
                .first?.fullContent, body,
            "Original publisher text is retained")
        assertTrue(try await migrated.isRead(articleId: "historical-b"), "Read flags are unioned")
        assertTrue(try await migrated.isSaved(articleId: "historical-a"), "Saved flags are unioned")
        assertEqual(
            value(copy, "SELECT read_at || ':' || saved_at FROM article_state WHERE article_id='historical-a';"),
            "33.0:44.0", "Survivor carries latest known history timestamps")
        assertEqual(
            value(copy, "SELECT read_at FROM article_reconciliation_history WHERE article_id='historical-a';"), "11.0",
            "Survivor's original read timestamp remains intact")
        assertEqual(
            value(copy, "SELECT saved_at FROM article_reconciliation_history WHERE article_id='historical-b';"), "22.0",
            "Duplicate's original bookmark timestamp remains intact")
        assertEqual(
            value(copy, "SELECT count(*) FROM article_feeds WHERE article_id='historical-a';"), "2",
            "Feed associations are unioned without multiplying articles")
        assertEqual(try await migrated.counts().total, 6, "Counts hide reconciled copies")
        assertEqual(try await migrated.counts().saved, 1, "Bookmarks count surviving documents")
        assertEqual(try await migrated.getReadArticleIDs(), Set(["historical-a"]), "Read cache uses surviving IDs")
        assertEqual(try await migrated.searchArticles(query: "Historical").count, 6, "FTS hides reconciled copies")
        assertEqual(
            value(copy, "SELECT count(*) FROM article_feeds WHERE article_id='historical-a' AND feed_url='feed-b';"),
            "1", "Other original feed remains associated with the survivor")
        let incoming = FeedArticle(
            title: "Historical report", link: url, guid: "fresh-guid", description: body,
            pubDate: Date(timeIntervalSince1970: 100), source: "Publisher", fullContent: body)
        assertTrue(
            try await migrated.upsertArticles([incoming]).isEmpty,
            "Proven family evidence prevents refreshed variants from reappearing")
        assertTrue(
            try await migrated.fetchArticles(options: ArticleFetchOptions(canonicalURL: url)).isEmpty,
            "Uncertain URL tombstone is never revived")
        assertEqual(
            value(copy, "SELECT count(*) FROM article_aliases WHERE kind='content' AND article_id IS NULL;"), "2",
            "Historical evidence never revives ambiguous content aliases")
        try await migrated.clearArticleCache()
        assertEqual(
            try await migrated.fetchArticles(id: "historical-b", options: ArticleFetchOptions(includingOriginals: true))
                .first?.fullContent, body,
            "Saved family originals survive content cache purging")
        await migrated.close()
        try await migrated.open()
        assertEqual(
            try await migrated.fetchArticles(id: "historical-c").first?.id, "historical-a",
            "Reconciled identities survive reopening")
        try await migrated.setSaved(articleId: "historical-b", isSaved: false)
        assertFalse(
            try await migrated.isSaved(articleId: "historical-a"), "Old-ID actions update the surviving bookmark")
        assertEqual(sqlite3_open(copy, &handle), SQLITE_OK, "Add an overview citing a retained original")
        execute(
            "PRAGMA foreign_keys = ON; INSERT INTO event_overviews VALUES ('history-overview','history-event',1,'hash',1,1,'Title','Summary','[]',NULL,'[]','synthesized',1,1); INSERT INTO event_overview_citations(id,overview_id,article_id,passage_id,passage_fingerprint,quote) VALUES ('history-citation','history-overview','historical-b','passage','fingerprint','Quoted original');"
        )
        sqlite3_close(handle)
        assertEqual(
            try await migrated.pruneOldArticles(keepReadDays: 30), 0,
            "A citation to any original protects the entire reconciled family")
        assertEqual(
            try await migrated.fetchArticles(limit: nil, options: ArticleFetchOptions(includingOriginals: true)).count,
            8,
            "Citation retention preserves all family originals")
        try await migrated.deleteEventOverview(eventID: "history-event")
        assertEqual(
            try await migrated.pruneOldArticles(keepReadDays: 30), 3,
            "Retention removes an expired original family together")
        assertEqual(try await migrated.fetchArticles(limit: nil).count, 5, "Pruning never resurrects hidden originals")
        assertTrue(
            try await migrated.fetchArticles(id: "historical-b").isEmpty,
            "Pruned old IDs cannot point at resurrected copies")
        assertEqual(value(copy, "PRAGMA quick_check;"), "ok", "Migrated library passes quick_check")
        assertTrue(value(copy, "PRAGMA foreign_key_check;") == nil, "Reconciled families have no dangling foreign keys")
        await migrated.close()
    }

    @MainActor
    static func testIdentityBaselineScenarios(fixtureRoot: URL) async throws {
        print("  - Testing baseline query, mobile/AMP and publisher reprint scenarios...")
        func feedArticle(_ link: String, guid: String, feed: String) -> FeedArticle {
            let xml =
                "<rss><channel><title>Baseline publisher</title><item><title>Same headline</title><link><![CDATA[\(link)]]></link><guid>\(guid)</guid><description>Short publisher teaser.</description><pubDate>Thu, 01 Oct 2026 12:00:00 GMT</pubDate></item></channel></rss>"
            var article = FeedXMLParser(data: Data(xml.utf8), feedURL: feed).parse().first!
            article.identityFeedURL = feed
            return article
        }
        let feed = fixtureRoot.appendingPathComponent("baseline/feed").absoluteString
        for (index, key) in ["page", "article_id", "post", "lang", "reference"].enumerated() {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            let base = fixtureRoot.appendingPathComponent("baseline/query-\(index)").absoluteString
            let first = feedArticle(base + "?\(key)=1&utm_source=rss", guid: "query-first", feed: feed)
            try await db.upsertArticles([first], feedUrl: feed)
            try await db.markRead(articleId: first.id, isRead: true)
            try await db.setSaved(articleId: first.id, isSaved: true)
            let trackingVariant = feedArticle(base + "?\(key)=1&fbclid=changed", guid: "query-variant", feed: feed)
            assertTrue(
                try await db.upsertArticles([trackingVariant], feedUrl: feed).isEmpty,
                "Tracking-only \(key) variant reuses one document")
            let otherDocument = feedArticle(base + "?\(key)=2&utm_medium=feed", guid: "query-other", feed: feed)
            try await db.upsertArticles([otherDocument], feedUrl: feed)
            assertEqual(
                try await db.fetchArticles(limit: nil).count, 2,
                "Meaningful \(key) value distinguishes documents with identical titles")
            assertTrue(try await db.isRead(articleId: trackingVariant.id), "Tracking variant resolves read history")
            assertTrue(try await db.isSaved(articleId: trackingVariant.id), "Tracking variant resolves saved history")
            assertFalse(
                try await db.isRead(articleId: otherDocument.id), "Different document has independent read state")
            assertEqual(
                ArticleIdentity.canonicalizeURL(base + "?\(key)=&\(key)=2&utm_campaign=test"),
                base + "?\(key)=&\(key)=2", "Empty and repeated meaningful query values survive")
            await db.close()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let pipeline = ContentExtractionPipeline(client: mockHTTPClient(configuration: configuration))
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
        assertTrue(
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
            assertEqual(
                await pipeline.extractArticleWithIdentity(from: desktop.absoluteString).outcome, expected,
                "HTTP \(status) from the publisher maps to its reader state over the network path")
        }
        for path in ["baseline/mobile/story", "baseline/amp/story"] {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            let requested = fixtureRoot.appendingPathComponent(path)
            let original = feedArticle(requested.absoluteString, guid: "format-original", feed: feed)
            try await db.upsertArticles([original], feedUrl: feed)
            try await db.markRead(articleId: original.id, isRead: true)
            try await db.setSaved(articleId: original.id, isSaved: true)
            let variant = feedArticle(desktop.absoluteString, guid: "format-variant", feed: feed)
            assertTrue(
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
            guard let evidence = result.evidence else {
                fatalError("Matching protected format fixture must produce evidence")
            }
            assertTrue(evidence.urls.contains(desktop.absoluteString), "Matching format canonical is verified")
            try await db.recordDocumentIdentity(evidence, articleID: original.id)
            assertTrue(
                try await db.upsertArticles([variant], feedUrl: feed).isEmpty,
                "Verified mobile/AMP variant retains one document")
            assertEqual(try await db.fetchArticles(limit: nil).count, 1, "Format alias does not create a second card")
            assertTrue(try await db.isRead(articleId: variant.id), "Format alias retains reading history")
            assertTrue(try await db.isSaved(articleId: variant.id), "Format alias retains saved history")
            await db.close()
        }

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        var wire = feedArticle("https://wire.example/report", guid: "syndicated-guid", feed: "https://wire.example/rss")
        var reprint = feedArticle(
            "https://outlet.example/report", guid: "syndicated-guid", feed: "https://outlet.example/rss")
        wire.fullContent = prose
        reprint.fullContent = prose
        // Use the same label too: host and subscription identity must still distinguish publishers.
        try await db.upsertArticles([wire], feedUrl: wire.identityFeedURL)
        try await db.upsertArticles([reprint], feedUrl: reprint.identityFeedURL)
        let stored = try await db.fetchArticles(limit: nil)
        assertEqual(
            stored.count, 2,
            "Identical wire text, headline, date and raw GUID across publishers remain two source documents")
        let wireID = stored.first { $0.link == wire.link }!.id
        let reprintID = stored.first { $0.link == reprint.link }!.id
        try await db.markRead(articleId: wireID, isRead: true)
        try await db.setSaved(articleId: wireID, isSaved: true)
        assertFalse(try await db.isRead(articleId: reprintID), "Reprint reading state stays independent")
        assertFalse(try await db.isSaved(articleId: reprintID), "Reprint saved state stays independent")
        await db.close()
    }

    /// #981: a feed date beyond clock skew is stored as unknown (ordered by ingestion time, pruned with its
    /// neighbours) in every format; a few minutes ahead keeps its date.
    static func testFutureDatedItems() async throws {
        print("  - Testing future-dated feed items...")
        // A fixed clock handed to every upsert keeps the test off the wall clock.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let soon = iso.string(from: now.addingTimeInterval(300))
        let rss = """
            <rss><channel><title>Wire</title>
            <item><title>RSS future</title><link>https://example.com/rss-future</link><pubDate>Sat, 01 Jan 2050 00:00:00 GMT</pubDate></item>
            <item><title>RSS skew</title><link>https://example.com/rss-skew</link><pubDate>\(iso.string(from: now.addingTimeInterval(300)))</pubDate></item>
            </channel></rss>
            """
        let atom = """
            <feed xmlns='http://www.w3.org/2005/Atom'><title>Wire</title>
            <entry><id>atom-future</id><title>Atom future</title><link href='https://example.com/atom-future'/><published>2050-01-01T00:00:00Z</published></entry>
            <entry><id>atom-skew</id><title>Atom skew</title><link href='https://example.com/atom-skew'/><published>\(soon)</published></entry>
            </feed>
            """
        let json = """
            {"version":"https://jsonfeed.org/version/1.1","title":"Wire","items":[
            {"id":"json-future","url":"https://example.com/json-future","title":"JSON future","content_text":"Text","date_published":"2050-01-01T00:00:00Z"},
            {"id":"json-skew","url":"https://example.com/json-skew","title":"JSON skew","content_text":"Text","date_published":"\(soon)"}]}
            """
        let articles =
            FeedXMLParser(data: Data(rss.utf8), feedURL: "https://example.com/rss").parse()
            + FeedXMLParser(data: Data(atom.utf8), feedURL: "https://example.com/atom").parse()
            + (JSONFeedParser.parse(data: Data(json.utf8), feedURL: "https://example.com/json") ?? [])
        assertEqual(articles.count, 6, "All three formats parse")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        try await db.upsertArticles(articles, now: now)
        let stored = try await db.fetchArticles()
        for format in ["RSS", "Atom", "JSON"] {
            let future = stored.first { $0.title == "\(format) future" }
            let skew = stored.first { $0.title == "\(format) skew" }
            assertEqual(future?.pubDate, DateParser.unknownDate, "\(format): a date years ahead is stored as unknown")
            assertTrue(
                abs((future?.queryOrderValue ?? 0) - now.timeIntervalSince1970) < 60,
                "\(format): the future-dated story lists by its ingestion time")
            assertTrue(
                abs((skew?.pubDate.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970 - 300) < 5,
                "\(format): clock skew keeps the date")
        }
        let futureCard = await MainActor.run { stored.first { $0.title == "RSS future" }?.cardDateText() }
        assertTrue(futureCard?.hasPrefix("Added ") == true, "A future date shows when the story was added (#1037)")
        try await db.upsertArticles(articles, now: now.addingTimeInterval(60))
        let refreshed = try await db.fetchArticles()
        assertEqual(
            refreshed.first { $0.title == "RSS future" }?.queryOrderValue,
            stored.first { $0.title == "RSS future" }?.queryOrderValue, "A refresh keeps the original ingestion time")
        // A row stored with a future date before the clamp existed is repaired when its feed refreshes, even with
        // retention off.
        let stale = stored.first { $0.title == "RSS future" }!
        _ = try await db.eventRows(
            "UPDATE articles SET published_at = ? WHERE id = ?;", [.real(2_524_608_000), .text(stale.id)])
        try await db.upsertArticles(articles, now: now.addingTimeInterval(120))
        assertEqual(
            try await db.fetchArticles().first { $0.title == "RSS future" }?.pubDate, DateParser.unknownDate,
            "A refresh repairs a stored future date")
        // A row stored before the clamp existed is returned to ingestion order by retention.
        let legacy = stored.first { $0.title == "RSS skew" }!
        _ = try await db.eventRows(
            "UPDATE articles SET published_at = ? WHERE id = ?;", [.real(2_524_608_000), .text(legacy.id)])
        for article in stored { try await db.markRead(articleId: article.id, isRead: true) }
        assertEqual(
            try await db.pruneOldArticles(keepReadDays: 30, now: now.addingTimeInterval(60 * 86400)), 6,
            "Future-dated stories are pruned with their neighbours")
        // Feed health ignores a clamped date, and a link-less item keeps the ID the parser gave it (its fingerprint
        // would otherwise change with the date).
        let linkless = FeedArticle(
            title: "Wire brief", link: "", guid: nil, description: "Brief",
            pubDate: Date(timeIntervalSince1970: 2_524_608_000),
            source: "Wire")
        let healthFeed = "https://example.com/health"
        let inserted = try await db.upsertArticles(
            [linkless], feedUrl: healthFeed, validators: FeedValidators(etag: nil, lastModified: nil), now: now)
        assertTrue(inserted.contains(linkless.id), "A clamped link-less item keeps its parsed ID")
        assertEqual(
            try await db.feedFetchStates()[healthFeed]?.latestItemAt, nil, "A future date is not the newest item")
        await db.close()
    }

    static func testUndatedArticleOrdering() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let dated = (0..<501).map { index in
            FeedArticle(
                title: "Dated \(index)", link: "", guid: "dated-\(index)", description: "",
                pubDate: Date(timeIntervalSince1970: Double(index)), source: "Publisher")
        }
        let undated = (0..<3).map { index in
            FeedArticle(
                title: "Undated \(index)", link: "", guid: "undated-\(index)", description: "",
                pubDate: DateParser.unknownDate, source: "Publisher")
        }
        try await db.upsertArticles(dated + undated)
        let snapshot = try await db.fetchArticles()
        assertEqual(
            Set(snapshot.prefix(3).map(\.id)), Set(undated.map(\.id)),
            "Undated stories remain visible beyond 500 dated stories")
        assertEqual(snapshot.first?.pubDate, DateParser.unknownDate, "Ordering never fabricates a publication date")
        let firstPage = try await db.fetchArticles(limit: 2)
        let remainder = try await db.fetchArticles(
            limit: nil, options: ArticleFetchOptions(after: ArticleQueryCursor(firstPage.last!)))
        assertEqual((firstPage + remainder).count, 504, "Date cursor includes every row")
        assertEqual(Set((firstPage + remainder).map(\.id)).count, 504, "Tied ingestion dates do not duplicate rows")
        let searchPage = try await db.searchArticles(query: "is:unread", limit: 2)
        let searchRemainder = try await db.searchArticles(
            query: "is:unread", limit: 600, after: ArticleQueryCursor(searchPage.last!))
        assertEqual(
            (searchPage + searchRemainder).map(\.id), (firstPage + remainder).map(\.id),
            "Filter-only search uses the same order and cursor")
        try await db.upsertArticles(undated)
        assertEqual(
            try await db.fetchArticles(limit: 3).map(\.queryOrderValue), snapshot.prefix(3).map(\.queryOrderValue),
            "Refresh preserves original ingestion time")
        try await db.markRead(articleId: undated[0].id, isRead: true)
        assertEqual(try await db.pruneOldArticles(), 0, "New undated read stories are not pruned as ancient")
        await db.close()
    }

    @MainActor
    static func testCanonicalArticleIngestion(fixtureRoot: URL) async throws {
        print("  - Testing canonical URL ingestion across changing GUIDs...")
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let first = FeedArticle(
            title: "Original report", link: fixtureRoot.appendingPathComponent("identity/story").absoluteString,
            guid: "first-guid", description: "Publisher report", pubDate: Date(timeIntervalSince1970: 100),
            source: "Publisher")
        let update = FeedArticle(
            title: "Updated report", link: first.link + "?utm_source=another-feed",
            guid: "replacement-guid", description: "Updated publisher report",
            pubDate: Date(timeIntervalSince1970: 200), source: first.source)
        try await db.upsertArticles([first], feedUrl: "primary-feed")
        try await db.markRead(articleId: first.id, isRead: true)
        try await db.setSaved(articleId: first.id, isSaved: true)
        let inserted = try await db.upsertArticles([update, update], feedUrl: "secondary-feed")
        assertTrue(inserted.isEmpty, "A changed GUID for the same canonical document is not a new article")
        let rows = try await db.fetchArticles(limit: nil)
        assertEqual(rows.count, 1, "Canonical aliases produce one stored article")
        assertEqual(rows.first?.id, first.id, "Stored primary key remains the UI identity after GUID changes")
        assertEqual(rows.first?.title, update.title, "Alias refresh updates publisher metadata")
        assertTrue(try await db.isRead(articleId: first.id), "Alias refresh preserves read history")
        assertTrue(try await db.isSaved(articleId: first.id), "Alias refresh preserves saved state")
        assertEqual(try await db.searchArticles(query: "Updated").first?.id, first.id, "FTS returns the durable ID")
        try await db.markRead(articleId: first.id, isRead: false)
        try await db.markAllRead(feedUrl: "secondary-feed")
        assertTrue(try await db.isRead(articleId: first.id), "Both feeds remain associated with the document")
        await store.setSaved(article: update, isSaved: false)
        assertFalse(try await db.isSaved(articleId: first.id), "Saving an incoming alias resolves the durable ID")
        assertTrue(store.operationError == nil, "Alias save must not fail a foreign-key check")
        let homepageEntries = (0..<2).map { index in
            FeedArticle(
                title: "Homepage-linked item \(index)", link: fixtureRoot.absoluteString,
                guid: "homepage-\(index)", description: "Different reports", pubDate: Date(), source: first.source)
        }
        assertEqual(
            try await db.upsertArticles(homepageEntries).count, 2,
            "Generic homepage links do not merge distinct entries")
        let missingLinks = (0..<2).map { index in
            FeedArticle(
                title: "Missing-link item \(index)", link: "", guid: "missing-link-\(index)",
                description: "Different reports", pubDate: Date(), source: first.source)
        }
        assertEqual(try await db.upsertArticles(missingLinks).count, 2, "Missing links do not identify a document")
        let referenceURL = first.link + "?reference=edition-two"
        assertEqual(
            ArticleIdentity.canonicalizeURL(referenceURL), referenceURL,
            "Meaningful query keys must not be stripped by a broad ref prefix")
        let otherEdition = FeedArticle(
            title: update.title, link: referenceURL, guid: "different-edition",
            description: update.description, pubDate: update.pubDate, source: first.source)
        assertEqual(
            try await db.upsertArticles([otherEdition]), Set([otherEdition.id]),
            "Meaningful query differences retain distinct documents")
        let sameHeadline = FeedArticle(
            title: update.title, link: first.link + "-different", guid: "different-event",
            description: update.description, pubDate: update.pubDate, source: first.source)
        assertEqual(
            try await db.upsertArticles([sameHeadline]), Set([sameHeadline.id]),
            "Matching text alone cannot merge different documents")
        let encoded = try JSONEncoder().encode(rows[0])
        assertEqual(
            try JSONDecoder().decode(FeedArticle.self, from: encoded).id, first.id,
            "Cached articles retain the stored identity")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "storedID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        assertEqual(
            try JSONDecoder().decode(FeedArticle.self, from: legacyData).id, update.id,
            "Legacy JSON remains decodable without a stored ID")
        await db.close()
    }

    @MainActor
    static func testValidatedDocumentIdentity(fixtureRoot: URL) async throws {
        print("  - Testing protected canonical and redirect identity evidence...")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let pipeline = ContentExtractionPipeline(client: mockHTTPClient(configuration: configuration))
        defer { MockURLProtocol.requestHandler = nil }
        let requested = fixtureRoot.appendingPathComponent("short/story")
        let final = fixtureRoot.appendingPathComponent("articles/story")
        let canonical = fixtureRoot.appendingPathComponent("canonical/story")
        let prose = (1...65).map { "Verified publisher fact \($0) adds distinctive editorial evidence." }.joined(
            separator: " ")
        func html(_ href: String = "../canonical/story", title: String = "Publisher story", body: String? = nil)
            -> String
        {
            "<html><head><title>\(title)</title><link rel='alternate canonical' href='\(href)'></head><body><article><p>\(body ?? prose)</p><figure><img src='../photo.jpg'><figcaption>Publisher photo</figcaption></figure><p>Additional reporting confirms the detailed evidence and provides context for this event.</p></article></body></html>"
        }
        var requests = [URL]()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            requests.append(url)
            let resolved = url == requested ? final : url
            return (
                HTTPURLResponse(url: resolved, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html().utf8)
            )
        }
        let extraction = await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
        assertTrue(extraction.outcome.isSuccess, "Validated redirect remains readable")
        guard let evidence = extraction.evidence else {
            assertTrue(false, "Successful fetch produces identity evidence")
            return
        }
        assertEqual(
            Set(evidence.urls), Set([final.absoluteString, canonical.absoluteString]),
            "Fetched redirect and equivalent canonical are evidence")
        assertEqual(requests, [requested, canonical], "Exactly one canonical verification probe is made")
        guard case .success(let content, _, let document) = extraction.outcome else { return }
        assertEqual(
            document?.blocks.first(where: { $0.kind == .figure })?.imageURL,
            fixtureRoot.appendingPathComponent("photo.jpg").absoluteString,
            "Relative images resolve from the final response URL")

        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        var original = FeedArticle(
            title: "Publisher story", link: requested.absoluteString, guid: "original", description: "Teaser",
            pubDate: Date(), source: "Publisher")
        original.identityFeedURL = fixtureRoot.appendingPathComponent("feed").absoluteString
        try await db.upsertArticles([original])
        try await db.markRead(articleId: original.id, isRead: true)
        try await db.setSaved(articleId: original.id, isSaved: true)
        await store.updateEnrichment(
            id: original.id, content: content, readerDocument: document, identityEvidence: evidence)
        let variant = FeedArticle(
            title: original.title, link: canonical.absoluteString, guid: "new-guid", description: original.description,
            pubDate: original.pubDate, source: original.source)
        assertTrue(
            try await db.upsertArticles([variant], feedUrl: original.identityFeedURL).isEmpty,
            "Verified canonical variant reuses stored identity")
        assertEqual(
            try await db.fetchArticles(options: ArticleFetchOptions(canonicalURL: final.absoluteString)).first?.id,
            original.id,
            "Verified redirect resolves through aliases")
        assertTrue(try await db.isRead(articleId: original.id), "Canonical evidence preserves read state")
        assertTrue(try await db.isSaved(articleId: original.id), "Canonical evidence preserves saved state")
        let unrelated = FeedArticle(
            title: "Unrelated", link: fixtureRoot.appendingPathComponent("unrelated").absoluteString, guid: "unrelated",
            description: "Different article", pubDate: Date(), source: "Publisher")
        try await db.upsertArticles([unrelated])
        do {
            try await db.recordDocumentIdentity(evidence, articleID: unrelated.id)
            assertTrue(false, "Evidence cannot be attached to another article")
        } catch {}
        await db.close()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-validated-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let persistent = DatabaseEngine(path: path)
        try await persistent.open()
        try await persistent.upsertArticles([original, variant])
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated alias failure fixture")
        assertEqual(
            sqlite3_exec(
                handle,
                "CREATE TRIGGER fail_document BEFORE INSERT ON article_aliases WHEN new.kind='url' AND new.value LIKE '%/articles/story' BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
                nil, nil, nil), SQLITE_OK, "Inject second evidence alias failure")
        do {
            try await persistent.recordDocumentIdentity(evidence, articleID: original.id)
            assertTrue(false, "Alias write failure must propagate")
        } catch {}
        assertEqual(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: canonical.absoluteString))
                .first?.id, variant.id,
            "Failed evidence rolls back earlier alias conflict")
        assertEqual(
            sqlite3_exec(handle, "DROP TRIGGER fail_document;", nil, nil, nil), SQLITE_OK,
            "Remove alias failure fixture")
        sqlite3_close(handle)
        try await persistent.recordDocumentIdentity(evidence, articleID: original.id)
        assertEqual(
            try await persistent.fetchArticles(limit: nil).count, 2,
            "Evidence does not merge conflicting historical rows")
        assertTrue(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: canonical.absoluteString))
                .isEmpty,
            "Conflicting validated canonical becomes ambiguous")
        await persistent.close()
        try await persistent.open()
        assertEqual(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: final.absoluteString)).first?
                .id, original.id,
            "Validated redirect alias survives reopening")
        assertTrue(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: canonical.absoluteString))
                .isEmpty,
            "Validated canonical ambiguity survives reopening")
        await persistent.close()

        for href in [
            "https://127.0.0.1/private", "file:///etc/passwd", "https://other.example/article", "/",
            "https://user:secret@\(fixtureRoot.host!)/article",
        ] {
            requests = []
            MockURLProtocol.requestHandler = { request in
                requests.append(request.url!)
                return (
                    HTTPURLResponse(url: final, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html(href).utf8)
                )
            }
            let rejected = await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
            assertTrue(rejected.outcome.isSuccess, "Untrusted canonical does not discard readable content")
            assertEqual(rejected.evidence?.urls, [final.absoluteString], "Arbitrary canonical is not identity evidence")
            assertEqual(requests, [requested], "Unsafe or cross-origin canonical never triggers a fetch")
        }
        for mismatch in ["body", "title", "status", "multiple"] {
            requests = []
            MockURLProtocol.requestHandler = { request in
                let url = request.url!
                requests.append(url)
                var page =
                    url == requested
                    ? html()
                    : html(
                        title: mismatch == "title" ? "Other story" : "Publisher story",
                        body: mismatch == "body" ? prose + " Changed facts." : nil)
                if mismatch == "multiple" {
                    page = page.replacingOccurrences(
                        of: "</head>", with: "<link rel='canonical' href='/another'></head>")
                }
                let status = mismatch == "status" && url != requested ? 403 : 200
                return (
                    HTTPURLResponse(
                        url: url == requested ? final : url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(page.utf8)
                )
            }
            let rejected = await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
            assertTrue(rejected.outcome.isSuccess, "Optional failed canonical proof retains the source article")
            assertEqual(
                rejected.evidence?.urls, [final.absoluteString],
                "Changed title/body, failed response or multiple canonicals do not alias")
        }
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: URL(string: "https://127.0.0.1/article")!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!, Data(html().utf8)
            )
        }
        let blocked = await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
        assertFalse(blocked.outcome.isSuccess, "Final response destination still requires protected validation")
        assertTrue(blocked.evidence == nil, "Blocked final destination yields no identity evidence")
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: URL(string: requested.absoluteString.replacingOccurrences(of: "https://", with: "http://"))!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html().utf8)
            )
        }
        let downgrade = await pipeline.extractArticleWithIdentity(from: requested.absoluteString, allowHTTP: true)
        assertFalse(
            downgrade.outcome.isSuccess,
            "HTTPS extraction rejects an HTTP final destination even when initial HTTP is allowed")
        assertTrue(downgrade.evidence == nil, "Downgrade creates no aliases")
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: final, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html().utf8))
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
        }
        assertTrue(await cancelled.value.evidence == nil, "Cancelled extraction returns no identity evidence")

        let insecure = requested.absoluteString.replacingOccurrences(of: "https://", with: "http://")
        for allowHTTP in [false, true] {
            requests.removeAll()
            MockURLProtocol.requestHandler = { request in
                requests.append(request.url!)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("<article><p>\(prose)</p></article>".utf8)
                )
            }
            let upgraded = await pipeline.extractArticleWithIdentity(from: insecure, allowHTTP: allowHTTP)
            assertTrue(upgraded.outcome.isSuccess, "HTTP feed links remain readable under either transport setting")
            assertEqual(
                requests.map(\.absoluteString), [allowHTTP ? insecure : requested.absoluteString],
                "Extraction upgrades HTTP unless the user explicitly allows it")
        }
        requests.removeAll()
        let malformed = await pipeline.extractArticleWithIdentity(from: "http://[malformed")
        assertFalse(malformed.outcome.isSuccess, "Malformed article links fail before fetching")
        assertTrue(requests.isEmpty, "Malformed links never reach the network")
    }

    @MainActor
    static func testPublisherTextFingerprints() async throws {
        print("  - Testing conservative publisher text fingerprints...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let text = (1...65).map { "Publisher evidence number \($0) confirms a distinct detail." }.joined(separator: " ")
        func incoming(
            _ guid: String, host: String = "publisher.example", title: String = "Report",
            body: String? = nil, description: String? = nil,
            date: Date = Date(timeIntervalSince1970: 100)
        ) -> FeedArticle {
            var article = FeedArticle(
                title: title, link: "https://\(host)/\(guid)", guid: guid,
                description: description ?? text, pubDate: date, source: "Shared label")
            article.identityFeedURL = "https://\(host)/feed"
            article.fullContent = body
            return article
        }
        let db = DatabaseEngine(path: path)
        try await db.open()
        let first = incoming("first")
        try await db.upsertArticles([first])
        try await db.markRead(articleId: first.id, isRead: true)
        try await db.setSaved(articleId: first.id, isSaved: true)
        let duplicate = incoming("other-url-and-guid", description: text.replacingOccurrences(of: " ", with: "\n  "))
        assertTrue(
            try await db.upsertArticles([duplicate]).isEmpty, "Exact normalized publisher text reuses the document")
        assertEqual(try await db.resolvedArticleID(for: duplicate), first.id, "Text matching preserves the original ID")
        assertTrue(try await db.isRead(articleId: duplicate.id), "Variant retains read state through its ID alias")
        assertTrue(try await db.isSaved(articleId: duplicate.id), "Variant retains bookmark state")
        for article in [
            incoming("reprint", host: "other-publisher.example"),
            incoming("changed", description: text + " New information."),
            incoming("later", date: Date(timeIntervalSince1970: 200)),
            incoming("other-title", title: "Another report"),
        ] {
            assertEqual(
                try await db.upsertArticles([article]), Set([article.id]),
                "Different publisher, text or metadata stays separate")
        }
        let shortA = incoming("short-a", description: "Read more on our website.")
        let shortB = incoming("short-b", description: shortA.description)
        try await db.upsertArticles([shortA])
        assertEqual(try await db.upsertArticles([shortB]), Set([shortB.id]), "Shared short teasers do not merge")
        let unknown = incoming("undated", date: DateParser.unknownDate)
        assertTrue(
            ArticleIdentity.publisherTextFingerprints(unknown).isEmpty, "Undated documents require stronger evidence")
        assertTrue(
            ArticleIdentity.publisherTextFingerprints(
                incoming("large", description: String(repeating: text, count: 100))
            ).isEmpty, "Oversized text is skipped rather than truncated")
        var generated = incoming("generated", description: "Short teaser")
        generated.aiSummary = text
        assertTrue(
            ArticleIdentity.publisherTextFingerprints(generated).isEmpty,
            "Generated summaries never identify publisher documents")
        let bodyA = incoming("body-a", body: text, description: "First teaser")
        let bodyB = incoming("body-b", body: text, description: "Second teaser")
        try await db.upsertArticles([bodyA])
        assertTrue(try await db.upsertArticles([bodyB]).isEmpty, "Exact full body can match different descriptions")

        let extracted = incoming("extracted", description: "No full body in RSS")
        try await db.upsertArticles([extracted])
        try await db.updateEnrichment(
            articleId: extracted.id,
            update: DatabaseEngine.EnrichmentUpdate(content: text + " Extracted details."))
        let extractedVariant = incoming(
            "extracted-variant", body: text + " Extracted details.", description: "Different teaser")
        assertTrue(
            try await db.upsertArticles([extractedVariant]).isEmpty,
            "On-demand publisher extraction contributes body evidence")

        // A known GUID owns a separate row before it acquires identical publisher text.
        let distinct = incoming("distinct", description: text + " Original distinction.")
        try await db.upsertArticles([distinct])
        let corrected = incoming("distinct")
        assertTrue(try await db.upsertArticles([corrected]).isEmpty, "Known GUID takes precedence over text")
        assertEqual(
            try await db.resolvedArticleID(for: corrected), distinct.id,
            "Authoritative identity is not overwritten by text")
        let uncertain = incoming("uncertain")
        assertEqual(
            try await db.upsertArticles([uncertain]), Set([uncertain.id]),
            "Ambiguous text never selects one of its owners")
        await db.close()
        try await db.open()
        assertEqual(try await db.resolvedArticleID(for: duplicate), first.id, "Observed variant survives reopening")
        let stillUncertain = incoming("still-uncertain")
        assertEqual(
            try await db.upsertArticles([stillUncertain]), Set([stillUncertain.id]), "Ambiguity remains after reopening"
        )
        let mixed = incoming("mixed-evidence", body: text)
        assertEqual(
            try await db.upsertArticles([mixed]), Set([mixed.id]),
            "Ambiguous description blocks automatic matching even with a unique body candidate")
        assertTrue(try await db.isSaved(articleId: first.id), "Migration and reopening retain bookmark state")
        // Fingerprint failure must roll back extracted text and enrichment together.
        var failureHandle: OpaquePointer?
        assertEqual(sqlite3_open(path, &failureHandle), SQLITE_OK, "Open isolated failure injector")
        assertEqual(
            sqlite3_exec(
                failureHandle,
                "CREATE TRIGGER reject_text BEFORE INSERT ON article_aliases WHEN new.kind = 'content' BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
                nil, nil, nil), SQLITE_OK, "Inject content alias failure")
        do {
            try await db.updateEnrichment(
                articleId: extracted.id,
                update: DatabaseEngine.EnrichmentUpdate(summary: "Should roll back", content: text + " Failed update."))
            assertTrue(false, "Alias failure must propagate")
        } catch {}
        let rolledBack = try await db.fetchArticles(id: extracted.id).first
        assertEqual(
            rolledBack?.fullContent, text + " Extracted details.", "Failed alias preserves prior publisher text")
        assertTrue(rolledBack?.aiSummary == nil, "Failed alias preserves prior enrichment")
        assertEqual(
            sqlite3_exec(failureHandle, "DROP TRIGGER reject_text;", nil, nil, nil), SQLITE_OK,
            "Remove failure injector")
        sqlite3_close(failureHandle)
        await db.close()

        // Exercise v6 -> v7 with existing aliases and a cancellation rollback.
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated migration fixture")
        let downgrade = """
            BEGIN;
            ALTER TABLE article_aliases RENAME TO aliases_v7;
            CREATE TABLE article_aliases(kind TEXT NOT NULL CHECK(kind IN ('id','url')), value TEXT NOT NULL,
                article_id TEXT REFERENCES articles(id) ON DELETE CASCADE, PRIMARY KEY(kind,value));
            INSERT INTO article_aliases SELECT kind,value,article_id FROM aliases_v7 WHERE kind != 'content';
            DROP TABLE aliases_v7;
            CREATE INDEX idx_article_aliases_article ON article_aliases(article_id);
            DROP TABLE article_reconciliation_history; DROP TABLE article_reconciliations; PRAGMA user_version = 6;
            COMMIT;
            """
        assertEqual(sqlite3_exec(handle, downgrade, nil, nil, nil), SQLITE_OK, "Reconstruct v6 aliases")
        sqlite3_close(handle)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await db.open()
        }
        do {
            try await cancelled.value
            assertTrue(false, "Cancelled fingerprint schema migration throws")
        } catch is CancellationError {}
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Read cancelled migration")
        var statement: OpaquePointer?
        assertEqual(
            sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK, "Read schema version")
        assertEqual(sqlite3_step(statement), SQLITE_ROW, "Schema version exists")
        assertEqual(sqlite3_column_int(statement, 0), 6, "Cancelled migration retains v6")
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        try await db.open()
        assertEqual(try await db.resolvedArticleID(for: duplicate), first.id, "v7 retains existing aliases")
        assertTrue(try await db.isRead(articleId: first.id), "v7 retains reading state")
        let historicalVariant = incoming(
            "historical-new-guid", body: text + " Extracted details.", description: "Fresh teaser")
        assertTrue(
            try await db.upsertArticles([historicalVariant]).isEmpty,
            "Migration indexes existing publisher body evidence")
        assertEqual(
            try await db.resolvedArticleID(for: historicalVariant), extracted.id,
            "Historical body resolves without rewriting the primary key")
        let historicalAmbiguity = incoming("historical-ambiguous")
        assertEqual(
            try await db.upsertArticles([historicalAmbiguity]), Set([historicalAmbiguity.id]),
            "Migration preserves conflicting historical text as ambiguous")
        await db.close()

        let suite = testDefaultsSuite("test.text.refresh")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = ["https://publisher.example/feed"]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        var notifications = [String]()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [first, duplicate], nil, nil) } },
            notifyBatch: { articles, _ in notifications.append(contentsOf: articles.map { $0.id }) })
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        assertEqual(manager.articles.count, 1, "Refresh displays exact content variants once")
        assertEqual(notifications, [first.id], "Refresh notifies only the committed document")
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        assertEqual(notifications, [first.id], "Repeated content variants never notify again")
        manager.stopBackgroundWork()
        await store.database.close()
    }

    @MainActor
    static func testFeedScopedGUIDs(fixtureRoot: URL) async throws {
        print("  - Testing feed-scoped GUID collisions and notification identities...")
        let feeds = [
            fixtureRoot.appendingPathComponent("guid-feed-a").absoluteString,
            fixtureRoot.appendingPathComponent("guid-feed-b").absoluteString,
        ]
        func incoming(_ feed: String, _ link: String, guid: String = "shared-guid") -> FeedArticle {
            var article = FeedArticle(
                title: "Report", link: link, guid: guid, description: "Publisher report",
                pubDate: Date(timeIntervalSince1970: 100), source: "Shared feed title")
            article.identityFeedURL = feed
            return article
        }
        let first = incoming(feeds[0], fixtureRoot.appendingPathComponent("publisher-a/report").absoluteString)
        let second = incoming(feeds[1], fixtureRoot.appendingPathComponent("publisher-b/report").absoluteString)
        assertTrue(first.id != second.id, "The same raw GUID from different feeds has different identity")
        assertTrue(
            ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0] + "?utm_source=rss") != first.id,
            "Article tracking rules must not collapse configured feed URLs")
        assertTrue(
            ArticleIdentity.scopedGUID(
                "shared-guid", feedURL: feeds[0].replacingOccurrences(of: "https://", with: "http://")) != first.id,
            "Explicit HTTP and HTTPS subscriptions retain separate namespaces")
        assertTrue(
            ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0] + "?edition=2") != first.id,
            "Document-selecting feed parameters retain separate namespaces")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        assertEqual(
            try await db.upsertArticles([first], feedUrl: feeds[0]), Set([first.id]),
            "First feed inserts its scoped identity")
        try await db.markRead(articleId: first.id, isRead: true)
        try await db.setSaved(articleId: first.id, isSaved: true)
        assertEqual(
            try await db.upsertArticles([second], feedUrl: feeds[1]), Set([second.id]),
            "Other publisher's reused GUID inserts a distinct document")
        assertEqual(
            try await db.fetchArticles(limit: nil).count, 2, "GUID collision does not overwrite either publisher")
        assertFalse(try await db.isRead(articleId: second.id), "The other publisher does not inherit reading state")
        assertFalse(try await db.isSaved(articleId: second.id), "The other publisher does not inherit a bookmark")
        let moved = incoming(feeds[1], fixtureRoot.appendingPathComponent("publisher-b/moved").absoluteString)
        assertTrue(
            try await db.upsertArticles([moved], feedUrl: feeds[1]).isEmpty, "Same-feed GUID resolves a changed URL")
        assertEqual(
            try await db.fetchArticles(id: second.id).first?.link, moved.link,
            "URL correction updates only its own publisher")
        assertEqual(
            try await db.fetchArticles(id: first.id).first?.link, first.link, "The other publisher's URL stays intact")
        let sharedDocument = incoming(feeds[1], first.link, guid: "same-document-other-feed")
        assertTrue(
            try await db.upsertArticles([sharedDocument], feedUrl: feeds[1]).isEmpty,
            "Exact document URL can still connect different feeds")
        assertEqual(
            try await db.resolvedArticleID(for: sharedDocument), first.id,
            "Scoped alias points to the original shared document")
        let missingA = incoming(feeds[0], "", guid: "missing-link-guid")
        let missingB = incoming(feeds[1], "", guid: "missing-link-guid")
        assertEqual(
            try await db.upsertArticles([missingA], feedUrl: feeds[0]), Set([missingA.id]),
            "Missing URL remains identifiable within its feed")
        assertEqual(
            try await db.upsertArticles([missingB], feedUrl: feeds[1]), Set([missingB.id]),
            "Missing URLs do not make GUIDs global")
        await db.close()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-guid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite3").path
        let copy = directory.appendingPathComponent("copy.sqlite3").path
        let legacyDB = DatabaseEngine(path: path)
        try await legacyDB.open()
        let legacy = FeedArticle(
            title: "Legacy report", link: first.link, guid: "legacy-guid", description: "Existing article",
            pubDate: Date(), source: "Publisher")
        try await legacyDB.upsertArticles([legacy], feedUrl: feeds[0])
        try await legacyDB.markRead(articleId: legacy.id, isRead: true)
        try await legacyDB.setSaved(articleId: legacy.id, isSaved: true)
        let multi = FeedArticle(
            title: "Multi-feed legacy report", link: fixtureRoot.appendingPathComponent("legacy/multi").absoluteString,
            guid: "multi-guid", description: "Existing article", pubDate: Date(), source: "Publisher")
        try await legacyDB.upsertArticles([multi], feedUrl: feeds[0])
        try await legacyDB.upsertArticles([multi], feedUrl: feeds[1])
        let uncertain = FeedArticle(
            title: "Unattributed variant", link: fixtureRoot.appendingPathComponent("legacy/uncertain").absoluteString,
            guid: "original-unattributed", description: "Existing article", pubDate: Date(), source: "Publisher")
        try await legacyDB.upsertArticles([uncertain], feedUrl: feeds[0])
        let unattributed = FeedArticle(
            title: uncertain.title, link: uncertain.link, guid: "unattributed-guid", description: uncertain.description,
            pubDate: uncertain.pubDate, source: "Other publisher")
        try await legacyDB.upsertArticles([unattributed])
        await legacyDB.close()
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated v5 fixture")
        assertEqual(
            sqlite3_exec(
                handle,
                "DROP TABLE article_reconciliation_history; DROP TABLE article_reconciliations; DELETE FROM article_aliases WHERE value LIKE 'feed-guid:%'; PRAGMA user_version = 5;",
                nil, nil, nil), SQLITE_OK, "Reconstruct a legacy v5 library")
        sqlite3_close(handle)
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        let migrated = DatabaseEngine(path: copy)
        let cancelledMigration = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await migrated.open()
        }
        do {
            try await cancelledMigration.value
            assertTrue(false, "Cancelled scoped GUID migration must be reported")
        } catch is CancellationError {
            assertEqual(sqlite3_open(copy, &handle), SQLITE_OK, "Inspect cancelled v6 migration")
            var statement: OpaquePointer?
            assertEqual(
                sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK,
                "Read cancelled migration version")
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Read old schema version")
            assertEqual(sqlite3_column_int(statement, 0), 5, "Scoped GUID migration rolls back its version")
            sqlite3_finalize(statement)
            assertEqual(
                sqlite3_prepare_v2(
                    handle, "SELECT count(*) FROM article_aliases WHERE value LIKE 'feed-guid:%';", -1, &statement, nil),
                SQLITE_OK, "Read cancelled migration aliases")
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Read scoped alias count")
            assertEqual(sqlite3_column_int(statement, 0), 0, "Cancelled migration commits no scoped aliases")
            sqlite3_finalize(statement)
            sqlite3_close(handle)
        }
        try await migrated.open()
        let legacyMoved = incoming(
            feeds[0], fixtureRoot.appendingPathComponent("legacy/moved").absoluteString, guid: "legacy-guid")
        assertTrue(
            try await migrated.upsertArticles([legacyMoved], feedUrl: feeds[0]).isEmpty,
            "Migration maps scoped GUID to the existing primary key even after URL correction")
        assertEqual(
            try await migrated.fetchArticles(id: legacy.id).first?.id, legacy.id, "Legacy primary key is preserved")
        let unknownMulti = incoming(
            feeds[1], fixtureRoot.appendingPathComponent("legacy/multi-moved").absoluteString, guid: "multi-guid")
        assertEqual(
            try await migrated.resolvedArticleID(for: unknownMulti), unknownMulti.id,
            "Migration does not guess GUID ownership for multi-feed history")
        assertEqual(
            try await migrated.fetchArticles(id: multi.id).first?.id, multi.id,
            "Uncertain multi-feed article retains its old ID")
        let unknownOwner = incoming(
            feeds[0], fixtureRoot.appendingPathComponent("legacy/unattributed-moved").absoluteString,
            guid: "unattributed-guid")
        assertEqual(
            try await migrated.resolvedArticleID(for: unknownOwner), unknownOwner.id,
            "Migration does not attribute a later unscoped GUID variant to the original feed")
        assertTrue(try await migrated.isRead(articleId: legacyMoved.id), "Scoped lookup preserves legacy read state")
        assertTrue(try await migrated.isSaved(articleId: legacyMoved.id), "Scoped lookup preserves legacy saved state")
        let legacyCollision = incoming(feeds[1], second.link, guid: "legacy-guid")
        assertEqual(
            try await migrated.upsertArticles([legacyCollision], feedUrl: feeds[1]), Set([legacyCollision.id]),
            "Legacy GUID ownership does not extend to another feed")
        assertEqual(
            try await migrated.fetchArticles(limit: nil).count, 4,
            "Copied library retains originals and colliding document")
        await migrated.close()

        let suite = testDefaultsSuite("test.guid.refresh")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = feeds
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        var notified = [String]()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                urls.map { feed in
                    let articles = feed == feeds[0] ? [first, first] : [second, second, sharedDocument]
                    let items = articles.map { article in
                        "<item><title>Report</title><link>\(article.link)</link><guid isPermaLink='false'>\(article.guid!)</guid><description>Publisher report</description></item>"
                    }.joined()
                    let xml = "<rss version='2.0'><channel><title>Shared feed title</title>\(items)</channel></rss>"
                    return (feed, FeedXMLParser(data: Data(xml.utf8)).parse(), nil, nil)
                }
            }, notifyBatch: { articles, _ in notified.append(contentsOf: articles.map { $0.id }) })
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        assertEqual(
            Set(notified), Set([first.id, second.id]), "Both colliding publishers notify with committed, distinct IDs")
        assertEqual(notified.count, 2, "Duplicate RSS rows and overlapping feeds notify once per stored document")
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        assertEqual(notified.count, 2, "Repeated refresh does not re-notify either publisher")
        assertEqual(
            Set(manager.articles.map { $0.id }), Set([first.id, second.id]),
            "Visible identities agree with notification IDs")
        manager.stopBackgroundWork()
        await store.database.close()
    }
}
