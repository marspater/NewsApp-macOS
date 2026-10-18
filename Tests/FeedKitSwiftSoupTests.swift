import Foundation

/// Offline parser checks run by test.sh, including --parsing-regressions. No user state or network access.
enum FeedKitSwiftSoupTests {
    static func run() {
        let pipeline = ContentExtractionPipeline.shared
        let base = "https://example.com/news/feed.xml"
        let first =
            "Engineers inspected the bridge after the storm and reported that the main structure remained intact. Local officials said the road would reopen after the safety checks were completed."
        let second =
            "Crews continued clearing debris from the road throughout the morning. Residents were advised to use the alternative route while workers completed repairs to the damaged barriers."
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Parsing regression: \(message)") }
        }

        let metadata = """
            <html><head><script>let fake = '<meta property="og:image" content="https://example.com/fake.jpg">';</script>
            <meta property=og:image content="https://example.com/photo.jpg?a=1&amp;b=2">
            <meta name=twitter:image content=/twitter.jpg>
            <script type='application/ld+json'>{"@type":"Organization","image":"/logo.jpg"}</script>
            <script type='application/ld+json'>{"@graph":[{"@type":"NewsArticle","image":{"url":"/schema.jpg"}}]}</script>
            </head><body><article><p>\(first)</p><p>\(second)</p></article></body></html>
            """
        let images = pipeline.extractLeadImages(from: metadata)
        check(
            images == ["https://example.com/photo.jpg?a=1&b=2", "/twitter.jpg", "/schema.jpg"],
            "CSS metadata ignores script text and organization logos, decodes attributes and preserves priority")

        let malformed = "<div itemprop=articleBody><p>\(first)<p>\(second)</div>"
        let repaired = pipeline.extractFromHTML(malformed, baseUrl: base)
        check(repaired.isSuccess, "Malformed HTML receives a quality-validated repaired DOM")
        if case .success(_, _, let document) = repaired {
            check(
                document?.blocks.filter { $0.kind == .paragraph }.count == 2,
                "HTML5 repair separates omitted paragraph end tags")
        }
        check(
            !pipeline.extractFromHTML("<section hidden>\(malformed)</section>", baseUrl: base).isSuccess,
            "Repair preserves exclusions on ancestor elements")
        check(
            !pipeline.extractFromHTML("<aside>\(malformed)</aside>", baseUrl: base).isSuccess,
            "Repair never promotes navigation or auxiliary content")
        check(
            !pipeline.extractFromHTML("<article><p>Subscribe now</p></article>").isSuccess,
            "DOM repair does not bypass content quality")

        let rss = """
            <rss xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:m="http://search.yahoo.com/mrss/">
            <channel><title>Publisher</title><item xml:base="https://example.com/reports/">
            <title>Bridge report</title><link>bridge</link><dc:date>2026-10-18T04:00:00Z</dc:date>
            <dc:creator>Reporter</dc:creator><description>\(first)</description><m:group>
            <m:credit>Agency Photographer</m:credit><m:content url="photo.jpg" type="image/jpeg" width="1200" height="800"/>
            </m:group></item></channel></rss>
            """
        let articles = FeedXMLParser(data: Data(rss.utf8), feedURL: base).parse()
        check(articles.count == 1, "RSS and canonicalized Media RSS namespaces reach FeedKit")
        check(articles.first?.link == "https://example.com/reports/bridge", "Nested xml:base resolves RSS text links")
        check(articles.first?.pubDate == DateParser.parse("2026-10-18T04:00:00Z"), "Dublin Core dates are retained")
        check(articles.first?.source == "Publisher", "A Dublin Core creator does not replace the publisher")
        check(
            articles.first?.readerDocument?.images?.first?.credit == "Agency Photographer",
            "Group-level Media RSS credits reach reader media")
        check(
            articles.first?.imageUrl == "https://example.com/reports/photo.jpg",
            "Relative media resolves inside its XML base")

        let rdf = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>RDF Publisher</title></channel>
            <item rdf:about="https://example.com/rdf"><dc:title>RDF report</dc:title><link>https://example.com/rdf</link>
            <dc:date>2026-10-18T04:00:00Z</dc:date></item></rdf:RDF>
            """
        check(
            FeedXMLParser(data: Data(rdf.utf8), feedURL: base).parse().first?.pubDate != DateParser.unknownDate,
            "RDF/RSS 1.0 Dublin Core dates remain supported")

        check(
            FeedXMLParser(data: Data(rdf.utf8), feedURL: base).parse().first?.title == "RDF report",
            "FeedKit maps a Dublin Core title not handled by the compatibility parser")

        let malicious =
            "<!DOCTYPE rss [<!ENTITY payload 'expanded'>]><rss><channel><item><title>&payload;</title></item></channel></rss>"
        let entityParser = FeedXMLParser(data: Data(malicious.utf8), feedURL: base)
        check(
            entityParser.parse().isEmpty && entityParser.parseError != nil,
            "Entity declarations are rejected before expansion")
        let delayedEntity = String(repeating: " ", count: 65_536) + malicious
        check(
            FeedXMLParser(data: Data(delayedEntity.utf8), feedURL: base).parse().isEmpty,
            "Entity declarations beyond the prolog scan are rejected by the streaming delegate")
        check(
            FeedXMLParser(data: malicious.data(using: .utf16)!, feedURL: base).parse().isEmpty,
            "UTF-16 entity declarations cannot bypass the prolog guard")
        let deep =
            "<rss><channel>" + String(repeating: "<x>", count: 65) + String(repeating: "</x>", count: 65)
            + "</channel></rss>"
        check(
            FeedXMLParser(data: Data(deep.utf8), feedURL: base).parse().isEmpty, "XML nesting is capped before FeedKit")

        for version in ["https://jsonfeed.org/version/1", "https://jsonfeed.org/version/1.1"] {
            let json: [String: Any] = [
                "version": version, "title": "JSON Publisher",
                "items": [
                    [
                        "id": "json-story", "url": "https://example.com/json",
                        "content_html": "<p>\(first)</p><p>\(second)</p>",
                        "date_published": "2026-10-18T04:00:00.125Z", "authors": [["name": "Reporter"]],
                    ],
                    [
                        "id": "legacy", "link": "https://example.com/legacy", "pubDate": "18 Oct 2026 04:00 GMT",
                        "description": "<p>Legacy summary</p>", "thumbnail": "https://example.com/image.jpg",
                        "categories": ["Science"], "tags": [], "date_modified": 42,
                        "author": "unused malformed metadata",
                    ],
                    ["id": "undated", "url": "https://example.com/undated", "date_published": "not a date"],
                ],
            ]
            let result = JSONFeedParser.parse(data: try! JSONSerialization.data(withJSONObject: json), feedURL: base)!
            check(result.count == 3, "FeedKit reads JSON Feed 1.0/1.1 and legacy aliases")
            check(result[0].readerDocument?.hasPublisherText == true, "JSON Feed HTML keeps reader v4 structure")
            check(
                result[1].description == "Legacy summary" && result[1].category == "Science",
                "Legacy JSON aliases retain cleaned summary and category")
            check(
                result[1].pubDate != DateParser.unknownDate,
                "Permissive RFC822 aliases parse without seconds or weekday")
            check(result[2].pubDate == DateParser.unknownDate, "Malformed dates retain the stable unknown sentinel")
        }
        let manyXML =
            "<rss><channel>"
            + (0...500).map {
                "<item><title>Story \($0)</title><link>https://example.com/\($0)</link></item>"
            }.joined() + "</channel></rss>"
        check(
            FeedXMLParser(data: Data(manyXML.utf8), feedURL: base).parse().count == 500,
            "The streaming and FeedKit paths preserve the 500-story XML cap")
        let manyJSON: [String: Any] = [
            "items": (0...500).map { ["id": "story-\($0)", "url": "https://example.com/\($0)"] }
        ]
        check(
            JSONFeedParser.parse(data: try! JSONSerialization.data(withJSONObject: manyJSON), feedURL: base)?.count
                == 500,
            "JSON Feed decoding keeps only the first 500 stories")
        let largeXML =
            "<rss><channel><item><title>Large report</title><link>https://example.com/large</link><description>"
            + String(repeating: "x", count: 524_289) + "</description></item></channel></rss>"
        check(
            FeedXMLParser(data: Data(largeXML.utf8), feedURL: base).parse().count == 1,
            "An item exceeding the FeedKit adapter budget retains the streaming compatibility path")

        check(DateParser.parse("Tues, 6 November 2007 12:00:00 GMT") != nil, "Permissive weekday spellings work")
        check(DateParser.parse("impossible") == nil, "Invalid dates do not become current time")
        print("✅ SwiftSoup / FeedKit parsing regressions passed")
    }
}
