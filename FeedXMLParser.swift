import Foundation

/// Standalone XML / RSS 2.0 / Atom parser with security guards against
/// recursion bombs, entity expansions, and oversized element nesting.
final class FeedXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let feedURL: String
    private var articles = [FeedArticle]()

    private var currentElement = ""
    private var insideItem = false
    private var channelTitle = ""
    private var parsingChannelTitle = false

    private var itemTitle = ""
    private var itemDescription = ""
    private var itemLink = ""
    private var itemGuid = ""
    private var itemPubDate = ""
    private var itemImageUrl = ""
    private var itemCategory = ""
    private var itemContentEncoded = ""
    private var isCollectingContentEncoded = false

    private var currentNestingDepth = 0
    private let maxNestingDepth = 64
    private let maxArticlesPerFeed = 500

    init(data: Data, feedURL: String = "") {
        self.data = data
        self.feedURL = feedURL
    }

    func parse() -> [FeedArticle] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.parse()

        // Post-parse: if channelTitle is still empty, extract from feedURL
        if channelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            channelTitle = extractSourceFromURL(feedURL)
        }

        // Apply channelTitle to any article that has "Feed" or empty source
        for i in 0..<articles.count {
            let src = articles[i].source
            if src.isEmpty || src == "Feed" || src == "Unknown" {
                let name = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    articles[i] = FeedArticle(
                        title: articles[i].title, link: articles[i].link,
                        guid: articles[i].guid,
                        description: articles[i].description, pubDate: articles[i].pubDate,
                        source: name, imageUrl: articles[i].imageUrl,
                        aiSummary: articles[i].aiSummary, fullContent: articles[i].fullContent,
                        category: articles[i].category, contentFetched: articles[i].contentFetched
                    )
                }
            }
        }
        return articles
    }

    private func extractSourceFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        var name = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
            .replacingOccurrences(of: "rss.", with: "")
        if let dotRange = name.range(of: ".", options: .backwards) {
            name = String(name[..<dotRange.lowerBound])
        }
        if let dotRange = name.range(of: ".", options: .backwards) {
            name = String(name[name.index(after: dotRange.lowerBound)...])
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentNestingDepth += 1
        if currentNestingDepth > maxNestingDepth {
            parser.abortParsing()
            return
        }

        currentElement = elementName

        if elementName == "channel" || elementName == "feed" {
            parsingChannelTitle = true
        }

        if elementName == "item" || elementName == "entry" {
            insideItem = true
            parsingChannelTitle = false
            itemTitle = ""
            itemDescription = ""
            itemLink = ""
            itemGuid = ""
            itemPubDate = ""
            itemImageUrl = ""
            itemCategory = ""
            itemContentEncoded = ""
        }

        if elementName == "content:encoded" || (elementName == "content" && insideItem) {
            isCollectingContentEncoded = true
            itemContentEncoded = ""
        }

        if insideItem && (elementName == "enclosure" || elementName == "media:content" || elementName == "media:thumbnail") {
            if let url = attributeDict["url"], !url.isEmpty {
                if let type = attributeDict["type"], type.hasPrefix("image") {
                    itemImageUrl = url
                } else if itemImageUrl.isEmpty {
                    itemImageUrl = url
                }
            }
        }

        if insideItem && elementName == "link" {
            if let href = attributeDict["href"] {
                itemLink = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollectingContentEncoded {
            itemContentEncoded += string
            return
        }

        if !insideItem && parsingChannelTitle && currentElement == "title" {
            channelTitle += string
        }

        guard insideItem else { return }
        switch currentElement {
        case "title": itemTitle += string
        case "description", "summary": itemDescription += string
        case "link": itemLink += string
        case "guid", "id": itemGuid += string
        case "pubDate", "published", "updated": itemPubDate += string
        case "category", "dc:subject": itemCategory += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let str = String(data: CDATABlock, encoding: .utf8) else { return }

        if isCollectingContentEncoded {
            itemContentEncoded += str
        } else if !insideItem && parsingChannelTitle && currentElement == "title" {
            channelTitle += str
        } else if insideItem && currentElement == "description" {
            itemDescription += str
        } else if insideItem && currentElement == "title" {
            itemTitle += str
        } else if insideItem && (currentElement == "guid" || currentElement == "id") {
            itemGuid += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        currentNestingDepth = max(0, currentNestingDepth - 1)

        if elementName == "content:encoded" || (elementName == "content" && isCollectingContentEncoded) {
            isCollectingContentEncoded = false
        }

        if elementName == "item" || elementName == "entry" {
            insideItem = false

            guard articles.count < maxArticlesPerFeed else { return }

            let date = DateParser.parse(itemPubDate)
            let cleanDesc = stripHTMLSimple(itemDescription).trimmingCharacters(in: .whitespacesAndNewlines)

            var fullContent: String? = nil
            let trimmedContent = itemContentEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                fullContent = stripHTMLSimple(trimmedContent)
            }

            var sourceName = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if sourceName.isEmpty || sourceName == "Unknown" {
                sourceName = extractSourceFromURL(itemLink.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if let dashRange = sourceName.range(of: " - ", options: .backwards) {
                let before = sourceName[..<dashRange.lowerBound]
                if before.count > 2 { sourceName = String(before) }
            }
            if let gtRange = sourceName.range(of: " > ") {
                let before = sourceName[..<gtRange.lowerBound]
                if before.count > 2 { sourceName = String(before) }
            }
            if let pipeRange = sourceName.range(of: " | ") {
                let before = sourceName[..<pipeRange.lowerBound]
                if before.count > 2 { sourceName = String(before) }
            }

            if itemImageUrl.isEmpty {
                itemImageUrl = extractImageFromHTML(itemDescription) ?? ""
            }
            if itemImageUrl.isEmpty, fullContent != nil {
                itemImageUrl = extractImageFromHTML(itemContentEncoded) ?? ""
            }

            let guidVal = itemGuid.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanCategory: String? = {
                let first = itemCategory.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                guard let first = first, !first.isEmpty else { return nil }
                return first
            }()
            let article = FeedArticle(
                title: itemTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                link: itemLink.trimmingCharacters(in: .whitespacesAndNewlines),
                guid: guidVal.isEmpty ? nil : guidVal,
                description: cleanDesc,
                pubDate: date,
                source: sourceName.isEmpty ? "Feed" : sourceName,
                imageUrl: itemImageUrl.isEmpty ? nil : itemImageUrl,
                aiSummary: nil,
                fullContent: fullContent,
                category: cleanCategory,
                contentFetched: fullContent != nil
            )
            articles.append(article)
        }
    }

    private func stripHTMLSimple(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?i)</(p|div|blockquote|h[1-6]|li|tr)>",
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?i)<(br|hr)\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8220;", with: "\u{201C}")
            .replacingOccurrences(of: "&#8221;", with: "\u{201D}")
            .replacingOccurrences(of: "&#8212;", with: "\u{2014}")
            .replacingOccurrences(of: "&mdash;", with: "\u{2014}")
            .replacingOccurrences(of: "&#8211;", with: "\u{2013}")
            .replacingOccurrences(of: "&ndash;", with: "\u{2013}")

        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return ArticleContentRedactor.cleanText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func extractImageFromHTML(_ html: String) -> String? {
        let pattern = "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let captureRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[captureRange])
    }
}
