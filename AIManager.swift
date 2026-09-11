import Foundation

/// Backwards-compatibility adapter delegating to the modular ArticleIntelligence layer.
final class AIManager: Sendable {
    static let shared = AIManager()

    private let intelligence: ArticleIntelligence

    init(intelligence: ArticleIntelligence = .shared) {
        self.intelligence = intelligence
    }

    func analyzeArticle(title: String, description: String) async -> String {
        await intelligence.analyzeArticle(title: title, description: description)
    }

    func categorizeArticle(title: String, description: String, rssCategory: String?) async -> String? {
        let res = await intelligence.categorizeArticle(title: title, description: description, rssCategory: rssCategory)
        return res?.category
    }

    func cleanExtractedContent(_ rawContent: String) -> String {
        intelligence.cleanContent(rawContent)
    }
}
