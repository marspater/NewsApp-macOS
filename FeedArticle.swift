import Foundation

struct FeedArticle: Identifiable, Codable, Hashable {
    var id: String { link }
    let title: String
    let link: String
    let description: String
    let pubDate: Date
    let source: String
    var imageUrl: String?
}
