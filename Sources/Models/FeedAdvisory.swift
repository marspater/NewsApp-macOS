import Foundation

/// A dated maintainer advisory regarding technical deterioration or editorial changes in a source.
struct FeedAdvisory: Equatable, Sendable {
    enum Reason: String, CaseIterable, Codable, Sendable {
        case technicalDeterioration = "technical_deterioration"
        case readerInaccessible = "reader_inaccessible"
        case paywallIntroduced = "paywall_introduced"
        case ownershipChange = "ownership_change"
        case syndicationShift = "syndication_shift"
        case standardUpdate = "standard_update"

        var displayName: String {
            switch self {
            case .technicalDeterioration: return "Technical issues"
            case .readerInaccessible: return "Reader restricted"
            case .paywallIntroduced: return "Subscription required"
            case .ownershipChange: return "Ownership change"
            case .syndicationShift: return "Syndication shift"
            case .standardUpdate: return "Standard update"
            }
        }
    }

    enum Uncertainty: String, CaseIterable, Codable, Sendable {
        case known, provisional, unknown
    }

    let date: String
    let reason: Reason
    let summary: String
    let evidenceLinks: [String]
    let uncertainty: Uncertainty
    let suggestedAlternativeFeedIDs: [String]
}

/// A detected coverage gap in a reader's subscribed topics.
struct TopicGap: Identifiable, Equatable, Sendable {
    var id: String { catalogSet.rawValue }
    let catalogSet: CatalogSet
    let title: String
    let rationale: String
    let candidateFeeds: [CatalogFeed]
}

/// Pure on-device engine for gap discovery and alternative source lookups.
enum CatalogReviewEngine {
    /// Detects offered catalog sets with zero active subscriptions in the user's reading list.
    static func detectTopicGaps(
        subscribedURLs: [String],
        catalog: [CatalogFeed] = FeedCatalog.feeds
    ) -> [TopicGap] {
        let normalizedSubscribed = Set(subscribedURLs.compactMap { AppSettings.normalizeFeedURL($0) })
        var coveredSets = Set<CatalogSet>()

        for feed in catalog where normalizedSubscribed.contains(feed.url) {
            coveredSets.insert(feed.set)
        }

        return CatalogSet.offered.compactMap { catalogSet in
            guard !coveredSets.contains(catalogSet) else { return nil }
            let candidates = catalog.filter { $0.set == catalogSet }
            guard !candidates.isEmpty else { return nil }
            return TopicGap(
                catalogSet: catalogSet,
                title: catalogSet.title,
                rationale: "No active subscriptions covering \(catalogSet.title.lowercased()).",
                candidateFeeds: candidates
            )
        }
    }

    /// Finds candidate alternatives for an advisory-affected or deteriorating feed.
    static func alternatives(
        for feedURL: String,
        advisory: FeedAdvisory? = nil,
        catalog: [CatalogFeed] = FeedCatalog.feeds
    ) -> [CatalogFeed] {
        guard let normalizedURL = AppSettings.normalizeFeedURL(feedURL) else { return [] }
        if let advisory, !advisory.suggestedAlternativeFeedIDs.isEmpty {
            let targetIDs = Set(advisory.suggestedAlternativeFeedIDs)
            let matches = catalog.filter { targetIDs.contains($0.id) && $0.url != normalizedURL }
            if !matches.isEmpty { return matches }
        }

        // Fallback: match by the feed's set in the catalog
        guard let matchingFeed = catalog.first(where: { $0.url == normalizedURL }) else {
            return []
        }
        return catalog.filter { $0.set == matchingFeed.set && $0.url != normalizedURL }
    }
}
