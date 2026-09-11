import Foundation

struct FeedArticle: Identifiable, Codable, Hashable, Sendable {
    var id: String { guid ?? normalizedLink }
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
        FeedArticle.normalizeURL(link)
    }

    static func normalizeURL(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return trimmed
        }
        components.host = components.host?.lowercased()
        if components.scheme == "http" {
            components.scheme = "https"
        }
        if let queryItems = components.queryItems {
            let junkParams = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "ref", "rss_source", "feedburner"]
            let cleanedItems = queryItems.filter { item in
                !junkParams.contains { item.name.lowercased().hasPrefix($0) }
            }
            components.queryItems = cleanedItems.isEmpty ? nil : cleanedItems
        }
        var path = components.path
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
            components.path = path
        }
        return components.url?.absoluteString ?? trimmed
    }
}
