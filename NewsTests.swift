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
        
        // 1. UTM parameters removal
        let url1 = "https://example.com/story?utm_source=feed&utm_medium=rss&ref=share"
        assertEqual(FeedArticle.normalizeURL(url1), "https://example.com/story", "Should strip tracking query parameters")
        
        // 2. Trailing slash removal
        let url2 = "https://example.com/path/"
        assertEqual(FeedArticle.normalizeURL(url2), "https://example.com/path", "Should strip trailing slashes")
        
        // 3. Lowercase host
        let url3 = "https://EXamPLE.COm/Path/"
        assertEqual(FeedArticle.normalizeURL(url3), "https://example.com/Path", "Should lowercase the host and strip trailing slash")
        
        // 4. Force HTTPS
        let url4 = "http://example.com/path"
        assertEqual(FeedArticle.normalizeURL(url4), "https://example.com/path", "Should upgrade scheme to https")
    }
    
    static func testSSRFValidation() async {
        print("  - Testing SSRF block list...")
        
        // Local addresses must be blocked
        assertTrue(FeedManager.isBlockedLocalAddress("localhost"), "Should block localhost")
        assertTrue(FeedManager.isBlockedLocalAddress("127.0.0.1"), "Should block 127.0.0.1")
        assertTrue(FeedManager.isBlockedLocalAddress("10.0.1.5"), "Should block private range 10.x")
        assertTrue(FeedManager.isBlockedLocalAddress("192.168.1.100"), "Should block private range 192.168.x")
        assertTrue(FeedManager.isBlockedLocalAddress("172.20.5.5"), "Should block private range 172.16-31.x")
        assertTrue(FeedManager.isBlockedLocalAddress("::1"), "Should block IPv6 loopback")
        assertTrue(FeedManager.isBlockedLocalAddress("fe80::1"), "Should block IPv6 link-local")
        
        // Public addresses must be allowed
        assertFalse(FeedManager.isBlockedLocalAddress("google.com"), "Should allow public hostnames")
        assertFalse(FeedManager.isBlockedLocalAddress("8.8.8.8"), "Should allow public IPs")
        assertFalse(FeedManager.isBlockedLocalAddress("172.15.2.2"), "Should allow public range outside 172.16-31")
    }
    
    static func testDateParsing() async {
        print("  - Testing Date parsing...")
        
        // Test RSS format (RFC 822)
        let date1Str = "Tue, 19 May 2026 20:30:00 GMT"
        let date1 = DateParser.parse(date1Str)
        assertTrue(date1.timeIntervalSince1970 > 0, "Should successfully parse RFC 822 date")
        
        // Test Atom / ISO 8601 format
        let date2Str = "2026-05-19T20:30:00Z"
        let date2 = DateParser.parse(date2Str)
        assertTrue(date2.timeIntervalSince1970 > 0, "Should successfully parse ISO 8601 date")
    }
    
    static func testXMLParsing() async {
        print("  - Testing XML Feed parsing...")
        
        let xmlData = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
            <channel>
                <title>Test Feed Source</title>
                <link>https://test.com</link>
                <item>
                    <title>Test Article Title</title>
                    <link>https://test.com/article1</link>
                    <guid>unique-guid-123</guid>
                    <description>Hello world &lt;b&gt;bold text&lt;/b&gt; &amp;amp; more.</description>
                    <pubDate>Tue, 19 May 2026 20:30:00 +0000</pubDate>
                </item>
            </channel>
        </rss>
        """.data(using: .utf8)!
        
        let parser = FeedXMLParser(data: xmlData, feedURL: "https://test.com/rss")
        let articles = parser.parse()
        
        assertEqual(articles.count, 1, "Should parse exactly one article")
        let first = articles[0]
        assertEqual(first.title, "Test Article Title", "Should match title")
        assertEqual(first.link, "https://test.com/article1", "Should match link")
        assertEqual(first.guid, "unique-guid-123", "Should extract guid")
        assertEqual(first.id, "unique-guid-123", "Should use guid as article ID")
        assertEqual(first.description, "Hello world bold text & more.", "Should clean HTML elements and decode entities")
        assertEqual(first.source, "Test Feed Source", "Should extract and clean feed channel title")
    }
    
    static func testJSONParsing() async {
        print("  - Testing JSON Feed parsing...")
        
        let jsonData = """
        {
            "version": "https://jsonfeed.org/version/1.1",
            "title": "JSON Test Feed",
            "home_page_url": "https://jsonfeedtest.com",
            "items": [
                {
                    "id": "json-unique-id-789",
                    "url": "https://jsonfeedtest.com/post-1",
                    "title": "JSON Feed Article",
                    "content_html": "<p>Content of the JSON article</p>",
                    "summary": "Short summary",
                    "date_published": "2026-05-19T20:30:00Z"
                }
            ]
        }
        """.data(using: .utf8)!
        
        guard let articles = JSONFeedParser.parse(data: jsonData, feedURL: "https://jsonfeedtest.com/feed.json") else {
            print("❌ Failed to parse JSON Feed data")
            exit(1)
        }
        
        assertEqual(articles.count, 1, "Should parse exactly one JSON item")
        let first = articles[0]
        assertEqual(first.title, "JSON Feed Article", "Should match title")
        assertEqual(first.link, "https://jsonfeedtest.com/post-1", "Should match link")
        assertEqual(first.guid, "json-unique-id-789", "Should map item id to guid")
        assertEqual(first.id, "json-unique-id-789", "Should use guid as article ID")
        assertEqual(first.description, "Short summary", "Should match description")
        assertEqual(first.source, "JSON Test Feed", "Should use feed title as source name")
    }
    
    static func testNavigationCommands() async {
        print("  - Testing Keyboard Navigation Offset Logic...")
        
        let count = 5
        func nextIndex(current: Int?, offset: Int) -> Int {
            let currentIndex: Int
            if let cur = current {
                currentIndex = cur
            } else {
                currentIndex = offset > 0 ? -1 : count
            }
            return max(0, min(count - 1, currentIndex + offset))
        }
        
        // Initial jump forward
        assertEqual(nextIndex(current: nil, offset: 1), 0, "Initial next should select index 0")
        // Step forward
        assertEqual(nextIndex(current: 0, offset: 1), 1, "Should advance to index 1")
        assertEqual(nextIndex(current: 1, offset: 1), 2, "Should advance to index 2")
        // Clamp at upper bound
        assertEqual(nextIndex(current: 4, offset: 1), 4, "Should clamp at end of list")
        // Step backwards
        assertEqual(nextIndex(current: 4, offset: -1), 3, "Should move back to index 3")
        // Clamp at lower bound
        assertEqual(nextIndex(current: 0, offset: -1), 0, "Should clamp at beginning of list")
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
        
        // Item 1 (flat)
        assertEqual(items[0].title, "Top News", "Should extract title")
        assertEqual(items[0].url, "https://news.ycombinator.com/rss", "Should extract xmlUrl")
        assertEqual(items[0].folder, nil, "Should have nil folder for root item")
        
        // Item 2 (inside Technology folder)
        assertEqual(items[1].title, "Ars Technica", "Should extract title")
        assertEqual(items[1].url, "https://feeds.arstechnica.com/arstechnica/index", "Should extract xmlUrl")
        assertEqual(items[1].folder, "Technology", "Should associate with Technology folder")
        
        // Item 3 (inside Technology folder with URL attribute instead of xmlUrl)
        assertEqual(items[2].title, "The Verge", "Should extract title from text attribute")
        assertEqual(items[2].url, "https://www.theverge.com/rss/index.xml", "Should extract URL attribute")
        assertEqual(items[2].folder, "Technology", "Should associate with Technology folder")
        
        // Test Export
        let urlsToExport = [
            "https://feeds.arstechnica.com/arstechnica/index",
            "https://news.ycombinator.com/rss"
        ]
        let exported = OPMLExporter.generateOPML(feedURLs: urlsToExport, title: "Exported Feeds")
        assertTrue(exported.contains("<opml version=\"2.0\">"), "Export should contain opml version 2.0")
        assertTrue(exported.contains("<title>Exported Feeds</title>"), "Export should contain title")
        assertTrue(exported.contains("xmlUrl=\"https://feeds.arstechnica.com/arstechnica/index\""), "Export should contain feed 1")
        assertTrue(exported.contains("xmlUrl=\"https://news.ycombinator.com/rss\""), "Export should contain feed 2")
        
        // Roundtrip test: parse the exported OPML
        let roundtripData = exported.data(using: .utf8)!
        let roundtripItems = OPMLParser.parse(data: roundtripData)
        assertEqual(roundtripItems.count, 2, "Roundtrip OPML export should parse back into 2 feeds")
        assertEqual(roundtripItems[0].url, "https://feeds.arstechnica.com/arstechnica/index", "Roundtrip feed 1 URL match")
        assertEqual(roundtripItems[1].url, "https://news.ycombinator.com/rss", "Roundtrip feed 2 URL match")
    }
    
    static func testOfflineCacheAndResilience() async {
        print("  - Testing Offline Cache & Resilience...")
        
        // 1. Configure offline cache
        CacheManager.shared.configureOfflineCache()
        
        // 2. Save sample article
        let sample = [FeedArticle(
            title: "Offline Test Story",
            link: "https://example.com/story-offline",
            guid: "offline-1",
            description: "Offline summary",
            pubDate: Date(),
            source: "Offline Source"
        )]
        CacheManager.shared.save(sample, forKey: "offline_test_key")
        
        // 3. Load sample article
        let loaded = CacheManager.shared.load(forKey: "offline_test_key", as: [FeedArticle].self)
        assertEqual(loaded?.count, 1, "Should load cached article")
        assertEqual(loaded?[0].title, "Offline Test Story", "Should match cached title")
        
        // 4. Verify total cache size is positive
        let size = CacheManager.shared.calculateTotalCacheSize()
        assertTrue(size > 0, "Cache directory should contain bytes")
    }
}
