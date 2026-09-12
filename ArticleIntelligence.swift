import Foundation
import NaturalLanguage
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Fixed News Category Taxonomy (12 Standard Categories)

public enum NewsCategory: String, CaseIterable, Sendable, Codable {
    case technology = "Technology"
    case science = "Science"
    case business = "Business"
    case politics = "Politics"
    case world = "World"
    case sports = "Sports"
    case entertainment = "Entertainment"
    case health = "Health"
    case travel = "Travel"
    case food = "Food"
    case fashion = "Fashion"
    case lifestyle = "Lifestyle"

    public static func match(from string: String) -> NewsCategory? {
        let firstLine = string.components(separatedBy: .newlines).first ?? string
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        for cat in allCases {
            if cat.rawValue.localizedCaseInsensitiveCompare(trimmed) == .orderedSame {
                return cat
            }
        }
        // Partial mappings for common synonyms
        let lower = trimmed.lowercased()
        if lower.contains("tech") { return .technology }
        if lower.contains("politic") || lower.contains("gov") || lower.contains("election") { return .politics }
        if lower.contains("sci") || lower.contains("space") { return .science }
        if lower.contains("econ") || lower.contains("biz") || lower.contains("finance") || lower.contains("market") { return .business }
        if lower.contains("sport") { return .sports }
        if lower.contains("entertain") || lower.contains("movie") || lower.contains("film") || lower.contains("music") { return .entertainment }
        if lower.contains("health") || lower.contains("med") || lower.contains("wellness") { return .health }
        if lower.contains("travel") || lower.contains("tourism") { return .travel }
        if lower.contains("food") || lower.contains("cook") || lower.contains("dining") || lower.contains("culinary") || lower.contains("recipe") { return .food }
        if lower.contains("style") || lower.contains("fashion") { return .fashion }
        if lower.contains("global") || lower.contains("world") || lower.contains("international") || lower.contains("war") || lower.contains("conflict") || lower.contains("military") { return .world }
        if lower.contains("life") || lower.contains("living") { return .lifestyle }
        return nil
    }
}

// MARK: - Foundation Models Generable Schemas

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
public enum GenerableNewsCategory: String, CaseIterable, Sendable, Codable {
    case technology = "Technology"
    case science = "Science"
    case business = "Business"
    case politics = "Politics"
    case world = "World"
    case sports = "Sports"
    case entertainment = "Entertainment"
    case health = "Health"
    case travel = "Travel"
    case food = "Food"
    case fashion = "Fashion"
    case lifestyle = "Lifestyle"

    var toDomainCategory: NewsCategory {
        NewsCategory(rawValue: self.rawValue) ?? .technology
    }
}

@available(macOS 26.0, *)
@Generable
public struct GenerableClassificationOutput: Sendable, Codable {
    @Guide(description: "The primary category of the news article from the allowed list.")
    public var category: GenerableNewsCategory

    @Guide(description: "Confidence level between 0.0 and 1.0", .range(0.0...1.0))
    public var confidence: Double
}

@available(macOS 26.0, *)
@Generable
public enum GenerableSentimentKind: String, CaseIterable, Sendable, Codable {
    case positive = "Positive"
    case neutral = "Neutral"
    case critical = "Critical"
}

@available(macOS 26.0, *)
@Generable
public struct GenerableEntityItem: Sendable, Codable {
    @Guide(description: "Name of the entity (e.g. person, organization, or place)")
    public var name: String

    @Guide(description: "Type of entity (person, organization, place, or unknown)")
    public var type: String
}

@available(macOS 26.0, *)
@Generable
public struct GenerableArticleAnalysis: Sendable, Codable {
    @Guide(description: "A single concise paragraph summarizing the article.")
    public var summary: String

    @Guide(description: "Between 3 and 5 bullet key points summarizing the key takeaways.", .count(3...5))
    public var keyPoints: [String]

    @Guide(description: "Key named entities mentioned in the article.")
    public var entities: [GenerableEntityItem]

    @Guide(description: "Overall sentiment of the article.")
    public var sentiment: GenerableSentimentKind
}
#endif

// MARK: - Intelligence Domain Models

public enum EntityType: String, Sendable, Codable, Hashable {
    case person
    case organization
    case place
    case unknown
}

public struct EntityResult: Sendable, Equatable, Codable, Hashable {
    public let name: String
    public let type: EntityType
    public let confidence: Double

    public init(name: String, type: EntityType, confidence: Double = 1.0) {
        self.name = name
        self.type = type
        self.confidence = confidence
    }
}

public struct SentimentResult: Sendable, Equatable, Codable, Hashable {
    public let score: Double        // -1.0 (very negative) to +1.0 (very positive)
    public let confidence: Double   // 0.0 to 1.0
    public let label: String        // "Positive", "Neutral", "Critical"

    public init(score: Double, confidence: Double, label: String) {
        self.score = score
        self.confidence = confidence
        self.label = label
    }
}

public struct TopicResult: Sendable, Equatable, Codable {
    public let category: String
    public let confidence: Double   // 0.0 to 1.0
    public let evidence: [String]   // Extracted keywords / entities supporting the category

    public init(category: String, confidence: Double, evidence: [String] = []) {
        self.category = category
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct SummaryResult: Sendable, Equatable, Codable {
    public let text: String
    public let sentencesUsed: Int
    public let confidence: Double

    public init(text: String, sentencesUsed: Int, confidence: Double) {
        self.text = text
        self.sentencesUsed = sentencesUsed
        self.confidence = confidence
    }
}

/// Structured article intelligence result persisted in SQLite and displayed in the reader UI.
public struct ArticleAnalysis: Sendable, Equatable, Codable {
    public let summary: String
    public let keyPoints: [String]
    public let entities: [EntityResult]
    public let category: String?
    public let sentiment: SentimentResult?
    public let modelIdentifier: String
    public let analysisVersion: Int

    public init(
        summary: String,
        keyPoints: [String] = [],
        entities: [EntityResult] = [],
        category: String? = nil,
        sentiment: SentimentResult? = nil,
        modelIdentifier: String = "apple.foundation-model",
        analysisVersion: Int = 1
    ) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.entities = entities
        self.category = category
        self.sentiment = sentiment
        self.modelIdentifier = modelIdentifier
        self.analysisVersion = analysisVersion
    }
}

// MARK: - Typed AI Error Domain

public enum AIAnalysisError: Error, Sendable, Equatable {
    case unavailable(String)
    case modelNotReady
    case modelError(String)
    case contextTooLarge
    case invalidStructuredOutput
    case cancelled
    case contentUnavailable
    case extractionFailed
    case persistenceFailed
}

// MARK: - Capability Protocols (Model-Agnostic)

public protocol SentimentAnalyzing: Sendable {
    func analyzeSentiment(for text: String) async -> SentimentResult
}

public protocol EntityExtracting: Sendable {
    func extractEntities(from text: String) async -> [EntityResult]
}

public protocol TopicClassifying: Sendable {
    func classifyTopic(title: String, description: String, text: String?, rssCategory: String?) async -> TopicResult?
}

public protocol ArticleSummarizing: Sendable {
    func summarize(title: String, content: String) async -> SummaryResult
}

public protocol ContentCleaning: Sendable {
    func cleanContent(_ rawText: String) -> String
}

// MARK: - NaturalLanguage & Deterministic Implementations (M1/M2 Fallback)

public final class NaturalLanguageSentimentAnalyzer: SentimentAnalyzing {
    public init() {}

    public func analyzeSentiment(for text: String) async -> SentimentResult {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (sentiment, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let score = Double(sentiment?.rawValue ?? "0") ?? 0.0

        let confidence: Double = min(1.0, abs(score) * 1.5 + 0.4)
        let label: String
        if score > 0.25 {
            label = "Positive"
        } else if score < -0.25 {
            label = "Critical"
        } else {
            label = "Neutral"
        }

        return SentimentResult(score: score, confidence: confidence, label: label)
    }
}

public final class NaturalLanguageEntityExtractor: EntityExtracting {
    public init() {}

    public func extractEntities(from text: String) async -> [EntityResult] {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "AIEntityExtraction", metadata: "len=\(text.count)")
        defer { NewsSignposts.end(NewsSignposts.intelligence, name: "AIEntityExtraction", state: signpostState) }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var entities = [EntityResult]()
        var seen = Set<String>()

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if let tag = tag {
                let entityType: EntityType
                switch tag {
                case .personalName: entityType = .person
                case .organizationName: entityType = .organization
                case .placeName: entityType = .place
                default: entityType = .unknown
                }

                if entityType != .unknown {
                    let word = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = word.lowercased()
                    if word.count > 2 && !seen.contains(lower) {
                        seen.insert(lower)
                        entities.append(EntityResult(name: word, type: entityType, confidence: 0.9))
                    }
                }
            }
            return true
        }
        return entities
    }
}

public final class NaturalLanguageTopicClassifier: TopicClassifying {
    public init() {}

    public static let taxonomy: [(category: NewsCategory, keywords: [String])] = [
        (.technology, ["tech", "software", "hardware", "artificial intelligence", "ai", "computer", "silicon valley", "cyber", "programming", "developer", "machine learning", "chip", "semiconductor", "startup", "coding", "algorithm", "neural", "apple", "google", "microsoft", "nvidia", "intel", "amd", "cloud", "server", "linux", "ios", "macos", "android", "iphone", "macbook"]),
        (.science, ["science", "research", "study", "discovery", "space", "nasa", "physics", "biology", "chemistry", "climate", "species", "quantum", "astronomy", "planet", "genome", "laboratory", "experiment", "rocket", "satellite", "mars", "telescope", "fossil", "ecosystem"]),
        (.business, ["market", "stock", "economy", "finance", "wall street", "investor", "venture", "ipo", "revenue", "profit", "earnings", "trade", "inflation", "bank", "gdp", "recession", "shares", "dividend", "crypto", "bitcoin", "central bank", "interest rate", "valuation"]),
        (.politics, ["congress", "senate", "democrat", "republican", "white house", "legislation", "campaign", "electoral", "president", "biden", "trump", "parliament", "vote", "voter", "lawmaker", "governor", "supreme court", "election", "policy", "sanction"]),
        (.world, ["international", "global", "europe", "asia", "africa", "middle east", "ukraine", "russia", "china", "foreign", "united nations", "un", "diplomat", "treaty", "conflict", "war", "peace", "nato", "embassy", "border", "refugee", "geopolitics"]),
        (.sports, ["sport", "football", "basketball", "soccer", "baseball", "nfl", "nba", "mlb", "athlete", "championship", "league", "coach", "olympic", "tennis", "golf", "tournament", "fifa", "premier league", "quarterback", "stadium", "goal", "formula 1", "f1"]),
        (.entertainment, ["entertainment", "movie", "film", "celebrity", "music", "television", "hollywood", "streaming", "netflix", "disney", "actor", "actress", "concert", "album", "grammy", "oscar", "cinema", "box office", "pop star", "emmy", "broadway"]),
        (.health, ["health", "medical", "doctor", "hospital", "disease", "treatment", "vaccine", "mental health", "wellness", "fitness", "nutrition", "therapy", "clinical", "virus", "cancer", "surgery", "medicine", "fda", "diet", "workout", "cardio", "pharma"]),
        (.travel, ["travel", "flight", "airline", "hotel", "tourism", "destination", "vacation", "airport", "cruise", "resort", "backpacking", "passport", "visa", "itinerary", "sightseeing"]),
        (.food, ["food", "restaurant", "recipe", "cooking", "chef", "dining", "cuisine", "wine", "baking", "cocktail", "flavor", "meal", "coffee", "pastry", "culinary", "ingredient", "dish"]),
        (.fashion, ["fashion", "designer", "runway", "clothing", "trend", "outfit", "accessory", "vogue", "apparel", "haute couture", "sneaker", "luxury", "footwear", "wardrobe"]),
        (.lifestyle, ["lifestyle", "home", "garden", "parenting", "relationship", "decor", "mindfulness", "habits", "productivity", "diy", "family", "pets", "minimalism", "culture"])
    ]

    public func classifyTopic(title: String, description: String, text: String?, rssCategory: String?) async -> TopicResult? {
        // 1. Direct match on RSS category hint
        if let rssCat = rssCategory?.trimmingCharacters(in: .whitespacesAndNewlines), !rssCat.isEmpty {
            if let matched = NewsCategory.match(from: rssCat) {
                return TopicResult(category: matched.rawValue, confidence: 0.95, evidence: [rssCat])
            }
        }

        // 2. Score title, description, and body against taxonomy
        let titleLower = title.lowercased()
        let descLower = description.lowercased()
        let bodyLower = (text ?? "").prefix(2000).lowercased()

        var bestCategory: NewsCategory?
        var maxScore = 0.0
        var bestEvidence: [String] = []

        for item in Self.taxonomy {
            var score = 0.0
            var matched: [String] = []

            for kw in item.keywords {
                if titleLower.contains(kw) {
                    score += 3.0
                    matched.append(kw)
                }
                if descLower.contains(kw) {
                    score += 1.5
                    matched.append(kw)
                }
                if bodyLower.contains(kw) {
                    score += 0.5
                }
            }

            if score > maxScore {
                maxScore = score
                bestCategory = item.category
                bestEvidence = Array(Set(matched))
            }
        }

        if let cat = bestCategory, maxScore >= 2.0 {
            let confidence = min(0.95, 0.5 + (maxScore * 0.08))
            return TopicResult(category: cat.rawValue, confidence: confidence, evidence: bestEvidence)
        }

        return nil
    }
}

public final class ExtractiveArticleSummarizer: ArticleSummarizing {
    public init() {}

    public func summarize(title: String, content: String) async -> SummaryResult {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "AISummarization", metadata: "len=\(content.count)")
        defer { NewsSignposts.end(NewsSignposts.intelligence, name: "AISummarization", state: signpostState) }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SummaryResult(text: title, sentencesUsed: 1, confidence: 0.5)
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let s = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 30 && s.count < 350 {
                sentences.append(s)
            }
            return sentences.count < 40
        }

        guard !sentences.isEmpty else {
            return SummaryResult(text: String(trimmed.prefix(200)), sentencesUsed: 1, confidence: 0.5)
        }

        let titleWords = Set(title.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 3 })

        var scored: [(sentence: String, score: Double, originalIndex: Int)] = []
        for (idx, sentence) in sentences.enumerated() {
            var score = 0.0
            score += max(0, 5.0 - Double(idx) * 0.5)
            let sWords = Set(sentence.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let overlap = titleWords.intersection(sWords).count
            score += Double(overlap) * 2.5
            if sentence.count >= 80 && sentence.count <= 220 {
                score += 2.0
            }
            scored.append((sentence, score, idx))
        }

        scored.sort { $0.score > $1.score }
        let topCount = min(2, scored.count)
        let selected = scored.prefix(topCount).sorted { $0.originalIndex < $1.originalIndex }
        let summaryText = selected.map { $0.sentence }.joined(separator: " ")

        return SummaryResult(text: summaryText, sentencesUsed: topCount, confidence: 0.85)
    }

    /// Generates 3 to 5 key points by extracting highest scoring distinct sentences.
    public func extractKeyPoints(title: String, content: String) async -> [String] {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "AIKeyPoints", metadata: "len=\(content.count)")
        defer { NewsSignposts.end(NewsSignposts.intelligence, name: "AIKeyPoints", state: signpostState) }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let s = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 40 && s.count < 280 && !s.hasSuffix("?") {
                sentences.append(s)
            }
            return sentences.count < 50
        }

        guard sentences.count >= 3 else {
            return sentences
        }

        let titleWords = Set(title.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 3 })
        var scored: [(sentence: String, score: Double, originalIndex: Int)] = []
        for (idx, s) in sentences.enumerated() {
            var score = max(0, 4.0 - Double(idx) * 0.3)
            let sWords = Set(s.lowercased().components(separatedBy: .whitespacesAndNewlines))
            score += Double(titleWords.intersection(sWords).count) * 2.0
            scored.append((s, score, idx))
        }

        scored.sort { $0.score > $1.score }
        let selected = scored.prefix(min(4, scored.count)).sorted { $0.originalIndex < $1.originalIndex }
        return selected.map { $0.sentence }
    }
}

public final class ProseContentCleaner: ContentCleaning {
    public init() {}

    public func cleanContent(_ rawText: String) -> String {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "ContentPreparation", metadata: "len=\(rawText.count)")
        defer { NewsSignposts.end(NewsSignposts.intelligence, name: "ContentPreparation", state: signpostState) }

        let lines = rawText.components(separatedBy: "\n\n")
        var cleanedParagraphs = [String]()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 30 else { continue }
            if isBoilerplate(trimmed) { continue }
            if trimmed.count < 60 && !trimmed.contains(".") && !trimmed.contains("?") { continue }

            let uppercaseRatio = Double(trimmed.filter { $0.isUppercase }.count) / Double(max(trimmed.count, 1))
            if uppercaseRatio > 0.6 && trimmed.count < 80 { continue }

            let specialCharCount = trimmed.filter { "→←►▸▶|»«●■□☐✓✗×".contains($0) }.count
            if specialCharCount > 2 { continue }

            if isProse(trimmed) {
                cleanedParagraphs.append(trimmed)
            }
        }

        var seen = Set<String>()
        var unique = [String]()
        for p in cleanedParagraphs {
            let key = String(p.prefix(80)).lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(p)
            }
        }

        return unique.joined(separator: "\n\n")
    }

    private func isProse(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        var contentWordCount = 0
        var totalWordCount = 0

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, _ in
            totalWordCount += 1
            if let tag = tag {
                switch tag {
                case .noun, .verb, .adjective, .adverb, .pronoun, .determiner, .preposition, .conjunction:
                    contentWordCount += 1
                default: break
                }
            }
            return totalWordCount < 50
        }

        guard totalWordCount > 3 else { return false }
        return Double(contentWordCount) / Double(totalWordCount) > 0.5
    }

    private func isBoilerplate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let junkPhrases = [
            "share this", "follow us", "join the conversation", "newsletter",
            "subscribe", "sign up", "log in", "sign in", "cookie", "privacy policy",
            "terms of service", "terms & conditions", "all rights reserved",
            "contact me with", "receive email", "trusted partners",
            "by submitting your", "add us as", "related articles", "read next",
            "advertisement", "sponsored", "promoted", "flipboard",
            "leave a reply", "your email address", "breaking space news",
            "breaking news, the latest updates", "share on", "tweet this",
            "pin it", "copy link", "print this", "download our app",
            "recommended for you", "more stories", "you may also like"
        ]
        return junkPhrases.contains { lower.contains($0) }
    }
}

// MARK: - ArticleClassifier (Automatic Ingestion Capability)

/// Dedicated, high-accuracy topic classifier used automatically during feed ingestion.
/// Multi-stage pipeline: RSS hints -> Apple Foundation Models (when available) -> NaturalLanguage fallback.
public final class ArticleClassifier: Sendable {
    public static let shared = ArticleClassifier()

    private let fallbackClassifier: NaturalLanguageTopicClassifier

    public init(fallbackClassifier: NaturalLanguageTopicClassifier = NaturalLanguageTopicClassifier()) {
        self.fallbackClassifier = fallbackClassifier
    }

    /// Whether Apple Foundation Models is ready and available on this hardware.
    public var isFoundationModelsAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Classifies an article into one of the 12 fixed application categories.
    public func classify(
        title: String,
        description: String,
        text: String? = nil,
        rssCategory: String? = nil
    ) async -> TopicResult {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "AIClassification", metadata: "title_len=\(title.count)")
        defer { NewsSignposts.end(NewsSignposts.intelligence, name: "AIClassification", state: signpostState) }

        // Stage 1: Fast deterministic RSS hint
        if let rssHint = rssCategory?.trimmingCharacters(in: .whitespacesAndNewlines), !rssHint.isEmpty {
            if let matched = NewsCategory.match(from: rssHint) {
                return TopicResult(category: matched.rawValue, confidence: 0.95, evidence: [rssHint])
            }
        }

        // Stage 2: Foundation Models classification (when available)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isFoundationModelsAvailable {
            do {
                let session = LanguageModelSession()
                let prompt = """
                Classify this news article into exactly one category from the allowed list:
                Allowed categories: Technology, Science, Business, Politics, World, Sports, Entertainment, Health, Travel, Food, Fashion, Lifestyle.

                Title: \(title)
                Description: \(description)
                """

                let response = try await session.respond(to: prompt, generating: GenerableClassificationOutput.self)
                let modelCategory = response.content.category.toDomainCategory.rawValue
                let confidence = response.content.confidence

                // Confidence evaluation policy:
                // >= 0.85: accept directly
                // 0.60 ..< 0.85: verify against deterministic classifier
                // < 0.60: fall back
                if confidence >= 0.85 {
                    return TopicResult(category: modelCategory, confidence: confidence, evidence: ["foundation_model"])
                } else if confidence >= 0.60 {
                    if let deterministic = await fallbackClassifier.classifyTopic(title: title, description: description, text: text, rssCategory: rssCategory) {
                        if deterministic.category == modelCategory {
                            return TopicResult(category: modelCategory, confidence: max(confidence, deterministic.confidence), evidence: ["foundation_model_verified"] + deterministic.evidence)
                        } else if deterministic.confidence > confidence {
                            return deterministic
                        }
                    }
                    return TopicResult(category: modelCategory, confidence: confidence, evidence: ["foundation_model_unverified"])
                }
            } catch {
                // Foundation Models failure -> fall through to deterministic fallback
            }
        }
        #endif

        // Stage 3: NaturalLanguage & Keyword deterministic fallback
        if let result = await fallbackClassifier.classifyTopic(title: title, description: description, text: text, rssCategory: rssCategory) {
            return result
        }

        // Stage 4: Default generic fallback
        return TopicResult(category: NewsCategory.world.rawValue, confidence: 0.5, evidence: ["default_fallback"])
    }
}

// MARK: - ArticleAnalyzer (Lazy Interactive Reading Capability)

/// Dedicated semantic analyzer invoked lazily and exclusively when the user opens an article.
/// Fully cancellable when the user navigates away.
public final class ArticleAnalyzer: Sendable {
    public static let shared = ArticleAnalyzer()

    private let fallbackSummarizer: ExtractiveArticleSummarizer
    private let fallbackExtractor: NaturalLanguageEntityExtractor
    private let fallbackSentiment: NaturalLanguageSentimentAnalyzer
    private let contentCleaner: ProseContentCleaner

    public init(
        fallbackSummarizer: ExtractiveArticleSummarizer = ExtractiveArticleSummarizer(),
        fallbackExtractor: NaturalLanguageEntityExtractor = NaturalLanguageEntityExtractor(),
        fallbackSentiment: NaturalLanguageSentimentAnalyzer = NaturalLanguageSentimentAnalyzer(),
        contentCleaner: ProseContentCleaner = ProseContentCleaner()
    ) {
        self.fallbackSummarizer = fallbackSummarizer
        self.fallbackExtractor = fallbackExtractor
        self.fallbackSentiment = fallbackSentiment
        self.contentCleaner = contentCleaner
    }

    /// Analyzes an article on-demand, generating 1-paragraph summary, 3-5 key points, entities, and sentiment.
    /// Responds cooperatively to Task cancellation.
    public func analyze(
        title: String,
        content: String,
        category: String? = nil
    ) async throws -> ArticleAnalysis {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "AIAnalysis", metadata: "content_len=\(content.count)")
        defer { NewsSignposts.end(NewsSignposts.intelligence, name: "AIAnalysis", state: signpostState) }

        // Cooperative cancellation check
        try Task.checkCancellation()

        let cleaned = contentCleaner.cleanContent(content)
        let effectiveContent = cleaned.isEmpty ? content : cleaned

        // Context budget management: truncate to avoid exceeding model context window (~6000 chars)
        let contextBudget = 6000
        let budgetedContent = String(effectiveContent.prefix(contextBudget))

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), ArticleClassifier.shared.isFoundationModelsAvailable {
            do {
                let session = LanguageModelSession()
                let prompt = """
                Analyze the following news article and produce:
                1. A single concise paragraph summary.
                2. Between 3 and 5 bullet key points summarizing the primary takeaways.
                3. Key named entities mentioned.
                4. Overall sentiment (Positive, Neutral, or Critical).

                Title: \(title)

                Article Content:
                \(budgetedContent)
                """

                try Task.checkCancellation()

                let response = try await session.respond(to: prompt, generating: GenerableArticleAnalysis.self)
                let gen = response.content

                try Task.checkCancellation()

                let entities = gen.entities.map { item in
                    let type: EntityType
                    switch item.type.lowercased() {
                    case "person": type = .person
                    case "organization", "company": type = .organization
                    case "place", "location": type = .place
                    default: type = .unknown
                    }
                    return EntityResult(name: item.name, type: type, confidence: 0.95)
                }

                let sentimentScore: Double
                switch gen.sentiment {
                case .positive: sentimentScore = 0.6
                case .neutral: sentimentScore = 0.0
                case .critical: sentimentScore = -0.6
                }
                let sentimentResult = SentimentResult(score: sentimentScore, confidence: 0.9, label: gen.sentiment.rawValue)

                return ArticleAnalysis(
                    summary: gen.summary,
                    keyPoints: gen.keyPoints,
                    entities: entities,
                    category: category,
                    sentiment: sentimentResult,
                    modelIdentifier: "apple.foundation-model",
                    analysisVersion: 1
                )
            } catch is CancellationError {
                throw AIAnalysisError.cancelled
            } catch {
                // If model fails or throws, fall through to deterministic fallback
            }
        }
        #endif

        try Task.checkCancellation()

        // Fallback: Extractive NaturalLanguage pipeline
        let summaryResult = await fallbackSummarizer.summarize(title: title, content: budgetedContent)
        let keyPoints = await fallbackSummarizer.extractKeyPoints(title: title, content: budgetedContent)
        let entities = await fallbackExtractor.extractEntities(from: budgetedContent)
        let sentiment = await fallbackSentiment.analyzeSentiment(for: budgetedContent)

        return ArticleAnalysis(
            summary: summaryResult.text,
            keyPoints: keyPoints,
            entities: entities,
            category: category,
            sentiment: sentiment,
            modelIdentifier: "apple.natural-language.fallback",
            analysisVersion: 1
        )
    }
}

// MARK: - Unified ArticleIntelligence Facade (Backwards Compatibility)

public final class ArticleIntelligence: Sendable {
    public static let shared = ArticleIntelligence()

    public let classifier: ArticleClassifier
    public let analyzer: ArticleAnalyzer

    public let sentimentAnalyzer: SentimentAnalyzing
    public let entityExtractor: EntityExtracting
    public let topicClassifier: TopicClassifying
    public let summarizer: ArticleSummarizing
    public let contentCleaner: ContentCleaning

    public init(
        classifier: ArticleClassifier = .shared,
        analyzer: ArticleAnalyzer = .shared,
        sentimentAnalyzer: SentimentAnalyzing = NaturalLanguageSentimentAnalyzer(),
        entityExtractor: EntityExtracting = NaturalLanguageEntityExtractor(),
        topicClassifier: TopicClassifying = NaturalLanguageTopicClassifier(),
        summarizer: ArticleSummarizing = ExtractiveArticleSummarizer(),
        contentCleaner: ContentCleaning = ProseContentCleaner()
    ) {
        self.classifier = classifier
        self.analyzer = analyzer
        self.sentimentAnalyzer = sentimentAnalyzer
        self.entityExtractor = entityExtractor
        self.topicClassifier = topicClassifier
        self.summarizer = summarizer
        self.contentCleaner = contentCleaner
    }

    /// Multi-dimensional analysis generating insight string, entities, and sentiment.
    public func analyzeArticle(title: String, description: String) async -> String {
        let fullText = "\(title). \(description)"
        let sentiment = await sentimentAnalyzer.analyzeSentiment(for: fullText)
        let entities = await entityExtractor.extractEntities(from: fullText)

        if !entities.isEmpty {
            let entityList = entities.prefix(3).map { $0.name }.joined(separator: ", ")
            return "\(sentiment.label) coverage · Key focus: \(entityList)"
        } else {
            return "\(sentiment.label) analysis · Developing story"
        }
    }

    /// Categorizes article with confidence score and supporting evidence.
    public func categorizeArticle(title: String, description: String, text: String? = nil, rssCategory: String? = nil) async -> TopicResult? {
        await classifier.classify(title: title, description: description, text: text, rssCategory: rssCategory)
    }

    /// Produces concise extractive summary of full article text.
    public func summarizeArticle(title: String, content: String) async -> SummaryResult {
        await summarizer.summarize(title: title, content: content)
    }

    /// Cleans extracted raw HTML text to remove boilerplate and navigation artifacts.
    public func cleanContent(_ rawText: String) -> String {
        contentCleaner.cleanContent(rawText)
    }
}

// MARK: - Article Content Redactor & Formatter

public enum ArticleContentRedactor {
    private static let boilerplatePatterns: [String] = [
        // Fused sentence ending, e.g. 'last year.Read full article' or 'last year. Read full article Comments'
        "(?i)(\\.|!|\\?)\\s*(?:read full article|read more|continue reading|view comments|leave a comment|full story)\\b.*$",
        // Trailing standalone boilerplate
        "(?i)[\\s\\.]*\\b(?:read full article|read more|continue reading|view comments|leave a comment|full story)\\b[\\s\\.]*$",
        // Syndication notices at end of line
        "(?i)the post .* appeared first on .*\\.?$"
    ]

    private static let boilerplateLineExact: Set<String> = [
        "comments", "comment", "read full article", "read more", "continue reading",
        "view comments", "leave a comment", "share this article", "share this post",
        "related articles", "source", "read original", "full article", "full story"
    ]

    /// Cleans boilerplate phrases, syndication notes, and trailing artifacts from text.
    public static func cleanText(_ rawText: String) -> String {
        var text = rawText
        
        for pattern in boilerplatePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                let range = NSRange(text.startIndex..., in: text)
                if pattern.contains("(\\.|!|\\?)") {
                    text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
                } else {
                    text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
                }
            }
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Redacts boilerplate and intelligently splits article content into readable editorial paragraphs.
    public static func redactAndSplit(_ rawText: String) -> [String] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawParagraphs: [String]
        if normalized.contains("\n\n") {
            rawParagraphs = normalized.components(separatedBy: "\n\n")
        } else if normalized.contains("\n") {
            rawParagraphs = normalized.components(separatedBy: "\n")
        } else {
            rawParagraphs = [normalized]
        }

        var result = [String]()
        for para in rawParagraphs {
            let cleaned = cleanText(para)
            guard !cleaned.isEmpty else { continue }
            if isBoilerplateLine(cleaned) { continue }

            // If a single paragraph is too monolithic (> 450 characters and 3+ sentences), split it
            if cleaned.count > 450 {
                let subParagraphs = splitLongParagraph(cleaned)
                for sub in subParagraphs {
                    let subCleaned = cleanText(sub)
                    if !subCleaned.isEmpty && !isBoilerplateLine(subCleaned) {
                        result.append(subCleaned)
                    }
                }
            } else {
                result.append(cleaned)
            }
        }

        while let last = result.last, isBoilerplateLine(last) {
            result.removeLast()
        }

        return result
    }

    /// Checks if a string is solely a boilerplate phrase or syndication footer.
    public static func isBoilerplateLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!-–—()[]{}•*#0123456789/ "))
        let lower = stripped.lowercased()

        if boilerplateLineExact.contains(lower) {
            return true
        }
        if (lower.hasPrefix("comment") || lower.hasSuffix("comments")) && lower.count < 25 {
            return true
        }
        let rawLower = trimmed.lowercased()
        if rawLower.hasPrefix("the post ") && rawLower.contains(" appeared first on ") {
            return true
        }
        if rawLower.hasPrefix("photo by ") || rawLower.hasPrefix("image credit:") || rawLower.hasPrefix("photo credit:") {
            return true
        }
        return false
    }

    /// Splits a large unsegmented paragraph at sentence boundaries into balanced readable paragraphs.
    private static func splitLongParagraph(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences = [String]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        guard sentences.count > 2 else { return [text] }

        var paragraphs = [String]()
        var currentPara = ""
        for sentence in sentences {
            if !currentPara.isEmpty && (currentPara.count + sentence.count > 320) {
                paragraphs.append(currentPara)
                currentPara = sentence
            } else {
                if currentPara.isEmpty {
                    currentPara = sentence
                } else {
                    currentPara += " " + sentence
                }
            }
        }
        if !currentPara.isEmpty {
            paragraphs.append(currentPara)
        }
        return paragraphs.isEmpty ? [text] : paragraphs
    }
}

// MARK: - Article Preview Policy

public enum ArticlePreviewPolicy {
    /// Returns all clean paragraphs for display. The reader shows full extracted content.
    /// The terminal affordance provides access to the original web page.
    public static func computePreview(paragraphs: [String], isExtracted: Bool) -> [String] {
        return paragraphs
    }
}

// MARK: - Trackpad Swipe Navigation Evaluator

public enum TrackpadSwipeDirection: Equatable, Sendable {
    case previous
    case next
    case none
}

public enum TrackpadSwipeEvaluator {
    /// Evaluates accumulated horizontal and vertical trackpad deltas.
    /// Returns .previous for dominant rightward swipe, .next for dominant leftward swipe,
    /// and .none if vertical scroll dominates or threshold is not met.
    public static func evaluate(deltaX: CGFloat, deltaY: CGFloat, threshold: CGFloat = 60.0) -> TrackpadSwipeDirection {
        let absX = abs(deltaX)
        let absY = abs(deltaY)

        guard absX >= threshold else { return .none }
        guard absX > (absY * 1.8) else { return .none }

        return deltaX > 0 ? .previous : .next
    }
}



