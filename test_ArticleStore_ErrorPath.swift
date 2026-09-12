import Foundation

// Need to create a mock that throws
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
        throw NSError(domain: "TestMockError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated mock error"])
    }
}
