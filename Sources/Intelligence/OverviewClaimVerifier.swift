import Foundation

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
    case emptyClaim
}

/// Verification result for a single claim/fact in an overview.
public struct ClaimVerificationResult: Sendable, Equatable {
    public let factID: String
    public let statement: String
    public let isValid: Bool
    public let failureReasons: [ClaimVerificationFailureReason]

    public init(factID: String, statement: String, isValid: Bool, failureReasons: [ClaimVerificationFailureReason] = []) {
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
            failures.append(contentsOf: verifyCitation(citationID, fact: fact, overview: overview, passagesByID: passagesByID))
        }

        return ClaimVerificationResult(
            factID: fact.id,
            statement: fact.text,
            isValid: failures.isEmpty,
            failureReasons: failures
        )
    }

    private static func verifyCitation(_ citationID: String, fact: OverviewFact, overview: EventOverviewDocument,
                                       passagesByID: [String: EvidencePassage]) -> [ClaimVerificationFailureReason] {
        guard let citation = overview.citations[citationID] else { return [.missingCitation(citationID: citationID)] }
        guard let passage = passagesByID[citation.passageID], citation.articleID == passage.articleID,
              citation.passageFingerprint == passage.fingerprint else { return [.missingPassage(passageID: citation.passageID)] }
        var failures = verifyQuoteGrounding(quote: citation.quote, passage: passage)
        failures.append(contentsOf: verifyNumbersAndEntities(statement: fact.text, passage: passage))
        if let failure = verifyNegationPreservation(statement: fact.text, passage: passage) { failures.append(failure) }
        if let failure = verifyAttributionPreservation(statement: fact.text, passage: passage) { failures.append(failure) }
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
        for curr in currencies {
            if !containsCurrency(curr, in: passage.text) {
                reasons.append(.currencyMismatch(claimCurrency: curr, passageID: passage.id))
            }
        }

        // 3. Units
        let units = extractUnits(from: statement)
        for unit in units {
            if !containsUnit(unit, in: passage.text) {
                reasons.append(.unitMismatch(claimUnit: unit, passageID: passage.id))
            }
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
        "не", "ні", "ніколи", "жоден", "відмовився", "відхилив", "заперечив"
    ]

    private static func verifyNegationPreservation(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        let claimTokens = tokenize(statement)
        let passageTokens = tokenize(passage.text)

        let claimHasNegation = claimTokens.contains(where: { negationWords.contains($0) })
        let passageHasNegation = passageTokens.contains(where: { negationWords.contains($0) })

        if claimHasNegation != passageHasNegation {
            return .negationFlipped(claimText: statement, passageID: passage.id)
        }

        return nil
    }

    // MARK: - Attribution Preservation

    private static let attributionPatterns: [String] = [
        "announced", "said", "stated", "claimed", "reported", "according to",
        "повідомило", "заявив", "повідомив", "зазначив", "підкреслив", "за словами", "згідно з"
    ]

    private static func verifyAttributionPreservation(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        let normalizedStatement = statement.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedPassage = passage.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        for pattern in attributionPatterns {
            if let range = normalizedStatement.range(of: pattern) {
                let prefix = String(statement[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let entityCandidate = extractAttributionEntity(from: prefix)

                if !entityCandidate.isEmpty {
                    let normalizedEntity = entityCandidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    if !normalizedPassage.contains(normalizedEntity) {
                        return .attributionMissing(claimAttribution: entityCandidate, passageID: passage.id)
                    }
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

    private static let numbersRegex = try! NSRegularExpression(pattern: #"\b\d+([.,]\d+)?\b"#)
    private static let unitsRegex = try! NSRegularExpression(
        pattern: #"\b(km/h|mph|km|miles|kg|lbs|GB|MB|TB|percent|відсотків|відсотки|відсотка)\b|%"#,
        options: .caseInsensitive
    )
    private static let datesYearRegex = try! NSRegularExpression(pattern: #"\b(19\d\d|20\d\d)\b"#)

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
        for sym in singleCharSymbols {
            if text.contains(sym) {
                results.append(sym)
            }
        }
        let wordCodes = ["USD", "EUR", "GBP", "UAH", "грн"]
        for code in wordCodes {
            if containsWholeWord(code, in: text) {
                results.append(code)
            }
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
