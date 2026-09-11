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
        
        let sample = [FeedArticle(
            title: "Offline Test Story",
            link: "https://example.com/story-offline",
            guid: "offline-1",
            description: "Offline summary",
            pubDate: Date(),
            source: "Offline Source"
        )]
        CacheManager.shared.save(sample, forKey: "offline_test_key")
        
        let loaded = CacheManager.shared.load(forKey: "offline_test_key", as: [FeedArticle].self)
        assertEqual(loaded?.count, 1, "Should load cached article")
        assertEqual(loaded?[0].title, "Offline Test Story", "Should match cached title")
        
        let size = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(size > 0, "Cache directory should contain bytes")
    }
}
