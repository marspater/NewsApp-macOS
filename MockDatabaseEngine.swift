import Foundation

class MockDatabaseEngine: DatabaseEngine {
    override func updateEnrichment(
        articleId: String,
        summary: String? = nil,
        category: String? = nil,
        sentiment: Double? = nil,
        entities: [String]? = nil,
        topics: [String]? = nil,
        content: String? = nil,
        image: String? = nil
    ) throws {
        throw NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated mock error"])
    }
}
