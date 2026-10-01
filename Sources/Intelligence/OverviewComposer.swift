import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Foundation Models Typed Schemas

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
public struct GenerableOverviewFactItem: Sendable, Codable {
    @Guide(description: "A clear, concise factual claim directly supported by the cited passage.")
    public var statement: String

    @Guide(description: "The exact passage_id identifier from which this claim was extracted.")
    public var passageID: String

    @Guide(description: "The verbatim quote from the passage supporting this claim. Never fabricate speech in a person's name.")
    public var quote: String
}

@available(macOS 26.0, *)
@Generable
public struct GenerableOverviewDraft: Sendable, Codable {
    @Guide(description: "A one or two paragraph introduction summarizing the event based only on the verified facts.")
    public var introduction: String

    @Guide(description: "Three to five key facts with citations selected strictly from the verified facts list.")
    public var keyFacts: [GenerableOverviewFactItem]
}
#endif

// MARK: - Validation Result

/// Result of validating a fact against source passages before overview composition.
public struct FactOverviewValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let failureReason: String?

    public init(isValid: Bool, failureReason: String? = nil) {
        self.isValid = isValid
        self.failureReason = failureReason
    }
}

// MARK: - Overview Composer

/// Synthesizes concise, evidence-backed event overviews strictly from verified passage-anchored facts.
/// Enforces:
/// 1. One or two paragraph introduction.
/// 2. Three to five key facts with citations.
/// 3. Quotes reproduced from the source, never generated in a person's name.
/// 4. Publisher text is never replaced by the overview.
public struct OverviewComposer: Sendable {

    /// Validates whether a fact candidate satisfies the quote grounding and passage invariants.
    public static func validateFactForOverview(
        _ fact: PassageAnchoredFact,
        against passages: [EvidencePassage]
    ) -> FactOverviewValidationResult {
        guard let matchingPassage = passages.first(where: { $0.id == fact.passageID }) else {
            return FactOverviewValidationResult(isValid: false, failureReason: "Passage ID \(fact.passageID) not found in source passages")
        }

        let trimmedQuote = fact.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuote.isEmpty else {
            return FactOverviewValidationResult(isValid: false, failureReason: "Fact quote is empty")
        }

        let normalizedPassage = matchingPassage.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedQuote = trimmedQuote.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        guard normalizedPassage.contains(normalizedQuote) else {
            return FactOverviewValidationResult(isValid: false, failureReason: "Quote is not verbatim contained in passage text")
        }

        return FactOverviewValidationResult(isValid: true)
    }

    /// Composes an event overview from verified facts and source evidence passages.
    ///
    /// - Parameters:
    ///   - eventID: Identifier of the event cluster.
    ///   - eventTitle: Title of the event.
    ///   - verifiedFacts: Pre-extracted, passage-anchored facts.
    ///   - passages: Stored evidence passages for the event.
    ///   - articles: Original source publisher articles (retained untouched).
    ///   - leadImage: Optional lead image for the overview.
    ///   - membershipVersion: Membership version of the event cluster.
    /// - Returns: Derived `EventOverviewDocument`.
    static func composeOverview(
        eventID: String,
        eventTitle: String,
        verifiedFacts: [PassageAnchoredFact],
        passages: [EvidencePassage],
        articles: [FeedArticle],
        leadImage: OverviewLeadImage? = nil,
        membershipVersion: Int = 1
    ) -> EventOverviewDocument {
        let passagesByID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        let articlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })

        // Filter and validate facts strictly against passage grounding
        var validFacts: [PassageAnchoredFact] = []
        for fact in verifiedFacts {
            if validateFactForOverview(fact, against: passages).isValid {
                validFacts.append(fact)
            }
        }

        // Compute deterministic input text hash from passage fingerprints
        let sortedFingerprints = passages.map { $0.fingerprint }.sorted().joined(separator: ":")
        let inputTextHash = ArticleIdentity.sha256Hex(sortedFingerprints.isEmpty ? eventTitle : sortedFingerprints)

        let versionContext = OverviewVersionContext(
            membershipVersion: membershipVersion,
            inputTextHash: inputTextHash,
            schemaVersion: EventOverviewDocument.currentSchemaVersion,
            analysisVersion: EventOverviewDocument.currentAnalysisVersion
        )

        let memberArticleIDs = articles.map { $0.id }

        // If fewer than 3 verified facts, provide a safe fallback overview
        if validFacts.count < 3 {
            return composeFallbackOverview(
                eventID: eventID,
                eventTitle: eventTitle,
                validFacts: validFacts,
                passagesByID: passagesByID,
                articlesByID: articlesByID,
                versionContext: versionContext,
                memberArticleIDs: memberArticleIDs,
                leadImage: leadImage
            )
        }

        // Synthesize 3 to 5 key facts
        let targetFactCount = min(5, max(3, validFacts.count))
        let selectedFacts = Array(validFacts.prefix(targetFactCount))

        var overviewFacts: [OverviewFact] = []
        var citations: [OverviewCitation] = []

        for (index, fact) in selectedFacts.enumerated() {
            let citationID = "cite_\(fact.passageID)_\(index + 1)"
            let passage = passagesByID[fact.passageID]
            let article = articlesByID[fact.articleID]

            let meta: OverviewSourceMetadata?
            if let art = article {
                meta = OverviewSourceMetadata(
                    title: art.title,
                    name: art.source,
                    url: art.link,
                    publishedAt: art.pubDate
                )
            } else {
                meta = nil
            }

            let citation = OverviewCitation(
                id: citationID,
                articleID: fact.articleID,
                passageID: fact.passageID,
                passageFingerprint: passage?.fingerprint ?? ArticleIdentity.sha256Hex(fact.quote),
                quote: fact.quote,
                source: meta
            )
            citations.append(citation)

            let overviewFact = OverviewFact(
                id: "fact_\(index + 1)",
                text: fact.statement,
                citationIDs: [citationID]
            )
            overviewFacts.append(overviewFact)
        }

        // Build one or two paragraph introduction
        let introduction = formatIntroduction(eventTitle: eventTitle, facts: selectedFacts)

        let content = OverviewContent(
            title: eventTitle,
            summary: introduction,
            facts: overviewFacts,
            citations: citations,
            leadImage: leadImage
        )

        let provenance = OverviewProvenance(
            memberArticleIDs: memberArticleIDs,
            kind: .synthesized,
            createdAt: Date(),
            updatedAt: Date()
        )

        return EventOverviewDocument(
            eventID: eventID,
            version: versionContext,
            content: content,
            provenance: provenance
        )
    }

    /// Formats a concise 1 or 2 paragraph introduction strictly from the verified facts.
    private static func formatIntroduction(eventTitle: String, facts: [PassageAnchoredFact]) -> String {
        guard !facts.isEmpty else { return eventTitle }

        // Paragraph 1: Headline synthesis from the first 2 facts
        let leadingStatements = facts.prefix(2).map { $0.statement }
        let p1 = leadingStatements.joined(separator: " ")

        // Paragraph 2 (if 3 or more facts): Contextual elaboration from subsequent facts
        if facts.count >= 3 {
            let subsequentStatements = facts.dropFirst(2).prefix(2).map { $0.statement }
            let p2 = subsequentStatements.joined(separator: " ")
            return "\(p1)\n\n\(p2)"
        }

        return p1
    }

    /// Composes a fallback excerpt overview when insufficient verified facts exist for full synthesis.
    private static func composeFallbackOverview(
        eventID: String,
        eventTitle: String,
        validFacts: [PassageAnchoredFact],
        passagesByID: [String: EvidencePassage],
        articlesByID: [String: FeedArticle],
        versionContext: OverviewVersionContext,
        memberArticleIDs: [String],
        leadImage: OverviewLeadImage?
    ) -> EventOverviewDocument {
        var overviewFacts: [OverviewFact] = []
        var citations: [OverviewCitation] = []

        for (index, fact) in validFacts.enumerated() {
            let citationID = "cite_fb_\(fact.passageID)_\(index + 1)"
            let passage = passagesByID[fact.passageID]
            let article = articlesByID[fact.articleID]

            let meta: OverviewSourceMetadata?
            if let art = article {
                meta = OverviewSourceMetadata(title: art.title, name: art.source, url: art.link, publishedAt: art.pubDate)
            } else {
                meta = nil
            }

            let citation = OverviewCitation(
                id: citationID,
                articleID: fact.articleID,
                passageID: fact.passageID,
                passageFingerprint: passage?.fingerprint ?? ArticleIdentity.sha256Hex(fact.quote),
                quote: fact.quote,
                source: meta
            )
            citations.append(citation)

            overviewFacts.append(OverviewFact(
                id: "fb_fact_\(index + 1)",
                text: fact.statement,
                citationIDs: [citationID]
            ))
        }

        let summary = validFacts.isEmpty ? eventTitle : validFacts.map { $0.statement }.joined(separator: " ")

        let content = OverviewContent(
            title: eventTitle,
            summary: summary,
            facts: overviewFacts,
            citations: citations,
            leadImage: leadImage
        )

        let provenance = OverviewProvenance(
            memberArticleIDs: memberArticleIDs,
            kind: .fallbackExcerpts,
            createdAt: Date(),
            updatedAt: Date()
        )

        return EventOverviewDocument(
            eventID: eventID,
            version: versionContext,
            content: content,
            provenance: provenance
        )
    }

    /// Builds a prompt for Foundation Models guided overview composition with untrusted data boundary defense.
    public static func buildOverviewPrompt(
        eventTitle: String,
        verifiedFacts: [PassageAnchoredFact],
        passages: [EvidencePassage]
    ) -> String {
        let framedPassages = GenerationPromptDefense.frameEvidencePassages(passages)
        var factsList = ""
        for (i, f) in verifiedFacts.enumerated() {
            factsList += "\(i + 1). [\(f.passageID)] \(f.statement) (Quote: \"\(f.quote)\")\n"
        }

        return """
        \(GenerationPromptDefense.untrustedDataSystemGuard)

        You are an evidence-anchored journalistic synthesizer composing an event overview.
        Topic: \(eventTitle)

        Instructions:
        1. Write a one or two paragraph introduction synthesizing the event.
        2. Select 3 to 5 key facts from the verified facts list below.
        3. For each key fact, reference its exact passage_id and verbatim quote.
        4. NEVER generate or attribute statements in a person's name unless the quote is verbatim present in the passage.
        5. Do not replace or contradict publisher text. Use only provided facts.

        <verified_facts>
        \(factsList)</verified_facts>

        \(framedPassages)
        """
    }

    #if canImport(FoundationModels)
    /// Composes an event overview using Foundation Models when available on macOS 26+.
    @available(macOS 26.0, *)
    static func composeWithModel(
        eventID: String,
        eventTitle: String,
        verifiedFacts: [PassageAnchoredFact],
        passages: [EvidencePassage],
        articles: [FeedArticle],
        leadImage: OverviewLeadImage? = nil,
        membershipVersion: Int = 1
    ) async throws -> EventOverviewDocument {
        let session = LanguageModelSession()
        let prompt = buildOverviewPrompt(eventTitle: eventTitle, verifiedFacts: verifiedFacts, passages: passages)
        let response = try await session.respond(to: prompt, generating: GenerableOverviewDraft.self)

        let draft = response.content
        var candidateFacts: [PassageAnchoredFact] = []
        for (i, item) in draft.keyFacts.enumerated() {
            let articleID = passages.first(where: { $0.id == item.passageID })?.articleID ?? ""
            candidateFacts.append(PassageAnchoredFact(
                id: "model_fact_\(i + 1)",
                statement: item.statement,
                passageID: item.passageID,
                quote: item.quote,
                articleID: articleID
            ))
        }

        // Validate draft facts against passages
        return composeOverview(
            eventID: eventID,
            eventTitle: eventTitle,
            verifiedFacts: candidateFacts.isEmpty ? verifiedFacts : candidateFacts,
            passages: passages,
            articles: articles,
            leadImage: leadImage,
            membershipVersion: membershipVersion
        )
    }
    #endif
}
