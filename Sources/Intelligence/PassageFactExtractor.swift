import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// A raw fact candidate proposed by an extraction model or parser before deterministic validation.
public struct RawFactCandidate: Sendable, Codable, Hashable {
    public let statement: String
    public let passageID: String
    public let quote: String

    public init(statement: String, passageID: String, quote: String) {
        self.statement = statement
        self.passageID = passageID
        self.quote = quote
    }
}

/// A validated, passage-anchored fact guaranteed to reference an existing passage and grounded quote.
public struct PassageAnchoredFact: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let statement: String
    public let passageID: String
    public let quote: String
    public let articleID: String

    public init(
        id: String = UUID().uuidString,
        statement: String,
        passageID: String,
        quote: String,
        articleID: String
    ) {
        self.id = id
        self.statement = statement
        self.passageID = passageID
        self.quote = quote
        self.articleID = articleID
    }
}

/// Specific reason why a candidate fact was rejected during deterministic validation.
public enum FactExtractionRejectionReason: Sendable, Equatable {
    case missingPassageID(String)
    case emptyStatement
    case emptyQuote
    case unanchoredQuote(quote: String, passageID: String)
}

/// Diagnostic outcome of validating candidate facts against stored evidence passages.
public struct FactExtractionDiagnostic: Sendable {
    public let candidateCount: Int
    public let acceptedFacts: [PassageAnchoredFact]
    public let rejectedFacts: [(statement: String, reason: FactExtractionRejectionReason)]

    public var isAllAnchored: Bool {
        rejectedFacts.isEmpty && acceptedFacts.count == candidateCount
    }

    public init(
        candidateCount: Int,
        acceptedFacts: [PassageAnchoredFact],
        rejectedFacts: [(statement: String, reason: FactExtractionRejectionReason)]
    ) {
        self.candidateCount = candidateCount
        self.acceptedFacts = acceptedFacts
        self.rejectedFacts = rejectedFacts
    }
}

// MARK: - Foundation Models Typed Schemas

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    public struct GenerablePassageFactItem: Sendable, Codable {
        @Guide(
            description:
                "A single atomic, evidence-backed factual statement derived strictly from the referenced passage.")
        public var statement: String

        @Guide(description: "The exact passage_id identifier from which this statement was extracted.")
        public var passageID: String

        @Guide(description: "The exact verbatim phrase or sentence quote from the passage supporting the statement.")
        public var quote: String
    }

    @available(macOS 26.0, *)
    @Generable
    public struct GenerablePassageFactExtraction: Sendable, Codable {
        @Guide(
            description:
                "List of atomic facts extracted from the provided evidence passages. Every fact must reference a valid passage ID."
        )
        public var facts: [GenerablePassageFactItem]
    }
#endif

// MARK: - Passage Fact Validator

/// Validates candidate facts against input passages, deterministically rejecting phantom IDs and ungrounded claims.
public struct PassageFactValidator: Sendable {
    /// Validates raw candidate facts against the provided evidence passages.
    ///
    /// - Parameters:
    ///   - candidates: Candidate facts proposed by model or heuristic extraction.
    ///   - passages: Valid evidence passages available in the cluster context.
    /// - Returns: Diagnostic containing strictly validated facts and specific rejection reasons.
    public static func validateCandidates(
        _ candidates: [RawFactCandidate],
        against passages: [EvidencePassage]
    ) -> FactExtractionDiagnostic {
        let passagesByID = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0) })
        var accepted: [PassageAnchoredFact] = []
        var rejected: [(statement: String, reason: FactExtractionRejectionReason)] = []

        for (index, candidate) in candidates.enumerated() {
            let trimmedStatement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedQuote = candidate.quote.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let passage = passagesByID[candidate.passageID] else {
                rejected.append((candidate.statement, .missingPassageID(candidate.passageID)))
                continue
            }

            guard !trimmedStatement.isEmpty else {
                rejected.append((candidate.statement, .emptyStatement))
                continue
            }

            guard !trimmedQuote.isEmpty else {
                rejected.append((candidate.statement, .emptyQuote))
                continue
            }

            // Case and diacritic insensitive containment check
            let normalizedPassageText = passage.text.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let normalizedQuote = trimmedQuote.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

            guard normalizedPassageText.contains(normalizedQuote) else {
                rejected.append(
                    (candidate.statement, .unanchoredQuote(quote: candidate.quote, passageID: candidate.passageID)))
                continue
            }

            let factID = "fact_\(passage.id)_\(index + 1)"
            let fact = PassageAnchoredFact(
                id: factID,
                statement: trimmedStatement,
                passageID: passage.id,
                quote: trimmedQuote,
                articleID: passage.articleID
            )
            accepted.append(fact)
        }

        return FactExtractionDiagnostic(
            candidateCount: candidates.count,
            acceptedFacts: accepted,
            rejectedFacts: rejected
        )
    }
}

// MARK: - Passage Fact Extractor

/// Extracts atomic facts from evidence passages as a distinct stage before narrative summarization.
public struct PassageFactExtractor: Sendable {
    /// Builds the structured prompt for guided fact extraction with security boundaries.
    public static func buildFactExtractionPrompt(passages: [EvidencePassage]) -> String {
        let framedPassages = GenerationPromptDefense.frameEvidencePassages(passages)
        return """
            \(GenerationPromptDefense.untrustedDataSystemGuard)

            You are a rigorous, evidence-anchored factual information extractor.
            Do not synthesize or summarize into an overview yet.
            Extract atomic factual statements directly stated in the evidence passages below.
            For each fact:
            1. Provide a clear, atomic statement.
            2. Supply the exact passage_id from which the fact was extracted.
            3. Supply the verbatim quote supporting that statement.
            Every statement must be grounded in its referenced passage. Do not add outside knowledge.

            \(framedPassages)
            """
    }

    private static let nonTerminalAbbreviations: Set<String> = [
        "st.", "u.s.", "u.k.", "mr.", "mrs.", "ms.", "dr.", "prof.", "gov.", "sen.", "rep.",
        "gen.", "col.", "capt.", "lt.", "sgt.", "maj.", "jan.", "feb.", "mar.", "apr.",
        "jun.", "jul.", "aug.", "sep.", "sept.", "oct.", "nov.", "dec.", "vs.", "i.e.",
        "e.g.", "etc.", "no.", "vol.", "rev.", "hon.", "dept.",
    ]

    private static func hasUnclosedQuotes(_ text: Substring) -> Bool {
        var doubleQuoteOpen = false
        var curlQuoteOpen = false
        for char in text {
            if char == "\"" {
                doubleQuoteOpen.toggle()
            } else if char == "“" {
                curlQuoteOpen = true
            } else if char == "”" {
                curlQuoteOpen = false
            }
        }
        return doubleQuoteOpen || curlQuoteOpen
    }

    /// Segments text into complete sentences, combining fragments split at abbreviations (e.g. "St.") or within unclosed quotes.
    public static func segmentedSentences(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard !ranges.isEmpty else { return [] }

        var merged: [Range<String.Index>] = []
        var currentStart = ranges[0].lowerBound
        var currentEnd = ranges[0].upperBound

        for i in 0..<ranges.count {
            let slice = text[currentStart..<ranges[i].upperBound]
            let trimmedEnd = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastWord = trimmedEnd.split(whereSeparator: \.isWhitespace).last.map { String($0).lowercased() } ?? ""
            let isAbbrev = nonTerminalAbbreviations.contains(lastWord)
            let unclosed = hasUnclosedQuotes(slice)

            if (isAbbrev || unclosed) && i + 1 < ranges.count {
                currentEnd = ranges[i + 1].upperBound
            } else {
                merged.append(currentStart..<currentEnd)
                if i + 1 < ranges.count {
                    currentStart = ranges[i + 1].lowerBound
                    currentEnd = ranges[i + 1].upperBound
                }
            }
        }
        return merged
    }

    /// Extracts passage-anchored facts using deterministic sentence segmentation for non-AI / macOS 15 execution.
    public static func deterministicExtract(passages: [EvidencePassage]) -> [PassageAnchoredFact] {
        var candidates: [RawFactCandidate] = []
        for passage in passages {
            let sentenceRanges = segmentedSentences(in: passage.text)
            for sentenceRange in sentenceRanges {
                let sentence = String(passage.text[sentenceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.count >= 15 {
                    candidates.append(
                        RawFactCandidate(
                            statement: sentence,
                            passageID: passage.id,
                            quote: sentence
                        ))
                }
            }
        }
        let diagnostic = PassageFactValidator.validateCandidates(candidates, against: passages)
        return diagnostic.acceptedFacts
    }

    #if canImport(FoundationModels)
        /// Performs guided fact extraction using Foundation Models when available on macOS 26+.
        @available(macOS 26.0, *)
        public static func extractFactsWithModel(
            passages: [EvidencePassage]
        ) async throws -> FactExtractionDiagnostic {
            let session = LanguageModelSession()
            let prompt = buildFactExtractionPrompt(passages: passages)
            let response = try await session.respond(to: prompt, generating: GenerablePassageFactExtraction.self)
            let rawCandidates = response.content.facts.map {
                RawFactCandidate(statement: $0.statement, passageID: $0.passageID, quote: $0.quote)
            }
            return PassageFactValidator.validateCandidates(rawCandidates, against: passages)
        }
    #endif
}
