import Foundation

struct JSONFeed: Decodable {
    let version: String?
    let title: String?
    let items: [JSONFeedItem]
}

struct JSONFeedItem: Decodable {
    let id: String?
    let url: String?
    let title: String?
    let content_html: String?
    let content_text: String?
    let summary: String?
    let date_published: String?
    let image: String?
    let tags: [String]?
    
    // For RSS-in-JSON compatibility some apis use 'link' or 'pubDate' or 'thumbnail'
    let link: String?
    let pubDate: String?
    let description: String?
    let thumbnail: String?
    let categories: [String]?
}

class JSONFeedParser {
    static func parse(data: Data, feedURL: String) -> [FeedArticle]? {
        let decoder = JSONDecoder()
        
        // Determine source
        var baseSource = "Feed"
        if let urlComponents = URL(string: feedURL), let host = urlComponents.host {
            baseSource = host.replacingOccurrences(of: "www.", with: "")
                .replacingOccurrences(of: "api.", with: "")
        }
        
        // Try parsing strict JSON Feed format first
        if let feed = try? decoder.decode(JSONFeed.self, from: data) {
            let sourceName = feed.title ?? baseSource
            
            var articles = [FeedArticle]()
            for item in feed.items {
                let link = item.url ?? item.link ?? item.id ?? ""
                if link.isEmpty { continue }
                
                let title = item.title ?? "Untitled"
                let desc = item.summary ?? item.description ?? ""
                let content = item.content_html ?? item.content_text
                
                let rawDate = item.date_published ?? item.pubDate ?? ""
                let pubDate = DateParser.parse(rawDate)
                
                let imageUrl = item.image ?? item.thumbnail
                
                var category: String? = nil
                if let tags = item.tags, !tags.isEmpty {
                    category = tags.first
                } else if let cats = item.categories, !cats.isEmpty {
                    category = cats.first
                }
                
                let cleanDesc = stripSimpleHTML(desc)
                let cleanContent = content != nil ? stripSimpleHTML(content!) : nil

                let article = FeedArticle(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    link: link,
                    description: cleanDesc,
                    pubDate: pubDate,
                    source: sourceName,
                    imageUrl: imageUrl,
                    aiSummary: nil,
                    fullContent: cleanContent,
                    category: category,
                    contentFetched: cleanContent != nil && cleanContent!.count > 100
                )
                articles.append(article)
            }
            return articles
        }
        
        return nil
    }
    
    private static func stripSimpleHTML(_ html: String) -> String {
        var str = html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        str = str.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        str = str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")
        ]
        for (entity, replacement) in entities {
            str = str.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
