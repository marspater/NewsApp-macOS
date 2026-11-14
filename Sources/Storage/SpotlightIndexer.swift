// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

/// Protocol abstracting local CoreSpotlight indexing for saved stories (#559).
protocol SpotlightIndexing: Sendable {
    /// Adds or replaces a saved story's item in the index; never throws, so a failure leaves the library change in
    /// place.
    func indexSavedArticle(_ article: FeedArticle) async
    /// Removes one story's item from the index.
    func removeSavedArticle(id: String) async
    /// Removes every item in the saved-stories domain, leaving other domains alone.
    func removeAllSavedArticles() async
}

/// Local-only CoreSpotlight indexer for saved stories.
/// Indexes title, publisher, publisher description, and publication date under `"com.marspater.news.saved-stories"`.
struct SystemSpotlightIndexer: SpotlightIndexing, Sendable {
    /// The indexer over `CSSearchableIndex.default()`.
    static let shared = SystemSpotlightIndexer()
    /// The Spotlight domain that holds every saved-story item.
    static let domainIdentifier = "com.marspater.news.saved-stories"

    private let logger = Logger(subsystem: "com.marspater.news", category: "SpotlightIndexer")

    /// Creates a `CSSearchableItem` for a saved article with a single-percent-encoded `news://story/<id>` deep link.
    static func makeSearchableItem(for article: FeedArticle) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
        attributeSet.title = article.title
        let publisher = article.publisherName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !publisher.isEmpty {
            attributeSet.publishers = [publisher]
        }
        // The publisher's description only: generated summaries stay out of the system index, so Clear AI Analysis
        // has nothing to leave behind in Spotlight (#983).
        attributeSet.contentDescription = article.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if article.pubDate != DateParser.unknownDate {
            attributeSet.contentCreationDate = article.pubDate
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encodedID =
            article.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? article.id
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

    /// The indexed stories; their Spotlight items are built on request, so none leaves this actor shared.
    private var indexed: [String: FeedArticle] = [:]
    private(set) var indexCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var removeAllCallCount = 0

    init() {}

    func indexSavedArticle(_ article: FeedArticle) async {
        indexCallCount += 1
        indexed[article.id] = article
    }

    func removeSavedArticle(id: String) async {
        removeCallCount += 1
        indexed.removeValue(forKey: id)
    }

    func removeAllSavedArticles() async {
        removeAllCallCount += 1
        indexed.removeAll()
    }

    func contains(id: String) -> Bool {
        indexed[id] != nil
    }

    func item(for id: String) -> sending CSSearchableItem? {
        indexed[id].map { SystemSpotlightIndexer.makeSearchableItem(for: $0) }
    }

    func getIndexedCount() -> Int {
        indexed.count
    }

    func getIndexCallCount() -> Int {
        indexCallCount
    }
}
