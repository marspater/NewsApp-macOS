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
    case speakerMismatch(claimSpeaker: String, passageID: String)
    case misquotedReport(quote: String, passageID: String)
    case actionMismatch(claimAction: String, passageID: String)
    case quotationAsFact(passageID: String)
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
        if let speaker = mismatchedSpeaker(statement: fact.text, passageText: passage.text) {
            failures.append(.speakerMismatch(claimSpeaker: speaker, passageID: passage.id))
        }
        if let quote = misquotedReport(statement: fact.text, passageText: passage.text) {
            failures.append(.misquotedReport(quote: quote, passageID: passage.id))
        }
        if let action = unsupportedAction(statement: fact.text, passageText: passage.text) {
            failures.append(.actionMismatch(claimAction: action, passageID: passage.id))
        }
        if restatesQuotationAsFact(statement: fact.text, passageText: passage.text) {
            failures.append(.quotationAsFact(passageID: passage.id))
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
            if !containsNumber(normalizeText(num), in: normalizedPassage) {
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
            // Whole words: "reinstated" does not contain the verb "stated".
            if let range = statement.range(
                of: #"\b"# + pattern + #"\b"#, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive])
            {
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

    // MARK: - Reported Speech Helpers

    private static let reportingVerbs: Set<String> = [
        "said", "says", "told", "tells", "called", "calls", "asked", "asks", "spoke", "speaks", "stated", "states",
        "declared", "declares", "shouted", "wrote", "writes", "explained", "explains", "added", "adds", "warned",
        "warns", "remarked", "hailed", "promised", "promises", "announced", "announces", "claimed", "claims",
        "alleged", "alleges", "insisted", "insists", "argued", "argues", "reported", "reports", "accused", "accuses",
        "denied", "denies", "acknowledged", "acknowledges", "confirmed", "confirms", "according",
    ]

    /// Roles that identify a speaker even without a name: "the regional prosecutor's office said".
    private static let speakerRoles: Set<String> = [
        "spokesperson", "spokesman", "spokeswoman", "minister", "ministry", "president", "official", "officials",
        "office", "police", "prosecutor", "prosecutors", "army", "military", "government", "commander", "governor",
        "mayor", "chief", "director", "agency", "court", "judge", "authorities", "department", "council",
    ]

    /// Capitalized at the start of a sentence without naming anyone.
    private static let capitalizedFunctionWords: Set<String> = [
        "the", "a", "an", "he", "she", "they", "it", "we", "i", "you", "this", "that", "these", "those", "his",
        "her", "their", "its", "our", "my", "your", "in", "on", "at", "but", "and", "after", "before", "when",
        "while", "as", "for", "with", "by", "from", "of", "to", "if", "there", "some", "many", "monday", "tuesday",
        "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private static let unquotedFirstPerson: Set<String> = [
        "we", "We", "our", "Our", "ours", "us", "my", "My", "me", "myself", "ourselves",
    ]

    private static let firstPersonPronouns: Set<String> = [
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves",
    ]

    /// Straight or curly double quotes, or single quotes that are not apostrophes inside a word ("Thursday's").
    /// Quote characters are escaped so static analysers do not read the apostrophe as an unterminated literal.
    private static let quotationRegex = try? NSRegularExpression(
        pattern:
            #"[\x{22}\x{201C}]([^\x{22}\x{201D}]+)[\x{22}\x{201D}]|(?<![\p{L}\p{N}])[\x{27}\x{2018}]([^\x{27}\x{2019}]+)[\x{27}\x{2019}](?![\p{L}\p{N}])"#
    )

    /// Case-preserving words, so proper names stay recognisable.
    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Proper names and speaker roles among `words`: whom a reporting verb can point at.
    private static func speakerWords(_ words: some Sequence<String>) -> [String] {
        words.filter { word in
            let lower = word.lowercased()
            if speakerRoles.contains(lower) { return true }
            return word.first?.isUppercase == true && !capitalizedFunctionWords.contains(lower)
                && !reportingVerbs.contains(lower)
        }
    }

    /// A reporting verb together with an identified speaker; "he said" alone does not identify anyone.
    private static func hasReportingConstruction(_ words: [String]) -> Bool {
        !reportingVerbs.isDisjoint(with: words.map { $0.lowercased() }) && !speakerWords(words).isEmpty
    }

    // MARK: - Detached Quotation Verification

    private static func verifyDetachedQuotation(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        isDetachedQuotation(statement) ? .detachedQuotation(claimText: statement, passageID: passage.id) : nil
    }

    /// Shared with `OverviewQualityAuditor`. A claim that is only a quotation, or quotes someone in the first
    /// person without saying who outside the quotation marks, reads as dialogue detached from its speaker.
    static func isDetachedQuotation(_ statement: String) -> Bool {
        guard let regex = quotationRegex else { return false }
        let ns = statement as NSString
        let range = NSRange(location: 0, length: ns.length)
        let quotes = regex.matches(in: statement, range: range).compactMap { match in
            [match.range(at: 1), match.range(at: 2)].first { $0.location != NSNotFound }.map(ns.substring(with:))
        }
        // Speech copied without its quotation marks: "we have confirmed…" with no speaker. Case matters, so "US"
        // and "World War I" are not pronouns.
        guard !quotes.isEmpty else {
            let claimWords = words(statement)
            return claimWords.contains { unquotedFirstPerson.contains($0) } && reportedSpeakers(claimWords).isEmpty
        }
        let outside = words(regex.stringByReplacingMatches(in: statement, range: range, withTemplate: " "))
        if outside.isEmpty { return true }
        let quotesFirstPerson = quotes.contains { !firstPersonPronouns.isDisjoint(with: tokenize($0)) }
        return quotesFirstPerson && !hasReportingConstruction(outside)
    }

    // MARK: - Dropped Attribution Verification

    private static let motivePhrases = ["in order to", "feared", "sought to"]
    private static let militaryClaimPattern =
        #"\b(destroyed|\d+.*targets (had been|were) destroyed|intercepted|forces intercepted)\b"#
    private static let closurePhrases = ["ceasing operations", "closing its operations", "ended its duties"]

    private static func verifyDroppedAttribution(
        statement: String,
        passage: EvidencePassage
    ) -> ClaimVerificationFailureReason? {
        droppedAttributionSpeaker(statement: statement, passageText: passage.text).map {
            .droppedAttribution(speaker: $0, claimText: statement, passageID: passage.id)
        }
    }

    /// Shared with `OverviewQualityAuditor`. When a claim restates a motive, battlefield result or contested
    /// closure that the closest passage sentence attributes to a speaker, the claim must keep a reporting verb
    /// and that speaker; a generic stand-in such as "officials" for a named general does not count. Returns
    /// the dropped speaker.
    static func droppedAttributionSpeaker(statement: String, passageText: String) -> String? {
        let statementLower = statement.lowercased()
        let contested =
            motivePhrases.contains { statementLower.contains($0) }
            || statementLower.range(of: militaryClaimPattern, options: .regularExpression) != nil
            || closurePhrases.contains { statementLower.contains($0) }
        guard contested else { return nil }

        let sentence = words(closestSentence(to: statement, in: passageText))
        var speaker: [String] = []
        for (index, word) in sentence.enumerated() where reportingVerbs.contains(word.lowercased()) {
            // "General Jordan Cole said", else "said General Jordan Cole" or "according to the agency".
            let before = speakerWords(sentence[max(0, index - 6)..<index])
            let after = speakerWords(sentence[(index + 1)..<min(index + 7, sentence.count)])
            speaker += word.lowercased() == "according" || before.isEmpty ? after : before
        }
        guard !speaker.isEmpty else { return nil }

        let claimWords = words(statement)
        let claimLower = Set(claimWords.map { $0.lowercased() })
        if hasReportingConstruction(claimWords), !claimLower.isDisjoint(with: speaker.map { $0.lowercased() }) {
            return nil
        }
        var seen = Set<String>()
        return speaker.filter { seen.insert($0).inserted }.joined(separator: " ")
    }

    /// The passage sentence sharing the most words with the claim; attribution elsewhere in a long
    /// passage says nothing about this claim.
    private static func closestSentence(to statement: String, in passage: String) -> String {
        let claim = Set(tokenize(statement))
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = passage
        return tokenizer.tokens(for: passage.startIndex..<passage.endIndex).map { String(passage[$0]) }
            .max { claim.intersection(tokenize($0)).count < claim.intersection(tokenize($1)).count } ?? passage
    }

    // MARK: - Speaker, Quotation and Action Verification

    /// Speakers named within four words of each reporting verb: before it ("the Israeli military said"), else after it
    /// ("said Ford", "according to the health ministry"). Lowercased; "he said" names no one.
    private static func reportedSpeakers(_ words: [String]) -> Set<String> {
        var speakers = Set<String>()
        for (index, word) in words.enumerated() where reportingVerbs.contains(word.lowercased()) {
            let before = speakerWords(words[max(0, index - 4)..<index])
            let after = speakerWords(words[min(index + 1, words.count)..<min(index + 5, words.count)])
            speakers.formUnion(
                (word.lowercased() == "according" || before.isEmpty ? after : before).map { $0.lowercased() })
        }
        return speakers
    }

    /// A claim that reports speech must name a speaker the closest passage sentence names, or any passage sentence
    /// when that one reports none: "Carney said" for "Ford said", or "Hamas said" for "the military said Hamas
    /// fighters attacked", is a renamed speaker. Returns the claim's speaker.
    static func mismatchedSpeaker(statement: String, passageText: String) -> String? {
        let claimSpeakers = reportedSpeakers(words(statement))
        guard !claimSpeakers.isEmpty else { return nil }
        var passageSpeakers = reportedSpeakers(words(closestSentence(to: statement, in: passageText)))
        if passageSpeakers.isEmpty { passageSpeakers = reportedSpeakers(words(passageText)) }
        return claimSpeakers.isDisjoint(with: passageSpeakers) ? claimSpeakers.sorted().joined(separator: " ") : nil
    }

    private static func quotations(_ text: String) -> [String] {
        guard let regex = quotationRegex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            [match.range(at: 1), match.range(at: 2)].first { $0.location != NSNotFound }.map(ns.substring(with:))
        }
    }

    /// A claim quotation holding a reporting clause ("will not give up Pokrovsk, the commander said,") must sit inside
    /// one passage quotation; otherwise the claim moved the speaker into the quoted words. Returns that quotation.
    static func misquotedReport(statement: String, passageText: String) -> String? {
        let passageQuotes = quotations(passageText).map { " " + tokenize($0).joined(separator: " ") + " " }
        return quotations(statement).first { quote in
            let quoteWords = words(quote)
            guard hasReportingConstruction(quoteWords) else { return false }
            let folded = " " + tokenize(quote).joined(separator: " ") + " "
            return !passageQuotes.contains { $0.contains(folded) }
        }
    }

    /// A claim that copies eight or more words of a passage quotation must keep the quotation marks or name a
    /// speaker: "These are the first elections … whose outcome is uncertain" restates an analyst's assessment as fact.
    static func restatesQuotationAsFact(statement: String, passageText: String) -> Bool {
        guard quotations(statement).isEmpty, !hasReportingConstruction(words(statement)) else { return false }
        let claim = " " + tokenize(statement).joined(separator: " ") + " "
        return quotations(passageText).contains { quote in
            let quoteWords = tokenize(quote)
            guard quoteWords.count >= 8 else { return false }
            return (0...(quoteWords.count - 8)).contains { start in
                claim.contains(" " + quoteWords[start..<start + 8].joined(separator: " ") + " ")
            }
        }
    }

    /// Legal and physical actions a summary must not upgrade: a summons is not an arrest.
    private static let actionRegex = try? NSRegularExpression(
        pattern:
            #"\b(arrest|detain|charge|indict|convict|sentence|jail|imprison|summon|kill|wound|injure|resign|dismiss|expel|deport|execute|sue)(?:s|d|ed|es|ing|led)?\b"#,
        options: [.caseInsensitive])

    private static func actions(_ text: String) -> Set<String> {
        guard let actionRegex else { return [] }
        let ns = text as NSString
        return Set(
            actionRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).lowercased()
            })
    }

    /// The first legal or physical action in the claim that the passage never reports in any form.
    static func unsupportedAction(statement: String, passageText: String) -> String? {
        actions(statement).subtracting(actions(passageText)).sorted().first
    }

    // MARK: - Citation Grounding Verification

    private static func verifyCitationGrounding(
        statement: String,
        passage: EvidencePassage
    ) -> [ClaimVerificationFailureReason] {
        ungroundedCitationTerms(statement: statement, passageText: passage.text).map {
            .ungroundedCitation(missingToken: $0, passageID: passage.id)
        }
    }

    /// Shared with `OverviewQualityAuditor`: places the claim names that the cited passage never mentions.
    /// Full stops are ignored so "US" matches "U.S.".
    static func ungroundedCitationTerms(statement: String, passageText: String) -> [String] {
        func nameTokens(_ text: String) -> [String] { tokenize(text.replacingOccurrences(of: ".", with: "")) }
        let passage = " " + nameTokens(passageText).joined(separator: " ") + " "
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = statement
        var missing: [String] = []
        tagger.enumerateTags(
            in: statement.startIndex..<statement.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            let place = nameTokens(String(statement[range])).joined(separator: " ")
            if tag == .placeName, !place.isEmpty, !passage.contains(" \(place) ") { missing.append(place) }
            return true
        }
        return missing
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

    /// A number not part of a longer one: "14" is not in "140", "2014" or "1.14", but is in "$14m".
    private static func containsNumber(_ number: String, in text: String) -> Bool {
        text.range(
            of: #"(?<![\d.,])"# + NSRegularExpression.escapedPattern(for: number) + #"(?![\d]|[.,]\d)"#,
            options: .regularExpression) != nil
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

    /// Folded words, so a claim matches its passage across case and accents. `words` above keeps case on purpose.
    private static func tokenize(_ text: String) -> [String] {
        MuteRules.foldedWords(text)
    }
}
