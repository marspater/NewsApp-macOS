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
    private var parsedItems: [(xml: String?, baseURL: URL?)] = []
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
        guard parseGuardedXML(), enrichParsedItems() else { return [] }
        normalizeArticleSources()
        guard !Task.isCancelled else {
            parseError = "Feed parsing cancelled"
            return []
        }
        return articles
    }

    private func parseGuardedXML() -> Bool {
        guard !Task.isCancelled, data.count <= SecureHTTPClient.defaultFeedLimit else {
            parseError = "Feed exceeds parsing limit or was cancelled"
            return false
        }
        // Reject declarations before Foundation or FeedKit can expand them, including UTF-16/32 prologs.
        let prolog = Data(data.prefix(65_536).filter { $0 != 0 })
        guard prolog.range(of: Data("<!ENTITY".utf8)) == nil else {
            parseError = "XML entity declarations are not allowed"
            return false
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            parseError = "Malformed XML feed"
            return false
        }

        guard recognizedFeed else {
            parseError = "The XML document is not an RSS or Atom feed"
            return false
        }
        return true
    }

    private func enrichParsedItems() -> Bool {
        // Foundation XMLParser is not reentrant; invoke FeedKit only after the guarded parse has finished.
        for index in articles.indices {
            guard !Task.isCancelled else {
                parseError = "Feed parsing cancelled"
                return false
            }
            if let xml = parsedItems[index].xml {
                articles[index] = applyFeedKitItem(xml, baseURL: parsedItems[index].baseURL, to: articles[index])
            }
        }
        return true
    }

    private func normalizeArticleSources() {
        if channelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            channelTitle = extractSourceFromURL(feedURL)
        }
        let name = (channelTitle.components(separatedBy: .newlines).first ?? channelTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for i in articles.indices {
            let src = articles[i].source
            guard src.isEmpty || src == "Feed" || src == "Unknown" else { continue }
            articles[i] = FeedArticle(
                title: articles[i].title, link: articles[i].link, guid: articles[i].guid,
                description: articles[i].description, pubDate: articles[i].pubDate, source: name,
                imageUrl: articles[i].imageUrl, aiSummary: articles[i].aiSummary,
                fullContent: articles[i].fullContent, category: articles[i].category,
                contentFetched: articles[i].contentFetched, readerDocument: articles[i].readerDocument)
        }
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
            resetItemState()
        }

        if insideItem {
            handleItemElement(elementName: elementName, attributeDict: attributeDict)
        }
    }

    private func handleItemElement(elementName: String, attributeDict: [String: String]) {
        let attributes = attributeDict.filter { !$0.key.hasPrefix("xmlns") }.sorted { $0.key < $1.key }.map {
            key, value in
            let value = ["url", "href"].contains(key) ? resolvedURL(value) : value
            return " \(key)=\"\(escapeHTML(value))\""
        }.joined()
        appendItemXML("<\(elementName)\(attributes)>")
        // An Atom entry's <source> describes the feed it was copied from: none of its elements (link, content,
        // category, media) set the entry's own fields (#795). A <source> inside XHTML content is markup.
        if isAtom, !isCollectingContentEncoded, elementStack.contains("source") { return }

        if (elementName == "content:encoded" || elementName == "content") && contentDepth == nil {
            isCollectingContentEncoded = true
            itemContentEncoded = ""
            contentDepth = currentNestingDepth
            itemContentIsPlainText = elementName == "content" && (attributeDict["type"] ?? "text") == "text"
            itemContentIsXHTML = elementName == "content" && attributeDict["type"] == "xhtml"
        } else if isCollectingContentEncoded && !itemContentIsPlainText {
            let encodedAttrs = attributeDict.sorted { $0.key < $1.key }.map { key, value in
                " \(key)=\"\(escapeHTML(value))\""
            }.joined()
            itemContentEncoded += "<\(elementName)\(encodedAttrs)>"
        }

        if elementName == "guid" {
            itemGuidIsPermalink = attributeDict["isPermaLink"]?.lowercased() != "false"
        }

        if elementName == "category", let term = attributeDict["term"], itemCategory.isEmpty {
            itemCategory = term
        }

        if ["enclosure", "media:content", "media:thumbnail"].contains(elementName) {
            handleMediaElement(elementName: elementName, attributeDict: attributeDict)
        }

        if elementName == "link" {
            let relation = attributeDict["rel"] ?? "alternate"
            if let href = attributeDict["href"], relation == "alternate", itemLink.isEmpty {
                itemLink =
                    URL(string: href, relativeTo: baseURLs.last.flatMap { $0 })?.absoluteURL.absoluteString ?? href
            }
        }
    }

    private func resetItemState() {
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

    private func handleMediaElement(elementName: String, attributeDict: [String: String]) {
        guard let raw = attributeDict["url"], !raw.isEmpty else { return }
        let type = attributeDict["type"]?.lowercased()
        let medium = attributeDict["medium"]?.lowercased()
        let url = resolvedURL(raw)
        let width = attributeDict["width"].flatMap(Int.init)
        let height = attributeDict["height"].flatMap(Int.init)
        // The Guardian lists sized media:content renditions with neither type nor medium.
        let isImageExtension = ["jpg", "jpeg", "png", "webp", "avif", "gif"].contains(
            URL(string: raw)?.pathExtension.lowercased() ?? "")
        let isImage =
            type?.hasPrefix("image/") == true
            || (type == nil
                && (elementName == "media:thumbnail" || medium == "image"
                    || (elementName == "media:content" && (medium == nil || medium == "image")
                        && (width != nil || isImageExtension))
                    || isImageExtension))
        if isImage, ReaderImageCandidate.usable(url: url, width: width, height: height),
            itemImageCandidates.count < 8
        {
            itemImageCandidates.append(ReaderImageCandidate(url: url, origin: .feed, width: width, height: height))
            // The widest rendition; the first listed when sizes are unknown or equal.
            itemImageUrl = itemImageCandidates.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? url
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
        // An Atom entry's <source> describes the feed it was copied from; its title is not the entry's (#795).
        if isAtom, elementStack.contains("source") { return }
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
        appendItemText(string, field: field)
    }

    private func appendItemText(_ string: String, field: String) {
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
            // A category inside an Atom <source> is the origin feed's; it must not block the entry's own term.
            if ["category", "dc:subject"].contains(elementName), !isCollectingContentEncoded,
                !(isAtom && elementStack.contains("source"))
            {
                itemCategory += "\n"
            }
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

        if elementName == "title" && !insideItem {
            parsingChannelTitle = false
        }

        if elementName == "item" || elementName == "entry" {
            insideItem = false

            guard articles.count < maxArticlesPerFeed else { return }

            finishArticle()
        }
    }

    private func finishArticle() {
        let fallbackDate = itemUpdated.isEmpty ? itemDublinDate : itemUpdated
        let rawDate = itemPubDate.isEmpty ? fallbackDate : itemPubDate
        let guid = itemGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = itemDocumentLink(guid: guid)
        let content = itemContent(articleLink: link)
        if itemImageUrl.isEmpty { itemImageUrl = extractImageFromHTML(itemDescription) ?? "" }
        if itemImageUrl.isEmpty { itemImageUrl = extractImageFromHTML(itemContentEncoded) ?? "" }
        let category = itemCategory.components(separatedBy: .newlines)
            .map {
                ContentExtractionPipeline.shared.decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first { !$0.isEmpty }
        let decodedTitle = ContentExtractionPipeline.shared.decodeHTMLEntities(itemTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = itemReaderDocument(
            from: content.extracted, cleaned: content.text, isTeaser: content.isTeaser, isPlainText: content.isPlainText
        )
        let article = FeedArticle(
            title: decodedTitle,
            link: resolvedURL(link, baseURL: itemBaseURL), guid: guid.isEmpty ? nil : guid,
            description: Self.stripHTMLSimple(itemDescription).trimmingCharacters(in: .whitespacesAndNewlines),
            pubDate: DateParser.parse(rawDate) ?? DateParser.unknownDate, source: itemSourceName(),
            imageUrl: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl), aiSummary: nil,
            fullContent: content.extracted?.content ?? content.text, category: category,
            contentFetched: content.text != nil, readerDocument: doc)
        articles.append(article)
        parsedItems.append((itemXML, itemBaseURL))
    }

    private func itemDocumentLink(guid: String) -> String {
        let link = itemLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.isEmpty, itemGuidIsPermalink, let url = URL(string: guid),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else { return link }
        return guid
    }

    private func itemSourceName() -> String {
        var source = (channelTitle.components(separatedBy: .newlines).first ?? channelTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty || source == "Unknown" {
            source = extractSourceFromURL(itemLink.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for (sep, backwards) in [(" - ", true), (" > ", false), (" | ", false)] {
            trimSourceName(&source, separator: sep, options: backwards ? .backwards : [])
        }
        return source.isEmpty ? "Feed" : source
    }

    private struct ItemContent {
        let text: String?
        let extracted: ExtractionOutcome?
        let isTeaser: Bool
        let isPlainText: Bool
    }

    private func itemContent(articleLink: String) -> ItemContent {
        let trimmed = itemContentEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainText =
            itemContentIsPlainText || (!itemContentIsXHTML && !trimmed.contains("<") && trimmed.contains("\n"))
        let content: String?
        if trimmed.isEmpty {
            content = nil
        } else if itemContentIsPlainText {
            content = trimmed
        } else {
            content = Self.stripHTMLSimple(trimmed)
        }
        let cleaned = content?.isEmpty == true ? nil : content
        let extracted =
            plainText
            ? nil : ContentExtractionPipeline.shared.extractFromHTML(trimmed, baseUrl: resolvedURL(articleLink))
        let isTeaser = extracted?.document?.hasCompleteArticleBody == false || (cleaned?.count ?? 0) < 600
        return ItemContent(text: cleaned, extracted: extracted, isTeaser: isTeaser, isPlainText: plainText)
    }

    private func itemReaderDocument(
        from extracted: ExtractionOutcome?, cleaned: String?, isTeaser: Bool, isPlainText: Bool
    ) -> ReaderDocument? {
        guard !isPlainText else { return nil }
        var doc: ReaderDocument? = if case .success(_, _, let d) = extracted { d } else { nil }
        if doc == nil, let cleaned, !cleaned.isEmpty {
            let paras = cleaned.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ReaderBlock(kind: .paragraph, text: $0) }
            if !paras.isEmpty {
                doc = ReaderDocument(
                    version: ReaderDocument.currentVersion,
                    blocks: paras,
                    images: itemImageCandidates.isEmpty ? nil : itemImageCandidates,
                    leadImageURL: nil,
                    isComplete: !isTeaser
                )
            }
        }
        if isTeaser {
            doc?.isComplete = false
        }
        if !itemImageCandidates.isEmpty {
            doc = ReaderDocument(
                version: doc?.version ?? ReaderDocument.currentVersion,
                blocks: doc?.blocks ?? [],
                images: (doc?.images ?? []) + itemImageCandidates,
                leadImageURL: doc?.leadImageURL,
                isComplete: doc?.isComplete
            )
        }
        return doc?.curated(feedImage: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl), title: itemTitle)
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
    private func applyFeedKitItem(_ itemXML: String, baseURL: URL?, to article: FeedArticle) -> FeedArticle {
        guard !Task.isCancelled else { return article }
        let namespaces =
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:media=\"http://search.yahoo.com/mrss/\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\" xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" xmlns:ext=\"urn:x-news:foreign\""
        let xml =
            isAtom
            ? "<feed xmlns=\"http://www.w3.org/2005/Atom\" \(namespaces)>\(itemXML)</feed>"
            : "<rss version=\"2.0\" \(namespaces)><channel>\(itemXML)</channel></rss>"
        if isAtom {
            guard let atom = try? FeedKit.AtomFeed(data: Data(xml.utf8)), !Task.isCancelled,
                let item = atom.entries?.first
            else {
                return article
            }
            return applyFeedKitMedia(item.media, baseURL: baseURL, to: atomArticle(item, keeping: article))
        } else {
            guard let rss = try? FeedKit.RSSFeed(data: Data(xml.utf8)), !Task.isCancelled,
                let item = rss.channel?.items?.first
            else {
                return article
            }
            return applyFeedKitMedia(item.media, baseURL: baseURL, to: rssArticle(item, keeping: article))
        }
    }

    private func rssArticle(_ item: FeedKit.RSSFeedItem, keeping article: FeedArticle) -> FeedArticle {
        let dc = item.dublinCore
        let rawTitle = article.title.isEmpty ? item.title ?? dc?.title ?? "" : article.title
        let title = ContentExtractionPipeline.shared.decodeHTMLEntities(rawTitle)
        let desc =
            article.description.isEmpty
            ? Self.stripHTMLSimple(item.description ?? dc?.description ?? "") : article.description
        let date =
            article.pubDate == DateParser.unknownDate ? item.pubDate ?? dc?.date ?? article.pubDate : article.pubDate
        let cat = article.category ?? item.categories?.first?.text ?? dc?.subject
        return FeedArticle(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: article.link, guid: article.guid,
            description: desc, pubDate: date, source: article.source, imageUrl: article.imageUrl,
            fullContent: article.fullContent, category: cat, contentFetched: article.contentFetched,
            readerDocument: article.readerDocument)
    }

    private func atomArticle(_ item: FeedKit.AtomFeedEntry, keeping article: FeedArticle) -> FeedArticle {
        let rawTitle = article.title.isEmpty ? item.title ?? "" : article.title
        let title = ContentExtractionPipeline.shared.decodeHTMLEntities(rawTitle)
        let desc = article.description.isEmpty ? Self.stripHTMLSimple(item.summary?.text ?? "") : article.description
        let date =
            article.pubDate == DateParser.unknownDate
            ? item.published ?? item.updated ?? article.pubDate : article.pubDate
        return FeedArticle(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: article.link, guid: article.guid,
            description: desc, pubDate: date, source: article.source, imageUrl: article.imageUrl,
            fullContent: article.fullContent, category: article.category, contentFetched: article.contentFetched,
            readerDocument: article.readerDocument)
    }

    private func applyFeedKitMedia(_ media: FeedKit.Media?, baseURL: URL?, to article: FeedArticle)
        -> FeedArticle
    {
        var images = article.readerDocument?.images ?? []
        let credit = (media?.credits ?? media?.group?.credits ?? []).compactMap(\.text).joined(
            separator: ", ")
        let contents = (media?.contents ?? []) + (media?.group?.contents ?? [])
        for content in contents {
            guard let attributes = content.attributes, let raw = attributes.url,
                attributes.type?.hasPrefix("image/") == true || attributes.medium == "image"
                    || (attributes.type == nil && attributes.medium == nil && attributes.width != nil)
            else { continue }
            let url = resolvedURL(raw, baseURL: baseURL)
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
        var result = article
        result.imageUrl = imageURL
        if article.readerDocument != nil || !images.isEmpty {
            result.readerDocument = ReaderDocument(
                version: article.readerDocument?.version ?? ReaderDocument.currentVersion,
                blocks: article.readerDocument?.blocks ?? [],
                images: images,
                leadImageURL: article.readerDocument?.leadImageURL,
                isComplete: article.readerDocument?.isComplete
            ).curated(feedImage: imageURL, title: article.title)
        }
        return result
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
        // RSS 2.0 has no namespace; Atom, RSS 1.0, RDF and XHTML content elements keep their local names.
        case nil, "", "http://www.w3.org/2005/Atom", "http://purl.org/atom/ns#", "http://purl.org/rss/1.0/",
            "http://my.netscape.com/rdf/simple/0.9/", "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
            "http://www.w3.org/1999/xhtml":
            return name
        // Any other vocabulary (itunes:title, googleplay:description) never stands in for the item's own fields (#795).
        default: return "ext:" + name
        }
    }

    private func resolvedURL(_ value: String, baseURL: URL? = nil) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: baseURL ?? baseURLs.last.flatMap { $0 } ?? URL(string: feedURL))?
            .absoluteURL.absoluteString ?? value
    }

    static func stripHTMLSimple(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?i)</(p|div|blockquote|h[1-6]|li|tr)>", with: "\n\n", options: .regularExpression
        )
        .replacingOccurrences(of: "(?i)<(br|hr)\\s*/?>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = ContentExtractionPipeline.shared.decodeHTMLEntities(text)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return ArticleContentRedactor.cleanText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func trimSourceName(_ sourceName: inout String, separator: String, options: String.CompareOptions = []) {
        if let range = sourceName.range(of: separator, options: options) {
            let before = sourceName[..<range.lowerBound]
            if before.count > 2 { sourceName = String(before) }
        }
    }

    private static let imageRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<img[^>]+(?:src|data-src|data-original)\\s*=\\s*['\"]([^'\"]+)['\"]",
            options: .caseInsensitive)
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
