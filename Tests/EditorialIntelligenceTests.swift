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

/// Regression and integrity suite for Epic #714 Editorial Intelligence (#716, #717, #718).
enum EditorialIntelligenceTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            fputs("❌ Editorial intelligence: \(message)\n", stderr)
        }
    }

    static func run() async {
        fputs("Running EditorialIntelligenceTests...\n", stderr)
        await testEntityExtraction()
        do {
            try await testEntityStorePersistence()
            try await testEntityDossierAssembly()
            try await testPublisherQualityFilter()
        } catch {
            failures += 1
            fputs("❌ Editorial intelligence unexpected error: \(error)\n", stderr)
        }
        if failures == 0 {
            fputs("✅ Editorial intelligence: all \(checks) checks passed\n", stderr)
        } else {
            fputs("❌ Editorial intelligence failed with \(failures) failures across \(checks) checks\n", stderr)
            exit(1)
        }
    }

    private static func testEntityExtraction() async {
        let service = EntityExtractionService()
        let text = "Microsoft CEO Satya Nadella visited Google in New York today."
        let result = await service.extractEntities(
            from: text,
            articleId: "art-test-1",
            publisherId: "test-wire",
            publishedAt: Date()
        )
        let entities = result.entities
        let mentions = result.mentions
        let coOccurrences = result.coOccurrences

        check(!entities.isEmpty, "Entities extracted from sample sentence")
        check(!mentions.isEmpty, "Mentions created from sample sentence")

        let slugs = Set(entities.map(\.id))
        check(
            slugs.contains("person:satya-nadella") || entities.contains { $0.canonicalName.contains("Satya Nadella") },
            "Person entity extracted")
        check(
            slugs.contains("organization:microsoft") || entities.contains { $0.canonicalName.contains("Microsoft") },
            "Organization entity extracted")
        check(
            slugs.contains("location:new-york") || entities.contains { $0.canonicalName.contains("New York") },
            "Location entity extracted")

        if entities.count >= 2 {
            check(!coOccurrences.isEmpty, "Co-occurrences calculated across entities in same article")
        }
    }

    private static func testEntityStorePersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("news-entity-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite3")
        let database = DatabaseEngine(path: dbURL.path)
        try await database.open()

        let now = Date()
        let entity = EntityRecord(
            id: "person:satya-nadella",
            canonicalName: "Satya Nadella",
            entityType: .person,
            mentionCount: 3,
            firstSeen: now,
            lastSeen: now
        )
        let mention = EntityMention(
            id: "m-1",
            entityId: "person:satya-nadella",
            articleId: "art-101",
            publisherId: "Reuters",
            publishedAt: now,
            passageOffset: 12,
            confidence: 0.92
        )

        try await database.saveEntities(
            entities: [entity],
            mentions: [mention],
            coOccurrences: []
        )

        let fetched = try await database.fetchEntity(id: "person:satya-nadella")
        check(fetched != nil, "Fetched saved entity from database")
        check(fetched?.canonicalName == "Satya Nadella", "Canonical name preserved")
        check(fetched?.mentionCount == 3, "Mention count preserved")

        let topPersons = try await database.fetchTopEntities(type: .person, limit: 10)
        check(topPersons.count == 1, "Top person query returns 1 item")
        check(topPersons.first?.id == "person:satya-nadella", "Top person matches inserted ID")
    }

    private static func testEntityDossierAssembly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("news-dossier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite3")
        let database = DatabaseEngine(path: dbURL.path)
        try await database.open()

        let now = Date()
        let entity1 = EntityRecord(
            id: "person:satya-nadella",
            canonicalName: "Satya Nadella",
            entityType: .person,
            mentionCount: 5,
            firstSeen: now,
            lastSeen: now
        )
        let entity2 = EntityRecord(
            id: "organization:microsoft",
            canonicalName: "Microsoft",
            entityType: .organization,
            mentionCount: 10,
            firstSeen: now,
            lastSeen: now
        )

        let m1 = EntityMention(
            id: "m-101",
            entityId: "person:satya-nadella",
            articleId: "art-1",
            publisherId: "Reuters",
            publishedAt: now,
            passageOffset: 0,
            confidence: 0.95
        )
        let m2 = EntityMention(
            id: "m-102",
            entityId: "person:satya-nadella",
            articleId: "art-2",
            publisherId: "Bloomberg",
            publishedAt: now,
            passageOffset: 15,
            confidence: 0.90
        )

        let co = EntityCoOccurrence(
            sourceEntityId: "person:satya-nadella",
            targetEntityId: "organization:microsoft",
            targetCanonicalName: "Microsoft",
            targetEntityType: .organization,
            coOccurrenceCount: 4
        )

        try await database.saveEntities(
            entities: [entity1, entity2],
            mentions: [m1, m2],
            coOccurrences: [co]
        )

        let dossier = try await database.fetchEntityDossier(entityId: "person:satya-nadella", referenceDate: now)
        check(dossier != nil, "Dossier assembled successfully")
        check(dossier?.publisherBreakdown.count == 2, "Publisher breakdown contains 2 publishers")
        check(!dossier!.coverage30Days.isEmpty, "Coverage timeline contains buckets")

        let totalShare = dossier?.publisherBreakdown.reduce(0.0) { $0 + $1.share } ?? 0.0
        check(abs(totalShare - 1.0) < 0.001, "Publisher shares sum to 1.0")

        let dossierB = try await database.fetchEntityDossier(entityId: "organization:microsoft", referenceDate: now)
        check(dossierB != nil, "Dossier for target entity assembled successfully")
        check(
            dossierB?.coOccurringEntities.first?.targetEntityId == "person:satya-nadella",
            "Target entity sees reverse co-occurrence")
    }

    private static func testPublisherQualityFilter() async throws {
        let service = EntityExtractionService()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("news-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite3")
        let database = DatabaseEngine(path: dbURL.path)
        try await database.open()

        let paywalledArticle = FeedArticle(
            title: "Exclusive Report",
            link: "https://wsj.com/story",
            guid: "art-paywalled",
            description: "Paywalled snippet",
            pubDate: Date(),
            source: "WSJ",
            fullContent: "Full paywalled text"
        )
        try await database.recordReaderBarrier(.subscriber, articleID: paywalledArticle.id)

        let extracted = try await service.extractAndStore(article: paywalledArticle, database: database)
        check(!extracted, "Article with reader barrier was excluded from extraction")

        let allEntities = try await database.fetchTopEntities(limit: 10)
        check(allEntities.isEmpty, "No entities stored for paywalled article")
    }
}
