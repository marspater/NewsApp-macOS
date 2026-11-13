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
import Testing

extension NativeSuites {
    /// Input FeedKit and SwiftSoup mishandle, and the app's handling of it.
    @Suite(.tags(.feedParsing, .integration)) struct FeedDependencySuite {
        private static func rss(_ item: String, namespaces: String = "") -> Data {
            Data(
                """
                <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" \
                xmlns:media="http://search.yahoo.com/mrss/" \(namespaces)><channel><title>T</title>\
                <item><title>Hello</title><link>https://example.com/a</link><guid>g</guid>\(item)</item>\
                </channel></rss>
                """.utf8)
        }

        private static func parse(_ data: Data) -> FeedArticle? {
            FeedXMLParser(data: data, feedURL: "https://example.com/feed").parse().first
        }

        @Test(arguments: [
            #"<enclosure url="https://example.com/a.mp3" length="" type="audio/mpeg"/>"#,
            #"<media:content url="https://example.com/a.jpg" medium="image" width="100%"/>"#,
            #"<media:content url="https://example.com/a.jpg" medium="image" fileSize=""/>"#,
            #"<media:content url="https://example.com/a.mp4" medium="video" duration="1:30"/>"#,
            #"<media:content url="https://example.com/a.jpg" medium="image" isDefault="yes"/>"#,
            #"<media:community><media:statistics views="1,234"/></media:community>"#,
            "<pubDate>Yesterday at noon</pubDate>",
            "<pubDate>2026-11-08</pubDate>",
            "<dc:date>n/a</dc:date>",
        ])
        func anUnconvertibleValueKeepsTheByline(field: String) {
            #expect(Self.parse(Self.rss("<dc:creator>Jane Doe</dc:creator>\(field)"))?.author == "Jane Doe")
        }

        @Test func bylinesCombineAndSkipAnEntrysSource() {
            let creators = Self.rss("<dc:creator>Jane</dc:creator><dc:creator>John</dc:creator><author>Jane</author>")
            #expect(Self.parse(creators)?.author == "Jane, John", "Repeated names appear once")
            let atom = Data(
                """
                <feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><entry><title>H</title><id>a</id>
                <link href="https://example.com/a"/><author><name>Jane</name><email>j@example.com</email></author>
                <source><author><name>Other</name></author></source><updated>soon</updated></entry></feed>
                """.utf8)
            #expect(Self.parse(atom)?.author == "Jane")
        }

        @Test func anUnreadableDateFallsToTheNextField() {
            let dated = Self.rss("<pubDate>soon</pubDate><dc:date>2026-11-01T10:00:00Z</dc:date>")
            #expect(Self.parse(dated)?.pubDate == Date(timeIntervalSince1970: 1_793_527_200))
        }

        /// FeedKit's lenient fallback read this as midnight.
        @Test func zoneLessRFC822KeepsItsTime() {
            #expect(DateParser.parse("Sun, 8 Nov 2026 10:00:00") == Date(timeIntervalSince1970: 1_794_132_000))
            #expect(DateParser.parse("2026-11-08T10:00+01:00") == Date(timeIntervalSince1970: 1_794_128_400))
            #expect(DateParser.parse("Sun, 08 Nov 2026") == Date(timeIntervalSince1970: 1_794_096_000))
        }

        @Test func impossibleDatesAreRejectedAndOffsetsApplied() {
            #expect(DateParser.parse("Sun, 31 Feb 2026 10:00:00 GMT") == nil)
            #expect(DateParser.parse("Sun, 08 Nov 2026 25:00:00 GMT") == nil)
            #expect(DateParser.parse("2026-11-08 10:00:00 +0100") == Date(timeIntervalSince1970: 1_794_128_400))
        }

        @Test func strayTextAroundTheDocumentIsNotFatal() {
            let rss = String(decoding: Self.rss("<dc:creator>J</dc:creator>"), as: UTF8.self)
            let parsers = [
                FeedXMLParser(data: Data((rss + "[]").utf8), feedURL: "https://example.com/feed"),
                FeedXMLParser(
                    data: Data(("\n  <?xml version=\"1.0\"?>" + rss).utf8), feedURL: "https://example.com/feed"),
            ]
            for parser in parsers {
                #expect(parser.parse().count == 1)
                #expect(parser.parseError == nil)
            }
            let truncated = FeedXMLParser(data: Data(rss.dropLast(10).utf8), feedURL: "https://example.com/feed")
            #expect(truncated.parse().isEmpty)
            #expect(truncated.parseError != nil, "A document that stops inside its root is still malformed")
        }

        @Test func namespacesWithoutATrailingSlashAreRecognized() {
            let feed = Data(
                """
                <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss"><channel><title>T</title><item>\
                <title>H</title><link>https://example.com/a</link>\
                <media:thumbnail url="https://cdn.example.com/a.jpg"/></item></channel></rss>
                """.utf8)
            #expect(Self.parse(feed)?.imageUrl == "https://cdn.example.com/a.jpg")
        }

        @Test func dublinCoreAndContentNamespacesWithoutATrailingSlashAreRecognized() {
            let feed = Data(
                """
                <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1" \
                xmlns:content="http://purl.org/rss/1.0/modules/content"><channel><title>T</title><item>\
                <title>H</title><link>https://example.com/a</link><dc:creator>Jane</dc:creator>\
                <content:encoded><![CDATA[<p>The encoded body of the story.</p>]]></content:encoded></item>\
                </channel></rss>
                """.utf8)
            let article = Self.parse(feed)
            #expect(article?.author == "Jane")
            #expect(article?.fullContent?.contains("The encoded body of the story.") == true)
        }

        @Test(arguments: [
            #"{"id":1.5,"url":"https://example.com/1","title":"A"}"#,
            #"{"id":"1","url":"https://example.com/1","title":2026}"#,
            #"{"id":"1","url":{"x":1},"title":"A"}"#,
            #"{"id":"1","url":"https://example.com/1","title":"A","tags":[{"name":"World"}]}"#,
            #"{"id":"1","url":"https://example.com/1","title":"A","image":{"url":"https://example.com/a.jpg"}}"#,
            #"{"id":"1","url":"https://example.com/1","title":"A","content_text":12}"#,
            #""not an item""#,
        ])
        func aMistypedJSONMemberKeepsTheFeed(item: String) {
            let feed = #"{"title":5,"version":1,"items":["# + item + #",{"id":"ok","url":"https://example.com/ok"}]}"#
            let articles = JSONFeedParser.parse(data: Data(feed.utf8), feedURL: "https://example.com/feed.json")
            #expect(articles?.contains { $0.guid == "ok" } == true)
        }

        @Test func jsonFeedTagsAndAuthorsAreRead() {
            func item(_ members: String) -> FeedArticle? {
                let feed = #"{"items":[{"id":"1","url":"https://example.com/1",\#(members)}]}"#
                return JSONFeedParser.parse(data: Data(feed.utf8), feedURL: "https://example.com/f")?.first
            }
            #expect(item(#""tags":"World""#)?.category == "World")
            #expect(item(#""tags":["World",5]"#)?.category == "World")
            #expect(item(#""authors":[{"name":"Jane"},{"name":"John"}]"#)?.author == "Jane, John")
            #expect(item(#""author":{"name":"Jane"}"#)?.author == "Jane")
            #expect(item(#""author":"Jane""#)?.author == "Jane")
        }

        @Test func aBooleanJSONIDFallsBackToTheURL() {
            let feed =
                #"{"items":[{"id":true,"url":"https://example.com/a"},{"id":true,"url":"https://example.com/b"}]}"#
            let articles = JSONFeedParser.parse(data: Data(feed.utf8), feedURL: "https://example.com/f") ?? []
            #expect(articles.count == 2)
            #expect(Set(articles.map(\.guid)).count == 2)
            #expect(!articles.contains { $0.guid == "1" })
        }

        @Test func anEmptyJSONContentHTMLKeepsTheContentText() {
            let body = String(repeating: "The council approved the flood defence plan on Tuesday. ", count: 20)
            let feed =
                #"{"items":[{"id":"1","url":"https://example.com/1","content_html":"","content_text":"\#(body)"}]}"#
            let article = JSONFeedParser.parse(data: Data(feed.utf8), feedURL: "https://example.com/f")?.first
            #expect(article?.fullContent?.contains("flood defence plan") == true)
        }

        @Test func nestingBombsNeverReachTheParser() {
            let bomb = String(repeating: "<table><tr><td>", count: 40_000) + "x"
            let elapsed = ContinuousClock().measure {
                #expect(ContentExtractionPipeline.shared.extractFromHTML(bomb).content == nil)
                #expect(ContentExtractionPipeline.shared.extractLeadImages(from: bomb).isEmpty)
            }
            #expect(elapsed < .seconds(30), "Without the bound this parse runs for hours")
        }

        @Test func endTagsOutsideTheirScopeReachNeitherEntryPoint() {
            let bomb = String(repeating: "<div><table><tr><td></div></table>", count: 3_000)
            let elapsed = ContinuousClock().measure {
                #expect(ContentExtractionPipeline.shared.extractFromHTML(bomb).content == nil)
                #expect(ContentExtractionPipeline.shared.extractLeadImages(from: bomb).isEmpty)
            }
            #expect(elapsed < .seconds(30))
        }

        @Test func aBalancedTableInsideADivIsNotDeep() {
            let page = String(repeating: "<div><table><tr><td><div>x</div></td></tr></table></div>", count: 3_000)
            #expect(!HTMLDOMBuilder.nestsTooDeeply(page))
        }

        @Test func nestingEstimateIgnoresPagesThatAreNot() {
            #expect(!HTMLDOMBuilder.nestsTooDeeply(String(repeating: "<div>a</div><p>b<br><li>c", count: 20_000)))
            let script = "<script>" + String(repeating: "for(i=0;i<n;i++)'<div>';", count: 20_000) + "</script><p>x"
            #expect(!HTMLDOMBuilder.nestsTooDeeply(script))
            #expect(!HTMLDOMBuilder.nestsTooDeeply(String(repeating: "<path d=\"M0 0\"/>", count: 5_000)))
            #expect(HTMLDOMBuilder.nestsTooDeeply(String(repeating: "<DIV>", count: 3_000)))
        }

        /// None of these closes an element for the parser, so the depth is real.
        @Test(arguments: [
            "<div><!-- </div> -->", "<div><!-- </div> --!>", #"<div title="</div>">"#, "<div title='</div>'>",
            "<div><!--!></div>-->", "<div><!---!></div>-->", "<div><!----!></div>-->",
            "<div><table><tr><td></div></table>", "<div><object></div></object>", "<div><marquee></div></marquee>",
            "<div><textarea></div></textarea>", "<div><title></div></title>", "<x-a></x-b>", "<div a=/>",
            #"<div a=b"></div">"#,
        ])
        func markupThatClosesNothingCannotHideDepth(unit: String) {
            #expect(HTMLDOMBuilder.nestsTooDeeply(String(repeating: unit, count: 3_000)))
        }

        @Test func aQuoteOutsideAValueCannotHideTheRestOfThePage() {
            for opener in [#"<div a">"#, #"<div =">"#, "<div a=b'>"] {
                #expect(HTMLDOMBuilder.nestsTooDeeply(opener + String(repeating: "<div>", count: 3_000)))
            }
        }

        @Test(arguments: [
            "<!-- <div> -->", "<!--> <div></div>", "<!---> <div></div>", #"<div title="<div>"></div>"#,
            "<script><!--</script><p>x",
            "<TEXTAREA><div></TEXTAREA>", "a < b <1 </1>", "<div/>", #"<div a="b"/>"#,
        ])
        func markupThatOpensNothingDoesNotCount(unit: String) {
            #expect(!HTMLDOMBuilder.nestsTooDeeply(String(repeating: unit, count: 3_000)))
        }

        @Test func manyRemovedSiblingsDoNotStallExtraction() {
            let page = "<article>" + String(repeating: "<style></style>", count: 80_000) + "</article>"
            let elapsed = ContinuousClock().measure { _ = ContentExtractionPipeline.shared.extractFromHTML(page) }
            #expect(elapsed < .seconds(30), "Removal in document order took over 200 seconds in a debug build")
        }

        @Test func linkedDataWithACharsetParameterIsRead() {
            let body = (1...12).map { "Sentence number \($0) of the story carries enough ordinary words to count." }
                .joined(separator: " ")
            let html = #"<script type="application/ld+json; charset=utf-8">{"articleBody":"\#(body)"}</script>"#
            #expect(
                ContentExtractionPipeline.shared.extractFromHTML(html).content?.contains("Sentence number 12") == true)
        }
    }
}
