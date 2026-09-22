import Foundation

/// Extracts full article text and lead imagery from remote web pages using
/// the ContentExtractionPipeline with bounded streaming and readability heuristics.
final class WebContentExtractor: Sendable {
    static func fetchFullContentAndImage(for link: String, allowHTTP: Bool = false) async -> (String?, String?) {
        await ContentExtractionPipeline.shared.extractArticle(from: link, allowHTTP: allowHTTP)
    }
}
