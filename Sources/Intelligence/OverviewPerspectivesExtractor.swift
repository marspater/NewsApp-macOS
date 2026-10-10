import Foundation
import NaturalLanguage

/// Result of deterministically validating an overview perspective against evidence passages and rules.
struct OverviewPerspectiveValidationResult: Sendable, Equatable {
    enum Rule: String, Sendable, Codable {
        case noCitation, unknownCitation, emptyQuote, shortParticipant, vagueParticipant, shortPosition, ungrounded
    }

    let isValid: Bool
    let rejectionReason: String?

    init(isValid: Bool, rejectionReason: String? = nil) {
        self.isValid = isValid
        self.rejectionReason = rejectionReason
    }

    /// Stable rule name for aggregate reports; unlike `rejectionReason`, it never contains participant text.
    var rule: Rule? {
        guard let reason = rejectionReason else { return nil }
        return Self.reasonEndings.first { reason.hasSuffix($0.ending) }?.rule
    }

    /// Each rejection reason in `OverviewPerspectivesValidator` ends with fixed text after any quoted value.
    private static let reasonEndings: [(ending: String, rule: Rule)] = [
        ("Perspective has no source citation", .noCitation),
        ("not found in overview citations", .unknownCitation),
        ("has empty quote", .emptyQuote),
        ("Participant name is empty or too short", .shortParticipant),
        ("is an unattributed generality", .vagueParticipant),
        ("Position statement is empty or too short", .shortPosition),
        ("is not grounded in cited passage text (synthetic or hallucinated claim)", .ungrounded),
    ]
}

/// Counts why an event's perspectives section is absent or thin (#313). Holds no passage or speaker text.
struct OverviewPerspectivesDiagnosis: Sendable, Equatable, Codable {
    var passages = 0
    var uncitedPassages = 0
    var passagesWithCandidates = 0
    /// Passages without a candidate that still contain a quotation mark or a speech verb.
    var passagesWithUnmatchedSpeech = 0
    /// Passages using typographic quotation marks.
    var passagesWithTypographicQuotes = 0
    var candidates = 0
    var vagueCandidates = 0
    var voices = 0
    var rejections: [String: Int] = [:]
    var perspectives = 0
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
        "officials say", "experts", "experts say", "commentators", "officials",
        // A pronoun names no participant on its own.
        "he", "she", "it", "they", "we", "i", "you",
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
                let positionWords =
                    normalizedPosition
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }

                if !positionWords.isEmpty {
                    let matchingWordCount = positionWords.filter { combinedText.contains($0) }.count
                    let matchRatio = Double(matchingWordCount) / Double(positionWords.count)
                    if matchRatio < 0.35 {
                        return OverviewPerspectiveValidationResult(
                            isValid: false,
                            rejectionReason:
                                "Position statement is not grounded in cited passage text (synthetic or hallucinated claim)"
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
        ("Business Wire", ["business wire", "(business wire)"]),
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
        evaluate(passages: passages, articles: articles, existingCitations: existingCitations).perspectives
    }

    /// Runs the same extraction and reports how many passages, candidates and voices each step kept (#313).
    static func diagnosePerspectives(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation]
    ) -> OverviewPerspectivesDiagnosis {
        evaluate(passages: passages, articles: articles, existingCitations: existingCitations).diagnosis
    }

    /// One voice: its first statement and every citation of a reprint or repeat.
    private typealias Voice = (primary: ExtractedCandidate, citationIDs: Set<String>)

    private static func evaluate(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation]
    ) -> (perspectives: [OverviewPerspective], diagnosis: OverviewPerspectivesDiagnosis) {
        var diagnosis = OverviewPerspectivesDiagnosis()
        diagnosis.passages = passages.count
        let candidates = attributedCandidates(
            passages: passages, articles: articles, existingCitations: existingCitations, diagnosis: &diagnosis)
        diagnosis.candidates = candidates.count
        let voices = collapseVoices(candidates, diagnosis: &diagnosis)
        diagnosis.voices = voices.count
        let perspectives = validatedPerspectives(
            voices, existingCitations: existingCitations, passages: passages, diagnosis: &diagnosis)
        diagnosis.perspectives = perspectives.count
        // Sorted deterministically by participant name; no verified perspective leaves the section absent.
        return (perspectives.sorted { $0.participant < $1.participant }, diagnosis)
    }

    /// Attributed statements in cited passages, counting passages that yield none.
    private static func attributedCandidates(
        passages: [EvidencePassage],
        articles: [FeedArticle],
        existingCitations: [String: OverviewCitation],
        diagnosis: inout OverviewPerspectivesDiagnosis
    ) -> [ExtractedCandidate] {
        let articlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })

        // Reverse-index passages to citation IDs
        let passageToCitationID = Dictionary(
            existingCitations.map { ($0.value.passageID, $0.key) }, uniquingKeysWith: { _, last in last })

        var candidates: [ExtractedCandidate] = []
        for passage in passages {
            if passage.text.contains("\u{201C}") || passage.text.contains("\u{201D}") {
                diagnosis.passagesWithTypographicQuotes += 1
            }
            guard let citID = passageToCitationID[passage.id] else {
                diagnosis.uncitedPassages += 1
                continue
            }
            let source = articlesByID[passage.articleID]?.source
            let passageCandidates = extractAttributedQuotes(
                text: passage.text,
                citationID: citID,
                passageID: passage.id,
                articleID: passage.articleID,
                wireSource: detectWireSource(in: passage.text, articleSource: source),
                publisher: source
            )
            if !passageCandidates.isEmpty {
                diagnosis.passagesWithCandidates += 1
            } else if containsSpeechCue(passage.text) {
                diagnosis.passagesWithUnmatchedSpeech += 1
            }
            candidates.append(contentsOf: passageCandidates)
        }
        return candidates
    }

    /// Rule 3: reprints are not presented as independent voices. Vague speakers are dropped; statements from the same
    /// participant or a syndicated wire story collapse into one voice that keeps every citation.
    private static func collapseVoices(
        _ candidates: [ExtractedCandidate], diagnosis: inout OverviewPerspectivesDiagnosis
    ) -> [Voice] {
        var collapsed: [Voice] = []
        for cand in candidates {
            guard !OverviewPerspectivesValidator.isVagueParticipant(cand.participant) else {
                diagnosis.vagueCandidates += 1
                continue
            }
            if let index = collapsed.firstIndex(where: { isSameVoice(existing: $0.primary, candidate: cand) }) {
                collapsed[index].citationIDs.insert(cand.citationID)
                collapsed[index].primary = merged(collapsed[index].primary, with: cand)
            } else {
                collapsed.append((primary: cand, citationIDs: [cand.citationID]))
            }
        }
        return collapsed
    }

    /// The voice's first statement, with the longer participant name and any wire or publisher credit.
    private static func merged(_ existing: ExtractedCandidate, with cand: ExtractedCandidate) -> ExtractedCandidate {
        ExtractedCandidate(
            participant: existing.participant.count >= cand.participant.count ? existing.participant : cand.participant,
            position: existing.position,
            quote: existing.quote,
            citationID: existing.citationID,
            passageID: existing.passageID,
            articleID: existing.articleID,
            originalWireSource: existing.originalWireSource ?? cand.originalWireSource,
            sourcePublisher: existing.sourcePublisher ?? cand.sourcePublisher
        )
    }

    /// Validates each voice against its cited passages, counting rejections by rule.
    private static func validatedPerspectives(
        _ voices: [Voice],
        existingCitations: [String: OverviewCitation],
        passages: [EvidencePassage],
        diagnosis: inout OverviewPerspectivesDiagnosis
    ) -> [OverviewPerspective] {
        var validated: [OverviewPerspective] = []
        for item in voices {
            let primary = item.primary
            let perspective = OverviewPerspective(
                id: "persp_\(primary.passageID)_\(abs(primary.participant.hashValue % 10000))",
                participant: primary.participant,
                position: primary.position,
                citationIDs: Array(item.citationIDs).sorted(),
                sourcePublisher: primary.sourcePublisher,
                originalWireSource: primary.originalWireSource
            )
            let validation = OverviewPerspectivesValidator.validatePerspective(
                perspective, against: existingCitations, passages: passages)
            if validation.isValid {
                validated.append(perspective)
            } else {
                diagnosis.rejections[validation.rule?.rawValue ?? "unknown", default: 0] += 1
            }
        }
        return validated
    }

    private static let speechVerbs = try? NSRegularExpression(
        pattern: #"\b(?:said|says|told|added|stated|announced|warned)\b"#, options: [.caseInsensitive])

    /// A quotation mark or speech verb, so a passage without a candidate may hold a missed attribution.
    private static func containsSpeechCue(_ text: String) -> Bool {
        if text.contains("\"") || text.contains("\u{201C}") || text.contains("\u{201D}") { return true }
        return speechVerbs?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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
            for marker in wire.markers where lowerText.contains(marker) {
                return wire.name
            }
        }
        return nil
    }

    /// One compiled attribution pattern with its capture groups and minimum statement length.
    private struct Attribution {
        let regex: NSRegularExpression
        let participantGroup: Int
        let statementGroup: Int
        let minimumLength: Int

        init?(_ pattern: String, participantGroup: Int, statementGroup: Int, minimumLength: Int) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.regex = regex
            self.participantGroup = participantGroup
            self.statementGroup = statementGroup
            self.minimumLength = minimumLength
        }
    }

    // Compiled once; matches keep pattern order.
    private static let attributions: [Attribution] = {
        // Quote first, with either "said Participant" or "Participant said". Keep paired delimiters and
        // capture the original statement: typographic punctuation must not rewrite the cited evidence.
        let verbs =
            #"(?:said|stated|announced|noted|argued|warned|confirmed|declared|emphasized|urged|reiterated|cautioned|explained)"#
        let participant = #"([A-Z][A-Za-z0-9\s,\.\-]{2,60})"#
        var quoted: [Attribution?] = []
        for quote in [#"\"([^\"“”]{10,250})\""#, #"“([^\"“”]{10,250})”"#] {
            let verbFirst = quote + #",?\s*"# + verbs + #"\s+"# + participant
            let speakerFirst = quote + #",?\s*"# + participant + #"\s+"# + verbs + #"\b"#
            quoted.append(Attribution(verbFirst, participantGroup: 2, statementGroup: 1, minimumLength: 0))
            quoted.append(Attribution(speakerFirst, participantGroup: 2, statementGroup: 1, minimumLength: 0))
        }
        // Pattern 2: [Participant] (said that|stated that|announced that|argued that|warned that|noted that|confirmed that) [Statement].
        let patternSpeakerFirst =
            #"([A-Z][A-Za-z0-9\s,\.\-]{2,60})\s+(?:said that|stated that|announced that|argued that|warned that|noted that|confirmed that|emphasized that|urged that)\s+([^\.\n]{15,200})"#
        // Pattern 2b: reported speech without an adjacent "that" (#313): "Foreign Secretary Ed Miliband said his
        // country does not accept…", "Édouard Geffray told TF1 television on Thursday night that…". The speaker
        // excludes full stops, so it cannot reach back into the previous sentence.
        // When and where the remark was made: "on Thursday night", "Tuesday", "in a statement", "at a news conference".
        let time =
            #"(?:\s+(?:(?:on|late on|earlier on|late|early)\s+)?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|this week|last week|this month|last month|earlier|later)(?:\s+(?:night|morning|evening|afternoon))?(?:\s+\([^)]{1,30}\))?)?(?:\s+(?:in a statement|in an interview|in a report|in a post|at a news conference|during a news conference)[^:,]{0,30}[:,]?)?"#
        let patternReported =
            #"(\p{Lu}[\p{L}0-9\s,'’\-]{1,60}?)\s+(?:(?:said|says)\#(time)\s+(?:that\s+)?|told\s+\p{Lu}[\p{L}0-9\s]{1,40}?\#(time)\s+that\s+)(?!(?:in|on|at|of|for|during|after|before|while|with|is|are|was|were|has|have|had|would|will|could|should|can)\b|\p{Ll}+ing\b)([\p{L}0-9“\"][^\.\n]{15,200})"#
        // Pattern 3: According to [Participant], [Statement].
        let patternAccordingTo = #"According to\s+([A-Z][A-Za-z0-9\s,\.\-]{2,60}),\s+([^\.\n]{15,200})"#

        return
            (quoted + [
                Attribution(patternSpeakerFirst, participantGroup: 1, statementGroup: 2, minimumLength: 10),
                Attribution(patternAccordingTo, participantGroup: 1, statementGroup: 2, minimumLength: 10),
                Attribution(patternReported, participantGroup: 1, statementGroup: 2, minimumLength: 15),
            ]).compactMap { $0 }
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
        let nsString = text as NSString
        for attribution in attributions {
            let matches = attributedMatches(
                of: attribution.regex,
                in: nsString,
                participantGroup: attribution.participantGroup,
                statementGroup: attribution.statementGroup,
                minimumStatementLength: attribution.minimumLength
            )
            for match in matches {
                results.append(
                    ExtractedCandidate(
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
        in nsString: NSString,
        participantGroup: Int,
        statementGroup: Int,
        minimumStatementLength: Int
    ) -> [(participant: String, statement: String)] {
        let matches = regex.matches(in: nsString as String, range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match -> (participant: String, statement: String)? in
            guard match.numberOfRanges >= 3 else { return nil }
            let participant = cleanParticipant(nsString.substring(with: match.range(at: participantGroup)))
            let statement = nsString.substring(with: match.range(at: statementGroup)).trimmingCharacters(
                in: .whitespacesAndNewlines)
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

        // Only the last sentence names the speaker: "…studies literature. He" is "He". A title such as "Dr." or
        // "Gov." is capitalized, so a stop after a lowercase word marks the sentence end.
        if let lastStop = cleaned.range(of: ". ", options: .backwards),
            let before = cleaned[..<lastStop.lowerBound].split(separator: " ").last,
            before.allSatisfy({ $0.isLowercase })
        {
            cleaned = String(cleaned[lastStop.upperBound...])
        }
        // A leading adverbial is not the speaker: "Last month, Germany", "On Wednesday, Canada's justice minister, …".
        var segments = cleaned.components(separatedBy: ", ")
        while segments.count > 1, let first = segments.first?.split(separator: " ").first,
            leadingAdverbials.contains(first.lowercased())
        {
            segments.removeFirst()
        }
        // A participle clause describes the speaker: "Hilliard, sitting at the high court…" is "Hilliard".
        if let clause = segments.dropFirst().firstIndex(where: {
            $0.split(separator: " ").first?.hasSuffix("ing") == true
        }) {
            segments = Array(segments[..<clause])
        }
        var words = segments.joined(separator: ", ").split(separator: " ").map(String.init)
        while let first = words.first, ["and", "but", "so", "the", "a", "an"].contains(first.lowercased()) {
            words.removeFirst()
        }
        while let last = words.last, ["also", "has", "have", "had", "will", "would"].contains(last.lowercased()) {
            words.removeLast()
        }
        // A speaker cut off at a relative word or pronoun is incomplete: "Seoul, which", "Kyiv and".
        if let last = words.last?.lowercased(), danglingWords.contains(last) { return "" }
        // A speaker names someone: "court filing" or "father of four" has no capitalized word.
        guard words.contains(where: { $0.first?.isUppercase == true }) else { return "" }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:-"))
    }

    private static let leadingAdverbials: Set<String> = [
        "and", "but", "so", "meanwhile", "later", "earlier", "last", "this", "next", "on", "in", "at", "during",
        "after", "before", "since", "while", "when", "speaking", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
    private static let danglingWords: Set<String> = [
        "which", "who", "whom", "whose", "that", "and", "or", "but", "she", "he", "they", "it", "her", "his", "their",
        "its",
    ]
}
