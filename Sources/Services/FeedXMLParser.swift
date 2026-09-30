import Foundation

/// Standalone XML / RSS 2.0 / Atom parser with security guards against
/// recursion bombs, entity expansions, and oversized element nesting.
final class FeedXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let feedURL: String
    private var articles = [FeedArticle]()

    private var currentElement = ""
    private var elementStack: [String] = []
    private var contentDepth: Int?
    private var baseURLs: [URL?] = []
    private var itemContentIsPlainText = false
    private var recognizedFeed = false
    private var itemUpdated = ""
    private(set) var parseError: String?
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
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            parseError = "Malformed XML feed"
            return []
        }

        guard recognizedFeed else {
            parseError = "The XML document is not an RSS or Atom feed"
            return []
        }
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

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        currentNestingDepth += 1
        if currentNestingDepth > maxNestingDepth {
            parser.abortParsing()
            return
        }

        let elementName = normalizedElement(elementName, namespaceURI: namespaceURI)
        let parentBase = baseURLs.last.flatMap { $0 } ?? URL(string: feedURL)
        baseURLs.append(attributeDict["xml:base"].flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase)
        if ["rss", "feed", "RDF"].contains(elementName), currentNestingDepth == 1 { recognizedFeed = true }
        elementStack.append(elementName)
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
            itemUpdated = ""
            contentDepth = nil
            itemContentIsPlainText = false
            isCollectingContentEncoded = false
            itemImageUrl = ""
            itemCategory = ""
            itemContentEncoded = ""
        }

        if insideItem && (elementName == "content:encoded" || elementName == "content") && contentDepth == nil {
            isCollectingContentEncoded = true
            itemContentEncoded = ""
            contentDepth = currentNestingDepth
            itemContentIsPlainText = elementName == "content" && (attributeDict["type"] ?? "text") == "text"
        } else if isCollectingContentEncoded && ["p", "div", "br", "li", "h1", "h2", "blockquote"].contains(elementName) {
            itemContentEncoded += "\n\n"
        }

        if insideItem && elementName == "category", let term = attributeDict["term"], itemCategory.isEmpty {
            itemCategory = term
        }

        if insideItem && (elementName == "enclosure" || elementName == "media:content" || elementName == "media:thumbnail"),
           let url = attributeDict["url"], !url.isEmpty {
            if let type = attributeDict["type"], type.hasPrefix("image") {
                itemImageUrl = url
            } else if itemImageUrl.isEmpty {
                itemImageUrl = url
            }
        }

        if insideItem && elementName == "link" {
            let relation = attributeDict["rel"] ?? "alternate"
            if let href = attributeDict["href"], relation == "alternate", itemLink.isEmpty {
                itemLink = URL(string: href, relativeTo: baseURLs.last.flatMap { $0 })?.absoluteURL.absoluteString ?? href
            }
        }
    }

    func parser(_ _: XMLParser, foundCharacters string: String) {
        if isCollectingContentEncoded {
            itemContentEncoded += string
            return
        }

        if !insideItem && parsingChannelTitle && currentElement == "title" && ["channel", "feed"].contains(elementStack.dropLast().last ?? "") {
            channelTitle += string
        }

        guard insideItem else { return }
        let field = elementStack.last(where: { ["title", "description", "summary", "link", "guid", "id", "pubDate", "published", "updated", "category", "dc:subject"].contains($0) }) ?? currentElement
        switch field {
        case "title": itemTitle += string
        case "description", "summary": itemDescription += string
        case "link": itemLink += string
        case "guid", "id": itemGuid += string
        case "pubDate", "published": itemPubDate += string
        case "updated": itemUpdated += string
        case "category", "dc:subject": itemCategory += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        guard let str = String(data: cdataBlock, encoding: .utf8) else { return }

        self.parser(parser, foundCharacters: str)
    }

    func parser(_ _: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName _: String?) {
        let elementName = normalizedElement(elementName, namespaceURI: namespaceURI)
        if contentDepth == currentNestingDepth {
            isCollectingContentEncoded = false
            contentDepth = nil
        } else if isCollectingContentEncoded && ["p", "div", "li", "blockquote"].contains(elementName) {
            itemContentEncoded += "\n\n"
        }
        currentNestingDepth = max(0, currentNestingDepth - 1)
        _ = elementStack.popLast()
        _ = baseURLs.popLast()
        currentElement = elementStack.last ?? ""

        if elementName == "item" || elementName == "entry" {
            insideItem = false

            guard articles.count < maxArticlesPerFeed else { return }

            let date = DateParser.parse(itemPubDate.isEmpty ? itemUpdated : itemPubDate)
            let cleanDesc = stripHTMLSimple(itemDescription).trimmingCharacters(in: .whitespacesAndNewlines)

            var fullContent: String? = nil
            let trimmedContent = itemContentEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                let cleaned = itemContentIsPlainText ? trimmedContent : stripHTMLSimple(trimmedContent)
                fullContent = cleaned.isEmpty ? nil : cleaned
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
                link: resolvedURL(itemLink),
                guid: guidVal.isEmpty ? nil : guidVal,
                description: cleanDesc,
                pubDate: date,
                source: sourceName.isEmpty ? "Feed" : sourceName,
                imageUrl: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl),
                aiSummary: nil,
                fullContent: fullContent,
                category: cleanCategory,
                contentFetched: fullContent != nil
            )
            articles.append(article)
        }
    }

    private func normalizedElement(_ name: String, namespaceURI: String?) -> String {
        switch namespaceURI {
        case "http://purl.org/rss/1.0/modules/content/": return "content:" + name
        case "http://search.yahoo.com/mrss/": return "media:" + name
        case "http://purl.org/dc/elements/1.1/": return "dc:" + name
        default: return name
        }
    }

    private func resolvedURL(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: URL(string: feedURL))?.absoluteURL.absoluteString ?? value
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
