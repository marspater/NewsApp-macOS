// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

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
        guard !trimmed.isEmpty else { return nil }

        if let exact = matchExact(trimmed) { return exact }
        // Whole words only: "Wildlife" is not Lifestyle, "Stockholm" is not Business and "Homeland" is not a home.
        let padded = MuteRules.paddedPhrase(trimmed)
        if let highPriority = matchHighPriorityOverlap(padded) { return highPriority }
        return matchSynonyms(padded)
    }

    private static func matchExact(_ trimmed: String) -> NewsCategory? {
        allCases.first { $0.rawValue.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private static func contains(_ padded: String, any cues: [String]) -> Bool {
        cues.contains { padded.contains(MuteRules.paddedPhrase($0)) }
    }

    private static func matchHighPriorityOverlap(_ padded: String) -> NewsCategory? {
        if contains(
            padded,
            any: [
                "health", "medical", "medicine", "clinical", "hospital", "hospitals", "vaccine", "vaccines", "disease",
                "diseases", "pharma", "pharmaceutical", "pharmaceuticals",
            ])
        {
            return .health
        }
        if contains(
            padded, any: ["space", "nasa", "astronomy", "quantum", "biology", "physics", "telescope", "telescopes"])
        {
            return .science
        }
        if contains(
            padded,
            any: [
                "stock", "stocks", "wall street", "earnings", "inflation", "investor", "investors", "investing",
                "revenue", "revenues", "recession", "finance", "financial", "dividend", "dividends",
            ])
        {
            return .business
        }
        if contains(
            padded,
            any: [
                "congress", "senate", "election", "elections", "politics", "political", "lawmaker", "lawmakers",
                "parliament", "white house", "governor", "campaign", "campaigns",
            ])
        {
            return .politics
        }
        return nil
    }

    /// Whole-word cues in priority order; earlier groups win ("Life & Style" is Lifestyle, "Style" alone is Fashion).
    private static let synonymKeywordGroups: [(category: NewsCategory, cues: [String])] = [
        (
            .technology,
            [
                "tech", "technology", "fintech", "software", "hardware", "artificial intelligence", "ai", "cyber",
                "cybersecurity", "chip", "chips",
            ]
        ),
        (.business, ["econ", "economy", "economics", "economic", "biz", "market", "markets"]),
        (.sports, ["sport", "sports", "football", "basketball", "soccer", "league"]),
        (
            .entertainment,
            [
                "entertain", "entertainment", "movie", "movies", "film", "films", "music", "celebrity", "celebrities",
                "cinema",
            ]
        ),
        (.health, ["wellness", "fitness", "nutrition"]),
        (.travel, ["travel", "tourism", "vacation", "flight", "flights"]),
        (.food, ["food", "cook", "cooking", "dining", "culinary", "recipe", "recipes", "restaurant", "restaurants"]),
        (
            .world,
            [
                "global", "world", "international", "foreign", "geopolitics", "geopolitical", "united nations", "un",
                "diplomat", "diplomats", "diplomacy", "diplomatic",
            ]
        ),
        (.lifestyle, ["life", "living", "lifestyle", "home", "parenting"]),
        (.fashion, ["style", "fashion", "runway", "apparel"]),
        (.science, ["sci", "science", "research"]),
    ]

    private static func matchSynonyms(_ padded: String) -> NewsCategory? {
        synonymKeywordGroups.first { contains(padded, any: $0.cues) }?.category
    }
}

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

extension EntityResult {
    /// Collapse exact duplicates and unambiguous person surnames, including cached analyses.
    public static func readerTags(from entities: [EntityResult]) -> [EntityResult] {
        var seen = Set<String>()
        let normalized = entities.compactMap { entity -> EntityResult? in
            let name = entity.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            // ponytail: short named-entity labels only; a richer entity resolver can handle document titles later.
            guard !name.isEmpty, name.count <= 60, name.split(separator: " ").count <= 6,
                entity.confidence >= 0.5, seen.insert(key).inserted
            else { return nil }
            return EntityResult(name: name, type: entity.type, confidence: entity.confidence)
        }
        func personWords(_ name: String) -> [Substring] {
            let titles: Set<Substring> = ["mr", "mrs", "ms", "dr", "sir", "president", "senator"]
            return Array(MuteRules.words(name).drop(while: { titles.contains($0) }))
        }
        return normalized.filter { entity in
            let words = personWords(entity.name)
            guard entity.type == .person, words.count == 1 else { return true }
            let matches = normalized.filter {
                let full = personWords($0.name)
                return $0.type == .person && full.count > 1 && full.last == words.last
            }
            return matches.count != 1
        }
    }

    /// The reader tags for one story, most mentioned first. Each name scores its mentions in the body, with mentions in
    /// the title and description counted three times, and needs a score of 2, so a name the story passes over once
    /// makes no tag. A person counts their surname alone, since stories name people in full once.
    public static func readerTags(
        from entities: [EntityResult], title: String, description: String, text: String
    ) -> [EntityResult] {
        let scored = readerTags(from: entities).enumerated().map { offset, entity in
            let words = entity.name.split(separator: " ")
            let term =
                entity.type == .person && words.count > 1 && words.last!.count >= 3 ? String(words.last!) : entity.name
            let lead = mentions(of: term, in: title) + mentions(of: term, in: description)
            return (entity: entity, score: 3 * lead + mentions(of: term, in: text), offset: offset)
        }
        return scored.filter { $0.score >= 2 }
            .sorted { ($0.score, $1.offset) > ($1.score, $0.offset) }
            .map(\.entity)
    }

    /// Whole-word occurrences of `term` in `text`, case-sensitive so a surname like Price is not the word "price".
    static func mentions(of term: String, in text: String) -> Int {
        var count = 0
        var searched = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: .diacriticInsensitive, range: searched) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : " "
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : " "
            if !before.isLetter, !before.isNumber, !after.isLetter, !after.isNumber { count += 1 }
            searched = found.upperBound..<text.endIndex
        }
        return count
    }
}
