import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

/// Protocol abstracting local CoreSpotlight indexing for saved stories (#559).
protocol SpotlightIndexing: Sendable {
    func indexSavedArticle(_ article: FeedArticle) async
    func removeSavedArticle(id: String) async
    func removeAllSavedArticles() async
}

/// Local-only CoreSpotlight indexer for saved stories.
/// Indexes title, publisher, summary, and publication date under `"com.marspater.news.saved-stories"`.
struct SystemSpotlightIndexer: SpotlightIndexing, Sendable {
    static let shared = SystemSpotlightIndexer()
    static let domainIdentifier = "com.marspater.news.saved-stories"

    private let logger = Logger(subsystem: "com.marspater.news", category: "SpotlightIndexer")

    static func makeSearchableItem(for article: FeedArticle) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
        attributeSet.title = article.title
        let publisher = article.publisherName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !publisher.isEmpty {
            attributeSet.publishers = [publisher]
        }
        let summaryText = (article.aiSummary ?? article.description).trimmingCharacters(in: .whitespacesAndNewlines)
        attributeSet.contentDescription = summaryText
        if article.pubDate != DateParser.unknownDate {
            attributeSet.contentCreationDate = article.pubDate
        }
        let encodedID =
            article.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? article.id
        attributeSet.contentURL = URL(string: "news://story/\(encodedID)")

        return CSSearchableItem(
            uniqueIdentifier: article.id,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributeSet
        )
    }

    func indexSavedArticle(_ article: FeedArticle) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let item = Self.makeSearchableItem(for: article)
        do {
            try await CSSearchableIndex.default().indexSearchableItems([item])
        } catch {
            logger.error("Failed to index saved story in Spotlight: \(error.localizedDescription)")
        }
    }

    func removeSavedArticle(id: String) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
        } catch {
            logger.error("Failed to remove saved story from Spotlight: \(error.localizedDescription)")
        }
    }

    func removeAllSavedArticles() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
        } catch {
            logger.error("Failed to clear saved stories Spotlight domain: \(error.localizedDescription)")
        }
    }
}

/// Deterministic in-memory Spotlight indexer for unit and E2E testing without mutating the host Mac's Spotlight database.
actor MockSpotlightIndexer: SpotlightIndexing {
    static let domainIdentifier = SystemSpotlightIndexer.domainIdentifier

    private(set) var indexedItems: [String: CSSearchableItem] = [:]
    private(set) var indexCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var removeAllCallCount = 0

    init() {}

    func indexSavedArticle(_ article: FeedArticle) async {
        indexCallCount += 1
        let item = SystemSpotlightIndexer.makeSearchableItem(for: article)
        indexedItems[article.id] = item
    }

    func removeSavedArticle(id: String) async {
        removeCallCount += 1
        indexedItems.removeValue(forKey: id)
    }

    func removeAllSavedArticles() async {
        removeAllCallCount += 1
        indexedItems.removeAll()
    }

    func contains(id: String) -> Bool {
        indexedItems[id] != nil
    }

    func item(for id: String) -> CSSearchableItem? {
        indexedItems[id]
    }

    func getIndexedCount() -> Int {
        indexedItems.count
    }

    func getIndexCallCount() -> Int {
        indexCallCount
    }
}
