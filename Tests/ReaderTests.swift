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

/// The Reader suites of the regression runner; `ReaderTests.run()` is this atom's entry point.
enum ReaderTests {
    static func run() async throws { try await NewsTests.runReaderTests() }
}

extension NewsTests {
    static func runReaderTests() async throws {
        let fixtureRoot = defaultFixtureRoot
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testReaderFigures", { try await testReaderFigures(fixtureRoot: fixtureRoot) }),
            ("testReaderExtractionFidelity", { testReaderExtractionFidelity(fixtureRoot: fixtureRoot) }),
            ("testReaderParsingRegressions", { await testReaderParsingRegressions() }),
            ("testStructuredReaderAndTags", { await testStructuredReaderAndTags() }),
            ("testReaderStoreUpdates", { await testReaderStoreUpdates() }),
            ("testPublisherContentProvenance", { try await testPublisherContentProvenance() }),
            ("testContentExtractionPipelineDeep", { await testContentExtractionPipelineDeep() }),
            ("testExtractionURLRejection", { await testExtractionURLRejection() }),
            ("testNoteAnchoring", { testNoteAnchoring() }),
            ("testSentenceDiffAndStoryEvolution", { testSentenceDiffAndStoryEvolution() }),
            ("testArticleContentRedactionAndTypography", { await testArticleContentRedactionAndTypography() }),
            ("testArticleDetailReadingExperienceOverhaul", { await testArticleDetailReadingExperienceOverhaul() }),
            ("testReaderPhaseC", { try await testReaderPhaseC(fixtureRoot: fixtureRoot) }),
            ("testReaderPassageMatcher", { testReaderPassageMatcher() }),
            ("testBBCExtractionFixture", { await testBBCExtractionFixture() }),
            ("testMultiPublisherExtractionFixtures", { await testMultiPublisherExtractionFixtures() }),
            ("testReaderFurnitureRemoval", { await testReaderFurnitureRemoval() }),
            ("testContentQualityValidation", { await testContentQualityValidation() }),
            ("testExtractionOutcomeDiagnostics", { await testExtractionOutcomeDiagnostics() }),
        ]
        try await runSuite(tests)
    }

    @MainActor
    static func testReaderStoreUpdates() async {
        let suiteName = testDefaultsSuite("test.reader")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let manager = FeedManager(settings: AppSettings(defaults: defaults), store: store, schedulesRefresh: false)
        let article = FeedArticle(
            title: "Report", link: "https://example.com/report", guid: "reader-test", description: "Preview",
            pubDate: Date(), source: "Publisher")
        await store.batchUpsert(articles: [article])
        await store.updateEnrichment(id: article.id, category: "Science", content: "The complete publisher article.")
        assertEqual(
            manager.articles.first?.fullContent, "The complete publisher article.",
            "Feed views receive extracted text immediately")
        assertEqual(
            manager.articles.first?.category, "Science", "Category changes propagate without another feed refresh")
        let classifiedRevision = store.revision
        var publications = 0
        let observation = store.$articles.dropFirst().sink { _ in publications += 1 }
        assertTrue(
            await store.updateEnrichment(id: article.id, category: "Science"), "Repeated classification persists")
        assertEqual(store.revision, classifiedRevision, "Unchanged enrichment does not invalidate feed or reader")
        assertEqual(publications, 0, "Unchanged enrichment does not republish the article collection")
        await store.updateEnrichment(id: article.id, category: "World")
        assertEqual(store.revision, classifiedRevision + 1, "A changed classification still invalidates queries")
        assertEqual(publications, 1, "A changed classification publishes once")
        observation.cancel()

        // Background classification publishes a burst together, with the latest state of every story (#778).
        let burst = (0..<5).map { index in
            FeedArticle(
                title: "Burst \(index)", link: "https://example.com/burst-\(index)", guid: "burst-\(index)",
                description: "Preview", pubDate: Date(), source: "Publisher")
        }
        await store.batchUpsert(articles: burst)
        let burstRevision = store.revision
        var burstPublications = 0
        let burstObservation = store.$articles.dropFirst().sink { _ in burstPublications += 1 }
        // The batch waits longer than the writes take on a loaded machine; the test publishes it explicitly.
        store.coalescedPublicationDelay = .seconds(600)
        for article in burst {
            await store.updateEnrichment(id: article.id, category: "Science", coalescesPublication: true)
        }
        await store.updateEnrichment(id: burst[0].id, category: "World", coalescesPublication: true)
        assertEqual(burstPublications, 0, "Background classification waits to be published together")
        assertEqual(store.revision, burstRevision, "Waiting classification does not reload queries yet")
        await store.flushPendingPublications()
        assertEqual(burstPublications, 1, "A classification burst publishes the article collection once")
        assertEqual(store.revision, burstRevision + 1, "A classification burst reloads queries once")
        assertEqual(
            store.articles.first { $0.title == "Burst 0" }?.category, "World",
            "The latest classification of a story is the one published")
        assertEqual(
            store.articles.filter { $0.title.hasPrefix("Burst ") && $0.title != "Burst 0" }.compactMap(\.category),
            Array(repeating: "Science", count: 4), "Every story of the burst is published")
        burstObservation.cancel()

        let delegate = SecureSessionDelegateCoordinator()
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let task = URLSession.shared.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for destination in ["file:///etc/passwd", "https://example.com:22/story", "http://example.com/story"] {
            var rejected = false
            delegate.urlSession(
                .shared, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: destination)!)
            ) { redirected in
                rejected = redirected == nil
            }
            assertTrue(rejected, "Unsafe redirect must be rejected before connection")
        }
        task.cancel()

        // Redirect safety state is keyed per task object, not by task identifier across sessions (#808). The
        // delegate resolves nothing (#945), so the allowed redirect stays off the network.
        let keyed = SecureSessionDelegateCoordinator()
        let sessionConfig = URLSessionConfiguration.ephemeral
        let sessionA = URLSession(configuration: sessionConfig)
        let sessionB = URLSession(configuration: sessionConfig)
        defer {
            sessionA.invalidateAndCancel()
            sessionB.invalidateAndCancel()
        }
        let taskA = sessionA.dataTask(with: URL(string: "http://example.com/start")!)
        let taskB = sessionB.dataTask(with: URL(string: "https://example.com/start")!)
        assertEqual(
            taskA.taskIdentifier, taskB.taskIdentifier,
            "Two distinct sessions issue overlapping task identifiers starting at 1")

        let responseA = HTTPURLResponse(
            url: taskA.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirectedA: URLRequest? = nil
        keyed.urlSession(
            sessionA, task: taskA, willPerformHTTPRedirection: responseA,
            newRequest: URLRequest(url: URL(string: "http://example.com/next")!)
        ) { redirectedA = $0 }
        assertTrue(redirectedA != nil, "Task A with HTTP scheme permits HTTP redirect")

        let responseB = HTTPURLResponse(
            url: taskB.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirectedB: URLRequest? = nil
        keyed.urlSession(
            sessionB, task: taskB, willPerformHTTPRedirection: responseB,
            newRequest: URLRequest(url: URL(string: "http://example.com/downgrade")!)
        ) { redirectedB = $0 }
        assertTrue(
            redirectedB == nil,
            "Task B with HTTPS scheme refuses downgrade to HTTP despite matching task identifier")

        // Task B uses up its redirect depth, then task A completes; a dropped state would start B at zero again.
        let safe = URLRequest(url: URL(string: "https://example.com/safe")!)
        for _ in 1..<SecureHTTPClient.maxRedirects {
            keyed.urlSession(sessionB, task: taskB, willPerformHTTPRedirection: responseB, newRequest: safe) { _ in }
        }
        keyed.urlSession(sessionA, task: taskA, didCompleteWithError: nil)

        var redirectedB2: URLRequest? = URLRequest(url: URL(string: "https://example.com/unset")!)
        keyed.urlSession(sessionB, task: taskB, willPerformHTTPRedirection: responseB, newRequest: safe) {
            redirectedB2 = $0
        }
        assertTrue(
            redirectedB2 == nil,
            "Task B keeps its redirect count after task A completes, so the redirect past the limit is refused")

        taskA.cancel()
        taskB.cancel()

        // Proxy refresh is required whenever the gateway listener port changes (#807).
        assertTrue(
            WebPreviewPolicy.needsProxyRefresh(configuredPort: nil, currentPort: 8080),
            "Unconfigured port needs refresh")
        assertTrue(
            WebPreviewPolicy.needsProxyRefresh(configuredPort: 8080, currentPort: 8081), "Changed port needs refresh")
        assertFalse(
            WebPreviewPolicy.needsProxyRefresh(configuredPort: 8080, currentPort: 8080),
            "Unchanged port does not refresh")
        assertTrue(
            WebPreviewPolicy.needsProxyRefresh(configuredPort: UInt16(8080), currentPort: UInt16(8081)),
            "UInt16 changed port needs refresh")
        assertFalse(
            WebPreviewPolicy.needsProxyRefresh(configuredPort: UInt16(8080), currentPort: UInt16(8080)),
            "UInt16 unchanged port does not refresh")

        // A refused subframe is dropped quietly; only a refused main frame reports an error (#802).
        var insecureRefused = false
        do { try await SecureHTTPClient.shared.validateDestination(URL(string: "http://example.com/frame")!) } catch {
            insecureRefused = true
        }
        assertTrue(insecureRefused, "An http address is refused while insecure HTTP is off")
        assertTrue(
            WebPreviewPolicy.refusalMessage(isMainFrame: true) != nil, "A main-frame refusal reports an error")
        assertTrue(WebPreviewPolicy.refusalMessage(isMainFrame: false) == nil, "A subframe refusal is quiet")
        assertTrue(WebPreviewPolicy.isMainFrame(targetFrameIsMain: nil), "A new-window navigation counts as main frame")
    }

    static func testReaderParsingRegressions() async {
        for (identifier, excluded) in [
            ("article-commentary", false), ("comment-thread", true),
            ("RELATED-ARTICLES", true), ("unrelated-content", false),
        ] {
            let node = DOMElementNode(tag: "div", attributes: ["class": identifier], text: "Publisher prose")
            assertEqual(
                node.isReaderExcluded, excluded, "Cached exclusion regex preserves token boundaries and case matching")
        }
        let topic = await ArticleClassifier.shared.classify(
            title: "NASA launches space telescope", description: "Astronomy mission")
        assertEqual(topic.category, "Science", "Cheap ingestion classification works without generative inference")
        let pipeline = ContentExtractionPipeline.shared
        assertEqual(
            HTMLDOMBuilder.parse(html: "<p>Before<!-- hidden\ncomment --> after.</p>").combinedText(),
            "Before after.", "Cached comment regex removes multiline comments")
        let encodedHTML = "<p>Publisher caf\u{00e9}</p>"
        let latin1Data = encodedHTML.data(using: .isoLatin1)!
        let latin1Response = HTTPURLResponse(
            url: URL(string: "https://example.com/article")!,
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; CHARSET='ISO-8859-1'"])!
        assertEqual(
            pipeline.decodeHTML(data: latin1Data, response: latin1Response), encodedHTML,
            "Cached header regex preserves case-insensitive quoted charset decoding")
        for meta in ["<meta charset='iso-8859-1'>", "<meta content='text/html;charset=iso-8859-1'>"] {
            let document = meta + encodedHTML
            assertEqual(
                pipeline.decodeHTML(data: document.data(using: .isoLatin1)!), document,
                "Cached meta regexes preserve both charset declarations")
        }
        // #819: one stray byte in a UTF-8 page, and a prefix fetch cut inside a character, keep UTF-8 text.
        var strayByte = Data("<p>It\u{2019}s caf\u{00e9} ".utf8)
        strayByte.append(0xFF)
        strayByte.append(contentsOf: Data("na\u{00ef}ve</p>".utf8))
        assertEqual(
            pipeline.decodeHTML(data: strayByte), "<p>It\u{2019}s caf\u{00e9} \u{FFFD}na\u{00ef}ve</p>",
            "An undeclared UTF-8 page with one invalid byte is not decoded as Latin-1")
        let utf8Response = HTTPURLResponse(
            url: URL(string: "https://example.com/article")!,
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        assertEqual(
            pipeline.decodeHTML(data: strayByte, response: utf8Response),
            "<p>It\u{2019}s caf\u{00e9} \u{FFFD}na\u{00ef}ve</p>", "A declared UTF-8 page decodes leniently")
        let cut = Data("<p>caf\u{00e9} \u{2019}".utf8).dropLast(2)
        assertEqual(
            pipeline.decodeHTML(data: Data(cut), response: utf8Response), "<p>caf\u{00e9} ",
            "A trailing partial sequence from a prefix fetch is trimmed")
        assertEqual(
            pipeline.decodeHTML(data: "<p>caf\u{00e9} na\u{00ef}ve</p>".data(using: .isoLatin1)!),
            "<p>caf\u{00e9} na\u{00ef}ve</p>", "An undeclared Latin-1 page still decodes as Latin-1")
        assertEqual(
            pipeline.decodeHTML(data: Data("<p>caf\u{00e9} \u{FFFD}</p>".utf8)), "<p>caf\u{00e9} \u{FFFD}</p>",
            "Valid UTF-8 containing a literal replacement character stays UTF-8")
        var tied = Data("<p>caf\u{00e9} ".utf8)
        tied.append(0xFF)
        assertEqual(
            pipeline.decodeHTML(data: tied), "<p>caf\u{00e9} \u{FFFD}",
            "One valid multi-byte character against one invalid byte keeps UTF-8")
        assertEqual(
            pipeline.decodeHTML(data: "<p>na\u{00ef}ve \u{00ff}".data(using: .isoLatin1)!), "<p>na\u{00ef}ve \u{00ff}",
            "A trailing byte that cannot start a UTF-8 sequence is not trimmed from a Latin-1 page")
        let inline = "<p>The <strong>central bank</strong> raised <a href='/rate'>rates</a> today.</p>"
        assertEqual(
            HTMLDOMBuilder.parse(html: inline).combinedText(), "The central bank raised rates today.",
            "Inline text retains publisher order and punctuation")
        let prose =
            "The central bank published its quarterly report with detailed forecasts for inflation and employment across the economy."
        let second =
            "Independent economists reviewed the figures and described the outlook as stable, with further updates expected next month."
        let html = "<SCRIPT>ignored()</SCRIPT><ARTICLE><P>\(prose)<P>\(second)</ARTICLE>"
        assertEqual(
            pipeline.extractFromHTML(html).content, "\(prose)\n\n\(second)",
            "Uppercase raw tags and optional paragraph endings preserve the body")
        let third =
            "Officials said the review would continue into next year, and a public consultation is planned before any decision."
        let threeParagraphs = "<p>\(prose)</p><p>\(second)</p><p>\(third)</p>"
        assertEqual(
            pipeline.extractFromHTML(
                "<script>document.write('<script src=\"/jquery.js\">\\x3C/script>')</script><article>\(threeParagraphs)</article>"
            ).content, "\(prose)\n\n\(second)\n\n\(third)",
            "Markup written inside a script does not swallow the page (Africanews, CNA, Science News)")
        assertEqual(
            pipeline.extractFromHTML(
                "<style>a::before { content: '<style>'; } /* </b> */</style><script>var s = '</div>';</script><article>\(threeParagraphs)</article>"
            ).content, "\(prose)\n\n\(second)\n\n\(third)",
            "Style and script end at their own first closing tag, whatever markup they contain")
        assertEqual(
            pipeline.extractFromHTML(
                "<nav><nav><p>Menu link text that is long enough to read as prose here.</p></nav></nav><article>\(threeParagraphs)</article>"
            )
            .content, "\(prose)\n\n\(second)\n\n\(third)",
            "Nested ignored elements still close by depth")
        assertEqual(
            pipeline.extractFromHTML(
                "<div class='menu'><h3>Topics</h3><h3>Sections</h3></div><div class='entry-content'><figure><img src='https://news.example/a.jpg' width='1200' height='800'></figure>\(threeParagraphs)</div>"
            ).content, "\(prose)\n\n\(second)\n\n\(third)",
            "An explicit publisher body keeps every paragraph (NASA)")
        assertEqual(
            pipeline.extractFromHTML(
                "<div class='menu'><h3>Topics</h3><h3>Sections</h3><p>Top Programming Languages</p></div><div class='body-description'>\(threeParagraphs)</div>"
            ).content, "\(prose)\n\n\(second)\n\n\(third)",
            "A RebelMouse body beats the site menu (IEEE Spectrum)")
        assertEqual(
            pipeline.extractFromHTML(
                "<article><p>\(prose)</p><div class='pmc-paywall'><p>\(second)</p><p>\(third)</p></div></article>"
            )
            .content, "\(prose)\n\n\(second)\n\n\(third)",
            "A metering wrapper holding the story stays (Variety)")
        assertEqual(
            pipeline.extractFromHTML(
                "<article>\(threeParagraphs)<div class='paywall'><p>Subscribe today for unlimited access to every story we publish.</p></div></article>"
            ).content, "\(prose)\n\n\(second)\n\n\(third)",
            "A paywall prompt without the story is still furniture")
        assertEqual(
            pipeline.extractFromHTML(
                "<article><div x-cloak class='panel'><label>Size</label><select><option>Small</option><option>Standard</option><option>Large</option></select> Links Standard Orange</div>\(threeParagraphs)</article>"
            ).content, "\(prose)\n\n\(second)\n\n\(third)",
            "Script-only panels and form controls are not story text (Ars Technica)")
        assertEqual(
            pipeline.extractFromHTML(
                "<article><div class='story'>\(threeParagraphs)<p>\(prose)</p><p>\(second)</p></div><div class='article-body'><p>Sponsored: a short report on how security teams measure the defenses they deploy.</p><p>Download the free report today to compare your scores with industry peers.</p></div></article>"
            ).content?.hasPrefix(prose), true,
            "A small box with an explicit body class does not replace the story (BleepingComputer)")
        let standfirst = "Officials expect the review to shape spending plans for the coming decade across the region."
        let guardianLike = pipeline.extractFromHTML(
            "<article><div data-gu-name='media'><figure><img src='https://news.example/lead.jpg' width='1200' height='800'><figcaption>Crews at work.</figcaption></figure></div><div class='player-note'><p>This story is voiced by an automated narrator for listeners on the go.</p></div><div data-gu-name='standfirst'><p>\(standfirst)</p></div><div class='article-body-commercial-selector'>\(threeParagraphs)</div></article>"
        )
        assertEqual(
            guardianLike.content, "\(standfirst)\n\n\(prose)\n\n\(second)\n\n\(third)",
            "An explicit body keeps the article's standfirst but not other lead-in text (the Guardian)")
        assertEqual(
            pipeline.extractFromHTML(
                "<article><header><h1>Review shapes plans</h1><p class='standfirst'>\(standfirst)</p></header><div class='entry-content'>\(threeParagraphs)</div></article>"
            ).content, "\(standfirst)\n\n\(prose)\n\n\(second)\n\n\(third)",
            "A standfirst in the article's own header survives the explicit-body repair")
        assertEqual(
            pipeline.extractFromHTML(
                "<article><h3>Email Story</h3><p>Join our Whatsapp Channel</p>\(threeParagraphs)</article>"
            )
            .content, "\(prose)\n\n\(second)\n\n\(third)",
            "Sharing and channel prompts are not story text (Dawn)")
        if case .success(_, _, let document) = guardianLike {
            assertEqual(
                document?.blocks.first?.imageURL, "https://news.example/lead.jpg",
                "An explicit body keeps the article's lead figure")
        } else {
            assertTrue(false, "The Guardian-like page extracts")
        }
        assertTrue(
            pipeline.extractFromHTML("<article><div>\(prose)</div><div>\(second)</div></article>").isSuccess,
            "Div-only articles remain readable")
        // #242: the region stops at the article body, and repeated page furniture no longer rejects the page.
        let body = (1...6).map { "<p>Paragraph \($0): \(prose)</p>" }.joined()
        let teasers = (1...12).map {
            "<div class=\"card\"><a href=\"/story/\($0)\"><h3>Other headline number \($0) about a different event entirely</h3></a></div>"
        }.joined()
        let wrapped = pipeline.extractFromHTML(
            "<div class=\"site\"><article><div class=\"article__text\">\(body)</div><h2>Most Popular</h2>\(teasers)</article></div>"
        )
        assertEqual(
            wrapped.content?.components(separatedBy: "\n\n").count, 6,
            "A link-heavy wrapper cannot outscore the article body")
        assertFalse(wrapped.content?.contains("Other headline") ?? true, "Teaser links stay out of the reader")
        let cited = (1...6).map {
            "<p>Section two, point \($0): officials cited <a href=\"/a/\($0)\">the published quarterly inflation report from the central bank</a> and <a href=\"/b/\($0)\">the independent employment survey released last week</a> today.</p>"
        }.joined()
        let sectioned = pipeline.extractFromHTML(
            "<article><section>\(body)</section><section>\(cited)</section><section><p>Closing: \(second)</p></section></article>"
        )
        assertEqual(
            sectioned.content?.components(separatedBy: "\n\n").count, 13,
            "Heavily cited prose keeps every section of the article")
        let halfCited = pipeline.extractFromHTML(
            "<article><section>" + (1...5).map { "<p>Paragraph \($0): \(prose)</p>" }.joined() + "</section>"
                + cited.components(separatedBy: "</p>").prefix(5).map { $0 + "</p>" }.joined() + "</article>")
        assertEqual(
            halfCited.content?.components(separatedBy: "\n\n").count, 10,
            "Citations never trigger the link-density penalty")
        let cards =
            "<ul>"
            + (1...10).map {
                "<li><a href=\"/related/\($0)\">Related story number \($0): a long headline about another event in a different country entirely</a> Two hours ago, from our foreign desk.</li>"
            }.joined() + "</ul>"
        let carded = pipeline.extractFromHTML(
            "<div class=\"site\"><article><div class=\"body\">\(body)</div>\(cards)</article></div>")
        assertFalse(
            carded.content?.contains("Related story") ?? true,
            "Teaser cards dominated by one headline link stay navigation")
        let citedList =
            "<ul>" + cited.replacingOccurrences(of: "<p>", with: "<li>").replacingOccurrences(of: "</p>", with: "</li>")
            + "</ul>"
        let listed = pipeline.extractFromHTML(
            "<article><section>\(body)</section><section>\(citedList)</section><section><p>Closing: \(second)</p></section></article>"
        )
        assertEqual(
            listed.content?.components(separatedBy: "\n\n").count, 13, "Cited list items count as prose, not navigation"
        )
        // #246: widgets inside an article must not make its final sections lose to the first section.
        let widget = "<div class=\"related-stories\">" + teasers + "</div>"
        let interrupted = pipeline.extractFromHTML(
            "<article><section>\(body)</section>\(widget)<section><p>Ending one: \(prose)</p><p>Ending two: \(second)</p></section></article>"
        )
        assertEqual(
            interrupted.content?.components(separatedBy: "\n\n").count, 8,
            "An inline related widget keeps both surrounding article sections")
        let splitCards = (1...10).map {
            "<li class=\"story-card\"><a href=\"/category/\($0)\">World news and politics</a> <a href=\"/other/\($0)\">Other headline number \($0) about another country</a> <a href=\"/publisher/\($0)\">The international reporting desk</a> Published this morning with the latest updates and background.</li>"
        }.joined()
        let splitCarded = pipeline.extractFromHTML(
            "<article><section>\(body)</section><ul>\(splitCards)</ul></article>")
        assertEqual(
            splitCarded.content?.components(separatedBy: "\n\n").count, 6,
            "Split-link teaser cards cannot masquerade as cited prose")
        assertFalse(
            splitCarded.content?.contains("Other headline") ?? true, "Card markup excludes multi-anchor teaser text")
        assertEqual(
            HTMLDOMBuilder.parse(html: "<a class=\"card\" href=\"/story\">Linked card headline</a>").combinedText(),
            "Linked card headline", "A link styled as a card is traversed without recursive self-inspection")
        let editorialCard = pipeline.extractFromHTML(
            "<article><div class=\"card\"><p>\(prose) See <a href=\"/report\">the report</a>.</p><p>\(second) See <a href=\"/survey\">the survey</a>.</p></div></article>"
        )
        assertTrue(
            editorialCard.isSuccess, "Presentation cards containing mostly publisher prose retain inline citations")
        let placeholder =
            "<p>To view this video please enable JavaScript, and consider upgrading to a web browser that supports HTML5 video</p>"
        let pullQuote =
            "<p>“\(second) This is the line the editors chose to repeat as a pull quote in the middle of the story.”</p>"
        let furnished = pipeline.extractFromHTML(
            "<article>\(placeholder)\(body)\(placeholder)\(pullQuote)\(placeholder)\(pullQuote)</article>")
        assertFalse(
            furnished.content?.contains("enable JavaScript") ?? true,
            "Repeated short furniture is removed instead of rejecting the page")
        assertEqual(
            furnished.content?.components(separatedBy: "pull quote").count, 2,
            "A repeated prose-length block keeps one occurrence")
        let aside = "<p>(The report was updated on Tuesday.)</p>"
        let asided = pipeline.extractFromHTML("<article>\(body)\(aside)\(aside)</article>")
        assertEqual(
            asided.content?.components(separatedBy: "updated on Tuesday").count, 2,
            "Sentence punctuation before a closing parenthesis is prose")
        let shortQuote = "<p>“We will not back down,” the minister said.</p>"
        let quoted = pipeline.extractFromHTML(
            "<article>\(body)\(shortQuote)<blockquote>\(shortQuote)</blockquote><p>Read more</p><p>Read more</p></article>"
        )
        assertEqual(
            quoted.content?.components(separatedBy: "We will not back down").count, 2,
            "A short repeated sentence keeps one occurrence")
        assertFalse(quoted.content?.contains("Read more") ?? true, "Repeated labels are removed")
        let crowded = pipeline.extractFromHTML(
            "<article>" + String(repeating: placeholder, count: 5)
                + (1...3).map { "<p>Paragraph \($0): \(prose)</p>" }.joined() + "</article>")
        assertEqual(
            crowded.content?.components(separatedBy: "\n\n").count, 3,
            "Labels are removed before the repetition check, even when they outnumber the prose")
        let loop = String(repeating: "<p>\(prose)</p>", count: 4)
        assertFalse(
            pipeline.extractFromHTML("<article>\(loop)<p>\(second)</p></article>").isSuccess,
            "A page that is mostly one repeated paragraph is still a loop")
        let hiddenHTML =
            "<article><p>\(prose)</p><p>\(second)</p><div hidden><p>Hidden subscription announcement that should never appear in a reader.</p></div><div aria-hidden='true'>Another hidden panel with a substantial amount of text.</div><button>Follow this publisher for personalized updates and notifications.</button></article>"
        assertEqual(
            pipeline.extractFromHTML(hiddenHTML).content, "\(prose)\n\n\(second)",
            "Hidden panels and button labels cannot leak into publisher prose")
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
        assertEqual(
            article?.fullContent, "First important paragraph.\n\nSecond paragraph.",
            "Atom XHTML preserves paragraph boundaries")
        assertEqual(
            article?.pubDate, DateParser.parse("2026-09-20T10:00:00Z"),
            "Published and updated dates are not concatenated")
        // #115: Ekonomichna Pravda sends plain text in content:encoded, paragraphs separated by blank lines.
        let plainEncoded = """
            <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Daily</title><item><title>Report</title>
            <link>https://example.com/plain</link><content:encoded><![CDATA[ \(prose)


            Officials said the agreement &amp; its annexes wouldn&#8217;t be published&nbsp;before the parliamentary review next week.


            \(second)]]></content:encoded></item></channel></rss>
            """
        let plainArticle = FeedXMLParser(data: Data(plainEncoded.utf8)).parse().first
        assertEqual(
            plainArticle.map { ArticleContentRedactor.redactAndSplit($0.fullContent ?? "") },
            [
                prose,
                "Officials said the agreement & its annexes wouldn\u{2019}t be published before the parliamentary review next week.",
                second,
            ],
            "Plain-text content:encoded keeps its paragraph breaks and decodes entities")
        assertTrue(
            plainArticle?.readerDocument == nil,
            "Plain feed text is no reader document, so the reader fetches the page's structure")
        let rss =
            "<rss><channel><title>News</title><image><title>News logo</title></image><item><title>Story</title><link>https://example.com/story</link></item></channel></rss>"
        assertEqual(
            FeedXMLParser(data: Data(rss.utf8)).parse().first?.source, "News",
            "Feed image title cannot contaminate publisher name")
        let broken = FeedXMLParser(data: Data("<rss><channel><item>".utf8))
        assertTrue(broken.parse().isEmpty && broken.parseError != nil, "Malformed feeds report a parsing failure")
        let json = """
            {"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://example.com/1","content_text":"Use x < y and y > z.","summary":"Use x < y and y > z. Keep &amp; literal."},{"id":"2","url":"https://example.com/2","description":"<p>Legacy <b>HTML</b> &amp; text.</p>"}]}
            """
        let textArticle = JSONFeedParser.parse(data: Data(json.utf8), feedURL: "https://example.com/feed")?.first
        assertEqual(
            textArticle?.fullContent, "Use x < y and y > z.", "JSON plain text must never pass through HTML stripping")
        assertEqual(textArticle?.contentFetched, true, "Short explicit feed content is readable")
        assertEqual(
            textArticle?.description, "Use x < y and y > z. Keep &amp; literal.",
            "JSON summaries preserve plain text comparisons and literal entities")
        let legacyArticle = JSONFeedParser.parse(data: Data(json.utf8), feedURL: "https://example.com/feed")?.last
        assertEqual(legacyArticle?.description, "Legacy HTML & text.", "Legacy JSON descriptions retain HTML cleanup")
        let unidentified = """
            {"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://example.com/1","title":"Kept"},{"title":"No id or URL","content_text":"Dropped"}]}
            """
        assertEqual(
            JSONFeedParser.parse(data: Data(unidentified.utf8), feedURL: "https://example.com/feed")?.map(\.title),
            ["Kept"], "An item with neither id nor URL is skipped instead of getting a random identity on every refresh"
        )
    }

    static func testStructuredReaderAndTags() async {
        let first =
            "The central bank published its quarterly report with detailed forecasts for inflation and employment across the economy."
        let second =
            "Independent economists reviewed the figures and described the outlook as stable, with further updates expected next month."
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
        assertEqual(
            document.blocks.filter { $0.kind == .heading }.map(\.text), ["What changes?"],
            "Short publisher headings survive")
        assertEqual(
            document.blocks.filter { $0.kind == .listItem }.map(\.ordinal), [3, 4], "Ordered lists retain numbering")
        assertTrue(
            document.blocks.contains { $0.kind == .quote && $0.text.contains("stable.\nWe") },
            "Quote paragraphs keep their break")
        assertTrue(document.blocks.contains { $0.kind == .code && $0.text.contains("\n") }, "Code retains line breaks")
        for unwanted in [
            "USER COMMENT", "Other report", "Another report", "newsletter", "PODCAST", "Related topics",
            "More on this story", "Get in touch", "views on the triple lock", "17:45 weekdays",
        ] {
            assertFalse(content.contains(unwanted), "Publisher furniture excluded: \(unwanted)")
        }
        assertTrue(
            content.contains("instruction discussed by the researcher"),
            "Editorial references to a programme remain eligible")
        assertTrue(content.contains("Editorial commentary"), "Comment filtering must not remove editorial commentary")

        // #330: BBC's live layout wraps a newsletter banner and its signup prose in ordinary image and text blocks.
        func bbcBlock(_ kind: String, _ inner: String) -> String {
            "<div data-block=\"\(kind)\" class=\"ssrcss-vxwoax-ComponentWrapper\"><div class=\"ssrcss-126h8e-Spacer\">\(inner)</div></div>"
        }
        func bbcFigure(_ alt: String, _ caption: String) -> String {
            bbcBlock(
                "image",
                "<div data-testid=\"image\"><figure class=\"ssrcss-hc6arm-StyledFigure\"><div><span><picture>"
                    + "<img alt=\"\(alt)\" src=\"https://ichef.bbci.co.uk/ace/standard/976/cpsprodpb/\(caption.count)/live/photo.jpg\" width=\"976\" height=\"549\"/>"
                    + "</picture></span></div>\(caption.isEmpty ? "" : "<figcaption>\(caption)</figcaption>")</figure></div>"
            )
        }
        let bbcText = { (inner: String) in
            bbcBlock(
                "text",
                "<div data-testid=\"rich-text\"><div class=\"ssrcss-nqezkk-RichTextContainer\"><p>\(inner)</p></div></div>"
            )
        }
        let newsletterHTML =
            "<main><article>" + bbcText(first)
            + bbcFigure("Officials outside the central bank in London", "The bank's headquarters in the City of London")
            + bbcText(second)
            + bbcText(
                "A separate newsletter sent to investors last week warned that rates could rise again before the summer."
            )
            + bbcFigure(
                "A thin, grey banner promoting the US Politics Unspun newsletter. The banner reads: “The newsletter that cuts through the noise.”",
                "")
            + bbcText(
                "Follow the twists and turns with the US Politics Unspun newsletter. Readers in the UK can <a href=\"/newsletters/zgmn46f\">sign up here</a>. Those outside the UK can <a href=\"/news/articles/c2lkky9zngvo\">sign up here</a>."
            )
            + bbcText(
                "Sign up here to get the latest royal stories every week with our Royal Watch <a href=\"https://www.bbc.co.uk/newsletters/zkp3wsg\">newsletter</a>."
            )
            + "</article></main>"
        guard
            case .success(let newsletterContent, _, let newsletterDocument) = ContentExtractionPipeline.shared
                .extractFromHTML(newsletterHTML),
            let newsletterDocument
        else {
            assertTrue(false, "BBC newsletter fixture must extract successfully")
            return
        }
        let figures = newsletterDocument.blocks.filter { $0.kind == .figure }
        assertEqual(
            figures.map(\.imageAlt), ["Officials outside the central bank in London"],
            "Newsletter banners are removed; editorial figures stay")
        assertEqual(figures.first?.text, "The bank's headquarters in the City of London", "Editorial captions stay")
        for unwanted in ["Politics Unspun", "Royal Watch", "sign up"] {
            assertFalse(newsletterContent.contains(unwanted), "Plain text excludes newsletter signup: \(unwanted)")
            assertFalse(
                newsletterDocument.blocks.contains { $0.text.contains(unwanted) },
                "Structured reader excludes newsletter signup: \(unwanted)")
        }
        assertTrue(
            newsletterContent.contains("separate newsletter sent to investors"),
            "Editorial mentions of newsletters stay")
        let extremeList = HTMLDOMBuilder.parse(html: "<ol start='\(Int.max)'><li>First</li><li>Second</li></ol>")
        assertEqual(extremeList.readingBlocks().count, 2, "Untrusted extreme list numbering must not overflow")
        let tags = EntityResult.readerTags(from: [
            EntityResult(name: "Healey", type: .person), EntityResult(name: "John Healey", type: .person),
            EntityResult(name: " JOHN  HEALEY ", type: .person),
            EntityResult(name: "Stanford University", type: .organization),
            EntityResult(name: "AI on Employment Among Recent College Graduates", type: .unknown),
        ])
        assertEqual(
            tags.map(\.name), ["John Healey", "Stanford University"],
            "Tags resolve aliases and reject document-title fragments")
        let ambiguous = EntityResult.readerTags(from: [
            EntityResult(name: "Smith", type: .person), EntityResult(name: "John Smith", type: .person),
            EntityResult(name: "Jane Smith", type: .person),
        ])
        assertEqual(ambiguous.count, 3, "An ambiguous surname must not be merged into a guessed identity")
        // #924: a name the story mentions once in passing makes no tag; the people it is about lead.
        let coldFusion = EntityResult.readerTags(
            from: [
                EntityResult(name: "Huw Price", type: .person, confidence: 0.9),
                EntityResult(name: "Trinity College", type: .organization, confidence: 0.9),
                EntityResult(name: "Strait of Hormuz", type: .place, confidence: 0.9),
                EntityResult(name: "Matt Trevithick", type: .person, confidence: 0.9),
            ],
            title: "Is There Anything Left in the Dream of Cold Fusion?",
            description: "A thriving research program with exotic atoms stretches the boundaries of physics.",
            text: "Huw Price, a philosopher at Trinity College, argued scientists were too dismissive. Price wrote "
                + "a paper; the price of energy rose while ships queued in the Strait of Hormuz. Matt Trevithick "
                + "organised a review. Trevithick said the work continued, and Trevithick funded 28 papers; "
                + "Trevithick's team kept going. "
                + "Price disagreed.")
        assertEqual(
            coldFusion.map(\.name), ["Matt Trevithick", "Huw Price"],
            "Tags rank by mentions and drop names mentioned once in passing")
        assertEqual(EntityResult.mentions(of: "Price", in: "the price rose; Price, Priceless"), 1, "Whole words only")
        // #925: a reader document without a usable image still shows the page-lookup image the card shows.
        var lookedUp = FeedArticle(
            storedID: "quanta-cold-fusion", title: "Is There Anything Left in the Dream of Cold Fusion?",
            link: "https://example.com/cold-fusion", guid: "quanta-cold-fusion", description: "Exotic atoms.",
            pubDate: Date(), source: "Quanta Magazine")
        lookedUp.imageUrl = "https://example.com/cold-fusion-og.jpg"
        let paragraph = ReaderBlock(kind: .paragraph, text: "Cold fusion: now there's an idea.")
        lookedUp.readerDocument = ReaderDocument(blocks: [paragraph, paragraph], images: [])
        assertEqual(
            ArticleDetailView.leadImage(for: lookedUp, blocks: [paragraph, paragraph]), lookedUp.imageUrl,
            "The reader leads with the image the card shows")
        let bodyFigure = ReaderBlock(kind: .figure, text: "", imageURL: "https://example.com/cold-fusion-og.jpg")
        assertEqual(
            ArticleDetailView.leadImage(for: lookedUp, blocks: [paragraph, paragraph, bodyFigure]), nil,
            "No lead figure when the body already shows that image")
        assertEqual(
            ArticleDetailView.leadImage(for: lookedUp, blocks: [bodyFigure, paragraph]), nil,
            "No lead figure when a figure opens the body")

        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-reader-\(UUID().uuidString).sqlite3"
        ).path
        defer { removeTemporaryLibrary(atPath: path) }
        let database = DatabaseEngine(path: path)
        do {
            try await database.open()
            var article = FeedArticle(
                title: "Report", link: "https://example.com/structured", guid: "reader-structure",
                description: "Preview", pubDate: Date(), source: "Test", fullContent: content)
            try await database.upsertArticles([article])
            try await database.markRead(articleId: article.id, isRead: true)
            try await database.setSaved(articleId: article.id, isSaved: true)
            await database.close()
            var handle: OpaquePointer?
            assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open migration fixture")
            assertEqual(
                sqlite3_exec(
                    handle,
                    "DROP TABLE article_reconciliation_history; DROP TABLE article_reconciliations; DROP TABLE article_aliases; DROP TABLE article_feeds; ALTER TABLE articles DROP COLUMN reader_document; ALTER TABLE article_enrichment DROP COLUMN key_points; ALTER TABLE article_enrichment DROP COLUMN category; ALTER TABLE article_enrichment DROP COLUMN confidence; ALTER TABLE article_enrichment DROP COLUMN model_identifier; ALTER TABLE article_enrichment DROP COLUMN analysis_version; PRAGMA user_version = 1;",
                    nil, nil, nil), SQLITE_OK, "Prepare v1 fixture")
            sqlite3_close(handle)
            try await database.open()
            let migrated = try await database.fetchArticles()
            assertEqual(migrated.first?.fullContent, content, "Migration preserves old body text")
            assertTrue(try await database.isSaved(articleId: article.id), "Migration preserves saved state")
            assertTrue(try await database.isRead(articleId: article.id), "Migration preserves read state")
            try await database.updateEnrichment(
                articleId: article.id, update: .init(content: content, readerDocument: document))
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

    static func testReaderPassageMatcher() {
        print(
            "  - Testing the citation jump: a quote finds its reader block exactly, by word overlap, or not at all...")
        let blocks = [
            ReaderBlock(kind: .heading, text: "Council approves the harbour plan"),
            ReaderBlock(
                kind: .paragraph,
                text: "The council approved the harbour redevelopment plan on Tuesday after a four-hour debate."),
            ReaderBlock(kind: .figure, text: "The harbour at dusk", imageURL: "https://example.com/harbour.jpg"),
            ReaderBlock(kind: .paragraph, text: "Opponents said the budget leaves nothing for the ferry terminal."),
        ]
        assertEqual(
            ReaderPassageMatcher.index(of: "approved the harbour redevelopment plan on Tuesday", in: blocks), 1,
            "An exact quote finds its paragraph")
        assertEqual(
            ReaderPassageMatcher.index(
                of: "“Opponents said the budget leaves nothing for the ferry terminal.”", in: blocks),
            3, "Quotation marks and punctuation do not matter")
        assertEqual(
            ReaderPassageMatcher.index(
                of: "the budget leaves nothing at all for the ferry terminal, opponents said", in: blocks),
            3, "A lightly reworded quote finds the block sharing most of its words")
        assertEqual(
            ReaderPassageMatcher.index(of: "The harbour at dusk", in: blocks), nil,
            "A figure caption is never a cited passage")
        assertEqual(
            ReaderPassageMatcher.index(of: "Completely unrelated sentence about elections abroad", in: blocks), nil,
            "An unrelated quote matches nothing")
    }

    static func testReaderExtractionFidelity(fixtureRoot: URL) {
        print("  - Testing reader v10 structure: short paragraphs, line breaks, lists, quotes, tables and embeds...")
        let first =
            "Publisher reporting preserves meaningful structure for readers and supplies enough context to understand this specific event."
        let second =
            "A second paragraph provides independent details and explains the evidence without substituting any generated prose for the publisher's words."
        // Stories are mostly prose; the quality gate rejects pages made mainly of short lines.
        let third =
            "A third paragraph closes the report with the reaction of officials and the steps they announced for next week."
        let base = fixtureRoot.appendingPathComponent("news/story").absoluteString
        func blocks(_ body: String) -> [ReaderBlock] {
            guard
                case .success(_, _, let document) = ContentExtractionPipeline.shared.extractFromHTML(
                    "<article><p>\(first)</p>\(body)<p>\(second)</p><p>\(third)</p></article>", baseUrl: base),
                let document
            else {
                assertTrue(false, "Fixture extracts: \(body.prefix(40))")
                return []
            }
            return document.blocks
        }

        let short = blocks("<p>He was 34.</p><p>Share</p>")
        assertTrue(short.contains { $0.kind == .paragraph && $0.text == "He was 34." }, "A short sentence is kept")
        assertFalse(short.contains { $0.text == "Share" }, "A one-word label is not a paragraph")

        let verse = blocks("<p><strong>Roses</strong> are red,<br>violets are <a href='/blue'>blue</a>.</p>")
            .first { $0.text.hasPrefix("Roses") }
        assertEqual(verse?.text, "Roses are red,\nviolets are blue.", "A line break inside a paragraph is kept")
        assertTrue(verse?.inlineRuns?.contains { $0.strong } == true, "Bold survives a line break")
        assertTrue(verse?.inlineRuns?.contains { $0.link != nil } == true, "Links survive a line break")
        let wrapped = blocks("<p>Source formatting wraps this\n   sentence across two lines of markup.</p>")
        assertTrue(
            wrapped.contains { $0.text == "Source formatting wraps this sentence across two lines of markup." },
            "Newlines in the markup stay spaces")

        let unordered = blocks(
            "<ul><li>First item in the outer list<ul><li>Nested item one</li><li>Nested item two</li></ul></li><li>Second outer item</li></ul>"
        ).filter { $0.kind == .listItem }
        assertEqual(
            unordered.map(\.text),
            ["First item in the outer list", "Nested item one", "Nested item two", "Second outer item"],
            "Nested list items follow their parent instead of joining its text")
        assertEqual(unordered.map(\.level), [nil, 1, 1, nil], "Nested items are one level deeper")
        let ordered = blocks("<ol><li>Step one of the method<ol><li>Sub step</li></ol></li><li>Step two</li></ol>")
            .filter { $0.kind == .listItem }
        assertEqual(ordered.map(\.ordinal), [1, 1, 2], "Each ordered list keeps its own numbering")
        assertEqual(ordered.map(\.level), [nil, 1, nil], "Ordered sub-steps are nested")

        let quoted = blocks(
            "<blockquote><p>First quoted paragraph from the source.</p><p>Second quoted paragraph from it.</p></blockquote>"
                + "<aside class='pull-quote'>A line pulled from the story itself for display.</aside>"
                + "<aside class='standfirst'>The page's own standfirst under the headline.</aside>"
                + "<blockquote class='twitter-tweet'><p>A post embedded in the story for this check.</p><a href='https://twitter.com/user/status/1'>Link</a></blockquote>"
        )
        assertEqual(
            quoted.first { $0.kind == .quote }?.text,
            "First quoted paragraph from the source.\nSecond quoted paragraph from it.",
            "A multi-paragraph quote keeps its paragraph breaks")
        assertTrue(quoted.contains { $0.kind == .pullQuote }, "A pull-quote aside is a pull quote")
        assertTrue(quoted.contains { $0.kind == .standfirst }, "A standfirst aside is a standfirst, not a quote")
        let post = quoted.first { $0.kind == .embed }
        assertEqual(post?.text, "twitter.com", "An embedded post names its host")
        assertEqual(post?.imageURL, "https://twitter.com/user/status/1", "An embedded post keeps its address")
        let players = blocks(
            "<figure><iframe src=\"https://www.youtube.com/embed/abc123\" width=\"560\" height=\"315\"></iframe></figure>"
                + "<video controls><source src=\"https://cdn.example.org/clip.mp4\" type=\"video/mp4\"></video>")
        let embeds = players.filter { $0.kind == .embed }
        assertEqual(
            embeds.map(\.text), ["youtube.com", "cdn.example.org"],
            "An embedded player or video is a placeholder naming its host instead of vanishing")
        assertEqual(
            embeds.first?.imageURL, "https://www.youtube.com/embed/abc123", "The placeholder keeps the player address")

        let table = blocks(
            "<table><tr><th>Team</th><th>Wins</th></tr><tr><td>Team A</td><td>3</td></tr><tr><td>Team B</td><td>2</td></tr></table>"
        ).first { $0.kind == .table }
        assertEqual(table?.text, "Team\tWins\nTeam A\t3\nTeam B\t2", "A data table keeps its rows and cells")
        assertEqual(table?.ordinal, 1, "A th first row is the header")
        let layout = blocks("<table><tr><td><p>\(first) Laid out inside a table cell.</p></td></tr></table>")
        assertFalse(layout.contains { $0.kind == .table }, "A layout table is read as ordinary content")
        assertTrue(layout.contains { $0.text.hasSuffix("Laid out inside a table cell.") }, "Layout table prose is kept")

        let script =
            blocks("<p>Water is H<sub>2</sub>O and the plot covers 5 km<sup>2</sup> in total area.</p>")
            .first { $0.text.hasPrefix("Water") }?.inlineRuns ?? []
        assertTrue(script.contains { $0.text == "2" && $0.baselineShift == -1 }, "Subscript is marked")
        assertTrue(script.contains { $0.text == "2" && $0.baselineShift == 1 }, "Superscript is marked")

        let stamped = blocks("<p>(Updated: 21 Oct 2026 05:12PM)</p><p>Updated rules take effect in March.</p>")
        assertFalse(stamped.contains { $0.text.hasPrefix("(Updated") }, "A plain update stamp is not story text")
        assertTrue(
            stamped.contains { $0.text == "Updated rules take effect in March." }, "A sentence about updates stays")

        let stored =
            #"{"version":9,"blocks":[{"kind":"paragraph","text":"Old text"},{"kind":"hologram","text":"Later"}]}"#
        let decoded = try? JSONDecoder().decode(ReaderDocument.self, from: Data(stored.utf8))
        assertEqual(decoded?.blocks.map(\.kind), [.paragraph, .paragraph], "Stored and unknown kinds still decode")
        assertEqual(decoded?.blocks.first?.level, nil, "Documents without new fields decode")
    }

    static func testReaderFigures(fixtureRoot: URL) async throws {
        print("  - Testing inline reader figures, captions and bounded image decoding...")
        let prose =
            "The researchers published their findings after reviewing the available evidence and comparing the results across several independent observations."
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
        guard
            case .success(let content, let lead, let document) = pipeline.extractFromHTML(
                html, baseUrl: fixtureRoot.absoluteString),
            let document
        else {
            assertTrue(false, "Structured publisher fixture must extract")
            return
        }
        assertEqual(
            document.blocks.map(\.kind), [.paragraph, .figure, .heading, .paragraph],
            "Keep editorial order and remove hidden, duplicate and invalid images")
        let figure = document.blocks[1]
        assertEqual(
            figure.imageURL, fixtureRoot.appendingPathComponent("media/report.png").absoluteString,
            "Relative figure URL resolves against publisher page")
        assertEqual(lead, figure.imageURL, "An editorial figure supplies the lead when metadata is absent")
        assertEqual(
            figure.text, "Sample photograph. Credit: Research team.", "Caption and attribution survive extraction")
        assertEqual(
            figure.imageAlt, "Researchers examining the sample", "Publisher alt text survives for accessibility")
        assertFalse(content.contains("Credit:"), "Image captions do not enter the article prose used for analysis")
        assertEqual(
            try JSONDecoder().decode(ReaderDocument.self, from: JSONEncoder().encode(document)), document,
            "Reader figures round-trip through persisted JSON")
        let oldJSON = Data(#"{"version":2,"blocks":[{"kind":"paragraph","text":"Old text"}]}"#.utf8)
        assertEqual(
            try JSONDecoder().decode(ReaderDocument.self, from: oldJSON).blocks[0].text, "Old text",
            "Existing reader documents remain readable")
        assertTrue(
            ContentExtractionPipeline.readerImageURL("data:image/png;base64,AAAA", baseURL: nil) == nil,
            "Embedded resources are not remote reader images")
        assertTrue(
            ContentExtractionPipeline.readerImageURL("https://user:secret@example.com/image.png", baseURL: nil) == nil,
            "Credential-bearing image URLs are rejected")
        assertEqual(
            ContentExtractionPipeline.readerImageURL(
                "https://cdn.example.com/signed.jpg?token=a&amp;b", baseURL: nil),
            "https://cdn.example.com/signed.jpg?token=a&amp;b",
            "An attribute the HTML parser already decoded is not decoded a second time (#1082)")
        let entityImagesHTML = """
            <html><head><title>Entity Image Attributes</title>
            <meta property="og:image" content="https://www.nasa.gov/wp-content/uploads/2026/11/goosenecks.jpg?w=1672&#038;h=940&amp;crop=1">
            </head><body><article>
            <figure><img width="1672" height="940" src="https://www.nasa.gov/wp-content/uploads/2026/11/goosenecks.jpg?w=1672&#038;h=940" srcset="https://www.nasa.gov/wp-content/uploads/2026/11/goosenecks.jpg?w=1672&#038;h=940&amp;dpr=2 1672w"></figure>
            <p>\(prose)</p><p>Second paragraph. \(prose)</p><p>Third paragraph. \(prose)</p>
            </article></body></html>
            """
        if case .success(_, let entityLead, let entityDoc) = pipeline.extractFromHTML(
            entityImagesHTML, baseUrl: "https://science.nasa.gov/earth/earth-observatory/goosenecks/")
        {
            assertEqual(
                entityLead,
                "https://www.nasa.gov/wp-content/uploads/2026/11/goosenecks.jpg?w=1672&h=940&dpr=2",
                "Body figure srcset decodes &#038; and &amp; before URL parsing (#1082)")
            assertEqual(
                entityDoc?.images?.map(\.url),
                [
                    "https://www.nasa.gov/wp-content/uploads/2026/11/goosenecks.jpg?w=1672&h=940&dpr=2",
                    "https://www.nasa.gov/wp-content/uploads/2026/11/goosenecks.jpg?w=1672&h=940&crop=1",
                ],
                "Both body image and og:image decode &#038; and &amp; without %23038; mangling (#1082)")
        } else {
            assertTrue(false, "Entity image fixture must extract")
        }
        let manyFigures = (0..<20).map { "<figure><img src='/media/\($0).png'></figure>" }.joined()
        guard
            case .success(_, _, let bounded) = pipeline.extractFromHTML(
                "<article><p>\(prose)</p>\(manyFigures)<p>Second paragraph. \(prose)</p></article>",
                baseUrl: fixtureRoot.absoluteString)
        else {
            assertTrue(false, "Bounded media fixture must retain prose")
            return
        }
        assertEqual(bounded?.blocks.filter { $0.kind == .figure }.count, 8, "Reader document bounds remote image work")
        let divHTML =
            "<article><div>\(prose)</div><figure><img src='/media/div.png'></figure><div>Another observation. \(prose)</div></article>"
        guard
            case .success(let divText, _, let divDocument) = pipeline.extractFromHTML(
                divHTML, baseUrl: fixtureRoot.absoluteString)
        else {
            assertTrue(false, "Adding figures must not suppress the div-only prose fallback")
            return
        }
        assertTrue(divText.contains("Another observation"), "Div-only prose survives around figures")
        assertEqual(
            divDocument?.blocks.map(\.kind), [.paragraph, .figure, .paragraph],
            "Div-only articles preserve image position")
        let context = CGContext(
            data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
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
        } catch {
            // Expected invalid-image failure.
        }
    }

    @MainActor
    static func testPublisherContentProvenance() async throws {
        print("  - Testing publisher-input provenance, invalidation and stale-result rejection (#164)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let article = FeedArticle(
            storedID: "provenance-story", title: "Harbor bridge opens", link: "https://example.com/provenance-story",
            guid: "provenance-story", description: "The bridge opens on Tuesday.", pubDate: Date(),
            source: "Harbor News", category: "World")
        let companion = FeedArticle(
            storedID: "provenance-companion", title: "Harbor bridge traffic begins",
            link: "https://example.com/provenance-companion",
            guid: "provenance-companion", description: "Traffic begins on Tuesday.", pubDate: article.pubDate,
            source: "City News")
        _ = try await db.upsertArticles([article, companion])
        try await db.markRead(articleId: article.id, isRead: true)
        try await db.setSaved(articleId: article.id, isSaved: true)
        let analysis = ArticleAnalysis(
            summary: "Bridge opens.", keyPoints: ["Traffic begins"], entities: [], category: "World", sentiment: nil,
            modelIdentifier: "test", analysisVersion: 2)
        assertTrue(
            try await db.saveArticleAnalysis(analysis, for: article.id, expectedInputHash: article.publisherInputHash),
            "Analysis saves only against its captured publisher input")
        _ = try await db.upsertArticles([article])
        assertTrue(await db.fetchArticleAnalysis(for: article.id) != nil, "An unchanged refresh keeps analysis")
        assertEqual(
            try await db.publisherContentRevisions(for: article.id).count, 1, "An unchanged refresh creates no revision"
        )
        var staleSnapshot = article
        staleSnapshot.aiSummary = "Unversioned imported analysis"
        _ = try await db.upsertArticles([staleSnapshot])
        assertEqual(
            await db.fetchArticleAnalysis(for: article.id)?.summary, analysis.summary,
            "An unversioned snapshot cannot overwrite valid analysis")
        let body = "The city opened the Harbor bridge on Tuesday after its final structural inspections."
        assertTrue(
            try await db.updateEnrichment(articleId: article.id, update: .init(content: body)),
            "Initial extraction persists")
        let extracted = try await db.fetchArticles(id: article.id).first!
        let extraction = try await db.publisherContentRevisions(for: article.id).first!
        assertEqual(extraction.kind, .extraction, "First body extraction is not a publisher update")
        assertEqual(extraction.inputHash, extracted.publisherInputHash, "SQLite and Swift hash the same input fields")
        assertEqual(
            await db.fetchArticleAnalysis(for: article.id), nil, "A newly extracted input invalidates old analysis")
        assertTrue(
            try await db.saveArticleAnalysis(
                analysis, for: article.id, expectedInputHash: extracted.publisherInputHash), "Fresh body analysis saves"
        )
        let event = try await db.createEvent(memberArticleIDs: [article.id, companion.id])
        let overview = EventOverviewDocument(
            eventID: event.id,
            version: OverviewVersionContext(membershipVersion: event.membershipVersion, inputTextHash: "test-input"),
            content: OverviewContent(
                title: "Harbor bridge", summary: "A sourced test overview.", facts: [], citations: []),
            provenance: OverviewProvenance(memberArticleIDs: [article.id, companion.id]))
        assertTrue(try await db.recordEventOverview(overview), "Overview stored before publisher change")
        let revisedBody = body + " The eastbound lane remains closed for further work."
        assertTrue(
            try await db.updateEnrichment(articleId: article.id, update: .init(content: revisedBody)),
            "A body update persists")
        let changed = try await db.fetchArticles(id: article.id).first!
        let update = try await db.publisherContentRevisions(for: article.id).first!
        assertEqual(update.kind, .publisherUpdate, "A changed existing body is a locally observed publisher update")
        assertEqual(update.changeDescription, "Article body", "Provenance identifies the changed field")
        assertEqual(await db.fetchArticleAnalysis(for: article.id), nil, "A body update invalidates generated analysis")
        assertEqual(
            try await db.fetchEventOverview(eventID: event.id), nil,
            "Affected event overviews are invalidated atomically")
        assertFalse(
            try await db.saveArticleAnalysis(
                analysis, for: article.id, expectedInputHash: extracted.publisherInputHash),
            "An in-flight result cannot save against changed input")
        assertFalse(
            try await db.updateEnrichment(
                articleId: article.id,
                update: .init(category: "Science", expectedInputHash: extracted.publisherInputHash)),
            "Stale classification cannot overwrite the new article")
        assertFalse(
            try await db.recordEventOverview(
                overview, expectedArticleInputs: [article.id: extracted.publisherInputHash]),
            "A stale overview cannot resurrect an invalidated document")
        assertTrue(
            try await db.saveArticleAnalysis(analysis, for: article.id, expectedInputHash: changed.publisherInputHash),
            "Current input is analyzable again")
        assertTrue(try await db.isRead(articleId: article.id), "Revisions preserve read state")
        assertTrue(try await db.isSaved(articleId: article.id), "Revisions preserve saved state")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        assertTrue(
            await store.setSaved(article: extracted, isSaved: true), "Saving an older reader snapshot still works")
        assertEqual(
            try await db.fetchArticles(id: article.id).first?.fullContent, revisedBody,
            "Saving cannot revert publisher content")
        assertEqual(
            try await db.publisherContentRevisions(for: article.id).first?.version, update.version,
            "Saving creates no false update")
        for index in 0..<25 {
            _ = try await db.updateEnrichment(
                articleId: article.id, update: .init(content: revisedBody + " Observation \(index)."))
        }
        let history = try await db.publisherContentRevisions(for: article.id)
        assertEqual(history.count, 20, "Observation metadata is bounded")
        assertEqual(history.first?.version, update.version + 25, "Version numbers remain monotonic after pruning")
        _ = try await db.updateEnrichment(articleId: companion.id, update: .init(content: body))
        let feedUpdate = FeedArticle(
            storedID: companion.id, title: "Harbor bridge traffic begins tomorrow", link: companion.link,
            guid: companion.guid, description: "Traffic starts on Wednesday.", pubDate: companion.pubDate,
            source: companion.source)
        _ = try await db.upsertArticles([feedUpdate])
        let feedRevision = try await db.publisherContentRevisions(for: companion.id).first!
        assertEqual(feedRevision.kind, .publisherUpdate, "Changed feed text is an observed publisher update")
        assertEqual(feedRevision.changedFields, 3, "Title and summary changes are distinguished from body changes")
        let beforePurge = try await db.publisherContentRevisions(for: companion.id)
        try await db.clearArticleCache()
        assertEqual(
            try await db.publisherContentRevisions(for: companion.id).map(\.fingerprint),
            beforePurge.map(\.fingerprint),
            "A local cache purge is not a publisher update")
        assertTrue(
            try await db.fetchArticles(id: article.id).first?.fullContent != nil,
            "Saved publisher bodies survive cache purging")
        // Unit tests never reach the live on-device model.
        let coordinator = OverviewGenerationCoordinator(
            store: store, queue: EnrichmentQueue(store: store))
        let cachedOverview = await coordinator.requestOverview(
            eventID: event.id, eventTitle: "Harbor bridge",
            membershipVersion: event.membershipVersion,
            articles: try await db.fetchArticles(limit: nil, eventID: event.id))
        assertTrue(cachedOverview != nil, "An overview can be generated from current stored inputs")
        _ = try await db.updateEnrichment(
            articleId: article.id, update: .init(content: revisedBody + " The city announced an additional inspection.")
        )
        let frozen = await coordinator.requestOverview(
            eventID: event.id, eventTitle: "Harbor bridge",
            membershipVersion: event.membershipVersion, articles: [article, companion])
        assertEqual(
            frozen, nil,
            "An overview built from frozen pre-update snapshots is rejected, not served from the old memory cache")
        assertEqual(try await db.fetchEventOverview(eventID: event.id), nil, "A rejected overview is not stored")
        let current = try await db.fetchArticles(limit: nil, eventID: event.id)
        let regenerated = await coordinator.requestOverview(
            eventID: event.id, eventTitle: "Harbor bridge",
            membershipVersion: event.membershipVersion, articles: current)
        assertTrue(
            regenerated != nil && regenerated?.id != cachedOverview?.id,
            "Current stored inputs regenerate the overview with unchanged membership")

        // Upgrade a copied v15 fixture; the original and all durable publisher/user state survive.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("news-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("v15.sqlite")
        let legacy = DatabaseEngine(path: original.path)
        try await legacy.open()
        _ = try await legacy.upsertArticles([changed])
        try await legacy.markRead(articleId: changed.id, isRead: true)
        try await legacy.setSaved(articleId: changed.id, isSaved: true)
        _ = try await legacy.saveArticleAnalysis(analysis, for: changed.id)
        await legacy.close()
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(original.path, &handle), SQLITE_OK, "Open only the owned migration fixture")
        assertEqual(
            sqlite3_exec(
                handle,
                "DROP TRIGGER trg_publisher_content_insert; DROP TRIGGER trg_publisher_content_update; DROP TABLE publisher_content_revisions; ALTER TABLE article_enrichment DROP COLUMN input_content_version; ALTER TABLE article_enrichment DROP COLUMN input_text_hash; PRAGMA user_version=15;",
                nil, nil, nil), SQLITE_OK, "Reconstruct v15 provenance-free fixture")
        sqlite3_close(handle)
        let copy = root.appendingPathComponent("upgraded.sqlite")
        try FileManager.default.copyItem(at: original, to: copy)
        let migrated = DatabaseEngine(path: copy.path)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await migrated.open()
        }
        do {
            try await cancelled.value
            assertTrue(false, "Cancelled provenance migration must throw")
        } catch is CancellationError {
            // Expected: the cancelled migration rolls back and the next open retries it.
        }
        try await migrated.open()
        assertEqual(
            try await migrated.publisherContentRevisions(for: changed.id).first?.kind, .snapshot,
            "Migration records a baseline, not a fabricated update")
        assertEqual(
            await migrated.fetchArticleAnalysis(for: changed.id), nil, "Unversioned legacy analysis must regenerate")
        assertEqual(
            try await migrated.fetchArticles(id: changed.id).first?.fullContent, revisedBody,
            "Migration preserves the saved publisher body")
        assertTrue(try await migrated.isRead(articleId: changed.id), "Migration preserves read state")
        assertTrue(try await migrated.isSaved(articleId: changed.id), "Migration preserves saved state")
        await migrated.close()
        func value(_ file: URL, _ sql: String) -> String? {
            var connection: OpaquePointer?
            var statement: OpaquePointer?
            assertEqual(sqlite3_open(file.path, &connection), SQLITE_OK, "Inspect only the owned provenance fixture")
            defer { sqlite3_close(connection) }
            assertEqual(
                sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK, "Prepare provenance inspection")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        assertEqual(
            value(copy, "PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Provenance schema upgrades to the current schema")
        assertEqual(value(original, "PRAGMA user_version;"), "15", "Original v15 fixture remains untouched")
        assertEqual(value(copy, "PRAGMA quick_check;"), "ok", "Upgraded provenance library passes quick_check")
        assertEqual(value(copy, "PRAGMA foreign_key_check;"), nil, "Provenance has no dangling article references")
    }

    static func testContentExtractionPipelineDeep() async {
        print("  - Testing Content Extraction Pipeline (Entities, Link Density, Lead Image)...")

        let pipeline = ContentExtractionPipeline.shared

        // 1. Entity decoding
        let encoded =
            "&quot;Innovation &amp; Discovery&quot; &mdash; It&#39;s an &#8220;extraordinary&#8221; achievement"
        let decoded = pipeline.decodeHTMLEntities(encoded)
        assertEqual(
            decoded, "\"Innovation & Discovery\" — It's an “extraordinary” achievement",
            "Should decode named, decimal, and hex entities")

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

    static func testExtractionURLRejection() async {
        print("  - Testing extraction URL rejection...")

        // 1. Invalid URL string
        let invalidResult = await ContentExtractionPipeline.shared.extractArticle(from: "not a url")
        assertTrue(invalidResult.0 == nil && invalidResult.1 == nil, "Should return nil for invalid URL string")

        // 2. Blocked scheme (will hit SecureHTTPClient rejection or pipeline bail out)
        let blockedResult = await ContentExtractionPipeline.shared.extractArticle(from: "file:///etc/passwd")
        assertTrue(
            blockedResult.0 == nil && blockedResult.1 == nil, "Should return nil for blocked schemes like file://")
    }

    /// Placing selections, finding a note again after re-extraction, and painting its range (#711).
    static func testNoteAnchoring() {
        print("  - Testing highlight anchoring across re-extraction and selections (#711)...")
        let story = [
            "Officials said the bridge opens on Tuesday.",
            "",
            "Crews finished the deck. Officials said the bridge opens on Tuesday after inspections.",
        ]
        // Selections: one passage, several lines, and text that is not in the story.
        let one = NoteAnchor.place(selection: "the bridge opens", in: story)
        assertEqual(one?.map(\.index), [0], "A quote that occurs twice is placed at its first occurrence")
        assertEqual(one?.map(\.start), [15], "With its character offset")
        let lines = NoteAnchor.place(selection: "Crews finished the deck.\n\nOfficials said the bridge", in: story)
        assertEqual(lines?.map(\.index), [2, 2], "Lines of one selection stay in order")
        assertEqual(lines?.map(\.start), [0, 25], "Each line gets its own offset")
        // The same quote again goes to its next occurrence, and when all are taken the first is returned (a duplicate).
        let again = NoteAnchor.place(selection: "the bridge opens", in: story, taken: [(0, 15..<31)])
        assertEqual(again?.map(\.index), [2], "A highlighted occurrence is skipped")
        assertEqual(again?.map(\.start), [40], "For the next one")
        let all = NoteAnchor.place(selection: "the bridge opens", in: story, taken: [(0, 15..<31), (2, 40..<56)])
        assertEqual(all?.map(\.index), [0], "With every occurrence taken the first is returned")
        assertTrue(NoteAnchor.place(selection: "not in the story", in: story) == nil, "Unknown text has no place")
        assertTrue(NoteAnchor.place(selection: "  \n ", in: story) == nil, "A blank selection has no place")

        // A note made in the third block, where the quote also occurs in the first block.
        let note = NoteAnchor.note(
            articleID: "a", paragraphs: story, index: 2, start: 25, quote: "Officials said the bridge opens")
        assertEqual(note.prefix, "Crews finished the deck. ", "The note keeps the words before the quote")
        assertEqual(note.suffix, " on Tuesday after inspections.", "And after it")
        assertEqual(
            NoteAnchor.resolve(note, in: story)?.index, 2, "The stored position is used while the text still matches")
        assertEqual(NoteAnchor.resolve(note, in: story)?.range, 25..<56, "With the stored character range")

        // A re-extraction adds a block above and rewrites the first one: the offsets are stale, the context decides.
        let extracted = ["Updated: the story was edited.", "Officials said the bridge opens in May."] + story
        let moved = NoteAnchor.resolve(note, in: extracted)
        assertEqual(moved?.index, 4, "The quote follows its context to the moved block, not the first look-alike")
        assertEqual(moved?.range, 25..<56, "With its range")
        let shifted = [
            "Breaking: Crews finished the deck. Officials said the bridge opens on Tuesday after inspections."
        ]
        assertEqual(
            NoteAnchor.resolve(note, in: shifted)?.range, 25 + 10..<56 + 10, "Offsets inside a block are found again")

        // A look-alike that moved into the stored position does not keep the note: the context decides.
        let before = ["Officials: the bridge opens in May.", "Crews said the bridge opens soon."]
        let second = NoteAnchor.note(
            articleID: "a", paragraphs: before, index: 1, start: 11, quote: "the bridge opens")
        assertEqual(NoteAnchor.resolve(second, in: before)?.index, 1, "Unchanged text keeps the stored place")
        let swapped = [before[1], before[0]]
        assertEqual(
            NoteAnchor.resolve(second, in: swapped)?.index, 0,
            "The quote follows its context when another occurrence takes its place")

        // Without any context left the nearest block wins, and a quote that is gone is lost.
        let bare = UserNote(
            articleID: "a", paragraphIndex: 3, charStart: 0, selectedText: "bridge opens", prefix: "", suffix: "")
        assertEqual(NoteAnchor.resolve(bare, in: story)?.index, 2, "A tie goes to the nearest block")
        assertTrue(NoteAnchor.resolve(note, in: ["The bridge is open."]) == nil, "A quote that was rewritten is lost")
        assertTrue(NoteAnchor.resolve(note, in: []) == nil, "An empty story holds no quote")

        // Offsets count characters, so emoji and combining marks do not shift the range.
        let emoji = ["🇳🇱 Café opens 🎉 at nine."]
        let greeting = NoteAnchor.note(
            articleID: "a", paragraphs: emoji, index: 0, start: 15, quote: "at nine")
        assertEqual(NoteAnchor.resolve(greeting, in: emoji)?.range, 15..<22, "Characters, not UTF-16 units")

        // The overlay paints exactly the resolved ranges.
        let overlay = ReaderOverlay(notes: [note, bare], paragraphs: story)
        assertEqual(overlay.highlights[2]?.count, 2, "Both notes are painted in the third block")
        var text = AttributedString(story[2])
        text.paint(25..<56, AppColor.noteHighlight)
        text.paint(900..<901, AppColor.noteHighlight)
        let painted = text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        assertEqual(
            painted, ["Officials said the bridge opens"], "Only the quote has a background; a stale range is ignored")
    }

    /// The sentence diff on a three-revision breaking story, its block overlay, the pair budget and which updates a story can be compared with (#712).
    static func testSentenceDiffAndStoryEvolution() {
        print("  - Testing the sentence diff on a multi-revision breaking story (#712)...")
        let first =
            "Two people were hurt when a bus hit a bridge rail on Monday. Police closed the road. "
            + "The driver was taken to hospital."
        let second =
            "Two people were hurt when a bus hit a bridge rail on Monday.  Police closed the road. "
            + "The driver, 54, was taken to hospital. A tow truck is on the way."
        let third =
            "Three people were hurt when a bus hit a bridge rail on Monday. Police closed the road. "
            + "The driver, 54, was taken to hospital. The road reopened at 9 pm."

        /// The diff of two texts as "= kept", "+ added" and "- retracted" lines.
        func kinds(_ before: String, _ after: String) -> [String] {
            SentenceDiff.diff(before: before, after: after).map { item in
                switch item.kind {
                case .unchanged: "= \(item.text)"
                case .added: "+ \(item.text)"
                case .retracted: "- \(item.text)"
                }
            }
        }
        assertEqual(
            kinds(first, second),
            [
                "= Two people were hurt when a bus hit a bridge rail on Monday.", "= Police closed the road.",
                "- The driver was taken to hospital.", "+ The driver, 54, was taken to hospital.",
                "+ A tow truck is on the way.",
            ], "Extra spaces are not a change; a reworded sentence is one retracted and one added")
        assertEqual(
            kinds(second, third),
            [
                "- Two people were hurt when a bus hit a bridge rail on Monday.",
                "+ Three people were hurt when a bus hit a bridge rail on Monday.", "= Police closed the road.",
                "= The driver, 54, was taken to hospital.", "- A tow truck is on the way.",
                "+ The road reopened at 9 pm.",
            ], "The next revision is classified against the one before it")
        assertEqual(
            SentenceDiff.diff(before: first, after: first).filter { $0.kind != .unchanged }.count, 0, "Same text")
        assertEqual(SentenceDiff.diff(before: "", after: second).filter { $0.kind == .added }.count, 4, "All new")
        assertEqual(SentenceDiff.diff(before: second, after: "").filter { $0.kind == .retracted }.count, 4, "All gone")

        // Blocks of the third revision, as the reader shows them: tinted ranges and the retracted lines' places.
        let blocks = [
            "Three people were hurt when a bus hit a bridge rail on Monday. Police closed the road.",
            "",
            "The driver, 54, was taken to hospital. The road reopened at 9 pm.",
        ]
        let overlay = SentenceDiff.overlay(before: second, after: third, blocks: blocks)
        /// The characters of `range` in the block's text.
        func slice(_ block: Int, _ range: Range<Int>) -> String {
            String(Array(blocks[block])[range])
        }
        assertEqual(
            overlay.added[0].map { $0.map { slice(0, $0) } },
            ["Three people were hurt when a bus hit a bridge rail on Monday."], "A reworded sentence is tinted")
        assertEqual(
            overlay.added[2].map { $0.map { slice(2, $0) } }, ["The road reopened at 9 pm."],
            "A new sentence is tinted")
        assertEqual(overlay.added[1], nil, "A block without text is untouched")
        assertEqual(
            overlay.retracted[-1], ["Two people were hurt when a bus hit a bridge rail on Monday."],
            "A sentence retracted before any kept one is listed before the first block")
        assertEqual(
            overlay.retracted[2], ["A tow truck is on the way."], "A retracted sentence follows the sentence before it")
        assertTrue(
            SentenceDiff.overlay(before: third, after: third, blocks: blocks).added.isEmpty, "No change, no tint")
        assertTrue(SentenceDiff.overlay(before: third, after: third, blocks: blocks).isEmpty, "And nothing retracted")

        // Duplicate sentences: only the added copy is tinted, and a retracted sentence follows its own neighbours.
        let echo = "It rained. Police said. The road closed."
        let echoBlocks = ["It rained. Police said. The road closed. Police said."]
        let echoOverlay = SentenceDiff.overlay(before: echo, after: echo + " Police said.", blocks: echoBlocks)
        assertEqual(echoOverlay.added[0], [41..<53], "The repeated sentence is tinted once, where it was added")
        let removedEcho = SentenceDiff.overlay(before: echoBlocks[0], after: echo, blocks: [echo])
        assertEqual(
            removedEcho.retracted[0], ["Police said."], "The sentence removed at the end follows the last block")

        // Past the pair budget only the shared head and tail are kept, and the middle is replaced as a whole: with
        // the budget the two extra sentences would be the only changes.
        let head = (0..<10).map { "Head \($0) stays." }
        let tail = (0..<10).map { "Tail \($0) stays." }
        let shared = (0..<2_100).map { "Shared sentence \($0) holds." }
        let items = SentenceDiff.diff(
            before: (head + shared + tail).joined(separator: " "),
            after: (head + ["Extra sentence."] + shared + ["Closing sentence."] + tail).joined(separator: " "))
        assertEqual(items.filter { $0.kind == .unchanged }.count, 20, "The shared head and tail survive a large diff")
        assertEqual(items.filter { $0.kind == .added }.count, 2_102, "Past the budget the new middle is added whole")
        assertEqual(items.filter { $0.kind == .retracted }.count, 2_100, "And the old middle is retracted whole")

        // Which updates a story can be compared with.
        /// A revision with the given kind and kept text.
        func revision(_ version: Int, _ kind: PublisherContentRevision.Kind, _ previous: String?)
            -> PublisherContentRevision
        {
            PublisherContentRevision(
                version: version, observedAt: Date(), kind: kind, changedFields: 4, inputHash: "h\(version)",
                previousText: previous)
        }
        let body = String(repeating: "x", count: 100)
        assertEqual(
            PublisherContentRevision.comparable(
                [
                    revision(3, .publisherUpdate, "older body"), revision(2, .publisherUpdate, "oldest"),
                    revision(1, .snapshot, nil),
                ], current: body
            ).map(\.version), [3, 2], "Updates that kept their text are listed newest first")
        assertEqual(
            PublisherContentRevision.comparable(
                [revision(2, .publisherUpdate, String(repeating: "t", count: 50)), revision(1, .snapshot, nil)],
                current: String(repeating: "x", count: 2_000)
            ).map(\.version), [], "A teaser that the page's body completed is not an edit")
        assertEqual(
            PublisherContentRevision.comparable(
                [
                    revision(4, .publisherUpdate, "body before"), revision(3, .extraction, nil),
                    revision(2, .publisherUpdate, "summary before"), revision(1, .snapshot, nil),
                ], current: body
            ).map(\.version), [4], "An update before an extraction compares a summary with a body")
        assertEqual(
            PublisherContentRevision.comparable([revision(2, .publisherUpdate, nil)], current: body).count, 0,
            "An update that kept no text has nothing to compare")

        // The text a revision compares: the body, or the summary while there is no body.
        assertEqual(PublisherContentRevision.text(description: "Summary", content: "Body"), "Body", "Body first")
        assertEqual(PublisherContentRevision.text(description: "Summary", content: ""), "Summary", "Then the summary")
        assertEqual(PublisherContentRevision.text(description: "Summary", content: nil), "Summary", "No body")
    }

    static func testArticleContentRedactionAndTypography() async {
        print("  - Testing ArticleContentRedactor and Typography...")

        // 1. Test trailing and fused boilerplate removal (e.g. '...last year.Read full article\nComments')
        let rawJunk =
            "The launcher delivered a batch of CubeSats to low-Earth orbit from a spaceport in northern Norway, and Isar tasted success after its first test flight ended in failure last year.Read full article\nComments"
        let cleaned = ArticleContentRedactor.redactAndSplit(rawJunk)
        assertEqual(cleaned.count, 1, "Should filter boilerplate lines and clean fused text")
        assertEqual(
            cleaned.first,
            "The launcher delivered a batch of CubeSats to low-Earth orbit from a spaceport in northern Norway, and Isar tasted success after its first test flight ended in failure last year.",
            "Should strip .Read full article and drop Comments")

        // 2. Test syndication footers and standalone boilerplate lines
        let syndicationText = """
            Apple has introduced a new capability in Swift.

            The post Apple Announces New Swift Features appeared first on 9to5Mac.

            Comments
            """
        let cleanedSyndication = ArticleContentRedactor.redactAndSplit(syndicationText)
        assertEqual(cleanedSyndication.count, 1, "Should strip syndication notice and comments line")
        assertEqual(
            cleanedSyndication.first, "Apple has introduced a new capability in Swift.",
            "Content should match without syndication")

        // 3. Test preservation of legitimate words in content
        let normalText = "The spokesperson declined to make any further comments on the ongoing investigation."
        let cleanedNormal = ArticleContentRedactor.cleanText(normalText)
        assertEqual(cleanedNormal, normalText, "Should not redact 'comments' inside a legitimate sentence")

        // 4. Test paragraph splitting for long unformatted RSS blocks (> 650 chars)
        let longBlock =
            "SpaceX is dialing back its Falcon 9 launch program, and there is no certainty about when SpaceX's reusable next-generation super-heavy-lift rocket will carry payloads. "
            + "Customers in any sector will usually welcome competition. Theoretically, competition will lead to lower prices and allow the best to rise to the top. "
            + "So it's no surprise satellite operators are cheering the success of a new launch provider. This was especially the case when Germany's Isar Aerospace reached orbit for the first time with its Spectrum rocket. "
            + "The launcher delivered a batch of CubeSats to low-Earth orbit from a spaceport in northern Norway, marking a milestone."
        let splitParagraphs = ArticleContentRedactor.redactAndSplit(longBlock)
        assertTrue(
            splitParagraphs.count >= 2,
            "Monolithic text should be split into multiple paragraphs at sentence boundaries")

    }

    static func testArticleDetailReadingExperienceOverhaul() async {
        print("  - Testing Article Detail Reading Experience Overhaul...")
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

    static func testReaderPhaseC(fixtureRoot: URL) async throws {
        print("  - Testing reader v4 formatting, media curation and feed-only structure...")
        // A paywall-classed paragraph once made reader exclusion ask itself again until the stack overflowed (Bus
        // error in the live catalog run).
        let meteredParagraph =
            "<article><p>Publisher reporting preserves meaningful structure for readers and supplies context today.</p><p class='paywall'>Subscribe to keep reading this story and every other one on the site.</p><p>A second paragraph provides independent details and explains the evidence in the publisher's own words.</p></article>"
        if case .success(let content, _, _) = ContentExtractionPipeline.shared.extractFromHTML(
            meteredParagraph, baseUrl: fixtureRoot.appendingPathComponent("news/metered").absoluteString)
        {
            assertFalse(content.contains("Subscribe to keep reading"), "A paywall-classed paragraph is furniture")
        } else {
            assertTrue(false, "A story with a paywall-classed paragraph extracts")
        }
        let first =
            "Publisher reporting preserves meaningful structure for readers and supplies enough context to understand this specific event."
        let second =
            "A second paragraph provides independent details and explains the evidence without substituting any generated prose for the publisher's words."
        let base = fixtureRoot.appendingPathComponent("news/story").absoluteString
        let shapes = [
            "<article><p>\(first)</p><p>\(second)</p></article>",
            "<main><h2>Background</h2><div><p>\(first)</p></div><p>\(second)</p></main>",
            "<article><div>\(first)<br>\(second)</div></article>",
            "<article>\(first)<p>\(second)</p></article>",
            "<article><p>\(first)<strong> Strong finding</strong> and <em>emphasized context</em>.</p><p>\(second)</p></article>",
            "<article><p>\(first) <a href='../evidence'>Source evidence</a> and <code>metric_value</code>.</p><p>\(second)</p></article>",
            "<article><p>\(first)</p><blockquote><p>\(second)</p></blockquote></article>",
            "<article><p>\(first)</p><ol start=4><li>\(second)</li></ol></article>",
            "<article><p>\(first)<p>\(second)</article>",
            "<article><p style='display:none'>HIDDEN PROSE</p><p>\(first)</p><p>\(second)</p></article>",
            "<article><p>\(first)</p><figure><img data-src='/photo.jpg' width=1200 height=800 alt='Publisher reporting'><figcaption>Actual scene <span class='photo-credit'>Agency / Photographer</span></figcaption></figure><p>\(second)</p></article>",
            "<article><p>\(first)</p><picture><source srcset='/small.jpg 400w, /large.jpg 1200w'><img src='/fallback.jpg' width=1200 height=800></picture><noscript><img src='/backup.jpg'></noscript><p>\(second)</p></article>",
            // The Guardian repeats the figcaption per breakpoint and its credit sits inside the caption text.
            "<article><p>\(first)</p><figure data-credit='Jen Golbeck/SOPA\n  Images/Shutterstock'><picture><img src='/beach.jpg' width=1200 height=800 alt='A young girl runs on a beach'></picture><span><figcaption><span><svg></svg></span><span>A girl runs on Orange Beach.</span> Photograph: Jen Golbeck/SOPA Images/Shutterstock</figcaption></span><span><figcaption><span></span><span>A girl runs on Orange Beach.</span> Photograph: Jen Golbeck/SOPA Images/Shutterstock</figcaption></span></figure><p>\(second)</p></article>",
        ]
        var documents = [ReaderDocument]()
        for (index, html) in shapes.enumerated() {
            guard
                case .success(let content, _, let document) = ContentExtractionPipeline.shared.extractFromHTML(
                    html, baseUrl: base), let document
            else {
                assertTrue(false, "Reader shape \(index) extracts")
                continue
            }
            assertTrue(content.contains(first) && content.contains(second), "Shape \(index) retains publisher text")
            assertFalse(content.contains("HIDDEN PROSE"), "Hidden text never reaches analysis")
            assertEqual(
                document.version, ReaderDocument.currentVersion,
                "Structured publisher data uses the current extraction version")
            assertEqual(
                try JSONDecoder().decode(ReaderDocument.self, from: JSONEncoder().encode(document)), document,
                "Shape \(index) round trips without loss")
            documents.append(document)
        }
        assertTrue(documents[0].images?.isEmpty == true, "Missing image retains a structured text-only document")
        assertEqual(
            documents[2].blocks.filter { $0.kind == .paragraph }.count, 2,
            "Explicit br prose is not flattened into one wall")
        assertTrue(documents[4].blocks[0].inlineRuns?.contains { $0.strong } == true, "Strong text survives")
        assertTrue(documents[4].blocks[0].inlineRuns?.contains { $0.emphasis } == true, "Emphasis survives")
        assertTrue(documents[5].blocks[0].inlineRuns?.contains { $0.code } == true, "Inline code survives")
        assertEqual(
            documents[5].blocks[0].inlineRuns?.first(where: { $0.link != nil })?.link,
            fixtureRoot.appendingPathComponent("evidence").absoluteString,
            "Inline links resolve relative to the protected response")
        let figure = documents[10].blocks.first { $0.kind == .figure }!
        assertEqual(figure.text, "Actual scene", "Credit stays out of caption")
        assertEqual(figure.imageCredit, "Agency / Photographer", "Credit retained separately")
        assertEqual(figure.imageWidth, 1200, "Unquoted dimensions retained")
        let responsiveFigure = documents[12].blocks.first { $0.kind == .figure }!
        assertEqual(
            responsiveFigure.text, "A girl runs on Orange Beach. Photograph: Jen Golbeck/SOPA Images/Shutterstock",
            "Breakpoint copies of one figcaption render once")
        assertEqual(responsiveFigure.imageCredit, nil, "Credit already inside the caption is not repeated")
        assertTrue(
            documents[11].images?.contains { $0.url.hasSuffix("/large.jpg") } == true,
            "Suitable responsive source chosen")
        assertTrue(
            documents[11].images?.contains { $0.url.hasSuffix("/backup.jpg") } == true,
            "Noscript image fallback retained")
        assertFalse(ReaderImageCandidate.usable(url: base + "/logo.png"), "Publisher logos excluded")
        assertFalse(ReaderImageCandidate.usable(url: base + "/advertisement/banner.jpg"), "Ad image paths excluded")
        assertFalse(
            ReaderImageCandidate.usable(url: base + "/pixel.gif", width: 1, height: 1), "Tracking pixel excluded")
        assertFalse(ReaderImageCandidate.usable(url: "javascript:alert(1)"), "Executable media URL excluded")
        assertFalse(
            ReaderImageCandidate.usable(url: base + "/media/import/term-banners/tag-war-desktop.jpg"),
            "Section banners are page furniture")
        assertTrue(
            ReaderImageCandidate.usable(url: base + "/media/bannerman-portrait.jpg"),
            "Only whole path words name a banner")
        let invalid = ContentExtractionPipeline.shared.extractFromHTML(
            "<article><p>\(first) <a href='javascript:alert(1)'>unsafe link</a></p><p>\(second)</p><figure><img src='/logo.png'></figure></article>",
            baseUrl: base)
        guard case .success(_, _, let safe) = invalid else { fatalError("Invalid URL fixture must remain readable") }
        assertFalse(safe?.blocks.contains { $0.kind == .figure } == true, "Logo figure filtered")
        assertFalse(
            safe?.blocks.flatMap { $0.inlineRuns ?? [] }.contains { $0.link?.hasPrefix("javascript:") == true } == true,
            "Unsafe inline link remains plain text")
        let old = Data(#"{"version":3,"blocks":[{"kind":"paragraph","text":"Legacy publisher prose"}]}"#.utf8)
        assertEqual(
            try JSONDecoder().decode(ReaderDocument.self, from: old).blocks.first?.text, "Legacy publisher prose",
            "Old reader documents remain decodable")
        assertFalse(
            ContentExtractionPipeline.shared.extractFromHTML("<article><p>Subscribe to continue</p></article>")
                .isSuccess, "Paywall fragments remain an explicit fallback")
        let media = [
            ReaderImageCandidate(url: base + "/unrelated.jpg", origin: .openGraph, width: 8000, height: 4000),
            ReaderImageCandidate(url: base + "/scene.jpg", origin: .body, alt: "Publisher reporting"),
        ]
        assertEqual(
            ReaderImageCandidate.select(from: media, title: "Publisher reporting")?.origin, .body,
            "Publisher association beats raw size")
        let noImage = ReaderDocument(blocks: [], images: [], leadImageURL: nil)
        assertTrue(
            noImage.selectedImage(fallback: base + "/old.jpg") == nil,
            "A curated text-only document never revives the old feed image")
        let docWithExtractedImages = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(url: base + "/body.jpg", origin: .body, width: 1200, height: 800)
            ],
            leadImageURL: nil
        )
        assertEqual(
            docWithExtractedImages.selectedImage(fallback: base + "/old.jpg"),
            base + "/body.jpg",
            "A curated document without explicit leadImageURL falls back to usable extracted images")

        let abbrevText =
            "Envoy visited St. Petersburg for talks with U.S. and U.K. diplomats. Dr. Smith commented on the report."
        let sentences = PassageFactExtractor.segmentedSentences(in: abbrevText).map {
            abbrevText[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        assertEqual(sentences.count, 2, "Sentence segmentation must not split on St. or U.S. or Dr.")
        assertEqual(
            sentences.first, "Envoy visited St. Petersburg for talks with U.S. and U.K. diplomats.",
            "Abbreviation sentence preserved")
        assertEqual(sentences.last, "Dr. Smith commented on the report.", "Second sentence preserved")

        let quoteText =
            "He said \"The outcome was positive. We expect further meetings.\" Next sentence starts here."
        let quoteSentences = PassageFactExtractor.segmentedSentences(in: quoteText).map {
            quoteText[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        assertEqual(quoteSentences.count, 2, "Unclosed quotes should not be split across sentence boundaries")
        assertEqual(
            quoteSentences.first, "He said \"The outcome was positive. We expect further meetings.\"",
            "Quote sentence preserved")

        let oversizedHTML =
            "<article><p>\(first)</p><figure><img src='/oversized.jpg' width='20000' height='20000'></figure><p>\(second)</p></article>"
        guard
            case .success(let oversizedText, _, let oversizedDocument) = ContentExtractionPipeline.shared
                .extractFromHTML(oversizedHTML, baseUrl: base)
        else { fatalError("Oversized media must not discard prose") }
        assertTrue(oversizedText.contains(first), "Oversized media keeps publisher prose")
        assertFalse(
            oversizedDocument?.blocks.contains { $0.kind == .figure } == true,
            "Oversized declared dimensions are excluded before image requests")
        let bodyOnlyRSS =
            "<rss xmlns:content='http://purl.org/rss/1.0/modules/content/'><channel><title>Publisher</title><item><guid>rss-no-page</guid><title>Offline report</title><content:encoded><![CDATA[\(shapes[0])]]></content:encoded></item></channel></rss>"
        let bodyOnly = FeedXMLParser(data: Data(bodyOnlyRSS.utf8), feedURL: base).parse().first!
        assertEqual(bodyOnly.link, "", "RSS-only fixture has no fetchable article page")
        assertEqual(
            bodyOnly.readerDocument?.blocks.filter { $0.kind == .paragraph }.count, 2,
            "RSS-only publisher body retains paragraph structure without a page fetch")
        assertTrue(
            bodyOnly.fullContent?.contains(first) == true && bodyOnly.contentFetched,
            "RSS-only publisher content is ready for native rendering")

        let html = shapes[10]
        let rss =
            "<rss version='2.0'><channel><title>Fixture publisher</title><item><title>Report</title><link>\(base)</link><description>Preview</description><content:encoded xmlns:content='http://purl.org/rss/1.0/modules/content/'><![CDATA[\(html)]]></content:encoded></item></channel></rss>"
        let rssArticle = FeedXMLParser(data: Data(rss.utf8), feedURL: base).parse().first!
        assertEqual(
            rssArticle.readerDocument?.blocks.first(where: { $0.kind == .figure })?.imageCredit, figure.imageCredit,
            "RSS-only structure and credit survive parsing")
        let json = try JSONSerialization.data(withJSONObject: [
            "version": "https://jsonfeed.org/version/1.1",
            "items": [["id": "json-v4", "url": base, "title": "Report", "content_html": html]],
        ])
        let jsonArticle = JSONFeedParser.parse(data: json, feedURL: base)!.first!
        assertTrue(
            jsonArticle.readerDocument?.blocks.contains { $0.kind == .figure } == true,
            "JSON Feed HTML stays structured")
        let atom =
            "<feed xmlns='http://www.w3.org/2005/Atom'><title>Publisher</title><entry><id>atom-v4</id><title>Report</title><link href='\(base)'/><content type='xhtml'><div xmlns='http://www.w3.org/1999/xhtml'><p>\(first) <strong>Actual finding</strong></p><p>\(second)</p></div></content></entry></feed>"
        let atomArticle = FeedXMLParser(data: Data(atom.utf8), feedURL: base).parse().first!
        assertTrue(
            atomArticle.readerDocument?.blocks.first?.inlineRuns?.contains { $0.strong } == true,
            "Atom XHTML inline markup survives XML parsing")
        let mediaRSS =
            "<rss xmlns:media='http://search.yahoo.com/mrss/'><channel><title>Publisher</title><item><title>Media report</title><link>\(base)</link><enclosure url='\(base)/audio.mp3' type='audio/mpeg'/><media:content url='\(base)/scene.jpg' type='image/jpeg' width='1200' height='800'/><media:credit>Publisher photographer</media:credit></item></channel></rss>"
        let mediaArticle = FeedXMLParser(data: Data(mediaRSS.utf8), feedURL: base).parse().first!
        assertEqual(mediaArticle.imageUrl, base + "/scene.jpg", "Audio enclosures are not image candidates")
        assertEqual(mediaArticle.readerDocument?.images?.first?.width, 1200, "Feed dimensions retained")
        assertEqual(
            mediaArticle.readerDocument?.images?.first?.credit, "Publisher photographer", "Feed image credit retained")
        assertFalse(mediaArticle.readerDocument?.hasPublisherText ?? true, "Feed media alone is not a reader document")
        // The Guardian lists sized renditions with neither type nor medium; the widest one leads.
        let sizedRSS =
            "<rss xmlns:media='http://search.yahoo.com/mrss/'><channel><title>Publisher</title><item><title>Sized report</title><link>\(base)</link><media:content width='140' url='\(base)/small.jpg'/><media:content width='460' url='\(base)/large.jpg'/><media:content url='\(base)/clip.mp4' medium='video'/></item></channel></rss>"
        let sizedArticle = FeedXMLParser(data: Data(sizedRSS.utf8), feedURL: base).parse().first!
        assertEqual(sizedArticle.imageUrl, base + "/large.jpg", "Untyped sized media:content is an image, widest first")
        assertEqual(
            sizedArticle.readerDocument?.leadImageURL, base + "/large.jpg",
            "The lead prefers the larger rendition on equal evidence")
        assertEqual(sizedArticle.readerDocument?.images?.count, 2, "Video media:content is not an image")
        // A site mark is not the story's picture (#995): the SVG of CNBC's page chrome blocked the page lookup.
        let vectorRSS =
            "<rss xmlns:media='http://search.yahoo.com/mrss/'><channel><title>Publisher</title><item><title>Vector report</title><link>\(base)</link><media:content url='\(base)/mark.svg' type='image/svg+xml'/><description><![CDATA[<img src='\(base)/site.svg'><img src='\(base)/photo.jpg'>Text]]></description></item><item><title>Mark only</title><link>\(base)/2</link><media:content url='\(base)/mark.svg' type='image/svg+xml'/></item><item><title>Typed mark</title><link>\(base)/3</link><media:content url='\(base)/mark' type='image/svg+xml'/><description><![CDATA[<img src='\(base)/pixel.gif'><img src='\(base)/story.jpg'>Text]]></description></item></channel></rss>"
        let vectorArticles = FeedXMLParser(data: Data(vectorRSS.utf8), feedURL: base).parse()
        assertEqual(vectorArticles.first?.imageUrl, base + "/photo.jpg", "A feed SVG gives way to the photo after it")
        assertTrue(vectorArticles[1].imageUrl == nil, "A feed with only an SVG has no image: the page lookup runs")
        assertEqual(
            vectorArticles.last?.imageUrl, base + "/story.jpg",
            "A declared SVG type and a tracking pixel give way to the photo")
        let entityRSS =
            "<rss><channel><title>Publisher</title><item><title>Entity report</title><link>\(base)/entity</link><description><![CDATA[Infantino in March&#039;s vote &#x2014; &hellip;]]></description></item></channel></rss>"
        assertEqual(
            FeedXMLParser(data: Data(entityRSS.utf8), feedURL: base).parse().first?.description,
            "Infantino in March's vote — …", "Feed summaries decode numeric and named entities")
        assertEqual(
            ReaderImageCandidate.preferredRendition(
                of: URL(string: "https://ichef.bbci.co.uk/ace/standard/240/cpsprodpb/a/live/b.jpg")!
            ).absoluteString,
            "https://ichef.bbci.co.uk/ace/standard/976/cpsprodpb/a/live/b.jpg",
            "BBC thumbnails request a sharper rendition")
        assertEqual(
            ReaderImageCandidate.preferredRendition(of: URL(string: base + "/ace/standard/240/b.jpg")!).absoluteString,
            base + "/ace/standard/240/b.jpg", "Other hosts keep their image URL")
        assertTrue(
            ArticleContentRedactor.isBoilerplateLine("Topics:ReformGiorgia MeloniItaly"), "Tag strips are boilerplate")
        assertFalse(
            ArticleContentRedactor.isBoilerplateLine(
                "Topics discussed at the summit included trade and security policy."),
            "Prose that mentions topics stays")
        assertTrue(
            ArticleContentRedactor.isBoilerplateLine(
                "To display this content from YouTube, you must enable advertisement tracking and audience measurement."
            ), "Embedded-video consent notices are boilerplate")
        assertTrue(
            ArticleContentRedactor.isBoilerplateLine(
                "One of your browser extensions seems to be blocking the video player from loading."),
            "Video player notices are boilerplate")
        assertTrue(
            ArticleContentRedactor.isBoilerplateLine("Keywords for this article"),
            "France 24 keyword footer header is boilerplate")
        assertTrue(
            ArticleContentRedactor.isBoilerplateLine("Keywords for this story"),
            "Keywords header variation is boilerplate")
        assertTrue(
            ArticleContentRedactor.isBoilerplateLine(
                "The content you requested does not exist or is not available anymore."),
            "France 24 unavailable widget placeholder notice is boilerplate")
        assertTrue(
            documents[0].hasPublisherText && bodyOnly.readerDocument?.hasPublisherText == true,
            "Publisher text makes a reader document")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        try await db.upsertArticles([rssArticle])
        assertEqual(
            try await db.fetchArticles().first?.readerDocument, rssArticle.readerDocument, "Feed reader v4 persists")
        try await db.updateEnrichment(articleId: rssArticle.id, update: .init(content: first, readerDocument: noImage))
        assertTrue(try await db.fetchArticles().first?.imageUrl == nil, "Curation can clear a wrong image in storage")
        var repeats = [FeedArticle]()
        for index in 0..<3 {
            repeats.append(
                FeedArticle(
                    title: "Document \(index)", link: base + "/\(index)", guid: "repeat-\(index)", description: first,
                    pubDate: Date(), source: "Recurring publisher", imageUrl: base + "/shared.jpg"))
        }
        try await db.upsertArticles(Array(repeats.prefix(2)))
        assertTrue(
            try await db.repeatedImageURLs(source: "Recurring publisher").isEmpty,
            "Two documents do not make an image recurring")
        try await db.upsertArticles([repeats[2]])
        let repeated = try await db.repeatedImageURLs(source: "Recurring publisher")
        assertEqual(
            repeated, Set([base + "/shared.jpg"]),
            "Recurrence counts distinct publisher documents, also after an earlier lookup was cached (#778)")
        assertTrue(
            try await db.fetchArticles().filter { $0.source == "Recurring publisher" }.allSatisfy {
                $0.imageUrl == nil
            }, "Feed cards omit repeated publisher furniture on hydration")
        assertTrue(
            try await db.fetchArticles(includingOriginals: true).filter { $0.source == "Recurring publisher" }
                .allSatisfy { $0.imageUrl != nil }, "Explicit original retrieval preserves stored image metadata")
        assertTrue(
            try await db.searchArticles(query: "Document").allSatisfy { $0.imageUrl == nil },
            "Search uses the same media curation")
        assertTrue(
            try await db.repeatedImageURLs(source: "Other publisher").isEmpty,
            "Recurrence never leaks between publishers")
        assertTrue(
            documents[10].curated(feedImage: nil, title: "Report", excluding: Set([figure.imageURL!])).blocks.allSatisfy
            { $0.kind != .figure }, "Repeated publisher furniture is removed during curation")

        // #115: a summary-only feed with media (the mediaRSS shape) refreshes an article the reader already extracted.
        let mediaOnly = FeedArticle(
            title: "Refreshed report", link: base + "/refreshed", guid: "refreshed-report", description: "Preview",
            pubDate: Date(), source: "Refresh publisher", imageUrl: base + "/scene.jpg",
            readerDocument: ReaderDocument(
                blocks: [], images: [ReaderImageCandidate(url: base + "/scene.jpg", origin: .feed)]))
        try await db.upsertArticles([mediaOnly])
        var movedMedia = mediaOnly
        movedMedia.readerDocument = ReaderDocument(
            blocks: [], images: [ReaderImageCandidate(url: base + "/replacement.jpg", origin: .feed)])
        try await db.upsertArticles([movedMedia])
        assertEqual(
            try await db.fetchArticles(limit: 1, id: mediaOnly.id).first?.readerDocument?.images?.first?.url,
            base + "/replacement.jpg", "Feed media still refreshes a media-only document")
        let extracted = documents[1]
        try await db.updateEnrichment(
            articleId: mediaOnly.id, update: .init(content: first + "\n\n" + second, readerDocument: extracted))
        var teaser = mediaOnly
        teaser.fullContent = "Feed teaser"
        for refresh in [mediaOnly, teaser] {
            try await db.upsertArticles([refresh])
            let stored = try await db.fetchArticles(limit: 1, id: mediaOnly.id).first
            assertEqual(
                stored?.readerDocument?.blocks, extracted.blocks,
                "A refresh without publisher text keeps the extracted headings and paragraphs")
            assertTrue(
                stored?.fullContent?.contains(second) == true,
                "A refresh without publisher text keeps the extracted body")
        }
        var fullFeed = mediaOnly
        fullFeed.fullContent = second
        fullFeed.readerDocument = ReaderDocument(blocks: [ReaderBlock(kind: .paragraph, text: second)])
        try await db.upsertArticles([fullFeed])
        let replaced = try await db.fetchArticles(limit: 1, id: mediaOnly.id).first
        assertEqual(
            replaced?.readerDocument?.blocks, fullFeed.readerDocument?.blocks,
            "Feed publisher text still replaces the stored document")
        assertEqual(replaced?.fullContent, second, "Feed publisher text still replaces the stored body")
        await db.close()
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
        assertEqual(
            leadImage, "https://ichef.bbci.co.uk/news/1024/branded_news/abc12345.jpg", "Lead image must be extracted")
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
            "Independent observers commended the transparency mechanisms embedded within the final treaty text as unprecedented in multilateral diplomacy.",
        ]
        assertEqual(
            ContentQualityValidator.validate(paragraphs: valid), .valid, "Substantive article must pass validation")

        // 2. Empty paragraphs rejected
        assertEqual(
            ContentQualityValidator.validate(paragraphs: []), .rejected(reason: "No readable paragraphs found"),
            "Empty paragraphs rejected")

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
            "A single short paragraph covering the mountain rescue effort in northern Nepal.",
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
            "The council published a detailed report on local transport improvements and future investment.",
        ]
        if case .rejected(let reason) = ContentQualityValidator.validate(paragraphs: repeated) {
            assertTrue(reason.contains("repetitive"), "Must detect duplicate text loop")
        } else {
            assertTrue(false, "Should reject repetitive syndication loops")
        }
    }

    static func testReaderFurnitureRemoval() async {
        print("  - Testing reader furniture removal (title, stamps, bios, follow prompts, rails, teasers)...")
        let pipeline = ContentExtractionPipeline.shared
        let body = """
            <p>We gave the phone a seven out of ten. But that was not always the score we planned, and it might not be the right score forever. Such are the challenges of reviewing a big new idea about the most popular device.</p>
            <p>On this episode, the hosts debate whether the phone deserved the score it got, and try to work through how this device might change over time. Is the outer screen a feature or a bug for the device as a whole?</p>
            <p>After that, the hosts talk about the huge security flaw that rocked the web this week and what it means for the future of the web, artificial intelligence, and everything else people build online.</p>
            """
        func texts(_ outcome: ExtractionOutcome) -> [String] {
            outcome.document?.blocks.map { "\($0.kind):\($0.text)" } ?? []
        }

        // A publisher lede: the title, a standfirst after it, a time stamp, an author bio, a follow prompt and
        // rails of teaser cards, none with a semantic class name.
        let ledePage = """
            <html><head><title>Phones</title></head><body><article>
            <div class="l1"><div><h1>The phone should have been a tablet</h1><p class="c1">On the podcast: Notes on a phone review, a security scandal, and more.</p></div>
            <div><span class="s1"><time datetime="2026-10-23T17:00:00Z">Oct 23, 2026, 5:00 PM UTC</time></span></div>
            <div><div><span class="c1">is editor-at-large and podcast co-host with over a decade of experience covering consumer tech. Previously, at three other publications.</span></div></div></div>
            <div class="e1">\(body)
            <div class="t1"><span><strong>Follow topics and authors</strong> from this story to see more like this in your personalized homepage feed and to receive email updates.</span><ul><li id="follow-author-x"><span>Dana Pierce</span></li></ul></div>
            </div></article>
            <div class="x1"><h2>Most Popular</h2><ol><li><a href="/a">A dangerous grip on outer space</a></li><li><a href="/b">People are coding their way to better TVs</a></li></ol></div>
            <div class="y1"><h2>Top Stories</h2><div class="z1"><span>Jess Weatherbed 4:52 PM UTC</span><a href="/c">No, the phone is not a small phone and that is fine</a></div><div class="z1"><span>Andrew Webster 12:00 PM UTC</span><a href="/d">A streamer cannot fire its way out of this downward spiral</a></div></div>
            </body></html>
            """
        let lede = pipeline.extractFromHTML(ledePage, baseUrl: "https://news.example/a")
        let ledeKinds = lede.document?.blocks.map(\.kind) ?? []
        assertEqual(
            ledeKinds, [.standfirst, .paragraph, .paragraph, .paragraph],
            "The paragraph after <h1> is the standfirst; stamp, bio, follow prompt and rails are not story text: "
                + "\(texts(lede))")
        assertTrue(
            lede.document?.blocks.first?.text.hasPrefix("On the podcast:") == true,
            "The standfirst keeps the publisher's text")

        // A recommendation section inside the body (Al Jazeera's more-on) and a class-less one both go; a real
        // section heading stays, as does prose that names a former editor.
        let sectioned = """
            <html><body><main><div class="wysiwyg">\(body)
            <section class="more-on"><h2>Recommended Stories</h2><ul><li><a href="/x">Regulator sues network claiming retaliation over coverage</a></li></ul></section>
            <h2>Public, private, or both?</h2>
            <p>Jordan Smith is a former editor of the paper, and said the plan would take a strong partnership with local and state governments before anything could be built on the coast.</p>
            <section><h2>Related Articles</h2><p><a href="/y">Launch site study names three candidates</a></p></section>
            <p>There were 175 orbital launch attempts last year from the two existing ranges, and officials project the country will need far more capacity before the end of the decade.</p>
            <div class="author-mini-bio"><img src="https://news.example/head.jpg" width="200" height="200"><p>Stephen Clark Space Reporter</p></div>
            <p>Stephen Clark is a space reporter at the publication, covering private space companies and the world's space agencies.</p>
            </div></main></body></html>
            """
        let section = pipeline.extractFromHTML(sectioned, baseUrl: "https://news.example/b")
        let sectionTexts = texts(section)
        assertEqual(
            section.document?.blocks.map(\.kind) ?? [],
            [.paragraph, .paragraph, .paragraph, .heading, .paragraph, .paragraph],
            "Navigation headings and bios go, section headings and prose stay: \(sectionTexts)")
        assertTrue(
            sectionTexts.contains { $0.hasPrefix("heading:Public, private") }
                && sectionTexts.contains { $0.contains("former editor") }
                && !sectionTexts.contains {
                    $0.contains("Recommended") || $0.contains("Related") || $0.contains("space reporter at")
                },
            "Only the publisher's own heading and prose remain: \(sectionTexts)")

        // Utility-class hidden duplicates are not shown twice; a feed teaser ending in its own link is incomplete.
        let hiddenDuplicate = pipeline.extractFromHTML(
            "<html><body><article><div class=\"ad-shell hidden\"><p>A sponsored placeholder paragraph the page keeps hidden until an advertising script fills it.</p></div>\(body)</article></body></html>"
        )
        assertEqual(
            hiddenDuplicate.document?.blocks.count, 3,
            "A `hidden` utility class hides its subtree: \(texts(hiddenDuplicate))")
        let responsive = pipeline.extractFromHTML(
            "<html><body><article><div class=\"hidden md:block\">\(body)</div></article></body></html>")
        assertEqual(
            responsive.document?.blocks.count, 3,
            "`hidden md:block` shows on wide windows, so its body stays: \(texts(responsive))")
        // Layout modifiers name what sits beside the story, not the story (PBS, Science News, Variety, IEEE).
        for wrapper in [
            "<section class=\"article-with-sidebar\">", "<div class=\"page__body page__body--with-sidebar\">",
            "<div class=\"non_member_follow\">",
        ] {
            let tag = wrapper.hasPrefix("<section") ? "section" : "div"
            let wrapped = pipeline.extractFromHTML("<html><body><main>\(wrapper)\(body)</\(tag)></main></body></html>")
            assertEqual(wrapped.document?.blocks.count, 3, "\(wrapper) keeps the story: \(texts(wrapped))")
        }
        let teaser = pipeline.extractFromHTML(
            body
                + "<p><a href=\"https://news.example/story/\">Read full article</a></p><p><a href=\"https://news.example/story/#comments\">Comments</a></p>",
            baseUrl: "https://news.example/story/")
        assertEqual(teaser.document?.isComplete, false, "A teaser ending in Read full article is incomplete")
        assertEqual(
            teaser.document?.hasCompleteArticleBody, false, "The reader fetches the page for an incomplete teaser")
        let continued = pipeline.extractFromHTML(
            body + " <a href=\"https://news.example/story/\">Continue reading...</a>",
            baseUrl: "https://news.example/story/")
        assertEqual(continued.document?.isComplete, false, "A Guardian-style Continue reading… link marks a teaser")
        let whole = pipeline.extractFromHTML(body, baseUrl: "https://news.example/story/")
        assertEqual(whole.document?.isComplete, true, "Three full paragraphs without a trailing link are complete")
        // The Verge: three paragraphs over 600 characters that end "… Read the full story at The Verge." (#586). The
        // completeness rule does not override the closing line, and the same body trailing off in an ellipsis is a
        // teaser too; a sentence that merely says "read more" is not.
        let verge = pipeline.extractFromHTML(
            body.replacingOccurrences(
                of: "</p>", with: "… Read the full story at The Verge.</p>", options: .backwards,
                range: body.range(of: "</p>", options: .backwards)),
            baseUrl: "https://www.theverge.com/story/")
        assertEqual(verge.document?.isComplete, false, "A Verge teaser closing with the publisher line is incomplete")
        assertEqual(verge.document?.hasCompleteArticleBody, false, "The reader fetches The Verge page")
        let trailing = pipeline.extractFromHTML(
            body.replacingOccurrences(
                of: "</p>", with: "…</p>", options: .backwards, range: body.range(of: "</p>", options: .backwards)),
            baseUrl: "https://news.example/story/")
        assertEqual(trailing.document?.isComplete, false, "A last paragraph trailing off in an ellipsis is a teaser")
        let mention = pipeline.extractFromHTML(
            body.replacingOccurrences(
                of: "</p>", with: " Those who want detail can read more in the report.</p>", options: .backwards,
                range: body.range(of: "</p>", options: .backwards)),
            baseUrl: "https://news.example/story/")
        assertEqual(mention.document?.isComplete, true, "A sentence that merely says \"read more\" is not a teaser")
        assertTrue(ReaderDocument.closesAsTeaser("Read more on Ars Technica"), "Read more on <publisher>")
        assertTrue(ReaderDocument.closesAsTeaser("Continue reading at Engadget…"), "Continue reading at <publisher>")
        assertFalse(ReaderDocument.closesAsTeaser("The minister said she would read more before deciding."), "Prose")
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

}

extension PublisherContentRevision {
    /// Everything but the kept text, which a cache purge removes.
    fileprivate var fingerprint: String {
        "\(version)|\(kind)|\(observedAt.timeIntervalSince1970)|\(changedFields)|\(inputHash)"
    }
}
