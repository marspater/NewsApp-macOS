import Foundation
import NaturalLanguage

// MARK: - Quality Gate Types

/// Kind of critical error that blocks generative overview release.
public enum CriticalErrorKind: String, Codable, Sendable, Equatable, Hashable {
    case numberMismatch
    case dateMismatch
    case attributionError
}

/// Audit status for a single factual claim in an overview document.
public enum ClaimSupportStatus: Sendable, Equatable {
    case supported
    case unsupported(reason: String)
    case criticalError(kind: CriticalErrorKind, detail: String)
}

/// Result of auditing a single claim against cited source passages and control expectations.
public struct ClaimAuditResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let claimText: String
    public let citationIDs: [String]
    public let status: ClaimSupportStatus
    public let auditedPassageIDs: [String]

    public var isSupported: Bool {
        if case .supported = status { return true }
        return false
    }

    public var criticalErrorKind: CriticalErrorKind? {
        if case .criticalError(let kind, _) = status { return kind }
        return nil
    }

    public init(
        id: String,
        claimText: String,
        citationIDs: [String],
        status: ClaimSupportStatus,
        auditedPassageIDs: [String]
    ) {
        self.id = id
        self.claimText = claimText
        self.citationIDs = citationIDs
        self.status = status
        self.auditedPassageIDs = auditedPassageIDs
    }
}

/// Grounds one overview claim in its cited passages: numbers, dates, citation terms and attribution must come from
/// the passage. `OverviewComposer` runs it on every drafted sentence. The reports, control samples, timing tracker
/// and release gate that audit whole overviews live in the test build (`Tests/OverviewQualityAudit.swift`, #549).
// MARK: - Overview Quality Auditor

/// Evaluates factual grounding of overview claims against source passages and labeled control samples.
/// Enforces the release gate: critical number, date, or attribution errors block the generative release.
public struct OverviewQualityAuditor: Sendable {

    private static let numberPattern: NSRegularExpression = {
        let pattern =
            #"(?:[\$€£¥])?\s*\b\d+(?:[.,]\d+)*(?:\s*(?:billion|million|trillion|thousand|gigawatts?|megawatts?|%|percent))?\b"#
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) ?? NSRegularExpression()
    }()

    private static let monthPattern: NSRegularExpression = {
        let pattern = #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\b"#
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) ?? NSRegularExpression()
    }()

    private static let yearPattern: NSRegularExpression = {
        let pattern = #"\b(?:19|20)\d{2}\b"#
        return (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }()

    private static let attributionPhrasePattern: NSRegularExpression = {
        let pattern = #"(?i)\b(?:according to|reported by|stated by|announced by|said by)\s+([A-Z][a-zA-Z\s]{2,30})\b"#
        return (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }()

    // MARK: - Single Claim Audit

    /// Audits a single overview factual claim against the cited evidence passages.
    public static func auditClaim(
        _ claim: OverviewFact,
        citations: [String: OverviewCitation],
        passages: [EvidencePassage]
    ) -> ClaimAuditResult {
        guard !claim.citationIDs.isEmpty else {
            return ClaimAuditResult(
                id: claim.id,
                claimText: claim.text,
                citationIDs: [],
                status: .unsupported(reason: "Claim has no associated citation IDs"),
                auditedPassageIDs: []
            )
        }

        let passagesByID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        var resolvedPassages: [EvidencePassage] = []
        var auditedPassageIDs: [String] = []

        // 1. Verify citations and quote fidelity
        for citationID in claim.citationIDs {
            guard let citation = citations[citationID] else {
                return ClaimAuditResult(
                    id: claim.id,
                    claimText: claim.text,
                    citationIDs: claim.citationIDs,
                    status: .unsupported(reason: "Citation ID '\(citationID)' not found in document citations"),
                    auditedPassageIDs: auditedPassageIDs
                )
            }

            guard let passage = passagesByID[citation.passageID] else {
                return ClaimAuditResult(
                    id: claim.id,
                    claimText: claim.text,
                    citationIDs: claim.citationIDs,
                    status: .unsupported(
                        reason: "Cited passage ID '\(citation.passageID)' not found in source passages"),
                    auditedPassageIDs: auditedPassageIDs
                )
            }

            auditedPassageIDs.append(passage.id)
            resolvedPassages.append(passage)

            // Quote must be verbatim in the passage (case/diacritic insensitive)
            let normPassage = passage.text.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let normQuote = citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

            if !normQuote.isEmpty && !normPassage.contains(normQuote) {
                return ClaimAuditResult(
                    id: claim.id,
                    claimText: claim.text,
                    citationIDs: claim.citationIDs,
                    status: .criticalError(
                        kind: .attributionError,
                        detail: "Citation quote '\(citation.quote)' is not verbatim in passage '\(passage.id)'"
                    ),
                    auditedPassageIDs: auditedPassageIDs
                )
            }
        }

        let combinedPassageText = resolvedPassages.map(\.text).joined(separator: "\n")
        let normalizedPassage = combinedPassageText.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        // 1b. Check Citation Grounding (Unsupported)
        if let citationError = checkCitationGrounding(claimText: claim.text, passageText: combinedPassageText) {
            return ClaimAuditResult(
                id: claim.id,
                claimText: claim.text,
                citationIDs: claim.citationIDs,
                status: .unsupported(reason: citationError),
                auditedPassageIDs: auditedPassageIDs
            )
        }

        // 2. Check Number Fidelity (Critical Number Mismatch)
        if let numberError = checkNumberFidelity(claimText: claim.text, normalizedPassage: normalizedPassage) {
            return ClaimAuditResult(
                id: claim.id,
                claimText: claim.text,
                citationIDs: claim.citationIDs,
                status: .criticalError(kind: .numberMismatch, detail: numberError),
                auditedPassageIDs: auditedPassageIDs
            )
        }

        // 3. Check Date Fidelity (Critical Date Mismatch)
        if let dateError = checkDateFidelity(claimText: claim.text, normalizedPassage: normalizedPassage) {
            return ClaimAuditResult(
                id: claim.id,
                claimText: claim.text,
                citationIDs: claim.citationIDs,
                status: .criticalError(kind: .dateMismatch, detail: dateError),
                auditedPassageIDs: auditedPassageIDs
            )
        }

        // 4. Check Attribution Fidelity (Critical Attribution Error)
        if let attributionError = checkAttributionFidelity(
            claimText: claim.text, passageText: combinedPassageText, normalizedPassage: normalizedPassage)
        {
            return ClaimAuditResult(
                id: claim.id,
                claimText: claim.text,
                citationIDs: claim.citationIDs,
                status: .criticalError(kind: .attributionError, detail: attributionError),
                auditedPassageIDs: auditedPassageIDs
            )
        }

        return ClaimAuditResult(
            id: claim.id,
            claimText: claim.text,
            citationIDs: claim.citationIDs,
            status: .supported,
            auditedPassageIDs: auditedPassageIDs
        )
    }

    // MARK: - Private Fidelity Helpers

    private static func checkNumberFidelity(claimText: String, normalizedPassage: String) -> String? {
        let nsClaim = claimText as NSString
        let matches = numberPattern.matches(in: claimText, range: NSRange(location: 0, length: nsClaim.length))

        // Create a passage variant with thousands commas removed from numbers (e.g. "12,000" -> "12000")
        let passageWithoutThousandsCommas = normalizedPassage.replacingOccurrences(
            of: #"(?<=\d),(?=\d{3}\b)"#,
            with: "",
            options: .regularExpression
        )

        for match in matches {
            let matchedStr = nsClaim.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract the core number token (preserving decimal points, removing currency symbols and suffix scale words)
            let coreNumber =
                matchedStr
                .replacingOccurrences(of: #"^[\$€£¥]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: #"\s*(?:billion|million|trillion|thousand|gigawatts?|megawatts?|%|percent)$"#, with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !coreNumber.isEmpty else { continue }

            let coreWithoutCommas = coreNumber.replacingOccurrences(of: ",", with: "")

            // Check if core number appears in passage directly (e.g. "12,000" or "1.5")
            // or in passage without commas (e.g. "12000")
            let foundInPassage =
                normalizedPassage.contains(coreNumber)
                || passageWithoutThousandsCommas.contains(coreWithoutCommas)

            if !foundInPassage {
                return
                    "Claim asserts quantity '\(matchedStr)' with value '\(coreNumber)' not supported by cited passage"
            }

            // If a scale unit is present (e.g. billion, million, gigawatt, %), verify it too
            let lowerMatch = matchedStr.lowercased()
            for scale in ["billion", "million", "trillion", "thousand", "gigawatt", "megawatt", "%", "percent"] {
                if lowerMatch.contains(scale) && !normalizedPassage.contains(scale) {
                    return "Claim asserts scale '\(scale)' in quantity '\(matchedStr)' not supported by cited passage"
                }
            }
        }
        return nil
    }

    private static func checkDateFidelity(claimText: String, normalizedPassage: String) -> String? {
        let nsClaim = claimText as NSString

        // Check Month names
        let monthMatches = monthPattern.matches(in: claimText, range: NSRange(location: 0, length: nsClaim.length))
        for match in monthMatches {
            let month = nsClaim.substring(with: match.range).lowercased()
            if !normalizedPassage.contains(month) {
                return "Claim asserts month '\(month.capitalized)' not supported by cited passage"
            }
        }

        // Check 4-digit Years
        let yearMatches = yearPattern.matches(in: claimText, range: NSRange(location: 0, length: nsClaim.length))
        for match in yearMatches {
            let year = nsClaim.substring(with: match.range)
            if !normalizedPassage.contains(year) {
                return "Claim asserts year '\(year)' not supported by cited passage"
            }
        }

        return nil
    }

    private static func checkCitationGrounding(claimText: String, passageText: String) -> String? {
        OverviewClaimVerifier.ungroundedCitationTerms(statement: claimText, passageText: passageText).first
            .map { "Claim names place '\($0)' not mentioned in cited passage" }
    }

    /// `passageText` keeps capitals so speaker names stay recognisable; `normalizedPassage` is folded.
    private static func checkAttributionFidelity(
        claimText: String, passageText: String, normalizedPassage: String
    ) -> String? {
        if OverviewClaimVerifier.isDetachedQuotation(claimText) {
            return "Claim contains detached or unattributed quotation: '\(claimText)'"
        }
        if let speaker = OverviewClaimVerifier.droppedAttributionSpeaker(
            statement: claimText, passageText: passageText)
        {
            return "Claim drops attribution to \(speaker): '\(claimText)'"
        }

        let nsClaim = claimText as NSString

        // Check explicit attribution phrases: "according to X", "reported by X", etc.
        let phraseMatches = attributionPhrasePattern.matches(
            in: claimText, range: NSRange(location: 0, length: nsClaim.length))
        for match in phraseMatches {
            if match.numberOfRanges > 1 {
                let entity = nsClaim.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let normEntity = entity.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if !normEntity.isEmpty && !normalizedPassage.contains(normEntity) {
                    return "Claim attributes statement to '\(entity)' not present in cited passage"
                }
            }
        }

        // Check Named Entities via NLTagger (personalName and organizationName)
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = claimText
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var entityError: String? = nil

        tagger.enumerateTags(
            in: claimText.startIndex..<claimText.endIndex, unit: .word, scheme: .nameType, options: options
        ) { tag, tokenRange in
            if let tag = tag, tag == .personalName || tag == .organizationName {
                let entity = String(claimText[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let normEntity = entity.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if normEntity.count > 3 && !normalizedPassage.contains(normEntity) {
                    // Check if primary name component (e.g. family name) is in passage
                    let components = normEntity.split(separator: " ").map(String.init)
                    let anyFound = components.contains { $0.count > 2 && normalizedPassage.contains($0) }
                    if !anyFound {
                        entityError = "Claim refers to entity '\(entity)' not mentioned in cited passage"
                        return false
                    }
                }
            }
            return true
        }

        return entityError
    }
}
