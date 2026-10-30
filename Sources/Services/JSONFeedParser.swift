import FeedKit
import Foundation

class JSONFeedParser {
    static func parse(data: Data, feedURL: String) -> [FeedArticle]? {
        guard let bounded = normalizedFeedData(data), let feed = decodeFeed(bounded) else { return nil }
        // Determine source
        var baseSource = "Feed"
        if let urlComponents = URL(string: feedURL), let host = urlComponents.host {
            baseSource = host.replacingOccurrences(of: "www.", with: "")
                .replacingOccurrences(of: "api.", with: "")
        }

        let sourceName = feed.title ?? baseSource
        var articles = [FeedArticle]()
        for item in (feed.items ?? []).prefix(500) {
            guard !Task.isCancelled else { return nil }
            if let article = article(from: item, sourceName: sourceName) { articles.append(article) }
        }
        return Task.isCancelled ? nil : articles
    }

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
            if item["summary"] == nil || item["summary"] is NSNull {
                item["summary"] = FeedXMLParser.stripHTMLSimple(item["description"] as? String ?? "")
            }
            if let rawDate = item["date_published"] as? String {
                if let parsed = DateParser.parse(rawDate) {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    item["date_published"] = formatter.string(from: parsed)
                } else {
                    item.removeValue(forKey: "date_published")
                }
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

    private static func decodeFeed(_ data: Data) -> FeedKit.JSONFeed? {
        try? FeedKit.JSONFeed(data: data)
    }

    private static func article(from item: FeedKit.JSONFeedItem, sourceName: String) -> FeedArticle? {
        // An item without a URL keeps its ID as identity; the ID is its link only when it is a web address (#799).
        let webID = item.id.flatMap {
            ["http", "https"].contains(URL(string: $0)?.scheme?.lowercased() ?? "") ? $0 : nil
        }
        let link = item.url ?? webID ?? ""
        if link.isEmpty && (item.id ?? "").isEmpty { return nil }

        let title = item.title ?? "Untitled"

        let pubDate = item.datePublished ?? DateParser.unknownDate

        let imageUrl = item.image

        var category: String? = nil
        if let tags = item.tags, !tags.isEmpty {
            category = tags.first
        }

        let cleanDesc = item.summary ?? ""
        let cleanContent = item.contentHtml.map(FeedXMLParser.stripHTMLSimple) ?? item.contentText
        let readableContent = cleanContent.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }

        let cleanTitle = ContentExtractionPipeline.shared.decodeHTMLEntities(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        return FeedArticle(
            title: cleanTitle,
            link: link,
            guid: item.id,
            description: cleanDesc,
            pubDate: pubDate,
            source: sourceName,
            imageUrl: imageUrl,
            aiSummary: nil,
            fullContent: extracted?.content ?? readableContent,
            category: category,
            contentFetched: readableContent != nil,
            readerDocument: curatedDoc
        )
    }
}
