import Foundation

/// Evidence passage extracted from a source article to support an event overview.
public struct EvidencePassage: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let articleID: String
    public let text: String
    public let fingerprint: String
    public var ordinal: Int?

    public init(id: String, articleID: String, text: String, fingerprint: String? = nil, ordinal: Int? = nil) {
        self.id = id
        self.articleID = articleID
        self.text = text
        self.fingerprint = fingerprint ?? ArticleIdentity.sha256Hex(text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.ordinal = ordinal
    }
}

/// Claim-level citation linking an overview statement directly to a stored article and evidence passage.
public struct OverviewCitation: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let articleID: String
    public let passageID: String
    public let passageFingerprint: String
    public let quote: String
    public var sourceTitle: String?
    public var sourceName: String?
    public var sourceURL: String?
    public var publishedAt: Date?

    public init(
        id: String,
        articleID: String,
        passageID: String,
        passageFingerprint: String,
        quote: String,
        sourceTitle: String? = nil,
        sourceName: String? = nil,
        sourceURL: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.id = id
        self.articleID = articleID
        self.passageID = passageID
        self.passageFingerprint = passageFingerprint
        self.quote = quote
        self.sourceTitle = sourceTitle
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.publishedAt = publishedAt
    }
}

/// A verified factual claim with explicit claim-level citations to supporting passages.
public struct OverviewFact: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let citationIDs: [String]

    public init(id: String, text: String, citationIDs: [String]) {
        self.id = id
        self.text = text
        self.citationIDs = citationIDs
    }
}

/// Lead image chosen for the event overview with caption, attribution credit, and origin article.
public struct OverviewLeadImage: Codable, Hashable, Sendable {
    public let url: String
    public var caption: String?
    public var credit: String?
    public var sourceArticleID: String?

    public init(url: String, caption: String? = nil, credit: String? = nil, sourceArticleID: String? = nil) {
        self.url = url
        self.caption = caption
        self.credit = credit
        self.sourceArticleID = sourceArticleID
    }
}

/// Generation mode for an event overview.
public enum OverviewKind: String, Codable, Sendable {
    case synthesized
    case fallbackExcerpts
}

/// Derived overview document model bound to membership version, input text hashes, schema version, and analysis version.
public struct EventOverviewDocument: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let currentAnalysisVersion = 1

    public let id: String
    public let eventID: String
    public let membershipVersion: Int
    public let inputTextHash: String
    public let schemaVersion: Int
    public let analysisVersion: Int
    public let createdAt: Date
    public let updatedAt: Date

    public let title: String
    public let summary: String
    public let facts: [OverviewFact]
    public let citations: [String: OverviewCitation]
    public let leadImage: OverviewLeadImage?
    public let memberArticleIDs: [String]
    public let kind: OverviewKind

    public init(
        id: String = UUID().uuidString,
        eventID: String,
        membershipVersion: Int,
        inputTextHash: String,
        schemaVersion: Int = currentSchemaVersion,
        analysisVersion: Int = currentAnalysisVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String,
        summary: String,
        facts: [OverviewFact],
        citations: [OverviewCitation],
        leadImage: OverviewLeadImage? = nil,
        memberArticleIDs: [String] = [],
        kind: OverviewKind = .synthesized
    ) {
        self.id = id
        self.eventID = eventID
        self.membershipVersion = membershipVersion
        self.inputTextHash = inputTextHash
        self.schemaVersion = schemaVersion
        self.analysisVersion = analysisVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.summary = summary
        self.facts = facts
        var dict: [String: OverviewCitation] = [:]
        for c in citations { dict[c.id] = c }
        self.citations = dict
        self.leadImage = leadImage
        self.memberArticleIDs = memberArticleIDs
        self.kind = kind
    }

    /// Evaluates if an existing overview is stale relative to updated membership, inputs, or versions.
    public func isStale(
        currentMembershipVersion: Int,
        currentInputTextHash: String,
        targetSchemaVersion: Int = currentSchemaVersion,
        targetAnalysisVersion: Int = currentAnalysisVersion
    ) -> Bool {
        membershipVersion != currentMembershipVersion
            || inputTextHash != currentInputTextHash
            || schemaVersion != targetSchemaVersion
            || analysisVersion != targetAnalysisVersion
    }

    /// Computes deterministic input text hash across selected evidence passages.
    public static func computeInputTextHash(passages: [EvidencePassage]) -> String {
        let sorted = passages.sorted {
            if $0.articleID != $1.articleID { return $0.articleID < $1.articleID }
            if ($0.ordinal ?? 0) != ($1.ordinal ?? 0) { return ($0.ordinal ?? 0) < ($1.ordinal ?? 0) }
            return $0.id < $1.id
        }
        let combined = sorted.map { "\($0.articleID):\($0.fingerprint)" }.joined(separator: "|")
        return ArticleIdentity.sha256Hex(combined)
    }

    /// Computes deterministic input text hash across candidate/representative articles.
    static func computeInputTextHash(articles: [FeedArticle]) -> String {
        let sorted = articles.sorted { $0.id < $1.id }
        let combined = sorted.map { a in
            let text = a.fullContent ?? a.description
            let textHash = ArticleIdentity.sha256Hex(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return "\(a.id):\(textHash)"
        }.joined(separator: "|")
        return ArticleIdentity.sha256Hex(combined)
    }
}
