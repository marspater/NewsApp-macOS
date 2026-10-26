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

        let categorized = """
            <rss><channel><title>Publisher</title><item><title>Category boundaries</title><link>https://example.com/categories</link>
            <category>World</category><category>Artificial intelligence</category><category>Business</category>
            </item></channel></rss>
            """
        check(
            FeedXMLParser(data: Data(categorized.utf8), feedURL: base).parse().first?.category == "World",
            "Successive RSS categories must not concatenate into a fabricated label")
        let titledTags = EntityResult.readerTags(from: [
            .init(name: "Donald Trump", type: .person), .init(name: "Mr. Trump", type: .person),
            .init(name: "Trump", type: .person), .init(name: "Russia", type: .place),
        ])
        check(
            titledTags.map(\.name) == ["Donald Trump", "Russia"],
            "Honorific surname aliases collapse without deleting places")
        let articleAndFurniture = """
            <main><article class="article-body-commercial-selector"><p>\(first)</p><p>\(second)</p>
            <div class="also-read"><p>Unrelated recommendation with enough prose to look like a paragraph.</p>
            <img src="https://example.com/thumbnail.jpg" width="90" height="90"></div>
            <h2>Most viewed</h2><span>Explore more on these topics</span></article>
            <section><p>Other news furniture outside the publisher body should never enter the story.</p></section></main>
            """
        let clean = pipeline.extractFromHTML(articleAndFurniture, baseUrl: base)
        check(
            clean.content == first + "\n\n" + second,
            "Explicit publisher bodies exclude Guardian furniture and Hindu related cards")
        let alJazeera = """
            <main><div class="wysiwyg wysiwyg--all-content"><p>\(first)</p><div><p>\(second)</p></div>
            <p>Final section: \(first)</p></div><aside><p>Other coverage from the site.</p></aside></main>
            """
        check(
            pipeline.extractFromHTML(alJazeera, baseUrl: base).content?.contains("Final section:") == true,
            "Al Jazeera's explicit body retains later nested paragraphs")
        let paywall = """
            <article><p>Subscribe to unlock this article</p><h2>Save 50% on Standard Digital</h2>
            <p>Save now on essential digital access to trusted journalism on any device for your first year.</p>
            <p>Savings based on monthly annualised price and the subscription offer ends later this month.</p></article>
            """
        check(
            !pipeline.extractFromHTML(paywall, baseUrl: base).isSuccess,
            "A subscription offer is not accepted as article prose")
        check(
            pipeline.extractFromHTML(paywall, baseUrl: base) == .subscriberOnly,
            "A subscription offer is reported as a subscriber-only story")
        let barrier = """
            <html><head><script type="application/ld+json">{"@type":"NewsArticle","headline":"Markets",
            "isAccessibleForFree":"False"}</script></head><body><div class="barrier-grid"><div class="paywall">
            <p>Try unlimited access. Then pay monthly.</p></div></div></body></html>
            """
        check(
            pipeline.extractFromHTML(barrier, baseUrl: base) == .subscriberOnly,
            "An FT-style barrier with isAccessibleForFree=false is subscriber-only, not a parser failure")
        check(
            pipeline.extractFromHTML(
                "<html><body><div class=\"barrier\"><p>Short text.</p></div><article><p>\(first)</p><p>\(second)</p></article></body></html>",
                baseUrl: base
            ).isSuccess, "Readable prose next to an unrelated barrier class still succeeds")
        let structuredBody = """
            <html><head><script type="application/ld+json">{"@graph":[{"@type":"NewsArticle",
            "articleBody":"\(first)\\n\(second)\\nFinal structured paragraph: \(first)"}]}</script></head>
            <body><main><p>\(first)</p></main></body></html>
            """
        check(
            pipeline.extractFromHTML(structuredBody, baseUrl: base).content?.contains("Final structured paragraph")
                == true,
            "A thin DOM body falls back to the publisher's JSON-LD articleBody")
        let editorial = pipeline.extractFromHTML(
            """
            <article><header class="article-header"><h1>Bridge</h1><p class="standfirst">The council says repairs will finish before winter, ending weeks of detours.</p></header>
            <p>\(first)</p><aside class="pull-quote">The structure remained intact after the storm passed.</aside>
            <aside class="related"><p>Other coverage from the site that should never appear.</p></aside><p>\(second)</p></article>
            """, baseUrl: base)
        check(
            editorial.content?.contains("repairs will finish before winter") == true,
            "A header standfirst is kept inside the article")
        check(
            editorial.document?.blocks.contains { $0.kind == .pullQuote && $0.text.hasPrefix("The structure") } == true,
            "An aside pull quote becomes a pull quote block")
        check(editorial.content?.contains("Other coverage") == false, "Related-story asides stay excluded")
        let hydrated = """
            <html><head><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"story":
            {"bodyHtml":"<p>\(first)</p><p>\(second)</p><p>\(second)</p><p>Hydrated final paragraph: \(first)</p>"}}}}</script></head>
            <body><div id="__next"><p>\(first)</p></div></body></html>
            """
        check(
            pipeline.extractFromHTML(hydrated, baseUrl: base).content?.contains("Hydrated final paragraph") == true,
            "A thin page falls back to its Next.js hydration body")
        check(
            pipeline.extractFromHTML(
                hydrated.replacingOccurrences(
                    of: "<script id=",
                    with: "<script type=\"application/ld+json\">{\"articleBody\":\"Short teaser.\"}</script><script id="
                ),
                baseUrl: base
            ).content?.contains("Hydrated final paragraph") == true,
            "A teaser-length JSON-LD body does not hide the hydration body")
        let stamped = pipeline.extractFromHTML(
            """
            <article><ul><li>· <time datetime="2026-10-20T13:13:26Z">20 October 2026, 14:13 BST</time></li></ul>
            <p>\(first)</p><p>\(second) It was confirmed at <time>14:13</time> by officials on site.</p></article>
            """, baseUrl: base)
        check(stamped.content?.contains("14:13 BST") == false, "A metadata strip timestamp is not story text")
        check(stamped.content?.contains("confirmed at 14:13") == true, "Prose that mentions a time is kept")
        let sections = """
            <article><hr><p>\(first)</p><hr><hr><p>\(second)</p><hr></article>
            """
        check(
            pipeline.extractFromHTML(sections, baseUrl: base).document?.blocks.map(\.kind)
                == [.paragraph, .divider, .paragraph],
            "Section rules survive only between content, once")
        let wall = (1...8).map {
            "Sentence \($0) describes the bridge inspection and the repairs in some detail today."
        }
        .joined(separator: " ")
        let walled = pipeline.extractFromHTML(
            "<article><p>\(wall)<strong> Strong finding</strong> closes it.</p><p>\(second)</p></article>",
            baseUrl: base)
        let wallBlocks = walled.document?.blocks.filter { $0.kind == .paragraph } ?? []
        check(wallBlocks.count >= 3, "A wall-of-text paragraph splits at sentence boundaries")
        check(
            wallBlocks.dropLast().map(\.text).joined(separator: " ") == "\(wall) Strong finding closes it.",
            "Splitting a paragraph keeps every word in order")
        check(
            wallBlocks.dropLast().last?.inlineRuns?.contains { $0.strong } == true
                && wallBlocks.allSatisfy { $0.inlineRuns != nil },
            "Inline formatting is split with the paragraph")

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

        let nestedMedia = """
            <rss xml:base="../reports/" xmlns:m="http://search.yahoo.com/mrss/"><channel>
            <item xml:base="first/"><title>First</title><link>story</link><m:group xml:base="photos/">
            <m:credit>First photographer</m:credit><m:content url="one.jpg" type="image/jpeg" width="1200"/>
            </m:group></item><item xml:base="second/"><title>Second</title><link>story</link>
            <m:group xml:base="photos/"><m:credit>Second photographer</m:credit>
            <m:content url="two.jpg" type="image/jpeg" width="1200"/></m:group></item></channel></rss>
            """
        let nestedArticles = FeedXMLParser(data: Data(nestedMedia.utf8), feedURL: base).parse()
        check(
            nestedArticles.map(\.imageUrl) == [
                "https://example.com/reports/first/photos/one.jpg",
                "https://example.com/reports/second/photos/two.jpg",
            ], "Each item preserves root, item and media-group relative XML bases during FeedKit enrichment")
        check(
            nestedArticles.last?.readerDocument?.images?.first?.credit == "Second photographer",
            "Separate item media credits remain associated with their own images")

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
        for encoding in [String.Encoding.utf32, .isoLatin1] {
            let encoded = "<?xml version=\"1.0\"?><!-- café -->" + malicious
            let parser = FeedXMLParser(data: encoded.data(using: encoding)!, feedURL: base)
            check(
                parser.parse().isEmpty && parser.parseError == "XML entity declarations are not allowed",
                "Entity prolog detection does not depend on UTF-8 decoding")
        }
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

        // HTML entity decoding in title & category and source name newline cleaning
        let xmlWithEntities = """
            <rss><channel><title>BBC News\n        BBC News</title>
            <item><title>SpaceX&#8217;s gamble with AT&amp;#038;T</title>
            <link>https://example.com/spacex</link>
            <description>Summary</description>
            <category>Sci&amp;Tech</category>
            </item></channel></rss>
            """
        let parsedEntities = FeedXMLParser(data: Data(xmlWithEntities.utf8), feedURL: base).parse()
        check(parsedEntities.first?.title == "SpaceX’s gamble with AT&T", "HTML entities in RSS titles are decoded")
        check(parsedEntities.first?.source == "BBC News", "Channel titles with newlines are cleaned of duplicate lines")
        check(parsedEntities.first?.category == "Sci&Tech", "HTML entities in categories are decoded")

        // Teaser detection in FeedXMLParser
        let teaserFeed = """
            <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>The Verge</title>
            <item><title>Teaser story</title><link>https://example.com/teaser</link>
            <description>Short teaser summary</description>
            <content:encoded><![CDATA[<p>First teaser paragraph.</p><p>Second teaser paragraph. <a href="https://example.com/full">Continue reading...</a></p>]]></content:encoded>
            </item></channel></rss>
            """
        let parsedTeaser = FeedXMLParser(data: Data(teaserFeed.utf8), feedURL: base).parse().first
        check(parsedTeaser?.contentFetched == true, "Items with explicit content:encoded have contentFetched == true")
        check(
            parsedTeaser?.readerDocument?.hasCompleteArticleBody == false,
            "Teaser items must report hasCompleteArticleBody == false")

        // Boilerplate filtering for video errors, Google Preferred Source, and publisher footers
        check(
            ArticleContentRedactor.isBoilerplateLine(
                "To play this video you need to enable JavaScript in your browser."),
            "Video error heading is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine("This video can not be played"),
            "Video error paragraph is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine("Video Duration 28 minutes 30 seconds"),
            "Video duration is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine(
                "Add CNA as a trusted source to help Google better understand and surface our content in search results."
            ), "Google trusted source CTA is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine(
                "If you rely on our team for trusted reporting, please take a moment to select us as your Preferred Source on Google"
            ), "Google preferred source CTA is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine("CBC's Journalistic Standards and Practices"),
            "CBC standards is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine("Corrections and clarifications"),
            "Corrections footer is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine("Edited by: Jenipher Camino Gonzalez"),
            "Editor footer is boilerplate")
        check(
            ArticleContentRedactor.isBoilerplateLine("Published - October 18, 2026 09:36 am IST"),
            "Standalone dateline is boilerplate")

        print("✅ SwiftSoup / FeedKit parsing regressions passed")
    }

    static func runEmbeddingIntegration() async throws {
        let title = "Anthropic releases Claude coding model with improved reasoning"
        let summary =
            "Anthropic released its Claude coding model with improved reasoning and software development tools."
        let html =
            "<div itemprop=articleBody><p>\(summary) Developers can use the release to review code and diagnose problems in existing software.<p>The company said the updated model supports longer coding tasks and detailed technical explanations. The release includes tools for developers to evaluate the changes in their own projects.</div>"
        let date = "2026-10-18T04:00:00Z"
        let xml = """
            <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>First Wire</title>
            <item><title>\(title)</title><link>https://first.example.com/claude</link>
            <description>\(summary)</description><pubDate>\(date)</pubDate>
            <content:encoded><![CDATA[\(html)]]></content:encoded></item></channel></rss>
            """
        let json: [String: Any] = [
            "version": "https://jsonfeed.org/version/1.1", "title": "Second Wire",
            "items": [
                [
                    "id": "claude", "url": "https://second.example.com/claude", "title": title,
                    "summary": summary, "date_published": date, "content_html": html,
                ]
            ],
        ]
        let articles =
            FeedXMLParser(data: Data(xml.utf8)).parse()
            + (JSONFeedParser.parse(data: try JSONSerialization.data(withJSONObject: json), feedURL: "") ?? [])
        precondition(articles.count == 2, "Both feed formats must produce an article")
        precondition(
            articles.allSatisfy { $0.readerDocument?.hasPublisherText == true },
            "Both feed formats must retain repaired publisher text")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseEngine(path: root.appendingPathComponent("integration.sqlite3").path)
        try await database.open()
        _ = try await database.upsertArticles(articles)
        let report = try await EventClusterer.run(in: database, now: articles[0].pubDate)
        let vectors = try await database.fetchArticleEmbeddings(
            articleIDs: articles.map(\.id), modelVersion: SentenceEmbedder.modelVersion)
        precondition(vectors.count == 2, "Production clustering must compute and persist both feed embeddings")
        precondition(
            vectors.values.allSatisfy { vector in
                vector.count == SentenceEmbedder.vectorDimension
                    && abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.001
            }, "Parsed article embeddings must have the expected dimension and unit norm")
        precondition(report.created == 1, "Equivalent parsed reports must form one event through the hybrid matcher")
        try await testReaderDocumentStoragePreservation()
        print("✅ Feed parsing → reader extraction → embeddings → event clustering integration passed")
    }

    static func testReaderDocumentStoragePreservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseEngine(path: root.appendingPathComponent("preservation.sqlite3").path)
        try await database.open()

        let initialDoc = ReaderDocument(
            version: 5,
            blocks: [
                ReaderBlock(kind: .paragraph, text: "Initial rich paragraph 1"),
                ReaderBlock(kind: .paragraph, text: "Initial rich paragraph 2"),
            ],
            images: [ReaderImageCandidate(url: "https://example.com/lead.jpg", origin: .body)],
            leadImageURL: "https://example.com/lead.jpg"
        )
        let article = FeedArticle(
            title: "Test Article",
            link: "https://example.com/story",
            guid: "test-guid-1",
            description: "Test description",
            pubDate: Date(),
            source: "Test Source",
            fullContent: "Initial rich paragraph 1\n\nInitial rich paragraph 2",
            readerDocument: initialDoc
        )
        try await database.upsertArticles([article])

        var stored = try await database.fetchArticles(limit: 1, id: article.id).first
        precondition(stored?.readerDocument != nil, "Article must have readerDocument after initial upsert")

        // 1. Updating enrichment with content ONLY (no readerDocument) MUST NOT erase reader_document
        _ = try await database.updateEnrichment(
            articleId: article.id,
            update: .init(
                content: "Initial rich paragraph 1\n\nInitial rich paragraph 2 (enriched)", readerDocument: nil)
        )
        stored = try await database.fetchArticles(limit: 1, id: article.id).first
        precondition(
            stored?.readerDocument != nil,
            "updateEnrichment without readerDocument must NOT wipe stored readerDocument to NULL!")
        precondition(stored?.readerDocument?.blocks.count == 2, "Stored readerDocument blocks must be preserved")

        // 2. Incoming teaser snippet must NOT overwrite stored rich readerDocument or content
        let teaser = FeedArticle(
            title: "Test Article",
            link: "https://example.com/story",
            guid: "test-guid-1",
            description: "Test description",
            pubDate: Date(),
            source: "Test Source",
            fullContent: "Short teaser snippet",
            contentFetched: false,
            readerDocument: ReaderDocument(
                version: 6,
                blocks: [ReaderBlock(kind: .paragraph, text: "Short teaser snippet")],
                isComplete: false
            )
        )
        try await database.upsertArticles([teaser])
        stored = try await database.fetchArticles(limit: 1, id: article.id).first
        precondition(
            stored?.readerDocument?.blocks.count == 2, "Incoming teaser must NOT overwrite stored rich readerDocument!")
        precondition(
            stored?.fullContent?.contains("Initial rich paragraph 1") == true, "Stored full content must be preserved!")
        precondition(
            stored?.fullContent?.contains("Short teaser snippet") == false,
            "Incoming teaser content must NOT overwrite stored content!")
    }
}
