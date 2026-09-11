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

    var normalizedLink: String {
        ArticleIdentity.canonicalizeURL(link)
    }

    static func normalizeURL(_ urlString: String) -> String {
        ArticleIdentity.canonicalizeURL(urlString)
    }
}
