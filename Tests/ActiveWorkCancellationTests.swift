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

/// The ActiveWorkCancellation suites of the regression runner; `ActiveWorkCancellationTests.run()` is this atom's entry point.
enum ActiveWorkCancellationTests {
    static func run() async throws { try await NewsTests.runActiveWorkCancellationTests() }
}

extension NewsTests {
    static func runActiveWorkCancellationTests() async throws {
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testActiveWorkCancellation", { try await testActiveWorkCancellation() })
        ]
        try await runSuite(tests)
    }

    static func testActiveWorkCancellation() async throws {
        print("  - Testing cancellation during real clustering, transactional ingestion and feed parsing...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-active-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ingestion.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let now = Date()
        let feed = "https://cancel.example/feed"
        let original = FeedArticle(
            storedID: "preserved", title: "Preserved report", link: "https://cancel.example/preserved",
            guid: "preserved", description: "Original description", pubDate: now,
            source: "Publisher", fullContent: "Originalbodytoken")
        try await db.upsertArticles(
            [original], feedUrl: feed, validators: FeedValidators(etag: "original", lastModified: nil))
        try await db.markRead(articleId: original.id, isRead: true)
        try await db.setSaved(articleId: original.id, isSaved: true)
        var observer: OpaquePointer?
        assertEqual(
            sqlite3_open_v2(path, &observer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK,
            "Observe only the temporary ingestion database")
        defer { sqlite3_close(observer) }
        func snapshot() -> [String: [[String?]]] {
            var result: [String: [[String?]]] = [:]
            for table in [
                "articles", "article_state", "article_aliases", "article_enrichment", "article_feeds", "feeds",
                "articles_fts",
            ] {
                var statement: OpaquePointer?
                assertEqual(
                    sqlite3_prepare_v2(observer, "SELECT * FROM \(table) ORDER BY 1, 2;", -1, &statement, nil),
                    SQLITE_OK, "Prepare fixture snapshot")
                var rows: [[String?]] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    rows.append(
                        (0..<sqlite3_column_count(statement)).map { column in
                            sqlite3_column_text(statement, column).map { String(cString: $0) }
                        })
                    status = sqlite3_step(statement)
                }
                assertEqual(status, SQLITE_DONE, "Read complete fixture snapshot")
                sqlite3_finalize(statement)
                result[table] = rows
            }
            return result
        }
        let before = snapshot()
        let changed = FeedArticle(
            storedID: original.id, title: "Rolledback report", link: original.link,
            guid: original.guid, description: original.description, pubDate: now,
            source: original.source, fullContent: "Rolledbackbodytoken")
        let body = String(
            repeating: "Controlled publisher prose describes research and independent observations. ", count: 110)
        // The measured run keeps the audited workload. The regression run clusters 150 rows (one batch of 100 commits,
        // 50 stay pending at cancel) and parses 100 items, which still cancel mid-work. Ingestion keeps 20,000 rows:
        // the wait is for the page cache to spill, which takes the same time at any batch size; 4,000 rows commit first.
        let measuring = CommandLine.arguments.contains("--active-work-cancellation")
        // Exceed the native page-cache spill threshold so WAL growth occurs before COMMIT.
        let batch =
            [changed]
            + (0..<20_000).map { index in
                FeedArticle(
                    storedID: "cancel-insert-\(index)", title: "New report \(index)",
                    link: "https://cancel.example/insert/\(index)",
                    guid: "cancel-insert-\(index)", description: "Controlled report \(index)", pubDate: now,
                    source: "Publisher", fullContent: body)
            }
        let sampleCount = measuring ? 5 : 1
        var samples: [String: [Double]] = [:]
        for _ in 0..<sampleCount {
            assertEqual(
                sqlite3_exec(observer, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK,
                "Reset only the temporary WAL between equal-work samples")
            let done = SocketObservation()
            let write = Task.detached { () -> (Bool, Double) in
                let cancelled: Bool
                do {
                    _ = try await db.upsertArticles(
                        batch, feedUrl: feed, validators: FeedValidators(etag: "new", lastModified: nil))
                    cancelled = false
                } catch is CancellationError { cancelled = true } catch {
                    assertTrue(false, "Unexpected ingestion error: \(error)")
                    cancelled = false
                }
                let end = ProcessInfo.processInfo.systemUptime
                done.recordText("finished")
                return (cancelled, end)
            }
            // The spill comes later on a loaded machine, so wait for it or for the write to end, never a wall clock
            // alone (#692); a write that ends first fails the next assertion.
            await eventually("Actual transaction spills pages to the WAL before cancellation", timeout: .seconds(300)) {
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue
                    ?? 0
                return size > 1_048_576 || done.count > 0
            }
            assertEqual(done.count, 0, "Ingestion is still active at the observed WAL spill")
            let start = ProcessInfo.processInfo.systemUptime
            write.cancel()
            await eventually("Active ingestion cancels and rolls back within its deadline", timeout: .seconds(2)) {
                done.count == 1
            }
            let (cancelled, end) = await write.value
            assertTrue(cancelled, "Active ingestion reports CancellationError")
            samples["ingestion_rollback", default: []].append((end - start) * 1000)
            assertEqual(
                snapshot(), before,
                "Rollback preserves articles, read/save timestamps, identities, enrichment, feed metadata and FTS")
            assertEqual(try await db.counts().total, 1, "No cancelled batch row is committed")
            assertEqual(
                try await db.searchArticles(query: "Originalbodytoken").map(\.id), [original.id],
                "Original searchable text survives cancellation")
            assertTrue(
                try await db.searchArticles(query: "Rolledbackbodytoken").isEmpty, "Cancelled searchable text is absent"
            )
        }
        assertEqual(
            sqlite3_exec(observer, "INSERT INTO articles_fts(articles_fts) VALUES('integrity-check');", nil, nil, nil),
            SQLITE_OK, "FTS remains valid after repeated rollbacks")
        await db.close()

        let clustering = DatabaseEngine(path: directory.appendingPathComponent("clustering.sqlite3").path)
        try await clustering.open()
        let articles = (0..<(measuring ? 400 : 150)).map { index in
            FeedArticle(
                storedID: "cancel-cluster-\(index)", title: "Research observatory reports measurement \(index)",
                link: "https://cancel.example/cluster/\(index)", guid: "cancel-cluster-\(index)",
                description: "The research observatory published independent measurement results for project \(index).",
                pubDate: now, source: "Publisher \(index % 20)")
        }
        try await clustering.upsertArticles(articles)
        try await clustering.markRead(articleId: articles[0].id, isRead: true)
        try await clustering.setSaved(articleId: articles[0].id, isSaved: true)
        var pendingAtCancel: [Int] = []
        for _ in 0..<sampleCount {
            try await clustering.markEventMatchProcessed(articles.map(\.id), matcherVersion: 0, at: now)
            let done = SocketObservation()
            let work = Task.detached { () -> (Bool, Double) in
                let cancelled: Bool
                do {
                    _ = try await EventClusterer.run(in: clustering, now: now)
                    cancelled = false
                } catch is CancellationError { cancelled = true } catch {
                    assertTrue(false, "Unexpected clustering error: \(error)")
                    cancelled = false
                }
                let end = ProcessInfo.processInfo.systemUptime
                done.recordText("finished")
                return (cancelled, end)
            }
            await eventually("Clustering commits real progress before cancellation") {
                let count = try? await clustering.pendingEventMatchRows(
                    activeSince: now.addingTimeInterval(-72 * 3600),
                    matcherVersion: EventMatcher.version, limit: articles.count
                ).count
                return count.map { $0 < articles.count } ?? false
            }
            let remaining = try await clustering.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: articles.count
            ).count
            assertTrue(
                remaining > 0 && remaining < articles.count,
                "Clustering has completed some work and still has pending rows")
            assertEqual(done.count, 0, "Clustering is active when cancelled")
            pendingAtCancel.append(remaining)
            let start = ProcessInfo.processInfo.systemUptime
            work.cancel()
            await eventually("Active clustering cancels within its deadline", timeout: .seconds(2)) { done.count == 1 }
            let (cancelled, end) = await work.value
            assertTrue(cancelled, "Active clustering reports CancellationError")
            samples["clustering", default: []].append((end - start) * 1000)
            assertEqual(
                try await clustering.counts().total, articles.count, "Cancellation never deletes source articles")
            assertTrue(
                try await clustering.isRead(articleId: articles[0].id), "Clustering cancellation preserves read state")
            assertTrue(
                try await clustering.isSaved(articleId: articles[0].id), "Clustering cancellation preserves saved state"
            )
        }
        let resumed = try await EventClusterer.run(in: clustering, now: now)
        assertTrue(resumed.processed > 0, "A later pass resumes cancelled work")
        assertTrue(
            try await clustering.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 1
            ).isEmpty, "Resumed clustering drains remaining rows")
        assertEqual(
            try await EventClusterer.run(in: clustering, now: now).processed, 0, "The resumed archive is not recomputed"
        )
        await clustering.close()

        // Feed parsing extracts every item's HTML; a cancelled refresh must not finish that work or keep its result.
        let paragraph =
            "<p>Controlled publisher prose describes <em>research</em> and independent observations in detail.</p>"
        let itemCount = measuring ? 500 : 100
        let items = (0..<itemCount).map { index in
            "<item><title>Parsed report \(index)</title><link>https://cancel.example/parse/\(index)</link><guid>parse-\(index)</guid>"
                + "<description>Report \(index)</description><content:encoded><![CDATA[<h2>Section</h2>"
                + String(repeating: paragraph, count: 15) + "]]></content:encoded></item>"
        }.joined()
        let feedData = Data(
            ("<?xml version=\"1.0\"?><rss version=\"2.0\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\">"
                + "<channel><title>Publisher</title>" + items + "</channel></rss>").utf8)
        let fullStart = ProcessInfo.processInfo.systemUptime
        assertEqual(
            FeedXMLParser(data: feedData, feedURL: feed).parse().count, itemCount,
            "The uncancelled fixture parses every item"
        )
        let fullParse = ProcessInfo.processInfo.systemUptime - fullStart
        assertTrue(fullParse > 0.1, "The parsing fixture runs long enough to cancel mid-feed")
        for _ in 0..<sampleCount {
            let started = SocketObservation()
            let done = SocketObservation()
            let parse = Task.detached { () -> (Int, Double) in
                started.recordText("started")
                let parsed = FeedXMLParser(data: feedData, feedURL: feed).parse().count
                let end = ProcessInfo.processInfo.systemUptime
                done.recordText("finished")
                return (parsed, end)
            }
            await eventually("Feed parsing starts before cancellation") { started.count == 1 }
            try await Task.sleep(for: .seconds(fullParse / 4))
            assertEqual(done.count, 0, "Feed parsing is active when cancelled")
            let start = ProcessInfo.processInfo.systemUptime
            parse.cancel()
            await eventually("Active feed parsing stops within its deadline", timeout: .seconds(2)) { done.count == 1 }
            let (parsed, end) = await parse.value
            assertEqual(parsed, 0, "A cancelled parse returns no articles")
            samples["feed_parsing", default: []].append((end - start) * 1000)
        }
        let jsonFeed = Data(
            #"{"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://cancel.example/json/1","content_html":"<p>Body</p>"}]}"#
                .utf8)
        let cancelledJSON = await Task.detached { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return JSONFeedParser.parse(data: jsonFeed, feedURL: feed)?.count
        }.value
        assertEqual(cancelledJSON, nil, "A cancelled JSON Feed parse returns no articles")
        assertEqual(
            JSONFeedParser.parse(data: jsonFeed, feedURL: feed)?.count, 1,
            "The same JSON Feed parses when not cancelled")

        let report: [String: Any] = [
            "samples_ms": samples, "samples_per_operation": sampleCount, "ingestion_batch_rows": batch.count,
            "ingestion_body_characters": body.count, "wal_spill_threshold_bytes": 1_048_576,
            "clustering_library_rows": articles.count, "clustering_pending_at_cancel": pendingAtCancel,
            "parsing_feed_items": itemCount, "parsing_feed_bytes": feedData.count,
            "parsing_uncancelled_ms": fullParse * 1000,
            "sqlite_version": String(cString: sqlite3_libversion()),
        ]
        print(
            "ACTIVE_CANCELLATION_REPORT "
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        )
    }

}
