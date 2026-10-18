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
            if (item["tags"] as? [String])?.isEmpty == true { item["tags"] = item["categories"] }
            if item["summary"] == nil || item["summary"] is NSNull {
                item["summary"] = stripSimpleHTML(item["description"] as? String ?? "")
            }
            // Unused optional FeedKit fields must not make an otherwise compatible feed fail decoding.
            let fields: Set<String> = [
                "id", "url", "title", "content_html", "content_text", "summary", "date_published", "image", "tags",
            ]
            normalized.append(item.filter { fields.contains($0.key) })
        }
        object = object.filter { ["version", "title"].contains($0.key) }
        object["items"] = normalized
        guard let bounded = try? JSONSerialization.data(withJSONObject: object), !Task.isCancelled else { return nil }
        return bounded
    }

    private static func decodeFeed(_ data: Data) -> FeedKit.JSONFeed? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            return DateParser.parse(raw) ?? DateParser.unknownDate
        }
        return try? decoder.decode(FeedKit.JSONFeed.self, from: data)
    }

    private static func article(from item: FeedKit.JSONFeedItem, sourceName: String) -> FeedArticle? {
        let link = item.url ?? item.id ?? ""
        if link.isEmpty { return nil }

        let title = item.title ?? "Untitled"

        let pubDate = item.datePublished ?? DateParser.unknownDate

        let imageUrl = item.image

        var category: String? = nil
        if let tags = item.tags, !tags.isEmpty {
            category = tags.first
        }

        let cleanDesc = item.summary ?? ""
        let cleanContent = item.contentHtml.map(stripSimpleHTML) ?? item.contentText
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

    private static func stripSimpleHTML(_ html: String) -> String {
        var str = html.replacingOccurrences(
            of: "(?i)</(p|div|blockquote|h[1-6]|li|tr)>", with: "\n\n", options: .regularExpression)
        str = str.replacingOccurrences(of: "(?i)<(br|hr)\\s*/?>", with: "\n", options: .regularExpression)
        str = str.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#8217;", "\u{2019}"),
            ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}"), ("&#8212;", "\u{2014}"),
            ("&mdash;", "\u{2014}"), ("&#8211;", "\u{2013}"), ("&ndash;", "\u{2013}"),
        ]
        for (entity, replacement) in entities {
            str = str.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        str = str.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        str = str.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return ArticleContentRedactor.cleanText(str.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
