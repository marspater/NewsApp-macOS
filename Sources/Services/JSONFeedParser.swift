import FeedKit
import Foundation

class JSONFeedParser {
    /// Parses a JSON Feed 1.0/1.1 payload into normalized `FeedArticle` items.
    /// - Parameters:
    ///   - data: Raw JSON feed payload.
    ///   - feedURL: Subscription URL string for feed identity.
    ///   - baseURL: Effective response URL used to resolve relative links when a feed redirects; defaults to `feedURL`.
    static func parse(data: Data, feedURL: String, baseURL: String? = nil) -> [FeedArticle]? {
        guard let bounded = normalizedFeedData(data), let feed = decodeFeed(bounded) else { return nil }
        let resolutionBase = baseURL ?? feedURL
        // Determine source
        var baseSource = "Feed"
        if let urlComponents = URL(string: resolutionBase) ?? URL(string: feedURL), let host = urlComponents.host {
            baseSource = host.replacingOccurrences(of: "www.", with: "")
                .replacingOccurrences(of: "api.", with: "")
        }

        let rawFeedTitle = (feed.title?.components(separatedBy: .newlines).first ?? feed.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedFeedTitle = ContentExtractionPipeline.shared.decodeHTMLEntities(rawFeedTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = decodedFeedTitle.isEmpty ? baseSource : decodedFeedTitle
        var articles = [FeedArticle]()
        for item in (feed.items ?? []).prefix(500) {
            guard !Task.isCancelled else { return nil }
            if let article = article(from: item, sourceName: sourceName, baseURL: resolutionBase) {
                articles.append(article)
            }
        }
        return Task.isCancelled ? nil : articles
    }

    /// Normalizes legacy JSON Feed aliases and enforces size/item bounds before decoding.
    private static func normalizedFeedData(_ data: Data) -> Data? {
        guard !Task.isCancelled, data.count <= SecureHTTPClient.defaultFeedLimit,
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let items = object["items"] as? [[String: Any]]
        else { return nil }
        var normalized: [[String: Any]] = []
        for var item in items.prefix(500) {
            if Task.isCancelled { return nil }
            // Preserve RSS-in-JSON aliases while FeedKit owns the JSON Feed model.
            for (key, alias) in [
                ("url", "link"), ("date_published", "pubDate"), ("image", "thumbnail"), ("tags", "categories"),
            ] {
                if item[key] == nil || item[key] is NSNull { item[key] = item[alias] }
            }
            if item["id"] == nil || item["id"] is NSNull {
                // Without an id or a URL the item has no identity; a random one would store it again on every refresh.
                guard let url = item["url"], !(url is NSNull) else { continue }
                item["id"] = url
            }
            if (item["tags"] as? [String])?.isEmpty == true { item["tags"] = item["categories"] }
            if (item["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                item["summary"] = FeedXMLParser.stripHTMLSimple(item["description"] as? String ?? "")
            }
            // An item with only a modification date is dated by it, as RSS and Atom fall back to `updated` (#796).
            if let parsed = [item["date_published"], item["date_modified"]].lazy
                .compactMap({ ($0 as? String).flatMap { DateParser.parse($0) } }).first
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                item["date_published"] = formatter.string(from: parsed)
            } else {
                item.removeValue(forKey: "date_published")
            }
            // Unused optional FeedKit fields must not make an otherwise compatible feed fail decoding.
            let fields: Set<String> = [
                "id", "url", "title", "content_html", "content_text", "summary", "date_published", "image", "tags",
            ]
            normalized.append(item.filter { fields.contains($0.key) })
        }
        object = object.filter { ["version", "title"].contains($0.key) }
        if object["version"] == nil {
            object["version"] = "https://jsonfeed.org/version/1.1"
        }
        object["items"] = normalized
        guard let bounded = try? JSONSerialization.data(withJSONObject: object), !Task.isCancelled else { return nil }
        return bounded
    }

    /// Decodes bounded JSON Feed data using FeedKit.
    private static func decodeFeed(_ data: Data) -> FeedKit.JSONFeed? {
        try? FeedKit.JSONFeed(data: data)
    }

    /// Resolves a potentially relative item URL against the effective feed base URL.
    private static func resolvedURL(_ value: String, baseURL: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(string: trimmed, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString ?? trimmed
    }

    /// Converts a decoded JSON Feed item into a `FeedArticle`, resolving relative links and reader content.
    private static func article(from item: FeedKit.JSONFeedItem, sourceName: String, baseURL: String) -> FeedArticle? {
        // An item without a URL keeps its ID as identity; the ID is its link only when it is a web address (#799).
        let webID = item.id.flatMap {
            ["http", "https"].contains(URL(string: $0)?.scheme?.lowercased() ?? "") ? $0 : nil
        }
        let rawLink =
            item.url.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? webID ?? ""
        let link = resolvedURL(rawLink, baseURL: baseURL)
        if link.isEmpty && (item.id ?? "").isEmpty { return nil }

        let cleanTitle = ContentExtractionPipeline.shared.decodeHTMLEntities(item.title ?? "Untitled")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageUrl = item.image.flatMap { raw -> String? in
            let resolved = resolvedURL(raw, baseURL: baseURL)
            return resolved.isEmpty ? nil : resolved
        }
        let category = item.tags?
            .map {
                ContentExtractionPipeline.shared.decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first { !$0.isEmpty }
        let body = extractedBody(from: item, link: link, imageUrl: imageUrl, cleanTitle: cleanTitle)

        return FeedArticle(
            title: cleanTitle,
            link: link,
            guid: item.id,
            description: item.summary ?? "",
            pubDate: item.datePublished ?? DateParser.unknownDate,
            source: sourceName,
            imageUrl: imageUrl,
            aiSummary: nil,
            fullContent: body.fullContent,
            category: category,
            contentFetched: body.contentFetched,
            readerDocument: body.readerDocument
        )
    }

    private struct ExtractedBody {
        let fullContent: String?
        let contentFetched: Bool
        let readerDocument: ReaderDocument?
    }

    /// Extracts full-text reader content and structured blocks from a JSON Feed item's HTML or plain-text body.
    private static func extractedBody(
        from item: FeedKit.JSONFeedItem,
        link: String,
        imageUrl: String?,
        cleanTitle: String
    ) -> ExtractedBody {
        let cleanContent = item.contentHtml.map(FeedXMLParser.stripHTMLSimple) ?? item.contentText
        let readableContent = cleanContent.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let extracted = item.contentHtml.map {
            ContentExtractionPipeline.shared.extractFromHTML($0, baseUrl: link)
        }
        let isTeaser =
            extracted?.document?.hasCompleteArticleBody == false
            || (readableContent?.count ?? 0) < 600
        var doc = extracted?.document
        if doc == nil, item.contentHtml != nil, let readableContent, !readableContent.isEmpty {
            let paras = readableContent.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ReaderBlock(kind: .paragraph, text: $0) }
            if !paras.isEmpty {
                doc = ReaderDocument(
                    version: ReaderDocument.currentVersion,
                    blocks: paras,
                    images: nil,
                    leadImageURL: nil,
                    isComplete: !isTeaser
                )
            }
        }
        if isTeaser { doc?.isComplete = false }
        let curatedDoc = doc?.curated(feedImage: imageUrl, title: cleanTitle)
        return ExtractedBody(
            fullContent: extracted?.content ?? readableContent,
            contentFetched: readableContent != nil,
            readerDocument: curatedDoc
        )
    }
}
