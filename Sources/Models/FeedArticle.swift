import Foundation

struct FeedArticle: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        ArticleIdentity.computeId(guid: guid, link: link, title: title, source: source, pubDate: pubDate)
    }
    let title: String
    let link: String
    let guid: String?
    let description: String
    let pubDate: Date
    let source: String
    var imageUrl: String?
    var aiSummary: String?
    var fullContent: String?
    var category: String?
    var contentFetched: Bool = false
    var keyPoints: [String]?
    var entities: [EntityResult]?
    var sentimentScore: Double?
    var sentimentLabel: String?

    var normalizedLink: String {
        ArticleIdentity.canonicalizeURL(link)
    }

    static func normalizeURL(_ urlString: String) -> String {
        ArticleIdentity.canonicalizeURL(urlString)
    }
}

/// Navigation wrapper that pairs an active article with its contextual collection
/// (e.g. active filtered search, category, or unread stories).
struct FeedArticleWrap: Identifiable, Hashable, Sendable {
    let id: UUID
    let article: FeedArticle
    let contextArticles: [FeedArticle]
    
    init(article: FeedArticle, contextArticles: [FeedArticle] = []) {
        self.id = UUID()
        self.article = article
        self.contextArticles = contextArticles
    }
}
