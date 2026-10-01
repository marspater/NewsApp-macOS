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

/// Metadata describing the original source publication for an overview citation.
public struct OverviewSourceMetadata: Codable, Hashable, Sendable {
    public var title: String?
    public var name: String?
    public var url: String?
    public var publishedAt: Date?

    public init(
        title: String? = nil,
        name: String? = nil,
        url: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.title = title
        self.name = name
        self.url = url
        self.publishedAt = publishedAt
    }
}

/// Claim-level citation linking an overview statement directly to a stored article and evidence passage.
public struct OverviewCitation: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let articleID: String
    public let passageID: String
    public let passageFingerprint: String
    public let quote: String
    public var source: OverviewSourceMetadata?

    public var sourceTitle: String? { source?.title }
    public var sourceName: String? { source?.name }
    public var sourceURL: String? { source?.url }
    public var publishedAt: Date? { source?.publishedAt }

    public init(
        id: String,
        articleID: String,
        passageID: String,
        passageFingerprint: String,
        quote: String,
        source: OverviewSourceMetadata? = nil
    ) {
        self.id = id
        self.articleID = articleID
        self.passageID = passageID
        self.passageFingerprint = passageFingerprint
        self.quote = quote
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, articleID, passageID, passageFingerprint, quote
        case sourceTitle, sourceName, sourceURL, publishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.articleID = try container.decode(String.self, forKey: .articleID)
        self.passageID = try container.decode(String.self, forKey: .passageID)
        self.passageFingerprint = try container.decode(String.self, forKey: .passageFingerprint)
        self.quote = try container.decode(String.self, forKey: .quote)
        let title = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        let name = try container.decodeIfPresent(String.self, forKey: .sourceName)
        let url = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        let publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        if title != nil || name != nil || url != nil || publishedAt != nil {
            self.source = OverviewSourceMetadata(title: title, name: name, url: url, publishedAt: publishedAt)
        } else {
            self.source = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(articleID, forKey: .articleID)
        try container.encode(passageID, forKey: .passageID)
        try container.encode(passageFingerprint, forKey: .passageFingerprint)
        try container.encode(quote, forKey: .quote)
        try container.encodeIfPresent(sourceTitle, forKey: .sourceTitle)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(publishedAt, forKey: .publishedAt)
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

/// Versioning and input binding context for an event overview document.
public struct OverviewVersionContext: Codable, Hashable, Sendable {
    public let membershipVersion: Int
    public let inputTextHash: String
    public let schemaVersion: Int
    public let analysisVersion: Int

    public init(
        membershipVersion: Int,
        inputTextHash: String,
        schemaVersion: Int = EventOverviewDocument.currentSchemaVersion,
        analysisVersion: Int = EventOverviewDocument.currentAnalysisVersion
    ) {
        self.membershipVersion = membershipVersion
        self.inputTextHash = inputTextHash
        self.schemaVersion = schemaVersion
        self.analysisVersion = analysisVersion
    }
}

/// Narrative content and verified facts comprising an event overview.
public struct OverviewContent: Codable, Hashable, Sendable {
    public let title: String
    public let summary: String
    public let facts: [OverviewFact]
    public let citations: [String: OverviewCitation]
    public let leadImage: OverviewLeadImage?

    public init(
        title: String,
        summary: String,
        facts: [OverviewFact] = [],
        citations: [OverviewCitation] = [],
        leadImage: OverviewLeadImage? = nil
    ) {
        self.title = title
        self.summary = summary
        self.facts = facts
        var dict: [String: OverviewCitation] = [:]
        for c in citations { dict[c.id] = c }
        self.citations = dict
        self.leadImage = leadImage
    }
}

/// Origin, membership scope, and lifecycle timestamps for an overview document.
public struct OverviewProvenance: Codable, Hashable, Sendable {
    public let memberArticleIDs: [String]
    public let kind: OverviewKind
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        memberArticleIDs: [String] = [],
        kind: OverviewKind = .synthesized,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.memberArticleIDs = memberArticleIDs
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Derived overview document model bound to membership version, input text hashes, schema version, and analysis version.
public struct EventOverviewDocument: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let currentAnalysisVersion = 1

    public let id: String
    public let eventID: String
    public let version: OverviewVersionContext
    public let content: OverviewContent
    public let provenance: OverviewProvenance

    public var membershipVersion: Int { version.membershipVersion }
    public var inputTextHash: String { version.inputTextHash }
    public var schemaVersion: Int { version.schemaVersion }
    public var analysisVersion: Int { version.analysisVersion }
    public var title: String { content.title }
    public var summary: String { content.summary }
    public var facts: [OverviewFact] { content.facts }
    public var citations: [String: OverviewCitation] { content.citations }
    public var leadImage: OverviewLeadImage? { content.leadImage }
    public var memberArticleIDs: [String] { provenance.memberArticleIDs }
    public var kind: OverviewKind { provenance.kind }
    public var createdAt: Date { provenance.createdAt }
    public var updatedAt: Date { provenance.updatedAt }

    public init(
        id: String = UUID().uuidString,
        eventID: String,
        version: OverviewVersionContext,
        content: OverviewContent,
        provenance: OverviewProvenance = OverviewProvenance()
    ) {
        self.id = id
        self.eventID = eventID
        self.version = version
        self.content = content
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case id, eventID, membershipVersion, inputTextHash, schemaVersion, analysisVersion
        case createdAt, updatedAt, title, summary, facts, citations, leadImage, memberArticleIDs, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.eventID = try container.decode(String.self, forKey: .eventID)
        let membershipVersion = try container.decode(Int.self, forKey: .membershipVersion)
        let inputTextHash = try container.decode(String.self, forKey: .inputTextHash)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let analysisVersion = try container.decode(Int.self, forKey: .analysisVersion)
        self.version = OverviewVersionContext(
            membershipVersion: membershipVersion,
            inputTextHash: inputTextHash,
            schemaVersion: schemaVersion,
            analysisVersion: analysisVersion
        )
        let title = try container.decode(String.self, forKey: .title)
        let summary = try container.decode(String.self, forKey: .summary)
        let facts = try container.decode([OverviewFact].self, forKey: .facts)
        let citations = try container.decode([String: OverviewCitation].self, forKey: .citations)
        let leadImage = try container.decodeIfPresent(OverviewLeadImage.self, forKey: .leadImage)
        self.content = OverviewContent(
            title: title,
            summary: summary,
            facts: facts,
            citations: Array(citations.values),
            leadImage: leadImage
        )
        let memberArticleIDs = try container.decode([String].self, forKey: .memberArticleIDs)
        let kind = try container.decode(OverviewKind.self, forKey: .kind)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.provenance = OverviewProvenance(
            memberArticleIDs: memberArticleIDs,
            kind: kind,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(membershipVersion, forKey: .membershipVersion)
        try container.encode(inputTextHash, forKey: .inputTextHash)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(analysisVersion, forKey: .analysisVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(facts, forKey: .facts)
        try container.encode(citations, forKey: .citations)
        try container.encodeIfPresent(leadImage, forKey: .leadImage)
        try container.encode(memberArticleIDs, forKey: .memberArticleIDs)
        try container.encode(kind, forKey: .kind)
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
}

/// A real-world event and the stored articles that report it. Members are referenced by surviving
/// article ID only; source text stays on the article rows. `membershipVersion` grows whenever the
/// member set changes, so overviews bound to an older version are stale.
public struct StoryEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let membershipVersion: Int
    public let memberArticleIDs: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, membershipVersion: Int, memberArticleIDs: [String], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.membershipVersion = membershipVersion
        self.memberArticleIDs = memberArticleIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
