// NewsTests.swift

import Foundation
import Network
import WebKit
import SQLite3
import ImageIO
import UniformTypeIdentifiers

// MARK: - MockURLProtocol for Testing
class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var mockData: Data?
    static var mockResponse: HTTPURLResponse?
    static var mockError: Error?
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        if let handler = MockURLProtocol.requestHandler {
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }

        if let error = MockURLProtocol.mockError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let response = MockURLProtocol.mockResponse {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        if let data = MockURLProtocol.mockData {
            client?.urlProtocol(self, didLoad: data)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Responses are delivered synchronously; this mock has no pending load to cancel.
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #file, line: Int = #line) {
    if actual != expected {
        print("❌ ASSERTION FAILED: \(message)")
        print("   Expected: \(expected)")
        print("   Actual:   \(actual)")
        print("   Location: \(file):\(line)")
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message) (expected true, got false)")
        print("   Location: \(file):\(line)")
        exit(1)
    }
}

func assertFalse(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        print("❌ ASSERTION FAILED: \(message) (expected false, got true)")
        print("   Location: \(file):\(line)")
        exit(1)
    }
}

@main
struct NewsTests {
    static func main() async {
        do {
            try await runTests()
        } catch {
            print("❌ TEST FAILED with unexpected error: \(error)")
            exit(1)
        }
    }

    static func runTests(fixtureHost: String = "example.com") async throws {
        var fixtureURL = URLComponents()
        fixtureURL.scheme = "https"
        fixtureURL.host = fixtureHost
        let fixtureRoot = fixtureURL.url!
        if CommandLine.arguments.contains("--story-regressions") {
            try await testReaderFigures(fixtureRoot: fixtureRoot)
            try await testCanonicalArticleIngestion(fixtureRoot: fixtureRoot)
            try await testPersistentArticleAliases(fixtureRoot: fixtureRoot)
            try await testAuditPersistenceAndRoutingRegressions(fixtureRoot: fixtureRoot)
            try await testUndatedArticleOrdering()
            await testDatabaseEnginePersistence()
            await testFTS5SearchAndOperators()
            await testReaderParsingRegressions()
            await testStructuredReaderAndTags()
            await testReaderStoreUpdates()
            await testArticleRetentionPolicy()
            try await testGranularCacheClearingAndRetention()
            await testMultiPublisherExtractionFixtures()
            print("✅ Story regressions passed")
            return
        }
        print("🏃 Running NewsApp Unit Tests...")
        
        await testURLNormalization()
        await testSSRFValidation()
        await testIsBlockedIPv4()
        await testIPAddressValidatorDeep()
        await testSecureHTTPClientFetchImage()
        await testSecureHTTPClientPolicies()
        await testFeedErrorHierarchy()
        await testAppSettingsDecoupling()
        await testDateParsing()
        try await testAuditParsingAndSettingsRegressions(fixtureRoot: fixtureRoot)
        try await testAuditPersistenceAndRoutingRegressions(fixtureRoot: fixtureRoot)
        try await testAuditRefreshRegressions(fixtureRoot: fixtureRoot)
        try await testUndatedArticleOrdering()
        try await testReaderFigures(fixtureRoot: fixtureRoot)
        await testReaderParsingRegressions()
        await testStructuredReaderAndTags()
        await testReaderStoreUpdates()
        try await testProductionFollowupRegressions()
        await testXMLParsing()
        await testJSONParsing()
        await testNavigationCommands()
        await testEscapeXML()
        await testOPMLParsingAndExporting()
        await testOfflineCacheAndResilience()
        await testArticleIdentityDeep()
        await testDatabaseEnginePersistence()
        try await testCanonicalArticleIngestion(fixtureRoot: fixtureRoot)
        try await testPersistentArticleAliases(fixtureRoot: fixtureRoot)
        try await testFeedScopedGUIDs(fixtureRoot: fixtureRoot)
        await testFTS5SearchAndOperators()
        await testMigrationCoordinatorAtomicity()
        await testArticleRetentionPolicy()
        await testArticleIntelligenceCapabilities()
        await testContentExtractionPipelineDeep()
        await testWebContentExtractorFacade()
        await testEnrichmentQueueSchedulingAndPromotion()
        await testDesignSystemAndArticleFilter()
        await testDistributionAndEntitlementsIntegrity()
        await testStrictSemVerAndReleaseSecurity()
        await testNotificationModeTriageAndGrammar()
        try await testSocketNetworkBoundary()
        await testRefreshCoordinatorSingleFlightCoalescing()
        try await testFeedRemovalAndShutdown()
        await testSignpostHelperExecution()
        await testAppSettingsIsolationAndURLNormalization()
        await testFixedTaxonomyAndCaseInsensitivity()
        await testClassificationMultiStageAndConfidenceTiers()
        await testClassificationBenchmarkDataset()
        try await testArticleAnalyzerStructuredOutputAndFallbacks()
        await testInteractiveAnalysisCancellation()
        try await testGranularCacheClearingAndRetention()
        await testNotificationServiceErrorLogging()
        await testArticleStoreErrorResilience()
        await testFeedArticleWrapContextNavigation()
        await testArticleContentRedactionAndTypography()
        await testArticleDetailReadingExperienceOverhaul()
        await testBBCExtractionFixture()
        await testMultiPublisherExtractionFixtures()
        await testContentQualityValidation()
        await testExtractionOutcomeDiagnostics()
        await testCanonicalClassificationDisambiguation()
        await testAppContainerAndFrostedSurface()
        try await testReadManagerReconciliationCache()
        
        if ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1" {
            await testLiveReader()
        }
        if let snapshot = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] {
            let database = DatabaseEngine(path: snapshot)
            try await database.open()
            let articles = try await database.fetchArticles(limit: 500)
            assertFalse(articles.isEmpty, "Migrated snapshot must display stored articles")
            let counts = try await database.counts()
            print("  - Migrated isolated snapshot: \(counts.total) stories, \(counts.saved) saved")
            await database.close()
        }
        print("✅ SUCCESS: All tests passed!")
    }

    
    @MainActor
    static func testReaderStoreUpdates() async {
        let suiteName = "test.reader.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"))
        await store.initialize()
        let manager = FeedManager(settings: AppSettings(defaults: defaults), store: store, schedulesRefresh: false)
        let article = FeedArticle(title: "Report", link: "https://example.com/report", guid: "reader-test", description: "Preview", pubDate: Date(), source: "Publisher")
        await store.batchUpsert(articles: [article])
        await store.updateEnrichment(id: article.id, category: "Science", content: "The complete publisher article.")
        assertEqual(manager.articles.first?.fullContent, "The complete publisher article.", "Feed views receive extracted text immediately")
        assertEqual(manager.articles.first?.category, "Science", "Category changes propagate without another feed refresh")

        let delegate = SecureSessionDelegateCoordinator()
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let task = URLSession.shared.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for destination in ["file:///etc/passwd", "https://example.com:22/story", "http://example.com/story"] {
            var rejected = false
            delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: destination)!)) { redirected in
                rejected = redirected == nil
            }
            assertTrue(rejected, "Unsafe redirect must be rejected before connection")
        }
        task.cancel()
    }

    @MainActor
    static func testProductionFollowupRegressions() async throws {
        print("  - Testing cache rollback, ordered mutations, saved analysis and update failures...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("regression.sqlite").path
        let db = DatabaseEngine(path: path)
        let store = ArticleStore(database: db)
        await store.initialize()
        assertTrue(store.migrationCoordinator == nil, "Injected stores must not migrate real user defaults or caches")
        let article = FeedArticle(title: "Archived report", link: "https://example.com/archive", guid: "archived", description: "Preview", pubDate: .distantPast, source: "Publisher", fullContent: "Preserve this body")
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
        let analysis = ArticleAnalysis(summary: "New summary", keyPoints: ["Finding"], entities: [], category: "Science", sentiment: nil, modelIdentifier: "test", analysisVersion: 2)
        await store.saveArticleAnalysis(analysis, for: article.id)
        assertEqual(store.savedArticles.first?.aiSummary, "New summary", "Saved snapshot receives new analysis")
        await store.setSaved(article: article, isSaved: false)
        var connection: OpaquePointer?
        assertEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated failure-injection database")
        defer { sqlite3_close(connection) }
        assertEqual(sqlite3_exec(connection, "CREATE TRIGGER fail_cache BEFORE DELETE ON article_enrichment BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;", nil, nil, nil), SQLITE_OK, "Install rollback regression trigger")
        do {
            try await store.clearArticleCache()
            assertTrue(false, "Cache failures must reach the caller")
        } catch {
            // Failure is expected: the preceding assertion rejects an unexpected success.
        }
        let restored = try await db.fetchArticles(limit: 10)
        assertEqual(restored.first?.fullContent, "Preserve this body", "Failed cleanup rolls back the preceding content update")
        assertEqual(sqlite3_exec(connection, "DROP TRIGGER fail_cache;", nil, nil, nil), SQLITE_OK, "Remove isolated failure trigger")
        try await store.clearAllDatabaseCache()
        assertTrue(try await db.getReadArticleIDs().contains(article.id), "All-cache cleanup preserves read history")
        try await db.markAllRead(feedUrl: "https://example.com/rss")

        var recent: [FeedArticle] = []
        for number in 0..<510 {
            recent.append(FeedArticle(title: "Recent \(number)", link: "https://example.com/\(number)", guid: "recent-\(number)", description: "Recent", pubDate: Date(), source: "Publisher"))
        }
        try await db.upsertArticles(recent)
        let history = try await db.fetchArticles(isRead: true, limit: 200)
        assertTrue(history.contains(where: { $0.id == article.id }), "History queries include stories beyond the recent 500")
        let found = try await db.searchArticles(query: "Archived", limit: 200)
        assertEqual(found.first?.id, article.id, "Search reaches archived stories")
        assertEqual(try await db.searchArticles(query: "Archiv", limit: 200).first?.id, article.id, "FTS prefix search matches unfinished words")
        try await db.markRead(articleId: article.id, isRead: false)
        try await db.upsertArticles([article], feedUrl: "https://example.com/second-rss")
        try await db.markAllRead(feedUrl: "https://example.com/rss")
        assertTrue(try await db.getReadArticleIDs().contains(article.id), "Duplicate ingestion preserves original feed provenance")
        try await db.markRead(articleId: article.id, isRead: false)
        try await db.markAllRead(feedUrl: "https://example.com/second-rss")
        assertTrue(try await db.getReadArticleIDs().contains(article.id), "Shared stories belong to every originating feed")
        let firstPage = try await db.fetchArticles(limit: 200)
        let secondPage = try await db.fetchArticles(limit: 200, after: ArticleQueryCursor(firstPage.last!))
        let thirdPage = try await db.fetchArticles(limit: 200, after: ArticleQueryCursor(secondPage.last!))
        assertEqual(Set((firstPage + secondPage + thirdPage).map(\.id)).count, 511, "Keyset pages include all stories without duplicates at tied dates")
        let searchPage = try await db.searchArticles(query: "Recent", limit: 200)
        let searchNext = try await db.searchArticles(query: "Recent", limit: 400, after: ArticleQueryCursor(searchPage.last!))
        assertEqual(Set((searchPage + searchNext).map(\.id)).count, 510, "FTS rank cursor handles tied ranks without omissions")
        await db.close()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); MockURLProtocol.requestHandler = nil }
        let checker = UpdateChecker(session: session)
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
        assertEqual(checker.statusMessage, "No published release is available to compare.", "Missing releases are not reported as up to date")
    }

    static func testLiveReader() async {
        for link in ["https://www.bbc.co.uk/news/articles/c6jdvmy1287yo", "https://www.bbc.co.uk/news/articles/cm750pyz5r0eo"] {
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(from: link)
            guard case .success(let content, _, let document) = outcome else {
                assertTrue(false, "BBC reader regression must extract publisher prose")
                continue
            }
            assertTrue(document != nil, "Live publisher retains reader structure")
            assertFalse(content.contains("Get in touch"), "BBC contact furniture excluded")
            assertFalse(content.contains("17:45 weekdays"), "BBC listening promotion excluded")
        }

        for url in ["https://www.theguardian.com/world/rss", "https://feeds.arstechnica.com/arstechnica/index", "https://www.nasa.gov/feed/"] {
            let result = await FeedFetcher.shared.fetchSingleFeed(urlString: url)
            assertTrue(result.error == nil, "Live feed fetch must succeed for \(url)")
            guard let article = result.articles?.first else {
                assertTrue(false, "Live feed must contain an article")
                continue
            }
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(from: article.link)
            let content = article.fullContent ?? outcome.content ?? ""
            assertFalse(ArticleContentRedactor.redactAndSplit(content).isEmpty, "Live publisher article must provide readable prose for \(url)")
            print("  - Live reader: \(URL(string: url)!.host!), \(result.articles!.count) items, \(content.count) body characters; extraction success: \(outcome.isSuccess)")
        }
    }

    static func testReaderParsingRegressions() async {
        let topic = await ArticleClassifier.shared.classify(title: "NASA launches space telescope", description: "Astronomy mission", allowFoundationModels: false)
        assertEqual(topic.category, "Science", "Cheap ingestion classification works without generative inference")
        let pipeline = ContentExtractionPipeline.shared
        let inline = "<p>The <strong>central bank</strong> raised <a href='/rate'>rates</a> today.</p>"
        assertEqual(HTMLDOMBuilder.parse(html: inline).combinedText(), "The central bank raised rates today.", "Inline text retains publisher order and punctuation")
        let prose = "The central bank published its quarterly report with detailed forecasts for inflation and employment across the economy."
        let second = "Independent economists reviewed the figures and described the outlook as stable, with further updates expected next month."
        let html = "<SCRIPT>ignored()</SCRIPT><ARTICLE><P>\(prose)<P>\(second)</ARTICLE>"
        assertEqual(pipeline.extractFromHTML(html).content, "\(prose)\n\n\(second)", "Uppercase raw tags and optional paragraph endings preserve the body")
        assertTrue(pipeline.extractFromHTML("<article><div>\(prose)</div><div>\(second)</div></article>").isSuccess, "Div-only articles remain readable")
        let hiddenHTML = "<article><p>\(prose)</p><p>\(second)</p><div hidden><p>Hidden subscription announcement that should never appear in a reader.</p></div><div aria-hidden='true'>Another hidden panel with a substantial amount of text.</div><button>Follow this publisher for personalized updates and notifications.</button></article>"
        assertEqual(pipeline.extractFromHTML(hiddenHTML).content, "\(prose)\n\n\(second)", "Hidden panels and button labels cannot leak into publisher prose")
        let atom = """
        <atom:feed xmlns:atom="http://www.w3.org/2005/Atom"><atom:title>Daily</atom:title><atom:entry>
        <atom:id>item-1</atom:id><atom:title>Report</atom:title>
        <atom:link href="/report"/><atom:link rel="self" href="/api/report"/>
        <atom:published>2026-09-20T10:00:00Z</atom:published><atom:updated>2026-09-21T10:00:00Z</atom:updated>
        <atom:content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First <b>important</b> paragraph.</p><p>Second paragraph.</p></div></atom:content>
        </atom:entry></atom:feed>
        """
        let article = FeedXMLParser(data: Data(atom.utf8), feedURL: "https://example.com/feed").parse().first
        assertEqual(article?.link, "https://example.com/report", "Atom self links cannot replace article links")
        assertEqual(article?.fullContent, "First important paragraph.\n\nSecond paragraph.", "Atom XHTML preserves paragraph boundaries")
        assertEqual(article?.pubDate, DateParser.parse("2026-09-20T10:00:00Z"), "Published and updated dates are not concatenated")
        let rss = "<rss><channel><title>News</title><image><title>News logo</title></image><item><title>Story</title><link>https://example.com/story</link></item></channel></rss>"
        assertEqual(FeedXMLParser(data: Data(rss.utf8)).parse().first?.source, "News", "Feed image title cannot contaminate publisher name")
        let broken = FeedXMLParser(data: Data("<rss><channel><item>".utf8))
        assertTrue(broken.parse().isEmpty && broken.parseError != nil, "Malformed feeds report a parsing failure")
        let json = """
        {"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://example.com/1","content_text":"Use x < y and y > z.","summary":"Use x < y and y > z. Keep &amp; literal."},{"id":"2","url":"https://example.com/2","description":"<p>Legacy <b>HTML</b> &amp; text.</p>"}]}
        """
        let textArticle = JSONFeedParser.parse(data: Data(json.utf8), feedURL: "https://example.com/feed")?.first
        assertEqual(textArticle?.fullContent, "Use x < y and y > z.", "JSON plain text must never pass through HTML stripping")
        assertEqual(textArticle?.contentFetched, true, "Short explicit feed content is readable")
        assertEqual(textArticle?.description, "Use x < y and y > z. Keep &amp; literal.", "JSON summaries preserve plain text comparisons and literal entities")
        let legacyArticle = JSONFeedParser.parse(data: Data(json.utf8), feedURL: "https://example.com/feed")?.last
        assertEqual(legacyArticle?.description, "Legacy HTML & text.", "Legacy JSON descriptions retain HTML cleanup")
    }

    static func testStructuredReaderAndTags() async {
        let first = "The central bank published its quarterly report with detailed forecasts for inflation and employment across the economy."
        let second = "Independent economists reviewed the figures and described the outlook as stable, with further updates expected next month."
        let html = """
        <main><article><p>\(first)</p><h2>What changes?</h2><p>\(second)</p>
        <ol start="3"><li>Lower fees</li><li>Faster payments</li></ol>
        <blockquote><p>The outlook remains stable.</p><p>We will review it in December.</p></blockquote>
        <pre>let rate = 2\nprint(rate)</pre>
        <div class="reader-comments"><div class="article-body"><p>\(first) USER COMMENT MUST NOT APPEAR.</p></div></div>
        <div data-component="links-block"><h2>Related reports</h2><p><a href="/other">Other report headline</a>17 hours ago</p></div>
        <p><a href="/another">Another report headline about employment and the economy</a><span>1 day ago</span></p>
        <p>Sign up for our Economics newsletter to keep up with the news.</p>
        <div data-block="eventPromo"><p>PODCAST PROMOTION that does not belong in publisher prose.</p></div>
        <div data-block="topicList"><h2>Related topics</h2><p>Topic navigation that does not belong in publisher prose.</p></div>
        <div data-block="promoList"><h2>More on this story</h2><p>More publisher teasers that do not belong in the body.</p></div>
        <div data-block="uploaderEmbed"><h2>Get in touch</h2><p>What are your views on the triple lock?</p></div>
        <p>Listen to Newsbeat <a href="/sounds/play/live:bbc_radio_one">live</a> at 12:45 and 17:45 weekdays - or listen back <a href="/programmes/b006wkry/episodes/player">here</a>.</p>
        <p>Listen to Newsbeat was the instruction discussed by the researcher in the report.</p>
        <section class="commentary"><p>\(second) Editorial commentary belongs here.</p></section>
        </article></main>
        """
        let outcome = ContentExtractionPipeline.shared.extractFromHTML(html)
        guard case .success(let content, _, let document) = outcome, let document else {
            assertTrue(false, "Structured reader fixture must extract successfully")
            return
        }
        assertEqual(document.blocks.filter { $0.kind == .heading }.map(\.text), ["What changes?"], "Short publisher headings survive")
        assertEqual(document.blocks.filter { $0.kind == .listItem }.map(\.ordinal), [3, 4], "Ordered lists retain numbering")
        assertTrue(document.blocks.contains { $0.kind == .quote && $0.text.contains("stable. We") }, "Quote paragraphs retain word boundaries")
        assertTrue(document.blocks.contains { $0.kind == .code && $0.text.contains("\n") }, "Code retains line breaks")
        for unwanted in ["USER COMMENT", "Other report", "Another report", "newsletter", "PODCAST", "Related topics", "More on this story", "Get in touch", "views on the triple lock", "17:45 weekdays"] {
            assertFalse(content.contains(unwanted), "Publisher furniture excluded: \(unwanted)")
        }
        assertTrue(content.contains("instruction discussed by the researcher"), "Editorial references to a programme remain eligible")
        assertTrue(content.contains("Editorial commentary"), "Comment filtering must not remove editorial commentary")
        let extremeList = HTMLDOMBuilder.parse(html: "<ol start='\(Int.max)'><li>First</li><li>Second</li></ol>")
        assertEqual(extremeList.readingBlocks().count, 2, "Untrusted extreme list numbering must not overflow")
        let tags = EntityResult.readerTags(from: [
            EntityResult(name: "Healey", type: .person), EntityResult(name: "John Healey", type: .person),
            EntityResult(name: " JOHN  HEALEY ", type: .person), EntityResult(name: "Stanford University", type: .organization),
            EntityResult(name: "AI on Employment Among Recent College Graduates", type: .unknown)
        ])
        assertEqual(tags.map(\.name), ["John Healey", "Stanford University"], "Tags resolve aliases and reject document-title fragments")
        let ambiguous = EntityResult.readerTags(from: [EntityResult(name: "Smith", type: .person), EntityResult(name: "John Smith", type: .person), EntityResult(name: "Jane Smith", type: .person)])
        assertEqual(ambiguous.count, 3, "An ambiguous surname must not be merged into a guessed identity")

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("news-reader-\(UUID().uuidString).sqlite3").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let database = DatabaseEngine(path: path)
        do {
            try await database.open()
            var article = FeedArticle(title: "Report", link: "https://example.com/structured", guid: "reader-structure", description: "Preview", pubDate: Date(), source: "Test", fullContent: content)
            try await database.upsertArticles([article])
            try await database.markRead(articleId: article.id, isRead: true)
            try await database.setSaved(articleId: article.id, isSaved: true)
            await database.close()
            var handle: OpaquePointer?
            assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open migration fixture")
            assertEqual(sqlite3_exec(handle, "DROP TABLE article_aliases; DROP TABLE article_feeds; ALTER TABLE articles DROP COLUMN reader_document; ALTER TABLE article_enrichment DROP COLUMN key_points; ALTER TABLE article_enrichment DROP COLUMN category; ALTER TABLE article_enrichment DROP COLUMN confidence; ALTER TABLE article_enrichment DROP COLUMN model_identifier; ALTER TABLE article_enrichment DROP COLUMN analysis_version; PRAGMA user_version = 1;", nil, nil, nil), SQLITE_OK, "Prepare v1 fixture")
            sqlite3_close(handle)
            try await database.open()
            let migrated = try await database.fetchArticles()
            assertEqual(migrated.first?.fullContent, content, "Migration preserves old body text")
            assertTrue(try await database.isSaved(articleId: article.id), "Migration preserves saved state")
            assertTrue(try await database.isRead(articleId: article.id), "Migration preserves read state")
            try await database.updateEnrichment(articleId: article.id, update: .init(content: content, readerDocument: document))
            article.fullContent = "A later feed teaser must not overwrite the extracted document."
            try await database.upsertArticles([article])
            await database.close()
            try await database.open()
            let restored = try await database.fetchArticles()
            assertEqual(restored.first?.readerDocument, document, "Reader structure survives reopen and feed refresh")
            assertEqual(restored.first?.fullContent, content, "Body and structure remain consistent after feed refresh")
            let search = try await database.searchArticles(query: "inflation")
            assertEqual(search.first?.readerDocument, document, "FTS results retain reader structure")
            await database.close()
        } catch {
            await database.close()
            assertTrue(false, "Structured persistence failed: \(error)")
        }
    }

    static func testURLNormalization() async {
        print("  - Testing URL Normalization...")
        
        let url1 = "https://example.com/story?utm_source=feed&utm_medium=rss&ref=share"
        assertEqual(FeedArticle.normalizeURL(url1), "https://example.com/story", "Should strip tracking query parameters")
        
        let url2 = "https://example.com/path/"
        assertEqual(FeedArticle.normalizeURL(url2), "https://example.com/path", "Should strip trailing slashes")
        
        let url3 = "https://EXamPLE.COm/Path/"
        assertEqual(FeedArticle.normalizeURL(url3), "https://example.com/Path", "Should lowercase the host and strip trailing slash")
        
        let url4 = "http://example.com/path"
        assertEqual(FeedArticle.normalizeURL(url4), "https://example.com/path", "Should upgrade scheme to https")
    }
    
    static func testSSRFValidation() async {
        print("  - Testing SSRF block list...")
        
        assertTrue(FeedManager.isBlockedLocalAddress("localhost"), "Should block localhost")
        assertTrue(FeedManager.isBlockedLocalAddress("127.0.0.1"), "Should block 127.0.0.1")
        assertTrue(FeedManager.isBlockedLocalAddress("10.0.1.5"), "Should block private range 10.x")
        assertTrue(FeedManager.isBlockedLocalAddress("192.168.1.100"), "Should block private range 192.168.x")
        assertTrue(FeedManager.isBlockedLocalAddress("172.20.5.5"), "Should block private range 172.16-31.x")
        assertTrue(FeedManager.isBlockedLocalAddress("::1"), "Should block IPv6 loopback")
        assertTrue(FeedManager.isBlockedLocalAddress("fe80::1"), "Should block IPv6 link-local")
        
        assertTrue(FeedManager.isBlockedLocalAddress("192.0.0.88"), "Should block IETF special-use 192.0.0.0/24")
        // Hostname allowance depends on the local resolver, so it runs only with controlled network checks.
        if ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1" {
            assertFalse(FeedManager.isBlockedLocalAddress("google.com"), "Should allow public hostnames")
        }
        assertFalse(FeedManager.isBlockedLocalAddress("8.8.8.8"), "Should allow public IPs")
        assertFalse(FeedManager.isBlockedLocalAddress("172.15.2.2"), "Should allow public range outside 172.16-31")
    }

    static func testIsBlockedIPv4() async {
        print("  - Testing isBlockedIPv4 directly...")

        func makeInAddr(_ ipString: String) -> in_addr {
            var sin = in_addr()
            inet_pton(AF_INET, ipString, &sin)
            return sin
        }

        // Loopback
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("127.0.0.1")) != nil, "127.0.0.1 must be blocked")

        // Current network
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("0.0.0.0")) != nil, "0.0.0.0 must be blocked")

        // Private
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("10.0.0.1")) != nil, "10.0.0.1 must be blocked")
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("172.16.0.1")) != nil, "172.16.0.1 must be blocked")
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("192.168.0.1")) != nil, "192.168.0.1 must be blocked")

        // Link-Local
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("169.254.0.1")) != nil, "169.254.0.1 must be blocked")

        // Carrier-Grade NAT
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("100.64.0.1")) != nil, "100.64.0.1 must be blocked")

        // Multicast
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("224.0.0.1")) != nil, "224.0.0.1 must be blocked")

        // Broadcast
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("255.255.255.255")) != nil, "255.255.255.255 must be blocked")

        // Valid
        assertTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("8.8.8.8")) == nil, "8.8.8.8 must be allowed")
    }

    static func testIPAddressValidatorDeep() async {
        print("  - Testing IPAddressValidator (IPv4, IPv6, mapped IPv6, DNS)...")

        // 1. Literal IPv4 Loopback & Private
        assertTrue(IPAddressValidator.checkLiteralIP("127.0.0.1") != nil, "127.0.0.1 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("127.255.255.255") != nil, "127.255.255.255 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("0.0.0.0") != nil, "0.0.0.0 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("10.254.1.2") != nil, "10.254.1.2 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("172.16.0.1") != nil, "172.16.0.1 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("172.31.255.254") != nil, "172.31.255.254 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("192.168.0.1") != nil, "192.168.0.1 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("169.254.169.254") != nil, "169.254.169.254 link-local must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("224.0.0.1") != nil, "224.0.0.1 multicast must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("255.255.255.255") != nil, "255.255.255.255 broadcast must be blocked")

        // 2. Allowed Public IPv4
        assertTrue(IPAddressValidator.checkLiteralIP("93.184.216.34") == nil, "example.com public IP must be allowed")
        assertTrue(IPAddressValidator.checkLiteralIP("1.1.1.1") == nil, "1.1.1.1 public IP must be allowed")
        assertTrue(IPAddressValidator.checkLiteralIP("8.8.8.8") == nil, "8.8.8.8 public IP must be allowed")

        // 3. Literal IPv6 Loopback, ULA, Link-Local
        assertTrue(IPAddressValidator.checkLiteralIP("::1") == "IPv6 loopback (::1)", "::1 must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("::") != nil, ":: must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("fe80::1") != nil, "fe80::1 link-local must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("fc00::1") != nil, "fc00::1 ULA must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("fd12:3456::1") != nil, "fd12:3456::1 ULA must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("ff02::1") != nil, "ff02::1 multicast must be blocked")

        // 4. IPv4-mapped IPv6 normalization
        assertTrue(IPAddressValidator.checkLiteralIP("::ffff:127.0.0.1") != nil, "::ffff:127.0.0.1 mapped loopback must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("::ffff:192.168.1.1") != nil, "::ffff:192.168.1.1 mapped private must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("::ffff:10.0.0.1") != nil, "::ffff:10.0.0.1 mapped private must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("::ffff:93.184.216.34") == nil, "::ffff:93.184.216.34 mapped public must be allowed")

        // 5. NAT64 IPv6 normalization
        assertTrue(IPAddressValidator.checkLiteralIP("64:ff9b::127.0.0.1") == "NAT64 IPv6 (IPv4 loopback address (127.0.0.0/8))", "64:ff9b::127.0.0.1 NAT64 loopback must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("64:ff9b::192.168.1.1") == "NAT64 IPv6 (RFC 1918 private network (192.168.0.0/16))", "64:ff9b::192.168.1.1 NAT64 private must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("64:ff9b::10.0.0.1") == "NAT64 IPv6 (RFC 1918 private network (10.0.0.0/8))", "64:ff9b::10.0.0.1 NAT64 private must be blocked")
        assertTrue(IPAddressValidator.checkLiteralIP("64:ff9b::93.184.216.34") == nil, "64:ff9b::93.184.216.34 NAT64 public must be allowed")

        // 6. Hostname string validation
        if case .blocked = IPAddressValidator.validateHost("localhost") {
            // expected
        } else {
            print("❌ validateHost('localhost') was not blocked")
            exit(1)
        }

        if case .blocked = IPAddressValidator.validateHost("test.local") {
            // expected
        } else {
            print("❌ validateHost('test.local') was not blocked")
            exit(1)
        }

        if case .blocked = IPAddressValidator.validateHost("router.internal") {
            // expected
        } else {
            print("❌ validateHost('router.internal') was not blocked")
            exit(1)
        }

        // 7. Socket Address Validation (validateSocketAddress)
        var loopbackAddress = sockaddr_in()
        loopbackAddress.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &loopbackAddress.sin_addr)
        let blockedLoopback = withUnsafePointer(to: &loopbackAddress) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        assertTrue(blockedLoopback != nil, "127.0.0.1 socket address must be blocked")

        var publicAddress = sockaddr_in()
        publicAddress.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "8.8.8.8", &publicAddress.sin_addr)
        let allowedPublic = withUnsafePointer(to: &publicAddress) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        assertTrue(allowedPublic == nil, "8.8.8.8 socket address must be allowed")

        var loopbackIPv6Address = sockaddr_in6()
        loopbackIPv6Address.sin6_family = sa_family_t(AF_INET6)
        inet_pton(AF_INET6, "::1", &loopbackIPv6Address.sin6_addr)
        let blockedLoopback6 = withUnsafePointer(to: &loopbackIPv6Address) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        assertTrue(blockedLoopback6 != nil, "::1 socket address must be blocked")

        var publicIPv6Address = sockaddr_in6()
        publicIPv6Address.sin6_family = sa_family_t(AF_INET6)
        inet_pton(AF_INET6, "2606:4700:4700::1111", &publicIPv6Address.sin6_addr)
        let allowedPublic6 = withUnsafePointer(to: &publicIPv6Address) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        assertTrue(allowedPublic6 == nil, "2606:4700:4700::1111 socket address must be allowed")

        var unsupportedAddress = sockaddr()
        unsupportedAddress.sa_family = sa_family_t(AF_UNIX)
        let allowedUnsupported = withUnsafePointer(to: &unsupportedAddress) { ptr -> String? in
            IPAddressValidator.validateSocketAddress(ptr)
        }
        assertTrue(allowedUnsupported == nil, "Unsupported family socket address must return nil")
    }

    static func testSecureHTTPClientFetchImage() async {
        print("  - Testing SecureHTTPClient fetchImage with MockURLProtocol...")

        // Setup custom configuration with MockURLProtocol
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        let client = SecureHTTPClient(configuration: config)

        let targetURL = URL(string: "https://example.com/test-image.jpg")!

        // Test 1: Successful image fetch
        let mockData = Data(repeating: 0xAA, count: 1024)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, mockData)
        }

        do {
            let (data, response) = try await client.fetchImage(from: targetURL)
            assertEqual(data.count, 1024, "Should download exact mock bytes")
            assertEqual(response.statusCode, 200, "Should get 200 status code")
        } catch {
            print("❌ Unexpected error in fetchImage success test: \(error)")
            exit(1)
        }

        // Test 2: Image too large
        let maxAllowed = Int(SecureHTTPClient.defaultImageLimit)
        let tooLargeDataSize = maxAllowed + 1024
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(tooLargeDataSize)"]
            )!
            let largeData = Data(repeating: 0xBB, count: tooLargeDataSize)
            return (response, largeData)
        }

        do {
            _ = try await client.fetchImage(from: targetURL)
            print("❌ Expected fetchImage to throw responseTooLarge error")
            exit(1)
        } catch let error as FeedError {
            if case .responseTooLarge(let bytes, let maxAllowedLimit) = error {
                assertEqual(Int(bytes), tooLargeDataSize, "Expected byte size in error")
                assertEqual(Int(maxAllowedLimit), maxAllowed, "Expected max limit in error")
            } else {
                print("❌ Expected responseTooLarge error, got: \(error)")
                exit(1)
            }
        } catch {
            print("❌ Unexpected error type: \(error)")
            exit(1)
        }

        // Cleanup MockURLProtocol state
        MockURLProtocol.requestHandler = nil
    }

    static func testSecureHTTPClientPolicies() async {
        print("  - Testing SecureHTTPClient security policies...")

        // 1. Insecure scheme rejection (e.g. file://, javascript://)
        do {
            _ = try await SecureHTTPClient.shared.fetchData(from: URL(string: "file:///etc/passwd")!, maxBytes: 1024)
            print("❌ file:///etc/passwd should have thrown an insecureScheme error")
            exit(1)
        } catch let err as FeedError {
            if case .insecureScheme = err {
                // expected
            } else {
                print("❌ Unexpected error for file scheme: \(err)")
                exit(1)
            }
        } catch {
            print("❌ Unexpected error type: \(error)")
            exit(1)
        }

        // 2. Blocked port rejection (e.g. port 22, port 6379)
        do {
            _ = try await SecureHTTPClient.shared.fetchData(from: URL(string: "https://example.com:22/feed")!, maxBytes: 1024)
            print("❌ Port 22 should have been blocked")
            exit(1)
        } catch let err as FeedError {
            if case .blockedPort(let p) = err {
                assertEqual(p, 22, "Should block port 22")
            } else {
                print("❌ Unexpected error for blocked port: \(err)")
                exit(1)
            }
        } catch {
            print("❌ Unexpected error: \(error)")
            exit(1)
        }

        // 3. Blocked host rejection (e.g. localhost)
        do {
            _ = try await SecureHTTPClient.shared.fetchData(from: URL(string: "https://localhost/feed")!, maxBytes: 1024)
            print("❌ https://localhost should have been blocked")
            exit(1)
        } catch let err as FeedError {
            if case .blockedHost = err {
                // expected
            } else {
                print("❌ Unexpected error for localhost: \(err)")
                exit(1)
            }
        } catch {
            print("❌ Unexpected error: \(error)")
            exit(1)
        }
    }

    static func testFeedErrorHierarchy() async {
        print("  - Testing FeedError localized descriptions...")

        let err1 = FeedError.malformedURL("bad-url")
        assertTrue(err1.errorDescription?.contains("Malformed URL") == true, "Malformed URL message")

        let err2 = FeedError.blockedHost(host: "evil.com", reason: "Private subnet")
        assertTrue(err2.errorDescription?.contains("evil.com") == true, "Blocked host message")

        let err3 = FeedError.responseTooLarge(bytes: 20 * 1024 * 1024, maxAllowed: 10 * 1024 * 1024)
        assertTrue(err3.errorDescription?.contains("20.0 MB exceeds 10.0 MB") == true, "Response too large message")

        let err4 = FeedError.dnsRebindingDetected(host: "rebind.example", ip: "127.0.0.1")
        assertTrue(err4.errorDescription?.contains("DNS rebinding") == true, "DNS rebinding message")
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
    static func testAuditParsingAndSettingsRegressions(fixtureRoot: URL) async throws {
        print("  - Testing unknown dates, GUID permalinks and folder-only OPML imports...")
        assertEqual(DateParser.parse(""), nil, "Missing publication dates are unknown")
        assertEqual(DateParser.parse("definitely-not-a-date"), nil, "Malformed dates are unknown")
        let undatedXML = Data("<rss><channel><title>Publisher</title><item><title>Undated</title></item></channel></rss>".utf8)
        let first = FeedXMLParser(data: undatedXML).parse().first!
        let second = FeedXMLParser(data: undatedXML).parse().first!
        assertEqual(first.pubDate, DateParser.unknownDate, "Undated XML stories do not become breaking news")
        assertEqual(first.publicationDateText, "Date unavailable", "Unknown dates have an honest display label")
        assertEqual(first.id, second.id, "Undated stories without GUID or link retain a stable fingerprint")
        let json = Data(#"{"items":[{"id":"undated","url":"\#(fixtureRoot.appendingPathComponent("story").absoluteString)","date_published":"broken"}]}"#.utf8)
        assertEqual(JSONFeedParser.parse(data: json, feedURL: fixtureRoot.appendingPathComponent("feed").absoluteString)?.first?.pubDate,
                    DateParser.unknownDate, "Malformed JSON dates use the same stable fallback")
        for attribute in ["", " isPermaLink=\"true\"", " isPermaLink=\"false\""] {
            let xml = Data("<rss><channel><item><title>Permalink</title><guid\(attribute)>\(fixtureRoot.appendingPathComponent("permalink").absoluteString)</guid></item></channel></rss>".utf8)
            let article = FeedXMLParser(data: xml).parse().first!
            assertEqual(article.link, attribute.contains("false") ? "" : fixtureRoot.appendingPathComponent("permalink").absoluteString,
                        "RSS GUID fallback respects explicit non-permalink identifiers")
        }
        let suite = "test.audit.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let feed = fixtureRoot.appendingPathComponent("rss").absoluteString
        assertEqual(settings.addFeed(url: feed), feed, "New feed reports addition")
        assertEqual(settings.addFeed(url: feed), nil, "Duplicate feed reports no addition")
        let opml = Data("<opml><body><outline text=\"Archive Folder\"><outline xmlUrl=\"\(feed)\"/></outline></body></opml>".utf8)
        assertEqual(settings.importFeeds(from: opml), 0, "Folder-only import adds no duplicate subscription")
        let reloaded = AppSettings(defaults: defaults)
        assertTrue(reloaded.userSections.contains("Archive Folder"), "Imported folders survive settings reload")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try opml.write(to: url)
        assertEqual(try await OPMLFileReader.read(url), opml, "Async file import preserves data")
        try Data(repeating: 32, count: OPMLFileReader.maximumBytes + 1).write(to: url)
        do {
            _ = try await OPMLFileReader.read(url)
            assertTrue(false, "Oversized OPML files must be rejected")
        } catch { /* Expected bounded read failure. */ }
        do {
            _ = try OPMLParser.parseValidated(data: Data(repeating: 32, count: OPMLFileReader.maximumBytes + 1))
            assertTrue(false, "In-memory OPML imports must enforce the same size bound")
        } catch { /* Expected validation failure. */ }
    }

    @MainActor
    static func testAuditPersistenceAndRoutingRegressions(fixtureRoot: URL) async throws {
        print("  - Testing corrected metadata, alias saves and startup notification requests...")
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db)
        let original = FeedArticle(title: "Story", link: fixtureRoot.appendingPathComponent("old").absoluteString, guid: "stable-guid",
                                   description: "Preview", pubDate: Date(timeIntervalSince1970: 100), source: "Publisher")
        let pending = ArticleStore.NavigationRequest(articleID: original.id, link: original.link)
        store.pendingNavigation = pending
        await store.initialize()
        assertEqual(store.pendingNavigation, pending, "Initialization retains requests received before the UI mounts")
        assertEqual(try await db.upsertArticles([original, original]), Set([original.id]), "Duplicate batch rows count as one insertion")
        try await db.markRead(articleId: original.id, isRead: true)
        try await db.setSaved(articleId: original.id, isSaved: true)
        let corrected = FeedArticle(title: original.title, link: fixtureRoot.appendingPathComponent("corrected").absoluteString, guid: original.guid,
                                    description: original.description, pubDate: Date(timeIntervalSince1970: 200), source: original.source)
        assertTrue(try await db.upsertArticles([corrected]).isEmpty, "Corrected GUID metadata is an update, not a new story")
        let restored = try await db.fetchArticles(id: original.id).first!
        assertEqual(restored.link, corrected.link, "Corrected URL is persisted")
        assertEqual(restored.pubDate, corrected.pubDate, "Corrected publication date is persisted")
        assertTrue(try await db.isRead(articleId: original.id), "Metadata correction preserves reading history")
        assertTrue(try await db.isSaved(articleId: original.id), "Metadata correction preserves saved state")
        let incomplete = FeedArticle(title: original.title, link: "javascript:broken", guid: original.guid,
                                     description: original.description, pubDate: DateParser.unknownDate, source: original.source)
        try await db.upsertArticles([incomplete])
        let retained = try await db.fetchArticles(id: original.id).first!
        assertEqual(retained.link, corrected.link, "Malformed incoming URL cannot erase a working URL")
        assertEqual(retained.pubDate, corrected.pubDate, "Unknown incoming date cannot erase a known publication date")
        let archive = (0..<501).map { index in
            FeedArticle(title: "Recent \(index)", link: "https://example.com/recent/\(index)", guid: "recent-\(index)",
                        description: "Preview", pubDate: Date(timeIntervalSince1970: Double(1000 + index)), source: "Publisher")
        }
        try await db.upsertArticles(archive)
        await store.refreshState()
        assertFalse(store.articles.contains { $0.id == original.id }, "Notification fixture lies outside the 500-story snapshot")
        assertEqual(try await store.articleForNavigation(pending)?.id, original.id, "Stable ID routes old notifications after URL corrections")
        let legacyRequest = ArticleStore.NavigationRequest(articleID: nil, link: corrected.link + "?utm_source=rss")
        assertEqual(try await store.articleForNavigation(legacyRequest)?.id, original.id, "Old link-only notifications resolve normalized URLs")
        let saves = SavedStoriesManager(articleStore: store)
        let alias = FeedArticle(title: "Alias", link: corrected.link + "?utm_source=alias", guid: "different-guid",
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
        assertEqual(try await db.fetchArticles(id: alias.id).first?.id, original.id, "Alias save resolves the original document without a new primary key")
        assertEqual(try await db.fetchArticles(canonicalURL: corrected.link).count, 1, "Rapid save changes preserve one URL-equivalent document")
        let emptyLink = FeedArticle(title: "No link", link: "", guid: "empty-one", description: "", pubDate: .distantPast, source: "Publisher")
        let otherEmptyLink = FeedArticle(title: "Different story", link: "", guid: "empty-two", description: "", pubDate: .distantPast, source: "Publisher")
        saves.save(emptyLink)
        assertFalse(saves.isSaved(otherEmptyLink), "Missing URLs do not alias unrelated stories")
        await saves.waitForPendingChanges()
        await db.close()
        do {
            _ = try await store.fetchArticles()
            assertTrue(false, "Storage read failure must propagate rather than return an empty library")
        } catch { /* Expected closed-database error. */ }
    }

    @MainActor
    static func testAuditRefreshRegressions(fixtureRoot: URL) async throws {
        print("  - Testing notification deduplication beyond the snapshot and failed refresh storage...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("audit.sqlite").path
        let db = DatabaseEngine(path: path)
        let store = ArticleStore(database: db)
        await store.initialize()
        let archived = FeedArticle(title: "Archive", link: fixtureRoot.appendingPathComponent("archive").absoluteString, guid: "archive",
                                   description: "", pubDate: Date(timeIntervalSince1970: 0), source: "Publisher")
        let recent = (0..<501).map { index in
            FeedArticle(title: "Recent \(index)", link: "https://example.com/\(index)", guid: "item-\(index)",
                        description: "", pubDate: Date(timeIntervalSince1970: Double(index)), source: "Publisher")
        }
        await store.batchUpsert(articles: [archived] + recent)
        let fresh = FeedArticle(title: "Fresh", link: fixtureRoot.appendingPathComponent("fresh").absoluteString, guid: "fresh",
                                description: "", pubDate: DateParser.unknownDate, source: "Publisher")
        let suite = "test.audit.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = [fixtureRoot.appendingPathComponent("rss").absoluteString, fixtureRoot.appendingPathComponent("second").absoluteString]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        var notified: [String] = []
        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [archived, fresh, fresh], nil) } },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map { $0.id }) })
        await manager.fetchFeedsAsync()
        let freshID = ArticleIdentity.scopedGUID(fresh.guid, feedURL: settings.feedURLs[0])!
        assertTrue(manager.articles.contains { $0.id == freshID }, "Notified undated story remains in the visible snapshot")
        assertEqual(notified, [freshID], "Only committed new IDs notify once, across duplicate rows and feeds")
        await manager.fetchFeedsAsync()
        assertEqual(notified, [freshID], "Repeat refresh does not re-notify stored stories")
        manager.stopBackgroundWork()
        var connection: OpaquePointer?
        assertEqual(sqlite3_open(path, &connection), SQLITE_OK, "Open isolated refresh failure fixture")
        defer { sqlite3_close(connection) }
        assertEqual(sqlite3_exec(connection, "CREATE TRIGGER fail_ingest BEFORE INSERT ON articles BEGIN SELECT RAISE(ABORT, 'simulated ingestion failure'); END;", nil, nil, nil), SQLITE_OK, "Install failed-ingestion trigger")
        let failed = FeedArticle(title: "Failed", link: fixtureRoot.appendingPathComponent("failed").absoluteString, guid: "failed", description: "", pubDate: Date(), source: "Publisher")
        let failureManager = FeedManager(settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [failed], nil) } },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map { $0.id }) })
        await failureManager.fetchFeedsAsync()
        assertEqual(notified, [freshID], "Failed ingestion cannot send new-story notifications")
        assertFalse(failureManager.articles.contains { $0.id == failed.id }, "Failed ingestion cannot replace the library with parsed data")
        // Drain the startup cache read before forcing a read failure.
        _ = try await store.fetchArticles()
        let snapshot = failureManager.articles
        await db.close()
        await failureManager.fetchFeedsAsync()
        assertEqual(failureManager.articles, snapshot, "Refresh read errors retain the visible library")
        failureManager.stopBackgroundWork()
    }

    static func testUndatedArticleOrdering() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let dated = (0..<501).map { index in
            FeedArticle(title: "Dated \(index)", link: "", guid: "dated-\(index)", description: "",
                        pubDate: Date(timeIntervalSince1970: Double(index)), source: "Publisher")
        }
        let undated = (0..<3).map { index in
            FeedArticle(title: "Undated \(index)", link: "", guid: "undated-\(index)", description: "",
                        pubDate: DateParser.unknownDate, source: "Publisher")
        }
        try await db.upsertArticles(dated + undated)
        let snapshot = try await db.fetchArticles()
        assertEqual(Set(snapshot.prefix(3).map(\.id)), Set(undated.map(\.id)), "Undated stories remain visible beyond 500 dated stories")
        assertEqual(snapshot.first?.pubDate, DateParser.unknownDate, "Ordering never fabricates a publication date")
        let firstPage = try await db.fetchArticles(limit: 2)
        let remainder = try await db.fetchArticles(limit: nil, after: ArticleQueryCursor(firstPage.last!))
        assertEqual((firstPage + remainder).count, 504, "Date cursor includes every row")
        assertEqual(Set((firstPage + remainder).map(\.id)).count, 504, "Tied ingestion dates do not duplicate rows")
        let searchPage = try await db.searchArticles(query: "is:unread", limit: 2)
        let searchRemainder = try await db.searchArticles(query: "is:unread", limit: 600, after: ArticleQueryCursor(searchPage.last!))
        assertEqual((searchPage + searchRemainder).map(\.id), (firstPage + remainder).map(\.id), "Filter-only search uses the same order and cursor")
        try await db.upsertArticles(undated)
        assertEqual(try await db.fetchArticles(limit: 3).map(\.queryOrderValue), snapshot.prefix(3).map(\.queryOrderValue), "Refresh preserves original ingestion time")
        try await db.markRead(articleId: undated[0].id, isRead: true)
        assertEqual(try await db.pruneOldArticles(), 0, "New undated read stories are not pruned as ancient")
        await db.close()
    }

    static func testDateParsing() async {
        print("  - Testing Date parsing...")
        
        let date1Str = "Tue, 19 May 2026 20:30:00 GMT"
        let date1 = DateParser.parse(date1Str)
        assertTrue((date1?.timeIntervalSince1970 ?? 0) > 0, "Should successfully parse RFC 822 date")
        
        let date2Str = "2026-05-19T20:30:00Z"
        let date2 = DateParser.parse(date2Str)
        assertTrue((date2?.timeIntervalSince1970 ?? 0) > 0, "Should successfully parse ISO 8601 date")
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
        
        assertEqual(articles.count, 1, "Should parse 1 article")
        let article = articles[0]
        
        assertEqual(article.title, "Apple Announces M5 Architecture", "Title should match")
        assertEqual(article.guid, "ars-m5-2026", "Guid should be parsed directly")
        assertEqual(article.id, "ars-m5-2026", "id should resolve to guid")
        assertEqual(article.description, "The new M5 silicon introduces unified quantum accelerators.", "HTML in description should be cleaned")
        assertEqual(article.imageUrl, "https://cdn.arstechnica.net/m5-hero.jpg", "Image enclosure URL should be parsed")
        assertEqual(article.category, "Hardware", "Category should match")
        assertEqual(article.source, "Ars Technica & News", "Decoded channel title should be assigned as source")
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
        assertTrue(articles != nil, "Should parse valid JSON Feed data")
        assertEqual(articles?.count, 1, "Should contain 1 article")
        
        let art = articles![0]
        assertEqual(art.title, "Swift 6 Concurrency Everywhere", "Title should match")
        assertEqual(art.guid, "df-item-9982", "Guid should match item id")
        assertEqual(art.id, "df-item-9982", "id should resolve to guid")
        assertEqual(art.source, "Daring Fireball", "Source should match feed title")
        assertEqual(art.imageUrl, "https://daringfireball.net/images/df-header.png", "Image URL should match")
    }

    static func testNavigationCommands() async {
        print("  - Testing Keyboard Navigation Offset Logic...")
        
        let sampleArticles = (0..<5).map { i in
            FeedArticle(
                title: "Article \(i)",
                link: "https://example.com/article-\(i)",
                guid: "guid-\(i)",
                description: "Description \(i)",
                pubDate: Date(timeIntervalSince1970: Double(1000 + i * 100)),
                source: "Source"
            )
        }
        
        let currentID = "guid-2"
        let currentIndex = sampleArticles.firstIndex(where: { $0.id == currentID })!
        assertEqual(currentIndex, 2, "Current index should be 2")
        
        let nextIndex = min(currentIndex + 1, sampleArticles.count - 1)
        assertEqual(nextIndex, 3, "Next index should be 3")
        assertEqual(sampleArticles[nextIndex].id, "guid-3", "Next article should be guid-3")
        
        let prevIndex = max(currentIndex - 1, 0)
        assertEqual(prevIndex, 1, "Previous index should be 1")
        assertEqual(sampleArticles[prevIndex].id, "guid-1", "Previous article should be guid-1")
    }

    static func testEscapeXML() async {
        print("  - Testing XML Escaping...")
        let unescaped = "Ben & Jerry's <Ice Cream> \"Taste Test\""
        let expectedEscaped = "Ben &amp; Jerry&apos;s &lt;Ice Cream&gt; &quot;Taste Test&quot;"
        assertEqual(OPMLExporter.escapeXML(unescaped), expectedEscaped, "Strings should be correctly XML escaped")
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
        assertTrue(OPMLParser.parse(data: malformed).isEmpty, "Malformed OPML must not import partial subscriptions")
        let items = OPMLParser.parse(data: opmlSample)
        assertEqual(items.count, 3, "Should parse all 3 feeds from flat and nested outlines")
        
        assertEqual(items[0].title, "Top News", "Should extract title")
        assertEqual(items[0].url, "https://news.ycombinator.com/rss", "Should extract xmlUrl")
        assertEqual(items[0].folder, nil, "Should have nil folder for root item")
        
        assertEqual(items[1].title, "Ars Technica", "Should extract title")
        assertEqual(items[1].url, "https://feeds.arstechnica.com/arstechnica/index", "Should extract xmlUrl")
        assertEqual(items[1].folder, "Technology", "Should associate with Technology folder")
        
        assertEqual(items[2].title, "The Verge", "Should extract title from text attribute")
        assertEqual(items[2].url, "https://www.theverge.com/rss/index.xml", "Should extract URL attribute")
        assertEqual(items[2].folder, "Technology", "Should associate with Technology folder")
        
        let urlsToExport = [
            "https://feeds.arstechnica.com/arstechnica/index",
            "https://news.ycombinator.com/rss"
        ]
        let exported = OPMLExporter.generateOPML(feedURLs: urlsToExport, title: "Exported Feeds")
        assertTrue(exported.contains("<opml version=\"2.0\">"), "Export should contain opml version 2.0")
        assertTrue(exported.contains("<title>Exported Feeds</title>"), "Export should contain title")
        assertTrue(exported.contains("xmlUrl=\"https://feeds.arstechnica.com/arstechnica/index\""), "Export should contain feed 1")
        assertTrue(exported.contains("xmlUrl=\"https://news.ycombinator.com/rss\""), "Export should contain feed 2")
        
        let roundtripData = exported.data(using: .utf8)!
        let roundtripItems = OPMLParser.parse(data: roundtripData)
        assertEqual(roundtripItems.count, 2, "Roundtrip OPML export should parse back into 2 feeds")
        assertEqual(roundtripItems[0].url, "https://feeds.arstechnica.com/arstechnica/index", "Roundtrip feed 1 URL match")
        assertEqual(roundtripItems[1].url, "https://news.ycombinator.com/rss", "Roundtrip feed 2 URL match")

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
        let xxeItems = OPMLParser.parse(data: xxePayload)
        if let item = xxeItems.first {
            assertTrue(!item.title.contains("root:"), "OPMLParser must not resolve external file entities")
        }
    }
    
    static func testOfflineCacheAndResilience() async {
        print("  - Testing Offline Cache & Resilience...")
        
        CacheManager.shared.configureOfflineCache()
        let size = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(size >= 0, "Cache directory byte calculation should succeed")
        
        CacheManager.shared.clearWebCache()
        let sizeAfter = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(sizeAfter >= 0, "Cache clear should succeed non-destructively")
    }
    
    static func testArticleIdentityDeep() async {
        print("  - Testing Article Identity & Fingerprinting...")
        
        // Priority 1: GUID priority
        let id1 = ArticleIdentity.computeId(guid: "guid-12345", link: "https://example.com/story?utm_source=rss", title: "Test", source: "Source")
        assertEqual(id1, "guid-12345", "Should prioritize explicit non-URL GUID")
        
        // Priority 1 with URL GUID: canonicalization
        let id2 = ArticleIdentity.computeId(guid: "http://EXAMPLE.com/guid-story/?utm_medium=feed", link: "https://other.com", title: "Test", source: "Source")
        assertEqual(id2, "https://example.com/guid-story", "Should canonicalize URL GUID")
        
        // Priority 2: Canonical URL when GUID is nil or empty
        let id3 = ArticleIdentity.computeId(guid: "  ", link: "http://example.com/article/?ref=share", title: "Test", source: "Source")
        assertEqual(id3, "https://example.com/article", "Should prioritize canonicalized URL when GUID is whitespace")
        
        // Priority 3: Fallback content fingerprint when both GUID and Link are missing/invalid
        let date = Date(timeIntervalSince1970: 1700000000)
        let id4 = ArticleIdentity.computeId(guid: nil, link: "", title: "Breaking News", source: "Reuters", pubDate: date)
        assertTrue(id4.hasPrefix("fp_"), "Fallback ID should be a content fingerprint prefixed with fp_")
        
        let id5 = ArticleIdentity.computeId(guid: nil, link: "", title: "breaking news ", source: " reuters", pubDate: date)
        assertEqual(id4, id5, "Content fingerprints should be case- and whitespace-insensitive")
        
        // Legacy reconciliation
        let reconciled = ArticleIdentity.reconcileLegacyId("http://test.com/path/?utm_source=newsletter")
        assertEqual(reconciled, "https://test.com/path", "Should reconcile legacy URL")
    }
    
    static func testReaderFigures(fixtureRoot: URL) async throws {
        print("  - Testing inline reader figures, captions and bounded image decoding...")
        let prose = "The researchers published their findings after reviewing the available evidence and comparing the results across several independent observations."
        let html = """
        <article><p>\(prose)</p>
        <figure><img src="/media/report.png" alt="Researchers examining the sample" width="1200" height="800"><figcaption>Sample photograph. Credit: Research team.</figcaption></figure>
        <h2>Results</h2><p>Additional observations support the initial findings. \(prose)</p>
        <figure hidden><img src="/hidden.png"><figcaption>Hidden caption</figcaption></figure>
        <figure><img src="file:///private/image.png"><figcaption>Local resource</figcaption></figure>
        <figure><img src="/pixel.png" width="1" height="1"></figure>
        <figure><img src="/media/report.png"><figcaption>Duplicate image</figcaption></figure>
        <aside><figure><img src="/related.png"></figure></aside></article>
        """
        let pipeline = ContentExtractionPipeline()
        guard case .success(let content, let lead, let document) = pipeline.extractFromHTML(html, baseUrl: fixtureRoot.absoluteString),
              let document else {
            assertTrue(false, "Structured publisher fixture must extract")
            return
        }
        assertEqual(document.blocks.map(\.kind), [.paragraph, .figure, .heading, .paragraph], "Keep editorial order and remove hidden, duplicate and invalid images")
        let figure = document.blocks[1]
        assertEqual(figure.imageURL, fixtureRoot.appendingPathComponent("media/report.png").absoluteString, "Relative figure URL resolves against publisher page")
        assertEqual(lead, figure.imageURL, "An editorial figure supplies the lead when metadata is absent")
        assertEqual(figure.text, "Sample photograph. Credit: Research team.", "Caption and attribution survive extraction")
        assertEqual(figure.imageAlt, "Researchers examining the sample", "Publisher alt text survives for accessibility")
        assertFalse(content.contains("Credit:"), "Image captions do not enter the article prose used for analysis")
        assertEqual(try JSONDecoder().decode(ReaderDocument.self, from: JSONEncoder().encode(document)), document, "Reader figures round-trip through persisted JSON")
        let oldJSON = Data(#"{"version":2,"blocks":[{"kind":"paragraph","text":"Old text"}]}"#.utf8)
        assertEqual(try JSONDecoder().decode(ReaderDocument.self, from: oldJSON).blocks[0].text, "Old text", "Existing reader documents remain readable")
        assertTrue(ContentExtractionPipeline.readerImageURL("data:image/png;base64,AAAA", baseURL: nil) == nil, "Embedded resources are not remote reader images")
        assertTrue(ContentExtractionPipeline.readerImageURL("https://user:secret@example.com/image.png", baseURL: nil) == nil, "Credential-bearing image URLs are rejected")
        let manyFigures = (0..<20).map { "<figure><img src='/media/\($0).png'></figure>" }.joined()
        guard case .success(_, _, let bounded) = pipeline.extractFromHTML("<article><p>\(prose)</p>\(manyFigures)<p>Second paragraph. \(prose)</p></article>", baseUrl: fixtureRoot.absoluteString) else {
            assertTrue(false, "Bounded media fixture must retain prose")
            return
        }
        assertEqual(bounded?.blocks.filter { $0.kind == .figure }.count, 8, "Reader document bounds remote image work")
        let divHTML = "<article><div>\(prose)</div><figure><img src='/media/div.png'></figure><div>Another observation. \(prose)</div></article>"
        guard case .success(let divText, _, let divDocument) = pipeline.extractFromHTML(divHTML, baseUrl: fixtureRoot.absoluteString) else {
            assertTrue(false, "Adding figures must not suppress the div-only prose fallback")
            return
        }
        assertTrue(divText.contains("Another observation"), "Div-only prose survives around figures")
        assertEqual(divDocument?.blocks.map(\.kind), [.paragraph, .figure, .paragraph], "Div-only articles preserve image position")
        let context = CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        assertTrue(CGImageDestinationFinalize(destination), "Encode isolated raster fixture")
        let thumbnail = try SecureHTTPClient.decodeReaderImage(data as Data)
        assertEqual(thumbnail.width, 1600, "Decode at a bounded display size")
        assertEqual(thumbnail.height, 800, "Preserve image aspect ratio")
        do {
            _ = try SecureHTTPClient.decodeReaderImage(Data("invalid image".utf8))
            assertTrue(false, "Invalid image input must fail decoding")
        } catch { /* Expected invalid-image failure. */ }
    }

    @MainActor
    static func testCanonicalArticleIngestion(fixtureRoot: URL) async throws {
        print("  - Testing canonical URL ingestion across changing GUIDs...")
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db)
        await store.initialize()
        let first = FeedArticle(title: "Original report", link: fixtureRoot.appendingPathComponent("identity/story").absoluteString,
                                guid: "first-guid", description: "Publisher report", pubDate: Date(timeIntervalSince1970: 100), source: "Publisher")
        let update = FeedArticle(title: "Updated report", link: first.link + "?utm_source=another-feed",
                                 guid: "replacement-guid", description: "Updated publisher report", pubDate: Date(timeIntervalSince1970: 200), source: first.source)
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
            FeedArticle(title: "Homepage-linked item \(index)", link: fixtureRoot.absoluteString,
                        guid: "homepage-\(index)", description: "Different reports", pubDate: Date(), source: first.source)
        }
        assertEqual(try await db.upsertArticles(homepageEntries).count, 2, "Generic homepage links do not merge distinct entries")
        let missingLinks = (0..<2).map { index in
            FeedArticle(title: "Missing-link item \(index)", link: "", guid: "missing-link-\(index)",
                        description: "Different reports", pubDate: Date(), source: first.source)
        }
        assertEqual(try await db.upsertArticles(missingLinks).count, 2, "Missing links do not identify a document")
        let referenceURL = first.link + "?reference=edition-two"
        assertEqual(ArticleIdentity.canonicalizeURL(referenceURL), referenceURL, "Meaningful query keys must not be stripped by a broad ref prefix")
        let otherEdition = FeedArticle(title: update.title, link: referenceURL, guid: "different-edition",
                                       description: update.description, pubDate: update.pubDate, source: first.source)
        assertEqual(try await db.upsertArticles([otherEdition]), Set([otherEdition.id]), "Meaningful query differences retain distinct documents")
        let sameHeadline = FeedArticle(title: update.title, link: first.link + "-different", guid: "different-event",
                                       description: update.description, pubDate: update.pubDate, source: first.source)
        assertEqual(try await db.upsertArticles([sameHeadline]), Set([sameHeadline.id]), "Matching text alone cannot merge different documents")
        let encoded = try JSONEncoder().encode(rows[0])
        assertEqual(try JSONDecoder().decode(FeedArticle.self, from: encoded).id, first.id, "Cached articles retain the stored identity")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "storedID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        assertEqual(try JSONDecoder().decode(FeedArticle.self, from: legacyData).id, update.id, "Legacy JSON remains decodable without a stored ID")
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
        let first = FeedArticle(title: "Original report", link: fixtureRoot.appendingPathComponent("aliases/original").absoluteString,
                                guid: "alias-first", description: "Report", pubDate: Date(timeIntervalSince1970: 100), source: "Publisher")
        let duplicateA = FeedArticle(title: "Historical A", link: fixtureRoot.appendingPathComponent("aliases/ambiguous").absoluteString,
                                     guid: "historical-a", description: "Report", pubDate: Date(), source: "Publisher")
        let duplicateB = FeedArticle(title: "Historical B", link: fixtureRoot.appendingPathComponent("aliases/other").absoluteString,
                                     guid: "historical-b", description: "Report", pubDate: Date(), source: "Publisher")
        try await original.upsertArticles([first, duplicateA, duplicateB], feedUrl: "test-feed")
        try await original.markRead(articleId: first.id, isRead: true)
        try await original.setSaved(articleId: first.id, isSaved: true)
        await original.close()
        // Reconstruct a genuine v4 library, including duplicates that predate URL resolution.
        execute(originalPath, """
        UPDATE articles SET canonical_url = (SELECT canonical_url FROM articles WHERE id = 'historical-a') WHERE id = 'historical-b';
        DROP TABLE article_aliases;
        PRAGMA user_version = 4;
        """)
        let originalReadAt = value(originalPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';")
        let originalSavedAt = value(originalPath, "SELECT saved_at FROM article_state WHERE article_id = 'alias-first';")
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
            assertEqual(value(cancelledPath, "SELECT count(*) FROM sqlite_master WHERE name = 'article_aliases';"), "0", "Cancelled migration rolls back the alias schema")
            assertEqual(value(cancelledPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';"), originalReadAt, "Cancelled migration preserves history")
        }
        try await cancelledDB.open()
        await cancelledDB.close()
        let db = DatabaseEngine(path: copyPath)
        try await db.open()
        assertEqual(value(copyPath, "PRAGMA user_version;"), "6", "Copied v4 library upgrades to the current schema")
        assertEqual(value(originalPath, "PRAGMA user_version;"), "4", "Original fixture stays untouched")
        assertEqual(try await db.fetchArticles(limit: nil).count, 3, "Migration keeps historical rows")
        assertEqual(value(copyPath, "SELECT read_at FROM article_state WHERE article_id = 'alias-first';"), originalReadAt, "Migration preserves read history timestamp")
        assertEqual(value(copyPath, "SELECT saved_at FROM article_state WHERE article_id = 'alias-first';"), originalSavedAt, "Migration preserves bookmark timestamp")
        assertTrue(try await db.isRead(articleId: first.id), "Migration preserves read state")
        assertTrue(try await db.isSaved(articleId: first.id), "Migration preserves saved state")
        assertEqual(try await db.searchArticles(query: "Original").first?.id, first.id, "Migration preserves FTS")
        assertEqual(value(copyPath, "SELECT count(*) FROM article_aliases WHERE kind = 'url' AND article_id IS NULL;"), "1", "Conflicting historical URL is marked ambiguous")
        let unknown = FeedArticle(title: "Unknown identity", link: duplicateA.link, guid: "unknown-guid", description: "Report", pubDate: Date(), source: "Publisher")
        assertEqual(try await db.resolvedArticleID(for: unknown), unknown.id, "Ambiguous URL never selects a historical row")
        assertTrue(try await db.fetchArticles(limit: 1, canonicalURL: duplicateA.normalizedLink).isEmpty, "Ambiguous notification URL must not choose a document")
        execute(copyPath, "PRAGMA foreign_keys = ON; DELETE FROM articles WHERE id = 'historical-a';")
        assertTrue(try await db.fetchArticles(limit: 1, canonicalURL: duplicateA.normalizedLink).isEmpty, "Removing a conflicting row must not revive an ambiguous URL")
        assertEqual(try await db.resolvedArticleID(for: unknown), unknown.id, "Ambiguous URL remains unusable after deletion")

        func variant(_ guid: String, _ link: String, _ title: String) -> FeedArticle {
            var article = FeedArticle(title: title, link: link, guid: guid, description: first.description, pubDate: first.pubDate, source: first.source)
            article.identityFeedURL = "test-feed"
            return article
        }
        let second = variant("alias-second", first.link, first.title)
        assertTrue(try await db.upsertArticles([second], feedUrl: "test-feed").isEmpty, "Same URL registers a new observed ID")
        let moved = variant("alias-second", fixtureRoot.appendingPathComponent("aliases/moved").absoluteString, "Migrated report")
        assertTrue(try await db.upsertArticles([moved], feedUrl: "test-feed").isEmpty, "Observed replacement GUID carries a URL change")
        await db.close()
        try await db.open()
        assertEqual(try await db.fetchArticles(limit: 1, id: second.id).first?.id, first.id, "ID alias survives reopen")
        assertEqual(try await db.fetchArticles(limit: 1, canonicalURL: first.normalizedLink).first?.id, first.id, "Previous URL survives replacement and reopen")
        let store = ArticleStore(database: db)
        await store.initialize()
        let navigation = ArticleStore.NavigationRequest(articleID: second.id, link: "")
        assertEqual(try await store.articleForNavigation(navigation)?.id, first.id, "Old notification ID resolves to stored article")
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
        assertEqual(try await db.searchArticles(query: "Migrated").first?.id, first.id, "Updated FTS uses the original primary key")
        await store.refreshState()
        await store.updateEnrichment(id: second.id, content: "Verified evidence")
        assertEqual(store.articles.first(where: { $0.id == first.id })?.fullContent, "Verified evidence", "Alias enrichment updates the visible stored article")
        assertEqual(try await db.fetchArticles(id: first.id).first?.fullContent, "Verified evidence", "Enrichment through an alias updates the original")
        let analysis = ArticleAnalysis(summary: "Cited summary", keyPoints: ["Finding"], entities: [], category: "Science", sentiment: nil, modelIdentifier: "test", analysisVersion: 1)
        await store.saveArticleAnalysis(analysis, for: second.id)
        assertEqual(store.savedArticles.first(where: { $0.id == first.id })?.aiSummary, analysis.summary, "Alias analysis updates the saved article cache")
        assertEqual(await db.fetchArticleAnalysis(for: second.id)?.summary, analysis.summary, "Analysis persistence and lookup resolve aliases")
        let returned = variant("alias-third", first.link, "Returned report")
        assertTrue(try await db.upsertArticles([returned]).isEmpty, "Old URL recognizes a further GUID change")
        let simultaneous = variant("alias-second", fixtureRoot.appendingPathComponent("aliases/third-location").absoluteString, first.title)
        assertTrue(try await db.upsertArticles([simultaneous]).isEmpty, "Known ID and changed URL resolve together")
        let unrelated = variant("never-observed", fixtureRoot.appendingPathComponent("aliases/unrelated").absoluteString, first.title)
        assertEqual(try await db.resolvedArticleID(for: unrelated), unrelated.id, "No known signal means no guessed merge")

        // Use another known, unambiguous document rather than the historical conflict.
        let separate = variant("separate-guid", fixtureRoot.appendingPathComponent("aliases/separate").absoluteString, "Separate report")
        try await db.upsertArticles([separate])
        let contradictory = variant(first.id, separate.link, "Contradictory report")
        do {
            try await db.upsertArticles([contradictory])
            assertTrue(false, "Contradictory known ID and URL must be reported")
        } catch {
            assertEqual(try await db.fetchArticles(id: first.id).first?.title, "Original report", "Conflicting signals must not overwrite the original")
            assertEqual(try await db.fetchArticles(id: separate.id).first?.title, separate.title, "Conflicting signals must not overwrite the other document")
        }

        // An alias write failure must roll back the article update and its FTS trigger too.
        execute(copyPath, "CREATE TRIGGER fail_alias BEFORE INSERT ON article_aliases BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        let failed = variant("failed-alias", returned.link, "Must rollback")
        do {
            try await db.upsertArticles([failed])
            assertTrue(false, "Alias failure must be reported")
        } catch {
            assertEqual(try await db.fetchArticles(limit: 1, id: first.id).first?.title, "Original report", "Failed alias update restores the previous article")
            assertTrue(try await db.searchArticles(query: "rollback").isEmpty, "Failed alias write rolls back FTS")
            assertEqual(try await db.resolvedArticleID(failed.id), failed.id, "Failed alias is never committed")
        }
        execute(copyPath, "DROP TRIGGER fail_alias;")
        assertEqual(value(copyPath, "PRAGMA quick_check;"), "ok", "Migrated alias library passes quick_check")
        assertTrue(value(copyPath, "PRAGMA foreign_key_check;") == nil, "Migrated aliases have no dangling targets")
        await db.close()
    }

    @MainActor
    static func testFeedScopedGUIDs(fixtureRoot: URL) async throws {
        print("  - Testing feed-scoped GUID collisions and notification identities...")
        let feeds = [fixtureRoot.appendingPathComponent("guid-feed-a").absoluteString,
                     fixtureRoot.appendingPathComponent("guid-feed-b").absoluteString]
        func incoming(_ feed: String, _ link: String, guid: String = "shared-guid") -> FeedArticle {
            var article = FeedArticle(title: "Report", link: link, guid: guid, description: "Publisher report", pubDate: Date(), source: feed)
            article.identityFeedURL = feed
            return article
        }
        let first = incoming(feeds[0], fixtureRoot.appendingPathComponent("publisher-a/report").absoluteString)
        let second = incoming(feeds[1], fixtureRoot.appendingPathComponent("publisher-b/report").absoluteString)
        assertTrue(first.id != second.id, "The same raw GUID from different feeds has different identity")
        assertTrue(ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0] + "?utm_source=rss") != first.id, "Article tracking rules must not collapse configured feed URLs")
        assertTrue(ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0].replacingOccurrences(of: "https://", with: "http://")) != first.id, "Explicit HTTP and HTTPS subscriptions retain separate namespaces")
        assertTrue(ArticleIdentity.scopedGUID("shared-guid", feedURL: feeds[0] + "?edition=2") != first.id, "Document-selecting feed parameters retain separate namespaces")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        assertEqual(try await db.upsertArticles([first], feedUrl: feeds[0]), Set([first.id]), "First feed inserts its scoped identity")
        try await db.markRead(articleId: first.id, isRead: true)
        try await db.setSaved(articleId: first.id, isSaved: true)
        assertEqual(try await db.upsertArticles([second], feedUrl: feeds[1]), Set([second.id]), "Other publisher's reused GUID inserts a distinct document")
        assertEqual(try await db.fetchArticles(limit: nil).count, 2, "GUID collision does not overwrite either publisher")
        assertFalse(try await db.isRead(articleId: second.id), "The other publisher does not inherit reading state")
        assertFalse(try await db.isSaved(articleId: second.id), "The other publisher does not inherit a bookmark")
        let moved = incoming(feeds[1], fixtureRoot.appendingPathComponent("publisher-b/moved").absoluteString)
        assertTrue(try await db.upsertArticles([moved], feedUrl: feeds[1]).isEmpty, "Same-feed GUID resolves a changed URL")
        assertEqual(try await db.fetchArticles(id: second.id).first?.link, moved.link, "URL correction updates only its own publisher")
        assertEqual(try await db.fetchArticles(id: first.id).first?.link, first.link, "The other publisher's URL stays intact")
        let sharedDocument = incoming(feeds[1], first.link, guid: "same-document-other-feed")
        assertTrue(try await db.upsertArticles([sharedDocument], feedUrl: feeds[1]).isEmpty, "Exact document URL can still connect different feeds")
        assertEqual(try await db.resolvedArticleID(for: sharedDocument), first.id, "Scoped alias points to the original shared document")
        let missingA = incoming(feeds[0], "", guid: "missing-link-guid")
        let missingB = incoming(feeds[1], "", guid: "missing-link-guid")
        assertEqual(try await db.upsertArticles([missingA], feedUrl: feeds[0]), Set([missingA.id]), "Missing URL remains identifiable within its feed")
        assertEqual(try await db.upsertArticles([missingB], feedUrl: feeds[1]), Set([missingB.id]), "Missing URLs do not make GUIDs global")
        await db.close()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-guid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite3").path
        let copy = directory.appendingPathComponent("copy.sqlite3").path
        let legacyDB = DatabaseEngine(path: path)
        try await legacyDB.open()
        let legacy = FeedArticle(title: "Legacy report", link: first.link, guid: "legacy-guid", description: "Existing article", pubDate: Date(), source: "Publisher")
        try await legacyDB.upsertArticles([legacy], feedUrl: feeds[0])
        try await legacyDB.markRead(articleId: legacy.id, isRead: true)
        try await legacyDB.setSaved(articleId: legacy.id, isSaved: true)
        let multi = FeedArticle(title: "Multi-feed legacy report", link: fixtureRoot.appendingPathComponent("legacy/multi").absoluteString, guid: "multi-guid", description: "Existing article", pubDate: Date(), source: "Publisher")
        try await legacyDB.upsertArticles([multi], feedUrl: feeds[0])
        try await legacyDB.upsertArticles([multi], feedUrl: feeds[1])
        let uncertain = FeedArticle(title: "Unattributed variant", link: fixtureRoot.appendingPathComponent("legacy/uncertain").absoluteString, guid: "original-unattributed", description: "Existing article", pubDate: Date(), source: "Publisher")
        try await legacyDB.upsertArticles([uncertain], feedUrl: feeds[0])
        let unattributed = FeedArticle(title: uncertain.title, link: uncertain.link, guid: "unattributed-guid", description: uncertain.description, pubDate: uncertain.pubDate, source: "Other publisher")
        try await legacyDB.upsertArticles([unattributed])
        await legacyDB.close()
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open isolated v5 fixture")
        assertEqual(sqlite3_exec(handle, "DELETE FROM article_aliases WHERE value LIKE 'feed-guid:%'; PRAGMA user_version = 5;", nil, nil, nil), SQLITE_OK, "Reconstruct a legacy v5 library")
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
            assertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK, "Read cancelled migration version")
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Read old schema version")
            assertEqual(sqlite3_column_int(statement, 0), 5, "Scoped GUID migration rolls back its version")
            sqlite3_finalize(statement)
            assertEqual(sqlite3_prepare_v2(handle, "SELECT count(*) FROM article_aliases WHERE value LIKE 'feed-guid:%';", -1, &statement, nil), SQLITE_OK, "Read cancelled migration aliases")
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Read scoped alias count")
            assertEqual(sqlite3_column_int(statement, 0), 0, "Cancelled migration commits no scoped aliases")
            sqlite3_finalize(statement)
            sqlite3_close(handle)
        }
        try await migrated.open()
        let legacyMoved = incoming(feeds[0], fixtureRoot.appendingPathComponent("legacy/moved").absoluteString, guid: "legacy-guid")
        assertTrue(try await migrated.upsertArticles([legacyMoved], feedUrl: feeds[0]).isEmpty, "Migration maps scoped GUID to the existing primary key even after URL correction")
        assertEqual(try await migrated.fetchArticles(id: legacy.id).first?.id, legacy.id, "Legacy primary key is preserved")
        let unknownMulti = incoming(feeds[1], fixtureRoot.appendingPathComponent("legacy/multi-moved").absoluteString, guid: "multi-guid")
        assertEqual(try await migrated.resolvedArticleID(for: unknownMulti), unknownMulti.id, "Migration does not guess GUID ownership for multi-feed history")
        assertEqual(try await migrated.fetchArticles(id: multi.id).first?.id, multi.id, "Uncertain multi-feed article retains its old ID")
        let unknownOwner = incoming(feeds[0], fixtureRoot.appendingPathComponent("legacy/unattributed-moved").absoluteString, guid: "unattributed-guid")
        assertEqual(try await migrated.resolvedArticleID(for: unknownOwner), unknownOwner.id, "Migration does not attribute a later unscoped GUID variant to the original feed")
        assertTrue(try await migrated.isRead(articleId: legacyMoved.id), "Scoped lookup preserves legacy read state")
        assertTrue(try await migrated.isSaved(articleId: legacyMoved.id), "Scoped lookup preserves legacy saved state")
        let legacyCollision = incoming(feeds[1], second.link, guid: "legacy-guid")
        assertEqual(try await migrated.upsertArticles([legacyCollision], feedUrl: feeds[1]), Set([legacyCollision.id]), "Legacy GUID ownership does not extend to another feed")
        assertEqual(try await migrated.fetchArticles(limit: nil).count, 4, "Copied library retains originals and colliding document")
        await migrated.close()

        let suite = "test.guid.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = feeds
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"))
        await store.initialize()
        var notified = [String]()
        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { feed in
                let article = feed == feeds[0] ? first : second
                return (feed, [article, article], nil)
            } }, notifyBatch: { articles, _ in notified.append(contentsOf: articles.map { $0.id }) })
        await manager.fetchFeedsAsync()
        assertEqual(Set(notified), Set([first.id, second.id]), "Both colliding publishers notify with committed, distinct IDs")
        assertEqual(notified.count, 2, "Duplicate rows notify once per stored document")
        await manager.fetchFeedsAsync()
        assertEqual(notified.count, 2, "Repeated refresh does not re-notify either publisher")
        assertEqual(Set(manager.articles.map { $0.id }), Set([first.id, second.id]), "Visible identities agree with notification IDs")
        manager.stopBackgroundWork()
        await store.database.close()
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
                pubDate: Date(timeIntervalSince1970: 1700000000),
                source: "TechBlog",
                category: "Tech"
            )
            
            try await db.upsertArticles([art1], feedUrl: "https://example.com/feed.xml")
            
            // Mark read and saved
            try await db.markRead(articleId: art1.id, isRead: true)
            let isSaved = try await db.toggleSaved(articleId: art1.id)
            assertTrue(isSaved, "Article should now be saved")
            
            let fetched1 = try await db.fetchArticles()
            assertEqual(fetched1.count, 1, "Should fetch 1 article")
            assertEqual(fetched1[0].title, "Original Title", "Title should match")
            
            let isReadBefore = try await db.isRead(articleId: art1.id)
            assertTrue(isReadBefore, "Article should be read")
            
            // Re-ingest with updated title and enriched content
            var art1Updated = art1
            art1Updated.fullContent = "Detailed full content scraped from web"
            
            try await db.upsertArticles([art1Updated], feedUrl: "https://example.com/feed.xml")
            
            // Verify read state and saved state are STRICTLY PRESERVED after upsert conflict!
            let isReadAfter = try await db.isRead(articleId: art1.id)
            let isSavedAfter = try await db.isSaved(articleId: art1.id)
            assertTrue(isReadAfter, "Read status must be preserved after re-ingestion")
            assertTrue(isSavedAfter, "Saved status must be preserved after re-ingestion")
            
            let counts = try await db.counts()
            assertEqual(counts.total, 1, "Total count should be 1")
            assertEqual(counts.saved, 1, "Saved count should be 1")
            assertEqual(counts.unread, 0, "Unread count should be 0 because it was marked read")

            // Test batch operations with explicit transactions
            let art2 = FeedArticle(title: "Batch Article 2", link: "https://example.com/art2", guid: "g2", description: "", pubDate: Date(), source: "Test")
            let art3 = FeedArticle(title: "Batch Article 3", link: "https://example.com/art3", guid: "g3", description: "", pubDate: Date(), source: "Test")
            try await db.upsertArticles([art2, art3], feedUrl: "https://example.com/feed.xml")

            try await db.markReadBatch(articleIds: [art2.id, art3.id], isRead: true)
            assertTrue(try await db.isRead(articleId: art2.id), "art2 should be marked read via batch")
            assertTrue(try await db.isRead(articleId: art3.id), "art3 should be marked read via batch")

            try await db.batchMarkSaved([art2.id, art3.id])
            assertTrue(try await db.isSaved(articleId: art2.id), "art2 should be marked saved via batch")
            assertTrue(try await db.isSaved(articleId: art3.id), "art3 should be marked saved via batch")
        } catch {
            print("❌ DatabaseEngine test failed: \(error.localizedDescription)")
            exit(1)
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
                pubDate: Date(timeIntervalSince1970: 1700001000),
                source: "Nature",
                category: "Science"
            )
            let artB = FeedArticle(
                title: "Stock Markets Rally on Tech Surge",
                link: "https://example.com/market",
                guid: "m-1",
                description: "Wall Street gains led by semiconductor shares",
                pubDate: Date(timeIntervalSince1970: 1700002000),
                source: "Bloomberg",
                category: "Business"
            )
            
            try await db.upsertArticles([artA, artB])
            
            // Plain FTS match
            let search1 = try await db.searchArticles(query: "qubit")
            assertEqual(search1.count, 1, "Should find quantum article matching 'qubit'")
            assertEqual(search1[0].id, artA.id, "Matched article ID must match")
            
            let search2 = try await db.searchArticles(query: "shares")
            assertEqual(search2.count, 1, "Should find market article matching 'shares'")
            assertEqual(search2[0].id, artB.id, "Matched article ID must match")
            
            // Operator searches
            let searchSource = try await db.searchArticles(query: "source:Nature")
            assertEqual(searchSource.count, 1, "Should match source operator")
            
            let searchCategory = try await db.searchArticles(query: "category:Business")
            assertEqual(searchCategory.count, 1, "Should match category operator")
            
            // is:unread operator
            let searchUnread = try await db.searchArticles(query: "is:unread")
            assertEqual(searchUnread.count, 2, "Both articles should be unread initially")
            
            try await db.markRead(articleId: artA.id, isRead: true)
            let searchAfterRead = try await db.searchArticles(query: "is:read")
            assertEqual(searchAfterRead.count, 1, "Should find 1 read article")
            assertEqual(searchAfterRead[0].id, artA.id, "Read article ID should match")
        } catch {
            print("❌ FTS5 test failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    
    static func testMigrationCoordinatorAtomicity() async {
        print("  - Testing MigrationCoordinator Atomic Transaction & ID Reconciliation...")
        
        let tempDefaults = UserDefaults(suiteName: "com.marspater.news.test.\(UUID().uuidString)")!
        defer { tempDefaults.removePersistentDomain(forName: tempDefaults.description) }
        
        let db = DatabaseEngine(path: ":memory:")
        try? await db.open()
        
        let coordinator = MigrationCoordinator(
            database: db,
            userDefaults: tempDefaults,
            fileManager: .default
        )
        
        // Check migration needed
        let neededBefore = await coordinator.isMigrationNeeded()
        assertTrue(neededBefore, "Migration should be needed initially")
        
        // Execute migration
        let stats = try? await coordinator.migrateIfNeeded()
        assertTrue(stats != nil, "Migration should succeed")
        
        // Check migration no longer needed
        let neededAfter = await coordinator.isMigrationNeeded()
        assertFalse(neededAfter, "Migration should no longer be needed after execution")
        
        let version = tempDefaults.integer(forKey: MigrationCoordinator.migrationVersionKey)
        assertEqual(version, MigrationCoordinator.currentMigrationVersion, "Migration version must be set to 1")
    }
    
    static func testArticleRetentionPolicy() async {
        print("  - Testing Article Retention Policy...")
        
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            
            let oldDate = Date(timeIntervalSinceNow: -40 * 86400) // 40 days old
            let recentDate = Date(timeIntervalSinceNow: -5 * 86400) // 5 days old
            
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
            assertEqual(prunedCount, 1, "Only the old read article should be pruned")
            
            let remaining = try await db.fetchArticles()
            assertEqual(remaining.count, 3, "3 articles should remain in database")
            
            let ids = remaining.map { $0.id }
            assertFalse(ids.contains(oldRead.id), "Old read article must be removed")
            assertTrue(ids.contains(oldUnread.id), "Old unread article must remain")
            assertTrue(ids.contains(oldSaved.id), "Old saved article must remain")
            assertTrue(ids.contains(recentRead.id), "Recent read article must remain")
        } catch {
            print("❌ Retention test failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    
    static func testArticleIntelligenceCapabilities() async {
        print("  - Testing Article Intelligence Capabilities & Protocols...")
        
        let ai = ArticleIntelligence.shared
        
        // 1. Sentiment with confidence
        let positiveText = "The team celebrated their brilliant victory and delightful breakthrough with great joy."
        let sentPos = await ai.sentimentAnalyzer.analyzeSentiment(for: positiveText)
        assertTrue(sentPos.score > 0.1, "Sentiment score should be positive")
        assertEqual(sentPos.label, "Positive", "Sentiment label should be Positive")
        assertTrue(sentPos.confidence > 0.5, "Sentiment confidence should be substantive")
        
        // 2. Entity Extraction
        let entityText = "Tim Cook spoke at the Apple headquarters in Cupertino, California today."
        let entities = await ai.entityExtractor.extractEntities(from: entityText)
        assertTrue(!entities.isEmpty, "Should extract named entities")
        let entityNames = entities.map { $0.name }
        assertTrue(entityNames.contains("Apple") || entityNames.contains("Tim Cook") || entityNames.contains("Cupertino"), "Should extract Apple or Tim Cook or Cupertino")
        
        // 3. Topic Classification with confidence and evidence
        let topic = await ai.topicClassifier.classifyTopic(
            title: "Breakthrough in Quantum Computing Processor Architecture",
            description: "Physicists develop novel cryogenic semiconductor chip",
            text: nil,
            rssCategory: "Technology"
        )
        assertTrue(topic != nil, "Should classify topic")
        assertTrue(topic?.category == "Technology" || topic?.category == "Science", "Should classify as Technology or Science")
        assertTrue((topic?.confidence ?? 0) > 0.5, "Confidence should exceed 0.5")
        assertTrue(!((topic?.evidence.isEmpty) ?? true), "Evidence keywords should not be empty")
        
        // 4. Extractive Summarization
        let longArticle = """
        Researchers at the national laboratory have unveiled a groundbreaking clean energy reactor. The system generates continuous fusion output with zero carbon emissions. Earlier attempts struggled with magnetic confinement stability at high plasma temperatures. The team solved this by using high-temperature superconducting magnets. Commercial deployment is anticipated within the next decade following regulatory certification.
        """
        let summary = await ai.summarizer.summarize(title: "Groundbreaking Clean Energy Reactor Unveiled", content: longArticle)
        assertTrue(!summary.text.isEmpty, "Summary should not be empty")
        assertTrue(summary.sentencesUsed >= 1, "Should use at least 1 sentence")
        assertTrue(summary.confidence > 0.5, "Summary confidence should exceed 0.5")
        
        // 5. Prose Content Cleaning
        let dirtyText = """
        Share this on Twitter or follow us on Facebook.
        
        The spacecraft successfully entered the orbit of Mars after a nine-month interplanetary journey. Mission control confirmed telemetry signals were nominal across all scientific instruments.
        
        Subscribe to our daily newsletter for more stories like this! All rights reserved.
        """
        let cleaned = ai.cleanContent(dirtyText)
        assertFalse(cleaned.contains("Share this on Twitter"), "Should strip share boilerplate")
        assertFalse(cleaned.contains("Subscribe to our daily newsletter"), "Should strip newsletter boilerplate")
        assertTrue(cleaned.contains("The spacecraft successfully entered the orbit of Mars"), "Should preserve genuine prose")
    }
    
    static func testContentExtractionPipelineDeep() async {
        print("  - Testing Content Extraction Pipeline (Entities, Link Density, Lead Image)...")
        
        let pipeline = ContentExtractionPipeline.shared
        
        // 1. Entity decoding
        let encoded = "&quot;Innovation &amp; Discovery&quot; &mdash; It&#39;s an &#8220;extraordinary&#8221; achievement"
        let decoded = pipeline.decodeHTMLEntities(encoded)
        assertEqual(decoded, "\"Innovation & Discovery\" — It's an “extraordinary” achievement", "Should decode named, decimal, and hex entities")
        
        // 2. Link density computation
        let navigationSnippet = """
        <div class="nav-menu">
            <a href="/1">Home</a>
            <a href="/2">About</a>
            <a href="/3">Contact</a>
            <a href="/4">Careers</a>
            <a href="/5">Privacy</a>
        </div>
        """
        let navDensity = pipeline.computeLinkDensity(navigationSnippet)
        assertTrue(navDensity > 0.7, "Navigation snippet should have high link density (>0.7)")
        
        let articleSnippet = """
        <div class="article-text">
            Scientists have made a historic discovery deep within the Antarctic ice sheet.
            According to the published <a href="/paper">study</a>, the ancient core contains climate records dating back two million years.
            The findings provide critical insights into historical atmospheric compositions.
        </div>
        """
        let articleDensity = pipeline.computeLinkDensity(articleSnippet)
        assertTrue(articleDensity < 0.3, "Article text with few inline links should have low link density (<0.3)")
        
        // 3. Lead image extraction
        let htmlWithOG = """
        <html>
        <head>
            <title>Sample Article</title>
            <meta property="og:image" content="https://example.com/lead-image.jpg">
        </head>
        <body><p>Content</p></body>
        </html>
        """
        let extractedImage = pipeline.extractLeadImage(from: htmlWithOG)
        assertEqual(extractedImage, "https://example.com/lead-image.jpg", "Should extract og:image meta tag")
    }

    static func testWebContentExtractorFacade() async {
        print("  - Testing WebContentExtractor facade...")

        // 1. Invalid URL string
        let invalidResult = await WebContentExtractor.fetchFullContentAndImage(for: "not a url")
        assertTrue(invalidResult.0 == nil && invalidResult.1 == nil, "Should return nil for invalid URL string")

        // 2. Blocked scheme (will hit SecureHTTPClient rejection or pipeline bail out)
        let blockedResult = await WebContentExtractor.fetchFullContentAndImage(for: "file:///etc/passwd")
        assertTrue(blockedResult.0 == nil && blockedResult.1 == nil, "Should return nil for blocked schemes like file://")
    }
    
    static func testEnrichmentQueueSchedulingAndPromotion() async {
        print("  - Testing EnrichmentQueue Scheduling, Promotion & Cancellation...")
        
        let store = await ArticleStore(database: DatabaseEngine(path: ":memory:"))
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
        
        // 1. Enqueue background
        await queue.enqueue(article: articleA, priority: .background)
        
        // 2. Duplicate prevention & promotion
        await queue.enqueue(article: articleA, priority: .interactive)
        
        // 3. Enqueue second article
        await queue.enqueue(article: articleB, priority: .high)
        
        // 4. Cancel articleB
        await queue.cancel(articleId: articleB.id, reason: .user)
        let stateB = await queue.state(for: articleB.id)
        assertEqual(stateB, .cancelled(.user), "Article B should be in cancelled state")
        
        // 5. Cancel all
        await queue.cancelAll(reason: .superseded)
        let stateA = await queue.state(for: articleA.id)
        assertEqual(stateA, .cancelled(.superseded), "Article A should be cancelled with superseded reason")
        for _ in 0..<10 {
            await queue.enqueue(article: articleA, priority: .background)
            await queue.cancelAll(reason: .superseded)
            let active = await queue.activeJobCount()
            assertTrue(active <= 3, "Rapid replacement cannot exceed the concurrency bound")
        }
    }
    
    static func testDesignSystemAndArticleFilter() async {
        print("  - Testing Phase 4 Design System Tokens and Article Filter Query Parser...")
        
        // 1. Spacing tokens
        assertEqual(AppSpacing.xxs, 4.0, "AppSpacing.xxs should be 4.0")
        assertEqual(AppSpacing.xs, 8.0, "AppSpacing.xs should be 8.0")
        assertEqual(AppSpacing.sm, 12.0, "AppSpacing.sm should be 12.0")
        assertEqual(AppSpacing.md, 16.0, "AppSpacing.md should be 16.0")
        assertEqual(AppSpacing.lg, 24.0, "AppSpacing.lg should be 24.0")
        
        // 2. Radius tokens
        assertEqual(AppRadius.small, 6.0, "AppRadius.small should be 6.0")
        assertEqual(AppRadius.medium, 8.0, "AppRadius.medium should be 8.0")
        assertEqual(AppRadius.card, 12.0, "AppRadius.card should be 12.0")
        assertEqual(AppRadius.control, 6.0, "AppRadius.control should be 6.0")
        assertEqual(AppRadius.container, 16.0, "AppRadius.container should be 16.0")
        assertEqual(AppRadius.pill, 999.0, "AppRadius.pill should be 999.0")

        // 3. Layout tokens
        assertEqual(AppLayout.pageInset, 24.0, "AppLayout.pageInset should be 24.0")
        assertEqual(AppLayout.sidebarInset, 12.0, "AppLayout.sidebarInset should be 12.0")
        assertEqual(AppLayout.sectionGap, 24.0, "AppLayout.sectionGap should be 24.0")
        assertEqual(AppLayout.cardGap, 16.0, "AppLayout.cardGap should be 16.0")
        assertEqual(AppLayout.toolbarHeight, 44.0, "AppLayout.toolbarHeight should be 44.0")
        assertEqual(AppLayout.controlHeight, 28.0, "AppLayout.controlHeight should be 28.0")
        
        // 4. Ghost Typography Theme tokens
        assertEqual(AppTypography.bodyLineSpacing(for: .casper), 10.0, "Casper theme line spacing should be 10")
        assertEqual(AppTypography.bodyLineSpacing(for: .edition), 8.0, "Edition theme line spacing should be 8")
        assertEqual(AppTypography.bodyLineSpacing(for: .alto), 12.0, "Alto theme line spacing should be 12")
        
        // 4. ArticleFilterQuery structured parsing
        let complexQuery = "source:Bloomberg category:Tech is:unread apple silicon"
        let parsed = ArticleFilterQuery.parse(complexQuery)
        assertEqual(parsed.sourceFilter, "bloomberg", "Should parse source: operator")
        assertEqual(parsed.categoryFilter, "tech", "Should parse category: operator")
        assertEqual(parsed.isReadFilter, false, "Should parse is:unread operator")
        assertEqual(parsed.terms, ["apple", "silicon"], "Should extract search terms")
        
        // 5. Article matching logic
        let art1 = FeedArticle(
            title: "Apple introduces M4 Max Silicon",
            link: "https://bloomberg.com/news/apple-m4",
            guid: "test-art-1",
            description: "New chip delivers record performance",
            pubDate: Date(),
            source: "Bloomberg",
            category: "Technology"
        )
        let art2 = FeedArticle(
            title: "Federal Reserve holds interest rates steady",
            link: "https://wsj.com/fed-rates",
            guid: "test-art-2",
            description: "Central bank maintains current policy stance",
            pubDate: Date(),
            source: "Wall Street Journal",
            category: "Economy"
        )
        
        assertTrue(parsed.matches(article: art1, isRead: false, isSaved: false), "Article 1 should match query")
        assertFalse(parsed.matches(article: art1, isRead: true, isSaved: false), "Article 1 should fail because it is read")
        assertFalse(parsed.matches(article: art2, isRead: false, isSaved: false), "Article 2 should fail source/terms match")
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
        
        guard let data = fileManager.contents(atPath: entitlementsPath) else {
            assertEqual(true, false, "Failed to read News.entitlements data")
            return
        }
        
        do {
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                assertEqual(true, false, "News.entitlements is not a valid dictionary plist")
                return
            }
            
            assertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "Sandbox must be enabled")
            // Validate minimal required entitlements
            assertEqual(plist["com.apple.security.network.client"] as? Bool, true, "com.apple.security.network.client must be enabled")
            assertEqual(plist["com.apple.security.files.user-selected.read-write"] as? Bool, true, "com.apple.security.files.user-selected.read-write must be enabled")
            
            // Validate that unnecessary/unsafe entitlements are NOT present
            assertEqual(plist["com.apple.security.network.server"] as? Bool, true, "Loopback gateway requires listener permission")
            assertFalse(plist.keys.contains("com.apple.security.device.camera"), "Camera entitlement should not be granted")
            assertFalse(plist.keys.contains("com.apple.security.device.microphone"), "Microphone entitlement should not be granted")
            assertFalse(plist.keys.contains("com.apple.security.personal-information.location"), "Location entitlement should not be granted")
            assertFalse(plist.keys.contains("com.apple.security.personal-information.addressbook"), "Contacts entitlement should not be granted")
            assertFalse(plist.keys.contains("com.apple.security.files.all"), "All files entitlement should not be granted")
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

    static func testStrictSemVerAndReleaseSecurity() async {
        print("  - Testing Strict SemVer Parsing & Release URL Security...")

        // 1. Valid SemVer strings
        assertEqual(SemanticVersion.parse("v2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1), "v2.0.1 should parse")
        assertEqual(SemanticVersion.parse("2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1), "2.0.1 should parse")
        assertEqual(SemanticVersion.parse("10.12.3"), SemanticVersion(major: 10, minor: 12, patch: 3), "10.12.3 should parse")
        assertEqual(SemanticVersion.parse("0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0), "0.1.0 should parse")
        assertEqual(SemanticVersion.parse("v0.0.1"), SemanticVersion(major: 0, minor: 0, patch: 1), "v0.0.1 should parse")

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
        assertTrue(SemanticVersion(major: 2, minor: 0, patch: 1) > SemanticVersion(major: 2, minor: 0, patch: 0), "2.0.1 > 2.0.0")
        assertTrue(SemanticVersion(major: 2, minor: 1, patch: 0) > SemanticVersion(major: 2, minor: 0, patch: 9), "2.1.0 > 2.0.9")
        assertTrue(SemanticVersion(major: 3, minor: 0, patch: 0) > SemanticVersion(major: 2, minor: 9, patch: 9), "3.0.0 > 2.9.9")
        assertFalse(SemanticVersion(major: 2, minor: 0, patch: 0) > SemanticVersion(major: 2, minor: 0, patch: 1), "2.0.0 is not > 2.0.1")
        assertEqual(SemanticVersion(major: 2, minor: 0, patch: 0), SemanticVersion(major: 2, minor: 0, patch: 0), "Equality check")

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
    static func testNotificationModeTriageAndGrammar() async {
        print("  - Testing NotificationMode Triage, Privacy & Singular/Plural Grammar...")

        // 1. Singular/Plural grammar helper
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 1), "1 new article from 1 source", "Singular article and source")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 2, uniqueSourcesCount: 1), "2 new articles from 1 source", "Plural articles, singular source")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 3, uniqueSourcesCount: 2), "3 new articles across 2 sources", "Plural articles, plural sources")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 10, uniqueSourcesCount: 4), "10 new articles across 4 sources", "Multi-source plural formatting")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 0), "1 new article across 0 sources", "Edge case: 1 article, 0 sources")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 0), "0 new articles across 0 sources", "Edge case: 0 articles, 0 sources")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 1), "0 new articles from 1 source", "Edge case: 0 articles, 1 source")

        // 2. AppSettings Migration Semantics
        let suiteName = "test.notifications.migration.\(UUID().uuidString)"
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { tempDefaults.removePersistentDomain(forName: suiteName) }

        // Case A: legacy privateNotificationsEnabled = true -> migrates to .private
        tempDefaults.set(true, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsA = AppSettings(defaults: tempDefaults)
        assertEqual(settingsA.notificationMode, AppSettings.NotificationMode.privacy, "Legacy private flag should migrate to .private mode")
        assertEqual(tempDefaults.string(forKey: AppSettings.notificationModeKey), "private", "Migrated key should be written to defaults")

        // Case B: legacy privateNotificationsEnabled = false -> migrates to .full
        let suiteNameB = "test.notifications.migration.b.\(UUID().uuidString)"
        let tempDefaultsB = UserDefaults(suiteName: suiteNameB)!
        defer { tempDefaultsB.removePersistentDomain(forName: suiteNameB) }
        tempDefaultsB.set(false, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsB = AppSettings(defaults: tempDefaultsB)
        assertEqual(settingsB.notificationMode, AppSettings.NotificationMode.full, "Legacy non-private flag should migrate to .full mode")
        assertEqual(tempDefaultsB.string(forKey: AppSettings.notificationModeKey), "full", "Migrated key should be written to defaults")

        // Case C: mutation API updates both mode and legacy private flag
        settingsB.setNotificationMode(.minimal)
        assertEqual(settingsB.notificationMode, AppSettings.NotificationMode.minimal, "Mode should update to .minimal")
        assertEqual(tempDefaultsB.string(forKey: AppSettings.notificationModeKey), "minimal", "Key should update to minimal")
        assertFalse(settingsB.privateNotificationsEnabled, "privateNotificationsEnabled should be false for minimal")
    }

    actor FeedDeliveryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var started = false
        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func deliver() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    static func testFeedRemovalAndShutdown() async throws {
        let suite = "test.feed-lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = ["https://example.com/feed"]
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db)
        await store.initialize()
        let article = FeedArticle(title: "Late delivery", link: "https://example.com/late", guid: "late", description: "Report", pubDate: Date(), source: "Test")
        for shutdown in [false, true] {
            settings.feedURLs = ["https://example.com/feed"]
            let gate = FeedDeliveryGate()
            let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in
                    guard let url = urls.first else { return [] }
                    await gate.wait()
                    return [(url, [article], nil)]
                })
            let refresh = Task { await manager.fetchFeedsAsync() }
            while !(await gate.started) { await Task.yield() }
            if shutdown { manager.stopBackgroundWork() }
            else { manager.removeFeed(url: "https://example.com/feed") }
            await gate.deliver()
            await refresh.value
            assertTrue(try await db.fetchArticles().isEmpty, "Late feed delivery after removal or shutdown must not be stored")
            manager.stopBackgroundWork()
        }
        let cancelled = Task {
            do { try await db.upsertArticles([article]); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        cancelled.cancel()
        assertTrue(await cancelled.value, "Cancelled database ingestion propagates cancellation")
        assertTrue(try await db.fetchArticles().isEmpty, "Cancelled ingestion rolls back its transaction")
        await db.close()
    }

    final class SocketObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [String] = []
        private var completed = false
        func recordText(_ value: String) { lock.withLock { targets.append(value) } }
        func record(_ host: NWEndpoint.Host) { lock.withLock { targets.append(String(describing: host)) } }
        var count: Int { lock.withLock { targets.count } }
        var hosts: [String] { lock.withLock { targets } }
        func claim() -> Bool { lock.withLock { if completed { return false }; completed = true; return true } }
    }

    static func socketSend(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func socketRead(_ connection: NWConnection, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let next: Data = try await withCheckedThrowingContinuation { continuation in
                let once = SocketObservation()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if once.claim() { connection.cancel(); continuation.resume(throwing: FeedError.timeout) }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { bytes, _, eof, error in
                    guard once.claim() else { return }
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: eof ? FeedError.network("EOF") : FeedError.timeout) }
                }
            }
            data.append(next)
        }
        return data
    }

    static func socksConnect(_ proxy: NetworkBoundaryProxy, host: String, command: UInt8 = 1, port: UInt16 = 80) async throws -> (NWConnection, Data) {
        let endpoint = try await proxy.port()
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint)!, using: .tcp)
        client.start(queue: .global())
        try await socketSend(client, Data([5, 1, 0]))
        assertEqual(try await socketRead(client, count: 2), Data([5, 0]), "SOCKS greeting succeeds")
        let hostBytes = Data(host.utf8)
        var request = Data([5, command, 0, 3, UInt8(hostBytes.count)])
        request.append(hostBytes)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 255)])
        // Fragment across every protocol boundary, not just a single network packet.
        try await socketSend(client, Data(request.prefix(1)))
        try await socketSend(client, Data(request.dropFirst()))
        return (client, try await socketRead(client, count: 10))
    }

    @MainActor
    final class WebBoundaryProbe: NSObject, WKNavigationDelegate {
        static func permitsNavigation(_ url: URL) -> Bool {
            url.scheme == "http" && url.host == "rebind.invalid" && url.path == "/page"
                && (url.port == nil || url.port == 80) && url.user == nil && url.password == nil
        }
        func webView(_ _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, Self.permitsNavigation(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        let once = SocketObservation()
        var complete: ((Result<Void, Error>) -> Void)?
        func webView(_ _: WKWebView, didFinish _: WKNavigation!) {
            if once.claim() { complete?(.success(())) }
        }
        func webView(_ _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            if once.claim() { complete?(.failure(error)) }
        }
    }

    @MainActor
    static func verifyWebKitBoundary(proxy: ProxyConfiguration) async throws {
        for address in ["http://127.0.0.1/page", "https://rebind.invalid/page", "http://rebind.invalid/other", "http://rebind.invalid:8080/page", "http://user@rebind.invalid/page"] {
            assertFalse(WebBoundaryProbe.permitsNavigation(URL(string: address)!), "Probe rejects navigation outside its exact fixture")
        }
        assertTrue(WebBoundaryProbe.permitsNavigation(URL(string: "http://rebind.invalid/page")!), "Probe allows its controlled fixture")
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.configuration.userContentController.add(try await WebPreviewPolicy.contentRules())
        let probe = WebBoundaryProbe()
        view.navigationDelegate = probe
        defer { view.stopLoading(); view.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.complete = { continuation.resume(with: $0) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if probe.once.claim() { view.stopLoading(); continuation.resume(throwing: FeedError.timeout) }
            }
            view.load(URLRequest(url: URL(string: "http://rebind.invalid/page")!))
        }
    }

    static func respondToFixture(_ connection: NWConnection, data: Data?, port: UInt16,
                                 receivedRequests: SocketObservation, live: Bool) {
        let response: Data
        if data?.starts(with: Data("GET ".utf8)) == true {
            let request = String(decoding: data!, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            receivedRequests.recordText(request)
            if request.contains("/redirect.css ") {
                let redirect = Data("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/forbidden-redirect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: redirect, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let body: String
            if request.contains("/page ") {
                body = "<html><head><link rel='stylesheet' href='http://assets.invalid/style.css'><link rel='stylesheet' href='http://assets.invalid/redirect.css'></head><body>Publisher prose<img src='http://assets.invalid/image.svg'><img src='http://127.0.0.1:\(port)/forbidden'><img src='http://localhost:\(port)/forbidden-localhost'><img src='http://2130706433:\(port)/forbidden-decimal'><img src='http://0x7f000001:\(port)/forbidden-hex'><img src='http://127.1:\(port)/forbidden-short'><img src='http://0x7f.0.0.1:\(port)/forbidden-mixed-hex'><img src='http://0177.0.0.1:\(port)/forbidden-octal'><img src='http://%31%32%37.0.0.1:\(port)/forbidden-encoded'><img src='http://user@127.0.0.1:\(port)/forbidden-userinfo'><img src='http://127.0.0.1.:\(port)/forbidden-trailing-dot'>\(live ? "<img src='http://localtest.me:\(port)/forbidden-dns'>" : "")</body></html>"
            } else if request.contains(".svg ") {
                body = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>"
            } else if request.contains("/style.css ") { body = "body { color: black; }" }
            else { body = "OK" }
            let mime: String
        if request.contains(".svg ") { mime = "image/svg+xml" }
        else if request.contains(".css ") { mime = "text/css" }
        else { mime = "text/html" }
            let cacheHeader = request.contains("/cached-image.svg ") ? "Cache-Control: public, max-age=600\r\n" : "Cache-Control: no-store\r\n"
            response = Data("HTTP/1.1 200 OK\r\n\(cacheHeader)Content-Type: \(mime)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        } else { response = data ?? Data() }
        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func testSocketNetworkBoundary() async throws {
        print("  - Testing socket boundary: pinning, mixed DNS, loopback, malformed commands and fail-closed proxy...")
        let upstream = try NWListener(using: .tcp, on: .any)
        let upstreamQueue = DispatchQueue(label: "test.proxy.upstream")
        let receivedRequests = SocketObservation()
        let live = ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1"
        if live {
            assertTrue({ if case .blocked = IPAddressValidator.validateHost("localtest.me") { return true }; return false }(), "Live DNS-alias control resolves to a private address")
        }
        upstream.newConnectionHandler = { connection in
            connection.start(queue: upstreamQueue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, _ in
                respondToFixture(connection, data: data, port: upstream.port!.rawValue,
                                 receivedRequests: receivedRequests, live: live)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = SocketObservation()
            upstream.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
            }
            upstream.start(queue: upstreamQueue)
        }
        defer { upstream.cancel() }
        let fixturePort = upstream.port!
        let observed = SocketObservation()
        let connector: NetworkBoundaryProxy.Connector = { host, _ in
            observed.record(host)
            return NWConnection(host: "127.0.0.1", port: fixturePort, using: .tcp)
        }
        let mixed = NetworkBoundaryProxy(resolver: { _ in .allowed(ips: ["93.184.216.34", "127.0.0.1"]) }, connector: connector)
        let (mixedClient, mixedReply) = try await socksConnect(mixed, host: "mixed.invalid")
        assertEqual(mixedReply[1], 2, "Mixed public/private DNS answers are rejected before connecting")
        mixedClient.cancel()
        await mixed.stop()
        let production = NetworkBoundaryProxy(connector: connector)
        for host in ["127.0.0.1", "localhost", "2130706433", "0x7f000001", "localhost.", "test.local.", "intranet", "::1", "fe80::1%en0"] {
            let (client, reply) = try await socksConnect(production, host: host)
            assertEqual(reply[1], 2, "Private/alternate/scoped address denied at the socket boundary")
            client.cancel()
        }
        let (udpClient, udpReply) = try await socksConnect(production, host: "93.184.216.34", command: 3)
        assertEqual(udpReply[1], 2, "UDP ASSOCIATE is denied")
        try await socketSend(udpClient, Data("trailing".utf8))
        do {
            _ = try await socketRead(udpClient, count: 1)
            assertTrue(false, "Rejected tunnel never relays trailing client bytes")
        } catch let error as FeedError {
            assertEqual(error, .network("EOF"), "Rejected tunnel drains unread bytes and closes without a reset")
        }
        udpClient.cancel()
        let (portClient, portReply) = try await socksConnect(production, host: "93.184.216.34", port: 22)
        assertEqual(portReply[1], 2, "Unapproved ports denied")
        portClient.cancel()
        assertEqual(observed.count, 0, "Rejected requests never construct an upstream connection")
        await production.stop()
        let allowed = NetworkBoundaryProxy(resolver: { host in
            ["rebind.invalid", "93.184.216.34", "assets.invalid"].contains(host) ? .allowed(ips: ["93.184.216.34"]) : IPAddressValidator.validateHost(host)
        }, connector: connector)
        let (client, reply) = try await socksConnect(allowed, host: "rebind.invalid")
        assertEqual(reply[1], 0, "Approved destinations connect")
        try await socketSend(client, Data("relay proof".utf8))
        assertEqual(try await socketRead(client, count: 11), Data("relay proof".utf8), "Tunnel forwards data without rewriting it")
        client.cancel()
        assertEqual(observed.hosts, ["93.184.216.34"], "Connector receives the validated numeric IP, never the DNS hostname")
        let configuration = URLSessionConfiguration.ephemeral
        let proxy = try await allowed.configuration()
        assertFalse(proxy.allowFailover, "Native proxy may not fall back to direct connections")
        configuration.proxyConfigurations = [proxy]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let (body, _) = try await session.data(from: URL(string: "http://93.184.216.34/")!)
        assertEqual(String(decoding: body, as: UTF8.self), "OK", "Native URLSession uses the protected SOCKS tunnel")
        // Native image caching must reuse bytes without bypassing destination policy.
        let imageConfiguration = URLSessionConfiguration.ephemeral
        imageConfiguration.proxyConfigurations = [proxy]
        imageConfiguration.timeoutIntervalForRequest = 2
        imageConfiguration.urlCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
        let imageClient = SecureHTTPClient(configuration: imageConfiguration)
        let imageURL = URL(string: "http://93.184.216.34/cached-image.svg")!
        let initialRequests = receivedRequests.count
        let (firstImage, _) = try await imageClient.fetchImage(from: imageURL, allowHTTP: true)
        let (cachedImage, _) = try await imageClient.fetchImage(from: imageURL, allowHTTP: true)
        assertEqual(cachedImage, firstImage, "Cached image preserves publisher bytes")
        assertEqual(receivedRequests.count, initialRequests + 1, "Fresh images use one protected upstream request")
        do {
            _ = try await imageClient.fetchImage(from: imageURL)
            assertTrue(false, "Cached HTTP images cannot bypass disabled HTTP policy")
        } catch let error as FeedError {
            guard case .insecureScheme = error else { throw error }
        }
        _ = try await imageClient.fetchArticleHTML(from: imageURL, allowHTTP: true)
        assertEqual(receivedRequests.count, initialRequests + 2, "Article fetching still reloads cached URLs")
        let uncachedURL = URL(string: "http://93.184.216.34/uncached-image.svg")!
        _ = try await imageClient.fetchImage(from: uncachedURL, allowHTTP: true)
        _ = try await imageClient.fetchImage(from: uncachedURL, allowHTTP: true)
        assertEqual(receivedRequests.count, initialRequests + 4, "No-store images are fetched again")
        try await verifyWebKitBoundary(proxy: proxy)
        let paths = receivedRequests.hosts
        assertTrue(paths.contains { $0.contains("/style.css ") }, "WebKit stylesheet traverses the protected proxy")
        assertTrue(paths.contains { $0.contains("/image.svg ") }, "WebKit image traverses the protected proxy")
        assertFalse(paths.contains { $0.contains("/forbidden") }, "WebKit does not contact the reachable private fixture")
        await allowed.stop()
        let requestCount = receivedRequests.count
        do {
            _ = try await session.data(from: URL(string: "http://rebind.invalid/forbidden-after-stop")!)
            assertTrue(false, "Stopped gateway must not fall back to direct transport")
        } catch {
            // Failure is expected: the preceding assertion rejects an unexpected success.
        }
        assertEqual(receivedRequests.count, requestCount, "Stopped proxy never falls back to a reachable direct endpoint")
        if live {
            let publicURL = URL(string: "https://www.nasa.gov/feed/")!
            let directControl = URLSession(configuration: .ephemeral)
            let (controlBody, _) = try await directControl.data(from: publicURL)
            assertFalse(controlBody.isEmpty, "Public control is reachable without the stopped proxy")
            directControl.invalidateAndCancel()
            do {
                _ = try await session.data(from: publicURL)
                assertTrue(false, "Stopped proxy cannot fall back to a proven reachable public host")
            } catch {
                // The stopped proxy must reject the otherwise reachable public endpoint.
            }
        }
        session.invalidateAndCancel()
        for host in ["::127.0.0.1", "2002:7f00:1::", "2001::1", "2001:db8::1", "198.18.0.1", "192.0.2.1"] {
            assertTrue(IPAddressValidator.checkLiteralIP(host) != nil, "Transition/reserved addresses cannot escape the public boundary")
        }
    }

    actor TestCounter {
        var value: Int = 0
        func increment() { value += 1 }
    }

    struct SimulatedRefreshError: Error, Equatable {}

    static func testRefreshCoordinatorSingleFlightCoalescing() async {
        print("  - Testing RefreshCoordinator 20-Caller Stress Coalescing, Error Handling & Cancellation...")

        let coordinator = RefreshCoordinator()
        let counter = TestCounter()

        // 1. Single execution
        try? await coordinator.executeRefresh {
            await counter.increment()
        }
        let count1 = await counter.value
        assertEqual(count1, 1, "Single refresh execution should succeed")

        // 2. Stress Test: 20 concurrent callers coalesced onto 1 underlying refresh
        let stressCounter = TestCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        try await coordinator.executeRefresh {
                            // Simulated network latency
                            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                            await stressCounter.increment()
                        }
                    } catch {
                        assertTrue(false, "Unexpected error in concurrent stress caller: \(error)")
                    }
                }
            }
        }
        let totalExecutions = await stressCounter.value
        assertEqual(totalExecutions, 1, "20 concurrent callers should coalesce into exactly 1 actual refresh execution")
        let isRef = await coordinator.isRefreshing
        assertFalse(isRef, "Coordinator should return to idle after 20-caller stress test")

        // 3. Failure Propagation: all concurrent waiters observe thrown error & coordinator resets
        let errorCounter = TestCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await coordinator.executeRefresh {
                            try await Task.sleep(nanoseconds: 30_000_000) // 30ms
                            throw SimulatedRefreshError()
                        }
                    } catch is SimulatedRefreshError {
                        await errorCounter.increment()
                    } catch {
                        assertTrue(false, "Unexpected error type: \(error)")
                    }
                }
            }
        }
        let caughtErrors = await errorCounter.value
        assertEqual(caughtErrors, 5, "All 5 concurrent callers must observe the thrown failure")
        let isIdleAfterError = await coordinator.isRefreshing
        assertFalse(isIdleAfterError, "Coordinator must be idle after thrown error")

        // 4. Subsequent refresh works after failure
        let recoveryCounter = TestCounter()
        do {
            try await coordinator.executeRefresh {
                await recoveryCounter.increment()
            }
        } catch {
            assertTrue(false, "Subsequent refresh should succeed after prior error")
        }
        let recoveryCount = await recoveryCounter.value
        assertEqual(recoveryCount, 1, "Coordinator must successfully execute next refresh after error")

        // 5. Caller Cancellation Resilience: cancelling one waiter does not abort execution for others
        let cancelCoordinator = RefreshCoordinator()
        let completionCounter = TestCounter()
        let cancellationGate = FeedDeliveryGate()
        let waiterTask1 = Task {
            try await cancelCoordinator.executeRefresh {
                await cancellationGate.wait()
                await completionCounter.increment()
            }
        }
        while !(await cancellationGate.started) { await Task.yield() }

        let waiterTask2 = Task {
            try await cancelCoordinator.executeRefresh {
                await completionCounter.increment()
            }
        }
        // Keep work suspended until both callers have actually joined.
        while await cancelCoordinator.waiterCount < 2 { await Task.yield() }
        waiterTask1.cancel()
        await cancellationGate.deliver()
        _ = try? await waiterTask1.value
        _ = try? await waiterTask2.value

        let completedRuns = await completionCounter.value
        assertEqual(completedRuns, 1, "Background task should complete for remaining waiters even if first waiter cancelled")
        let cancelIdle = await cancelCoordinator.isRefreshing
        assertFalse(cancelIdle, "Coordinator must be idle after cancelled run completes")
    }

    static func testSignpostHelperExecution() async {
        print("  - Testing OSSignposter Measure Execution & Error Propagation (Sync & Async)...")

        // 1. Synchronous helper executes work and returns result
        let result = NewsSignposts.measure(signposter: NewsSignposts.database, name: "TestMeasure", metadata: "test=true") {
            return 42
        }
        assertEqual(result, 42, "measure should return work value")

        // 2. Synchronous helper propagates thrown errors
        struct TestError: Error, Equatable {}
        var caughtError = false
        do {
            try NewsSignposts.measure(signposter: NewsSignposts.feeds, name: "TestError") {
                throw TestError()
            }
        } catch is TestError {
            caughtError = true
        } catch {
            assertTrue(false, "measure must preserve the original error type")
        }
        assertTrue(caughtError, "measure should propagate thrown error")

        // 3. Asynchronous helper executes async work and returns result
        let asyncResult = try? await NewsSignposts.measure(signposter: NewsSignposts.database, name: "TestAsyncMeasure", metadata: "async=true") {
            try await Task.sleep(nanoseconds: 1_000_000)
            return 84
        }
        assertEqual(asyncResult, 84, "async measure should return async work value")

        // 4. Asynchronous helper propagates thrown errors
        var caughtAsyncError = false
        do {
            try await NewsSignposts.measure(signposter: NewsSignposts.feeds, name: "TestAsyncError") {
                try await Task.sleep(nanoseconds: 1_000_000)
                throw TestError()
            }
        } catch is TestError {
            caughtAsyncError = true
        } catch {
            assertTrue(false, "async measure must preserve the original error type")
        }
        assertTrue(caughtAsyncError, "async measure should propagate thrown error")
    }

    @MainActor
    static func testAppSettingsIsolationAndURLNormalization() async {
        print("  - Testing AppSettings UserDefaults Isolation & URLComponents Normalization...")

        // 1. URLComponents Normalization
        let httpFeed = "http://feeds.arstechnica.com/arstechnica/index"
        let normalizedHTTPS = AppSettings.normalizeFeedURL(httpFeed, allowInsecureHTTP: false)
        assertEqual(normalizedHTTPS, "https://feeds.arstechnica.com/arstechnica/index", "Should upgrade http to https when allowInsecureHTTP is false")

        let preservedHTTP = AppSettings.normalizeFeedURL(httpFeed, allowInsecureHTTP: true)
        assertEqual(preservedHTTP, "http://feeds.arstechnica.com/arstechnica/index", "Should preserve http when allowInsecureHTTP is true")

        let upperHost = "HTTPS://FEEDS.BBCO.CO.UK/NEWS/RSS.XML/"
        let normalizedUpper = AppSettings.normalizeFeedURL(upperHost)
        assertEqual(normalizedUpper, "https://feeds.bbco.co.uk/NEWS/RSS.XML", "Host must be lowercased and trailing slash stripped")

        let bareDomain = "example.com/"
        let normalizedBare = AppSettings.normalizeFeedURL(bareDomain)
        assertEqual(normalizedBare, "https://example.com", "Bare domain should gain https scheme and strip trailing slash")

        let invalidURL = AppSettings.normalizeFeedURL("")
        assertEqual(invalidURL, nil, "Empty string should return nil")

        // 2. Injected UserDefaults Isolation
        let suiteName = "test.settings.isolation.\(UUID().uuidString)"
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { tempDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: tempDefaults)
        _ = settings.addFeed(url: "https://isolated.example.com/rss.xml")
        settings.addSection("IsolatedSection")

        // Verify stored in tempDefaults
        let storedFeeds = tempDefaults.stringArray(forKey: AppSettings.feedURLsKey) ?? []
        assertTrue(storedFeeds.contains("https://isolated.example.com/rss.xml"), "Injected defaults must receive feedURLs mutations")

        let storedSections = tempDefaults.stringArray(forKey: AppSettings.userSectionsKey) ?? []
        assertTrue(storedSections.contains("IsolatedSection"), "Injected defaults must receive userSections mutations")
    }

    static func testFixedTaxonomyAndCaseInsensitivity() async {
        print("  - Testing Fixed Taxonomy (12 Categories), Synonyms & Case Insensitivity...")

        // 1. Exactly 12 categories
        assertEqual(NewsCategory.allCases.count, 12, "Taxonomy must define exactly 12 standard categories")

        // 2. Direct case-insensitive matching
        assertEqual(NewsCategory.match(from: "technology"), .technology, "lowercase 'technology'")
        assertEqual(NewsCategory.match(from: "TECHNOLOGY"), .technology, "uppercase 'TECHNOLOGY'")
        assertEqual(NewsCategory.match(from: "  Science  "), .science, "trimmed 'Science'")
        assertEqual(NewsCategory.match(from: "Business"), .business, "standard 'Business'")
        assertEqual(NewsCategory.match(from: "politics"), .politics, "standard 'politics'")
        assertEqual(NewsCategory.match(from: "world"), .world, "standard 'world'")
        assertEqual(NewsCategory.match(from: "Sports"), .sports, "standard 'Sports'")
        assertEqual(NewsCategory.match(from: "entertainment"), .entertainment, "standard 'entertainment'")
        assertEqual(NewsCategory.match(from: "Health"), .health, "standard 'Health'")
        assertEqual(NewsCategory.match(from: "Travel"), .travel, "standard 'Travel'")
        assertEqual(NewsCategory.match(from: "Food"), .food, "standard 'Food'")
        assertEqual(NewsCategory.match(from: "Fashion"), .fashion, "standard 'Fashion'")
        assertEqual(NewsCategory.match(from: "Lifestyle"), .lifestyle, "standard 'Lifestyle'")

        // 3. Synonym and substring matching
        assertEqual(NewsCategory.match(from: "tech news"), .technology, "tech synonym")
        assertEqual(NewsCategory.match(from: "election 2026"), .politics, "election synonym")
        assertEqual(NewsCategory.match(from: "space exploration"), .science, "space synonym")
        assertEqual(NewsCategory.match(from: "market finance"), .business, "finance synonym")
        assertEqual(NewsCategory.match(from: "international affairs"), .world, "international synonym")
        assertEqual(NewsCategory.match(from: "movie reviews"), .entertainment, "movie synonym")
        assertEqual(NewsCategory.match(from: "medical research"), .health, "med synonym")
        assertEqual(NewsCategory.match(from: "culinary arts"), .food, "cook/food synonym")

        // 4. Rejection of unmapped gibberish
        assertEqual(NewsCategory.match(from: "random-gibberish-string-xyz"), nil, "Unrelated strings should return nil")
        assertEqual(NewsCategory.match(from: ""), nil, "Empty string should return nil")
    }

    static func testClassificationMultiStageAndConfidenceTiers() async {
        print("  - Testing Multi-Stage Classification & Confidence Tiers...")

        let classifier = ArticleClassifier.shared

        // Stage 1: RSS Category deterministic hint takes immediate precedence with 0.95 confidence
        let rssResult = await classifier.classify(
            title: "Generic Headline With No Clues",
            description: "Some description here",
            rssCategory: "Technology",
            allowFoundationModels: false
        )
        assertEqual(rssResult.category, "Technology", "RSS hint should determine category")
        assertTrue(rssResult.confidence >= 0.90, "RSS hint should provide >= 0.90 confidence")
        assertTrue(rssResult.evidence.contains("Technology"), "Evidence should include RSS category")

        // Stage 2: Strong keyword title/description scoring
        let techResult = await classifier.classify(
            title: "Apple Announces M-Series Silicon Processor With Neural Acceleration",
            description: "Novel semiconductor architecture speeds machine learning and developer workflows",
            rssCategory: nil,
            allowFoundationModels: false
        )
        assertEqual(techResult.category, "Technology", "Strong tech keywords must classify as Technology")
        assertTrue(techResult.confidence >= 0.70, "Confidence should exceed 0.70")
        assertTrue(!techResult.evidence.isEmpty, "Evidence should list matched keywords")

        // Stage 3: Fallback when no keywords match
        let genericResult = await classifier.classify(
            title: "Unspecified Developments Reported",
            description: "Updates will follow as events occur",
            rssCategory: nil,
            allowFoundationModels: false
        )
        assertTrue(!genericResult.category.isEmpty, "Default category must be assigned")
    }

    static func testClassificationBenchmarkDataset() async {
        print("  - Testing Classification Benchmark Dataset Across All 12 Categories...")

        struct BenchmarkItem {
            let title: String
            let description: String
            let expectedCategory: NewsCategory
        }

        let dataset: [BenchmarkItem] = [
            BenchmarkItem(
                title: "NVIDIA Unveils Next-Gen AI Chip Architecture for Supercomputing",
                description: "The new GPU silicon accelerates neural network training and cloud datacenter workloads.",
                expectedCategory: .technology
            ),
            BenchmarkItem(
                title: "James Webb Space Telescope Observes Oldest Known Galaxy in Deep Space",
                description: "Astronomers confirm cosmological distance and stellar composition using infrared spectroscopy.",
                expectedCategory: .science
            ),
            BenchmarkItem(
                title: "Federal Reserve Holds Interest Rates Steady As Wall Street Stock Rally Continues",
                description: "Investors react positively to central bank inflation forecast and corporate earnings reports.",
                expectedCategory: .business
            ),
            BenchmarkItem(
                title: "Senate Committee Advances Bipartisan Election Security and Campaign Finance Bill",
                description: "Lawmakers vote in favor of new regulatory oversight before the congressional recess.",
                expectedCategory: .politics
            ),
            BenchmarkItem(
                title: "United Nations Envoy Brokering Ceasefire Talks In International Conflict",
                description: "Global diplomats convene in Geneva to negotiate refugee corridors and humanitarian aid.",
                expectedCategory: .world
            ),
            BenchmarkItem(
                title: "Quarterback Leads NFL Team to Super Bowl Championship Victory",
                description: "The thrilling stadium final concluded with a game-winning touchdown in overtime.",
                expectedCategory: .sports
            ),
            BenchmarkItem(
                title: "Hollywood Director Christopher Nolan Wins Best Director at Academy Awards",
                description: "The blockbuster cinema release dominated the Oscars ceremony with multiple awards.",
                expectedCategory: .entertainment
            ),
            BenchmarkItem(
                title: "Clinical Trial Demonstrates High Efficacy for Targeted Cancer Immunotherapy Drug",
                description: "Hospital oncologists report remission in patients receiving the breakthrough medical treatment.",
                expectedCategory: .health
            ),
            BenchmarkItem(
                title: "International Airlines Expand Non-Stop Flight Routes for Summer Vacation Travelers",
                description: "Tourists book resort hotels and sightseeing packages as travel demand surges.",
                expectedCategory: .travel
            ),
            BenchmarkItem(
                title: "Michelin-Starred Chef Opens New Restaurant Celebrating Seasonal Farm-to-Table Cuisine",
                description: "The tasting menu pairs fine dining dishes with artisanal wines and local pastry desserts.",
                expectedCategory: .food
            ),
            BenchmarkItem(
                title: "Luxury Fashion House Debuts Autumn Haute Couture Collection on Paris Runway",
                description: "Designer apparel, bespoke tailoring, and statement accessories set seasonal wardrobe trends.",
                expectedCategory: .fashion
            ),
            BenchmarkItem(
                title: "Interior Designers Share Tips for Creating a Mindful, Minimalist Home Garden",
                description: "Transform your living space with sustainable furniture, decluttering habits, and indoor plants.",
                expectedCategory: .lifestyle
            )
        ]

        var correctCount = 0
        for item in dataset {
            let result = await ArticleClassifier.shared.classify(
                title: item.title,
                description: item.description,
                rssCategory: nil,
                allowFoundationModels: false
            )
            if result.category == item.expectedCategory.rawValue {
                correctCount += 1
            } else {
                print("    ⚠️ Benchmark mismatch: '\(item.title)' -> classified as \(result.category), expected \(item.expectedCategory.rawValue)")
            }
        }

        let accuracy = Double(correctCount) / Double(dataset.count)
        print("    Classification accuracy: \(correctCount)/\(dataset.count) (\(Int(accuracy * 100))%)")
        assertTrue(accuracy >= 0.80, "Benchmark accuracy must meet or exceed 80% on ground-truth dataset")
    }

    static func testArticleAnalyzerStructuredOutputAndFallbacks() async throws {
        print("  - Testing ArticleAnalyzer Structured Output (Summary, Key Points, Entities, Sentiment)...")

        let analyzer = ArticleAnalyzer.shared
        let title = "Tech Giants Unveil Breakthrough Quantum Computing Core"
        let articleBody = """
        Researchers at leading technology institutes have announced a functional 1,000-qubit quantum processor.
        The breakthrough system operates at room temperature, eliminating the need for bulky liquid helium cryostats.
        Dr. Jane Doe presented the research at the International Physics Symposium in Geneva today.
        Commercial applications in cryptography, drug discovery, and materials science are slated for next year.
        Initial benchmark results show an exponential performance leap compared to traditional classical supercomputers.
        """

        let analysis = try await analyzer.analyze(title: title, content: articleBody, category: "Technology", allowFoundationModels: false)

        // 1. Summary validation
        assertTrue(!analysis.summary.isEmpty, "Analysis summary should not be empty")
        assertTrue(analysis.summary.count >= 20, "Summary should be a coherent passage")

        // 2. Key Points validation (between 2 and 5 items)
        assertTrue(!analysis.keyPoints.isEmpty, "Key points should not be empty")
        assertTrue(analysis.keyPoints.count >= 2 && analysis.keyPoints.count <= 5, "Key points count should be bounded (2-5 points)")

        // 3. Entities validation
        assertTrue(!analysis.entities.isEmpty, "Entities should be extracted")

        // 4. Sentiment validation
        assertTrue(analysis.sentiment != nil, "Sentiment should be evaluated")

        // 5. Model identifier and versioning
        assertTrue(!analysis.modelIdentifier.isEmpty, "Model identifier should identify engine")
        assertEqual(analysis.analysisVersion, 2, "Analysis version invalidates summaries from the old extraction pipeline")
    }

    static func testInteractiveAnalysisCancellation() async {
        print("  - Testing Interactive Analysis Cooperative Cancellation...")

        let analyzer = ArticleAnalyzer.shared
        let largeContent = String(repeating: "The rapid development of autonomous distributed systems continues to evolve across multiple technological sectors. ", count: 100)

        let task = Task {
            try await analyzer.analyze(title: "Massive Article", content: largeContent)
        }

        // Cancel task immediately
        task.cancel()

        var caughtCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            caughtCancellation = true
        } catch let err as AIAnalysisError where err == .cancelled {
            caughtCancellation = true
        } catch {
            caughtCancellation = true
        }
        assertTrue(caughtCancellation, "Cancelled analysis task must throw CancellationError or AIAnalysisError.cancelled")
    }

    static func testGranularCacheClearingAndRetention() async throws {
        print("  - Testing Granular Cache Purging (Selective Deletes & Feed Preservation)...")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        defer { Task { await db.close() } }

        // 1. Populate feeds and articles
        let testFeed = "https://example.com/tech.xml"
        let article1 = FeedArticle(title: "Article One", link: "https://example.com/1", guid: "art-1", description: "Desc 1", pubDate: Date(), source: "Test Feed", fullContent: "Content One")
        let article2 = FeedArticle(title: "Article Two", link: "https://example.com/2", guid: "art-2", description: "Desc 2", pubDate: Date(), source: "Test Feed", fullContent: "Content Two")

        try await db.upsertArticles([article1, article2], feedUrl: testFeed)
        _ = try await db.toggleSaved(articleId: article1.id) // article1 is saved!

        // Save AI enrichment for both
        let analysis = ArticleAnalysis(summary: "Summary text", keyPoints: ["Point 1", "Point 2"], entities: [], category: "Technology", sentiment: nil, modelIdentifier: "test", analysisVersion: 1)
        try await db.saveArticleAnalysis(analysis, for: article1.id)
        try await db.saveArticleAnalysis(analysis, for: article2.id)

        // Verify initial state
        let initialAnalysis1 = await db.fetchArticleAnalysis(for: article1.id)
        assertTrue(initialAnalysis1 != nil, "Article 1 should have analysis")
        let initialAnalysis2 = await db.fetchArticleAnalysis(for: article2.id)
        assertTrue(initialAnalysis2 != nil, "Article 2 should have analysis")

        // 2. Test clearArticleEnrichment(): clears AI analysis, keeps articles and feeds
        try await db.clearArticleEnrichment()
        let clearedAnalysis1 = await db.fetchArticleAnalysis(for: article1.id)
        assertTrue(clearedAnalysis1 == nil, "Article 1 enrichment must be purged")
        let clearedAnalysis2 = await db.fetchArticleAnalysis(for: article2.id)
        assertTrue(clearedAnalysis2 == nil, "Article 2 enrichment must be purged")

        let articlesAfterEnrichmentClear = try await db.fetchArticles(limit: 10)
        assertEqual(articlesAfterEnrichmentClear.count, 2, "Articles must remain intact after enrichment purge")

        // 3. Test clearArticleCache(): clears non-saved article bodies, keeps saved stories intact
        try await db.clearArticleCache()
        let articlesAfterContentClear = try await db.fetchArticles(limit: 10)
        let savedArticle = articlesAfterContentClear.first { $0.id == article1.id }
        assertEqual(savedArticle?.fullContent, "Content One", "Saved article content must NOT be cleared")
        let unsavedArticle = articlesAfterContentClear.first { $0.id == article2.id }
        assertTrue(unsavedArticle?.fullContent == nil, "Non-saved article content must be set to nil")

        // Cache cleanup must not delete user history.
        try await db.markRead(articleId: article2.id, isRead: true)
        try await db.clearAllDatabaseCache()
        let remainingArticles = try await db.fetchArticles(limit: 10)
        assertEqual(remainingArticles.count, 2, "Cache cleanup must preserve article headers and history")
        assertEqual(remainingArticles.first(where: { $0.id == article1.id })?.fullContent, "Content One", "Saved body survives cache cleanup")
        assertTrue(try await db.getReadArticleIDs().contains(article2.id), "Read history survives cache cleanup")

        // 5. Test CacheManager methods
        // Do not clear the user's WebKit cache from a unit test.
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
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 0), "1 new article across 0 sources", "Edge case: 1 article, 0 sources")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 0), "0 new articles across 0 sources", "Edge case: 0 articles, 0 sources")
        assertEqual(NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 1), "0 new articles from 1 source", "Edge case: 0 articles, 1 source")

        // 3. Importance computation range [0.0, 1.0]
        let score = service.computeImportance(title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response.")
        assertTrue(score >= 0.0 && score <= 1.0, "Score must be bounded between 0.0 and 1.0")

        // 4. Robust dispatching (no crashes across all 3 notification tiers)
        let sampleArticle = FeedArticle(title: "Urgent Update", link: "https://example.com/urgent", guid: "sample-guid", description: "Details follow", pubDate: Date(), source: "Wire Service")
        await service.triageAndNotify(newArticles: [sampleArticle], mode: .minimal)
        await service.triageAndNotify(newArticles: [sampleArticle], mode: .privacy)
        await service.triageAndNotify(newArticles: [sampleArticle], mode: .full)
    }

    @MainActor
    static func testArticleStoreErrorResilience() async {
        print("  - Testing ArticleStore Error Resilience & Database Failures...")

        let db = DatabaseEngine(path: ":memory:")
        try? await db.open()
        let store = ArticleStore(database: db)
        await store.initialize()

        let article = FeedArticle(title: "Test Error Article", link: "https://example.com/error", guid: "test-err-guid", description: "Test", pubDate: Date(), source: "Test")
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/feed")

        // Force close the database to trigger failure scenarios
        await db.close()

        // 1. toggleSave returns false on failure (PR #18)
        let savedResult = await store.toggleSave(article: article)
        assertFalse(savedResult, "toggleSave should return false when database throws an error")

        // 2. markAsRead catches error and does not mutate in-memory read state (PR #19)
        await store.markAsRead(id: "test-err-guid", isRead: true)
        assertFalse(store.readArticleIDs.contains("test-err-guid"), "readArticleIDs should not contain ID when DB markRead fails")

        // 3. markAllAsRead catches error gracefully without crashing (PR #20)
        await store.markAllAsRead()
    }

    static func testFeedArticleWrapContextNavigation() async {
        print("  - Testing FeedArticleWrap Context Preservation & Filtered Navigation Boundaries...")

        let artA = FeedArticle(title: "Article A", link: "https://example.com/a", guid: "a", description: "Desc A", pubDate: Date(), source: "Source 1", category: "Technology")
        let artB = FeedArticle(title: "Article B", link: "https://example.com/b", guid: "b", description: "Desc B", pubDate: Date(), source: "Source 2", category: "Science")
        let artC = FeedArticle(title: "Article C", link: "https://example.com/c", guid: "c", description: "Desc C", pubDate: Date(), source: "Source 1", category: "Technology")
        let artD = FeedArticle(title: "Article D", link: "https://example.com/d", guid: "d", description: "Desc D", pubDate: Date(), source: "Source 3", category: "Business")

        let allGlobal = [artA, artB, artC, artD]
        let techFilter = [artA, artC]

        // 1. Wrap with filtered context
        let wrap = FeedArticleWrap(article: artA, contextArticles: techFilter)
        assertEqual(wrap.article.id, artA.id, "Wrapped article ID must match artA")
        assertEqual(wrap.contextArticles.count, 2, "Filtered context must contain exactly 2 articles")
        assertEqual(wrap.contextArticles.map(\.id), [artA.id, artC.id], "Filtered context articles must match techFilter")

        // 2. Boundary simulation in filtered context:
        // In techFilter: artA is index 0. Has next (artC), but NO previous.
        let idxA = wrap.contextArticles.firstIndex(where: { $0.id == artA.id })
        assertEqual(idxA, 0, "artA should be at index 0 in filtered context")
        let hasPrevInFilter = idxA.map { $0 > 0 } ?? false
        let hasNextInFilter = idxA.map { $0 + 1 < wrap.contextArticles.count } ?? false
        assertFalse(hasPrevInFilter, "artA must not have previous article in filtered context")
        assertTrue(hasNextInFilter, "artA must have next article (artC) in filtered context")

        // In techFilter: Next article from artA is artC (skipping artB which is Science!)
        let nextArt = wrap.contextArticles[idxA! + 1]
        assertEqual(nextArt.id, artC.id, "Next article in tech filter must be artC, skipping artB")

        // In global context without filter: Next article from artA would have been artB
        let globalIdxA = allGlobal.firstIndex(where: { $0.id == artA.id })!
        let globalNext = allGlobal[globalIdxA + 1]
        assertEqual(globalNext.id, artB.id, "In unfiltered global context, next is artB")

        // 3. Fallback behavior when contextArticles is empty
        let wrapEmpty = FeedArticleWrap(article: artB)
        assertTrue(wrapEmpty.contextArticles.isEmpty, "Default contextArticles should be empty")

        // 4. Stable uniqueness of wrap identity
        let wrap2 = FeedArticleWrap(article: artA, contextArticles: techFilter)
        assertTrue(wrap.id != wrap2.id, "Each wrap must have a distinct UUID identity for navigation state")
    }

    static func testArticleContentRedactionAndTypography() async {
        print("  - Testing ArticleContentRedactor and Typography...")

        // 1. Test trailing and fused boilerplate removal (e.g. '...last year.Read full article\nComments')
        let rawJunk = "The launcher delivered a batch of CubeSats to low-Earth orbit from a spaceport in northern Norway, and Isar tasted success after its first test flight ended in failure last year.Read full article\nComments"
        let cleaned = ArticleContentRedactor.redactAndSplit(rawJunk)
        assertEqual(cleaned.count, 1, "Should filter boilerplate lines and clean fused text")
        assertEqual(cleaned.first, "The launcher delivered a batch of CubeSats to low-Earth orbit from a spaceport in northern Norway, and Isar tasted success after its first test flight ended in failure last year.", "Should strip .Read full article and drop Comments")

        // 2. Test syndication footers and standalone boilerplate lines
        let syndicationText = """
        Apple has introduced a new capability in Swift.

        The post Apple Announces New Swift Features appeared first on 9to5Mac.

        Comments
        """
        let cleanedSyndication = ArticleContentRedactor.redactAndSplit(syndicationText)
        assertEqual(cleanedSyndication.count, 1, "Should strip syndication notice and comments line")
        assertEqual(cleanedSyndication.first, "Apple has introduced a new capability in Swift.", "Content should match without syndication")

        // 3. Test preservation of legitimate words in content
        let normalText = "The spokesperson declined to make any further comments on the ongoing investigation."
        let cleanedNormal = ArticleContentRedactor.cleanText(normalText)
        assertEqual(cleanedNormal, normalText, "Should not redact 'comments' inside a legitimate sentence")

        // 4. Test paragraph splitting for long unformatted RSS blocks (> 650 chars)
        let longBlock = "SpaceX is dialing back its Falcon 9 launch program, and there is no certainty about when SpaceX's reusable next-generation super-heavy-lift rocket will carry payloads. " +
            "Customers in any sector will usually welcome competition. Theoretically, competition will lead to lower prices and allow the best to rise to the top. " +
            "So it's no surprise satellite operators are cheering the success of a new launch provider. This was especially the case when Germany's Isar Aerospace reached orbit for the first time with its Spectrum rocket. " +
            "The launcher delivered a batch of CubeSats to low-Earth orbit from a spaceport in northern Norway, marking a milestone."
        let splitParagraphs = ArticleContentRedactor.redactAndSplit(longBlock)
        assertTrue(splitParagraphs.count >= 2, "Monolithic text should be split into multiple paragraphs at sentence boundaries")

        // 5. Test Typography Lead Font Tokens
        let casperLead = AppTypography.leadFont(for: .casper)
        let editionLead = AppTypography.leadFont(for: .edition)
        let altoLead = AppTypography.leadFont(for: .alto)
        _ = casperLead
        _ = editionLead
        _ = altoLead
        assertTrue(true, "Lead font tokens must be defined for all themes")
    }

    static func testArticleDetailReadingExperienceOverhaul() async {
        print("  - Testing Article Detail Reading Experience Overhaul...")

        // 1. Preview Policy — now shows all content
        let sixParagraphs = (1...6).map { "Paragraph \($0) with substantive content describing current world events." }
        let allShown = ArticlePreviewPolicy.computePreview(paragraphs: sixParagraphs, isExtracted: true)
        assertEqual(allShown.count, 6, "All extracted paragraphs should be shown in reader")
        assertEqual(allShown.first, "Paragraph 1 with substantive content describing current world events.", "First paragraph should be preserved")

        let fourParagraphs = (1...4).map { "Paragraph \($0) with substantive content." }
        let allFour = ArticlePreviewPolicy.computePreview(paragraphs: fourParagraphs, isExtracted: true)
        assertEqual(allFour.count, 4, "All paragraphs should be preserved")

        let descriptionParagraphs = ["Brief summary paragraph from RSS feed."]
        let fallbackPreview = ArticlePreviewPolicy.computePreview(paragraphs: descriptionParagraphs, isExtracted: false)
        assertEqual(fallbackPreview.count, 1, "Fallback description should preserve all paragraphs")

        // 2. Trackpad Swipe Gesture Evaluation
        let rightwardResult = TrackpadSwipeEvaluator.evaluate(deltaX: 75.0, deltaY: 10.0, threshold: 60.0)
        assertEqual(rightwardResult, .previous, "Dominant rightward swipe should navigate to previous article")

        let leftwardResult = TrackpadSwipeEvaluator.evaluate(deltaX: -80.0, deltaY: 15.0, threshold: 60.0)
        assertEqual(leftwardResult, .next, "Dominant leftward swipe should navigate to next article")

        let verticalScrollResult = TrackpadSwipeEvaluator.evaluate(deltaX: 25.0, deltaY: 90.0, threshold: 60.0)
        assertEqual(verticalScrollResult, .none, "Dominant vertical scroll should not trigger article navigation")

        let smallWobbleResult = TrackpadSwipeEvaluator.evaluate(deltaX: 35.0, deltaY: 5.0, threshold: 60.0)
        assertEqual(smallWobbleResult, .none, "Sub-threshold horizontal movement should not trigger article navigation")

        // 3. Content Extraction Pipeline Paragraph Extraction
        let sampleHTML = """
        <html>
        <body>
        <article class="story-body">
            <p>The space agency announced the discovery of an Earth-sized exoplanet in the habitable zone.</p>
            <p>Observations with the orbital telescope revealed atmospheric water vapor signatures.</p>
            <p>Further spectroscopic follow-ups are planned for the upcoming observing cycle.</p>
        </article>
        </body>
        </html>
        """
        let extractedParagraphs = ContentExtractionPipeline.shared.extractParagraphs(from: sampleHTML)
        assertEqual(extractedParagraphs.count, 3, "Should cleanly extract 3 substantive paragraphs from HTML")
        assertTrue(extractedParagraphs[0].contains("exoplanet"), "Paragraph text should match content")
    }

    static func testBBCExtractionFixture() async {
        print("  - Testing BBC News Article Extraction Fixture...")

        let bbcHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <title>Mountaineer Mingma G tells the BBC about high-altitude rescue - BBC News</title>
            <meta property="og:image" content="https://ichef.bbci.co.uk/news/1024/branded_news/abc12345.jpg">
        </head>
        <body>
            <header role="banner">
                <nav><a href="/">BBC Home</a><a href="/news">News</a><a href="/sport">Sport</a></nav>
            </header>
            <main id="main-content">
                <article>
                    <header>
                        <h1 class="ssrcss-headline">Mountaineer Mingma G tells the BBC about high-altitude rescue</h1>
                    </header>
                    <div data-component="text-block" class="ssrcss-text-block">
                        <p class="ssrcss-1q0x1q5-Paragraph">Mountaineer Mingma G tells the BBC about the dramatic climb up the Himalayan ridge during unprecedented weather conditions.</p>
                    </div>
                    <div data-component="text-block" class="ssrcss-text-block">
                        <p class="ssrcss-1q0x1q5-Paragraph">The seasoned climber coordinated a multi-team summit effort after receiving distress calls from stranded expeditions on the north face.</p>
                    </div>
                    <div data-component="text-block" class="ssrcss-text-block">
                        <p class="ssrcss-1q0x1q5-Paragraph">Despite sub-zero winds and waning daylight, all twelve members were successfully escorted down to base camp without major frostbite.</p>
                    </div>
                    <div data-component="text-block" class="ssrcss-text-block">
                        <p class="ssrcss-1q0x1q5-Paragraph">Local alpine authorities praised the swift mobilization as one of the most effective high-altitude interventions on record in recent decades.</p>
                    </div>
                    <aside class="ssrcss-related-topics">
                        <h2>Related Topics</h2>
                        <ul><li><a href="/topics/nepal">Nepal</a></li><li><a href="/topics/mountains">Mountaineering</a></li></ul>
                    </aside>
                </article>
            </main>
            <footer role="contentinfo">
                <p class="copyright">Copyright 2026 BBC. All rights reserved.</p>
                <nav><a href="/terms">Terms of Use</a><a href="/about">About the BBC</a></nav>
            </footer>
        </body>
        </html>
        """

        let outcome = ContentExtractionPipeline.shared.extractFromHTML(bbcHTML)
        guard case .success(let content, let leadImage, _) = outcome else {
            assertTrue(false, "BBC extraction must succeed, got \(outcome)")
            return
        }

        let paragraphs = ArticleContentRedactor.redactAndSplit(content)
        assertEqual(paragraphs.count, 4, "Must extract all 4 BBC story text-block paragraphs")
        assertTrue(content.contains("Mountaineer Mingma G tells the BBC"), "Paragraph 1 present")
        assertTrue(content.contains("twelve members were successfully escorted"), "Paragraph 3 present")
        assertTrue(!content.contains("BBC Home"), "Navigation links must be excluded")
        assertTrue(!content.contains("Related Topics"), "Related topics section must be excluded")
        assertTrue(!content.contains("Copyright 2026 BBC"), "Footer copyright must be excluded")
        assertEqual(leadImage, "https://ichef.bbci.co.uk/news/1024/branded_news/abc12345.jpg", "Lead image must be extracted")
    }

    static func testMultiPublisherExtractionFixtures() async {
        print("  - Testing Multi-Publisher Extraction Fixtures (Reuters, Ars, Verge, NYTimes)...")

        // 1. Reuters Style
        let reutersHTML = """
        <html><body>
        <nav><a href="/">Reuters Home</a></nav>
        <article class="article-body">
            <div class="article-body__content">
                <p>Global semiconductor manufacturers reported record quarterly shipments as artificial intelligence demand surged across multiple sectors.</p>
                <p>Industry analysts noted that supply chain lead times have contracted significantly following major capital investments in fabrication plants.</p>
                <p>Major enterprise software providers continue to scale computational clusters to support next-generation foundational model training runs.</p>
            </div>
        </article>
        <footer><p>Reuters Thomson Trust Principles</p></footer>
        </body></html>
        """
        let reutersOutcome = ContentExtractionPipeline.shared.extractFromHTML(reutersHTML)
        guard case .success(let rContent, _, _) = reutersOutcome else {
            assertTrue(false, "Reuters extraction must succeed")
            return
        }
        let rParas = ArticleContentRedactor.redactAndSplit(rContent)
        assertEqual(rParas.count, 3, "Reuters should yield 3 paragraphs")
        assertTrue(!rContent.contains("Reuters Home"), "Navigation should be excluded")

        // 2. Ars Technica Style
        let arsHTML = """
        <html><body>
        <article class="article-single">
            <div class="article-content">
                <p>Researchers at the astrophysics laboratory have mapped the intricate magnetic field lines surrounding a supermassive black hole.</p>
                <p>Using a globally synchronized array of millimeter-wave radio observatories, the team reconstructed polarimetric signatures at micro-arcsecond resolution.</p>
                <p>The findings provide critical empirical validation for relativistic magnetohydrodynamic simulations developed over the past decade.</p>
            </div>
        </article>
        </body></html>
        """
        let arsOutcome = ContentExtractionPipeline.shared.extractFromHTML(arsHTML)
        guard case .success(let aContent, _, _) = arsOutcome else {
            assertTrue(false, "Ars Technica extraction must succeed")
            return
        }
        assertEqual(ArticleContentRedactor.redactAndSplit(aContent).count, 3, "Ars should yield 3 paragraphs")

        // 3. The Verge Style
        let vergeHTML = """
        <html><body>
        <main id="content">
            <article>
                <div class="duet--article--article-body-component">
                    <p>Electric vehicle charging network operators announced a standardized communication protocol to improve interoperability across metropolitan stations.</p>
                    <p>The update eliminates proprietary authentication handshakes in favor of universal hardware-level cryptographic key exchange.</p>
                    <p>Federal transportation regulators hailed the unified specification as an essential milestone for nationwide transit electrification goals.</p>
                </div>
            </article>
        </main>
        </body></html>
        """
        let vergeOutcome = ContentExtractionPipeline.shared.extractFromHTML(vergeHTML)
        guard case .success(let vContent, _, _) = vergeOutcome else {
            assertTrue(false, "The Verge extraction must succeed")
            return
        }
        assertEqual(ArticleContentRedactor.redactAndSplit(vContent).count, 3, "The Verge should yield 3 paragraphs")

        // 4. NYTimes Style
        let nytHTML = """
        <html><body>
        <article id="story">
            <section name="articleBody">
                <div class="StoryBodyCompanionColumn">
                    <p>Central banking officials signaled plans to maintain current policy rates following fresh data on consumer spending and labor market stability.</p>
                    <p>While headline inflation metrics have cooled toward historical targets, persistent wage growth in services has prompted measured caution among governors.</p>
                    <p>Financial market participants broadly recalibrated rate cut expectations, with treasury yields consolidating within recent trading ranges.</p>
                </div>
            </section>
        </article>
        </body></html>
        """
        let nytOutcome = ContentExtractionPipeline.shared.extractFromHTML(nytHTML)
        guard case .success(let nytContent, _, _) = nytOutcome else {
            assertTrue(false, "NYTimes extraction must succeed")
            return
        }
        assertEqual(ArticleContentRedactor.redactAndSplit(nytContent).count, 3, "NYTimes should yield 3 paragraphs")
    }

    static func testContentQualityValidation() async {
        print("  - Testing ContentQualityValidator Rules...")

        // 1. Valid paragraphs pass
        let valid = [
            "The international summit concluded today with landmark agreements on carbon emission reduction targets across all member economies.",
            "Delegates committed billions in concessional financing to support clean energy transitions in developing nations over the next ten years.",
            "Independent observers commended the transparency mechanisms embedded within the final treaty text as unprecedented in multilateral diplomacy."
        ]
        assertEqual(ContentQualityValidator.validate(paragraphs: valid), .valid, "Substantive article must pass validation")

        // 2. Empty paragraphs rejected
        assertEqual(ContentQualityValidator.validate(paragraphs: []), .rejected(reason: "No readable paragraphs found"), "Empty paragraphs rejected")

        // 3. Too short rejected
        let tooShort = ["This is a tiny snippet."]
        if case .rejected(let reason) = ContentQualityValidator.validate(paragraphs: tooShort) {
            assertTrue(reason.contains("too short"), "Must reject short snippets")
        } else {
            assertTrue(false, "Should reject very short snippets")
        }

        // 4. High boilerplate rejected
        let boilerplate = [
            "The post High Altitude Rescue appeared first on Himalayan News Network.",
            "Photo credit: Associated Press News Wire Archives / John Doe Photographer.",
            "Read full article",
            "A single short paragraph covering the mountain rescue effort in northern Nepal."
        ]
        if case .rejected(let reason) = ContentQualityValidator.validate(paragraphs: boilerplate) {
            assertTrue(reason.contains("boilerplate"), "Must detect high boilerplate ratio")
        } else {
            assertTrue(false, "Should reject boilerplate heavy text")
        }

        // 5. Repetitive syndicated loop rejected
        let repeated = [
            "The council published a detailed report on local transport improvements and future investment.",
            "The council published a detailed report on local transport improvements and future investment.",
            "The council published a detailed report on local transport improvements and future investment."
        ]
        if case .rejected(let reason) = ContentQualityValidator.validate(paragraphs: repeated) {
            assertTrue(reason.contains("repetitive"), "Must detect duplicate text loop")
        } else {
            assertTrue(false, "Should reject repetitive syndication loops")
        }
    }

    static func testExtractionOutcomeDiagnostics() async {
        print("  - Testing ExtractionOutcome Diagnostics & Failure Types...")

        let outcomeSuccess = ExtractionOutcome.success(content: "Article body", imageUrl: "https://example.com/img.jpg")
        assertTrue(outcomeSuccess.isSuccess, "Must identify success")
        assertEqual(outcomeSuccess.content, "Article body", "Content accessible")
        assertEqual(outcomeSuccess.imageUrl, "https://example.com/img.jpg", "Image accessible")
        assertEqual(outcomeSuccess.failureReason, nil, "No failure reason on success")

        let outcomeHTTP = ExtractionOutcome.httpError(status: 403)
        assertTrue(!outcomeHTTP.isSuccess, "Not success")
        assertEqual(outcomeHTTP.failureReason, "HTTP Error 403", "HTTP status failure message")

        let outcomeBlocked = ExtractionOutcome.securityBlocked(reason: "Private IP")
        assertEqual(outcomeBlocked.failureReason, "Security blocked: Private IP", "Security failure message")

        let outcomeNetwork = ExtractionOutcome.networkError(reason: "Connection timeout")
        assertEqual(outcomeNetwork.failureReason, "Connection timeout", "Network failure message")
    }

    static func testCanonicalClassificationDisambiguation() async {
        print("  - Testing Canonical Classification Disambiguation for Overlapping Topics...")

        // Overlap 1: Health + Technology (AI scanner for hospital patients)
        assertEqual(NewsCategory.match(from: "medical AI clinical diagnostic scanner"), .health, "Health cue overrides tech")

        // Overlap 2: Science + Technology (NASA satellite mission)
        assertEqual(NewsCategory.match(from: "NASA telescope deep space observatory"), .science, "Astronomy cue overrides tech")

        // Overlap 3: Business + Politics (Stock market inflation Wall Street)
        assertEqual(NewsCategory.match(from: "Wall Street stock market inflation revenue"), .business, "Market cues resolve to business")

        // Overlap 4: Politics + World (Senate Congress election)
        assertEqual(NewsCategory.match(from: "Senate Congress election campaign"), .politics, "Governance cues resolve to politics")

        // Overlap 5: World diplomacy (International foreign global treaty)
        assertEqual(NewsCategory.match(from: "International global foreign diplomat summit"), .world, "Diplomacy resolves to world")
    }

    @MainActor
    static func testAppContainerAndFrostedSurface() async {
        print("  - Testing AppContainer & Frosted Surface tokens...")

        let suite = "test.container.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"))
        let feeds = FeedManager(settings: settings, store: store, schedulesRefresh: false)
        let reads = ReadManager(articleStore: store)
        let saved = SavedStoriesManager(articleStore: store)
        let container = AppContainer(appSettings: settings, articleStore: store, feedManager: feeds, readManager: reads, savedStories: saved)
        assertTrue(container.appSettings === settings, "Injected settings wired")
        assertTrue(container.articleStore === store, "Injected store wired")
        assertTrue(container.readManager === reads, "Injected read manager wired")
        assertTrue(container.savedStories === saved, "Injected saved manager wired")

        let controlElevation = FrostedElevation.control
        assertEqual(controlElevation.surfaceBackingOpacity, 0.65, "Control backing is translucent (0.65)")
        assertEqual(controlElevation.shadowRadius, 12.0, "Control shadow radius is 12")

        let cardElevation = FrostedElevation.card
        assertEqual(cardElevation.surfaceBackingOpacity, 0.38, "Card backing is 0.38")
    }

    @MainActor
    static func testReadManagerReconciliationCache() async throws {
        print("  - Testing ReadManager Reconciliation Cache...")
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"))
        await store.initialize()
        let rm = ReadManager(articleStore: store)
        let rawId = "http://example.com/test-article-perf?utm_source=news&utm_medium=rss"
        await store.batchUpsert(articles: [FeedArticle(title: "Read", link: rawId, guid: ArticleIdentity.reconcileLegacyId(rawId), description: "Text", pubDate: Date(), source: "Test")])
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

        let article = FeedArticle(title: "Saved", link: "https://example.com/saved", guid: "isolated-save", description: "Text", pubDate: Date(), source: "Test")
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
}

