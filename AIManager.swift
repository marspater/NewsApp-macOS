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

    func categorizeArticle(title: String, description: String, rssCategory: String?) -> String? {
        // Fast synchronous check or extract category name
        var resultCategory: String?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let res = await intelligence.categorizeArticle(title: title, description: description, rssCategory: rssCategory)
            resultCategory = res?.category
            semaphore.signal()
        }
        semaphore.wait()
        return resultCategory
    }

    func cleanExtractedContent(_ rawContent: String) -> String {
        intelligence.cleanContent(rawContent)
    }
}
