import Foundation
import NaturalLanguage

/// Fully async AI analysis using NaturalLanguage framework.
/// Performs real sentiment scoring, named entity extraction, auto-categorization,
/// and content cleaning per article.
class AIManager {
    static let shared = AIManager()

    // MARK: - Article Intelligence Summary

    func analyzeArticle(title: String, description: String) async -> String {
        let fullText = "\(title). \(description)"

        // 1. Sentiment analysis
        let sentimentScore = computeSentiment(for: fullText)
        let sentimentLabel: String
        if sentimentScore > 0.3 {
            sentimentLabel = "Positive"
        } else if sentimentScore < -0.3 {
            sentimentLabel = "Critical"
        } else {
            sentimentLabel = "Neutral"
        }

        // 2. Named entity extraction
        let entities = extractEntities(from: fullText)

        // 3. Compose a genuinely unique insight
        if !entities.isEmpty {
            let entityList = entities.prefix(3).joined(separator: ", ")
            return "\(sentimentLabel) coverage · Key focus: \(entityList)"
        } else {
            let topics = extractTopics(from: fullText)
            if !topics.isEmpty {
                let topicList = topics.prefix(2).joined(separator: " & ")
                return "\(sentimentLabel) analysis · Topics: \(topicList)"
            }
            return "\(sentimentLabel) analysis · Developing story"
        }
    }

    // MARK: - NLP-Based Auto-Categorization

    /// Uses NLP entity/topic extraction to categorize, with keyword fallback.
    func categorizeArticle(title: String, description: String, rssCategory: String?) -> String? {
        // 1. If RSS already gave a recognized category, use it
        if let cat = rssCategory, !cat.isEmpty {
            if let matched = matchCategoryFromText(cat) { return matched }
        }

        let fullText = "\(title). \(description)"

        // 2. Use NLP to extract dominant entities and nouns, then match
        let entities = extractEntities(from: fullText)
        let topics = extractTopics(from: fullText)

        // Build a text blob from entities + topics for matching
        let nlpBlob = (entities + topics).joined(separator: " ").lowercased()
        if let matched = matchCategoryFromText(nlpBlob) { return matched }

        // 3. Keyword fallback on raw title + description
        if let matched = matchCategoryFromText(fullText) { return matched }

        return nil
    }

    private func matchCategoryFromText(_ text: String) -> String? {
        let lower = text.lowercased()

        // Ordered by specificity
        let categories: [(String, [String])] = [
            ("Science", ["science", "research", "study", "discovery", "space", "nasa", "physics", "biology", "chemistry", "climate", "species", "quantum", "astronomy", "planet", "genome", "laboratory", "experiment", "rocket", "satellite"]),
            ("Tech", ["tech", "software", "hardware", "artificial intelligence", "computer", "silicon valley", "cyber", "programming", "developer", "machine learning", "chip", "semiconductor", "startup", "coding", "algorithm", "neural"]),
            ("U.S. Politics", ["congress", "senate", "democrat", "republican", "white house", "legislation", "campaign", "electoral"]),
            ("Sports", ["sport", "football", "basketball", "soccer", "baseball", "nfl", "nba", "mlb", "athlete", "championship", "league", "coach", "olympic", "tennis", "golf", "tournament"]),
            ("Business", ["market", "stock", "economy", "finance", "wall street", "investor", "venture", "ipo", "revenue", "profit", "earnings", "trade", "inflation", "bank"]),
            ("Health & Wellness", ["health", "medical", "doctor", "hospital", "disease", "treatment", "vaccine", "mental health", "wellness", "fitness", "nutrition", "therapy", "clinical"]),
            ("Entertainment", ["entertainment", "movie", "film", "celebrity", "music", "television", "hollywood", "streaming", "netflix", "disney", "actor", "actress", "concert", "album", "grammy", "oscar"]),
            ("World", ["international", "global", "europe", "asia", "africa", "foreign", "united nations", "diplomat", "treaty", "conflict"]),
            ("Travel", ["travel", "flight", "airline", "hotel", "tourism", "destination", "vacation", "airport", "cruise"]),
            ("Fashion", ["fashion", "designer", "runway", "clothing", "trend", "outfit", "accessory"])
        ]

        for (category, keywords) in categories {
            for keyword in keywords {
                if lower.contains(keyword) { return category }
            }
        }
        return nil
    }

    // MARK: - Content Cleaning (NLP-powered)

    /// Cleans extracted article text by removing boilerplate lines using NLP analysis.
    /// Keeps only lines that look like actual prose.
    func cleanExtractedContent(_ rawContent: String) -> String {
        let lines = rawContent.components(separatedBy: "\n\n")
        var cleanedParagraphs = [String]()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 30 else { continue }

            // Skip obvious boilerplate
            if isBoilerplate(trimmed) { continue }

            // Skip lines that look like navigation/list items (very short, no sentence)
            if trimmed.count < 60 && !trimmed.contains(".") && !trimmed.contains("?") { continue }

            // Skip lines that are mostly uppercase (usually headers/nav)
            let uppercaseRatio = Double(trimmed.filter { $0.isUppercase }.count) / Double(max(trimmed.count, 1))
            if uppercaseRatio > 0.6 && trimmed.count < 80 { continue }

            // Skip lines with too many special chars (navigation artifacts)
            let specialCharCount = trimmed.filter { "→←►▸▶|»«●■□☐✓✗×".contains($0) }.count
            if specialCharCount > 2 { continue }

            // NLP check: is this actual prose?
            if isProse(trimmed) {
                cleanedParagraphs.append(trimmed)
            }
        }

        // Deduplicate near-identical paragraphs
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

    /// Detects whether a paragraph is genuine prose (not navigation/ads/junk)
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
            return totalWordCount < 50 // Cap iterations for performance
        }

        // Prose paragraphs are >60% content words
        guard totalWordCount > 3 else { return false }
        let ratio = Double(contentWordCount) / Double(totalWordCount)
        return ratio > 0.5
    }

    /// Pattern-based boilerplate detection
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
            "breaking news, the latest updates", "get the .* newsletter",
            "share on", "tweet this", "pin it", "copy link", "print this",
            "download our app", "available on", "recommended for you",
            "more stories", "you may also like", "popular articles",
            "editor's picks"
        ]
        return junkPhrases.contains { lower.contains($0) }
    }

    // MARK: - NLP Primitives

    private func computeSentiment(for text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (sentiment, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        return Double(sentiment?.rawValue ?? "0") ?? 0.0
    }

    private func extractEntities(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var entities = [String]()
        var seen = Set<String>()

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if let tag = tag,
               (tag == .personalName || tag == .organizationName || tag == .placeName) {
                let word = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = word.lowercased()
                if word.count > 2 && !seen.contains(lower) {
                    seen.insert(lower)
                    entities.append(word)
                }
            }
            return true
        }
        return entities
    }

    private func extractTopics(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        var nouns = [String]()
        var seen = Set<String>()

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            if let tag = tag, tag == .noun {
                let word = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = word.lowercased()
                if word.count > 4 && !seen.contains(lower) {
                    seen.insert(lower)
                    nouns.append(word.capitalized)
                }
            }
            return true
        }
        return nouns
    }
}
