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
import NaturalLanguage

/// On-device entity extraction actor utilizing Apple NaturalLanguage `NLTagger` (W2 #716).
/// Strictly detached from the main thread with zero cloud or network dependencies.
public actor EntityExtractionService {
    public static let shared = EntityExtractionService()

    public init() {}

    /// Canonical slug generation for entities (e.g. "person:satya-nadella", "organization:apple", "location:san-francisco").
    public static func canonicalSlug(name: String, type: EntityType) -> String {
        let lower = name.lowercased()
        let alphanumeric = lower.map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let cleaned = String(alphanumeric)
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(type.rawValue):\(cleaned)"
    }

    /// Cleans entity names by stripping extraneous punctuation and whitespace.
    public static func cleanCanonicalName(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    public struct ExtractionResult: Sendable {
        public let entities: [EntityRecord]
        public let mentions: [EntityMention]
        public let coOccurrences: [EntityCoOccurrence]

        public init(
            entities: [EntityRecord],
            mentions: [EntityMention],
            coOccurrences: [EntityCoOccurrence]
        ) {
            self.entities = entities
            self.mentions = mentions
            self.coOccurrences = coOccurrences
        }
    }

    private struct RawMention {
        let entityId: String
        let name: String
        let type: EntityType
        let offset: Int
    }

    /// Extracts Person, Organization, and Location entities from the provided text.
    public func extractEntities(
        from text: String,
        articleId: String,
        publisherId: String,
        publishedAt: Date
    ) -> ExtractionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ExtractionResult(entities: [], mentions: [], coOccurrences: [])
        }

        let rawMentions = collectRawMentions(from: text)
        let (entities, mentions) = buildEntitiesAndMentions(
            from: rawMentions,
            articleId: articleId,
            publisherId: publisherId,
            publishedAt: publishedAt
        )
        let coOccurrences = buildCoOccurrences(from: entities)

        return ExtractionResult(
            entities: entities,
            mentions: mentions,
            coOccurrences: coOccurrences
        )
    }

    private func mapTag(_ tag: NLTag) -> EntityType? {
        switch tag {
        case .personalName: return .person
        case .organizationName: return .organization
        case .placeName: return .location
        default: return nil
        }
    }

    private func cleanName(_ rawString: String) -> String? {
        var cleanedName = Self.cleanCanonicalName(rawString)
        let prefixes = ["CEO ", "President ", "Dr. ", "Mr. ", "Ms. ", "Mrs. ", "Senator ", "Governor "]
        for prefix in prefixes where cleanedName.hasPrefix(prefix) {
            cleanedName = String(cleanedName.dropFirst(prefix.count)).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        guard cleanedName.count >= 2, let firstChar = cleanedName.first, firstChar.isUppercase else { return nil }
        if cleanedName.allSatisfy({ $0.isNumber || $0.isPunctuation }) { return nil }
        return cleanedName
    }

    private func collectRawMentions(from text: String) -> [RawMention] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        var rawMentions: [RawMention] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, tokenRange in
            guard let tag = tag, let entityType = mapTag(tag) else { return true }
            guard let cleanedName = cleanName(String(text[tokenRange])) else { return true }
            let slug = Self.canonicalSlug(name: cleanedName, type: entityType)
            let offset = text.distance(from: text.startIndex, to: tokenRange.lowerBound)
            rawMentions.append(RawMention(entityId: slug, name: cleanedName, type: entityType, offset: offset))
            return true
        }
        return rawMentions
    }

    private func buildEntitiesAndMentions(
        from rawMentions: [RawMention],
        articleId: String,
        publisherId: String,
        publishedAt: Date
    ) -> ([EntityRecord], [EntityMention]) {
        var mentionCounts: [String: Int] = [:]
        var canonicalNames: [String: String] = [:]
        var entityTypes: [String: EntityType] = [:]

        for item in rawMentions {
            mentionCounts[item.entityId, default: 0] += 1
            if canonicalNames[item.entityId] == nil || item.name.count > (canonicalNames[item.entityId]?.count ?? 0) {
                canonicalNames[item.entityId] = item.name
            }
            entityTypes[item.entityId] = item.type
        }

        var mentions: [EntityMention] = []
        for raw in rawMentions {
            let count = mentionCounts[raw.entityId] ?? 1
            let confidence = min(0.99, 0.85 + Float(count - 1) * 0.03)
            let mention = EntityMention(
                id: "\(articleId):\(raw.offset):\(raw.entityId)",
                entityId: raw.entityId,
                articleId: articleId,
                publisherId: publisherId,
                publishedAt: publishedAt,
                passageOffset: raw.offset,
                confidence: confidence
            )
            mentions.append(mention)
        }

        var entities: [EntityRecord] = []
        for (slug, count) in mentionCounts {
            guard let name = canonicalNames[slug], let type = entityTypes[slug] else { continue }
            let record = EntityRecord(
                id: slug,
                canonicalName: name,
                entityType: type,
                mentionCount: count,
                firstSeen: publishedAt,
                lastSeen: publishedAt
            )
            entities.append(record)
        }
        return (entities, mentions)
    }

    private func buildCoOccurrences(from entities: [EntityRecord]) -> [EntityCoOccurrence] {
        let sortedEntities = entities.sorted { $0.id < $1.id }
        guard sortedEntities.count >= 2 else { return [] }

        var coOccurrences: [EntityCoOccurrence] = []
        for i in 0..<sortedEntities.count {
            for j in (i + 1)..<sortedEntities.count {
                let a = sortedEntities[i]
                let b = sortedEntities[j]
                coOccurrences.append(
                    EntityCoOccurrence(
                        sourceEntityId: a.id,
                        targetEntityId: b.id,
                        targetCanonicalName: b.canonicalName,
                        targetEntityType: b.entityType,
                        coOccurrenceCount: 1
                    )
                )
            }
        }
        return coOccurrences
    }

    /// Extracts entities from a FeedArticle and persists them to the database if the article passes quality checks.
    @discardableResult
    func extractAndStore(article: FeedArticle, database: DatabaseEngine) async throws -> Bool {
        // W1 Integration check: Skip paywalled, barrier-restricted, or empty articles
        if try await database.fetchArticleReaderBarrier(articleID: article.id) != nil {
            return false
        }

        let fullText = [article.title, article.description, article.fullContent ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !fullText.isEmpty else { return false }

        let publisher = article.source.isEmpty ? (article.identityFeedURL ?? "unknown") : article.source
        let extraction = extractEntities(
            from: fullText,
            articleId: article.id,
            publisherId: publisher,
            publishedAt: article.pubDate
        )

        guard !extraction.entities.isEmpty else { return false }

        try await database.saveEntities(
            entities: extraction.entities,
            mentions: extraction.mentions,
            coOccurrences: extraction.coOccurrences
        )
        return true
    }
}
