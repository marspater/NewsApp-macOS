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

// Angelia · Clio (sourced overviews) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// Evidence passage extracted from a source article to support an event overview.
public struct EvidencePassage: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let articleID: String
    public let text: String
    /// SHA-256 of the trimmed passage text; citations store it so a changed passage is detected.
    public let fingerprint: String
    /// The passage's position in its article, for a stable order; nil when unknown.
    public var ordinal: Int?

    /// Creates a passage; without a `fingerprint`, it is computed from the trimmed text.
    public init(id: String, articleID: String, text: String, fingerprint: String? = nil, ordinal: Int? = nil) {
        self.id = id
        self.articleID = articleID
        self.text = text
        self.fingerprint =
            fingerprint ?? ArticleIdentity.sha256Hex(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
    /// The cited `EvidencePassage`.
    public let passageID: String
    /// The cited passage's fingerprint when the overview was made.
    public let passageFingerprint: String
    /// The cited text as the overview shows it.
    public let quote: String
    /// The cited publication; nil when none was recorded.
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

    /// Decodes the flat stored form, in which the source fields sit beside the citation's own; `source` stays nil when
    /// none of them is present.
    ///
    /// - Throws: The decoder's error when a required field is missing or malformed.
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

    /// Encodes the flat stored form, writing only the source fields that are present.
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
    /// The citations that support the claim.
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
    /// The article the image came from; nil when not recorded.
    public var sourceArticleID: String?

    public init(url: String, caption: String? = nil, credit: String? = nil, sourceArticleID: String? = nil) {
        self.url = url
        self.caption = caption
        self.credit = credit
        self.sourceArticleID = sourceArticleID
    }
}

/// Clearly labeled modes for reading an event: either the synthesized event overview
/// or the underlying original source publication.
public enum ReaderExperienceMode: String, CaseIterable, Sendable, Identifiable {
    /// The sourced overview of the whole event.
    case eventOverview = "Event overview"
    /// The publisher's own article.
    case sourcePublication = "Source publication"

    public var id: String { rawValue }

    /// Opening a story in this mode counts as reading it. An event overview does not: opening an event
    /// marks nothing read, so the unread count only drops for stories the reader actually opens.
    public var marksOpenedStoryRead: Bool { self != .eventOverview }
}

/// An entry in an event overview's chronological timeline.
///
/// `dateKind` says what `dateText` is, so the reader never infers it from which `Date` happens to be set (#1241).
/// `eventDate` and `publicationDate` are optional full timestamps; a partial stated date (no year) is shown as text
/// only and never gets an invented year. Its place in time for ordering is `orderingDateMayHoldInferredYear`.
public struct OverviewTimelineItem: Codable, Hashable, Sendable, Identifiable {
    /// Where `dateText` comes from.
    public enum DateKind: String, Codable, Hashable, Sendable {
        /// A date the source text states for the event, at the precision it states.
        case stated
        /// The date an article was published; the only date shown as "Reported".
        case publication
        /// A time reference the source states that is not a calendar date: a time of day, a relative anchor
        /// ("yesterday morning") or a quarter. Shown in the source's words, never as a calendar date.
        case anchor
    }

    /// How precise a stated calendar date is; nil for anchors, publication dates and items stored before it existed.
    /// A range or list of dates the source states in one phrase is one span (#1249): its `dateText` keeps each end at
    /// the precision the source gives.
    public enum DatePrecision: String, Codable, Hashable, Sendable {
        case day
        case month
        case range
    }

    public let id: String
    public let dateText: String
    public let dateKind: DateKind
    /// The precision of a stated date (#1241): a month-only date is never counted as its first day.
    public let datePrecision: DatePrecision?
    public let summary: String
    public let citationIDs: [String]
    /// Whether the item states something planned rather than something that happened.
    public let isFuturePlan: Bool
    /// The full date the source states for the event; nil for a partial date, an anchor or a publication date.
    public let eventDate: Date?
    /// The article's publication date, for a `publication` item.
    public let publicationDate: Date?
    /// Ordering only: where a stated date falls in time, for filtering and sorting (Briefing). A date the source
    /// states without a year holds an inferred year here, so this value must never be formatted for display;
    /// `dateText` is what is shown.
    public let orderingDateMayHoldInferredYear: Date?
    /// Ordering only (#1249): the last ordering date of a range or list the source states in one phrase
    /// ("19 to 28 November", "on 3 and 5 November"), whose span runs from `orderingDateMayHoldInferredYear` to this
    /// date. nil for a single date, so items stored before it existed decode as single dates. It may hold an inferred
    /// year and is never displayed.
    public let orderingEndDateMayHoldInferredYear: Date?

    public init(
        id: String = UUID().uuidString,
        dateText: String,
        dateKind: DateKind = .stated,
        datePrecision: DatePrecision? = nil,
        summary: String,
        citationIDs: [String] = [],
        isFuturePlan: Bool = false,
        eventDate: Date? = nil,
        publicationDate: Date? = nil,
        orderingDateMayHoldInferredYear: Date? = nil,
        orderingEndDateMayHoldInferredYear: Date? = nil
    ) {
        self.id = id
        self.dateText = dateText
        self.dateKind = dateKind
        self.datePrecision = datePrecision
        self.summary = summary
        self.citationIDs = citationIDs
        self.isFuturePlan = isFuturePlan
        self.eventDate = eventDate
        self.publicationDate = publicationDate
        self.orderingDateMayHoldInferredYear = orderingDateMayHoldInferredYear
        self.orderingEndDateMayHoldInferredYear = orderingEndDateMayHoldInferredYear
    }

    enum CodingKeys: String, CodingKey {
        case id, dateText, dateKind, datePrecision, summary, citationIDs, isFuturePlan, eventDate, publicationDate
        case orderingDateMayHoldInferredYear, orderingEndDateMayHoldInferredYear
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let storedText = try container.decode(String.self, forKey: .dateText)
        let storedKind = try container.decodeIfPresent(DateKind.self, forKey: .dateKind)
        let hasKind = storedKind != nil
        if let kind = storedKind {
            dateKind = kind
            dateText = storedText
        } else {
            // Items stored before #1241 have no kind. Their producers wrote source text into `dateText`: the
            // builder's stated date, or the former extractor's anchor ("Yesterday Morning", "06:14 UTC") or its
            // "Scheduled" placeholder, which is no date and is dropped here, so no consumer ever receives it (#1241).
            let isPlaceholder = storedText.caseInsensitiveCompare("Scheduled") == .orderedSame
            dateText = isPlaceholder ? "" : storedText
            dateKind = Self.isAnchorText(storedText) ? .anchor : .stated
        }
        datePrecision = try container.decodeIfPresent(DatePrecision.self, forKey: .datePrecision)
        let storedEventDate = try container.decodeIfPresent(Date.self, forKey: .eventDate)
        // The former extractor parsed a yearless "November 2" with `MMMM yyyy`, which stored the day as the year
        // (0002-11-01). Such a date neither orders nor counts anything, so a stored item without a kind drops a year
        // before 100.
        let misparsed = storedEventDate.map { Self.legacyCalendar.component(.year, from: $0) < 100 } ?? false
        eventDate = !hasKind && misparsed ? nil : storedEventDate
        summary = try container.decode(String.self, forKey: .summary)
        citationIDs = try container.decode([String].self, forKey: .citationIDs)
        isFuturePlan = try container.decode(Bool.self, forKey: .isFuturePlan)
        publicationDate = try container.decodeIfPresent(Date.self, forKey: .publicationDate)
        orderingDateMayHoldInferredYear = try container.decodeIfPresent(
            Date.self, forKey: .orderingDateMayHoldInferredYear)
        orderingEndDateMayHoldInferredYear = try container.decodeIfPresent(
            Date.self, forKey: .orderingEndDateMayHoldInferredYear)
    }
}

extension OverviewTimelineItem {
    /// What counts as an anchor: a time of day, a relative day, or a quarter (with or without its year). The one
    /// definition, used to read items stored before #1241 and by `OverviewTimelineBuilder`'s anchor parser.
    static let anchorExpressions: [NSRegularExpression] = [
        #"\b\d{1,2}:\d{2}\s*(?:UTC|GMT|EST|PST|EDT|PDT|CET|CEST)\b"#,
        #"\b(?:earlier today|this morning|yesterday (?:morning|afternoon|evening)|last night|earlier this week)\b"#,
        #"\bQ(?<q>[1-4])\s+(?<qyear>(?:19|20)\d{2})\b"#,
        #"\b(?<ordinal>first|second|third|fourth)\s+quarter(?:\s+of\s+(?<oyear>(?:19|20)\d{2}))?\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// A year a plan states after a preposition ("in 2027", "by 2030"); an anchor only in a sentence that states a
    /// plan. A bare number ("plans to cut 2040 jobs") is no year.
    static let planYearExpression: NSRegularExpression = {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"\b(?:in|by|until)\s+(?<year>(?:19|20)\d{2})\b"#, options: [.caseInsensitive])
        else {
            preconditionFailure("The plan year expression is a valid pattern")
        }
        return expression
    }()

    /// A UTC Gregorian calendar for reading dates stored before #1241.
    static let legacyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()

    /// Whether `text` is, in full, an anchor rather than a calendar date.
    static func isAnchorText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        // The former extractor also stored a plan's bare year ("2028", "in 2028", "by 2035", "until 2030").
        if trimmed.range(
            of: #"^(?:(?:in|by|until)\s+)?(?:19|20)\d{2}$"#, options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        return anchorExpressions.contains {
            $0.firstMatch(in: trimmed, options: .anchored, range: range)?.range == range
        }
    }
}

/// A participant or publisher perspective with clearly attributed stance or statement.
public struct OverviewPerspective: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// The person or body whose position this is.
    public let participant: String
    /// Their stance or statement, as the sources report it.
    public let position: String
    public let citationIDs: [String]
    /// The publisher that reported the position; nil when not recorded.
    public let sourcePublisher: String?
    /// The wire agency the publisher credits for the report; nil when none.
    public let originalWireSource: String?

    public init(
        id: String = UUID().uuidString,
        participant: String,
        position: String,
        citationIDs: [String] = [],
        sourcePublisher: String? = nil,
        originalWireSource: String? = nil
    ) {
        self.id = id
        self.participant = participant
        self.position = position
        self.citationIDs = citationIDs
        self.sourcePublisher = sourcePublisher
        self.originalWireSource = originalWireSource
    }
}

/// A thematic grouping of verified facts around a specific angle (e.g., economic or infrastructural impact).
public struct OverviewThematicAngle: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let citationIDs: [String]
    public let facts: [OverviewFact]

    public init(
        id: String = UUID().uuidString,
        title: String,
        summary: String,
        citationIDs: [String] = [],
        facts: [OverviewFact] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.citationIDs = citationIDs
        self.facts = facts
    }
}

/// An entry in an event overview describing a stated practical implication on a named industry sector (Epic T, #670).
public struct OverviewIndustryImpact: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let industry: String
    public let implication: String
    public let citationIDs: [String]

    public init(
        id: String = UUID().uuidString,
        industry: String,
        implication: String,
        citationIDs: [String] = []
    ) {
        self.id = id
        self.industry = industry
        self.implication = implication
        self.citationIDs = citationIDs
    }
}

/// Optional evaluated tone of coverage; omitted when evidence or corpus evaluation does not justify it.
public struct OverviewCoverageSentiment: Codable, Hashable, Sendable {
    /// The tone score the evaluation gave the coverage.
    public let score: Double
    /// The tone in words.
    public let label: String
    /// How sure the evaluation is, 0 ... 1.
    public let confidence: Double
    public let rationale: String?

    public init(score: Double, label: String, confidence: Double, rationale: String? = nil) {
        self.score = score
        self.label = label
        self.confidence = confidence
        self.rationale = rationale
    }
}

/// Optional structured evidence sections: chronological timeline, participant perspectives, industry impact, thematic angle, and evaluated coverage sentiment.
public struct OverviewEvidenceSections: Codable, Hashable, Sendable {
    /// Sentence-level citations for a model-written introduction; absent in older and extractive documents.
    public let introduction: [OverviewFact]?
    public let timeline: [OverviewTimelineItem]
    public let perspectives: [OverviewPerspective]
    public let industryImpact: [OverviewIndustryImpact]
    public let thematicAngle: OverviewThematicAngle?
    public let coverageSentiment: OverviewCoverageSentiment?

    /// True when no section has content: no introduction claims, timeline, perspectives, impact, angle or sentiment.
    public var isEmpty: Bool {
        introduction?.isEmpty != false && timeline.isEmpty && perspectives.isEmpty && industryImpact.isEmpty
            && thematicAngle == nil && coverageSentiment == nil
    }

    public init(
        timeline: [OverviewTimelineItem] = [],
        perspectives: [OverviewPerspective] = [],
        thematicAngle: OverviewThematicAngle? = nil,
        coverageSentiment: OverviewCoverageSentiment? = nil,
        introduction: [OverviewFact]? = nil,
        industryImpact: [OverviewIndustryImpact] = []
    ) {
        self.timeline = timeline
        self.perspectives = perspectives
        self.thematicAngle = thematicAngle
        self.coverageSentiment = coverageSentiment
        self.introduction = introduction
        self.industryImpact = industryImpact
    }

    enum CodingKeys: String, CodingKey {
        case introduction, timeline, perspectives, industryImpact, thematicAngle, coverageSentiment
    }

    /// Decodes evidence sections, defaulting absent or null timeline, perspective, and industry-impact
    /// arrays to empty. Other absent or null fields, including the introduction, remain nil.
    ///
    /// - Throws: Errors from the decoder, including malformed section values or an incompatible container.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.introduction = try container.decodeIfPresent([OverviewFact].self, forKey: .introduction)
        self.timeline = try container.decodeIfPresent([OverviewTimelineItem].self, forKey: .timeline) ?? []
        self.perspectives = try container.decodeIfPresent([OverviewPerspective].self, forKey: .perspectives) ?? []
        self.industryImpact =
            try container.decodeIfPresent(
                [OverviewIndustryImpact].self, forKey: .industryImpact
            ) ?? []
        self.thematicAngle = try container.decodeIfPresent(OverviewThematicAngle.self, forKey: .thematicAngle)
        self.coverageSentiment = try container.decodeIfPresent(
            OverviewCoverageSentiment.self, forKey: .coverageSentiment
        )
    }

    /// Encodes populated sections, omitting empty timeline, perspective, and industry-impact arrays and
    /// nil optional fields. A present, empty introduction array is retained.
    ///
    /// - Throws: Errors propagated by the encoder while writing the sections.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(introduction, forKey: .introduction)
        if !timeline.isEmpty { try container.encode(timeline, forKey: .timeline) }
        if !perspectives.isEmpty { try container.encode(perspectives, forKey: .perspectives) }
        if !industryImpact.isEmpty { try container.encode(industryImpact, forKey: .industryImpact) }
        try container.encodeIfPresent(thematicAngle, forKey: .thematicAngle)
        try container.encodeIfPresent(coverageSentiment, forKey: .coverageSentiment)
    }
}

/// Generation mode for an event overview.
public enum OverviewKind: String, Codable, Sendable, Equatable, Hashable {
    /// Includes text the on-device model wrote over the excerpt overview.
    case synthesized
    /// Built from publisher excerpts alone, with no model-written text; a model generation change leaves it current.
    case fallbackExcerpts
}

/// Versioning and input binding context for an event overview document.
public struct OverviewVersionContext: Codable, Hashable, Sendable {
    /// The event's membership version the overview was made for.
    public let membershipVersion: Int
    /// `EventOverviewDocument.computeInputTextHash(passages:)` of the passages it was made from.
    public let inputTextHash: String
    /// The stored document layout version.
    public let schemaVersion: Int
    /// The generation rules version; a lower one than `currentAnalysisVersion` is regenerated.
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
    public let evidenceSections: OverviewEvidenceSections?

    /// Creates the content, indexing the citations by ID; a later citation replaces an earlier one with the same ID.
    public init(
        title: String,
        summary: String,
        facts: [OverviewFact] = [],
        citations: [OverviewCitation] = [],
        leadImage: OverviewLeadImage? = nil,
        evidenceSections: OverviewEvidenceSections? = nil
    ) {
        self.title = title
        self.summary = summary
        self.facts = facts
        var dict: [String: OverviewCitation] = [:]
        for c in citations { dict[c.id] = c }
        self.citations = dict
        self.leadImage = leadImage
        self.evidenceSections = evidenceSections
    }
}

/// Origin, membership scope, and lifecycle timestamps for an overview document.
public struct OverviewProvenance: Codable, Hashable, Sendable {
    /// The event's members when the overview was made.
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
    /// The stored document layout version this build writes.
    public static let currentSchemaVersion = 1
    /// 5: attributed straight/typographic quotations with both post-quote speaker orders. 7: reported speech
    /// attribution guards (preposition context, verb/relative exclusions, time phrases). 8: publisher-excerpt overviews
    /// with stored publisher headlines, complete publisher sentences, and empty summaries. 9: Highlights ranked by
    /// word overlap with coverage headlines; fragments under five words excluded. 10: sentences closed by their
    /// attribution, described and institutional speakers, and verifier speaker, quotation and action checks (#547).
    /// 11: conditional Industry Impact section (#670). 13: no feed footer or heading Highlights, one first-pass Highlight
    /// per publisher (#1251). 14: no cut-off feed description tail as a Highlight (#1253). 15: no page title block,
    /// the title alone or with its dateline, as a Highlight (#1266). 16: timeline items carry their date kind and
    /// come from the stated-date builder only (#1241). 17: one row for a stated date range or list (#1249).
    public static let currentAnalysisVersion = 17

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
    /// Every cited claim: the introduction's sentences, then the facts.
    public var allClaims: [OverviewFact] { (content.evidenceSections?.introduction ?? []) + facts }
    public var facts: [OverviewFact] { content.facts }
    public var citations: [String: OverviewCitation] { content.citations }
    public var leadImage: OverviewLeadImage? { content.leadImage }
    public var evidenceSections: OverviewEvidenceSections? { content.evidenceSections }
    public var timeline: [OverviewTimelineItem] { evidenceSections?.timeline ?? [] }
    public var perspectives: [OverviewPerspective] { evidenceSections?.perspectives ?? [] }
    public var industryImpact: [OverviewIndustryImpact] { evidenceSections?.industryImpact ?? [] }
    public var thematicAngle: OverviewThematicAngle? { evidenceSections?.thematicAngle }
    public var coverageSentiment: OverviewCoverageSentiment? { evidenceSections?.coverageSentiment }
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
        case evidenceSections
    }

    /// Decodes the flat stored form, in which version, content and provenance fields sit side by side.
    ///
    /// - Throws: The decoder's error when a required field is missing or malformed.
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
        let evidenceSections = try container.decodeIfPresent(OverviewEvidenceSections.self, forKey: .evidenceSections)
        self.content = OverviewContent(
            title: title,
            summary: summary,
            facts: facts,
            citations: Array(citations.values),
            leadImage: leadImage,
            evidenceSections: evidenceSections
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

    /// Encodes the flat stored form; the lead image and evidence sections only when present.
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
        try container.encodeIfPresent(content.evidenceSections, forKey: .evidenceSections)
        try container.encode(memberArticleIDs, forKey: .memberArticleIDs)
        try container.encode(kind, forKey: .kind)
    }

    /// Evaluates if an existing overview is stale relative to updated membership, inputs, or versions.
    public func isStale(
        currentMembershipVersion: Int,
        currentInputTextHash: String? = nil,
        targetSchemaVersion: Int = currentSchemaVersion,
        targetAnalysisVersion: Int = currentAnalysisVersion
    ) -> Bool {
        membershipVersion != currentMembershipVersion
            || (currentInputTextHash != nil && inputTextHash != currentInputTextHash)
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
