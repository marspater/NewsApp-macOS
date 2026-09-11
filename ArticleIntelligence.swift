import Foundation
import NaturalLanguage

// MARK: - Intelligence Domain Models

enum EntityType: String, Sendable, Codable {
    case person
    case organization
    case place
    case unknown
}

struct EntityResult: Sendable, Equatable, Codable {
    let name: String
    let type: EntityType
    let confidence: Double

    init(name: String, type: EntityType, confidence: Double = 1.0) {
        self.name = name
        self.type = type
        self.confidence = confidence
    }
}

struct SentimentResult: Sendable, Equatable, Codable {
    let score: Double        // -1.0 (very negative) to +1.0 (very positive)
    let confidence: Double   // 0.0 to 1.0
    let label: String        // "Positive", "Neutral", "Critical"

    init(score: Double, confidence: Double, label: String) {
        self.score = score
        self.confidence = confidence
        self.label = label
    }
}

struct TopicResult: Sendable, Equatable, Codable {
    let category: String
    let confidence: Double   // 0.0 to 1.0
    let evidence: [String]   // Extracted keywords / entities supporting the category

    init(category: String, confidence: Double, evidence: [String] = []) {
        self.category = category
        self.confidence = confidence
        self.evidence = evidence
    }
}

struct SummaryResult: Sendable, Equatable, Codable {
    let text: String
    let sentencesUsed: Int
    let confidence: Double

    init(text: String, sentencesUsed: Int, confidence: Double) {
        self.text = text
        self.sentencesUsed = sentencesUsed
        self.confidence = confidence
    }
}

// MARK: - Capability Protocols (Model-Agnostic)

protocol SentimentAnalyzing: Sendable {
    func analyzeSentiment(for text: String) async -> SentimentResult
}

protocol EntityExtracting: Sendable {
    func extractEntities(from text: String) async -> [EntityResult]
}

protocol TopicClassifying: Sendable {
    func classifyTopic(title: String, description: String, text: String?, rssCategory: String?) async -> TopicResult?
}

protocol ArticleSummarizing: Sendable {
    func summarize(title: String, content: String) async -> SummaryResult
}

protocol ContentCleaning: Sendable {
    func cleanContent(_ rawText: String) -> String
}

// MARK: - NaturalLanguage Implementations

final class NaturalLanguageSentimentAnalyzer: SentimentAnalyzing {
    init() {}

    func analyzeSentiment(for text: String) async -> SentimentResult {
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

final class NaturalLanguageEntityExtractor: EntityExtracting {
    init() {}

    func extractEntities(from text: String) async -> [EntityResult] {
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

final class NaturalLanguageTopicClassifier: TopicClassifying {
    init() {}

    private static let taxonomy: [(category: String, keywords: [String])] = [
        ("Science", ["science", "research", "study", "discovery", "space", "nasa", "physics", "biology", "chemistry", "climate", "species", "quantum", "astronomy", "planet", "genome", "laboratory", "experiment", "rocket", "satellite"]),
        ("Tech", ["tech", "software", "hardware", "artificial intelligence", "computer", "silicon valley", "cyber", "programming", "developer", "machine learning", "chip", "semiconductor", "startup", "coding", "algorithm", "neural", "apple", "google", "microsoft"]),
        ("U.S. Politics", ["congress", "senate", "democrat", "republican", "white house", "legislation", "campaign", "electoral", "president", "biden", "trump"]),
        ("Sports", ["sport", "football", "basketball", "soccer", "baseball", "nfl", "nba", "mlb", "athlete", "championship", "league", "coach", "olympic", "tennis", "golf", "tournament"]),
        ("Business", ["market", "stock", "economy", "finance", "wall street", "investor", "venture", "ipo", "revenue", "profit", "earnings", "trade", "inflation", "bank"]),
        ("Health & Wellness", ["health", "medical", "doctor", "hospital", "disease", "treatment", "vaccine", "mental health", "wellness", "fitness", "nutrition", "therapy", "clinical"]),
        ("Entertainment", ["entertainment", "movie", "film", "celebrity", "music", "television", "hollywood", "streaming", "netflix", "disney", "actor", "actress", "concert", "album", "grammy", "oscar"]),
        ("World", ["international", "global", "europe", "asia", "africa", "foreign", "united nations", "diplomat", "treaty", "conflict", "war"]),
        ("Travel", ["travel", "flight", "airline", "hotel", "tourism", "destination", "vacation", "airport", "cruise"]),
        ("Fashion", ["fashion", "designer", "runway", "clothing", "trend", "outfit", "accessory"])
    ]

    func classifyTopic(title: String, description: String, text: String?, rssCategory: String?) async -> TopicResult? {
        // 1. Exact or high-confidence match on RSS category
        if let rssCat = rssCategory?.trimmingCharacters(in: .whitespacesAndNewlines), !rssCat.isEmpty {
            for item in Self.taxonomy {
                if rssCat.localizedCaseInsensitiveContains(item.category) {
                    return TopicResult(category: item.category, confidence: 0.95, evidence: [rssCat])
                }
            }
        }

        // 2. Score title and description against taxonomy with weighted evidence
        let titleLower = title.lowercased()
        let descLower = description.lowercased()
        let bodyLower = (text ?? "").prefix(2000).lowercased()

        var bestCategory: String?
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
            return TopicResult(category: cat, confidence: confidence, evidence: bestEvidence)
        }

        return nil
    }
}

final class ExtractiveArticleSummarizer: ArticleSummarizing {
    init() {}

    func summarize(title: String, content: String) async -> SummaryResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SummaryResult(text: title, sentencesUsed: 1, confidence: 0.5)
        }

        // Split content into sentences
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

        // Score sentences based on position, title overlap, and length
        var scored: [(sentence: String, score: Double, originalIndex: Int)] = []
        for (idx, sentence) in sentences.enumerated() {
            var score = 0.0
            // Position weight (earlier sentences in journalism are more informative)
            score += max(0, 5.0 - Double(idx) * 0.5)

            // Title overlap
            let sWords = Set(sentence.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let overlap = titleWords.intersection(sWords).count
            score += Double(overlap) * 2.5

            // Optimal length bonus (80-220 characters)
            if sentence.count >= 80 && sentence.count <= 220 {
                score += 2.0
            }

            scored.append((sentence, score, idx))
        }

        // Pick top 2 most informative sentences, presented in chronological order
        scored.sort { $0.score > $1.score }
        let topCount = min(2, scored.count)
        let selected = scored.prefix(topCount).sorted { $0.originalIndex < $1.originalIndex }
        let summaryText = selected.map { $0.sentence }.joined(separator: " ")

        return SummaryResult(text: summaryText, sentencesUsed: topCount, confidence: 0.85)
    }
}

final class ProseContentCleaner: ContentCleaning {
    init() {}

    func cleanContent(_ rawText: String) -> String {
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

// MARK: - Unified ArticleIntelligence Facade

final class ArticleIntelligence: Sendable {
    static let shared = ArticleIntelligence()

    let sentimentAnalyzer: SentimentAnalyzing
    let entityExtractor: EntityExtracting
    let topicClassifier: TopicClassifying
    let summarizer: ArticleSummarizing
    let contentCleaner: ContentCleaning

    init(
        sentimentAnalyzer: SentimentAnalyzing = NaturalLanguageSentimentAnalyzer(),
        entityExtractor: EntityExtracting = NaturalLanguageEntityExtractor(),
        topicClassifier: TopicClassifying = NaturalLanguageTopicClassifier(),
        summarizer: ArticleSummarizing = ExtractiveArticleSummarizer(),
        contentCleaner: ContentCleaning = ProseContentCleaner()
    ) {
        self.sentimentAnalyzer = sentimentAnalyzer
        self.entityExtractor = entityExtractor
        self.topicClassifier = topicClassifier
        self.summarizer = summarizer
        self.contentCleaner = contentCleaner
    }

    /// Full multi-dimensional analysis generating insight string, entities, and sentiment.
    func analyzeArticle(title: String, description: String) async -> String {
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
    func categorizeArticle(title: String, description: String, text: String? = nil, rssCategory: String? = nil) async -> TopicResult? {
        await topicClassifier.classifyTopic(title: title, description: description, text: text, rssCategory: rssCategory)
    }

    /// Produces concise extractive summary of full article text.
    func summarizeArticle(title: String, content: String) async -> SummaryResult {
        await summarizer.summarize(title: title, content: content)
    }

    /// Cleans extracted raw HTML text to remove boilerplate and navigation artifacts.
    func cleanContent(_ rawText: String) -> String {
        contentCleaner.cleanContent(rawText)
    }
}
