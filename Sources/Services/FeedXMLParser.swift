import FeedKit
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
    private var itemDublinDate = ""
    private var itemBaseURL: URL?
    private var itemXML: String?
    private var itemXMLBytes = 0
    private var parsedItemXML: [String?] = []
    private var isAtom = false
    private(set) var parseError: String?
    private var insideItem = false
    private var channelTitle = ""
    private var parsingChannelTitle = false

    private var itemTitle = ""
    private var itemDescription = ""
    private var itemLink = ""
    private var itemGuid = ""
    private var itemGuidIsPermalink = true
    private var itemPubDate = ""
    private var itemImageUrl = ""
    private var itemImageCandidates = [ReaderImageCandidate]()
    private var itemContentIsXHTML = false
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
        guard !Task.isCancelled, data.count <= SecureHTTPClient.defaultFeedLimit else {
            parseError = "Feed exceeds parsing limit or was cancelled"
            return []
        }
        // Reject declarations before Foundation or FeedKit can expand them, including UTF-16/32 prologs.
        let prolog = String(decoding: data.prefix(65_536).filter { $0 != 0 }, as: UTF8.self)
        guard !prolog.contains("<!ENTITY") else {
            parseError = "XML entity declarations are not allowed"
            return []
        }
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
        // Foundation XMLParser is not reentrant; invoke FeedKit only after the guarded parse has finished.
        for index in articles.indices {
            guard !Task.isCancelled else {
                parseError = "Feed parsing cancelled"
                return []
            }
            if let xml = parsedItemXML[index] { articles[index] = applyFeedKitItem(xml, to: articles[index]) }
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
                        category: articles[i].category, contentFetched: articles[i].contentFetched,
                        readerDocument: articles[i].readerDocument
                    )
                }
            }
        }
        guard !Task.isCancelled else {
            parseError = "Feed parsing cancelled"
            return []
        }
        return articles
    }

    private func extractSourceFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        var name =
            host
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

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentNestingDepth += 1
        // A cancelled refresh stops here instead of extracting the rest of the feed.
        if currentNestingDepth > maxNestingDepth || Task.isCancelled {
            parser.abortParsing()
            return
        }

        let elementName = normalizedElement(elementName, namespaceURI: namespaceURI)
        let parentBase = baseURLs.last.flatMap { $0 } ?? URL(string: feedURL)
        baseURLs.append(
            attributeDict["xml:base"].flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase)
        if ["rss", "feed", "RDF"].contains(elementName), currentNestingDepth == 1 {
            recognizedFeed = true
            isAtom = elementName == "feed"
        }
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
            itemGuidIsPermalink = true
            itemPubDate = ""
            itemUpdated = ""
            itemDublinDate = ""
            itemBaseURL = baseURLs.last.flatMap { $0 }
            itemXML = articles.count < maxArticlesPerFeed ? "" : nil
            itemXMLBytes = 0
            contentDepth = nil
            itemContentIsPlainText = false
            isCollectingContentEncoded = false
            itemImageUrl = ""
            itemImageCandidates = []
            itemContentIsXHTML = false
            itemCategory = ""
            itemContentEncoded = ""
        }

        if insideItem {
            let attributes = attributeDict.filter { !$0.key.hasPrefix("xmlns") }.sorted { $0.key < $1.key }.map {
                key, value in
                let value = ["url", "href"].contains(key) ? resolvedURL(value) : value
                return " \(key)=\"\(escapeHTML(value))\""
            }.joined()
            appendItemXML("<\(elementName)\(attributes)>")
        }

        if insideItem && (elementName == "content:encoded" || elementName == "content") && contentDepth == nil {
            isCollectingContentEncoded = true
            itemContentEncoded = ""
            contentDepth = currentNestingDepth
            itemContentIsPlainText = elementName == "content" && (attributeDict["type"] ?? "text") == "text"
            itemContentIsXHTML = elementName == "content" && attributeDict["type"] == "xhtml"
        } else if isCollectingContentEncoded && !itemContentIsPlainText {
            let attributes = attributeDict.sorted { $0.key < $1.key }.map { key, value in
                " \(key)=\"\(escapeHTML(value))\""
            }.joined()
            itemContentEncoded += "<\(elementName)\(attributes)>"
        }

        if insideItem && elementName == "guid" {
            itemGuidIsPermalink = attributeDict["isPermaLink"]?.lowercased() != "false"
        }

        if insideItem && elementName == "category", let term = attributeDict["term"], itemCategory.isEmpty {
            itemCategory = term
        }

        if insideItem && ["enclosure", "media:content", "media:thumbnail"].contains(elementName),
            let raw = attributeDict["url"], !raw.isEmpty
        {
            let type = attributeDict["type"]?.lowercased()
            let medium = attributeDict["medium"]?.lowercased()
            let url = resolvedURL(raw)
            let width = attributeDict["width"].flatMap(Int.init)
            let height = attributeDict["height"].flatMap(Int.init)
            // The Guardian lists sized media:content renditions with neither type nor medium.
            let isImage =
                type?.hasPrefix("image/") == true
                || (type == nil
                    && (elementName == "media:thumbnail" || medium == "image"
                        || (elementName == "media:content" && medium == nil && width != nil)))
            if isImage, ReaderImageCandidate.usable(url: url, width: width, height: height),
                itemImageCandidates.count < 8
            {
                itemImageCandidates.append(ReaderImageCandidate(url: url, origin: .feed, width: width, height: height))
                // The widest rendition; the first listed when sizes are unknown or equal.
                itemImageUrl = itemImageCandidates.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? url
            }
        }

        if insideItem && elementName == "link" {
            let relation = attributeDict["rel"] ?? "alternate"
            if let href = attributeDict["href"], relation == "alternate", itemLink.isEmpty {
                itemLink =
                    URL(string: href, relativeTo: baseURLs.last.flatMap { $0 })?.absoluteURL.absoluteString ?? href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !Task.isCancelled else {
            parser.abortParsing()
            return
        }
        if insideItem { appendItemXML(escapeHTML(string)) }
        if isCollectingContentEncoded {
            itemContentEncoded += itemContentIsXHTML ? escapeHTML(string) : string
            return
        }

        if !insideItem && parsingChannelTitle && currentElement == "title"
            && ["channel", "feed"].contains(elementStack.dropLast().last ?? "")
        {
            channelTitle += string
        }

        guard insideItem else { return }
        if currentElement == "media:credit", !itemImageCandidates.isEmpty {
            let index = itemImageCandidates.count - 1
            itemImageCandidates[index].credit = String(((itemImageCandidates[index].credit ?? "") + string).prefix(500))
            return
        }
        let field =
            elementStack.last(where: {
                [
                    "title", "description", "summary", "link", "guid", "id", "pubDate", "published", "updated",
                    "category", "dc:subject", "dc:date",
                ].contains($0)
            }) ?? currentElement
        switch field {
        case "title": itemTitle += string
        case "description", "summary": itemDescription += string
        case "link": itemLink += string
        case "guid", "id": itemGuid += string
        case "pubDate", "published": itemPubDate += string
        case "updated": itemUpdated += string
        case "dc:date": itemDublinDate += string
        case "category", "dc:subject": itemCategory += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        guard let str = String(data: cdataBlock, encoding: .utf8) else { return }

        self.parser(parser, foundCharacters: str)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName _: String?)
    {
        guard !Task.isCancelled else {
            parser.abortParsing()
            return
        }
        let elementName = normalizedElement(elementName, namespaceURI: namespaceURI)
        if insideItem {
            appendItemXML("</\(elementName)>")
            if elementName == "link", !isCollectingContentEncoded { itemLink = resolvedURL(itemLink) }
        }
        if contentDepth == currentNestingDepth {
            isCollectingContentEncoded = false
            contentDepth = nil
        } else if isCollectingContentEncoded && !itemContentIsPlainText {
            itemContentEncoded += "</\(elementName)>"
        }
        currentNestingDepth = max(0, currentNestingDepth - 1)
        _ = elementStack.popLast()
        _ = baseURLs.popLast()
        currentElement = elementStack.last ?? ""

        if elementName == "item" || elementName == "entry" {
            insideItem = false

            guard articles.count < maxArticlesPerFeed else { return }

            let rawDate = itemPubDate.isEmpty ? (itemUpdated.isEmpty ? itemDublinDate : itemUpdated) : itemPubDate
            let date = DateParser.parse(rawDate) ?? DateParser.unknownDate
            let cleanDesc = stripHTMLSimple(itemDescription).trimmingCharacters(in: .whitespacesAndNewlines)

            var fullContent: String? = nil
            let trimmedContent = itemContentEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some publishers put plain text in content:encoded, with line breaks between paragraphs. HTML extraction would
            // collapse it into one paragraph; the simple cleanup keeps the breaks and still decodes entities.
            let plainText =
                itemContentIsPlainText
                || (!itemContentIsXHTML && !trimmedContent.contains("<") && trimmedContent.contains("\n"))
            if !trimmedContent.isEmpty {
                let cleaned = itemContentIsPlainText ? trimmedContent : stripHTMLSimple(trimmedContent)
                fullContent = cleaned.isEmpty ? nil : cleaned
            }

            var sourceName = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if sourceName.isEmpty || sourceName == "Unknown" {
                sourceName = extractSourceFromURL(itemLink.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            trimSourceName(&sourceName, separator: " - ", options: .backwards)
            trimSourceName(&sourceName, separator: " > ")
            trimSourceName(&sourceName, separator: " | ")

            if itemImageUrl.isEmpty {
                itemImageUrl = extractImageFromHTML(itemDescription) ?? ""
            }
            if itemImageUrl.isEmpty, fullContent != nil {
                itemImageUrl = extractImageFromHTML(itemContentEncoded) ?? ""
            }

            let guidVal = itemGuid.trimmingCharacters(in: .whitespacesAndNewlines)
            var articleLink = itemLink.trimmingCharacters(in: .whitespacesAndNewlines)
            if articleLink.isEmpty, itemGuidIsPermalink,
                let url = URL(string: guidVal),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
            {
                articleLink = guidVal
            }
            let cleanCategory: String? = {
                let first = itemCategory.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                guard let first = first, !first.isEmpty else { return nil }
                return first
            }()
            let extracted =
                plainText
                ? nil
                : ContentExtractionPipeline.shared.extractFromHTML(trimmedContent, baseUrl: resolvedURL(articleLink))
            var document: ReaderDocument?
            if case .success(_, _, let extractedDocument) = extracted { document = extractedDocument }
            if !itemImageCandidates.isEmpty {
                document = ReaderDocument(
                    blocks: document?.blocks ?? [], images: (document?.images ?? []) + itemImageCandidates)
            }
            document = document?.curated(
                feedImage: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl), title: itemTitle)
            let article = FeedArticle(
                title: itemTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                link: resolvedURL(articleLink, baseURL: itemBaseURL),
                guid: guidVal.isEmpty ? nil : guidVal,
                description: cleanDesc,
                pubDate: date,
                source: sourceName.isEmpty ? "Feed" : sourceName,
                imageUrl: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl),
                aiSummary: nil,
                fullContent: extracted?.content ?? fullContent,
                category: cleanCategory,
                contentFetched: fullContent != nil,
                readerDocument: document
            )
            articles.append(article)
            parsedItemXML.append(itemXML)
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName _: String, value _: String?) {
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName _: String, publicID _: String?, systemID _: String?
    ) {
        parser.abortParsing()
    }

    private func appendItemXML(_ value: String) {
        guard itemXML != nil else { return }
        itemXMLBytes += value.utf8.count
        // ponytail: FeedKit handles at most 512 KiB per item; larger entries keep the streaming compatibility path.
        guard itemXMLBytes <= 524_288 else {
            itemXML = nil
            return
        }
        itemXML?.append(value)
    }

    /// The streaming delegate owns depth, entity, item-count, base-URL and cancellation policy. FeedKit only sees
    /// a bounded item with canonical namespace prefixes and no publisher DTD or entity declarations.
    private func applyFeedKitItem(_ itemXML: String, to article: FeedArticle) -> FeedArticle {
        guard !Task.isCancelled else { return article }
        let namespaces =
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:media=\"http://search.yahoo.com/mrss/\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\" xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\""
        let xml =
            isAtom
            ? "<feed xmlns=\"http://www.w3.org/2005/Atom\" \(namespaces)>\(itemXML)</feed>"
            : "<rss version=\"2.0\" \(namespaces)><channel>\(itemXML)</channel></rss>"
        guard case .success(let feed) = FeedKit.FeedParser(data: Data(xml.utf8)).parse(), !Task.isCancelled else {
            return article
        }
        var title = article.title
        var description = article.description
        var category = article.category
        var date = article.pubDate
        let media: FeedKit.MediaNamespace?
        switch feed {
        case .rss(let rss):
            guard let item = rss.items?.first else { return article }
            if title.isEmpty { title = item.title ?? item.dublinCore?.dcTitle ?? "" }
            if description.isEmpty {
                description = stripHTMLSimple(item.description ?? item.dublinCore?.dcDescription ?? "")
            }
            if category == nil { category = item.categories?.first?.value ?? item.dublinCore?.dcSubject }
            if date == DateParser.unknownDate { date = item.pubDate ?? item.dublinCore?.dcDate ?? date }
            media = item.media
        case .atom(let atom):
            guard let item = atom.entries?.first else { return article }
            if title.isEmpty { title = item.title ?? "" }
            if description.isEmpty { description = stripHTMLSimple(item.summary?.value ?? "") }
            if date == DateParser.unknownDate { date = item.published ?? item.updated ?? date }
            media = item.media
        case .json: return article
        }
        var images = article.readerDocument?.images ?? []
        let credit = (media?.mediaCredits ?? media?.mediaGroup?.mediaCredits ?? []).compactMap(\.value).joined(
            separator: ", ")
        let contents = (media?.mediaContents ?? []) + (media?.mediaGroup?.mediaContents ?? [])
        for content in contents {
            guard let attributes = content.attributes, let raw = attributes.url,
                attributes.type?.hasPrefix("image/") == true || attributes.medium == "image"
                    || (attributes.type == nil && attributes.medium == nil && attributes.width != nil)
            else { continue }
            let url = resolvedURL(raw)
            guard ReaderImageCandidate.usable(url: url, width: attributes.width, height: attributes.height),
                !images.contains(where: { $0.url == url }), images.count < 8
            else { continue }
            images.append(
                ReaderImageCandidate(url: url, origin: .feed, width: attributes.width, height: attributes.height))
        }
        if !credit.isEmpty {
            for index in images.indices where images[index].origin == .feed && images[index].credit == nil {
                images[index].credit = String(credit.prefix(500))
            }
        }
        let imageURL = article.imageUrl ?? images.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
        let document =
            article.readerDocument == nil && images.isEmpty
            ? nil
            : ReaderDocument(
                blocks: article.readerDocument?.blocks ?? [], images: images
            ).curated(feedImage: imageURL, title: title)
        return FeedArticle(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: article.link,
            guid: article.guid, description: description, pubDate: date, source: article.source,
            imageUrl: imageURL, fullContent: article.fullContent, category: category,
            contentFetched: article.contentFetched, readerDocument: document)
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func normalizedElement(_ name: String, namespaceURI: String?) -> String {
        switch namespaceURI {
        case "http://purl.org/rss/1.0/modules/content/": return "content:" + name
        case "http://search.yahoo.com/mrss/": return "media:" + name
        case "http://purl.org/dc/elements/1.1/": return "dc:" + name
        default: return name
        }
    }

    private func resolvedURL(_ value: String, baseURL: URL? = nil) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: baseURL ?? baseURLs.last.flatMap { $0 } ?? URL(string: feedURL))?
            .absoluteURL.absoluteString ?? value
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
        // Every named and numeric form, including zero-padded ones such as `&#039;`.
        text = ContentExtractionPipeline.shared.decodeHTMLEntities(text)

        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return ArticleContentRedactor.cleanText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func trimSourceName(_ sourceName: inout String, separator: String, options: String.CompareOptions = []) {
        if let range = sourceName.range(of: separator, options: options) {
            let before = sourceName[..<range.lowerBound]
            if before.count > 2 { sourceName = String(before) }
        }
    }

    private static let imageRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"]", options: .caseInsensitive)
    }()

    private func extractImageFromHTML(_ html: String) -> String? {
        // Avoid repeated compilation of regex per parsed item
        guard let regex = Self.imageRegex else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
            let captureRange = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[captureRange])
    }
}
