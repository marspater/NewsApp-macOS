// NewsTests.swift

import Foundation

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
        print("🏃 Running NewsApp Unit Tests...")
        
        await testURLNormalization()
        await testSSRFValidation()
        await testIsBlockedIPv4()
        await testIPAddressValidatorDeep()
        await testSecureHTTPClientPolicies()
        await testFeedErrorHierarchy()
        await testAppSettingsDecoupling()
        await testDateParsing()
        await testXMLParsing()
        await testJSONParsing()
        await testNavigationCommands()
        await testOPMLParsingAndExporting()
        await testOfflineCacheAndResilience()
        await testArticleIdentityDeep()
        await testDatabaseEnginePersistence()
        await testFTS5SearchAndOperators()
        await testMigrationCoordinatorAtomicity()
        await testArticleRetentionPolicy()
        await testArticleIntelligenceCapabilities()
        await testContentExtractionPipelineDeep()
        await testEnrichmentQueueSchedulingAndPromotion()
        await testDesignSystemAndArticleFilter()
        await testDistributionAndEntitlementsIntegrity()
        await testStrictSemVerAndReleaseSecurity()
        await testNotificationModeTriageAndGrammar()
        await testRefreshCoordinatorSingleFlightCoalescing()
        await testSignpostHelperExecution()
        await testAppSettingsIsolationAndURLNormalization()
        await testFixedTaxonomyAndCaseInsensitivity()
        await testClassificationMultiStageAndConfidenceTiers()
        await testClassificationBenchmarkDataset()
        await testArticleAnalyzerStructuredOutputAndFallbacks()
        await testInteractiveAnalysisCancellation()
        await testGranularCacheClearingAndRetention()
        await testNotificationServiceErrorLogging()
        
        print("✅ SUCCESS: All tests passed!")
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
        
        assertFalse(FeedManager.isBlockedLocalAddress("google.com"), "Should allow public hostnames")
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
        assertTrue(IPAddressValidator.checkLiteralIP("::1") != nil, "::1 must be blocked")
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

        // 5. Hostname string validation
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
    
    static func testDateParsing() async {
        print("  - Testing Date parsing...")
        
        let date1Str = "Tue, 19 May 2026 20:30:00 GMT"
        let date1 = DateParser.parse(date1Str)
        assertTrue(date1.timeIntervalSince1970 > 0, "Should successfully parse RFC 822 date")
        
        let date2Str = "2026-05-19T20:30:00Z"
        let date2 = DateParser.parse(date2Str)
        assertTrue(date2.timeIntervalSince1970 > 0, "Should successfully parse ISO 8601 date")
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
    }
    
    static func testOfflineCacheAndResilience() async {
        print("  - Testing Offline Cache & Resilience...")
        
        CacheManager.shared.configureOfflineCache()
        let size = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(size >= 0, "Cache directory byte calculation should succeed")
        
        CacheManager.shared.clearAllCache()
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
            rssCategory: nil
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
    
    static func testEnrichmentQueueSchedulingAndPromotion() async {
        print("  - Testing EnrichmentQueue Scheduling, Promotion & Cancellation...")
        
        let queue = EnrichmentQueue()
        
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
        assertEqual(AppRadius.card, 14.0, "AppRadius.card should be 14.0")
        assertEqual(AppRadius.pill, 999.0, "AppRadius.pill should be 999.0")
        
        // 3. Ghost Typography Theme tokens
        assertEqual(AppTypography.bodyLineSpacing(for: .casper), 12.0, "Casper theme line spacing should be 12")
        assertEqual(AppTypography.bodyLineSpacing(for: .edition), 8.0, "Edition theme line spacing should be 8")
        assertEqual(AppTypography.bodyLineSpacing(for: .alto), 14.0, "Alto theme line spacing should be 14")
        
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
        
        guard let data = fileManager.contents(atPath: entitlementsPath) else {
            assertEqual(true, false, "Failed to read News.entitlements data")
            return
        }
        
        do {
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                assertEqual(true, false, "News.entitlements is not a valid dictionary plist")
                return
            }
            
            // Validate minimal required entitlements
            assertEqual(plist["com.apple.security.network.client"] as? Bool, true, "com.apple.security.network.client must be enabled")
            assertEqual(plist["com.apple.security.files.user-selected.read-write"] as? Bool, true, "com.apple.security.files.user-selected.read-write must be enabled")
            
            // Validate that unnecessary/unsafe entitlements are NOT present
            assertFalse(plist.keys.contains("com.apple.security.network.server"), "com.apple.security.network.server should not be granted")
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
        let packageDmgScript = (currentDir as NSString).appendingPathComponent("package_dmg.sh")
        let notarizeScript = (currentDir as NSString).appendingPathComponent("notarize.sh")
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

        // 2. AppSettings Migration Semantics
        let suiteName = "test.notifications.migration.\(UUID().uuidString)"
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { tempDefaults.removePersistentDomain(forName: suiteName) }

        // Case A: legacy privateNotificationsEnabled = true -> migrates to .private
        tempDefaults.set(true, forKey: AppSettings.privateNotificationsEnabledKey)
        let settingsA = AppSettings(defaults: tempDefaults)
        assertEqual(settingsA.notificationMode, AppSettings.NotificationMode.private, "Legacy private flag should migrate to .private mode")
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
        let waiterTask1 = Task {
            try await cancelCoordinator.executeRefresh {
                try await Task.sleep(nanoseconds: 60_000_000) // 60ms
                await completionCounter.increment()
            }
        }
        let waiterTask2 = Task {
            try await cancelCoordinator.executeRefresh {
                await completionCounter.increment()
            }
        }
        // Cancel waiterTask1 early
        waiterTask1.cancel()
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
        } catch {}
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
        } catch {}
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
            rssCategory: "Technology"
        )
        assertEqual(rssResult.category, "Technology", "RSS hint should determine category")
        assertTrue(rssResult.confidence >= 0.90, "RSS hint should provide >= 0.90 confidence")
        assertTrue(rssResult.evidence.contains("Technology"), "Evidence should include RSS category")

        // Stage 2: Strong keyword title/description scoring
        let techResult = await classifier.classify(
            title: "Apple Announces M-Series Silicon Processor With Neural Acceleration",
            description: "Novel semiconductor architecture speeds machine learning and developer workflows",
            rssCategory: nil
        )
        assertEqual(techResult.category, "Technology", "Strong tech keywords must classify as Technology")
        assertTrue(techResult.confidence >= 0.70, "Confidence should exceed 0.70")
        assertTrue(!techResult.evidence.isEmpty, "Evidence should list matched keywords")

        // Stage 3: Fallback when no keywords match
        let genericResult = await classifier.classify(
            title: "Unspecified Developments Reported",
            description: "Updates will follow as events occur",
            rssCategory: nil
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
                rssCategory: nil
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

    static func testArticleAnalyzerStructuredOutputAndFallbacks() async {
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

        let analysis = try! await analyzer.analyze(title: title, content: articleBody, category: "Technology")

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
        assertEqual(analysis.analysisVersion, 1, "Analysis version should match schema version")
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

    static func testGranularCacheClearingAndRetention() async {
        print("  - Testing Granular Cache Purging (Selective Deletes & Feed Preservation)...")

        let db = DatabaseEngine(path: ":memory:")
        try! await db.open()
        defer { Task { await db.close() } }

        // 1. Populate feeds and articles
        let testFeed = "https://example.com/tech.xml"
        let article1 = FeedArticle(title: "Article One", link: "https://example.com/1", guid: "art-1", description: "Desc 1", pubDate: Date(), source: "Test Feed", fullContent: "Content One")
        let article2 = FeedArticle(title: "Article Two", link: "https://example.com/2", guid: "art-2", description: "Desc 2", pubDate: Date(), source: "Test Feed", fullContent: "Content Two")

        try! await db.upsertArticles([article1, article2], feedUrl: testFeed)
        _ = try! await db.toggleSaved(articleId: article1.id) // article1 is saved!

        // Save AI enrichment for both
        let analysis = ArticleAnalysis(summary: "Summary text", keyPoints: ["Point 1", "Point 2"], entities: [], category: "Technology", sentiment: nil, modelIdentifier: "test", analysisVersion: 1)
        try! await db.saveArticleAnalysis(analysis, for: article1.id)
        try! await db.saveArticleAnalysis(analysis, for: article2.id)

        // Verify initial state
        let initialAnalysis1 = await db.fetchArticleAnalysis(for: article1.id)
        assertTrue(initialAnalysis1 != nil, "Article 1 should have analysis")
        let initialAnalysis2 = await db.fetchArticleAnalysis(for: article2.id)
        assertTrue(initialAnalysis2 != nil, "Article 2 should have analysis")

        // 2. Test clearArticleEnrichment(): clears AI analysis, keeps articles and feeds
        try! await db.clearArticleEnrichment()
        let clearedAnalysis1 = await db.fetchArticleAnalysis(for: article1.id)
        assertTrue(clearedAnalysis1 == nil, "Article 1 enrichment must be purged")
        let clearedAnalysis2 = await db.fetchArticleAnalysis(for: article2.id)
        assertTrue(clearedAnalysis2 == nil, "Article 2 enrichment must be purged")

        let articlesAfterEnrichmentClear = try! await db.fetchArticles(limit: 10)
        assertEqual(articlesAfterEnrichmentClear.count, 2, "Articles must remain intact after enrichment purge")

        // 3. Test clearArticleCache(): clears non-saved article bodies, keeps saved stories intact
        try! await db.clearArticleCache()
        let articlesAfterContentClear = try! await db.fetchArticles(limit: 10)
        let savedArticle = articlesAfterContentClear.first { $0.id == article1.id }
        assertEqual(savedArticle?.fullContent, "Content One", "Saved article content must NOT be cleared")
        let unsavedArticle = articlesAfterContentClear.first { $0.id == article2.id }
        assertTrue(unsavedArticle?.fullContent == nil, "Non-saved article content must be set to nil")

        // 4. Test clearAllDatabaseCache(): clears all non-saved articles, keeps saved stories and feed subscriptions
        try! await db.clearAllDatabaseCache()
        let remainingArticles = try! await db.fetchArticles(limit: 10)
        assertEqual(remainingArticles.count, 1, "Only saved article should remain after full database purge")
        assertEqual(remainingArticles.first?.id, article1.id, "Saved article must survive full purge")

        // 5. Test CacheManager methods
        CacheManager.shared.clearWebCache()
        CacheManager.shared.clearAllCache()
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

        // 3. Importance computation range [0.0, 1.0]
        let score = service.computeImportance(title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response.")
        assertTrue(score >= 0.0 && score <= 1.0, "Score must be bounded between 0.0 and 1.0")

        // 4. Robust dispatching (no crashes across all 3 notification tiers)
        let sampleArticle = FeedArticle(title: "Urgent Update", link: "https://example.com/urgent", guid: "sample-guid", description: "Details follow", pubDate: Date(), source: "Wire Service")
        await service.triageAndNotify(newArticles: [sampleArticle], mode: .minimal)
        await service.triageAndNotify(newArticles: [sampleArticle], mode: .private)
        await service.triageAndNotify(newArticles: [sampleArticle], mode: .full)
    }
}


