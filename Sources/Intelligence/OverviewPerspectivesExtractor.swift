import Foundation
import NaturalLanguage

/// Result of deterministically validating an overview perspective against evidence passages and rules.
struct OverviewPerspectiveValidationResult: Sendable, Equatable {
    enum Rule: String, Sendable, Codable {
        case noCitation, unknownCitation, emptyQuote, shortParticipant, vagueParticipant, shortPosition, timePhrase,
            ungrounded
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
        ("Position statement is a time phrase, not a position", .timePhrase),
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
        "officials say", "experts", "experts say", "commentators", "officials", "authorities",
        // A pronoun names no participant on its own.
        "he", "she", "it", "they", "we", "i", "you",
    ]

    private static let pureTimePhrases: Set<String> = [
        "earlier this year", "earlier this month", "earlier today", "earlier this week",
        "late last year", "late last month", "late last week", "last year", "last month",
        "this year", "this month", "this week", "earlier", "later",
    ]

    private static let dayNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    /// When a remark was made rather than what was said: "earlier this year", or "Thursday, warning…" left
    /// over from "said Thursday". A possessive such as "Monday's vote" is a position.
    static func isTimePhrase(_ position: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: "\"'.,:- ")
        let normalized = position.trimmingCharacters(in: punctuation).lowercased()
        if pureTimePhrases.contains(normalized) { return true }
        guard let first = normalized.split(separator: " ").first else { return false }
        return dayNames.contains(first.trimmingCharacters(in: punctuation))
    }

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

        if isTimePhrase(positionCleaned) {
            return OverviewPerspectiveValidationResult(
                isValid: false,
                rejectionReason: "Position statement is a time phrase, not a position"
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
            #"(?:said|stated|announced|noted|argued|warned|confirmed|declared|emphasized|urged|reiterated|cautioned|explained|wrote|posted)"#
        let participant = #"([A-Z][A-Za-z0-9\s,\.\-]{2,60})"#
        // When and where the remark was made: "on Thursday night", "Tuesday", "in a statement", "at a news conference".
        let time =
            #"(?:\s+(?:(?:on|late on|earlier on|late|early)\s+)?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|this week|last week|this month|last month|this year|last year|earlier this year|earlier this month|earlier today|earlier|later)(?:\s+(?:night|morning|evening|afternoon))?(?:\s+\([^)]{1,30}\))?)?(?:\s+(?:in a statement|in an interview|in a report|in a post|at a news conference|during a news conference)[^:,]{0,30})?[:,]?"#
        var quoted: [Attribution?] = []
        for quote in [#"\"([^\"“”]{10,250})\""#, #"“([^\"“”]{10,250})”"#] {
            let verbFirst = quote + #",?\s*"# + verbs + #"\s+"# + participant
            let speakerFirst = quote + #",?\s*"# + participant + #"\s+"# + verbs + #"\b"#
            let speakerBeforeQuote = participant + #"\s+"# + verbs + time + #"\s*"# + quote
            let speakerToldBeforeQuote =
                participant
                + #"\s+told\s+(?:(?:[Tt]he|[Aa]n?)\s+[\p{L}0-9\s]{1,30}?|\p{Lu}[\p{L}0-9\s]{1,30}?|reporters|journalists|broadcasters)\#(time)\s*"#
                + quote
            let accordingToQuoted = #"According to\s+"# + participant + #",\s*"# + quote
            quoted.append(Attribution(verbFirst, participantGroup: 2, statementGroup: 1, minimumLength: 0))
            quoted.append(Attribution(speakerFirst, participantGroup: 2, statementGroup: 1, minimumLength: 0))
            quoted.append(Attribution(speakerBeforeQuote, participantGroup: 1, statementGroup: 2, minimumLength: 0))
            quoted.append(Attribution(speakerToldBeforeQuote, participantGroup: 1, statementGroup: 2, minimumLength: 0))
            quoted.append(Attribution(accordingToQuoted, participantGroup: 1, statementGroup: 2, minimumLength: 0))
        }
        // Pattern 2: [Participant] (said that|stated that|announced that|argued that|warned that|noted that|confirmed that) [Statement].
        let patternSpeakerFirst =
            #"([A-Z][A-Za-z0-9\s,\.\-]{2,60})\s+(?:said that|stated that|announced that|argued that|warned that|noted that|confirmed that|emphasized that|urged that)\s+([^\.\n]{15,200})"#
        // Pattern 2b: reported speech without an adjacent "that" (#313): "Foreign Secretary Ed Miliband said his
        // country does not accept…", "Édouard Geffray told TF1 television on Thursday night that…". The speaker
        // excludes full stops, so it cannot reach back into the previous sentence.
        let patternReported =
            #"(\p{Lu}[\p{L}0-9\s,'’\-]{1,60}?)\s+(?:(?:said|says)\#(time)\s+(?:that\s+)?|told\s+(?:(?:[Tt]he|[Aa]n?)\s+[\p{L}0-9\s]{1,40}?|\p{Lu}[\p{L}0-9\s]{1,40}?|\p{Ll}+(?:\s+\p{Ll}+)?)\#(time)\s+that\s+)(?!(?:in|on|at|of|for|during|after|before|while|with|is|are|was|were|has|have|had|would|will|could|should|can|late|early|earlier|later|and|but|as|a\s+day\s+after)\b|\p{Ll}+ing\b)([\p{L}0-9“\"][^\.\n]{15,200})"#
        // Pattern 3: According to [Participant], [Statement].
        let patternAccordingTo = #"According to\s+([A-Z][A-Za-z0-9\s,\.\-]{2,60}),\s+([^\.\n]{15,200})"#
        // Pattern 4 (#547): a whole sentence closed by its attribution, without quotation marks: "Russia launched
        // 50 drones at Kyiv, the Ukrainian air force said.", "…, said Mayor Vitali Klitschko.", "…, according to
        // the Gaza health ministry.", "…, Peskov told reporters on Monday." The tag must end the sentence.
        // A dateline ("PARIS: ") is not part of the statement.
        // Full stops inside a number ("3.48") or an initialism ("U.S.") do not end it.
        let sentence =
            #"(?:^|(?<=[.!?]\s))(?:\p{Lu}{2,}(?:\s\p{Lu}{2,})*:\s+)?(\p{Lu}(?:[^.\n"“”]|\.(?=\d)|(?<=\b\p{Lu})\.){15,200}?)"#
        // Up to eight words without a comma; `isCompleteSpeaker` decides whether they name someone ("the club's
        // sporting director Max Eberl", "the interior ministry"), so "authorities" or "he" yield nothing.
        let tagSpeaker = #"([\p{L}0-9'’\-]+(?:\s+[\p{L}0-9'’\-]+){0,7}?)"#
        // "in a statement", a weekday, date or platform ("late on Friday", "on 11 October", "on Oct. 9", "on X"), an
        // optional "(October 23, 2026)", then the full stop or a continuation ("…, as authorities searched…").
        let inStatement = #"(?:\s+in\s+a\s+statement)?"#
        let closing =
            inStatement
            + #"(?:\s+(?:(?:late|early)\s+)?(?:on\s+)?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)(?:\s+(?:night|morning|evening|afternoon))?|\s+on\s+(?:\d{1,2}\s+\p{Lu}\p{Ll}+|\p{Lu}\p{Ll}+\.?\s+\d{1,2}|X|Facebook|Telegram|Instagram|social\s+media))?"#
            + #"(?:\s*\([^)]{1,30}\))?"# + inStatement
            + #"(?:\.|$|,\s+(?:adding|as|while|with|citing|saying|referring|noting)\b)"#
        let patternTrailing =
            sentence + #",\s+"# + tagSpeaker
            + #"\s+(?:said|says|added|stated|warned|wrote|posted|told\s+(?:reporters|journalists|(?:[Tt]he\s+)?\p{Lu}[\p{L}\s]{1,30}?))"#
            + closing
        // A speaker with one appositive: "…, the mayor of La Verrière, Nicolas Dainville, told AFP."
        let patternTrailingAppositive =
            sentence
            + #",\s+((?:[\p{L}0-9'’\-]+\s+){0,6}[\p{L}0-9'’\-]+,\s+(?:[\p{L}0-9'’\-]+\s+){0,4}[\p{L}0-9'’\-]+),"#
            + #"\s+(?:said|says|added|told\s+(?:reporters|journalists|(?:[Tt]he\s+)?\p{Lu}[\p{L}\s]{1,30}?))"# + closing
        // After the verb the speaker is a capitalized name or title: "…, said Mayor Vitali Klitschko.", never "…, said
        // on Monday…" or "…, said American tariffs hurt…".
        let patternTrailingVerbFirst =
            sentence
            + #",\s+(?:said|says|added)\s+((?:(?:Mr|Mrs|Ms|Dr)\.\s+)?\p{Lu}[\p{L}'’\-]*(?:\s+(?:\p{Lu}[\p{L}'’\-]*|al|bin|de|der|van|von|of|the)){0,5})\."#
        let patternTrailingAccordingTo =
            sentence + #",\s+according\s+to\s+"# + tagSpeaker + #"(?:\.|,\s+(?:adding|as|while|with|citing)\b)"#
        // A quotation closed by a described speaker: "…uncertain," political scientist Dusan Spasojevic told DW.
        var quotedTags: [Attribution?] = []
        for quote in [#"\"([^\"“”]{10,250})\""#, #"“([^\"“”]{10,250})”"#] {
            let tagged =
                quote + #",?\s*"# + tagSpeaker
                + #"\s+(?:said|says|added|explained|warned|wrote|told\s+(?:reporters|journalists|(?:[Tt]he\s+)?\p{Lu}[\p{L}\s]{0,30}?))"#
                + closing
            quotedTags.append(Attribution(tagged, participantGroup: 2, statementGroup: 1, minimumLength: 0))
            // "…satisfied," said student representative Nathanael Combary.
            let describedAfterVerb =
                quote
                + #",?\s*(?:said|says|added)\s+((?:\p{Ll}[\p{L}\-]*\s+){1,3}\p{Lu}[\p{L}'’\-]*(?:\s+\p{Lu}[\p{L}'’\-]*){0,3})[.,]"#
            quotedTags.append(Attribution(describedAfterVerb, participantGroup: 2, statementGroup: 1, minimumLength: 0))
        }

        return
            (quoted + quotedTags + [
                Attribution(patternSpeakerFirst, participantGroup: 1, statementGroup: 2, minimumLength: 10),
                Attribution(patternAccordingTo, participantGroup: 1, statementGroup: 2, minimumLength: 10),
                Attribution(patternReported, participantGroup: 1, statementGroup: 2, minimumLength: 15),
                Attribution(patternTrailing, participantGroup: 2, statementGroup: 1, minimumLength: 15),
                Attribution(patternTrailingAppositive, participantGroup: 2, statementGroup: 1, minimumLength: 15),
                Attribution(patternTrailingVerbFirst, participantGroup: 2, statementGroup: 1, minimumLength: 15),
                Attribution(patternTrailingAccordingTo, participantGroup: 2, statementGroup: 1, minimumLength: 15),
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
        // Zero-width and soft-hyphen characters (common in wire copy) would split words inside the patterns.
        let nsString = text.filter { !invisibleCharacters.contains($0) } as NSString
        for attribution in attributions {
            let matches = attributedMatches(
                of: attribution.regex,
                in: nsString,
                participantGroup: attribution.participantGroup,
                statementGroup: attribution.statementGroup,
                minimumStatementLength: attribution.minimumLength
            )
            // Patterns overlap ("…," Mayor Elena Rostova said. matches two); one candidate per statement and speaker.
            for match in matches
            where !results.contains(where: { $0.participant == match.participant && $0.position == match.statement }) {
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

    private static let invisibleCharacters: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}",
    ]

    private static let precedingPrepositionRegex = try? NSRegularExpression(
        pattern:
            #"(?:\b(?:in|at|from|to|by|near|across|around|into|with|during|about|against|told)\s+(?:the\s+|a\s+|an\s+|southeast\s+|north\s+|south\s+|east\s+|west\s+)?|%\s+of\s+)$"#,
        options: [.caseInsensitive])

    /// Whether the text before `location` ends in a preposition ("in the", "told", "% of"), so a capitalized word at
    /// `location` is a place or object, not a speaker. "According to" introduces a speaker.
    private static func precededByPreposition(_ location: Int, in nsString: NSString) -> Bool {
        guard location > 0 else { return false }
        let checkLength = min(40, location)
        let precedingText = nsString.substring(with: NSRange(location: location - checkLength, length: checkLength))
        if precedingText.lowercased().hasSuffix("according to ") { return false }
        return precedingPrepositionRegex?.firstMatch(
            in: precedingText, range: NSRange(location: 0, length: precedingText.utf16.count)) != nil
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
            var participantRange = match.range(at: participantGroup)
            if precededByPreposition(participantRange.location, in: nsString) {
                // "In Karak, Major General Abdallah al-Maaytah said": the place follows the preposition, the speaker
                // follows the last comma.
                let lastComma = nsString.range(of: ", ", options: .backwards, range: participantRange)
                guard lastComma.location != NSNotFound else { return nil }
                let start = NSMaxRange(lastComma)
                participantRange = NSRange(location: start, length: NSMaxRange(participantRange) - start)
            }
            let participant = cleanParticipant(nsString.substring(with: participantRange))
            let statement = nsString.substring(with: match.range(at: statementGroup)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !participant.isEmpty, statement.count >= minimumStatementLength else { return nil }
            // An unquoted statement of capitalized words only is a speaker tag: in "…the capital, said Mayor Vitali
            // Klitschko." the reported-speech pattern reads the sentence as the speaker and the name as the statement.
            if minimumStatementLength > 0, statement.split(separator: " ").allSatisfy({ $0.first?.isUppercase == true })
            {
                return nil
            }
            return (participant, statement)
        }
    }

    /// Strips leading conjunctions, wire datelines, or trailing punctuation from participant strings.
    private static func cleanParticipant(_ raw: String) -> String {
        let words = trimmedSpeakerWords(stripSpeakerPrefixes(raw))
        return isCompleteSpeaker(words)
            ? words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:-")) : ""
    }

    /// Removes datelines, leading articles and earlier sentences: "LONDON (Reuters) - The minister" is "minister",
    /// "…studies literature. He" is "He".
    private static func stripSpeakerPrefixes(_ raw: String) -> String {
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
        return cleaned
    }

    /// Drops leading adverbials, describing participle clauses and dangling connectives around the speaker.
    private static func trimmedSpeakerWords(_ cleaned: String) -> [String] {
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
        // A clause before the speaker is not part of it: "Kenya has recorded a second Ebola death, the health
        // ministry", "half of last week's numbers, the Interior Ministry". An appositive title stays: "Jordan's
        // ambassador to the US, Dina Kawar".
        while segments.count > 1, let first = segments.first,
            first.split(separator: " ").count >= 6
                || first.split(separator: " ").first { !["the", "a", "an"].contains($0) }?.first?.isLowercase == true
        {
            segments.removeFirst()
        }
        // A trailing connective is not part of the speaker: "CGT trade union, meanwhile".
        while segments.count > 1, let last = segments.last?.lowercased(), trailingConnectives.contains(last) {
            segments.removeLast()
        }
        var words = segments.joined(separator: ", ").split(separator: " ").map(String.init)
        while let first = words.first, ["and", "but", "so", "the", "a", "an"].contains(first.lowercased()) {
            words.removeFirst()
        }
        while let last = words.last, ["also", "has", "have", "had", "will", "would"].contains(last.lowercased()) {
            words.removeLast()
        }
        // "a figure the UN" is "UN": lowercase words before "the" and a name describe the statement, not the speaker.
        if let the = words.firstIndex(where: { $0.lowercased() == "the" }), the > 0, the + 1 < words.count,
            words[..<the].allSatisfy({ $0.first?.isLowercase == true }), words[the + 1].first?.isUppercase == true
        {
            words.removeFirst(the + 1)
        }
        // "Police on Saturday" is "Police".
        if words.count > 2, words[words.count - 2].lowercased() == "on",
            leadingAdverbials.contains(words[words.count - 1].lowercased())
        {
            words.removeLast(2)
        }
        return words
    }

    /// A speaker is a capitalized noun phrase, not a clause fragment.
    private static func isCompleteSpeaker(_ words: [String]) -> Bool {
        // A speaker cut off at a relative word or pronoun is incomplete: "Seoul, which", "Kyiv and", "outbreak and is".
        if let last = words.last?.lowercased(), danglingWords.contains(last) { return false }
        // A finite verb, relative pronoun, speech verb or clause conjunction means the match spans a clause.
        let clauseWord = words.contains {
            clauseWords.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:-")).lowercased())
        }
        if clauseWord { return false }
        if let first = words.first?.lowercased(), subordinators.contains(first) { return false }
        // A title alone is cut off: "said Mr." is not a speaker.
        if words.count == 1, let only = words.first?.lowercased(), honorifics.contains(only) { return false }
        // A speaker names someone: "court filing" or "father of four" has no capitalized word. An institution or
        // office as the head noun names its speaker too: "the interior ministry", "the club's sporting director".
        // A data source is not a speaker: "according to the National Grid map", "according to the report".
        if let last = words.last?.lowercased(), documentNouns.contains(last) { return false }
        // A bare institution names the speaker within its story ("the military said", "police said");
        // "officials" and "authorities" stay vague.
        if let last = words.last?.lowercased(),
            words.count > 1 ? institutionNouns.contains(last) : bareInstitutions.contains(last)
        {
            return true
        }
        return words.contains { $0.first?.isUppercase == true }
    }

    private static let bareInstitutions: Set<String> = [
        "police", "military", "army", "prosecutors", "government", "ministry", "court",
    ]
    private static let documentNouns: Set<String> = [
        "map", "maps", "figures", "data", "report", "reports", "website", "tally", "count", "estimate", "estimates",
        "survey", "poll", "statement", "records", "filing", "document", "documents", "study",
    ]
    private static let institutionNouns: Set<String> = [
        "ministry", "military", "army", "police", "government", "prosecutors", "prosecutor", "court", "agency",
        "council", "commission", "committee", "spokesperson", "spokesman", "spokeswoman", "minister", "president",
        "governor", "mayor", "embassy", "regulator", "director", "chief", "commander",
    ]

    private static let leadingAdverbials: Set<String> = [
        "and", "but", "so", "meanwhile", "later", "earlier", "last", "this", "next", "on", "in", "at", "during",
        "after", "before", "since", "while", "when", "speaking", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
    private static let clauseWords: Set<String> = [
        "is", "are", "was", "were", "which", "whom", "whose", "where", "who",
        "said", "says", "told", "after", "before", "because", "since", "until", "that",
    ]
    private static let trailingConnectives: Set<String> = ["meanwhile", "however", "too", "also", "instead"]
    private static let honorifics: Set<String> = ["mr", "mrs", "ms", "dr", "sir", "prof"]
    private static let subordinators: Set<String> = ["while", "when", "although", "though", "if"]
    private static let danglingWords: Set<String> = [
        "which", "who", "whom", "whose", "that", "and", "or", "but", "she", "he", "they", "it", "her", "his", "their",
        "its", "is", "are", "was", "were", "be", "been", "being",
    ]
}
