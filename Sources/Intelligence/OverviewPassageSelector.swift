import Foundation
import NaturalLanguage

/// Manages context token budgeting for on-device event overview generation.
/// Differentiates tokens from raw character counts, reserving budget for instructions, schema, and response.
public struct OverviewTokenBudget: Sendable, Equatable {
    public let totalBudget: Int
    public let instructionTokens: Int
    public let schemaTokens: Int
    public let reservedResponseTokens: Int
    public let safetyMarginTokens: Int

    /// Tokens remaining for input evidence passages after reserving for prompt template, schema, and response.
    public var availablePassageTokens: Int {
        max(0, totalBudget - instructionTokens - schemaTokens - reservedResponseTokens - safetyMarginTokens)
    }

    public init(
        totalBudget: Int = 4096,
        instructionTokens: Int = 350,
        schemaTokens: Int = 250,
        reservedResponseTokens: Int = 800,
        safetyMarginTokens: Int = 100
    ) {
        self.totalBudget = totalBudget
        self.instructionTokens = instructionTokens
        self.schemaTokens = schemaTokens
        self.reservedResponseTokens = reservedResponseTokens
        self.safetyMarginTokens = safetyMarginTokens
    }

    /// Estimates token count for arbitrary text using lexical tokenization.
    /// Characters are not tokens: accounts for word count, punctuation, and script density (e.g. Cyrillic/multibyte).
    public static func estimateTokens(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        var wordCount = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            wordCount += 1
            return true
        }

        let nonAsciiCount = trimmed.unicodeScalars.filter { $0.value > 127 }.count
        let nonAsciiRatio = Double(nonAsciiCount) / Double(max(1, trimmed.count))

        if nonAsciiRatio > 0.3 {
            // Cyrillic / multibyte text has significantly higher subword token density
            let charEstimate = Int(ceil(Double(trimmed.count) / 2.0))
            return max(wordCount, charEstimate)
        } else {
            // Latin script: words * 1.3 factor + punctuation
            let baseTokens = Int(ceil(Double(wordCount) * 1.3))
            let punctuationCount = trimmed.filter { $0.isPunctuation }.count
            return max(1, baseTokens + Int(ceil(Double(punctuationCount) * 0.5)))
        }
    }
}

/// Selects 2 to 5 substantively different representative articles from an event candidate cluster,
/// filtering out wire reprints and exact duplicates.
struct OverviewRepresentativeSelector: Sendable {
    init() {}

    /// Selects substantively different representatives from candidate articles.
    func selectRepresentatives(
        from articles: [FeedArticle],
        minCount: Int = 2,
        maxCount: Int = 5
    ) -> [FeedArticle] {
        guard !articles.isEmpty else { return [] }
        if articles.count == 1 { return articles }

        var uniqueArticles: [FeedArticle] = []
        var seenIDs = Set<String>()
        var seenURLs = Set<String>()

        for article in articles {
            let canonURL = article.normalizedLink
            if seenIDs.insert(article.id).inserted && seenURLs.insert(canonURL).inserted {
                uniqueArticles.append(article)
            }
        }

        // Group reprints together by content fingerprints and wire text
        var groups: [[FeedArticle]] = []
        var assignedArticleIDs = Set<String>()

        for i in 0..<uniqueArticles.count {
            let articleA = uniqueArticles[i]
            if assignedArticleIDs.contains(articleA.id) { continue }

            var currentGroup = [articleA]
            assignedArticleIDs.insert(articleA.id)

            let fingerprintsA = Set(ArticleIdentity.publisherTextFingerprints(articleA))
            let textA = normalizedTextPreview(articleA)

            for j in (i + 1)..<uniqueArticles.count {
                let articleB = uniqueArticles[j]
                if assignedArticleIDs.contains(articleB.id) { continue }

                let fingerprintsB = Set(ArticleIdentity.publisherTextFingerprints(articleB))
                let sharesFingerprint = !fingerprintsA.isEmpty && !fingerprintsB.isEmpty && !fingerprintsA.isDisjoint(with: fingerprintsB)

                let textB = normalizedTextPreview(articleB)
                let isWireReprint = isSubstantiveReprint(textA: textA, textB: textB, titleA: articleA.title, titleB: articleB.title)

                if sharesFingerprint || isWireReprint {
                    currentGroup.append(articleB)
                    assignedArticleIDs.insert(articleB.id)
                }
            }
            groups.append(currentGroup)
        }

        // From each reprint group, pick the highest quality representative
        let groupRepresentatives = groups.map { group -> FeedArticle in
            group.max { a, b in
                scoreArticleQuality(a) < scoreArticleQuality(b)
            } ?? group[0]
        }

        // Rank distinct representatives by substance and diversity
        let sortedRepresentatives = groupRepresentatives.sorted { a, b in
            scoreArticleQuality(a) > scoreArticleQuality(b)
        }

        let targetCount = min(maxCount, max(minCount, sortedRepresentatives.count))
        return Array(sortedRepresentatives.prefix(targetCount))
    }

    private func normalizedTextPreview(_ article: FeedArticle) -> String {
        let content = article.fullContent ?? article.description
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func isSubstantiveReprint(textA: String, textB: String, titleA: String, titleB: String) -> Bool {
        guard !textA.isEmpty, !textB.isEmpty else { return false }

        // Exact preview match (first 250 characters)
        let prefixA = String(textA.prefix(250))
        let prefixB = String(textB.prefix(250))
        if prefixA.count >= 100 && prefixA == prefixB { return true }

        // Identical title and high lexical overlap
        let normTitleA = titleA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normTitleB = titleB.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normTitleA == normTitleB {
            let tokensA = Set(textA.split(separator: " ").prefix(80))
            let tokensB = Set(textB.split(separator: " ").prefix(80))
            guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }
            let intersection = tokensA.intersection(tokensB).count
            let union = tokensA.union(tokensB).count
            let jaccard = Double(intersection) / Double(union)
            return jaccard > 0.65
        }

        return false
    }

    private func scoreArticleQuality(_ article: FeedArticle) -> Int {
        var score = 0
        if let blocks = article.readerDocument?.blocks, !blocks.isEmpty {
            score += 500 + blocks.count * 10
        }
        if let full = article.fullContent, !full.isEmpty {
            score += min(300, full.count / 10)
        }
        if !article.description.isEmpty {
            score += min(50, article.description.count / 10)
        }
        return score
    }
}

/// Result of passage selection across representative articles.
struct OverviewPassageSelection: Sendable, Equatable {
    let representatives: [FeedArticle]
    let passages: [EvidencePassage]
    let totalEstimatedTokens: Int
    let overflowHandled: Bool
    let isFallbackRecommended: Bool

    init(
        representatives: [FeedArticle],
        passages: [EvidencePassage],
        totalEstimatedTokens: Int,
        overflowHandled: Bool,
        isFallbackRecommended: Bool
    ) {
        self.representatives = representatives
        self.passages = passages
        self.totalEstimatedTokens = totalEstimatedTokens
        self.overflowHandled = overflowHandled
        self.isFallbackRecommended = isFallbackRecommended
    }
}

/// Selects relevant evidence passages per representative article within a token budget.
/// Handles context overflow gracefully without failing the reader.
struct OverviewPassageSelector: Sendable {
    private let representativeSelector: OverviewRepresentativeSelector

    init(representativeSelector: OverviewRepresentativeSelector = OverviewRepresentativeSelector()) {
        self.representativeSelector = representativeSelector
    }

    func selectPassages(
        from articles: [FeedArticle],
        budget: OverviewTokenBudget = OverviewTokenBudget()
    ) -> OverviewPassageSelection {
        let representatives = representativeSelector.selectRepresentatives(from: articles)
        guard !representatives.isEmpty else {
            return OverviewPassageSelection(
                representatives: [],
                passages: [],
                totalEstimatedTokens: 0,
                overflowHandled: false,
                isFallbackRecommended: true
            )
        }

        // Extract and rank candidate passages for each representative
        var candidatePassagesByRep: [[EvidencePassage]] = []
        for rep in representatives {
            let passages = extractRankedPassages(from: rep)
            if !passages.isEmpty {
                candidatePassagesByRep.append(passages)
            }
        }

        guard !candidatePassagesByRep.isEmpty else {
            return OverviewPassageSelection(
                representatives: representatives,
                passages: [],
                totalEstimatedTokens: 0,
                overflowHandled: false,
                isFallbackRecommended: true
            )
        }

        let maxTokens = budget.availablePassageTokens
        var selectedPassages: [EvidencePassage] = []

        // Initial collection: take up to 2 top passages per representative
        for repPassages in candidatePassagesByRep {
            selectedPassages.append(contentsOf: repPassages.prefix(2))
        }

        var currentTokens = computeTokens(for: selectedPassages)

        // If fits within budget comfortably, return directly
        if currentTokens <= maxTokens {
            return OverviewPassageSelection(
                representatives: representatives,
                passages: selectedPassages,
                totalEstimatedTokens: currentTokens,
                overflowHandled: false,
                isFallbackRecommended: false
            )
        }

        // Context overflow handling: prune proportionally while keeping multi-source evidence
        let overflowHandled = true

        // Step 1: Reduce to top 1 passage per representative
        selectedPassages = candidatePassagesByRep.compactMap { $0.first }
        currentTokens = computeTokens(for: selectedPassages)

        if currentTokens <= maxTokens {
            return OverviewPassageSelection(
                representatives: representatives,
                passages: selectedPassages,
                totalEstimatedTokens: currentTokens,
                overflowHandled: overflowHandled,
                isFallbackRecommended: false
            )
        }

        // Step 2: Trim long passages to leading key sentences
        var trimmedPassages: [EvidencePassage] = []
        for passage in selectedPassages {
            let trimmedText = trimToKeySentences(passage.text, maxChars: 180)
            trimmedPassages.append(
                EvidencePassage(
                    id: passage.id,
                    articleID: passage.articleID,
                    text: trimmedText,
                    ordinal: passage.ordinal
                )
            )
        }
        currentTokens = computeTokens(for: trimmedPassages)

        if currentTokens <= maxTokens {
            return OverviewPassageSelection(
                representatives: representatives,
                passages: trimmedPassages,
                totalEstimatedTokens: currentTokens,
                overflowHandled: overflowHandled,
                isFallbackRecommended: false
            )
        }

        // Step 3: Tightest budget constraint. Reduce to top 2 representatives
        let topTwo = Array(trimmedPassages.prefix(2))
        currentTokens = computeTokens(for: topTwo)

        let isFallback = currentTokens > maxTokens
        return OverviewPassageSelection(
            representatives: representatives,
            passages: topTwo,
            totalEstimatedTokens: currentTokens,
            overflowHandled: overflowHandled,
            isFallbackRecommended: isFallback
        )
    }

    private func extractRankedPassages(from article: FeedArticle) -> [EvidencePassage] {
        var rawCandidates: [(text: String, ordinal: Int)] = []

        if let blocks = article.readerDocument?.blocks, !blocks.isEmpty {
            for (index, block) in blocks.enumerated() {
                // Keep only prose blocks; skip figure, caption, code, or tiny snippets
                guard block.kind == .paragraph || block.kind == .quote || block.kind == .subheading || block.kind == .listItem else {
                    continue
                }
                let clean = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.count >= 35, !isBoilerplate(clean) else { continue }
                rawCandidates.append((clean, block.ordinal ?? index))
            }
        } else {
            let fallbackText = article.fullContent ?? article.description
            let paragraphs = fallbackText.components(separatedBy: "\n\n")
            for (index, para) in paragraphs.enumerated() {
                let clean = para.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.count >= 35, !isBoilerplate(clean) else { continue }
                rawCandidates.append((clean, index))
            }
        }

        let scored = rawCandidates.map { item -> (text: String, ordinal: Int, score: Int) in
            (item.text, item.ordinal, scorePassageRelevance(item.text))
        }

        let sorted = scored.sorted { $0.score > $1.score }
        return sorted.enumerated().map { index, item in
            EvidencePassage(
                id: "\(article.id)_p\(item.ordinal)",
                articleID: article.id,
                text: item.text,
                ordinal: item.ordinal
            )
        }
    }

    private func scorePassageRelevance(_ text: String) -> Int {
        var score = 0
        let numbers = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        score += min(50, numbers * 5)

        // Capitalized words / entities indicator
        let words = text.split(separator: " ")
        let capitalized = words.filter { $0.first?.isUppercase == true }.count
        score += min(60, capitalized * 4)

        // Quotes or attribution phrases
        if text.contains("\"") || text.contains("“") || text.contains("said") || text.contains("stated") {
            score += 40
        }

        // Optimal length between 80 and 450 characters
        if text.count >= 80 && text.count <= 450 {
            score += 50
        }

        return score
    }

    private func isBoilerplate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = [
            "sign up", "newsletter", "subscribe", "follow us on", "photo credit",
            "advertisement", "all rights reserved", "terms of service", "cookie policy"
        ]
        return triggers.contains { lower.contains($0) }
    }

    private func computeTokens(for passages: [EvidencePassage]) -> Int {
        passages.reduce(0) { $0 + OverviewTokenBudget.estimateTokens(for: $1.text) }
    }

    private func trimToKeySentences(_ text: String, maxChars: Int) -> String {
        let sentences = text.components(separatedBy: ". ")
        guard let first = sentences.first, !first.isEmpty else {
            return String(text.prefix(maxChars))
        }
        var result = first
        if !result.hasSuffix(".") { result += "." }
        if sentences.count > 1 && (result.count + sentences[1].count + 2) <= maxChars {
            result += " " + sentences[1]
            if !result.hasSuffix(".") { result += "." }
        }
        return result
    }
}
