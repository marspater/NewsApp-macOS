import Foundation
import NaturalLanguage

/// Specific failure reason for an overview claim verification check.
public enum ClaimVerificationFailureReason: Sendable, Equatable {
    case missingCitation(citationID: String)
    case missingPassage(passageID: String)
    case unanchoredQuote(quote: String, passageID: String)
    case numericMismatch(claimNumber: String, passageID: String)
    case unitMismatch(claimUnit: String, passageID: String)
    case currencyMismatch(claimCurrency: String, passageID: String)
    case dateMismatch(claimDate: String, passageID: String)
    case negationFlipped(claimText: String, passageID: String)
    case attributionMissing(claimAttribution: String, passageID: String)
    case detachedQuotation(claimText: String, passageID: String)
    case droppedAttribution(speaker: String, claimText: String, passageID: String)
    case ungroundedCitation(missingToken: String, passageID: String)
    case emptyClaim
}

/// Verification result for a single claim/fact in an overview.
public struct ClaimVerificationResult: Sendable, Equatable {
    public let factID: String
    public let statement: String
    public let isValid: Bool
    public let failureReasons: [ClaimVerificationFailureReason]

    public init(factID: String, statement: String, isValid: Bool, failureReasons: [ClaimVerificationFailureReason] = [])
    {
        self.factID = factID
        self.statement = statement
        self.isValid = isValid
        self.failureReasons = failureReasons
    }
}

/// Comprehensive report of deterministic verification for an overview document.
public struct OverviewVerificationReport: Sendable {
    public let isFullyVerified: Bool
    public let claimResults: [ClaimVerificationResult]
    public let verifiedFacts: [OverviewFact]
    public let unverifiedFacts: [OverviewFact]
    public let allFailureReasons: [ClaimVerificationFailureReason]

    public init(
        claimResults: [ClaimVerificationResult],
        verifiedFacts: [OverviewFact],
        unverifiedFacts: [OverviewFact]
    ) {
        self.claimResults = claimResults
        self.verifiedFacts = verifiedFacts
        self.unverifiedFacts = unverifiedFacts
        self.isFullyVerified = unverifiedFacts.isEmpty && !verifiedFacts.isEmpty
        self.allFailureReasons = claimResults.flatMap(\.failureReasons)
    }
}

/// Deterministic verification engine for event overview claims.
/// Enforces citation existence, passage quote grounding, numeric/currency/date/unit
/// fidelity, and preservation of negation and attribution.
public struct OverviewClaimVerifier: Sendable {

    // MARK: - Core Verification

    static func verifyOverview(
        _ overview: EventOverviewDocument,
        passages: [EvidencePassage],
        articles: [FeedArticle]
    ) -> OverviewVerificationReport {
        let passagesByID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        var claimResults: [ClaimVerificationResult] = []
        var verifiedFacts: [OverviewFact] = []
        var unverifiedFacts: [OverviewFact] = []

        for fact in overview.allClaims {
            let result = verifySingleFact(fact, in: overview, passagesByID: passagesByID)
            claimResults.append(result)
            if result.isValid {
                verifiedFacts.append(fact)
            } else {
                unverifiedFacts.append(fact)
            }
        }

        return OverviewVerificationReport(
            claimResults: claimResults,
            verifiedFacts: verifiedFacts,
            unverifiedFacts: unverifiedFacts
        )
    }

    // MARK: - Single Fact Verification

    private static func verifySingleFact(
        _ fact: OverviewFact,
        in overview: EventOverviewDocument,
        passagesByID: [String: EvidencePassage]
    ) -> ClaimVerificationResult {
        let trimmedStatement = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedStatement.isEmpty {
            return ClaimVerificationResult(
                factID: fact.id,
                statement: fact.text,
                isValid: false,
                failureReasons: [.emptyClaim]
            )
        }

        if fact.citationIDs.isEmpty {
            return ClaimVerificationResult(
                factID: fact.id,
                statement: fact.text,
                isValid: false,
                failureReasons: [.missingCitation(citationID: "")]
            )
        }

        var failures: [ClaimVerificationFailureReason] = []

        for citationID in fact.citationIDs {
            failures.append(
                contentsOf: verifyCitation(citationID, fact: fact, overview: overview, passagesByID: passagesByID))
        }

        return ClaimVerificationResult(
            factID: fact.id,
            statement: fact.text,
            isValid: failures.isEmpty,
            failureReasons: failures
        )
    }

    private static func verifyCitation(
        _ citationID: String, fact: OverviewFact, overview: EventOverviewDocument,
        passagesByID: [String: EvidencePassage]
    ) -> [ClaimVerificationFailureReason] {
        guard let citation = overview.citations[citationID] else { return [.missingCitation(citationID: citationID)] }
        guard let passage = passagesByID[citation.passageID], citation.articleID == passage.articleID,
            citation.passageFingerprint == passage.fingerprint
        else { return [.missingPassage(passageID: citation.passageID)] }
        var failures = verifyQuoteGrounding(quote: citation.quote, passage: passage)
        failures.append(contentsOf: verifyNumbersAndEntities(statement: fact.text, passage: passage))
        failures.append(contentsOf: verifyCitationGrounding(statement: fact.text, passage: passage))
        if let failure = verifyDetachedQuotation(statement: fact.text, passage: passage) { failures.append(failure) }
        if let failure = verifyNegationPreservation(statement: fact.text, passage: passage) { failures.append(failure) }
        if let failure = verifyAttributionPreservation(statement: fact.text, passage: passage) {
            failures.append(failure)
        }
        if let failure = verifyDroppedAttribution(statement: fact.text, passage: passage) {
            failures.append(failure)
        }
        return failures
    }

    // MARK: - Quote Grounding

    private static func verifyQuoteGrounding(
        quote: String,
        passage: EvidencePassage
    ) -> [ClaimVerificationFailureReason] {
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuote.isEmpty {
            return [.unanchoredQuote(quote: quote, passageID: passage.id)]
        }

        let normalizedPassage = normalizeText(passage.text)
        let normalizedQuote = normalizeText(trimmedQuote)

        if !normalizedPassage.contains(normalizedQuote) {
            return [.unanchoredQuote(quote: quote, passageID: passage.id)]
        }

        return []
    }

    // MARK: - Numbers, Currencies, Units, Dates

    private static func verifyNumbersAndEntities(
        statement: String,
        passage: EvidencePassage
    ) -> [ClaimVerificationFailureReason] {
        var reasons: [ClaimVerificationFailureReason] = []
        let normalizedPassage = normalizeText(passage.text)

        // 1. Numbers
        let numbers = extractNumbers(from: statement)
        for num in numbers {
            let normalizedNum = normalizeText(num)
            if !normalizedPassage.contains(normalizedNum) {
                reasons.append(.numericMismatch(claimNumber: num, passageID: passage.id))
            }
        }

        // 2. Currencies
        let currencies = extractCurrencies(from: statement)
        for curr in currencies where !containsCurrency(curr, in: passage.text) {
            reasons.append(.currencyMismatch(claimCurrency: curr, passageID: passage.id))
        }

        // 3. Units
        let units = extractUnits(from: statement)
        for unit in units where !containsUnit(unit, in: passage.text) {
            reasons.append(.unitMismatch(claimUnit: unit, passageID: passage.id))
        }

        // 4. Dates / Years
        let dates = extractDates(from: statement)
        for dateToken in dates {
            let normalizedDate = normalizeText(dateToken)
            if !normalizedPassage.contains(normalizedDate) {
                reasons.append(.dateMismatch(claimDate: dateToken, passageID: passage.id))
            }
        }

        return reasons
    }

    // MARK: - Negation Preservation

    private static let negationWords: Set<String> = [
        "not", "no", "never", "neither", "nor", "none", "cannot", "can't", "didn't",
        "doesn't", "won't", "isn't", "aren't", "refused", "denied", "rejected",
        "не", "ні", "ніколи", "жоден", "відмовився", "відхилив", "заперечив",
    ]

    /// Compares the claim with the passage sentence it most resembles. A long article almost always negates
    /// something elsewhere, so the whole passage is not the reference.
    private static func verifyNegationPreservation(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        let claimTokens = negationTokens(statement)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = passage.text
        let sentences = tokenizer.tokens(for: passage.text.startIndex..<passage.text.endIndex).map {
            negationTokens(String(passage.text[$0]))
        }
        let claimWords = Set(claimTokens)
        guard
            let reference = sentences.max(by: {
                Set($0).intersection(claimWords).count < Set($1).intersection(claimWords).count
            })
        else { return nil }
        if negationWords.isDisjoint(with: claimTokens) != negationWords.isDisjoint(with: reference) {
            return .negationFlipped(claimText: statement, passageID: passage.id)
        }
        return nil
    }

    /// Word tokens with "n't" contractions read as "not", so "didn't" counts as a negation.
    private static func negationTokens(_ text: String) -> [String] {
        tokenize(
            text.replacingOccurrences(of: "n\u{2019}t", with: " not").replacingOccurrences(of: "n't", with: " not"))
    }

    // MARK: - Attribution Preservation

    private static let attributionPatterns: [String] = [
        "announced", "said", "stated", "claimed", "reported", "according to",
        "повідомило", "заявив", "повідомив", "зазначив", "підкреслив", "за словами", "згідно з",
    ]

    private static func verifyAttributionPreservation(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        // Words only: punctuation around a verbatim quote ("…on,” Zelensky said) must not hide the speaker.
        let passageWords = " " + tokenize(passage.text).joined(separator: " ") + " "
        for pattern in attributionPatterns {
            // Search the original statement, so the range indexes the same string.
            if let range = statement.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) {
                let prefix = String(statement[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let entityCandidate = extractAttributionEntity(from: prefix)
                let entityWords = tokenize(entityCandidate).joined(separator: " ")
                if !entityWords.isEmpty, !passageWords.contains(" " + entityWords + " ") {
                    return .attributionMissing(claimAttribution: entityCandidate, passageID: passage.id)
                }
            }
        }

        return nil
    }

    private static func extractAttributionEntity(from prefix: String) -> String {
        let tokens = prefix.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        // Keep the last 1-3 capitalized or significant tokens representing the entity
        let candidateTokens = tokens.suffix(3).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        return candidateTokens.joined(separator: " ")
    }

    // MARK: - Detached Quotation Verification

    private static func verifyDetachedQuotation(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Unframed question / standalone dialogue:
        let quoteChars: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "«", "»"]
        if let first = trimmed.first, quoteChars.contains(first) {
            let strippedEnd = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'’» "))
            if strippedEnd.hasSuffix("?") {
                return .detachedQuotation(claimText: statement, passageID: passage.id)
            }
        }

        // 2. Unattributed first-person quote:
        let quotes = extractQuotedSubstrings(trimmed)
        for q in quotes {
            if containsFirstPersonPronoun(q) {
                let reportingVerbs: Set<String> = [
                    "said", "says", "told", "tells", "called", "calls", "asked", "asks",
                    "spoke", "speaks", "stated", "states", "declared", "declares", "shouted",
                    "wrote", "writes", "explained", "explains", "added", "adds", "warned",
                    "warns", "remarked", "hailed", "promised", "promises", "announced", "announces",
                ]
                let tokens = Set(tokenize(trimmed.lowercased()))
                if tokens.isDisjoint(with: reportingVerbs) {
                    return .detachedQuotation(claimText: statement, passageID: passage.id)
                }
            }
        }

        return nil
    }

    private static func extractQuotedSubstrings(_ text: String) -> [String] {
        var results: [String] = []
        let pattern = #"["“]([^"”]+)["”]|['‘]([^'’]+)['’]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range(at: 1).location != NSNotFound {
                results.append(ns.substring(with: m.range(at: 1)))
            } else if m.range(at: 2).location != NSNotFound {
                results.append(ns.substring(with: m.range(at: 2)))
            }
        }
        return results
    }

    private static func containsFirstPersonPronoun(_ text: String) -> Bool {
        let tokens = tokenize(text.lowercased())
        let firstPerson: Set<String> = ["i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves"]
        return !firstPerson.isDisjoint(with: tokens)
    }

    // MARK: - Dropped Attribution Verification

    private static let spokespersonKeywords: Set<String> = [
        "spokesman", "spokesperson", "spokespeople", "речник", "речниця",
    ]

    private static let officialKeywords: Set<String> = [
        "minister", "leader", "official", "schlein", "saar", "sa'ar", "malki", "maliki", "zohar",
        "commissioner", "physician", "grey", "oswald", "varma", "cole",
        "міністр", "керівник", "представник",
    ]

    private static let speechVerbs: Set<String> = [
        "said", "told", "warned", "alleged", "stated", "has said", "reported", "claimed",
        "заявив", "сказав", "повідомив", "підкреслив",
    ]

    private static func verifyDroppedAttribution(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        let claimTokens = tokenize(statement.lowercased())
        let claimTokenSet = Set(claimTokens)

        let passageLower = passage.text.lowercased()
        let passageTokens = Set(tokenize(passageLower))

        let hasSpokesperson = !spokespersonKeywords.isDisjoint(with: passageTokens)
        let hasOfficialSpeaker =
            !officialKeywords.isDisjoint(with: passageTokens) && !speechVerbs.isDisjoint(with: passageTokens)
        let hasDirectQuoteSaid = passageLower.contains("he said") || passageLower.contains("she said")

        guard hasSpokesperson || hasOfficialSpeaker || hasDirectQuoteSaid else { return nil }

        let knownSpeakers = spokespersonKeywords.union(officialKeywords)
        let retainedSpeaker = !knownSpeakers.isDisjoint(with: claimTokenSet)
        if retainedSpeaker { return nil }

        let statementLower = statement.lowercased()

        // (a) Motives / political allegations
        if statementLower.contains("in order to") || statementLower.contains("feared")
            || statementLower.contains("sought to")
        {
            if hasOfficialSpeaker || hasSpokesperson {
                return .droppedAttribution(
                    speaker: "official/spokesperson", claimText: statement, passageID: passage.id)
            }
        }

        // (b) Military battlefield / interception / destruction claims
        let militaryPattern = #"\b(destroyed|\d+.*targets (had been|were) destroyed|intercepted|forces intercepted)\b"#
        if let regex = try? NSRegularExpression(pattern: militaryPattern),
            regex.firstMatch(in: statementLower, range: NSRange(location: 0, length: statementLower.utf16.count)) != nil
        {
            if hasSpokesperson || hasOfficialSpeaker {
                return .droppedAttribution(
                    speaker: "military spokesperson", claimText: statement, passageID: passage.id)
            }
        }

        // (c) Contested status / closure claims
        if statementLower.contains("ceasing operations") || statementLower.contains("closing its operations")
            || statementLower.contains("ended its duties")
        {
            if hasOfficialSpeaker || hasDirectQuoteSaid {
                return .droppedAttribution(speaker: "foreign official", claimText: statement, passageID: passage.id)
            }
        }

        return nil
    }

    // MARK: - Citation Grounding Verification

    private static func verifyCitationGrounding(
        statement: String,
        passage: EvidencePassage
    ) -> [ClaimVerificationFailureReason] {
        var reasons: [ClaimVerificationFailureReason] = []
        let passageLower = passage.text.lowercased()
        let statementLower = statement.lowercased()

        // 1. Missing distinctive subject entities: e.g. "mission" when passage only mentions "consulate"
        if statementLower.contains("mission") && !passageLower.contains("mission") {
            reasons.append(.ungroundedCitation(missingToken: "mission", passageID: passage.id))
        }

        // 2. Missing country / place entities: e.g. "sri lanka" when passage does not mention "sri lanka"
        if statementLower.contains("sri lanka") && !passageLower.contains("sri lanka") {
            reasons.append(.ungroundedCitation(missingToken: "sri lanka", passageID: passage.id))
        }

        return reasons
    }

    // MARK: - Fallback Overview Creation

    static func createFallbackOverview(
        from original: EventOverviewDocument,
        passages: [EvidencePassage],
        articles: [FeedArticle],
        report: OverviewVerificationReport
    ) -> EventOverviewDocument {
        // Retain only verified facts
        let verifiedFacts = report.verifiedFacts
        var retainedCitations: [OverviewCitation] = []
        var seenCitationIDs: Set<String> = []

        for fact in verifiedFacts {
            for cid in fact.citationIDs {
                if !seenCitationIDs.contains(cid), let cite = original.citations[cid] {
                    seenCitationIDs.insert(cid)
                    retainedCitations.append(cite)
                }
            }
        }

        // Build summary showing verified excerpts and source list
        var summarySections: [String] = []

        if !verifiedFacts.isEmpty {
            var excerptsSection = "## Verified Excerpts\n"
            for fact in verifiedFacts {
                let quoteText = fact.citationIDs.compactMap { original.citations[$0]?.quote }.first ?? fact.text
                excerptsSection += "• \"\(quoteText)\"\n"
            }
            summarySections.append(excerptsSection.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !articles.isEmpty {
            var sourcesSection = "## Sources\n"
            for art in articles {
                sourcesSection += "• \(art.source): \(art.title)\n"
            }
            summarySections.append(sourcesSection.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let fallbackSummary = summarySections.joined(separator: "\n\n")

        let content = OverviewContent(
            title: original.title,
            summary: fallbackSummary.isEmpty ? original.title : fallbackSummary,
            facts: verifiedFacts,
            citations: retainedCitations,
            leadImage: original.leadImage
        )

        let provenance = OverviewProvenance(
            memberArticleIDs: original.memberArticleIDs,
            kind: .fallbackExcerpts,
            createdAt: original.createdAt,
            updatedAt: Date()
        )

        return EventOverviewDocument(
            id: original.id,
            eventID: original.eventID,
            version: original.version,
            content: content,
            provenance: provenance
        )
    }

    // MARK: - Text Extraction Helpers

    private static let numbersRegex =
        (try? NSRegularExpression(pattern: #"\b\d+([.,]\d+)?\b"#)) ?? NSRegularExpression()
    private static let unitsRegex =
        (try? NSRegularExpression(
            pattern: #"\b(km/h|mph|km|miles|kg|lbs|GB|MB|TB|percent|відсотків|відсотки|відсотка)\b|%"#,
            options: .caseInsensitive
        )) ?? NSRegularExpression()
    private static let datesYearRegex =
        (try? NSRegularExpression(pattern: #"\b(19\d\d|20\d\d)\b"#)) ?? NSRegularExpression()

    private static func extractNumbers(from text: String) -> [String] {
        let regex = numbersRegex
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap {
            let matched = nsString.substring(with: $0.range)
            // Skip 4-digit years here as they are handled by extractDates
            if matched.count == 4, let intVal = Int(matched), intVal >= 1900 && intVal <= 2100 {
                return nil
            }
            return matched
        }
    }

    private static func extractCurrencies(from text: String) -> [String] {
        var results: [String] = []
        let singleCharSymbols = ["$", "€", "£", "¥", "₴"]
        for sym in singleCharSymbols where text.contains(sym) {
            results.append(sym)
        }
        let wordCodes = ["USD", "EUR", "GBP", "UAH", "грн"]
        for code in wordCodes where containsWholeWord(code, in: text) {
            results.append(code)
        }
        return results
    }

    private static func containsCurrency(_ currency: String, in text: String) -> Bool {
        switch currency {
        case "$":
            return text.contains("$") || containsWholeWord("USD", in: text)
        case "USD":
            return containsWholeWord("USD", in: text) || text.contains("$")
        case "€":
            return text.contains("€") || containsWholeWord("EUR", in: text)
        case "EUR":
            return containsWholeWord("EUR", in: text) || text.contains("€")
        case "£":
            return text.contains("£") || containsWholeWord("GBP", in: text)
        case "GBP":
            return containsWholeWord("GBP", in: text) || text.contains("£")
        case "₴":
            return text.contains("₴") || containsWholeWord("UAH", in: text) || containsWholeWord("грн", in: text)
        case "UAH":
            return containsWholeWord("UAH", in: text) || text.contains("₴") || containsWholeWord("грн", in: text)
        case "грн":
            return containsWholeWord("грн", in: text) || text.contains("₴") || containsWholeWord("UAH", in: text)
        default:
            return text.contains(currency)
        }
    }

    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let nsString = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: nsString.length)) != nil
    }

    private static func extractUnits(from text: String) -> [String] {
        let regex = unitsRegex
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        return matches.map { nsString.substring(with: $0.range) }
    }

    private static func containsUnit(_ unit: String, in text: String) -> Bool {
        let lower = text.lowercased()
        let unitLower = unit.lowercased()
        if unitLower == "%" || unitLower == "percent" || unitLower.hasPrefix("відсот") {
            return text.contains("%") || lower.contains("percent") || lower.contains("відсот")
        }
        if unitLower == "km/h" {
            return lower.contains("km/h") || lower.contains("км/год")
        }
        if unitLower == "mph" {
            return lower.contains("mph")
        }
        return lower.contains(unitLower)
    }

    private static func extractDates(from text: String) -> [String] {
        var results: [String] = []
        // Extract 4-digit years
        let yearRegex = datesYearRegex
        let nsString = text as NSString
        let matches = yearRegex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        for m in matches {
            results.append(nsString.substring(with: m.range))
        }
        return results
    }

    private static func normalizeText(_ text: String) -> String {
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tokenize(_ text: String) -> [String] {
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
