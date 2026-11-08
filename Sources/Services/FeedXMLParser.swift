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

import FeedKit
import Foundation
import SwiftSoup

/// Checks shared by every XML document the app reads from outside: feeds and OPML imports (#928).
enum XMLInputGuard {
    /// Rejects declarations before Foundation or FeedKit can expand them, including UTF-16/32 documents.
    /// Feed parsing keeps its bounded prolog scan; OPML opts into the complete, separately size-bounded input.
    static func declaresEntities(_ data: Data, scanEntireInput: Bool = false) -> Bool {
        let scanLimit = scanEntireInput ? data.count : 65_536
        return Data(data.prefix(scanLimit).filter { $0 != 0 }).range(of: Data("<!ENTITY".utf8)) != nil
    }

    /// Detects DTD attribute-list declarations before Foundation can supply their defaults to parsed elements.
    static func declaresAttributeLists(_ data: Data, scanEntireInput: Bool = false) -> Bool {
        let scanLimit = scanEntireInput ? data.count : 65_536
        return Data(data.prefix(scanLimit).filter { $0 != 0 }).range(of: Data("<!ATTLIST".utf8)) != nil
    }
}

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
    private var itemDescriptionBaseURL: URL?
    private var itemLink = ""
    private var itemGuid = ""
    private var itemGuidIsPermalink = true
    private var itemPubDate = ""
    private var itemImageUrl = ""
    private var itemImageCandidates = [ReaderImageCandidate]()
    private var itemContentIsXHTML = false
    private var itemCategory = ""
    private var itemAuthors = ""
    private var itemContentEncoded = ""
    private var itemContentBaseURL: URL?
    private var isCollectingContentEncoded = false
    private var activeTextField: (depth: Int, field: String)?

    private var currentNestingDepth = 0
    private let maxNestingDepth = 64
    private let maxArticlesPerFeed = 500

    init(data: Data, feedURL: String = "", textEncodingName: String? = nil) {
        if let textEncodingName,
            !Self.hasByteOrderMark(data),
            !Self.declaresEncoding(data),
            let transcoded = Self.transcodeToUTF8(data: data, encodingName: textEncodingName)
        {
            self.data = transcoded
        } else {
            self.data = data
        }
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
        guard !XMLInputGuard.declaresEntities(data) else {
            parseError = "XML entity declarations are not allowed"
            return false
        }
        guard !XMLInputGuard.declaresAttributeLists(data) else {
            parseError = "XML attribute list declarations are not allowed"
            return false
        }
        let repaired = Self.repairXML(data: data)
        guard repaired.count <= SecureHTTPClient.defaultFeedLimit else {
            parseError = "Feed exceeds parsing limit or was cancelled"
            return false
        }
        // Output before the declaration, or anything after the closing root tag, is a server's stray text.
        let parser = XMLParser(data: Data(repaired.drop { [0x20, 0x09, 0x0A, 0x0D].contains($0) }))
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), !(recognizedFeed && currentNestingDepth == 0) {
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
                contentFetched: articles[i].contentFetched, readerDocument: articles[i].readerDocument,
                author: articles[i].author)
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
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentNestingDepth += 1
        // A cancelled refresh stops here instead of extracting the rest of the feed.
        if currentNestingDepth > maxNestingDepth || Task.isCancelled {
            parser.abortParsing()
            return
        }

        let elementName = normalizedElement(elementName, namespaceURI: namespaceURI, qualifiedName: qualifiedName)
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

    /// Processes an opening element inside an RSS `<item>` or Atom `<entry>`, capturing the first non-empty occurrence of each scalar field.
    private func handleItemElement(elementName: String, attributeDict: [String: String]) {
        let attributes = attributeDict.filter(Self.isFeedKitAttribute).sorted { $0.key < $1.key }.map { key, value in
            " \(key)=\"\(escapeHTML(key == "url" ? resolvedURL(value) : value))\""
        }.joined()
        appendItemXML("<\(elementName)\(attributes)>")
        // An Atom entry's <source> describes the feed it was copied from, and a foreign element (vendor:details) is
        // another vocabulary: nothing inside either sets the entry's own fields (#795). Inside XHTML content it is markup.
        if !isCollectingContentEncoded, insideForeignBlock { return }

        if (elementName == "content:encoded" || elementName == "content") && contentDepth == nil {
            isCollectingContentEncoded = true
            itemContentEncoded = ""
            itemContentBaseURL = baseURLs.last.flatMap { $0 }
            contentDepth = currentNestingDepth
            itemContentIsPlainText = elementName == "content" && (attributeDict["type"] ?? "text") == "text"
            itemContentIsXHTML = elementName == "content" && attributeDict["type"] == "xhtml"
        } else if isCollectingContentEncoded && !itemContentIsPlainText {
            let encodedAttrs = attributeDict.sorted { $0.key < $1.key }.map { key, value in
                " \(key)=\"\(escapeHTML(value))\""
            }.joined()
            itemContentEncoded += "<\(elementName)\(encodedAttrs)>"
        }

        if elementName == "guid", itemGuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            itemGuidIsPermalink = attributeDict["isPermaLink"]?.lowercased() != "false"
        }

        if elementName == "category", let term = attributeDict["term"], itemCategory.isEmpty {
            itemCategory = term
        }

        if ["enclosure", "media:content", "media:thumbnail"].contains(elementName) {
            handleMediaElement(elementName: elementName, attributeDict: attributeDict)
        }

        if elementName == "link" {
            if let href = attributeDict["href"] {
                let relation = attributeDict["rel"] ?? "alternate"
                if relation == "alternate", itemLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    itemLink = resolvedURL(href)
                }
            } else if activeTextField == nil, !isCollectingContentEncoded,
                itemLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                itemLink = ""
                activeTextField = (currentNestingDepth, "link")
            }
        } else if activeTextField == nil, !isCollectingContentEncoded,
            let current = itemFieldValue(for: elementName),
            current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            clearItemField(for: elementName)
            activeTextField = (currentNestingDepth, elementName)
        }
    }

    /// The attributes read from FeedKit's model. FeedKit rejects a whole item over one attribute it types as a number
    /// and cannot convert (`length=""`, `width="100%"`, `isDefault="yes"`), so nothing else reaches it.
    private static func isFeedKitAttribute(_ key: String, _ value: String) -> Bool {
        switch key {
        case "url", "type", "medium": return true
        case "width", "height": return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        default: return false
        }
    }

    /// Resets per-item accumulator buffers when entering a new RSS `<item>` or Atom `<entry>`.
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
        itemAuthors = ""
        itemContentEncoded = ""
        activeTextField = nil
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
        if isImage, ReaderImageCandidate.usable(url: url, width: width, height: height, type: type),
            itemImageCandidates.count < 8
        {
            itemImageCandidates.append(ReaderImageCandidate(url: url, origin: .feed, width: width, height: height))
            // The widest rendition; the first listed when sizes are unknown or equal.
            itemImageUrl = itemImageCandidates.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? url
        }
    }

    /// Handles character data inside the active feed channel or item field.
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
        // Text inside an Atom <source> or a foreign element is not the entry's (#795).
        if insideForeignBlock { return }
        if currentElement == "media:credit", !itemImageCandidates.isEmpty {
            let index = itemImageCandidates.count - 1
            itemImageCandidates[index].credit = String(((itemImageCandidates[index].credit ?? "") + string).prefix(500))
            return
        }
        if currentElement == "dc:creator" || currentElement == "author"
            || (currentElement == "name" && elementStack.dropLast().last == "author")
        {
            itemAuthors += string
            return
        }
        if let active = activeTextField {
            appendItemText(string, field: active.field)
            return
        }
        if let field = elementStack.last(where: { ["category", "dc:subject"].contains($0) }) {
            appendItemText(string, field: field)
        }
    }

    /// Returns the currently accumulated value for a single-value item text field, or `nil` if the element is not a tracked scalar field.
    private func itemFieldValue(for field: String) -> String? {
        switch field {
        case "title": return itemTitle
        case "description", "summary": return itemDescription
        case "guid", "id": return itemGuid
        case "pubDate", "published": return itemPubDate
        case "updated": return itemUpdated
        case "dc:date": return itemDublinDate
        default: return nil
        }
    }

    /// Resets the target scalar item text buffer before collecting characters from a newly opened element.
    private func clearItemField(for field: String) {
        switch field {
        case "title": itemTitle = ""
        case "description", "summary":
            itemDescription = ""
            itemDescriptionBaseURL = baseURLs.last.flatMap { $0 }
        case "guid", "id": itemGuid = ""
        case "pubDate", "published": itemPubDate = ""
        case "updated": itemUpdated = ""
        case "dc:date": itemDublinDate = ""
        default: break
        }
    }

    /// Appends character data to the buffer for the specified item text field.
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

    /// Handles closing XML elements, finalizing the active text field or completed article item.
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard !Task.isCancelled else {
            parser.abortParsing()
            return
        }
        let elementName = normalizedElement(elementName, namespaceURI: namespaceURI, qualifiedName: qualifiedName)
        if insideItem {
            appendItemXML("</\(elementName)>")
            // A category inside an Atom <source> or a foreign element must not block the entry's own term.
            if ["category", "dc:subject"].contains(elementName), !isCollectingContentEncoded, !insideForeignBlock {
                itemCategory += "\n"
            }
            if ["dc:creator", "author", "name"].contains(elementName), !isCollectingContentEncoded, !insideForeignBlock
            {
                itemAuthors += "\n"
            }
            if let active = activeTextField, active.depth == currentNestingDepth {
                if active.field == "link" { itemLink = resolvedURL(itemLink) }
                activeTextField = nil
            }
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
        // An unreadable date falls through to the next field instead of leaving the story undated.
        let rawDate = [itemPubDate, itemUpdated, itemDublinDate].first { DateParser.parse($0) != nil } ?? ""
        let guid = itemGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = itemDocumentLink(guid: guid)
        let content = itemContent(articleLink: link)
        if itemImageUrl.isEmpty {
            itemImageUrl = extractImageFromHTML(itemDescription, baseURL: itemDescriptionBaseURL) ?? ""
        }
        if itemImageUrl.isEmpty {
            itemImageUrl = extractImageFromHTML(itemContentEncoded, baseURL: itemContentBaseURL) ?? ""
        }
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
            imageUrl: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl, baseURL: itemBaseURL), aiSummary: nil,
            fullContent: content.extracted?.content ?? content.text, category: category,
            contentFetched: content.text != nil, readerDocument: doc, author: itemAuthorNames())
        articles.append(article)
        parsedItems.append((itemXML, itemBaseURL))
    }

    private func itemAuthorNames() -> String? {
        var seen = Set<String>()
        let names = itemAuthors.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Self.byline(names.joined(separator: ", "))
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
            ? nil
            : ContentExtractionPipeline.shared.extractFromHTML(
                trimmed, baseUrl: resolvedURL(articleLink, baseURL: itemBaseURL))
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
        return doc?.curated(
            feedImage: itemImageUrl.isEmpty ? nil : resolvedURL(itemImageUrl, baseURL: itemBaseURL), title: itemTitle)
    }

    func parser(
        _ parser: XMLParser, foundAttributeDeclarationWithName _: String, forElement _: String,
        type _: String?, defaultValue _: String?
    ) {
        parseError = "XML attribute list declarations are not allowed"
        parser.abortParsing()
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
        // Dates are DateParser's: FeedKit throws on the ones it cannot read and drops the time from others.
        guard itemXML != nil, !["pubDate", "published", "updated", "dc:date"].contains(currentElement) else { return }
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
        let cat = article.category ?? item.categories?.first?.text ?? dc?.subject
        return FeedArticle(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: article.link, guid: article.guid,
            description: desc, pubDate: article.pubDate, source: article.source, imageUrl: article.imageUrl,
            fullContent: article.fullContent, category: cat, contentFetched: article.contentFetched,
            readerDocument: article.readerDocument, author: article.author)
    }

    private func atomArticle(_ item: FeedKit.AtomFeedEntry, keeping article: FeedArticle) -> FeedArticle {
        let rawTitle = article.title.isEmpty ? item.title ?? "" : article.title
        let title = ContentExtractionPipeline.shared.decodeHTMLEntities(rawTitle)
        let desc = article.description.isEmpty ? Self.stripHTMLSimple(item.summary?.text ?? "") : article.description
        return FeedArticle(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), link: article.link, guid: article.guid,
            description: desc, pubDate: article.pubDate, source: article.source, imageUrl: article.imageUrl,
            fullContent: article.fullContent, category: article.category, contentFetched: article.contentFetched,
            readerDocument: article.readerDocument, author: article.author)
    }

    /// A feed's author text, bounded because the field is untrusted and never needs more than a few names.
    static func byline(_ raw: String?) -> String? {
        let text = ContentExtractionPipeline.shared.decodeHTMLEntities(raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
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
            guard
                ReaderImageCandidate.usable(
                    url: url, width: attributes.width, height: attributes.height, type: attributes.type),
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

    /// Inside an Atom entry's <source> or an element of another vocabulary, which never fill the item's fields (#795).
    private var insideForeignBlock: Bool {
        (isAtom && elementStack.contains("source")) || elementStack.contains { $0.hasPrefix("ext:") }
    }

    private func prefixUndeclared(_ name: String, qualifiedName: String?) -> String {
        for prefix in ["media:", "dc:", "content:"] {
            if qualifiedName?.hasPrefix(prefix) == true || name.hasPrefix(prefix) {
                return name.hasPrefix(prefix) ? name : prefix + name
            }
        }
        return name
    }

    private func normalizedElement(_ name: String, namespaceURI: String?, qualifiedName: String? = nil) -> String {
        switch namespaceURI {
        // Publishers also declare these without the trailing slash.
        case "http://purl.org/rss/1.0/modules/content/", "http://purl.org/rss/1.0/modules/content":
            return "content:" + name
        case "http://search.yahoo.com/mrss/", "http://search.yahoo.com/mrss": return "media:" + name
        case "http://purl.org/dc/elements/1.1/", "http://purl.org/dc/elements/1.1": return "dc:" + name
        // RSS 2.0 has no namespace; Atom, RSS 1.0, RDF and XHTML content elements keep their local names.
        case nil, "":
            return prefixUndeclared(name, qualifiedName: qualifiedName)
        case "http://www.w3.org/2005/Atom", "http://purl.org/atom/ns#", "http://purl.org/rss/1.0/",
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

    /// `&#038;` is the longest reference feeds use for one URL byte, so a candidate that fits the 8,192-byte
    /// image URL limit once decoded always passes this bound.
    private static let maxEncodedImageAttributeBytes = 8192 * 6

    /// Regex captures from CDATA markup never met an HTML parser, so they decode here, once, under attribute
    /// rules: `decodeHTMLEntities` would also unwrap `&amp;#38;`, and text rules would eat `&copy=` in a query.
    private static func decodedImageAttribute(_ raw: Substring) -> String? {
        guard raw.utf8.count <= maxEncodedImageAttributeBytes else { return nil }
        let raw = String(raw)
        return (try? SwiftSoup.Parser.unescapeEntities(raw, true)) ?? raw
    }

    private func extractImageFromHTML(_ html: String, baseURL: URL? = nil) -> String? {
        // Avoid repeated compilation of regex per parsed item
        guard let regex = Self.imageRegex else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        // The first picture the feed gate accepts: not vector artwork, a tracking pixel or a site mark.
        return regex.matches(in: html, range: range).lazy
            .compactMap { Range($0.range(at: 1), in: html) }
            .compactMap { Self.decodedImageAttribute(html[$0]) }
            .map { self.resolvedURL($0, baseURL: baseURL) }
            .first { ReaderImageCandidate.usable(url: $0) }
    }

    /// Detects UTF-8 or UTF-16 byte order marks at the beginning of XML data (#1149).
    static func hasByteOrderMark(_ data: Data) -> Bool {
        data.starts(with: [0xEF, 0xBB, 0xBF])
            || data.starts(with: [0xFE, 0xFF])
            || data.starts(with: [0xFF, 0xFE])
    }

    /// Detects whether an XML prolog explicitly specifies an encoding attribute (#1149).
    static func declaresEncoding(_ data: Data) -> Bool {
        let trimmed = data.drop { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
        guard trimmed.starts(with: Data("<?xml".utf8)) else { return false }
        let afterXml = trimmed.dropFirst(5)
        guard let firstByte = afterXml.first, [0x20, 0x09, 0x0A, 0x0D].contains(firstByte) else {
            return false
        }
        let prefix = trimmed.prefix(1024)
        guard let endRange = prefix.range(of: Data("?>".utf8)) else { return false }
        let declData = prefix[..<endRange.upperBound]
        guard
            let declString = String(data: declData, encoding: .ascii)
                ?? String(data: declData, encoding: .isoLatin1)
        else {
            return false
        }
        return declString.range(of: #"\bencoding\s*="#, options: .regularExpression) != nil
    }

    /// Resolves an IANA charset name or encoding alias to a Foundation `String.Encoding` (#1149).
    static func stringEncoding(for name: String) -> String.Encoding? {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        guard !cleaned.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cleaned as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
        return nil
    }

    /// Transcodes XML data from the specified encoding to UTF-8, bounded to `limit` bytes (#1149).
    static func transcodeToUTF8(
        data: Data, encodingName: String, limit: Int64 = SecureHTTPClient.defaultFeedLimit
    ) -> Data? {
        guard data.count <= limit else { return nil }
        guard let encoding = stringEncoding(for: encodingName) else { return nil }
        if encoding == .utf8 { return data }
        guard let string = String(data: data, encoding: encoding) else { return nil }
        guard let utf8Data = string.data(using: .utf8) else { return nil }
        guard utf8Data.count <= limit else { return nil }
        return utf8Data
    }

    // MARK: - Publisher XML Defect Repair (#1148)

    private static let htmlEntityToNumeric: [String: String] = [
        "nbsp": "&#160;", "iexcl": "&#161;", "cent": "&#162;", "pound": "&#163;", "curren": "&#164;", "yen": "&#165;",
        "brvbar": "&#166;", "sect": "&#167;", "uml": "&#168;", "copy": "&#169;", "ordf": "&#170;", "laquo": "&#171;",
        "not": "&#172;", "shy": "&#173;", "reg": "&#174;", "macr": "&#175;", "deg": "&#176;", "plusmn": "&#177;",
        "sup2": "&#178;", "sup3": "&#179;", "acute": "&#180;", "micro": "&#181;", "para": "&#182;", "middot": "&#183;",
        "cedil": "&#184;", "sup1": "&#185;", "ordm": "&#186;", "raquo": "&#187;", "frac14": "&#188;",
        "frac12": "&#189;",
        "frac34": "&#190;", "iquest": "&#191;",
        "Agrave": "&#192;", "Aacute": "&#193;", "Acirc": "&#194;", "Atilde": "&#195;", "Auml": "&#196;",
        "Aring": "&#197;", "AElig": "&#198;",
        "Ccedil": "&#199;", "Egrave": "&#200;", "Eacute": "&#201;", "Ecirc": "&#202;", "Euml": "&#203;",
        "Igrave": "&#204;", "Iacute": "&#205;", "Icirc": "&#206;", "Iuml": "&#207;",
        "ETH": "&#208;", "Ntilde": "&#209;", "Ograve": "&#210;", "Oacute": "&#211;", "Ocirc": "&#212;",
        "Otilde": "&#213;", "Ouml": "&#214;", "Oslash": "&#216;",
        "Ugrave": "&#217;", "Uacute": "&#218;", "Ucirc": "&#219;", "Uuml": "&#220;", "Yacute": "&#221;",
        "THORN": "&#222;", "szlig": "&#223;",
        "agrave": "&#224;", "aacute": "&#225;", "acirc": "&#226;", "atilde": "&#227;", "auml": "&#228;",
        "aring": "&#229;", "aelig": "&#230;",
        "ccedil": "&#231;", "egrave": "&#232;", "eacute": "&#233;", "ecirc": "&#234;", "euml": "&#235;",
        "igrave": "&#236;", "iacute": "&#237;", "icirc": "&#238;", "iuml": "&#239;",
        "eth": "&#240;", "ntilde": "&#241;", "ograve": "&#242;", "oacute": "&#243;", "ocirc": "&#244;",
        "otilde": "&#245;", "ouml": "&#246;", "oslash": "&#248;",
        "ugrave": "&#249;", "uacute": "&#250;", "ucirc": "&#251;", "uuml": "&#252;", "yacute": "&#253;",
        "thorn": "&#254;", "yuml": "&#255;",
        "ndash": "&#8211;", "mdash": "&#8212;", "lsquo": "&#8216;", "rsquo": "&#8217;", "sbquo": "&#8218;",
        "ldquo": "&#8220;", "rdquo": "&#8221;", "bdquo": "&#8222;", "dagger": "&#8224;", "Dagger": "&#8225;",
        "bull": "&#8226;", "hellip": "&#8230;", "permil": "&#8240;", "prime": "&#8242;", "Prime": "&#8243;",
        "lsaquo": "&#8249;", "rsaquo": "&#8250;", "euro": "&#8364;", "trade": "&#8482;",
        "larr": "&#8592;", "uarr": "&#8593;", "rarr": "&#8594;", "darr": "&#8595;", "harr": "&#8596;",
        "crarr": "&#8629;", "infin": "&#8734;", "asymp": "&#8776;", "ne": "&#8800;", "le": "&#8804;", "ge": "&#8805;",
        "times": "&#215;", "divide": "&#247;",
    ]

    /// Extracts the encoding declared in an XML prolog, if present (#1148).
    static func declaredEncoding(in data: Data) -> String.Encoding? {
        let trimmed = data.drop { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
        guard trimmed.starts(with: Data("<?xml".utf8)) else { return nil }
        let prefix = trimmed.prefix(1024)
        guard let endRange = prefix.range(of: Data("?>".utf8)) else { return nil }
        let declData = prefix[..<endRange.upperBound]
        guard
            let declString = String(data: declData, encoding: .ascii)
                ?? String(data: declData, encoding: .isoLatin1)
        else {
            return nil
        }
        guard
            let match = declString.range(
                of: #"(?i)\bencoding\s*=\s*['"]([^'"]+)['"]"#, options: .regularExpression)
        else {
            return nil
        }
        let matchedStr = declString[match]
        guard let eqIndex = matchedStr.firstIndex(of: "=") else { return nil }
        let encName = matchedStr[matchedStr.index(after: eqIndex)...].trimmingCharacters(
            in: CharacterSet(charactersIn: "\"' \t"))
        return stringEncoding(for: encName)
    }

    static func detectBOMEncoding(in data: Data) -> String.Encoding? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        return nil
    }

    private static func nextSpecialBlock(
        data: Data, currentIndex: Data.Index,
        nextCData: inout Range<Data.Index>?, nextComment: inout Range<Data.Index>?
    ) -> (range: Range<Data.Index>, isCData: Bool)? {
        let cdataStart = Data("<![CDATA[".utf8)
        let commentStart = Data("<!--".utf8)
        if let range = nextCData, range.lowerBound < currentIndex {
            nextCData = data[currentIndex...].range(of: cdataStart)
        }
        if let range = nextComment, range.lowerBound < currentIndex {
            nextComment = data[currentIndex...].range(of: commentStart)
        }
        switch (nextCData, nextComment) {
        case (.some(let cd), .some(let cm)):
            return cd.lowerBound <= cm.lowerBound ? (cd, true) : (cm, false)
        case (.some(let cd), .none):
            return (cd, true)
        case (.none, .some(let cm)):
            return (cm, false)
        case (.none, .none):
            return nil
        }
    }

    /// Repairs publisher XML defects (bare ampersands, common HTML entities, invalid control characters,
    /// invalid UTF-8 bytes) outside CDATA sections and comments (#1148).
    static func repairXML(data: Data) -> Data {
        if let bom = detectBOMEncoding(in: data), bom != .utf8 {
            if let decoded = String(bytes: data, encoding: bom) {
                let repaired = repairXML(data: Data(decoded.utf8))
                return String(decoding: repaired, as: UTF8.self).data(using: bom) ?? data
            }
        }
        let cdataStart = Data("<![CDATA[".utf8)
        let commentStart = Data("<!--".utf8)
        let cdataEnd = Data("]]>".utf8)
        let commentEnd = Data("-->".utf8)

        var result = Data()
        result.reserveCapacity(data.count + 128)
        let encoding = declaredEncoding(in: data) ?? .utf8
        var currentIndex = data.startIndex
        var nextCData = data.range(of: cdataStart)
        var nextComment = data.range(of: commentStart)

        while currentIndex < data.endIndex {
            guard
                let (specialRange, isCData) = nextSpecialBlock(
                    data: data, currentIndex: currentIndex,
                    nextCData: &nextCData, nextComment: &nextComment
                )
            else {
                let outsideData = data[currentIndex...]
                if !outsideData.isEmpty {
                    result.append(contentsOf: sanitizeOutside(outsideData, encoding: encoding))
                }
                break
            }

            let outsideData = data[currentIndex..<specialRange.lowerBound]
            if !outsideData.isEmpty {
                result.append(contentsOf: sanitizeOutside(outsideData, encoding: encoding))
            }
            let closeMarker = isCData ? cdataEnd : commentEnd
            let searchStart = specialRange.upperBound
            if let closeRange = data[searchStart...].range(of: closeMarker) {
                result.append(data[specialRange.lowerBound..<closeRange.upperBound])
                currentIndex = closeRange.upperBound
            } else {
                result.append(data[specialRange.lowerBound...])
                break
            }
        }
        return result
    }

    private static func isValidNumericEntity(_ content: Substring) -> Bool {
        guard content.hasPrefix("#") else { return false }
        let body = content.dropFirst()
        let isHex = body.hasPrefix("x")
        let digits = isHex ? body.dropFirst() : body
        guard !digits.isEmpty,
            digits.utf8.allSatisfy({
                ($0 >= 0x30 && $0 <= 0x39) || (isHex && (($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x66))
            }),
            let value = UInt32(digits, radix: isHex ? 16 : 10)
        else { return false }
        switch value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    private static func stripInvalidXMLControlChars(_ text: String) -> String {
        var stripped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let val = scalar.value
            let isDisallowed =
                (val <= 0x08) || (val >= 0x0B && val <= 0x0C) || (val >= 0x0E && val <= 0x1F) || (val == 0x7F)
            if !isDisallowed {
                stripped.append(scalar)
            }
        }
        return String(stripped)
    }

    private static func repairAmpersands(in cleaned: String) -> String {
        var result = ""
        result.reserveCapacity(cleaned.count + 16)
        var idx = cleaned.startIndex

        while idx < cleaned.endIndex {
            guard cleaned[idx] == "&" else {
                result.append(cleaned[idx])
                idx = cleaned.index(after: idx)
                continue
            }

            let nextIdx = cleaned.index(after: idx)
            var semicolonIdx: String.Index? = nil
            var searchIdx = nextIdx
            var count = 0
            while searchIdx < cleaned.endIndex && count < 32 {
                let c = cleaned[searchIdx]
                if c == ";" {
                    semicolonIdx = searchIdx
                    break
                }
                if c.isWhitespace || c == "<" || c == ">" || c == "&" || c == "\"" || c == "'" {
                    break
                }
                searchIdx = cleaned.index(after: searchIdx)
                count += 1
            }

            if let semi = semicolonIdx {
                let entity = String(cleaned[nextIdx..<semi])
                if ["amp", "lt", "gt", "quot", "apos"].contains(entity) {
                    result.append("&")
                    result.append(contentsOf: cleaned[nextIdx...semi])
                    idx = cleaned.index(after: semi)
                } else if isValidNumericEntity(cleaned[nextIdx..<semi]) {
                    result.append("&")
                    result.append(contentsOf: cleaned[nextIdx...semi])
                    idx = cleaned.index(after: semi)
                } else if let numeric = htmlEntityToNumeric[entity] {
                    result.append(numeric)
                    idx = cleaned.index(after: semi)
                } else {
                    result.append("&amp;")
                    idx = nextIdx
                }
            } else {
                result.append("&amp;")
                idx = nextIdx
            }
        }
        return result
    }

    private static func sanitizeOutside(_ data: Data, encoding: String.Encoding) -> Data {
        let text: String
        if encoding == .utf8 {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = String(bytes: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        }
        let cleaned = stripInvalidXMLControlChars(text)
        let repaired = repairAmpersands(in: cleaned)
        return repaired.data(using: encoding) ?? Data(repaired.utf8)
    }
}
