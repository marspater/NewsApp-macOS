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

extension NativeSuites {
    /// The runner's FeedParsingTests atom, test by test (#1070); the runner copy stays until CI shows parity.
    @Suite(.tags(.feedParsing, .integration)) struct FeedParsingSuite {
        @Test func feedErrorHierarchy() async { await Self.testFeedErrorHierarchy() }
        @Test func dateParsing() async { await Self.testDateParsing() }
        @Test func conditionalFeedRequests() async throws {
            try await Self.testConditionalFeedRequests(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func feedBackoffAndHostLimits() async throws { try await Self.testFeedBackoffAndHostLimits() }
        @Test func feedFailureKinds() async throws { try await Self.testFeedFailureKinds() }
        @Test func feedCatalog() async throws { try await Self.testFeedCatalog() }
        @Test func catalogReviewAndAlternatives() async throws { try await Self.testCatalogReviewAndAlternatives() }
        @Test func feedHealth() async throws { try await Self.testFeedHealth() }
        @Test func undatedArticleOrdering() async throws { try await Self.testUndatedArticleOrdering() }
        @Test func futureDatedItems() async throws { try await Self.testFutureDatedItems() }
        @Test func xMLParsing() async { await Self.testXMLParsing() }
        @Test func jSONParsing() async { await Self.testJSONParsing() }
        @Test func escapeXML() async { await Self.testEscapeXML() }
        @Test func oPMLParsingAndExporting() async { await Self.testOPMLParsingAndExporting() }
        @Test func oPMLHostileInput() async { await Self.testOPMLHostileInput() }
        @Test func articleIdentityDeep() async { await Self.testArticleIdentityDeep() }
        @Test func publisherTitleAliases() async throws { try await Self.testPublisherTitleAliases() }
        @Test func newsletterStrip() { Self.testNewsletterStrip() }
        @Test func canonicalArticleIngestion() async throws {
            try await Self.testCanonicalArticleIngestion(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func feedScopedGUIDs() async throws {
            try await Self.testFeedScopedGUIDs(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func validatedDocumentIdentity() async throws {
            try await Self.testValidatedDocumentIdentity(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
        @Test func publisherTextFingerprints() async throws { try await Self.testPublisherTextFingerprints() }
        @Test func auditParsingAndSettingsRegressions() async throws {
            try await Self.testAuditParsingAndSettingsRegressions(fixtureRoot: NewsTests.defaultFixtureRoot)
        }
    }
}

extension NativeSuites.FeedParsingSuite {
    /// `NewsTests.eventually`, recording its timeout through Swift Testing instead of the runner's failure log.
    static func eventually(_ message: String, timeout: Duration = .seconds(10), _ condition: @escaping () async -> Bool)
        async
    {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                expectTrue(false, message)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func testFeedErrorHierarchy() async {
        print("  - Testing FeedError localized descriptions...")

        let err1 = FeedError.malformedURL("bad-url")
        expectTrue(err1.errorDescription?.contains("Malformed URL") == true, "Malformed URL message")

        let err2 = FeedError.blockedHost(host: "evil.com", reason: "Private subnet")
        expectTrue(err2.errorDescription?.contains("evil.com") == true, "Blocked host message")

        let err3 = FeedError.responseTooLarge(bytes: 20 * 1024 * 1024, maxAllowed: 10 * 1024 * 1024)
        expectTrue(err3.errorDescription?.contains("20.0 MB exceeds 10.0 MB") == true, "Response too large message")

        let err4 = FeedError.dnsRebindingDetected(host: "rebind.example", ip: "127.0.0.1")
        expectTrue(err4.errorDescription?.contains("DNS rebinding") == true, "DNS rebinding message")

        // The preflight API has a closed error domain; rejected schemes never touch the network.
        do {
            try await SecureHTTPClient.shared.validateDestination(URL(fileURLWithPath: "/tmp/news-feed"))
            expectTrue(false, "Local file schemes must be refused")
        } catch {
            expectEqual(error, FeedError.insecureScheme("file"), "Preflight returns its typed FeedError")
        }
    }

    @MainActor
    static func testAuditParsingAndSettingsRegressions(fixtureRoot: URL) async throws {
        print("  - Testing unknown dates, GUID permalinks and folder-only OPML imports...")
        expectEqual(DateParser.parse(""), nil, "Missing publication dates are unknown")
        expectEqual(DateParser.parse("definitely-not-a-date"), nil, "Malformed dates are unknown")
        let undatedXML = Data(
            "<rss><channel><title>Publisher</title><item><title>Undated</title></item></channel></rss>".utf8)
        let first = FeedXMLParser(data: undatedXML).parse().first!
        let second = FeedXMLParser(data: undatedXML).parse().first!
        expectEqual(first.pubDate, DateParser.unknownDate, "Undated XML stories do not become breaking news")
        expectEqual(first.publicationDateText, "Date unavailable", "Unknown dates have an honest display label")
        expectEqual(first.cardDateText(), "Date unavailable", "Cards keep the honest unknown-date label")
        expectEqual(first.dateAccessibilityText, "publication date unavailable", "No date, no claim of publication")
        // An undated story with an ingestion time shows when it was added (#1037).
        var storedLate = first
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        storedLate.ingestedAt = clock.addingTimeInterval(-2 * 3600)
        // The same short date a dated story shows for that moment, so the test holds under any locale and OS wording.
        let twoHoursAgo = FeedArticle(
            title: "Dated", link: "https://example.com/two-hours", guid: nil, description: "",
            pubDate: clock.addingTimeInterval(-2 * 3600), source: "Publisher")
        expectEqual(
            storedLate.cardDateText(now: clock), "Added " + twoHoursAgo.cardDateText(now: clock),
            "A card shows when an undated story was added")
        expectTrue(storedLate.publicationDateText.hasPrefix("Added "), "The reader shows the added date")
        expectTrue(storedLate.dateAccessibilityText.hasPrefix("added "), "Accessibility says added, not published")
        var dated = FeedArticle(
            title: "Dated", link: "https://example.com/dated", guid: nil, description: "",
            pubDate: Date(timeIntervalSince1970: 1_700_000_000), source: "Publisher")
        dated.ingestedAt = storedLate.ingestedAt
        expectTrue(dated.dateAccessibilityText.hasPrefix("published "), "A dated story is still published")
        expectFalse(dated.cardDateText().hasPrefix("Added"), "A dated story ignores the ingestion time")
        // Loaded from the database an undated story carries its ingestion time; a search result carries a score instead (#1037).
        let undatedDB = DatabaseEngine(path: ":memory:")
        try await undatedDB.open()
        let undatedStory = FeedArticle(
            title: "Zeppelin harbour inspection", link: "https://example.com/zeppelin", guid: "zeppelin",
            description: "", pubDate: DateParser.unknownDate, source: "Publisher")
        try await undatedDB.upsertArticles([undatedStory])
        let listed = try await undatedDB.fetchArticles().first
        expectTrue(listed?.ingestedAt != nil, "A listed undated story carries when it was stored")
        let found = try await undatedDB.searchArticles(query: "zeppelin").first
        expectEqual(found?.id, listed?.id, "The search finds the undated story")
        expectTrue((found?.queryOrderValue ?? 1_000) < 1, "A search keeps its score as the order value")
        expectTrue(found?.ingestedAt != nil, "A search result still carries when the story was stored")
        expectEqual(found?.ingestedAt, listed?.ingestedAt, "The stored time is not the score")
        await undatedDB.close()
        do {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            func story(ageInSeconds age: TimeInterval) -> FeedArticle {
                FeedArticle(
                    title: "Dated", link: "https://example.com/dated", guid: "dated", description: "Text",
                    pubDate: now.addingTimeInterval(-age), source: "Test")
            }
            expectEqual(
                story(ageInSeconds: 20).cardDateText(now: now), "Just now", "A story under a minute old reads Just now")
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.dateTimeStyle = .numeric
            for age: TimeInterval in [60, 2 * 60 * 60, 24 * 60 * 60 - 1] {
                expectEqual(
                    story(ageInSeconds: age).cardDateText(now: now),
                    formatter.localizedString(fromTimeInterval: -age),
                    "Relative card dates use the supplied reference time, not the wall clock")
            }
        }
        expectEqual(first.id, second.id, "Undated stories without GUID or link retain a stable fingerprint")
        let json = Data(
            #"{"items":[{"id":"undated","url":"\#(fixtureRoot.appendingPathComponent("story").absoluteString)","date_published":"broken"}]}"#
                .utf8)
        expectEqual(
            JSONFeedParser.parse(data: json, feedURL: fixtureRoot.appendingPathComponent("feed").absoluteString)?.first?
                .pubDate,
            DateParser.unknownDate, "Malformed JSON dates use the same stable fallback")
        for attribute in ["", " isPermaLink=\"true\"", " isPermaLink=\"false\""] {
            let xml = Data(
                "<rss><channel><item><title>Permalink</title><guid\(attribute)>\(fixtureRoot.appendingPathComponent("permalink").absoluteString)</guid></item></channel></rss>"
                    .utf8)
            let article = FeedXMLParser(data: xml).parse().first!
            expectEqual(
                article.link,
                attribute.contains("false") ? "" : fixtureRoot.appendingPathComponent("permalink").absoluteString,
                "RSS GUID fallback respects explicit non-permalink identifiers")
        }
        let suite = testDefaultsSuite("test.audit.settings")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feed = fixtureRoot.appendingPathComponent("rss").absoluteString
        expectEqual(settings.addFeed(url: feed), feed, "New feed reports addition")
        expectEqual(settings.addFeed(url: feed), nil, "Duplicate feed reports no addition")
        let opml = Data(
            "<opml><body><outline text=\"Archive Folder\"><outline xmlUrl=\"\(feed)\"/></outline></body></opml>".utf8)
        expectEqual(settings.importFeeds(from: opml), 0, "Folder-only import adds no duplicate subscription")
        let reloaded = AppSettings(defaults: defaults)
        expectTrue(reloaded.userSections.contains("Archive Folder"), "Imported folders survive settings reload")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try opml.write(to: url)
        expectEqual(try await OPMLFileReader.read(url), opml, "Async file import preserves data")
        try Data(repeating: 32, count: OPMLFileReader.maximumBytes + 1).write(to: url)
        do {
            _ = try await OPMLFileReader.read(url)
            expectTrue(false, "Oversized OPML files must be rejected")
        } catch {
            // Expected bounded read failure.
        }
        do {
            _ = try OPMLParser.parseValidated(data: Data(repeating: 32, count: OPMLFileReader.maximumBytes + 1))
            expectTrue(false, "In-memory OPML imports must enforce the same size bound")
        } catch {
            // Expected validation failure.
        }

        // OPML Import Deduplication, Invalid URLs & Performance
        let opmlTestSettings = AppSettings(defaults: defaults)
        let sampleURL = "https://example.com/unique-feed.xml"
        _ = opmlTestSettings.addFeed(url: sampleURL)
        opmlTestSettings.addSection("Technology")

        let dupOPML = """
            <opml><body>
                <outline text="Dup Feed" xmlUrl="\(sampleURL)"/>
                <outline text="Technology">
                    <outline text="New Feed" xmlUrl="https://example.com/new-feed.xml"/>
                    <outline text="New Feed Repeat" xmlUrl="https://example.com/new-feed.xml"/>
                </outline>
                <outline text="InvalidFolder">
                    <outline text="Invalid Feed" xmlUrl="https://"/>
                </outline>
            </body></opml>
            """.data(using: .utf8)!

        let added = opmlTestSettings.importFeeds(from: dupOPML)
        expectEqual(
            added, 1,
            "Duplicate and invalid feeds should not be added; only the one unique new valid feed should be added")
        expectEqual(
            opmlTestSettings.feedURLs.filter { $0 == "https://example.com/new-feed.xml" }.count, 1,
            "New feed should only be added once")
        expectEqual(
            opmlTestSettings.feedURLs.filter { $0 == sampleURL }.count, 1, "Pre-existing feed should not be duplicated")
        expectEqual(
            opmlTestSettings.userSections.filter { $0 == "Technology" }.count, 1,
            "Pre-existing section should not be duplicated")
        expectFalse(
            opmlTestSettings.userSections.contains("InvalidFolder"),
            "Invalid feed URL should not cause invalid folder addition")

        let manySettings = AppSettings(defaults: defaults)
        var largeOPML = "<opml><body>\n"
        for i in 0..<10000 {
            largeOPML += "<outline text=\"Feed \(i)\" xmlUrl=\"https://example.com/feed\(i).xml\"/>\n"
        }
        largeOPML += "</body></opml>"
        let start = CFAbsoluteTimeGetCurrent()
        expectEqual(manySettings.importFeeds(from: Data(largeOPML.utf8)), 10000, "Large OPML import adds all feeds")
        let duration = CFAbsoluteTimeGetCurrent() - start
        expectTrue(duration < 5.0, "Large OPML import completes without quadratic stall (took \(duration)s)")
    }

    @MainActor
    static func testConditionalFeedRequests(fixtureRoot: URL) async throws {
        print("  - Testing conditional feed requests, 304 handling and atomic validator persistence...")
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        let client = NewsTests.mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        let feedURL = fixtureRoot.appendingPathComponent("conditional.xml")
        let modified = "Wed, 21 Oct 2026 07:28:00 GMT"

        // Header plumbing: validators are replayed, and only a conditional request may accept 304.
        var seen: [URLRequest] = []
        MockURLProtocol.requestHandler = { request in
            seen.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!, Data())
        }
        let (body, notModified) = try await client.fetchFeed(
            from: feedURL, validators: FeedValidators(etag: "W/\"v1\"", lastModified: modified))
        expectEqual(notModified.statusCode, 304, "Conditional request surfaces 304")
        expectTrue(body.isEmpty, "304 carries no body")
        expectEqual(seen.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"v1\"", "Weak ETag replayed verbatim")
        expectEqual(seen.last?.value(forHTTPHeaderField: "If-Modified-Since"), modified, "Last-Modified replayed")
        do {
            _ = try await client.fetchFeed(from: feedURL)
            expectTrue(false, "An unconditional request cannot accept 304")
        } catch {
            expectEqual(error as? FeedError, .httpStatus(304), "Unsolicited 304 stays an HTTP error")
        }
        expectTrue(
            FeedValidators(etag: "x\r\nInjected: 1", lastModified: String(repeating: "a", count: 600)).isEmpty,
            "Header injection and oversized validators are dropped")
        expectTrue(FeedValidators(etag: "\"caf\u{E9}\"", lastModified: nil).isEmpty, "Non-ASCII validators are dropped")

        // End to end through refresh, with a real database.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("conditional.sqlite").path
        let db = DatabaseEngine(path: path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let suite = testDefaultsSuite("test.conditional")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feed = feedURL.absoluteString
        settings.feedURLs = [feed]
        settings.aiEnabled = false
        // #799: only web links enter the library; an item without a link keeps its GUID identity.
        let linked = [
            "smb://evil.example/share", "x-apple.systempreferences:com.apple.preference.security",
            "file:///etc/passwd", "https://example.com/story", "http://example.com/older", "",
        ].map {
            FeedArticle(title: "Item", link: $0, guid: $0, description: "", pubDate: Date(), source: "Publisher")
        }
        expectEqual(
            FeedFetcher.webArticles(linked).map(\.link), ["https://example.com/story", "http://example.com/older", ""],
            "Feed items whose links are not web addresses are dropped")
        for link in [
            "smb://evil.example/share", "x-apple.systempreferences:com.apple.preference.security",
            "file:///etc/passwd", "javascript:alert(1)", "https:///no-host", "",
        ] {
            expectTrue(WebLink.url(link) == nil, "Every open site refuses \(link.isEmpty ? "an empty link" : link)")
        }
        expectEqual(
            WebLink.url(" https://example.com/story ")?.absoluteString, "https://example.com/story",
            "A web link opens, trimmed")
        let linkless = JSONFeedParser.parse(
            data: Data(
                #"{"version":"https://jsonfeed.org/version/1.1","title":"T","items":[{"id":"123","content_text":"Story"}]}"#
                    .utf8),
            feedURL: "https://example.com/feed.json")
        expectEqual(
            FeedFetcher.webArticles(linkless ?? []).map(\.guid), ["123"],
            "A JSON Feed item without a URL is kept by its ID")
        let emptyURL = JSONFeedParser.parse(
            data: Data(
                #"{"version":"https://jsonfeed.org/version/1.1","title":"T","items":[{"id":"https://example.com/a","url":"","content_text":"Story"}]}"#
                    .utf8),
            feedURL: "https://example.com/feed.json")
        expectEqual(emptyURL?.first?.link, "https://example.com/a", "An empty url falls back to a web ID")
        let fetcher = FeedFetcher(client: client)
        var notified = 0
        // No image lookup: it outlives fetchFeedsAsync and its write transaction would hold the lock the trigger edits need.
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, allowHTTP in await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db) },
            notifyBatch: { articles, _ in notified += articles.count },
            dependencies: FeedManager.Dependencies(imageFinder: .unavailable))
        func rss(_ names: [String]) -> Data {
            let items = names.map {
                "<item><title>Report \($0)</title><link>\(fixtureRoot.appendingPathComponent($0).absoluteString)</link><guid>\($0)</guid><description>Publisher report</description><pubDate>Wed, 21 Oct 2026 07:28:00 +0000</pubDate></item>"
            }
            return Data("<rss version='2.0'><channel><title>Conditional</title>\(items.joined())</channel></rss>".utf8)
        }
        func serve(_ names: [String], headers: [String: String]) {
            MockURLProtocol.requestHandler = { request in
                seen.append(request)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!,
                    rss(names)
                )
            }
        }
        func stored() async throws -> FeedValidators? { try await db.feedFetchStates()[feed]?.validators }

        seen = []
        serve(["a", "b"], headers: ["ETag": "\"v1\"", "Last-Modified": modified])
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        expectEqual(seen.count, 1, "First refresh requests the feed once")
        expectEqual(seen.first?.value(forHTTPHeaderField: "If-None-Match"), nil, "First refresh is unconditional")
        expectEqual(manager.articles.count, 2, "First refresh ingests the feed")
        expectEqual(
            try await stored(), FeedValidators(etag: "\"v1\"", lastModified: modified),
            "Validators persist with the ingested articles")

        seen = []
        MockURLProtocol.requestHandler = { request in
            seen.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!, Data())
        }
        let before = manager.articles
        await manager.fetchFeedsAsync()
        expectEqual(
            seen.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"", "Stored ETag is sent on the next refresh")
        expectEqual(
            seen.last?.value(forHTTPHeaderField: "If-Modified-Since"), modified,
            "Stored Last-Modified is sent on the next refresh")
        expectEqual(manager.articles, before, "304 leaves stored articles untouched")
        expectEqual(manager.feedStatuses[feed], .idle, "304 is a healthy refresh")
        expectEqual(notified, 2, "304 notifies nothing")
        expectEqual(try await stored(), FeedValidators(etag: "\"v1\"", lastModified: modified), "304 keeps validators")

        // An ingest that fails must not advance the validators, or the new items would hide behind a later 304.
        var connection: OpaquePointer?
        expectEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated conditional fixture")
        defer { sqlite3_close(connection) }
        expectEqual(
            sqlite3_exec(
                connection,
                "CREATE TRIGGER fail_ingest BEFORE INSERT ON articles BEGIN SELECT RAISE(ABORT, 'simulated ingestion failure'); END;",
                nil, nil, nil), SQLITE_OK, "Install failed-ingestion trigger")
        serve(["a", "b", "c"], headers: ["ETag": "\"v2\""])
        await manager.fetchFeedsAsync()
        expectEqual(manager.articles.count, 2, "Failed ingestion stores nothing")
        expectEqual(
            try await stored(), FeedValidators(etag: "\"v1\"", lastModified: modified),
            "Failed ingestion keeps the previous validators")

        expectEqual(
            sqlite3_exec(connection, "DROP TRIGGER fail_ingest;", nil, nil, nil), SQLITE_OK,
            "Remove failed-ingestion trigger")
        seen = []
        serve(["a", "b", "c"], headers: ["ETag": "\"v2\""])
        await manager.fetchFeedsAsync()
        expectEqual(
            seen.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"",
            "Retry still asks relative to the last ingested state")
        expectEqual(
            manager.articles.count, 3, "A server that answers 200 to a conditional request is ingested normally")
        expectEqual(
            try await stored(), FeedValidators(etag: "\"v2\"", lastModified: nil),
            "Validators advance with the new items and drop stale Last-Modified")

        serve(["a", "b", "c"], headers: [:])
        await manager.fetchFeedsAsync()
        expectEqual(try await stored(), nil, "A response without validators clears stale ones")

        serve(["a", "b", "c"], headers: ["ETag": "\"v3\""])
        await manager.fetchFeedsAsync()
        expectEqual(
            try await stored(), FeedValidators(etag: "\"v3\"", lastModified: nil), "Validators are recorded again")
        try await db.clearAllDatabaseCache()
        expectEqual(try await stored(), nil, "Purging replaceable caches forces the next refresh to be unconditional")
        manager.stopBackgroundWork()
        await db.close()
    }

    @MainActor
    static func testFeedBackoffAndHostLimits() async throws {
        print("  - Testing Retry-After, exponential backoff, per-host limits and manual-refresh limits...")

        // Policy: pure schedule and header parsing.
        expectEqual(FeedRetryPolicy.backoff(afterFailures: 0), 0, "No failures, no wait")
        expectEqual(
            [1, 2, 3, 4].map(FeedRetryPolicy.backoff(afterFailures:)), [600, 1200, 2400, 4800],
            "Backoff doubles from ten minutes")
        expectEqual(FeedRetryPolicy.backoff(afterFailures: 7), FeedRetryPolicy.maximumDelay, "Backoff is capped")
        expectEqual(
            FeedRetryPolicy.backoff(afterFailures: Int.max), FeedRetryPolicy.maximumDelay,
            "Huge failure counts cannot overflow")
        expectEqual(FeedRetryPolicy.delay(afterFailures: 1, retryAfter: 3600), 3600, "A longer Retry-After wins")
        expectEqual(
            FeedRetryPolicy.delay(afterFailures: 1, retryAfter: 30), 600, "Retry-After never shortens the backoff")
        expectEqual(
            FeedRetryPolicy.delay(afterFailures: 1, retryAfter: 1e12), FeedRetryPolicy.maximumRetryAfter,
            "Retry-After is capped at a day")
        expectEqual(FeedRetryPolicy.delay(afterFailures: 1, retryAfter: -5), 600, "Negative Retry-After is ignored")
        let reference = Date(timeIntervalSince1970: 1_792_567_620)  // Wed, 21 Oct 2026 07:27:00 GMT
        expectEqual(FeedRetryPolicy.retryAfter(header: "120", now: reference), 120, "Delay-seconds")
        expectEqual(FeedRetryPolicy.retryAfter(header: " 7 ", now: reference), 7, "Surrounding whitespace")
        expectEqual(
            FeedRetryPolicy.retryAfter(header: "Wed, 21 Oct 2026 07:28:00 GMT", now: reference), 60,
            "HTTP date in the future")
        expectEqual(
            FeedRetryPolicy.retryAfter(header: "Wed, 21 Oct 2026 07:00:00 GMT", now: reference), 0,
            "HTTP date in the past waits nothing")
        expectEqual(FeedRetryPolicy.retryAfter(header: "soon", now: reference), nil, "Garbage is ignored")
        expectEqual(FeedRetryPolicy.retryAfter(header: "-5", now: reference), nil, "Negative values are ignored")
        expectEqual(FeedRetryPolicy.retryAfter(header: nil, now: reference), nil, "Missing header")
        expectTrue(
            FeedRetryPolicy.retryAfter(header: String(repeating: "9", count: 400), now: reference).map { $0.isFinite }
                == true, "Absurd values stay finite")

        // Persistence: schedule survives reopening, success resets it, long quiet forgives it, validators are independent.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("backoff.sqlite").path
        let db = DatabaseEngine(path: path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = "https://8.8.8.8/persist.xml"
        await store.batchUpsert(
            articles: [
                FeedArticle(
                    title: "Kept", link: "https://example.com/kept", guid: "kept", description: "", pubDate: t0,
                    source: "Test")
            ],
            feedUrl: feed, validators: FeedValidators(etag: "\"keep\"", lastModified: nil))
        expectEqual(
            try await db.recordFeedFailure(feed, retryAfter: nil, at: t0), t0.addingTimeInterval(600),
            "First failure waits ten minutes")
        expectEqual(
            try await db.recordFeedFailure(feed, retryAfter: nil, at: t0.addingTimeInterval(601)),
            t0.addingTimeInterval(601 + 1200), "Second failure doubles the wait")
        await db.close()
        try await db.open()
        var stateAfterReopen = try await db.feedFetchStates()[feed]
        expectEqual(stateAfterReopen?.failures, 2, "Failure count survives reopening")
        expectEqual(stateAfterReopen?.retryAt, t0.addingTimeInterval(601 + 1200), "Retry time survives reopening")
        expectEqual(
            stateAfterReopen?.validators, FeedValidators(etag: "\"keep\"", lastModified: nil),
            "Failures do not touch validators")
        try await db.recordFeedSuccess(feed, at: t0.addingTimeInterval(4000))
        stateAfterReopen = try await db.feedFetchStates()[feed]
        expectEqual(stateAfterReopen?.failures, 0, "Success resets the failure count")
        expectEqual(stateAfterReopen?.retryAt, nil, "Success ends the wait")
        expectEqual(
            stateAfterReopen?.validators, FeedValidators(etag: "\"keep\"", lastModified: nil),
            "Success does not touch validators")
        // #788: a fresh 200 that carries no items still replaces the validators and the content stats.
        await store.batchUpsert(articles: [], feedUrl: feed, validators: FeedValidators(etag: nil, lastModified: nil))
        stateAfterReopen = try await db.feedFetchStates()[feed]
        expectTrue(stateAfterReopen?.validators == nil, "An empty 200 clears validators the feed no longer sends")
        expectEqual(stateAfterReopen?.itemCount, 0, "An empty 200 records that the feed carries no items")
        expectEqual(stateAfterReopen?.latestItemAt, nil, "An emptied feed has no newest item")
        try await db.recordFeedFailure(feed, retryAfter: nil, at: t0)
        try await db.recordFeedFailure(feed, retryAfter: nil, at: t0.addingTimeInterval(700))
        let forgiven = t0.addingTimeInterval(700 + 1200 + FeedRetryPolicy.maximumDelay + 1)
        expectEqual(
            try await db.recordFeedFailure(feed, retryAfter: nil, at: forgiven), forgiven.addingTimeInterval(600),
            "A long quiet period forgives old failures")

        // Fetcher: Retry-After, manual refresh inside the wait, and recovery.
        let mockConfig = URLSessionConfiguration.default
        mockConfig.protocolClasses = [MockURLProtocol.self]
        let mockClient = NewsTests.mockHTTPClient(configuration: mockConfig)
        defer { MockURLProtocol.requestHandler = nil }
        let clock = TestClock(t0)
        let fetcher = FeedFetcher(client: mockClient, now: { clock.now })
        let busy = "https://8.8.8.8/busy.xml"
        var requests: [String] = []
        var status = 429
        var headers = ["Retry-After": "3600"]
        let body = Data(
            "<rss version='2.0'><channel><title>T</title><item><title>One</title><link>https://example.com/one</link><guid>one</guid><description>Report</description></item></channel></rss>"
                .utf8)
        MockURLProtocol.requestHandler = { request in
            requests.append(request.url!.absoluteString)
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
                status == 200 ? body : Data()
            )
        }
        var results = await fetcher.fetchAllFeeds(urls: [busy], state: db)
        expectEqual(
            results.first?.error, .serverBusy(status: 429, retryAfter: 3600), "429 reports the server's Retry-After")
        expectEqual(
            try await db.feedFetchStates()[busy]?.retryAt, t0.addingTimeInterval(3600),
            "Retry-After becomes the persisted wait")
        clock.advance(by: 60)
        results = await fetcher.fetchAllFeeds(urls: [busy], state: db)  // a manual refresh takes the same path
        expectEqual(requests.count, 1, "A refresh inside the server's wait sends no request")
        expectEqual(
            results.first?.error, .retryScheduled(until: t0.addingTimeInterval(3600)),
            "The skipped feed reports when it resumes")
        clock.advance(by: 3600)
        status = 200
        headers = [:]
        results = await fetcher.fetchAllFeeds(urls: [busy], state: db)
        expectEqual(requests.count, 2, "Requests resume when the wait ends")
        expectEqual(results.first?.articles?.count, 1, "The recovered feed delivers its articles")
        expectEqual(try await db.feedFetchStates()[busy]?.failures ?? 0, 0, "Recovery clears the failure count")

        // Exponential backoff for 5xx; 503 without Retry-After; local rejections never back off.
        let flaky = "https://8.8.8.8/flaky.xml"
        status = 500
        var expected: [TimeInterval] = []
        for failures in 1...3 {
            let start = clock.now
            _ = await fetcher.fetchAllFeeds(urls: [flaky], state: db)
            let state = try await db.feedFetchStates()[flaky]
            expectEqual(state?.failures, failures, "Failure \(failures) is counted")
            expected.append(state!.retryAt!.timeIntervalSince(start))
            clock.advance(by: expected.last! + 1)
        }
        expectEqual(expected, [600, 1200, 2400], "Failing feeds back off exponentially")
        status = 503
        results = await fetcher.fetchAllFeeds(urls: [flaky], state: db)
        expectEqual(
            results.first?.error, .serverBusy(status: 503, retryAfter: nil),
            "503 without Retry-After is still a back-pressure signal")
        let insecure = "http://8.8.8.8/insecure.xml"
        _ = await fetcher.fetchAllFeeds(urls: [insecure], state: db)
        expectEqual(try await db.feedFetchStates()[insecure], nil, "A locally rejected URL is never scheduled")

        // Offline: when every request fails to connect nothing is blamed on the feeds; a mixed batch blames only the failing one.
        clock.advance(by: 3600)  // the 503 above cooled its whole host
        let down = "https://8.8.8.8/down.xml"
        let up = "https://8.8.4.4/up.xml"
        MockURLProtocol.requestHandler = { request in
            if request.url?.host == "8.8.8.8" { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = await fetcher.fetchAllFeeds(urls: [down, "https://8.8.8.8/down2.xml"], state: db)
        expectEqual(try await db.feedFetchStates()[down], nil, "An offline batch records no failures")
        _ = await fetcher.fetchAllFeeds(urls: [down, up], state: db)
        expectEqual(
            try await db.feedFetchStates()[down]?.failures, 1, "A feed failing while others succeed is backed off")

        // Host limits with held requests: two per host, many hosts in parallel.
        let gatedConfig = URLSessionConfiguration.default
        gatedConfig.protocolClasses = [GatedURLProtocol.self]
        let gatedClient = NewsTests.mockHTTPClient(configuration: gatedConfig)
        func answerAll(_ expectedCount: Int) async {
            var answered = 0
            while answered < expectedCount {
                if let url = GatedURLProtocol.heldURLs.first, GatedURLProtocol.respond(to: url, body: body) {
                    answered += 1
                } else {
                    await Task.yield()
                }
            }
        }
        GatedURLProtocol.reset()
        let slow = (1...5).map { "https://8.8.8.8/slow\($0).xml" } + (1...2).map { "https://8.8.4.4/slow\($0).xml" }
        let limited = FeedFetcher(client: gatedClient, now: { clock.now })
        let batch = Task { await limited.fetchAllFeeds(urls: slow, state: nil) }
        while GatedURLProtocol.started.count < 4 { await Task.yield() }
        await answerAll(slow.count)
        let finished = await batch.value
        expectEqual(finished.count, slow.count, "Every feed is fetched")
        expectEqual(
            GatedURLProtocol.peak.byHost["8.8.8.8"], FeedFetcher.maximumConcurrentFeedsPerHost,
            "A host never sees more than two concurrent requests")
        expectEqual(GatedURLProtocol.peak.total, 4, "Different hosts still run in parallel")

        // A host that pushes back is left alone, including feeds queued behind the refused one.
        GatedURLProtocol.reset()
        let siblings = (1...3).map { "https://8.8.8.8/sibling\($0).xml" }
        let cooling = FeedFetcher(client: gatedClient, now: { clock.now })
        let refused = Task { await cooling.fetchAllFeeds(urls: siblings, state: nil) }
        while GatedURLProtocol.started.count < 2 { await Task.yield() }
        GatedURLProtocol.respond(to: URL(string: siblings[0])!, status: 429, headers: ["Retry-After": "900"])
        // The refusal is handled in one actor turn, so once the cooldown is visible the queued sibling has been decided.
        while await cooling.cooldown(forHost: "8.8.8.8") == nil { await Task.yield() }
        GatedURLProtocol.respond(to: URL(string: siblings[1])!, body: body)
        let sibling = await refused.value
        expectEqual(
            Set(GatedURLProtocol.started.map(\.absoluteString)), Set([siblings[0], siblings[1]]),
            "The queued sibling is never requested")
        expectEqual(
            sibling.first { $0.urlString == siblings[2] }?.error,
            .retryScheduled(until: clock.now.addingTimeInterval(900)), "The sibling waits out the host's Retry-After")
        let again = await cooling.fetchAllFeeds(urls: [siblings[1]], state: nil)
        expectEqual(
            again.first?.error, .retryScheduled(until: clock.now.addingTimeInterval(900)),
            "The host cooldown outlives one refresh")
        expectEqual(GatedURLProtocol.started.count, 2, "No request is sent during the cooldown")

        // Cancelling a refresh is not a feed failure.
        GatedURLProtocol.reset()
        let cancelled = "https://8.8.4.4/cancelled.xml"
        let victim = Task {
            await FeedFetcher(client: gatedClient, now: { clock.now }).fetchAllFeeds(urls: [cancelled], state: db)
        }
        while GatedURLProtocol.started.isEmpty { await Task.yield() }
        victim.cancel()
        _ = await victim.value
        expectEqual(try await db.feedFetchStates()[cancelled], nil, "Cancellation records no failure")

        // End to end: Cmd-R inside the wait shows when the feed resumes and sends nothing.
        let suite = testDefaultsSuite("test.backoff")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let shown = "https://8.8.4.4/manager.xml"
        settings.feedURLs = [shown]
        settings.aiEnabled = false
        let managed = FeedFetcher(client: mockClient, now: { clock.now })
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, allowHTTP in await managed.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db) },
            notifyBatch: { _, _ in })
        requests = []
        status = 429
        headers = ["Retry-After": "1800"]
        MockURLProtocol.requestHandler = { request in
            requests.append(request.url!.absoluteString)
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data()
            )
        }
        let refreshStart = clock.now
        await manager.fetchFeedsAsync()
        expectEqual(
            manager.feedStatuses[shown], .failed(.serverBusy(status: 429, retryAfter: 1800)),
            "The refused refresh is reported")
        await manager.fetchFeedsAsync()
        expectEqual(requests.count, 1, "Manual refresh does not bypass the server's wait")
        expectEqual(
            manager.feedStatuses[shown], .failed(.retryScheduled(until: refreshStart.addingTimeInterval(1800))),
            "The paused feed reports when it resumes")
        manager.stopBackgroundWork()
        await db.close()
    }

    /// A manual refresh retries a feed a network change backed off, and nothing else (#927).
    @MainActor
    static func testFeedFailureKinds() async throws {
        print("  - Testing failure kinds and the manual retry of connectivity backoff (#927)...")
        expectEqual(
            FeedFailureKind.allCases.filter(\.isConnectivity), [.dns, .transport, .timeout],
            "Only an unanswered lookup, a lost path and a timeout count as connectivity")
        expectEqual(
            FeedFailureKind.liftedByManualRefresh, [.dns, .transport, .timeout, .dnsFiltered, .fakeIP],
            "A manual refresh also lifts a filtered or fake-IP answer (#929)")
        for (reason, kind) in [
            ("IPv4 current network (0.0.0.0/8)", IPAddressValidator.AnswerSubstitution.sinkhole),
            ("IPv6 unspecified address (::)", .sinkhole),
            ("IPv4-mapped IPv6 (IPv4 current network (0.0.0.0/8))", .sinkhole),
            ("IPv4 benchmarking network", .fakeIP),
        ] {
            expectEqual(IPAddressValidator.substitution(in: reason), kind, "\(reason) names its substitution")
        }
        for reason in [
            "RFC 1918 private network (10.0.0.0/8)", "IPv6 loopback (::1)", "Multicast address (224.0.0.0/4)",
        ] {
            expectEqual(IPAddressValidator.substitution(in: reason), nil, "\(reason) is a plain block")
        }
        expectTrue(
            !FeedError.substitutedAnswer(host: "x", kind: .sinkhole).isLocalRejection,
            "A substituted answer is recorded, so diagnostics show it")
        let urlErrors: [(URLError.Code, FeedFailureKind)] = [
            (.timedOut, .timeout), (.cannotFindHost, .dns), (.dnsLookupFailed, .dns),
            (.badURL, .transport), (.notConnectedToInternet, .transport), (.networkConnectionLost, .transport),
            (.cannotConnectToHost, .transport), (.dataNotAllowed, .transport), (.cancelled, .transport),
            (.secureConnectionFailed, .tls), (.serverCertificateUntrusted, .tls), (.serverCertificateHasBadDate, .tls),
            (.serverCertificateHasUnknownRoot, .tls), (.serverCertificateNotYetValid, .tls),
            (.clientCertificateRejected, .tls), (.clientCertificateRequired, .tls),
            (.badServerResponse, .unknown), (.cannotParseResponse, .unknown), (.userAuthenticationRequired, .unknown),
        ]
        for (code, kind) in urlErrors {
            expectEqual(FeedError(transportFailure: URLError(code)).failureKind, kind, "URLError \(code.rawValue)")
        }
        expectEqual(
            FeedError(transportFailure: CocoaError(.fileReadUnknown)).failureKind, .unknown,
            "An error of no known domain never counts as connectivity")
        let feedErrors: [(FeedError, FeedFailureKind)] = [
            (.malformedURL("x"), .policy), (.insecureScheme("http"), .policy), (.blockedPort(22), .policy),
            (.blockedHost(host: "x", reason: "y"), .policy),
            (.substitutedAnswer(host: "x", kind: .sinkhole), .dnsFiltered),
            (.substitutedAnswer(host: "x", kind: .fakeIP), .fakeIP),
            (.redirectBlocked(from: "a", to: "b", reason: "c"), .policy),
            (.dnsRebindingDetected(host: "x", ip: "y"), .policy), (.responseTooLarge(bytes: 2, maxAllowed: 1), .policy),
            (.tooManyRedirects(6), .http), (.httpStatus(500), .http), (.serverBusy(status: 429, retryAfter: 60), .http),
            (.unsupportedFormat("x"), .parse), (.parseFailed("x"), .parse),
            (.network("x"), .transport), (.timeout, .timeout), (.dnsUnanswered(host: "x", reason: "y"), .dns),
            (.noSuchHost("x"), .noSuchHost), (.tls("x"), .tls), (.unclassified("x"), .unknown),
            (.retryScheduled(until: Date()), .unknown),
        ]
        for (error, kind) in feedErrors {
            expectEqual(error.failureKind, kind, "\(error)")
            expectTrue(error.errorDescription?.isEmpty == false, "\(error) has text for Settings")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = DatabaseEngine(path: directory.appendingPathComponent("kinds.sqlite").path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        func kind(_ url: String) async throws -> FeedFailureKind? {
            try await db.feedFetchStates()[url]?.lastFailureKind
        }

        // A dead domain is not an offline batch, and an unanswered lookup is (no feed is blamed).
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(t0)
        let mockConfig = URLSessionConfiguration.default
        mockConfig.protocolClasses = [MockURLProtocol.self]
        defer { MockURLProtocol.requestHandler = nil }
        let dead = ["https://gone.example/one.xml", "https://gone.example/two.xml"]
        _ = await FeedFetcher(
            client: SecureHTTPClient(configuration: mockConfig, resolver: { _ in .noSuchHost }), now: { clock.now }
        ).fetchAllFeeds(urls: dead, state: db)
        expectEqual(try await kind(dead[0]), .noSuchHost, "A batch of dead domains is recorded, not taken for offline")
        let silent = "https://silent.example/feed.xml"
        _ = await FeedFetcher(
            client: SecureHTTPClient(configuration: mockConfig, resolver: { _ in .unresolvable(reason: "Timed out") }),
            now: { clock.now }
        ).fetchAllFeeds(urls: [silent], state: db)
        expectEqual(try await db.feedFetchStates()[silent], nil, "A batch whose lookups go unanswered blames no feed")

        // A fake-IP tunnel answers every name from 198.18.0.0/15 (#929): recorded with its own kind, never taken for
        // offline, and lifted by a manual refresh once the reader has changed the network.
        let tunnelled = "https://tunnel.example/feed.xml"
        _ = await FeedFetcher(
            client: SecureHTTPClient(
                configuration: mockConfig, resolver: { _ in .blocked(reason: "IPv4 benchmarking network") }),
            now: { clock.now }
        ).fetchAllFeeds(urls: [tunnelled], state: db)
        expectEqual(try await kind(tunnelled), .fakeIP, "A fake-IP answer is recorded as such")
        expectTrue(
            try await db.feedFetchStates()[tunnelled]?.retryAt.map { $0 > clock.now } == true,
            "A fake-IP answer backs the feed off until the network changes")
        try await db.clearConnectivityBackoff(at: clock.now)
        expectTrue(
            try await db.feedFetchStates()[tunnelled]?.retryAt.map { $0 <= clock.now } == true,
            "A manual refresh lifts a fake-IP backoff")

        // A blocked literal address involves no DNS answer, so it stays a plain block, never a filtered or fake-IP one.
        for literal in ["198.18.0.1", "198.18.0.1.", "0.0.0.0", "[::]"] {
            // No injected resolver: the system path guards literal addresses before any lookup.
            let client = SecureHTTPClient(configuration: mockConfig)
            do {
                try await client.validateDestination(URL(string: "https://\(literal)/feed.xml")!)
                expectTrue(false, "\(literal) is blocked")
            } catch let error as FeedError {
                if case .blockedHost = error {} else { expectTrue(false, "\(literal) is a plain block, got \(error)") }
            }
        }
        // A name whose answer is a sinkhole is the substituted answer, and its text names no single address.
        do {
            try await SecureHTTPClient(
                configuration: mockConfig, resolver: { _ in .blocked(reason: "IPv6 unspecified address (::)") }
            ).validateDestination(URL(string: "https://filtered.example/feed.xml")!)
            expectTrue(false, "A sinkhole answer is blocked")
        } catch let error as FeedError {
            expectEqual(error.failureKind, .dnsFiltered, "A sinkhole answer for a name is the filtered kind")
            expectFalse(error.errorDescription?.contains("0.0.0.0") ?? true, "The text names no single address")
        }

        // One feed of each kind, in one batch so the batch is not offline.
        let lost = "https://8.8.8.8/lost.xml"
        let certificate = "https://8.8.8.8/certificate.xml"
        let busy = "https://8.8.4.4/busy.xml"
        let failing = "https://example.org/failing.xml"
        let healthy = "https://example.org/healthy.xml"
        let body = Data(
            "<rss version='2.0'><channel><title>T</title><item><title>One</title><link>https://example.com/one</link><guid>one</guid></item></channel></rss>"
                .utf8)
        var requests: [String] = []
        var networkIsBack = false
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            requests.append(url)
            func answer(_ status: Int, _ headers: [String: String]? = nil, _ data: Data = Data()) -> (
                HTTPURLResponse, Data
            ) {
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, data)
            }
            switch url {
            case lost where !networkIsBack: throw URLError(.networkConnectionLost)
            case certificate: throw URLError(.serverCertificateUntrusted)
            case busy: return answer(503, ["Retry-After": "3600"])
            case failing: return answer(500)
            default: return answer(200, nil, body)
            }
        }
        let fetcher = FeedFetcher(client: NewsTests.mockHTTPClient(configuration: mockConfig), now: { clock.now })
        _ = await fetcher.fetchAllFeeds(urls: [lost, certificate, busy, failing, healthy], state: db)
        expectEqual(try await kind(lost), .transport, "A lost connection is stored as transport")
        expectEqual(try await kind(certificate), .tls, "A certificate failure is stored as TLS")
        expectEqual(try await kind(busy), .http, "A 503 is stored as HTTP")
        expectEqual(try await kind(failing), .http, "A 500 is stored as HTTP")
        expectEqual(try await kind(healthy), nil, "A success stores no kind")
        let busyUntil = try await db.feedFetchStates()[busy]?.retryAt
        expectEqual(busyUntil, t0.addingTimeInterval(3600), "The server's wait is stored")
        // A failure of unknown cause, and a connectivity failure on the host that just asked to be left alone.
        let unknown = "https://example.com/unknown.xml"
        try await db.recordFeedFailure(unknown, retryAfter: nil, at: t0)
        expectEqual(try await kind(unknown), .unknown, "A failure with no kind given is unknown")
        let cooled = "https://8.8.4.4/cooled.xml"
        try await db.recordFeedFailure(cooled, kind: .timeout, retryAfter: nil, at: t0)

        let suite = testDefaultsSuite("test.failure-kinds")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.feedURLs = [lost, certificate, busy, failing, healthy, unknown, cooled] + dead
        settings.aiEnabled = false
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, allowHTTP in await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db) },
            notifyBatch: { _, _ in }, dependencies: FeedManager.Dependencies(now: { clock.now }))
        defer { manager.stopBackgroundWork() }
        clock.advance(by: 60)

        // A scheduled refresh keeps every wait.
        requests = []
        await manager.fetchFeedsAsync(scheduled: true)
        expectEqual(requests, [healthy], "A scheduled refresh does not retry a feed in backoff")

        // A manual refresh on a network still down: the retry happens, fails and backs off further.
        requests = []
        await manager.fetchFeedsAsync()
        expectEqual(
            requests.sorted(), [lost, healthy].sorted(),
            "A manual refresh retries the connectivity failure and nothing a server, certificate or dead domain caused")
        var stored = try await db.feedFetchStates()[lost]
        expectEqual(stored?.failures, 2, "A failed retry still counts")
        expectEqual(stored?.retryAt, clock.now.addingTimeInterval(1200), "A failed retry backs off further")
        expectEqual(try await db.feedFetchStates()[busy]?.retryAt, busyUntil, "Retry-After still wins")
        if case .failed(.retryScheduled(let until))? = manager.feedStatuses[cooled] {
            expectEqual(until, busyUntil, "A host cooldown holds a connectivity failure on that host")
        } else {
            expectTrue(
                false,
                "The cooled host's feed reports its wait, not \(String(describing: manager.feedStatuses[cooled]))")
        }

        // Back online: the next manual refresh leaves the feed healthy.
        networkIsBack = true
        requests = []
        await manager.fetchFeedsAsync()
        expectEqual(requests.sorted(), [lost, healthy].sorted(), "The manual refresh retries it inside its backoff")
        stored = try await db.feedFetchStates()[lost]
        expectEqual(stored?.failures, 0, "A success clears the failure count")
        expectEqual(stored?.retryAt, nil, "A success clears the wait")
        expectEqual(stored?.lastFailureKind, nil, "A success clears the kind")
        expectEqual(try await kind(certificate), .tls, "A certificate failure stays until it succeeds")

        // A manual refresh that arrives during a scheduled one runs when that one ends, even if its caller is cancelled.
        let retrying = "https://8.8.8.8/retrying.xml"
        let racingSuite = testDefaultsSuite("test.failure-kinds-racing")
        defer { removeTestDefaults(racingSuite) }
        let racingSettings = AppSettings(defaults: UserDefaults(suiteName: racingSuite)!)
        racingSettings.feedURLs = [retrying, healthy]
        racingSettings.aiEnabled = false
        for cancelsScheduledCaller in [false, true] {
            try await db.recordFeedFailure(retrying, kind: .transport, retryAfter: nil, at: clock.now)
            let entered = NewsTests.SocketObservation()
            let released = NewsTests.SocketObservation()
            let racing = FeedManager(
                settings: racingSettings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, allowHTTP in
                    entered.recordText("entered")
                    while released.count == 0 { try? await Task.sleep(for: .milliseconds(5)) }
                    return await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db)
                },
                notifyBatch: { _, _ in }, dependencies: FeedManager.Dependencies(now: { clock.now }))
            defer { racing.stopBackgroundWork() }
            requests = []
            let scheduledRun = Task { await racing.fetchFeedsAsync(scheduled: true) }
            await eventually("The scheduled refresh is collecting") { entered.count == 1 }
            let manualRun = Task { await racing.fetchFeedsAsync() }
            await eventually("The manual refresh waits for the scheduled one") { !racing.manualRefreshWaiters.isEmpty }
            if cancelsScheduledCaller { scheduledRun.cancel() }
            released.recordText("released")
            await manualRun.value
            expectEqual(
                requests.sorted(), [retrying, healthy, healthy].sorted(),
                "The manual caller returns only after the refresh that retries the feed (\(cancelsScheduledCaller))")
            expectEqual(try await kind(retrying), nil, "The manual refresh that waited leaves the feed healthy")
            await scheduledRun.value
            expectTrue(racing.manualRefreshWaiters.isEmpty, "The request runs once")
        }

        // Stopping during the scheduled refresh resumes the caller waiting behind it, with no refresh after it.
        let cancelledEntered = NewsTests.SocketObservation()
        let cancelling = FeedManager(
            settings: racingSettings, store: store, schedulesRefresh: false,
            fetchBatch: { _, _ in
                cancelledEntered.recordText("entered")
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return []
            },
            notifyBatch: { _, _ in }, dependencies: FeedManager.Dependencies(now: { clock.now }))
        let cancelledRun = Task { await cancelling.fetchFeedsAsync(scheduled: true) }
        await eventually("The refresh to cancel is collecting") { cancelledEntered.count == 1 }
        let abandonedRun = Task { await cancelling.fetchFeedsAsync() }
        await eventually("The manual refresh waits behind it") { !cancelling.manualRefreshWaiters.isEmpty }
        cancelling.stopBackgroundWork()
        await abandonedRun.value
        await cancelledRun.value
        expectEqual(cancelledEntered.count, 1, "A cancelled refresh starts nothing after it")
        await db.close()
    }

    @MainActor
    static func testFeedCatalog() async throws {
        print("  - Testing the curated feed catalog, opt-in subscription and custom feeds...")
        let feeds = FeedCatalog.feeds
        let all = FeedCatalog.allFeeds
        expectTrue(
            (30...60).contains(feeds.count), "The starter catalog stays in the planned 30-60 range (\(feeds.count))")
        expectEqual(Set(all.map(\.id)).count, all.count, "Catalog ids are unique")
        expectEqual(Set(all.map(\.url)).count, all.count, "Catalog URLs are unique")
        for feed in all {
            expectEqual(
                AppSettings.normalizeFeedURL(feed.url), feed.url,
                "\(feed.id) is stored in subscription form, so it is fetched exactly as verified")
            let url = URL(string: feed.url)
            expectEqual(url?.scheme, "https", "\(feed.id) uses HTTPS")
            expectTrue(
                url?.host?.contains(".") == true && url?.user == nil && url?.password == nil,
                "\(feed.id) has a plain public host")
            expectTrue(
                feed.language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
                "\(feed.id) has a language code")
            expectTrue(
                feed.region == "global" || feed.region.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil,
                "\(feed.id) has a region")
            expectFalse(feed.title.isEmpty || feed.publisher.isEmpty, "\(feed.id) is labeled")
        }
        expectTrue(
            ISO8601DateFormatter().date(from: FeedCatalog.verifiedOn + "T00:00:00Z") != nil,
            "Verification date is a calendar date")
        for set in CatalogSet.offered {
            expectTrue(FeedCatalog.feeds(in: set).count >= 2, "\(set.title) is a real set")
            expectFalse(set.summary.isEmpty, "\(set.title) is described")
        }
        expectEqual(Set(feeds.map(\.language)), ["en"], "Only English feeds are offered")
        expectTrue(
            Set(FeedCatalog.parkedFeeds.map(\.language)).isSuperset(of: ["uk", "de", "fr", "it", "nl"]),
            "Other languages stay in the catalog, parked")
        expectFalse(CatalogSet.offered.contains(.europe), "A set with only parked feeds is not shown")

        // Earlier subscriptions to parked catalog feeds end at launch; custom and English feeds stay.
        let parkedSuite = testDefaultsSuite("test.catalog.parked")
        let parkedDefaults = UserDefaults(suiteName: parkedSuite)!
        defer { removeTestDefaults(parkedSuite) }
        let kept = ["https://example.com/custom.xml", feeds[0].url]
        parkedDefaults.set([kept[0], FeedCatalog.parkedFeeds[0].url, kept[1]], forKey: AppSettings.feedURLsKey)
        expectEqual(
            AppSettings(defaults: parkedDefaults).feedURLs, kept, "Parked catalog subscriptions are removed in order")
        expectEqual(parkedDefaults.stringArray(forKey: AppSettings.feedURLsKey), kept, "The removal persists")

        // Stories show the catalog publisher for their site, not a feed title such as "World news".
        func story(_ link: String, _ source: String) -> FeedArticle {
            FeedArticle(title: "Story", link: link, guid: link, description: "", pubDate: Date(), source: source)
        }
        expectEqual(
            story("https://www.theguardian.com/world/2026/oct/08/story", "World news").publisherName, "The Guardian",
            "Site host names the publisher")
        expectEqual(
            story("https://www.dw.com/en/story/a-1", "Deutsche Welle: DW.com").publisherName, "Deutsche Welle",
            "A feed subdomain matches the site")
        expectEqual(
            story("https://example.com/story", "Example Daily\n  Example Daily").publisherName, "Example Daily",
            "Other sites keep the feed title's first line")
        expectEqual(
            story("https://notaljazeera.com/story", "Other").publisherName, "Other",
            "Only the same host or its subdomains match")

        // A retired subscription ends once per retirement version; subscribing again later is kept.
        let nyt = "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"
        let onet = "https://wiadomosci.onet.pl/.feed"
        let ft = "https://www.ft.com/world?format=rss"
        let hill = "https://thehill.com/feed"
        expectFalse(FeedCatalog.allFeeds.contains { $0.url == hill }, "A reader-blocking feed leaves the catalog")
        expectFalse(AppSettings.defaultFeeds.contains(nyt), "Retired feeds are not fresh-install defaults")
        expectFalse(FeedCatalog.allFeeds.contains { $0.url == onet }, "Retired feeds leave the catalog")
        parkedDefaults.set([kept[0], nyt, onet], forKey: AppSettings.feedURLsKey)
        expectEqual(
            AppSettings(defaults: parkedDefaults).feedURLs, [kept[0], nyt, onet],
            "Settings that already retired every version keep manual subscriptions")
        parkedDefaults.removeObject(forKey: AppSettings.retiredFeedsVersionKey)
        parkedDefaults.set(true, forKey: "retired_default_feeds_v1")
        expectEqual(
            AppSettings(defaults: parkedDefaults).feedURLs, [kept[0], nyt],
            "The first retirement's flag counts as version 1; later ones still apply")
        parkedDefaults.removeObject(forKey: AppSettings.retiredFeedsVersionKey)
        parkedDefaults.removeObject(forKey: "retired_default_feeds_v1")
        parkedDefaults.set([kept[0], nyt, onet, ft, hill], forKey: AppSettings.feedURLsKey)
        expectEqual(AppSettings(defaults: parkedDefaults).feedURLs, [kept[0]], "Every retired subscription ends")
        let resubscribed = AppSettings(defaults: parkedDefaults)
        _ = resubscribed.addFeed(url: nyt)
        expectEqual(
            AppSettings(defaults: parkedDefaults).feedURLs, [kept[0], nyt], "A later manual subscription stays")

        // Opt-in: a fresh install subscribes to nothing from the catalog beyond its own defaults.
        let suite = testDefaultsSuite("test.catalog")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        expectEqual(
            feeds.filter(settings.isSubscribed).map(\.id), ["ars-technica"],
            "Only a default feed is subscribed before the user chooses")

        let world = FeedCatalog.feeds(in: .world)
        settings.feedURLs = ["https://example.com/custom.xml"]
        expectEqual(settings.addCatalogFeeds(world), world.count, "A set subscribes to each of its feeds")
        expectEqual(settings.addCatalogFeeds(world), 0, "Choosing a set twice adds nothing")
        expectEqual(
            settings.feedURLs.first, "https://example.com/custom.xml", "Existing subscriptions stay first and untouched"
        )
        expectEqual(settings.feedURLs.count, world.count + 1, "Only the chosen set was added")
        expectEqual(
            settings.addFeed(url: "https://example.org/own.xml"), "https://example.org/own.xml",
            "Custom RSS still subscribes next to catalog feeds")
        settings.removeFeed(url: world[0].url)
        expectFalse(settings.isSubscribed(world[0]), "Any catalog source can be unsubscribed")
        expectTrue(settings.isSubscribed(world[1]), "Unsubscribing one source keeps the others")
        expectEqual(
            defaults.stringArray(forKey: AppSettings.feedURLsKey), settings.feedURLs,
            "Catalog choices persist like any subscription")

        // One refresh covers a whole batch, and an already-subscribed feed does not refresh anything.
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        settings.feedURLs = []
        settings.aiEnabled = false
        let requested = TestRecorder()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await requested.record(urls)
                return urls.map { url in
                    let story = FeedArticle(
                        title: "Catalog story from \(url)", link: url + "/catalog-story", guid: "catalog-\(url)",
                        description: "", pubDate: Date(), source: "Catalog publisher")
                    return (url, [story], nil, nil)
                }
            },
            notifyBatch: { _, _ in })
        let ukraine = FeedCatalog.feeds(in: .ukraine)
        manager.addCatalogFeeds(ukraine)
        await eventually("The new batch is fetched together") {
            await requested.batches.contains { Set($0) == Set(ukraine.map(\.url)) }
        }
        // A refresh still in flight would absorb the next one; count only after it has finished.
        await eventually("The catalog refresh finishes") { await MainActor.run { !manager.isAnyFeedLoading } }
        expectEqual(
            store.articles.filter { $0.title.hasPrefix("Catalog story from") }.count, ukraine.count,
            "A newly subscribed catalog feed's stories reach the library with that refresh (#782)")
        expectTrue(
            FeedUpdateBuffer.subscriptionAdded(from: [], to: ukraine.map(\.url)),
            "Subscribing makes the list take the refresh as the reader's, not park it behind Show N New Stories")
        expectFalse(
            FeedUpdateBuffer.subscriptionAdded(from: ukraine.map(\.url), to: Array(ukraine.map(\.url).dropFirst())),
            "Unsubscribing starts no reader refresh in the list")
        var held = FeedUpdateBuffer()
        held.holdsSubscription = true
        held.replace(with: FeedSnapshot(articles: store.articles))
        expectFalse(held.holdsSubscription, "Showing the list's stories ends a subscription's hold")
        var holding = FeedUpdateBuffer()
        holding.replace(with: FeedSnapshot(articles: [store.articles.last!]))
        expectEqual(
            holding.receive(FeedSnapshot(articles: store.articles), holding: false, mode: .events), .replaced,
            "A reader refresh shows the new stories instead of waiting behind the updates button")
        let batches = await requested.batches.count
        manager.addCatalogFeeds(ukraine)
        await manager.fetchFeedsAsync()
        expectEqual(await requested.batches.count, batches + 1, "Re-adding subscribed feeds triggers no extra refresh")
        manager.stopBackgroundWork()
    }

    @MainActor
    static func testCatalogReviewAndAlternatives() async throws {
        print("  - Testing catalog reviews, advisories, topic gaps and alternatives (#244)...")
        // 1. Advisory lookup
        let f24Advisory = FeedCatalog.advisory(for: "https://www.france24.com/en/rss")
        expectTrue(f24Advisory != nil, "France 24 has a registered maintainer advisory")
        expectEqual(f24Advisory?.reason, .readerInaccessible, "France 24 advisory reason matches")
        expectEqual(f24Advisory?.uncertainty, .known, "France 24 uncertainty is known")
        expectTrue(f24Advisory?.evidenceLinks.isEmpty == false, "Evidence links exist")

        // 2. Trailing slashes / normalization in advisory lookup
        let f24Normalized = FeedCatalog.advisory(for: "https://www.france24.com/en/rss/")
        expectEqual(f24Normalized, f24Advisory, "Normalized URL matches advisory")

        // 3. Alternative source lookup
        let f24Alternatives = FeedCatalog.alternatives(for: "https://www.france24.com/en/rss")
        expectFalse(f24Alternatives.isEmpty, "France 24 provides alternatives")
        let altIDs = Set(f24Alternatives.map(\.id))
        expectTrue(altIDs.contains("bbc-world") || altIDs.contains("dw-english"), "Contains expected alternatives")
        expectFalse(altIDs.contains("france-24"), "Feed never recommends itself as an alternative")
        expectTrue(
            f24Alternatives.allSatisfy(FeedCatalog.feeds.contains), "Alternatives are offered, never parked, feeds")
        let retiredAlternatives = FeedCatalog.alternatives(
            for: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")
        expectEqual(
            Set(retiredAlternatives.map(\.id)), ["guardian-world", "bbc-world"],
            "A retired feed outside the catalog still gets its suggested alternatives")

        // 4. Fallback alternative lookup for feeds without explicit alternative list
        let techCrunch = "https://techcrunch.com/feed"
        let techAlternatives = CatalogReviewEngine.alternatives(for: techCrunch)
        expectFalse(techAlternatives.isEmpty, "Fallback alternatives exist for catalog topic")
        expectFalse(techAlternatives.contains { $0.url == techCrunch }, "Does not include itself")
        expectTrue(techAlternatives.allSatisfy { $0.set == .technology }, "All alternatives share topic set")

        // 5. Topic gap detection
        let allFeeds = FeedCatalog.feeds
        let zeroSubscribedGaps = CatalogReviewEngine.detectTopicGaps(subscribedURLs: [], catalog: allFeeds)
        expectEqual(
            zeroSubscribedGaps.count, CatalogSet.offered.count, "0 subscriptions has gaps for every offered set")

        // Subscribing to World and Tech removes those gaps
        let partialURLs = [
            "https://feeds.bbci.co.uk/news/world/rss.xml",
            "https://feeds.arstechnica.com/arstechnica/index",
        ]
        let partialGaps = CatalogReviewEngine.detectTopicGaps(subscribedURLs: partialURLs, catalog: allFeeds)
        let gapSets = Set(partialGaps.map(\.catalogSet))
        expectFalse(gapSets.contains(.world), "World news is no longer a gap")
        expectFalse(gapSets.contains(.technology), "Technology is no longer a gap")
        expectTrue(gapSets.contains(.politics), "Politics remains an uncovered gap")
        expectTrue(gapSets.contains(.scienceHealth), "Science & health remains an uncovered gap")
        for gap in partialGaps {
            expectFalse(gap.candidateFeeds.isEmpty, "Each gap offers candidate feeds")
            expectTrue(gap.candidateFeeds.allSatisfy { $0.set == gap.catalogSet }, "Candidates belong to gap set")
            expectFalse(gap.rationale.isEmpty, "Gap provides human rationale")
        }

        // Subscribing to all catalog feeds leaves 0 gaps
        let allSubscribedGaps = CatalogReviewEngine.detectTopicGaps(
            subscribedURLs: allFeeds.map(\.url), catalog: allFeeds)
        expectTrue(allSubscribedGaps.isEmpty, "Fully covered reading diet has 0 gaps")

        // 6. Advisory dismissal persistence and invariant checks
        let dismissSuite = testDefaultsSuite("test.catalog.dismissal")
        let dismissDefaults = UserDefaults(suiteName: dismissSuite)!
        defer { removeTestDefaults(dismissSuite) }

        let testSettings = AppSettings(defaults: dismissDefaults)
        let targetFeed = "https://www.france24.com/en/rss"
        expectFalse(testSettings.isAdvisoryDismissed(for: targetFeed, date: "2026-10-08"), "Not dismissed initially")

        testSettings.dismissAdvisory(for: targetFeed + "/", date: "2026-10-08")
        expectTrue(testSettings.visibleAdvisory(for: targetFeed) == nil, "A dismissed advisory is hidden in every view")
        expectTrue(
            testSettings.visibleAdvisory(for: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml") != nil,
            "Dismissing one feed's advisory leaves other advisories visible")
        expectTrue(
            testSettings.isAdvisoryDismissed(for: targetFeed, date: "2026-10-08"), "Dismissal persists normalized")
        expectTrue(
            testSettings.isAdvisoryDismissed(for: targetFeed, date: "2026-10-01"), "Earlier advisory is also covered")
        expectFalse(
            testSettings.isAdvisoryDismissed(for: targetFeed, date: "2026-10-09"), "Future advisory is not dismissed")

        // Reloading settings preserves dismissed state
        let reloadedSettings = AppSettings(defaults: dismissDefaults)
        expectTrue(
            reloadedSettings.isAdvisoryDismissed(for: targetFeed, date: "2026-10-08"),
            "Reloaded settings retains dismissal")

        // Invariant: subscriptions to advised or retired feeds survive a relaunch
        let retiredFeed = "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"
        _ = testSettings.addFeed(url: targetFeed)
        _ = testSettings.addFeed(url: retiredFeed)
        let relaunched = AppSettings(defaults: dismissDefaults)
        expectTrue(
            relaunched.feedURLs.contains(targetFeed) && relaunched.feedURLs.contains(retiredFeed),
            "Feeds with advisories remain in user subscriptions after relaunch")
    }

    @MainActor
    static func testFeedHealth() async throws {
        print("  - Testing feed health: availability, freshness, text quality and persistence...")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func health(_ configure: (inout FeedFetchState) -> Void) -> FeedHealth {
            var state = FeedFetchState(lastFetchedAt: now)
            configure(&state)
            return FeedHealth(state, now: now)
        }
        let unknown = FeedHealth(nil, now: now)
        expectEqual(
            [unknown.availability, health { $0.lastFetchedAt = nil }.availability], [.unknown, .unknown],
            "A feed never fetched is not rated")
        // The catalog finds a subscription's health by feed key, so a stored trailing slash still shows (#803).
        let slashHealth = health { $0.lastFetchedAt = now }
        let entries = ["https://slash.example.com/feed/": slashHealth]
        expectEqual(
            FeedManager.health(for: "https://slash.example.com/feed", in: entries), slashHealth,
            "Health stored with a trailing slash is found without it")
        expectEqual(
            FeedManager.health(for: "https://slash.example.com/feed/", in: entries), slashHealth,
            "Health is found by the exact URL")
        expectEqual(
            FeedManager.health(for: "https://other.example.com/feed", in: entries), nil,
            "Another feed has no health")
        expectEqual(unknown.freshness, .unknown, "No items, no freshness")
        expectEqual(unknown.textQuality, .unknown, "No items, no text quality")
        expectEqual(health { _ in }.availability, .responding, "A fetched feed responds")
        let retry = now.addingTimeInterval(600)
        expectEqual(
            health {
                $0.failures = 3
                $0.retryAt = retry
            }.availability, .failing(failures: 3, retryAt: retry), "Failures are reported with the next attempt")
        let day: TimeInterval = 86_400
        func freshness(_ age: TimeInterval) -> FeedHealth.Freshness {
            health { $0.latestItemAt = now.addingTimeInterval(-age) }.freshness
        }
        expectEqual(
            [
                freshness(0), freshness(-3_600), freshness(3 * day), freshness(3 * day + 1), freshness(30 * day),
                freshness(30 * day + 1),
            ],
            [.recent, .recent, .recent, .quiet, .quiet, .stale],
            "Freshness windows (future-dated items count as recent)")
        func quality(_ full: Int, of count: Int) -> FeedHealth.TextQuality {
            health {
                $0.itemCount = count
                $0.fullTextItems = full
            }.textQuality
        }
        expectEqual(
            [
                quality(0, of: 0), quality(8, of: 10), quality(79, of: 100), quality(3, of: 10), quality(29, of: 100),
                quality(0, of: 10),
            ],
            [.unknown, .full, .partial, .partial, .summaries, .summaries], "Text quality thresholds")
        expectTrue(
            health { $0.failures = 1 }.needsAttention
                && health { $0.latestItemAt = now.addingTimeInterval(-31 * day) }.needsAttention,
            "Failing and long-inactive feeds ask for attention")
        expectFalse(health { $0.latestItemAt = now.addingTimeInterval(-day) }.needsAttention, "A healthy feed does not")
        var good = FeedFetchState(lastFetchedAt: now)
        (good.latestItemAt, good.itemCount, good.fullTextItems) = (now.addingTimeInterval(-7_200), 10, 9)
        let summary = FeedHealth(good, now: now).summary(now: now)
        expectTrue(
            summary.hasPrefix("Responding · Newest item ") && summary.hasSuffix(" · Full text"),
            "Summary reads availability, freshness, text: \(summary)")
        expectTrue(
            health { $0.failures = 1 }.summary(now: now).hasPrefix("Not responding (1 failed attempt)"),
            "A failing feed says so plainly")
        expectEqual(FeedHealth(nil, now: now).summary(now: now), "Not checked yet", "An unchecked feed says so")
        expectTrue(
            FeedHealth.disclaimer.contains("not a rating of accuracy or trustworthiness"),
            "The disclaimer rules out a truthfulness reading")
        let wordings = [summary, health { $0.failures = 4 }.summary(now: now), unknown.summary(now: now)].map {
            $0.lowercased()
        }
        expectFalse(
            wordings.contains { text in
                ["credib", "bias", "fake", "reliab", "trust", "score", "accura"].contains { text.contains($0) }
            }, "Health wording never rates the reporting")

        // Content stats come from the response, not from the archive.
        func item(_ guid: String, date: Date, text: Int?) -> FeedArticle {
            FeedArticle(
                title: "Report \(guid)", link: "https://example.com/\(guid)", guid: guid, description: "",
                pubDate: date, source: "Test",
                fullContent: text.map { String(repeating: "x", count: $0) })
        }
        let stats = FeedContentStats(articles: [
            item("a", date: now, text: 1200), item("b", date: now.addingTimeInterval(-day), text: 1199),
            item("c", date: DateParser.unknownDate, text: nil),
        ])
        expectEqual(
            stats,
            FeedContentStats(articles: [
                item("a", date: now, text: 1200), item("b", date: now.addingTimeInterval(-day), text: 1199),
                item("c", date: DateParser.unknownDate, text: nil),
            ]), "Stats are a pure function of the articles")
        expectEqual([stats.itemCount, stats.fullTextItems], [3, 1], "Full text starts at 1200 characters")
        expectEqual(stats.latestItem, now, "Undated items do not set the newest date")
        expectEqual(
            FeedContentStats(articles: [item("c", date: DateParser.unknownDate, text: nil)]).latestItem, nil,
            "Only undated items: no newest date")

        // Persistence with the ingest, untouched by 304 and failures.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = DatabaseEngine(path: directory.appendingPathComponent("health.sqlite").path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let feed = "https://8.8.8.8/health.xml"
        let before = Date()
        await store.batchUpsert(
            articles: [item("a", date: now, text: 1500), item("b", date: now.addingTimeInterval(-day), text: nil)],
            feedUrl: feed,
            validators: FeedValidators(etag: "\"h1\"", lastModified: nil))
        var stored = try await db.feedFetchStates()[feed]
        expectEqual([stored?.itemCount, stored?.fullTextItems], [2, 1], "Ingest records what the response carried")
        expectEqual(stored?.latestItemAt, now, "Ingest records the newest item")
        expectTrue(
            (stored?.lastFetchedAt ?? .distantPast) >= before.addingTimeInterval(-1),
            "Ingest records when the feed answered")
        try await db.recordFeedSuccess(feed, at: now)
        try await db.recordFeedFailure(feed, retryAfter: nil, at: now)
        stored = try await db.feedFetchStates()[feed]
        expectEqual(
            [stored?.itemCount, stored?.fullTextItems], [2, 1], "304 and failures keep the last content stats")
        expectEqual(
            stored?.validators, FeedValidators(etag: "\"h1\"", lastModified: nil),
            "Health writes never touch validators")
        await store.batchUpsert(
            articles: [item("c", date: now.addingTimeInterval(day), text: 2000)], feedUrl: feed,
            validators: FeedValidators(etag: nil, lastModified: nil))
        stored = try await db.feedFetchStates()[feed]
        expectEqual([stored?.itemCount, stored?.fullTextItems], [1, 1], "A newer response replaces the stats")
        expectEqual(
            stored?.failures, 1,
            "Ingest writes only its own columns, so an earlier failure count stays until a success clears it")

        // End to end: a refresh publishes health to the UI model.
        let mockConfig = URLSessionConfiguration.default
        mockConfig.protocolClasses = [MockURLProtocol.self]
        defer { MockURLProtocol.requestHandler = nil }
        let suite = testDefaultsSuite("test.health")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let live = "https://8.8.4.4/live.xml"
        settings.feedURLs = [live]
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        let fetcher = FeedFetcher(client: NewsTests.mockHTTPClient(configuration: mockConfig))
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, allowHTTP in await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db) },
            notifyBatch: { _, _ in })
        let body = String(repeating: "Publisher report text. ", count: 80)
        let rfc822 = { () -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return formatter.string(from: Date())
        }()
        let xml = Data(
            "<rss version='2.0' xmlns:content='http://purl.org/rss/1.0/modules/content/'><channel><title>Live</title><item><title>One</title><link>https://example.com/live-one</link><guid>live-one</guid><pubDate>\(rfc822)</pubDate><content:encoded>\(body)</content:encoded></item></channel></rss>"
                .utf8)
        var status = 200
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: status == 429 ? ["Retry-After": "900"] : nil)!, status == 200 ? xml : Data()
            )
        }
        await manager.fetchFeedsAsync()
        let responding = manager.feedHealth[live]
        expectEqual(responding?.availability, .responding, "A refreshed feed reports as responding")
        expectEqual(responding?.freshness, .recent, "Its items are recent")
        expectEqual(responding?.textQuality, .full, "Its text is full")
        status = 429
        await manager.fetchFeedsAsync()
        if case .failing(let failures, let retryAt)? = manager.feedHealth[live]?.availability {
            expectEqual(failures, 1, "A refusal is counted")
            expectTrue((retryAt ?? .distantPast) > Date(), "The next attempt is in the future")
        } else {
            expectTrue(false, "A refused feed reports as failing")
        }
        expectEqual(manager.feedHealth[live]?.textQuality, .full, "Content stats survive a failure")
        manager.stopBackgroundWork()
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
        expectEqual(articles.count, 6, "All three formats parse")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        try await db.upsertArticles(articles, now: now)
        let stored = try await db.fetchArticles()
        for format in ["RSS", "Atom", "JSON"] {
            let future = stored.first { $0.title == "\(format) future" }
            let skew = stored.first { $0.title == "\(format) skew" }
            expectEqual(future?.pubDate, DateParser.unknownDate, "\(format): a date years ahead is stored as unknown")
            expectTrue(
                abs((future?.queryOrderValue ?? 0) - now.timeIntervalSince1970) < 60,
                "\(format): the future-dated story lists by its ingestion time")
            expectTrue(
                abs((skew?.pubDate.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970 - 300) < 5,
                "\(format): clock skew keeps the date")
        }
        let futureCard = await MainActor.run { stored.first { $0.title == "RSS future" }?.cardDateText() }
        expectTrue(futureCard?.hasPrefix("Added ") == true, "A future date shows when the story was added (#1037)")
        try await db.upsertArticles(articles, now: now.addingTimeInterval(60))
        let refreshed = try await db.fetchArticles()
        expectEqual(
            refreshed.first { $0.title == "RSS future" }?.queryOrderValue,
            stored.first { $0.title == "RSS future" }?.queryOrderValue, "A refresh keeps the original ingestion time")
        // A row stored with a future date before the clamp existed is repaired when its feed refreshes, even with
        // retention off.
        let stale = stored.first { $0.title == "RSS future" }!
        _ = try await db.eventRows(
            "UPDATE articles SET published_at = ? WHERE id = ?;", [.real(2_524_608_000), .text(stale.id)])
        try await db.upsertArticles(articles, now: now.addingTimeInterval(120))
        expectEqual(
            try await db.fetchArticles().first { $0.title == "RSS future" }?.pubDate, DateParser.unknownDate,
            "A refresh repairs a stored future date")
        // A row stored before the clamp existed is returned to ingestion order by retention.
        let legacy = stored.first { $0.title == "RSS skew" }!
        _ = try await db.eventRows(
            "UPDATE articles SET published_at = ? WHERE id = ?;", [.real(2_524_608_000), .text(legacy.id)])
        for article in stored { try await db.markRead(articleId: article.id, isRead: true) }
        expectEqual(
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
        expectTrue(inserted.contains(linkless.id), "A clamped link-less item keeps its parsed ID")
        expectEqual(
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
        expectEqual(
            Set(snapshot.prefix(3).map(\.id)), Set(undated.map(\.id)),
            "Undated stories remain visible beyond 500 dated stories")
        expectEqual(snapshot.first?.pubDate, DateParser.unknownDate, "Ordering never fabricates a publication date")
        let firstPage = try await db.fetchArticles(limit: 2)
        let remainder = try await db.fetchArticles(
            limit: nil, options: ArticleFetchOptions(after: ArticleQueryCursor(firstPage.last!)))
        expectEqual((firstPage + remainder).count, 504, "Date cursor includes every row")
        expectEqual(Set((firstPage + remainder).map(\.id)).count, 504, "Tied ingestion dates do not duplicate rows")
        let searchPage = try await db.searchArticles(query: "is:unread", limit: 2)
        let searchRemainder = try await db.searchArticles(
            query: "is:unread", limit: 600, after: ArticleQueryCursor(searchPage.last!))
        expectEqual(
            (searchPage + searchRemainder).map(\.id), (firstPage + remainder).map(\.id),
            "Filter-only search uses the same order and cursor")
        try await db.upsertArticles(undated)
        expectEqual(
            try await db.fetchArticles(limit: 3).map(\.queryOrderValue), snapshot.prefix(3).map(\.queryOrderValue),
            "Refresh preserves original ingestion time")
        try await db.markRead(articleId: undated[0].id, isRead: true)
        expectEqual(try await db.pruneOldArticles(), 0, "New undated read stories are not pruned as ancient")
        await db.close()
    }

    static func testDateParsing() async {
        print("  - Testing Date parsing...")

        let date1Str = "Tue, 19 May 2026 20:30:00 GMT"
        let date1 = DateParser.parse(date1Str)
        expectTrue((date1?.timeIntervalSince1970 ?? 0) > 0, "Should successfully parse RFC 822 date")

        let date2Str = "2026-05-19T20:30:00Z"
        let date2 = DateParser.parse(date2Str)
        expectTrue((date2?.timeIntervalSince1970 ?? 0) > 0, "Should successfully parse ISO 8601 date")
        expectEqual(
            DateParser.parse("2026-10-24"), Date(timeIntervalSince1970: 1_792_800_000),
            "A date-only ISO 8601 value is midnight UTC instead of an unknown date")
        expectEqual(
            DateParser.parse("2026-10-24T06:00:00"), Date(timeIntervalSince1970: 1_792_821_600),
            "A zone-less ISO 8601 time is read as UTC")
        expectEqual(DateParser.parse("yesterday"), nil, "Prose is still not a date")
    }

    static func testXMLParsing() async {
        print("  - Testing XML Feed parsing...")

        let sampleXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
            <channel>
                <title>Ars Technica &amp; News</title>
                <item>
                    <title>Apple Announces M5 Architecture</title>
                    <link>https://arstechnica.com/gadgets/2026/05/apple-m5-chip/</link>
                    <guid isPermaLink="false">ars-m5-2026</guid>
                    <description>&lt;p&gt;The new M5 silicon introduces unified quantum accelerators.&lt;/p&gt;</description>
                    <pubDate>Tue, 19 May 2026 18:00:00 GMT</pubDate>
                    <enclosure url="https://cdn.arstechnica.net/m5-hero.jpg" type="image/jpeg" length="123456" />
                    <category>Hardware</category>
                </item>
            </channel>
            </rss>
            """.data(using: .utf8)!

        let parser = FeedXMLParser(data: sampleXML, feedURL: "https://feeds.arstechnica.com/arstechnica/index")
        let articles = parser.parse()

        expectEqual(articles.count, 1, "Should parse 1 article")
        let article = articles[0]

        expectEqual(article.title, "Apple Announces M5 Architecture", "Title should match")
        expectEqual(article.guid, "ars-m5-2026", "Guid should be parsed directly")
        expectEqual(article.id, "ars-m5-2026", "id should resolve to guid")
        expectEqual(
            article.description, "The new M5 silicon introduces unified quantum accelerators.",
            "HTML in description should be cleaned")
        expectEqual(article.imageUrl, "https://cdn.arstechnica.net/m5-hero.jpg", "Image enclosure URL should be parsed")
        expectEqual(article.category, "Hardware", "Category should match")
        expectEqual(article.source, "Ars Technica & News", "Decoded channel title should be assigned as source")

        // #1145: a relative image resolves against the xml:base of the field that holds it.
        let fieldBaseXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
                <title>Field Bases</title>
                <entry xml:base="https://cdn.example.com/entry/">
                    <title>Summary Base</title><id>base-1</id><link href="https://feeds.example.com/1"/>
                    <summary type="html" xml:base="https://cdn.example.com/summary/"><![CDATA[<img src="lead.jpg"/>]]></summary>
                </entry>
                <entry xml:base="https://cdn.example.com/entry/">
                    <title>Content Base</title><id>base-2</id><link href="https://feeds.example.com/2"/>
                    <content type="html" xml:base="https://cdn.example.com/content/"><![CDATA[<img src="body.jpg"/>]]></content>
                </entry>
                <entry xml:base="https://cdn.example.com/entry/">
                    <title>Entry Base</title><id>base-3</id><link href="https://feeds.example.com/3"/>
                    <summary type="html"><![CDATA[<img src="plain.jpg"/>]]></summary>
                </entry>
            </feed>
            """.data(using: .utf8)!
        expectEqual(
            FeedXMLParser(data: fieldBaseXML, feedURL: "https://feeds.example.com/atom.xml").parse().map(\.imageUrl),
            [
                "https://cdn.example.com/summary/lead.jpg",
                "https://cdn.example.com/content/body.jpg",
                "https://cdn.example.com/entry/plain.jpg",
            ],
            "A field's own xml:base wins over the entry's, which still applies without one (#1145)")

        // #1134: relative <img> URLs in description and content:encoded resolve against item xml:base and feedURL.
        let relativeImageXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
            <channel>
                <title>Relative Images</title>
                <item xml:base="https://cdn.example.com/stories/2026/">
                    <title>Relative Description Image</title>
                    <link>post-1</link>
                    <guid isPermaLink="false">rel-1</guid>
                    <description><![CDATA[<p>Lead</p><img src="images/hero.jpg?w=1200"/>]]></description>
                </item>
                <item xml:base="https://cdn.example.com/stories/2026/">
                    <title>Relative Content Encoded Image</title>
                    <link>post-2</link>
                    <guid isPermaLink="false">rel-2</guid>
                    <description>Plain summary</description>
                    <content:encoded><![CDATA[<p>First paragraph</p><img src="/assets/featured.png?w=800"/>]]></content:encoded>
                </item>
            </channel>
            </rss>
            """.data(using: .utf8)!
        let relativeArticles = FeedXMLParser(
            data: relativeImageXML, feedURL: "https://feeds.example.com/rss.xml"
        ).parse()
        expectEqual(relativeArticles.count, 2, "Should parse both relative-image items")
        expectEqual(
            relativeArticles[0].imageUrl,
            "https://cdn.example.com/stories/2026/images/hero.jpg?w=1200",
            "Relative <img> in description resolves against item xml:base (#1134)")
        expectEqual(
            relativeArticles[1].imageUrl,
            "https://cdn.example.com/assets/featured.png?w=800",
            "Root-relative <img> in content:encoded resolves against item xml:base (#1134)")

        // #1082: HTML references in CDATA <img> attributes decode once, under attribute rules, before URL resolution.
        let overlongImage = "https://cdn.example.com/long.jpg?" + String(repeating: "&#0000000038;", count: 4000)
        func entityItem(_ html: String) -> String {
            """
            <item xml:base="https://cdn.example.com/stories/2026/">
                <title>Entity Image Item</title>
                <link>https://feeds.example.com/post</link>
                <description><![CDATA[\(html)]]></description>
            </item>
            """
        }
        let entityImageXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
            <channel>
                <title>Entity Images</title>
                \(entityItem(#"<p>Lead</p><img src="https://cdn.example.com/hero.jpg?w=1200&#038;h=800&amp;fit=crop"/>"#))
                \(entityItem(#"<img src="images/hero.jpg?size=1200&amp;format=webp"/>"#))
                \(entityItem(#"<img src="https://cdn.example.com/signed.jpg?token=a&amp;amp;b"/>"#))
                \(entityItem(#"<img src="https://cdn.example.com/query.jpg?a=1&copy=2"/>"#))
                \(entityItem("<img src=\"\(overlongImage)\"/><img src=\"https://cdn.example.com/second.jpg\"/>"))
            </channel>
            </rss>
            """.data(using: .utf8)!
        let entityArticles = FeedXMLParser(data: entityImageXML, feedURL: "https://feeds.example.com/rss.xml").parse()
        expectEqual(
            entityArticles.map(\.imageUrl),
            [
                "https://cdn.example.com/hero.jpg?w=1200&h=800&fit=crop",
                "https://cdn.example.com/stories/2026/images/hero.jpg?size=1200&format=webp",
                "https://cdn.example.com/signed.jpg?token=a&amp;b",
                "https://cdn.example.com/query.jpg?a=1&copy=2",
                "https://cdn.example.com/second.jpg",
            ],
            "CDATA image attributes decode once and an over-long candidate is skipped before decoding (#1082)")

        // #1150: undeclared media: and dc: prefixes preserve the item's image and byline.
        let undeclaredPrefixXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
            <channel>
                <title>Undeclared Prefixes</title>
                <item>
                    <title>Undeclared Item</title>
                    <link>https://example.com/undeclared</link>
                    <media:thumbnail url="https://example.com/undeclared-thumb.jpg"/>
                    <dc:creator>Jane Doe</dc:creator>
                </item>
            </channel>
            </rss>
            """.data(using: .utf8)!
        let undeclaredArticles = FeedXMLParser(data: undeclaredPrefixXML, feedURL: "https://example.com/rss").parse()
        expectEqual(undeclaredArticles.count, 1, "Should parse undeclared-prefix item")
        expectEqual(
            undeclaredArticles.first?.imageUrl,
            "https://example.com/undeclared-thumb.jpg",
            "Undeclared media:thumbnail preserves item image (#1150)")
        expectEqual(
            undeclaredArticles.first?.author,
            "Jane Doe",
            "Undeclared dc:creator preserves item byline (#1150)")

        // #1150: prefixes bound to an unrelated namespace are treated as foreign elements, not well-known ones.
        let unrelatedNamespaceXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:media="http://example.com/other-media" xmlns:dc="http://example.com/other-dc">
            <channel>
                <title>Unrelated Namespaces</title>
                <item>
                    <title>Unrelated Item</title>
                    <link>https://example.com/unrelated</link>
                    <media:thumbnail url="https://example.com/unrelated-thumb.jpg"/>
                    <dc:creator>Other Creator</dc:creator>
                </item>
            </channel>
            </rss>
            """.data(using: .utf8)!
        let unrelatedArticles = FeedXMLParser(data: unrelatedNamespaceXML, feedURL: "https://example.com/rss").parse()
        expectEqual(unrelatedArticles.count, 1, "Should parse unrelated-namespace item")
        expectNil(
            unrelatedArticles.first?.imageUrl,
            "Prefix bound to unrelated namespace is not treated as well-known media:thumbnail (#1150)")
        expectNil(
            unrelatedArticles.first?.author,
            "Prefix bound to unrelated namespace is not treated as well-known dc:creator (#1150)")

        // #1149: Latin-1 feed with no XML encoding declaration transcoded using charset header.
        let latin1NoDeclXML = """
            <rss version="2.0">
            <channel>
                <title>Café des Nouvelles</title>
                <item>
                    <title>Édition Spéciale</title>
                    <link>https://example.com/edition</link>
                    <guid>edition-1</guid>
                    <description>Résumé des événements.</description>
                </item>
            </channel>
            </rss>
            """.data(using: .isoLatin1)!
        let parsedNoDecl = FeedXMLParser(
            data: latin1NoDeclXML, feedURL: "https://example.com/rss", textEncodingName: "iso-8859-1"
        ).parse()
        expectEqual(parsedNoDecl.count, 1, "Latin-1 feed with charset header parses successfully (#1149)")
        expectEqual(
            parsedNoDecl.first?.title, "Édition Spéciale",
            "Article title with Latin-1 characters is transcoded (#1149)")
        expectEqual(
            parsedNoDecl.first?.source, "Café des Nouvelles",
            "Channel title with Latin-1 characters is preserved (#1149)")

        // #1149: XML declaration in the document takes precedence over the header charset.
        let latin1WithDeclXML = """
            <?xml version="1.0" encoding="ISO-8859-1"?>
            <rss version="2.0">
            <channel>
                <title>Théâtre Français</title>
                <item>
                    <title>Représentation</title>
                    <link>https://example.com/theatre</link>
                    <guid>theatre-1</guid>
                    <description>Détails du spectacle.</description>
                </item>
            </channel>
            </rss>
            """.data(using: .isoLatin1)!
        let parsedWithDecl = FeedXMLParser(
            data: latin1WithDeclXML, feedURL: "https://example.com/rss", textEncodingName: "utf-8"
        ).parse()
        expectEqual(
            parsedWithDecl.count, 1,
            "Document encoding declaration takes precedence over conflicting header (#1149)")
        expectEqual(
            parsedWithDecl.first?.title, "Représentation",
            "Article title parses using document's declared encoding (#1149)")

        // #1149: FeedFetcher end-to-end Latin-1 feed with Content-Type charset and no XML declaration
        let client = NewsTests.mockHTTPClient(
            configuration: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [MockURLProtocol.self]
                return config
            }())
        defer { MockURLProtocol.requestHandler = nil }
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/rss+xml; charset=iso-8859-1"])!,
                latin1NoDeclXML
            )
        }
        let fetcherResult = await FeedFetcher(client: client).fetchSingleFeed(
            urlString: "https://example.com/latin1.xml")
        expectEqual(fetcherResult.error, nil, "Latin-1 feed with Content-Type header fetches and parses (#1149)")
        expectEqual(
            fetcherResult.articles?.first?.title, "Édition Spéciale",
            "FeedFetcher extracts and transcodes Latin-1 feed with charset header (#1149)")

        // #1149: FeedFetcher end-to-end document declaration precedence over header
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/rss+xml; charset=utf-8"])!,
                latin1WithDeclXML
            )
        }
        let fetcherPrecedenceResult = await FeedFetcher(client: client).fetchSingleFeed(
            urlString: "https://example.com/declared.xml")
        expectEqual(
            fetcherPrecedenceResult.error, nil,
            "FeedFetcher respects document encoding declaration over conflicting header (#1149)")
        expectEqual(
            fetcherPrecedenceResult.articles?.first?.title, "Représentation",
            "FeedFetcher parses title via declared encoding (#1149)")

        // #1149: Parameter boundary check ignores prefix such as xcharset and matches true charset
        let xcharsetResp = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/rss+xml; xcharset=utf-8; charset=iso-8859-1"])!
        expectEqual(
            FeedFetcher.extractCharset(from: xcharsetResp), "iso-8859-1",
            "xcharset prefix is ignored in favor of complete charset parameter boundary (#1149)")

        let quotedResp = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/rss+xml; charset=\"iso-8859-1\""])!
        expectEqual(
            FeedFetcher.extractCharset(from: quotedResp), "iso-8859-1",
            "Quoted charset parameter value is extracted cleanly (#1149)")

        // #1148: Publisher XML defects (bare ampersand, HTML entities, control characters, invalid UTF-8) repaired outside CDATA.
        var defectXML = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
            <!-- Comment with bare & and &nbsp; -->
            <channel>
                <title>Publisher & Network &nbsp;</title>
                <item>
                    <title>Q&A with AT&T &copy; &mdash; \u{0007}</title>
                    <link>https://example.com/qa</link>
                    <guid>qa-1</guid>
                    <description><![CDATA[Preserve & and <tags> and &nbsp; verbatim]]></description>
                </item>
                <item>
                    <title>Item with bad UTF-8: 
            """.utf8)
        defectXML.append(contentsOf: [0xFF, 0xFE])
        defectXML.append(
            contentsOf: """
                </title>
                        <link>https://example.com/bad-utf8</link>
                        <guid>bad-1</guid>
                    </item>
                </channel>
                </rss>
                """.utf8)

        let defectArticles = FeedXMLParser(data: defectXML, feedURL: "https://example.com/rss").parse()
        expectEqual(defectArticles.count, 2, "Feeds with publisher defects parse all items (#1148)")
        expectEqual(
            defectArticles.first?.title, "Q&A with AT&T © —",
            "Bare ampersands, HTML entities, and control characters are repaired (#1148)")
        let cdataSample = "<![CDATA[Preserve & and <tags> and &nbsp; verbatim]]>".data(using: .utf8)!
        expectEqual(
            FeedXMLParser.repairXML(data: cdataSample), cdataSample,
            "CDATA sections with ampersands and markup remain unchanged (#1148)")
        expectTrue(
            defectArticles.last?.title.contains("Item with bad UTF-8") ?? false,
            "Invalid UTF-8 sequences are replaced and item is preserved (#1148)")

        // #1148: Entity and DTD declarations are still refused before repair.
        let hostileEntity = """
            <!DOCTYPE rss [<!ENTITY test "payload">]>
            <rss version="2.0"><channel><item><title>&test;</title></item></channel></rss>
            """.data(using: .utf8)!
        let hostileParser = FeedXMLParser(data: hostileEntity, feedURL: "https://example.com/rss")
        expectTrue(hostileParser.parse().isEmpty, "Entity declarations remain refused (#1148)")
        expectEqual(
            hostileParser.parseError, "XML entity declarations are not allowed",
            "Entity rejection error is preserved (#1148)")

        // #1148: Attribute list declarations rejected by parser delegate
        let hostileAttlist = """
            <!DOCTYPE rss [<!ATTLIST item id CDATA #IMPLIED>]>
            <rss version="2.0"><channel><item><title>Test</title></item></channel></rss>
            """.data(using: .utf8)!
        let attlistParser = FeedXMLParser(data: hostileAttlist, feedURL: "https://example.com/rss")
        expectTrue(attlistParser.parse().isEmpty, "Attlist declarations refused (#1148)")
        expectEqual(
            attlistParser.parseError, "XML attribute list declarations are not allowed",
            "Attlist error message set (#1148)")

        // #1148: Valid UTF-16 and UTF-32 feeds with BOM are preserved during repair
        let utf16XML = """
            <?xml version="1.0" encoding="UTF-16"?>
            <rss version="2.0"><channel><title>UTF16 &amp; Feed</title><item><title>Item 1</title><link>https://example.com/1</link><guid>1</guid></item></channel></rss>
            """
        var utf16Data = Data([0xFF, 0xFE])  // UTF-16 LE BOM
        utf16Data.append(utf16XML.data(using: .utf16LittleEndian)!)
        let utf16Parsed = FeedXMLParser(data: utf16Data, feedURL: "https://example.com/rss").parse()
        expectEqual(utf16Parsed.count, 1, "UTF-16 feed with BOM parses correctly (#1148)")

        var utf32Data = Data([0xFF, 0xFE, 0x00, 0x00])  // UTF-32 LE BOM
        utf32Data.append(utf16XML.data(using: .utf32LittleEndian)!)
        let utf32Parsed = FeedXMLParser(data: utf32Data, feedURL: "https://example.com/rss").parse()
        expectEqual(utf32Parsed.count, 1, "UTF-32 feed with BOM parses correctly (#1148)")

        // #1148: UTF-16 with bare ampersand and declared encoding repairs and parses correctly
        let utf16BareAmpXML = """
            <?xml version="1.0" encoding="UTF-16"?>
            <rss version="2.0"><channel><title>AT&T News</title><item><title>Item 1</title><link>https://example.com/1</link><guid>1</guid></item></channel></rss>
            """
        var utf16BareAmpData = Data([0xFF, 0xFE])
        utf16BareAmpData.append(utf16BareAmpXML.data(using: .utf16LittleEndian)!)
        let utf16BareAmpParsed = FeedXMLParser(data: utf16BareAmpData, feedURL: "https://example.com/rss").parse()
        expectEqual(utf16BareAmpParsed.count, 1, "UTF-16 feed with bare ampersand repairs and parses (#1148)")

        // #1148: UTF-32 feed with encoding in body/CDATA leaves body text intact
        let utf32BodyXML = """
            <?xml version="1.0" ENCODING="UTF-32"?>
            <rss version="2.0"><channel><title>Test</title><item><title>Code</title><description><![CDATA[use encoding="gzip" here]]></description><link>https://example.com/1</link><guid>1</guid></item></channel></rss>
            """
        var utf32BodyData = Data([0xFF, 0xFE, 0x00, 0x00])
        utf32BodyData.append(utf32BodyXML.data(using: .utf32LittleEndian)!)
        let utf32BodyParsed = FeedXMLParser(data: utf32BodyData, feedURL: "https://example.com/rss").parse()
        expectEqual(utf32BodyParsed.count, 1, "UTF-32 feed with encoding declaration in body parses (#1148)")
        expectTrue(
            utf32BodyParsed.first?.description.contains("encoding=\"gzip\"") == true,
            "Body encoding attribute remains intact (#1148)")

        // #1148: Disallowed numeric entities (control chars, surrogates) are escaped
        let badEntityXML = """
            <rss version="2.0"><channel><title>Test</title><item><title>Bad &#0; and &#xD800; and &#X41; and &amp;</title><link>https://example.com/1</link><guid>1</guid></item></channel></rss>
            """.data(using: .utf8)!
        let badEntityParsed = FeedXMLParser(data: badEntityXML, feedURL: "https://example.com/rss").parse()
        expectEqual(badEntityParsed.count, 1, "Feed with disallowed numeric entities parses after escaping (#1148)")
    }

    static func testJSONParsing() async {
        print("  - Testing JSON Feed parsing...")

        let sampleJSON = """
            {
                "version": "https://jsonfeed.org/version/1.1",
                "title": "Daring Fireball",
                "home_page_url": "https://daringfireball.net/",
                "feed_url": "https://daringfireball.net/feeds/json",
                "items": [
                    {
                        "id": "df-item-9982",
                        "url": "https://daringfireball.net/2026/05/swift_6_release",
                        "title": "Swift 6 Concurrency Everywhere",
                        "content_html": "<p>Swift 6 has landed with complete actor isolation.</p>",
                        "date_published": "2026-05-19T14:00:00Z",
                        "image": "https://daringfireball.net/images/df-header.png"
                    }
                ]
            }
            """.data(using: .utf8)!

        let articles = JSONFeedParser.parse(data: sampleJSON, feedURL: "https://daringfireball.net/feeds/json")
        expectTrue(articles != nil, "Should parse valid JSON Feed data")
        expectEqual(articles?.count, 1, "Should contain 1 article")

        let art = articles![0]
        expectEqual(art.title, "Swift 6 Concurrency Everywhere", "Title should match")
        expectEqual(art.guid, "df-item-9982", "Guid should match item id")
        expectEqual(art.id, "df-item-9982", "id should resolve to guid")
        expectEqual(art.source, "Daring Fireball", "Source should match feed title")
        expectEqual(art.imageUrl, "https://daringfireball.net/images/df-header.png", "Image URL should match")

        // #1133: UTF-8 BOM-prefixed JSON Feeds are routed to JSONFeedParser by FeedFetcher instead of FeedXMLParser.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = NewsTests.mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        var bomPayload = Data([0xEF, 0xBB, 0xBF])
        bomPayload.append(sampleJSON)
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/feed+json"])!,
                bomPayload
            )
        }
        let bomFeedURL = NewsTests.defaultFixtureRoot.appendingPathComponent("feed.json").absoluteString
        let bomResult = await FeedFetcher(client: client).fetchSingleFeed(
            urlString: bomFeedURL)
        expectEqual(bomResult.error, nil, "UTF-8 BOM JSON Feed must not fail sniffing (#1133)")
        expectEqual(
            bomResult.articles?.map(\.title), ["Swift 6 Concurrency Everywhere"],
            "UTF-8 BOM JSON Feed parses its items through FeedFetcher (#1133)")
    }

    static func testEscapeXML() async {
        print("  - Testing XML Escaping...")
        let unescaped = "Ben & Jerry's <Ice Cream> \"Taste Test\""
        let expectedEscaped = "Ben &amp; Jerry&apos;s &lt;Ice Cream&gt; &quot;Taste Test&quot;"
        expectEqual(OPMLExporter.escapeXML(unescaped), expectedEscaped, "Strings should be correctly XML escaped")
    }

    static func testOPMLParsingAndExporting() async {
        print("  - Testing OPML Parsing & Exporting...")

        let opmlSample = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
                <head>
                    <title>Subscriptions</title>
                </head>
                <body>
                    <outline text="Top News" title="Top News" type="rss" xmlUrl="https://news.ycombinator.com/rss"/>
                    <outline text="Technology" title="Technology">
                        <outline text="Ars Technica" title="Ars Technica" type="rss" xmlUrl="https://feeds.arstechnica.com/arstechnica/index" htmlUrl="https://arstechnica.com"/>
                        <outline text="The Verge" type="rss" URL="https://www.theverge.com/rss/index.xml"/>
                    </outline>
                </body>
            </opml>
            """.data(using: .utf8)!

        let malformed = Data("<opml><body><outline xmlUrl=\"https://example.com/feed\"/></body>".utf8)
        expectTrue(OPMLParser.parse(data: malformed).isEmpty, "Malformed OPML must not import partial subscriptions")
        let items = OPMLParser.parse(data: opmlSample)
        expectEqual(items.count, 3, "Should parse all 3 feeds from flat and nested outlines")

        expectEqual(items[0].title, "Top News", "Should extract title")
        expectEqual(items[0].url, "https://news.ycombinator.com/rss", "Should extract xmlUrl")
        expectEqual(items[0].folder, nil, "Should have nil folder for root item")

        expectEqual(items[1].title, "Ars Technica", "Should extract title")
        expectEqual(items[1].url, "https://feeds.arstechnica.com/arstechnica/index", "Should extract xmlUrl")
        expectEqual(items[1].folder, "Technology", "Should associate with Technology folder")

        expectEqual(items[2].title, "The Verge", "Should extract title from text attribute")
        expectEqual(items[2].url, "https://www.theverge.com/rss/index.xml", "Should extract URL attribute")
        expectEqual(items[2].folder, "Technology", "Should associate with Technology folder")

        let urlsToExport = [
            "https://feeds.arstechnica.com/arstechnica/index",
            "https://news.ycombinator.com/rss",
        ]
        let exported = OPMLExporter.generateOPML(feedURLs: urlsToExport, title: "Exported Feeds")
        expectTrue(exported.contains("<opml version=\"2.0\">"), "Export should contain opml version 2.0")
        expectTrue(exported.contains("<title>Exported Feeds</title>"), "Export should contain title")
        expectTrue(
            exported.contains("xmlUrl=\"https://feeds.arstechnica.com/arstechnica/index\""),
            "Export should contain feed 1")
        expectTrue(exported.contains("xmlUrl=\"https://news.ycombinator.com/rss\""), "Export should contain feed 2")

        let roundtripData = exported.data(using: .utf8)!
        let roundtripItems = OPMLParser.parse(data: roundtripData)
        expectEqual(roundtripItems.count, 2, "Roundtrip OPML export should parse back into 2 feeds")
        expectEqual(
            roundtripItems[0].url, "https://feeds.arstechnica.com/arstechnica/index", "Roundtrip feed 1 URL match")
        expectEqual(roundtripItems[1].url, "https://news.ycombinator.com/rss", "Roundtrip feed 2 URL match")

        // XXE injection test
        let xxePayload = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE opml [
                <!ENTITY xxe SYSTEM "file:///etc/passwd">
            ]>
            <opml version="2.0">
                <body>
                    <outline text="&xxe;" title="&xxe;" type="rss" xmlUrl="https://example.com/rss"/>
                </body>
            </opml>
            """.data(using: .utf8)!
        expectTrue(OPMLParser.parse(data: xxePayload).isEmpty, "An external file entity rejects the whole file (#928)")

        // OPML attribute order, category parsing, and case-insensitivity
        let advancedOPML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
                <head>
                    <title>Advanced Feeds</title>
                </head>
                <body>
                    <outline Title="Capital Title Feed" xmlUrl="https://example.com/feed1.xml" url="https://example.com/home1"/>
                    <outline Text="Capital Text Feed" type="rss" url="https://example.com/feed2.xml"/>
                    <outline text="Atom Feed" type="atom" url="https://example.com/feed3.xml"/>
                    <outline text="Category With Website" url="https://example.com/category">
                        <outline title="Nested Tech" type="rss" xmlUrl="https://example.com/tech.xml" url="https://example.com/tech"/>
                    </outline>
                    <outline title="" text="Empty Title Folder">
                        <outline title="   " text="Empty Title Feed" xmlUrl="https://example.com/feed4.xml"/>
                    </outline>
                    <outline text="Plain URL Feed" url="https://example.com/plain.xml"/>
                    <outline text="Bookmark" type="link" url="https://example.com/page"/>
                </body>
            </opml>
            """.data(using: .utf8)!

        let advancedItems = OPMLParser.parse(data: advancedOPML)
        expectEqual(advancedItems.count, 6, "Should parse 6 feeds, treating category with web url as folder")
        expectEqual(advancedItems[0].title, "Capital Title Feed", "Case-insensitive Title attribute")
        expectEqual(advancedItems[0].url, "https://example.com/feed1.xml", "Prioritizes xmlUrl over url")
        expectEqual(advancedItems[0].folder, nil, "Root item has nil folder")

        expectEqual(advancedItems[1].title, "Capital Text Feed", "Case-insensitive Text attribute")
        expectEqual(advancedItems[1].url, "https://example.com/feed2.xml", "Accepts url when type is rss")
        expectEqual(advancedItems[1].folder, nil, "Root item has nil folder")

        expectEqual(advancedItems[2].title, "Atom Feed", "Extracts atom feed title")
        expectEqual(advancedItems[2].url, "https://example.com/feed3.xml", "Accepts url when type is atom")

        expectEqual(advancedItems[3].title, "Nested Tech", "Extracts nested feed title")
        expectEqual(advancedItems[3].url, "https://example.com/tech.xml", "Prioritizes xmlUrl in nested feed")
        expectEqual(advancedItems[3].folder, "Category With Website", "Nested inside Category With Website folder")

        expectEqual(advancedItems[4].title, "Empty Title Feed", "Falls back to text when title is whitespace")
        expectEqual(advancedItems[4].url, "https://example.com/feed4.xml", "Extracts feed url")
        expectEqual(advancedItems[4].folder, "Empty Title Folder", "Folder falls back to text when title is empty")

        // An untyped url outline without children was imported before #901 and still is; a typed web link is not.
        expectEqual(advancedItems[5].title, "Plain URL Feed", "Untyped url outline without children stays a feed")
        expectEqual(advancedItems[5].url, "https://example.com/plain.xml", "Its url is the feed url")
        expectEqual(advancedItems[5].folder, nil, "Root url-only feed has nil folder")
    }

    /// #928: OPML import has the feed parser's guards. Hostile files fail with a reason and change nothing; exports
    /// from common readers still import.
    @MainActor
    static func testOPMLHostileInput() async {
        print("  - Testing OPML import guards: entities, nesting, outline count, reader exports (#928)...")
        func rejectionError(_ data: Data) -> NSError? {
            do {
                _ = try OPMLParser.parseValidated(data: data)
                return nil
            } catch {
                return error as NSError
            }
        }
        func rejection(_ data: Data) -> String? {
            rejectionError(data)?.localizedDescription
        }
        let feed = "<outline text=\"Feed\" type=\"rss\" xmlUrl=\"https://example.com/feed.xml\"/>"
        func opml(prolog: String = "", body: String) -> Data {
            let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            return Data("\(declaration)\(prolog)<opml version=\"2.0\"><body>\(body)</body></opml>".utf8)
        }

        // Entity expansion: a billion-laughs prolog is refused before the XML parser sees it, in bounded time.
        var laughs = "<!ENTITY lol0 \"lol\">"
        for level in 1...9 {
            laughs += "<!ENTITY lol\(level) \"" + String(repeating: "&lol\(level - 1);", count: 10) + "\">"
        }
        let bomb = opml(
            prolog: "<!DOCTYPE opml [\(laughs)]>",
            body: "<outline text=\"&lol9;\" type=\"rss\" xmlUrl=\"https://example.com/feed.xml\"/>")
        let start = ProcessInfo.processInfo.systemUptime
        let bombReason = rejection(bomb)
        expectTrue(
            ProcessInfo.processInfo.systemUptime - start < 1, "An entity bomb is rejected without being expanded")
        expectEqual(bombReason, "It declares XML entities, which News does not import.", "Entity bombs name the reason")
        // UTF-16 hides the declaration from an ASCII byte search unless the zero bytes are dropped first.
        let utf16 = String(decoding: bomb, as: UTF8.self).replacingOccurrences(of: "UTF-8", with: "UTF-16")
        let utf16Error = rejectionError(utf16.data(using: .utf16)!)
        expectEqual(utf16Error?.domain, "OPML", "A UTF-16 entity declaration uses the OPML error domain")
        expectEqual(utf16Error?.code, 3, "A UTF-16 entity declaration uses the guard error code")
        expectEqual(
            utf16Error?.localizedDescription,
            "It declares XML entities, which News does not import.",
            "A UTF-16 entity declaration names the entity guard")

        // DTD defaults are copied into every matching outline by Foundation and retained by the import.
        let attributeDefaults = opml(
            prolog: "<!DOCTYPE opml [<!ATTLIST outline title CDATA \"default title\">]>",
            body: feed + feed.replacingOccurrences(of: "Feed", with: "Second feed"))
        let attributeError = rejectionError(attributeDefaults)
        expectEqual(attributeError?.domain, "OPML", "ATTLIST declarations use the OPML error domain")
        expectEqual(attributeError?.code, 3, "ATTLIST declarations use the guard error code")
        expectEqual(
            attributeError?.localizedDescription,
            "It declares XML attribute lists, which News does not import.",
            "ATTLIST declarations are rejected before XMLParser supplies default attributes")
        let utf16AttributeDefaults = String(decoding: attributeDefaults, as: UTF8.self)
            .replacingOccurrences(of: "UTF-8", with: "UTF-16")
        let utf16AttributeError = rejectionError(utf16AttributeDefaults.data(using: .utf16)!)
        expectEqual(
            utf16AttributeError?.localizedDescription,
            "It declares XML attribute lists, which News does not import.",
            "UTF-16 ATTLIST declarations are rejected by the full-input scan")

        // An unused external-entity declaration beyond 64 KiB must be caught by the full-input scan,
        // without relying on XMLParser's declaration callback.
        let padded = opml(
            prolog: "<!--" + String(repeating: " ", count: 70_000)
                + "--><!DOCTYPE opml [<!ENTITY far SYSTEM \"file:///etc/passwd\">]>",
            body: feed)
        expectEqual(
            rejection(padded), "It declares XML entities, which News does not import.",
            "A late unused external entity is rejected before parsing")
        let external = opml(prolog: "<!DOCTYPE opml [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>", body: feed)
        expectTrue(OPMLParser.parse(data: external).isEmpty, "External entities import nothing")
        // An attribute default would give every bare outline a feed address; any DTD declaration is refused.
        let defaulted = opml(
            prolog: "<!DOCTYPE opml [<!ATTLIST outline xmlUrl CDATA \"https://attacker.invalid/feed\">]>",
            body: "<outline text=\"Looks empty\"/>")
        expectEqual(
            rejection(defaulted), "It declares XML attribute lists, which News does not import.",
            "An attribute default in a DTD is refused")
        expectTrue(OPMLParser.parse(data: defaulted).isEmpty, "A defaulted feed address is never imported")
        let declared = opml(prolog: "<!DOCTYPE opml [<!ELEMENT outline ANY>]>", body: feed)
        expectEqual(
            rejection(declared), "It contains document type definitions, which News does not import.",
            "An element declaration is refused")
        expectEqual(
            OPMLParser.parse(data: opml(prolog: "<!DOCTYPE opml>", body: feed)).count, 1,
            "A bare doctype without definitions still imports")

        // Nesting: 64 levels is the bound, as in the feed parser; one more is refused.
        func nested(_ levels: Int) -> Data {
            opml(
                body: String(repeating: "<outline text=\"Folder\">", count: levels) + feed
                    + String(repeating: "</outline>", count: levels))
        }
        // opml and body are two levels, the feed outline one more.
        let deepest = OPMLParser.maximumDepth - 3
        expectEqual(OPMLParser.parse(data: nested(deepest)).count, 1, "Nesting at the bound still imports")
        expectEqual(
            rejection(nested(deepest + 1)), "Its outlines nest more than 64 levels deep.",
            "Nesting past the bound is refused")
        expectEqual(rejection(nested(100_000)), "Its outlines nest more than 64 levels deep.", "Deep nesting bomb")

        // Outline count: the bound is inclusive and counts folders too.
        func outlines(_ count: Int) -> Data {
            opml(
                body: (0..<count).map { "<outline text=\"F\($0)\" type=\"rss\" xmlUrl=\"https://e.com/\($0).xml\"/>" }
                    .joined())
        }
        expectEqual(
            OPMLParser.parse(data: outlines(OPMLParser.maximumOutlines)).count, OPMLParser.maximumOutlines,
            "The outline bound itself imports")
        // The count is written in the reader's locale (20,000 or 20.000).
        expectEqual(
            rejection(outlines(OPMLParser.maximumOutlines + 1)),
            "It lists more than \(OPMLParser.maximumOutlines.formatted()) outlines.",
            "One outline past the bound is refused")

        // Malformed files still fail without a guard reason.
        for broken in ["", "<opml>", "<opml><body><outline></body></opml>", "not xml at all", "\u{FEFF}<<<>>>"] {
            expectTrue(OPMLParser.parse(data: Data(broken.utf8)).isEmpty, "Malformed OPML imports nothing: \(broken)")
        }

        // The reader sees why, and nothing changes.
        let suiteName = testDefaultsSuite("test.opml.guards")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let settings = AppSettings(defaults: defaults)
        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false)
        let feedsBefore = settings.feedURLs
        let sectionsBefore = settings.userSections
        expectEqual(manager.importFeeds(from: nested(deepest + 1)), 0, "A refused file adds no feed")
        expectEqual(
            store.operationError,
            "The OPML file could not be imported. Its outlines nest more than 64 levels deep. "
                + "No subscriptions were changed.", "The alert names the guard")
        store.operationError = nil
        expectEqual(manager.importFeeds(from: bomb), 0, "An entity bomb adds no feed")
        expectTrue(store.operationError?.contains("declares XML entities") == true, "The alert names entities")
        store.operationError = nil
        expectEqual(
            manager.importFeeds(from: Data(repeating: 32, count: OPMLFileReader.maximumBytes + 1)), 0,
            "An oversized file adds no feed")
        expectEqual(
            store.operationError,
            "The OPML file could not be imported. OPML files must be no larger than 5 MB. No subscriptions were changed.",
            "The alert names the size limit")
        store.operationError = nil
        expectEqual(manager.importFeeds(from: Data("<opml><body>".utf8)), 0, "A truncated file adds no feed")
        expectTrue(store.operationError?.contains("incomplete or malformed") == true, "Malformed keeps its message")
        expectEqual(settings.feedURLs, feedsBefore, "Refused files leave subscriptions unchanged")
        expectEqual(settings.userSections, sectionsBefore, "Refused files leave sections unchanged")
        manager.stopBackgroundWork()

        // Exports in the shape common readers write them still import.
        let netNewsWire = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- OPML generated by NetNewsWire -->
            <opml version="1.1">
            	<head>
            		<title>Subscriptions-OnMyMac.opml</title>
            	</head>
            <body>
            	<outline text="Daring Fireball" title="Daring Fireball" description="" type="rss" version="RSS" htmlUrl="https://daringfireball.net/" xmlUrl="https://daringfireball.net/feeds/main"/>
            	<outline text="News" title="News">
            		<outline text="BBC News - World" title="BBC News - World" description="" type="rss" version="RSS" htmlUrl="https://www.bbc.co.uk/news/world" xmlUrl="https://feeds.bbci.co.uk/news/world/rss.xml"/>
            	</outline>
            </body>
            </opml>
            """
        let feedly = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.0">
              <head>
                <title>Reader subscriptions in feedly Cloud</title>
              </head>
              <body>
                <outline text="Tech &amp; Science" title="Tech &amp; Science">
                  <outline type="rss" text="Ars Technica" title="Ars Technica" xmlUrl="https://feeds.arstechnica.com/arstechnica/index" htmlUrl="https://arstechnica.com"/>
                  <outline type="rss" text="Nature" title="Nature" xmlUrl="https://www.nature.com/nature.rss" htmlUrl="https://www.nature.com"/>
                </outline>
              </body>
            </opml>
            """
        let inoreader = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.0">
              <head><title>Subscriptions from Inoreader [https://www.inoreader.com]</title></head>
              <body>
                <outline text="World" title="World">
                  <outline text="Reuters" title="Reuters" type="rss" xmlUrl="https://example.com/reuters/world?format=rss&amp;lang=en" htmlUrl="https://www.reuters.com"/>
                </outline>
                <outline text="The Guardian" title="The Guardian" type="rss" xmlUrl="https://www.theguardian.com/world/rss" htmlUrl="https://www.theguardian.com"/>
              </body>
            </opml>
            """
        for (reader, document, expected) in [
            (
                "NetNewsWire", netNewsWire,
                ["https://daringfireball.net/feeds/main", "https://feeds.bbci.co.uk/news/world/rss.xml"]
            ),
            (
                "Feedly", feedly,
                ["https://feeds.arstechnica.com/arstechnica/index", "https://www.nature.com/nature.rss"]
            ),
            (
                "Inoreader", inoreader,
                ["https://example.com/reuters/world?format=rss&lang=en", "https://www.theguardian.com/world/rss"]
            ),
        ] {
            expectTrue(rejection(Data(document.utf8)) == nil, "\(reader) export passes the guards")
            expectEqual(OPMLParser.parse(data: Data(document.utf8)).map(\.url), expected, "\(reader) export imports")
        }
        expectEqual(
            OPMLParser.parse(data: Data(feedly.utf8)).first?.folder, "Tech & Science", "Escaped folder names import")
        expectEqual(
            OPMLParser.parse(data: Data(OPMLExporter.generateOPML(feedURLs: ["https://example.com/a.xml"]).utf8)).count,
            1, "News's own export passes the guards")
    }

    /// The pair model's newsletter strip (#737): series suffix, sign-up line and teaser go; everything else stays.
    static func testNewsletterStrip() {
        let edition = EventMatcher.newsletterStripped(
            title: "Stevens defects to back El-Sayed’s opponent | First Thing",
            description: "Trump called the candidate a ‘jihadist’. Plus an Australian fish worth its weight in gold\n\n"
                + "Don’t already get First Thing in your inbox? Sign up here\n\nGood morning. Stevens endorsed Rogers.")
        expectEqual(edition.title, "Stevens defects to back El-Sayed’s opponent", "Series suffix is dropped")
        expectEqual(
            edition.description, "Trump called the candidate a ‘jihadist’.\nGood morning. Stevens endorsed Rogers.",
            "Sign-up line and teaser are dropped")
        let reported = EventMatcher.newsletterStripped(
            title: "Hackers strike | First Thing",
            description: "A newsletter leaked 40,000 records, police said.\nSign up to First Thing\nSubscribe here")
        expectEqual(
            reported.description, "A newsletter leaked 40,000 records, police said.",
            "A paragraph that reports on a newsletter stays; only the calls to action go")
        let inbox = EventMatcher.newsletterStripped(
            title: "Hackers strike | First Thing",
            description: "Leaked files were found in your inbox, police said.\nGet First Thing in your inbox\n"
                + "Don’t already get First Thing in your inbox?")
        expectEqual(
            inbox.description, "Leaked files were found in your inbox, police said.",
            "A paragraph that reports an inbox event stays; only the inbox calls to action go")
        var stripPolicy = EventMatchPolicy.standard
        stripPolicy.pairModelStripsNewsletter = true
        expectEqual(
            EventMatcher.pairModelText(
                title: "Hackers strike | First Thing", description: "Sign up here", gap: nil, samePublisher: nil,
                policy: stripPolicy),
            EventFeatures.matchingText(title: "Hackers strike", description: ""),
            "The pair model's text follows the policy's strip")
        let column = EventMatcher.newsletterStripped(
            title: "Why growth is a lie | Radical Thinking with Aditya Chakrabortty", description: "A column.")
        expectEqual(column.title, "Why growth is a lie", "A column's author suffix is dropped too")
        expectEqual(column.description, "A column.", "A plain body is unchanged")
        let plain = EventMatcher.newsletterStripped(
            title: "Binance CEO says 90 percent of stolen assets have been replenished", description: "Sign up here")
        expectEqual(plain.title, "Binance CEO says 90 percent of stolen assets have been replenished", "No suffix")
        expectEqual(plain.description, "Sign up here", "Without a suffix the body is left alone")
        let scored = EventMatcher.newsletterStripped(title: "Lakers beat Celtics | 102-99", description: "")
        expectEqual(scored.title, "Lakers beat Celtics | 102-99", "A suffix with digits is not a series")
        expectTrue(EventMatcher.isNewsletterEdition(title: "Stevens defects | First Thing"), "A suffix is an edition")
        expectFalse(EventMatcher.isNewsletterEdition(title: "Lakers beat Celtics | 102-99"), "Digits are no series")
        expectFalse(EventMatcher.isNewsletterEdition(title: "Binance CEO replenishes assets"), "No suffix, no edition")
    }

    /// One publisher, one headline, two GUIDs and two URLs within hours: one story (#583). A recurring headline a day
    /// apart, another publisher, or a short headline stays separate.
    static func testPublisherTitleAliases() async throws {
        print("  - Testing same-publisher duplicate items aliased by headline (#583)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func item(
            _ guid: String, _ path: String, _ title: String, source: String = "CNA", host: String = "news.invalid",
            hours: Double
        ) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://\(host)/\(path)", guid: guid, description: "Lead \(guid).",
                pubDate: start.addingTimeInterval(hours * 3600), source: source)
        }
        let headline = "OpenAI says its AI agents disabled their own safety monitors"
        let first = item("g1", "world/openai-agents", headline, hours: 0)
        let second = item("g2", "world/openai-says-agents", headline, hours: 0.5)
        try await db.upsertArticles([first])
        try await db.upsertArticles([second])
        let firstID = try await db.resolvedArticleID(for: first)
        expectEqual(try await db.resolvedArticleID(for: second), firstID, "The second item aliases to the stored story")
        expectEqual(try await db.counts().total, 1, "One story is stored")
        let later = item("g3", "world/openai-later", headline, hours: 20)
        try await db.upsertArticles([later])
        expectTrue(
            try await db.resolvedArticleID(for: later) != firstID, "The same headline 20 hours later is another item")
        let elsewhere = item("g4", "world/elsewhere", headline, source: "Reuters", hours: 0.2)
        try await db.upsertArticles([elsewhere])
        expectTrue(
            try await db.resolvedArticleID(for: elsewhere) != firstID,
            "Another publisher's identical headline stays apart")
        let shortOne = item("g5", "opinion/talking-taxes", "Talking taxes", hours: 0)
        let shortTwo = item("g6", "opinion/talking-taxes-2", "Talking taxes", hours: 0.1)
        try await db.upsertArticles([shortOne, shortTwo])
        expectTrue(
            try await db.resolvedArticleID(for: shortOne) != (try await db.resolvedArticleID(for: shortTwo)),
            "A headline under four words never keys an alias")
        expectEqual(
            ArticleIdentity.publisherTitleKey(
                title: "Cartoon by Amjad Rasmi. (Courtesy of Asharq Al-Awsat)", source: "Arab News"),
            "publisher-title-v1|arab news|cartoon by amjad rasmi courtesy of asharq al awsat",
            "The key folds case, punctuation and diacritics")
        // Once two GUIDs point at one story, either GUID resolves to it on the next refresh.
        expectEqual(try await db.resolvedArticleID(for: second), firstID, "The duplicate's GUID keeps resolving")
        let hostPairs = [
            ("example.com", "www.example.com", true),
            ("www.example.com", "example.com", true),
            ("WWW.EXAMPLE.COM.", "example.com", true),
            ("example.com", "other.example.com", false),
            ("example.com", "another.example", false),
            ("ft.com", "news.ft.com", true),
        ]
        for (index, pair) in hostPairs.enumerated() {
            let source = "World news \(index)"
            let original = item(
                "host-\(index)-1", "original-\(index)", headline, source: source, host: pair.0, hours: 0)
            let duplicate = item(
                "host-\(index)-2", "duplicate-\(index)", headline, source: source, host: pair.1, hours: 0.5)
            try await db.upsertArticles([original])
            let originalID = try await db.resolvedArticleID(for: original)
            expectEqual(
                try await db.resolvedArticleID(for: duplicate) == originalID, pair.2,
                "Publisher headline matching from \(pair.0) to \(pair.1) respects host normalization and catalog names")
        }
        await db.close()
    }

    static func testArticleIdentityDeep() async {
        print("  - Testing Article Identity & Fingerprinting...")

        // Priority 1: GUID priority
        let id1 = ArticleIdentity.computeId(
            guid: "guid-12345", link: "https://example.com/story?utm_source=rss", title: "Test", source: "Source")
        expectEqual(id1, "guid-12345", "Should prioritize explicit non-URL GUID")

        // Priority 1 with URL GUID: canonicalization
        let id2 = ArticleIdentity.computeId(
            guid: "http://EXAMPLE.com/guid-story/?utm_medium=feed", link: "https://other.com", title: "Test",
            source: "Source")
        expectEqual(id2, "https://example.com/guid-story", "Should canonicalize URL GUID")

        // Priority 2: Canonical URL when GUID is nil or empty
        let id3 = ArticleIdentity.computeId(
            guid: "  ", link: "http://example.com/article/?ref=share", title: "Test", source: "Source")
        expectEqual(id3, "https://example.com/article", "Should prioritize canonicalized URL when GUID is whitespace")

        // Priority 3: Fallback content fingerprint when both GUID and Link are missing/invalid
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id4 = ArticleIdentity.computeId(
            guid: nil, link: "", title: "Breaking News", source: "Reuters", pubDate: date)
        expectTrue(id4.hasPrefix("fp_"), "Fallback ID should be a content fingerprint prefixed with fp_")

        let id5 = ArticleIdentity.computeId(
            guid: nil, link: "", title: "breaking news ", source: " reuters", pubDate: date)
        expectEqual(id4, id5, "Content fingerprints should be case- and whitespace-insensitive")

        // Legacy reconciliation
        let reconciled = ArticleIdentity.reconcileLegacyId("http://test.com/path/?utm_source=newsletter")
        expectEqual(reconciled, "https://test.com/path", "Should reconcile legacy URL")
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
        expectTrue(inserted.isEmpty, "A changed GUID for the same canonical document is not a new article")
        let rows = try await db.fetchArticles(limit: nil)
        expectEqual(rows.count, 1, "Canonical aliases produce one stored article")
        expectEqual(rows.first?.id, first.id, "Stored primary key remains the UI identity after GUID changes")
        expectEqual(rows.first?.title, update.title, "Alias refresh updates publisher metadata")
        expectTrue(try await db.isRead(articleId: first.id), "Alias refresh preserves read history")
        expectTrue(try await db.isSaved(articleId: first.id), "Alias refresh preserves saved state")
        expectEqual(try await db.searchArticles(query: "Updated").first?.id, first.id, "FTS returns the durable ID")
        try await db.markRead(articleId: first.id, isRead: false)
        try await db.markAllRead(feedUrl: "secondary-feed")
        expectTrue(try await db.isRead(articleId: first.id), "Both feeds remain associated with the document")
        await store.setSaved(article: update, isSaved: false)
        expectFalse(try await db.isSaved(articleId: first.id), "Saving an incoming alias resolves the durable ID")
        expectTrue(store.operationError == nil, "Alias save must not fail a foreign-key check")
        let homepageEntries = (0..<2).map { index in
            FeedArticle(
                title: "Homepage-linked item \(index)", link: fixtureRoot.absoluteString,
                guid: "homepage-\(index)", description: "Different reports", pubDate: Date(), source: first.source)
        }
        expectEqual(
            try await db.upsertArticles(homepageEntries).count, 2,
            "Generic homepage links do not merge distinct entries")
        let missingLinks = (0..<2).map { index in
            FeedArticle(
                title: "Missing-link item \(index)", link: "", guid: "missing-link-\(index)",
                description: "Different reports", pubDate: Date(), source: first.source)
        }
        expectEqual(try await db.upsertArticles(missingLinks).count, 2, "Missing links do not identify a document")
        let referenceURL = first.link + "?reference=edition-two"
        expectEqual(
            ArticleIdentity.canonicalizeURL(referenceURL), referenceURL,
            "Meaningful query keys must not be stripped by a broad ref prefix")
        let otherEdition = FeedArticle(
            title: update.title, link: referenceURL, guid: "different-edition",
            description: update.description, pubDate: update.pubDate, source: first.source)
        expectEqual(
            try await db.upsertArticles([otherEdition]), Set([otherEdition.id]),
            "Meaningful query differences retain distinct documents")
        let sameHeadline = FeedArticle(
            title: update.title, link: first.link + "-different", guid: "different-event",
            description: update.description, pubDate: update.pubDate, source: first.source)
        expectEqual(
            try await db.upsertArticles([sameHeadline]), Set([sameHeadline.id]),
            "Matching text alone cannot merge different documents")
        let encoded = try JSONEncoder().encode(rows[0])
        expectEqual(
            try JSONDecoder().decode(FeedArticle.self, from: encoded).id, first.id,
            "Cached articles retain the stored identity")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "storedID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        expectEqual(
            try JSONDecoder().decode(FeedArticle.self, from: legacyData).id, update.id,
            "Legacy JSON remains decodable without a stored ID")
        await db.close()
    }

    @MainActor
    static func testValidatedDocumentIdentity(fixtureRoot: URL) async throws {
        print("  - Testing protected canonical and redirect identity evidence...")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let pipeline = ContentExtractionPipeline(client: NewsTests.mockHTTPClient(configuration: configuration))
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
        expectTrue(extraction.outcome.isSuccess, "Validated redirect remains readable")
        guard let evidence = extraction.evidence else {
            expectTrue(false, "Successful fetch produces identity evidence")
            return
        }
        expectEqual(
            Set(evidence.urls), Set([final.absoluteString, canonical.absoluteString]),
            "Fetched redirect and equivalent canonical are evidence")
        expectEqual(requests, [requested, canonical], "Exactly one canonical verification probe is made")
        guard case .success(let content, _, let document) = extraction.outcome else { return }
        expectEqual(
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
        expectTrue(
            try await db.upsertArticles([variant], feedUrl: original.identityFeedURL).isEmpty,
            "Verified canonical variant reuses stored identity")
        expectEqual(
            try await db.fetchArticles(options: ArticleFetchOptions(canonicalURL: final.absoluteString)).first?.id,
            original.id,
            "Verified redirect resolves through aliases")
        expectTrue(try await db.isRead(articleId: original.id), "Canonical evidence preserves read state")
        expectTrue(try await db.isSaved(articleId: original.id), "Canonical evidence preserves saved state")
        let unrelated = FeedArticle(
            title: "Unrelated", link: fixtureRoot.appendingPathComponent("unrelated").absoluteString, guid: "unrelated",
            description: "Different article", pubDate: Date(), source: "Publisher")
        try await db.upsertArticles([unrelated])
        do {
            try await db.recordDocumentIdentity(evidence, articleID: unrelated.id)
            expectTrue(false, "Evidence cannot be attached to another article")
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
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated alias failure fixture")
        expectEqual(
            sqlite3_exec(
                handle,
                "CREATE TRIGGER fail_document BEFORE INSERT ON article_aliases WHEN new.kind='url' AND new.value LIKE '%/articles/story' BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
                nil, nil, nil), SQLITE_OK, "Inject second evidence alias failure")
        do {
            try await persistent.recordDocumentIdentity(evidence, articleID: original.id)
            expectTrue(false, "Alias write failure must propagate")
        } catch {}
        expectEqual(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: canonical.absoluteString))
                .first?.id, variant.id,
            "Failed evidence rolls back earlier alias conflict")
        expectEqual(
            sqlite3_exec(handle, "DROP TRIGGER fail_document;", nil, nil, nil), SQLITE_OK,
            "Remove alias failure fixture")
        sqlite3_close(handle)
        try await persistent.recordDocumentIdentity(evidence, articleID: original.id)
        expectEqual(
            try await persistent.fetchArticles(limit: nil).count, 2,
            "Evidence does not merge conflicting historical rows")
        expectTrue(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: canonical.absoluteString))
                .isEmpty,
            "Conflicting validated canonical becomes ambiguous")
        await persistent.close()
        try await persistent.open()
        expectEqual(
            try await persistent.fetchArticles(options: ArticleFetchOptions(canonicalURL: final.absoluteString)).first?
                .id, original.id,
            "Validated redirect alias survives reopening")
        expectTrue(
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
            expectTrue(rejected.outcome.isSuccess, "Untrusted canonical does not discard readable content")
            expectEqual(rejected.evidence?.urls, [final.absoluteString], "Arbitrary canonical is not identity evidence")
            expectEqual(requests, [requested], "Unsafe or cross-origin canonical never triggers a fetch")
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
            expectTrue(rejected.outcome.isSuccess, "Optional failed canonical proof retains the source article")
            expectEqual(
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
        expectFalse(blocked.outcome.isSuccess, "Final response destination still requires protected validation")
        expectTrue(blocked.evidence == nil, "Blocked final destination yields no identity evidence")
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: URL(string: requested.absoluteString.replacingOccurrences(of: "https://", with: "http://"))!,
                    statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html().utf8)
            )
        }
        let downgrade = await pipeline.extractArticleWithIdentity(from: requested.absoluteString, allowHTTP: true)
        expectFalse(
            downgrade.outcome.isSuccess,
            "HTTPS extraction rejects an HTTP final destination even when initial HTTP is allowed")
        expectTrue(downgrade.evidence == nil, "Downgrade creates no aliases")
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: final, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html().utf8))
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await pipeline.extractArticleWithIdentity(from: requested.absoluteString)
        }
        expectTrue(await cancelled.value.evidence == nil, "Cancelled extraction returns no identity evidence")

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
            expectTrue(upgraded.outcome.isSuccess, "HTTP feed links remain readable under either transport setting")
            expectEqual(
                requests.map(\.absoluteString), [allowHTTP ? insecure : requested.absoluteString],
                "Extraction upgrades HTTP unless the user explicitly allows it")
        }
        requests.removeAll()
        let malformed = await pipeline.extractArticleWithIdentity(from: "http://[malformed")
        expectFalse(malformed.outcome.isSuccess, "Malformed article links fail before fetching")
        expectTrue(requests.isEmpty, "Malformed links never reach the network")
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
        expectTrue(
            try await db.upsertArticles([duplicate]).isEmpty, "Exact normalized publisher text reuses the document")
        expectEqual(try await db.resolvedArticleID(for: duplicate), first.id, "Text matching preserves the original ID")
        expectTrue(try await db.isRead(articleId: duplicate.id), "Variant retains read state through its ID alias")
        expectTrue(try await db.isSaved(articleId: duplicate.id), "Variant retains bookmark state")
        for article in [
            incoming("reprint", host: "other-publisher.example"),
            incoming("changed", description: text + " New information."),
            incoming("later", date: Date(timeIntervalSince1970: 200)),
            incoming("other-title", title: "Another report"),
        ] {
            expectEqual(
                try await db.upsertArticles([article]), Set([article.id]),
                "Different publisher, text or metadata stays separate")
        }
        let shortA = incoming("short-a", description: "Read more on our website.")
        let shortB = incoming("short-b", description: shortA.description)
        try await db.upsertArticles([shortA])
        expectEqual(try await db.upsertArticles([shortB]), Set([shortB.id]), "Shared short teasers do not merge")
        let unknown = incoming("undated", date: DateParser.unknownDate)
        expectTrue(
            ArticleIdentity.publisherTextFingerprints(unknown).isEmpty, "Undated documents require stronger evidence")
        expectTrue(
            ArticleIdentity.publisherTextFingerprints(
                incoming("large", description: String(repeating: text, count: 100))
            ).isEmpty, "Oversized text is skipped rather than truncated")
        var generated = incoming("generated", description: "Short teaser")
        generated.aiSummary = text
        expectTrue(
            ArticleIdentity.publisherTextFingerprints(generated).isEmpty,
            "Generated summaries never identify publisher documents")
        let bodyA = incoming("body-a", body: text, description: "First teaser")
        let bodyB = incoming("body-b", body: text, description: "Second teaser")
        try await db.upsertArticles([bodyA])
        expectTrue(try await db.upsertArticles([bodyB]).isEmpty, "Exact full body can match different descriptions")

        let extracted = incoming("extracted", description: "No full body in RSS")
        try await db.upsertArticles([extracted])
        try await db.updateEnrichment(
            articleId: extracted.id,
            update: DatabaseEngine.EnrichmentUpdate(content: text + " Extracted details."))
        let extractedVariant = incoming(
            "extracted-variant", body: text + " Extracted details.", description: "Different teaser")
        expectTrue(
            try await db.upsertArticles([extractedVariant]).isEmpty,
            "On-demand publisher extraction contributes body evidence")

        // A known GUID owns a separate row before it acquires identical publisher text.
        let distinct = incoming("distinct", description: text + " Original distinction.")
        try await db.upsertArticles([distinct])
        let corrected = incoming("distinct")
        expectTrue(try await db.upsertArticles([corrected]).isEmpty, "Known GUID takes precedence over text")
        expectEqual(
            try await db.resolvedArticleID(for: corrected), distinct.id,
            "Authoritative identity is not overwritten by text")
        let uncertain = incoming("uncertain")
        expectEqual(
            try await db.upsertArticles([uncertain]), Set([uncertain.id]),
            "Ambiguous text never selects one of its owners")
        await db.close()
        try await db.open()
        expectEqual(try await db.resolvedArticleID(for: duplicate), first.id, "Observed variant survives reopening")
        let stillUncertain = incoming("still-uncertain")
        expectEqual(
            try await db.upsertArticles([stillUncertain]), Set([stillUncertain.id]), "Ambiguity remains after reopening"
        )
        let mixed = incoming("mixed-evidence", body: text)
        expectEqual(
            try await db.upsertArticles([mixed]), Set([mixed.id]),
            "Ambiguous description blocks automatic matching even with a unique body candidate")
        expectTrue(try await db.isSaved(articleId: first.id), "Migration and reopening retain bookmark state")
        // Fingerprint failure must roll back extracted text and enrichment together.
        var failureHandle: OpaquePointer?
        expectEqual(sqlite3_open(path, &failureHandle), SQLITE_OK, "Open isolated failure injector")
        expectEqual(
            sqlite3_exec(
                failureHandle,
                "CREATE TRIGGER reject_text BEFORE INSERT ON article_aliases WHEN new.kind = 'content' BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
                nil, nil, nil), SQLITE_OK, "Inject content alias failure")
        do {
            try await db.updateEnrichment(
                articleId: extracted.id,
                update: DatabaseEngine.EnrichmentUpdate(summary: "Should roll back", content: text + " Failed update."))
            expectTrue(false, "Alias failure must propagate")
        } catch {}
        let rolledBack = try await db.fetchArticles(id: extracted.id).first
        expectEqual(
            rolledBack?.fullContent, text + " Extracted details.", "Failed alias preserves prior publisher text")
        expectTrue(rolledBack?.aiSummary == nil, "Failed alias preserves prior enrichment")
        expectEqual(
            sqlite3_exec(failureHandle, "DROP TRIGGER reject_text;", nil, nil, nil), SQLITE_OK,
            "Remove failure injector")
        sqlite3_close(failureHandle)
        await db.close()

        // Exercise v6 -> v7 with existing aliases and a cancellation rollback.
        var handle: OpaquePointer?
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated migration fixture")
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
        expectEqual(sqlite3_exec(handle, downgrade, nil, nil, nil), SQLITE_OK, "Reconstruct v6 aliases")
        sqlite3_close(handle)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await db.open()
        }
        do {
            try await cancelled.value
            expectTrue(false, "Cancelled fingerprint schema migration throws")
        } catch is CancellationError {}
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Read cancelled migration")
        var statement: OpaquePointer?
        expectEqual(
            sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK, "Read schema version")
        expectEqual(sqlite3_step(statement), SQLITE_ROW, "Schema version exists")
        expectEqual(sqlite3_column_int(statement, 0), 6, "Cancelled migration retains v6")
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        try await db.open()
        expectEqual(try await db.resolvedArticleID(for: duplicate), first.id, "v7 retains existing aliases")
        expectTrue(try await db.isRead(articleId: first.id), "v7 retains reading state")
        let historicalVariant = incoming(
            "historical-new-guid", body: text + " Extracted details.", description: "Fresh teaser")
        expectTrue(
            try await db.upsertArticles([historicalVariant]).isEmpty,
            "Migration indexes existing publisher body evidence")
        expectEqual(
            try await db.resolvedArticleID(for: historicalVariant), extracted.id,
            "Historical body resolves without rewriting the primary key")
        let historicalAmbiguity = incoming("historical-ambiguous")
        expectEqual(
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
        expectEqual(manager.articles.count, 1, "Refresh displays exact content variants once")
        expectEqual(notifications, [first.id], "Refresh notifies only the committed document")
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        expectEqual(notifications, [first.id], "Repeated content variants never notify again")
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
        expectTrue(first.id != second.id, "The same raw GUID from different feeds has different identity")
        expectTrue(
            ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0] + "?utm_source=rss") != first.id,
            "Article tracking rules must not collapse configured feed URLs")
        expectTrue(
            ArticleIdentity.scopedGUID(
                "shared-guid", feedURL: feeds[0].replacingOccurrences(of: "https://", with: "http://")) != first.id,
            "Explicit HTTP and HTTPS subscriptions retain separate namespaces")
        expectTrue(
            ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0] + "?edition=2") != first.id,
            "Document-selecting feed parameters retain separate namespaces")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        expectEqual(
            try await db.upsertArticles([first], feedUrl: feeds[0]), Set([first.id]),
            "First feed inserts its scoped identity")
        try await db.markRead(articleId: first.id, isRead: true)
        try await db.setSaved(articleId: first.id, isSaved: true)
        expectEqual(
            try await db.upsertArticles([second], feedUrl: feeds[1]), Set([second.id]),
            "Other publisher's reused GUID inserts a distinct document")
        expectEqual(
            try await db.fetchArticles(limit: nil).count, 2, "GUID collision does not overwrite either publisher")
        expectFalse(try await db.isRead(articleId: second.id), "The other publisher does not inherit reading state")
        expectFalse(try await db.isSaved(articleId: second.id), "The other publisher does not inherit a bookmark")
        let moved = incoming(feeds[1], fixtureRoot.appendingPathComponent("publisher-b/moved").absoluteString)
        expectTrue(
            try await db.upsertArticles([moved], feedUrl: feeds[1]).isEmpty, "Same-feed GUID resolves a changed URL")
        expectEqual(
            try await db.fetchArticles(id: second.id).first?.link, moved.link,
            "URL correction updates only its own publisher")
        expectEqual(
            try await db.fetchArticles(id: first.id).first?.link, first.link, "The other publisher's URL stays intact")
        let sharedDocument = incoming(feeds[1], first.link, guid: "same-document-other-feed")
        expectTrue(
            try await db.upsertArticles([sharedDocument], feedUrl: feeds[1]).isEmpty,
            "Exact document URL can still connect different feeds")
        expectEqual(
            try await db.resolvedArticleID(for: sharedDocument), first.id,
            "Scoped alias points to the original shared document")
        let missingA = incoming(feeds[0], "", guid: "missing-link-guid")
        let missingB = incoming(feeds[1], "", guid: "missing-link-guid")
        expectEqual(
            try await db.upsertArticles([missingA], feedUrl: feeds[0]), Set([missingA.id]),
            "Missing URL remains identifiable within its feed")
        expectEqual(
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
        expectEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated v5 fixture")
        expectEqual(
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
            expectTrue(false, "Cancelled scoped GUID migration must be reported")
        } catch is CancellationError {
            expectEqual(sqlite3_open(copy, &handle), SQLITE_OK, "Inspect cancelled v6 migration")
            var statement: OpaquePointer?
            expectEqual(
                sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK,
                "Read cancelled migration version")
            expectEqual(sqlite3_step(statement), SQLITE_ROW, "Read old schema version")
            expectEqual(sqlite3_column_int(statement, 0), 5, "Scoped GUID migration rolls back its version")
            sqlite3_finalize(statement)
            expectEqual(
                sqlite3_prepare_v2(
                    handle, "SELECT count(*) FROM article_aliases WHERE value LIKE 'feed-guid:%';", -1, &statement, nil),
                SQLITE_OK, "Read cancelled migration aliases")
            expectEqual(sqlite3_step(statement), SQLITE_ROW, "Read scoped alias count")
            expectEqual(sqlite3_column_int(statement, 0), 0, "Cancelled migration commits no scoped aliases")
            sqlite3_finalize(statement)
            sqlite3_close(handle)
        }
        try await migrated.open()
        let legacyMoved = incoming(
            feeds[0], fixtureRoot.appendingPathComponent("legacy/moved").absoluteString, guid: "legacy-guid")
        expectTrue(
            try await migrated.upsertArticles([legacyMoved], feedUrl: feeds[0]).isEmpty,
            "Migration maps scoped GUID to the existing primary key even after URL correction")
        expectEqual(
            try await migrated.fetchArticles(id: legacy.id).first?.id, legacy.id, "Legacy primary key is preserved")
        let unknownMulti = incoming(
            feeds[1], fixtureRoot.appendingPathComponent("legacy/multi-moved").absoluteString, guid: "multi-guid")
        expectEqual(
            try await migrated.resolvedArticleID(for: unknownMulti), unknownMulti.id,
            "Migration does not guess GUID ownership for multi-feed history")
        expectEqual(
            try await migrated.fetchArticles(id: multi.id).first?.id, multi.id,
            "Uncertain multi-feed article retains its old ID")
        let unknownOwner = incoming(
            feeds[0], fixtureRoot.appendingPathComponent("legacy/unattributed-moved").absoluteString,
            guid: "unattributed-guid")
        expectEqual(
            try await migrated.resolvedArticleID(for: unknownOwner), unknownOwner.id,
            "Migration does not attribute a later unscoped GUID variant to the original feed")
        expectTrue(try await migrated.isRead(articleId: legacyMoved.id), "Scoped lookup preserves legacy read state")
        expectTrue(try await migrated.isSaved(articleId: legacyMoved.id), "Scoped lookup preserves legacy saved state")
        let legacyCollision = incoming(feeds[1], second.link, guid: "legacy-guid")
        expectEqual(
            try await migrated.upsertArticles([legacyCollision], feedUrl: feeds[1]), Set([legacyCollision.id]),
            "Legacy GUID ownership does not extend to another feed")
        expectEqual(
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
        expectEqual(
            Set(notified), Set([first.id, second.id]), "Both colliding publishers notify with committed, distinct IDs")
        expectEqual(notified.count, 2, "Duplicate RSS rows and overlapping feeds notify once per stored document")
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        expectEqual(notified.count, 2, "Repeated refresh does not re-notify either publisher")
        expectEqual(
            Set(manager.articles.map { $0.id }), Set([first.id, second.id]),
            "Visible identities agree with notification IDs")
        manager.stopBackgroundWork()
        await store.database.close()
    }

}
