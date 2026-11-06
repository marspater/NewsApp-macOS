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

import Foundation
import SQLite3

/// Per-feed health numbers: their arithmetic, what is stored, and what a refresh records (#715).
enum FeedHealthMetricsTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static let now = Date(timeIntervalSince1970: 1_793_491_200)
    static let day: TimeInterval = 24 * 60 * 60

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ FeedHealthMetrics: \(message)")
        }
    }

    static func checkArithmetic() {
        let empty = FeedHealthMetrics(FeedHealthObservations(), now: now)
        check(
            empty.successRate == nil && empty.averageLatency == nil && empty.itemsPerDay == nil
                && empty.extractionClass == .unknown && empty.fullReaderShare == nil, "no history is unknown, not zero")
        let busy = FeedHealthMetrics(
            FeedHealthObservations(
                attempts: 4, successes: 3, latencyTotal: 1.5, recentItems: 20, oldestRecentItem: now - 10 * day),
            now: now)
        check(busy.successRate == 0.75 && busy.averageLatency == 0.5, "rate and latency count successes only")
        check(busy.itemsPerDay == 2, "frequency divides by the days covered")
        let young = FeedHealthMetrics(
            FeedHealthObservations(recentItems: 5, oldestRecentItem: now - 3600), now: now)
        check(young.itemsPerDay == 5, "an hour of stories is not a rate of 120 a day")
        check(
            FeedHealthMetrics(FeedHealthObservations(attempts: 2), now: now).successRate == 0,
            "only failures is a rate of zero")
        check(
            FeedHealthMetrics(FeedHealthObservations(subscriberOnly: 2), now: now).extractionClass == .unknown,
            "two barriers name no class")
        for (observed, expected, message) in [
            (FeedHealthObservations(fullReader: 3), FeedHealthMetrics.ExtractionClass.fullReader, "complete text"),
            (FeedHealthObservations(fullReader: 1, teaser: 3), .teaser, "summary-only"),
            (FeedHealthObservations(fullReader: 1, subscriberOnly: 3), .paywall, "subscriber barriers"),
            (FeedHealthObservations(teaser: 1, blocked: 3), .blocked, "bot checks"),
            (FeedHealthObservations(fullReader: 2, subscriberOnly: 2), .fullReader, "a tie favours the feed"),
        ] {
            check(FeedHealthMetrics(observed, now: now).extractionClass == expected, "class: \(message)")
        }
        check(ReaderBarrier(.subscriberOnly) == .subscriber, "a subscriber barrier is recorded")
        check(ReaderBarrier(.httpError(status: 403)) == .blocked, "403 is a block")
        check(ReaderBarrier(.httpError(status: 500)) == nil, "a server error is no barrier")
        check(ReaderBarrier(.emptyContent) == nil, "an empty page is no barrier")
    }

    static func story(
        _ id: String, published: Date = now, content: String? = nil, complete: Bool? = nil
    ) -> FeedArticle {
        FeedArticle(
            storedID: id, title: "Headline \(id)", link: "https://example.com/\(id)", guid: id, description: "Blurb",
            pubDate: published, source: "Outlet", fullContent: content,
            readerDocument: complete.map { ReaderDocument(version: 1, blocks: [], isComplete: $0) })
    }

    static func checkStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let feed = "https://example.com/feed.xml"
        let db = DatabaseEngine(path: path)
        try await db.open()
        let stories = [
            story("full", published: now - 2 * day, complete: true),
            story("long", published: now - day, content: String(repeating: "x", count: FeedHealth.fullTextCharacters)),
            story("teaser", published: now - 40 * day, complete: false),
            story("barred", complete: false), story("blocked"), story("recovered", complete: true), story("plain"),
        ]
        try await db.upsertArticles(stories, feedUrl: feed, now: now)
        let stored = try await db.fetchArticles(limit: nil)
        func id(_ link: String) -> String { stored.first { $0.link.hasSuffix("/\(link)") }?.id ?? link }
        try await db.recordReaderBarrier(.subscriber, articleID: id("barred"))
        try await db.recordReaderBarrier(.blocked, articleID: id("blocked"))
        try await db.recordReaderBarrier(.subscriber, articleID: id("recovered"))
        try await db.recordFeedSuccess(feed, at: now)
        try await db.recordFeedSample(feed, latency: 0.25)
        try await db.recordFeedSample(feed, latency: 0.75)
        try await db.recordFeedSample(feed, latency: nil)

        var metrics = try await db.feedHealthMetrics(now: now)[feed]
        check(abs((metrics?.successRate ?? 0) - 2.0 / 3) < 1e-9 && metrics?.averageLatency == 0.5, "samples are stored")
        check(metrics?.assessedStories == 6, "stories with no extraction result are not assessed")
        check(metrics?.fullReaderShare == 0.5, "complete text outranks an old barrier, and long content counts")
        check(metrics?.extractionClass == .fullReader, "the stored class follows the counts")
        let frequency = 6.0 / 2
        check(metrics?.itemsPerDay == frequency, "frequency leaves out stories older than the window")

        // Across launches.
        await db.close()
        let reopened = DatabaseEngine(path: path)
        try await reopened.open()
        check(try await reopened.feedHealthMetrics(now: now)[feed] == metrics, "metrics survive a relaunch")

        // A feed that has been fading keeps a bounded history at the same rate.
        for index in 0..<(2 * DatabaseEngine.feedSampleWindow) {
            try await reopened.recordFeedSample(feed, latency: index % 2 == 0 ? 1 : nil)
        }
        metrics = try await reopened.feedHealthMetrics(now: now)[feed]
        let rate = metrics?.successRate ?? 0
        check(rate > 0.45 && rate < 0.55, "halving keeps the rate")
        check(abs((metrics?.averageLatency ?? 0) - 1) < 0.1, "halving keeps the latency")

        // One success among many failures keeps its weight through a halving.
        let sparse = "https://example.com/sparse.xml"
        try await reopened.recordFeedSuccess(sparse, at: now)
        try await reopened.recordFeedSample(sparse, latency: 1)
        for _ in 0..<(DatabaseEngine.feedSampleWindow - 1) {
            try await reopened.recordFeedSample(sparse, latency: nil)
        }
        try await reopened.recordFeedSample(sparse, latency: 1)
        let sparseLatency = try await reopened.feedHealthMetrics(now: now)[sparse]?.averageLatency
        check(sparseLatency == 1, "a success after a halving does not inflate the mean")

        // A reconciled duplicate keeps its feed link but is not a second story.
        let merged = "https://example.com/merged.xml"
        try await reopened.upsertArticles(
            [story("survivor", complete: true), story("duplicate", complete: true)], feedUrl: merged, now: now)
        let mergedStories = try await reopened.eventRows(
            "SELECT id FROM articles WHERE canonical_url LIKE '%/survivor' OR canonical_url LIKE '%/duplicate' ORDER BY canonical_url DESC;"
        )
        try await reopened.eventRows(
            "INSERT INTO article_reconciliations VALUES (?, ?, 'https://example.com/survivor', 'fingerprint');",
            [.text(mergedStories[1][0] ?? ""), .text(mergedStories[0][0] ?? "")])
        let mergedMetrics = try await reopened.feedHealthMetrics(now: now)[merged]
        check(mergedMetrics?.assessedStories == 1, "a reconciled duplicate does not count twice")

        // A malformed stored document costs that story its class, not the whole query.
        await reopened.close()
        func execute(_ sql: String) {
            var handle: OpaquePointer?
            check(sqlite3_open(path, &handle) == SQLITE_OK, "open the fixture")
            defer { sqlite3_close(handle) }
            check(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "fixture: \(sql)")
        }
        execute("UPDATE articles SET reader_document = 'not json' WHERE canonical_url LIKE '%/plain';")
        try await migrateFromV33(path: path, execute: execute, feed: feed)
    }

    /// A v33 library upgrades with its feeds and stories, and the new counters start at zero.
    static func migrateFromV33(path: String, execute: (String) -> Void, feed: String) async throws {
        execute(
            """
            PRAGMA legacy_alter_table=ON;
            ALTER TABLE articles DROP COLUMN reader_barrier;
            ALTER TABLE feeds DROP COLUMN fetch_attempts;
            ALTER TABLE feeds DROP COLUMN fetch_successes;
            ALTER TABLE feeds DROP COLUMN fetch_latency_total;
            PRAGMA user_version=33;
            """)
        let upgraded = DatabaseEngine(path: path)
        try await upgraded.open()
        let metrics = try await upgraded.feedHealthMetrics(now: now)[feed]
        check(metrics?.successRate == nil, "upgraded counters start empty")
        check(metrics?.assessedStories == 5, "upgraded stories keep their documents and lose only barriers")
        check(try await upgraded.storedSchemaVersion() == DatabaseEngine.schemaVersion, "a v33 library upgrades")
        let files = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
        check(files.contains { $0.contains("-before-v33-") }, "the upgrade keeps a rollback copy")
        await upgraded.close()
    }

    /// A real refresh through the fetcher: successes carry a latency, and neither an offline batch nor a server's
    /// scheduled pause counts against a feed.
    static func checkRefresh() async throws {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        defer { MockURLProtocol.requestHandler = nil }
        let fetcher = FeedFetcher(client: NewsTests.mockHTTPClient(configuration: config), now: { now })
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let good = "https://8.8.8.8/good.xml"
        let bad = "https://8.8.8.8/bad.xml"
        let body = Data(
            "<rss version='2.0'><channel><title>T</title><item><title>One</title><link>https://example.com/one</link></item></channel></rss>"
                .utf8)
        MockURLProtocol.requestHandler = { request in
            let status = request.url?.path == "/good.xml" ? 200 : 500
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                status == 200 ? body : Data()
            )
        }
        _ = await fetcher.fetchAllFeeds(urls: [good, bad], state: db)
        var metrics = try await db.feedHealthMetrics(now: now)
        check(metrics[good]?.successRate == 1, "a success is counted on refresh")
        check((metrics[good]?.averageLatency ?? -1) >= 0, "a success carries its latency")
        check(metrics[bad]?.successRate == 0 && metrics[bad]?.averageLatency == nil, "a failure carries no latency")

        // The failed feed now waits out its backoff: skipped requests are not attempts.
        _ = await fetcher.fetchAllFeeds(urls: [bad], state: db)
        metrics = try await db.feedHealthMetrics(now: now)
        check(metrics[bad]?.successRate == 0, "a paused feed stays at its count")
        let attempts = try await db.eventRows("SELECT fetch_attempts FROM feeds WHERE url = ?;", [.text(bad)])
        check(Double(attempts.first?.first.flatMap { $0 } ?? "") == 1, "a skipped request is not an attempt")

        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = FeedFetcher(client: NewsTests.mockHTTPClient(configuration: config), now: { now })
        _ = await offline.fetchAllFeeds(urls: [good], state: db)
        metrics = try await db.feedHealthMetrics(now: now)
        check(metrics[good]?.successRate == 1, "an offline batch says nothing about the feed")
        await db.close()
    }

    static func checkRows() async throws {
        func row(
            _ observed: FeedHealthObservations, state: FeedFetchState? = nil, url: String = "https://x.example/feed",
            publisher: String? = "X"
        ) -> PublisherHealthRow {
            PublisherHealthRow(
                feedURL: url, storedPublisher: publisher, metrics: FeedHealthMetrics(observed, now: now),
                health: FeedHealth(state, now: now))
        }
        let fresh = row(FeedHealthObservations())
        check(
            fresh.successText == "—" && fresh.latencyText == "—" && fresh.frequencyText == "—"
                && fresh.extractionText == "Unknown" && fresh.recommendations.isEmpty, "a new feed claims nothing")
        check(fresh.successSpoken == "Not measured yet", "VoiceOver hears unknown in words")
        let busy = row(
            FeedHealthObservations(
                attempts: 200, successes: 199, latencyTotal: 199 * 0.94, recentItems: 300,
                oldestRecentItem: now - 20 * day, fullReader: 4))
        check(busy.successText == "99%" && busy.successSpoken == "99 percent", "99.5% does not round up to perfect")
        check(busy.latencyText == "0.9 s" && busy.latencySpoken == "0.9 seconds", "latency has one decimal")
        check(
            busy.frequencyText == "15" && busy.frequencySpoken == "15 stories a day",
            "a busy feed reads in whole stories")
        check(busy.extractionText == "Full reader", "the text column names the class")
        let quiet = row(FeedHealthObservations(attempts: 1, successes: 1, latencyTotal: 1))
        check(
            quiet.frequencyText == "0" && quiet.frequencySortKey == 0, "a checked feed with no stories publishes zero")
        let rare = row(
            FeedHealthObservations(attempts: 1, successes: 1, recentItems: 1, oldestRecentItem: now - 29 * day))
        check(
            rare.frequencyText == "<0.1" && rare.frequencySpoken == "Less than 0.1 stories a day",
            "rare stays above zero")

        var failing = FeedFetchState()
        failing.failures = 2
        failing.lastFetchedAt = now - day
        failing.latestItemAt = now - 40 * day
        let paywalled = row(FeedHealthObservations(subscriberOnly: 3), state: failing)
        check(
            paywalled.recommendations == [.notResponding, .inactive, .requiresWebView], "recommendations keep one order"
        )
        check(
            paywalled.recommendationText == "Not responding · Inactive for over 30 days · Requires Web View",
            "recommendations read in the issue's words")
        check(
            row(FeedHealthObservations(blocked: 3)).recommendations == [.requiresWebView],
            "a blocked feed needs the Web View too")
        check(row(FeedHealthObservations(subscriberOnly: 2)).recommendations.isEmpty, "too few barriers say nothing")
        var recent = FeedFetchState()
        recent.latestItemAt = now - 29 * day
        check(row(FeedHealthObservations(), state: recent).recommendations.isEmpty, "29 quiet days is not inactive")

        let bad = row(FeedHealthObservations(attempts: 4, successes: 1))
        let good = row(FeedHealthObservations(attempts: 4, successes: 4))
        check(
            [fresh, good, bad].sorted(using: KeyPathComparator(\.successSortKey)).map(\.successText) == [
                "25%", "100%", "—",
            ],
            "the default order leads with trouble and leaves unknowns last")

        let catalogFeed = FeedCatalog.allFeeds[0]
        check(
            PublisherHealthRow.name(feedURL: catalogFeed.url, storedPublisher: "Other") == catalogFeed.title,
            "the catalog's title tells a publisher's feeds apart")
        check(
            PublisherHealthRow.name(feedURL: "https://x.example/f", storedPublisher: "Stored") == "Stored",
            "stored name")
        check(
            PublisherHealthRow.name(feedURL: "https://x.example/f", storedPublisher: nil) == "x.example",
            "the host last")
        check(PublisherHealthRow.footnote.hasPrefix(FeedHealth.disclaimer), "the footnote keeps the health disclaimer")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        try await db.upsertArticles([story("named")], feedUrl: "https://x.example/f", now: now)
        check(try await db.feedPublisherNames()["https://x.example/f"] == "Outlet", "stored publisher names are read")
        await db.close()
    }

    static func run() async {
        do {
            checkArithmetic()
            try await checkRows()
            try await checkStorage()
            try await checkRefresh()
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) feed health metric checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
