import Foundation
import NaturalLanguage

/// Result of deterministically validating an overview perspective against evidence passages and rules.
struct OverviewPerspectiveValidationResult: Sendable, Equatable {
    let isValid: Bool
    let rejectionReason: String?

    init(isValid: Bool, rejectionReason: String? = nil) {
        self.isValid = isValid
        self.rejectionReason = rejectionReason
    }
}

/// Enforces the four core rules of overview perspectives:
/// 1. Only explicitly attributed positions (identified speaker/participant, verified quote/statement).
/// 2. Never invent an "other side" (no synthetic counter-positions or forced false balance).
/// 3. Reprints are not presented as independent voices (syndicated wire reprints collapsed under original source).
/// 4. Every perspective has a verified source citation.
struct OverviewPerspectivesValidator: Sendable {

    /// Known vague, anonymous, or unattributed speaker generalities that must never count as attributed participants.
    static let vagueParticipants: Set<String> = [
        "critics", "critics say", "observers", "observers say", "observers note",
        "some people", "people", "many people", "many believe", "analysts", "analysts say",
        "sources", "sources say", "sources claim", "unnamed sources", "anonymous sources",
        "opponents", "opponents claim", "opponents argue", "skeptics", "the other side",
        "officials say", "experts", "experts say", "commentators"
    ]

    /// Evaluates whether a participant string represents a vague anonymous generality.
    static func isVagueParticipant(_ participant: String) -> Bool {
        let cleaned = participant.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:-"))
            .lowercased()

        if cleaned.count < 2 {
            return true
        }

        if vagueParticipants.contains(cleaned) {
            return true
        }

        let vaguePrefixes = ["critics ", "some ", "many ", "anonymous ", "unnamed ", "the other side"]
        for prefix in vaguePrefixes where cleaned.hasPrefix(prefix) {
            return true
        }

        return false
    }

    /// Validates a single perspective against citations and source evidence passages.
    static func validatePerspective(
        _ perspective: OverviewPerspective,
        against citations: [String: OverviewCitation],
        passages: [EvidencePassage]? = nil
    ) -> OverviewPerspectiveValidationResult {
        // Rule 4: Sourced items (every perspective must have valid source citations)
        guard !perspective.citationIDs.isEmpty else {
            return OverviewPerspectiveValidationResult(
                isValid: false,
                rejectionReason: "Perspective has no source citation"
            )
        }

        for citID in perspective.citationIDs {
            guard let citation = citations[citID] else {
                return OverviewPerspectiveValidationResult(
                    isValid: false,
                    rejectionReason: "Citation ID '\(citID)' not found in overview citations"
                )
            }
            guard !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return OverviewPerspectiveValidationResult(
                    isValid: false,
                    rejectionReason: "Citation '\(citID)' has empty quote"
                )
            }
        }

        // Rule 1: Only explicitly attributed positions
        let participantCleaned = perspective.participant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard participantCleaned.count >= 2 else {
            return OverviewPerspectiveValidationResult(
                isValid: false,
                rejectionReason: "Participant name is empty or too short"
            )
        }

        if isVagueParticipant(participantCleaned) {
            return OverviewPerspectiveValidationResult(
                isValid: false,
                rejectionReason: "Participant '\(perspective.participant)' is an unattributed generality"
            )
        }

        let positionCleaned = perspective.position.trimmingCharacters(in: .whitespacesAndNewlines)
        guard positionCleaned.count >= 5 else {
            return OverviewPerspectiveValidationResult(
                isValid: false,
                rejectionReason: "Position statement is empty or too short"
            )
        }

        // Rule 2: Never invent an "other side" (grounding check against source passage)
        if let passages = passages {
            let citedPassages = passages.filter { pass in
                perspective.citationIDs.contains(where: { citID in citations[citID]?.passageID == pass.id })
            }

            if !citedPassages.isEmpty {
                let combinedText = citedPassages.map(\.text).joined(separator: " ").lowercased()
                let normalizedPosition = positionCleaned.lowercased()
                let positionWords = normalizedPosition
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }

                if !positionWords.isEmpty {
                    let matchingWordCount = positionWords.filter { combinedText.contains($0) }.count
                    let matchRatio = Double(matchingWordCount) / Double(positionWords.count)
                    if matchRatio < 0.35 {
                        return OverviewPerspectiveValidationResult(
                            isValid: false,
                            rejectionReason: "Position statement is not grounded in cited passage text (synthetic or hallucinated claim)"
                        )
                    }
                }
            }
        }

        return OverviewPerspectiveValidationResult(isValid: true)
    }
}

/// Extracts attributed participant and publisher perspectives from evidence passages and member articles,
/// collapsing syndicated reprints under their original wire service.
struct OverviewPerspectivesExtractor: Sendable {

    /// Recognized syndicated wire news agencies.
    private static let recognizedWireServices: [(name: String, markers: [String])] = [
        ("Reuters", ["(reuters)", "reuters", "— reuters", "by reuters"]),
        ("Associated Press", ["(ap)", "associated press", "— ap", "by associated press", "ap news"]),
        ("AFP", ["(afp)", "agence france-presse", "— afp", "by afp"]),
        ("Bloomberg", ["bloomberg news", "bloomberg", "— bloomberg"]),
        ("UPI", ["united press international", "(upi)", "upi"]),
        ("PR Newswire", ["pr newswire", "(pr newswire)"]),
        ("Business Wire", ["business wire", "(business wire)"])
    ]

    /// Candidate attributed perspective discovered during text extraction.
    private struct ExtractedCandidate {
        let participant: String
        let position: String
        let quote: String
        let citationID: String
        let passageID: String
        let articleID: String
        let originalWireSource: String?
        let sourcePublisher: String?
    }

    /// Extracts validated attributed perspectives from event evidence passages.
    ///
    /// - Parameters:
    ///   - passages: Selected evidence passages for the event.
    ///   - articles: Member articles forming the event cluster.
    ///   - existingCitations: Citations map for the overview.
    /// - Returns: Validated attributed perspectives with wire reprints collapsed.
    static func extractPerspectives(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation]
    ) -> [OverviewPerspective] {
        let articlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })

        // Reverse-index passages to citation IDs
        var passageToCitationID: [String: String] = [:]
        for (citID, citation) in existingCitations {
            passageToCitationID[citation.passageID] = citID
        }

        var candidates: [ExtractedCandidate] = []

        for passage in passages {
            guard let citID = passageToCitationID[passage.id] else {
                continue
            }
            let article = articlesByID[passage.articleID]
            let wire = detectWireSource(in: passage.text, articleSource: article?.source)
            let publisher = article?.source

            let passageCandidates = extractAttributedQuotes(
                text: passage.text,
                citationID: citID,
                passageID: passage.id,
                articleID: passage.articleID,
                wireSource: wire,
                publisher: publisher
            )
            candidates.append(contentsOf: passageCandidates)
        }

        // Rule 3: Reprints are not presented as independent voices
        // Group and collapse duplicate statements from identical participants or syndicated wire stories
        var collapsed: [(primary: ExtractedCandidate, citationIDs: Set<String>)] = []

        for cand in candidates {
            // Check for vague participants
            guard !OverviewPerspectivesValidator.isVagueParticipant(cand.participant) else {
                continue
            }

            if let index = collapsed.firstIndex(where: { isSameVoice(existing: $0.primary, candidate: cand) }) {
                collapsed[index].citationIDs.insert(cand.citationID)
                let existingPrimary = collapsed[index].primary
                let wire = existingPrimary.originalWireSource ?? cand.originalWireSource
                let publisher = existingPrimary.sourcePublisher ?? cand.sourcePublisher
                let bestParticipant = existingPrimary.participant.count >= cand.participant.count ? existingPrimary.participant : cand.participant

                collapsed[index].primary = ExtractedCandidate(
                    participant: bestParticipant,
                    position: existingPrimary.position,
                    quote: existingPrimary.quote,
                    citationID: existingPrimary.citationID,
                    passageID: existingPrimary.passageID,
                    articleID: existingPrimary.articleID,
                    originalWireSource: wire,
                    sourcePublisher: publisher
                )
            } else {
                collapsed.append((primary: cand, citationIDs: [cand.citationID]))
            }
        }

        // Validate each collapsed candidate
        var validatedPerspectives: [OverviewPerspective] = []

        for item in collapsed {
            let primary = item.primary
            let sortedCitationIDs = Array(item.citationIDs).sorted()

            let perspective = OverviewPerspective(
                id: "persp_\(primary.passageID)_\(abs(primary.participant.hashValue % 10000))",
                participant: primary.participant,
                position: primary.position,
                citationIDs: sortedCitationIDs,
                sourcePublisher: primary.sourcePublisher,
                originalWireSource: primary.originalWireSource
            )

            let validation = OverviewPerspectivesValidator.validatePerspective(
                perspective,
                against: existingCitations,
                passages: passages
            )
            if validation.isValid {
                validatedPerspectives.append(perspective)
            }
        }

        // Absent sections rule: section is omitted if no verified attributed perspective exists
        guard !validatedPerspectives.isEmpty else {
            return []
        }

        // Sort deterministically by participant name
        return validatedPerspectives.sorted { $0.participant < $1.participant }
    }

    /// Evaluates whether two extracted candidates represent the same voice or syndicated reprint.
    private static func isSameVoice(existing: ExtractedCandidate, candidate: ExtractedCandidate) -> Bool {
        let p1 = existing.participant.lowercased()
        let p2 = candidate.participant.lowercased()

        let sameParticipant = p1 == p2 || p1.contains(p2) || p2.contains(p1)

        let pos1 = normalizedTokens(existing.position)
        let pos2 = normalizedTokens(candidate.position)

        let positionOverlap: Bool
        if !pos1.isEmpty && !pos2.isEmpty {
            let common = pos1.intersection(pos2)
            let minCount = min(pos1.count, pos2.count)
            positionOverlap = Double(common.count) / Double(minCount) >= 0.5
        } else {
            positionOverlap = false
        }

        // Case 1: Same participant and overlapping position
        if sameParticipant && positionOverlap {
            return true
        }

        // Case 2: Identical or strongly overlapping position statement (syndicated quote)
        if positionOverlap && (pos1.count >= 4 || pos2.count >= 4) {
            if existing.originalWireSource != nil || candidate.originalWireSource != nil || sameParticipant {
                return true
            }
        }

        return false
    }

    private static func normalizedTokens(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return Set(words)
    }

    /// Detects syndicated wire service from article text or feed source name.
    static func detectWireSource(in text: String, articleSource: String?) -> String? {
        let lowerText = text.lowercased()
        let lowerSource = articleSource?.lowercased() ?? ""

        for wire in recognizedWireServices {
            if lowerSource.contains(wire.name.lowercased()) {
                return wire.name
            }
            for marker in wire.markers {
                if lowerText.contains(marker) {
                    return wire.name
                }
            }
        }
        return nil
    }

    // Group order and minimum statement length per pattern; matches keep pattern order.
    private static let attributions: [(regex: NSRegularExpression, participantGroup: Int, statementGroup: Int, minimumLength: Int)] = {
        // Pattern 1: "[Quote]," (said|announced|stated|argued|warned|noted) [Participant].
        let patternQuoteFirst = #"\"([^\"]{10,250})\",?\s*(?:said|stated|announced|noted|argued|warned|confirmed|declared|emphasized|urged|reiterated|cautioned|explained)\s+([A-Z][A-Za-z0-9\s,\.\-]{2,60})"#
        // Pattern 2: [Participant] (said that|stated that|announced that|argued that|warned that|noted that|confirmed that) [Statement].
        let patternSpeakerFirst = #"([A-Z][A-Za-z0-9\s,\.\-]{2,60})\s+(?:said that|stated that|announced that|argued that|warned that|noted that|confirmed that|emphasized that|urged that)\s+([^\.\n]{15,200})"#
        // Pattern 3: According to [Participant], [Statement].
        let patternAccordingTo = #"According to\s+([A-Z][A-Za-z0-9\s,\.\-]{2,60}),\s+([^\.\n]{15,200})"#

        return [
            (try! NSRegularExpression(pattern: patternQuoteFirst), 2, 1, 0),
            (try! NSRegularExpression(pattern: patternSpeakerFirst), 1, 2, 10),
            (try! NSRegularExpression(pattern: patternAccordingTo), 1, 2, 10)
        ]
    }()

    /// Extracts quotes and statements with attribution to participants.
    private static func extractAttributedQuotes(
        text: String,
        citationID: String,
        passageID: String,
        articleID: String,
        wireSource: String?,
        publisher: String?
    ) -> [ExtractedCandidate] {
        var results: [ExtractedCandidate] = []
        for attribution in attributions {
            let matches = attributedMatches(
                of: attribution.regex,
                in: text,
                participantGroup: attribution.participantGroup,
                statementGroup: attribution.statementGroup,
                minimumStatementLength: attribution.minimumLength
            )
            for match in matches {
                results.append(ExtractedCandidate(
                    participant: match.participant,
                    position: match.statement,
                    quote: match.statement,
                    citationID: citationID,
                    passageID: passageID,
                    articleID: articleID,
                    originalWireSource: wireSource,
                    sourcePublisher: publisher
                ))
            }
        }

        return results
    }

    /// Runs one attribution pattern and keeps matches that name a participant and carry a statement
    /// of at least `minimumStatementLength` characters.
    private static func attributedMatches(
        of regex: NSRegularExpression,
        in text: String,
        participantGroup: Int,
        statementGroup: Int,
        minimumStatementLength: Int
    ) -> [(participant: String, statement: String)] {
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match -> (participant: String, statement: String)? in
            guard match.numberOfRanges >= 3 else { return nil }
            let participant = cleanParticipant(nsString.substring(with: match.range(at: participantGroup)))
            let statement = nsString.substring(with: match.range(at: statementGroup)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !participant.isEmpty, statement.count >= minimumStatementLength else { return nil }
            return (participant, statement)
        }
    }

    /// Strips leading conjunctions, wire datelines, or trailing punctuation from participant strings.
    private static func cleanParticipant(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:-"))

        // Strip leading datelines like "(Reuters) - " or "LONDON (Reuters) — "
        if let hyphenIndex = cleaned.range(of: " - ")?.upperBound {
            cleaned = String(cleaned[hyphenIndex...]).trimmingCharacters(in: .whitespaces)
        } else if let dashIndex = cleaned.range(of: " — ")?.upperBound {
            cleaned = String(cleaned[dashIndex...]).trimmingCharacters(in: .whitespaces)
        }

        // Strip leading articles
        let leadingWords = ["the ", "The ", "a ", "A ", "an ", "An "]
        for word in leadingWords where cleaned.hasPrefix(word) {
            cleaned = String(cleaned.dropFirst(word.count))
        }

        // If trailing clause was captured (e.g. "Dr. Sarah Jensen, Lead Volcanologist,"), preserve title but trim comma
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:-"))
    }
}
