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
import Testing

extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EntityDossierSuite {
        @Test func entityExtractionAndNormalization() async {
            let service = EntityExtractionService()
            let text = "Microsoft CEO Satya Nadella visited Google in New York today."
            let (entities, mentions, coOccurrences) = await service.extractEntities(
                from: text,
                articleId: "art-test-1",
                publisherId: "test-wire",
                publishedAt: Date()
            )

            #expect(!entities.isEmpty)
            #expect(!mentions.isEmpty)

            let slugs = Set(entities.map(\.id))
            #expect(
                slugs.contains("person:satya-nadella")
                    || entities.contains { $0.canonicalName.contains("Satya Nadella") })
            #expect(
                slugs.contains("organization:microsoft") || entities.contains { $0.canonicalName.contains("Microsoft") }
            )
            #expect(slugs.contains("location:new-york") || entities.contains { $0.canonicalName.contains("New York") })

            // Co-occurrences among multiple entities
            if entities.count >= 2 {
                #expect(!coOccurrences.isEmpty)
            }
        }

        @Test func entityStorePersistenceAndDossier() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("news-entity-test-\(UUID().uuidString)")
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
                mentionCount: 3,
                firstSeen: now,
                lastSeen: now
            )
            let entity2 = EntityRecord(
                id: "organization:microsoft",
                canonicalName: "Microsoft",
                entityType: .organization,
                mentionCount: 5,
                firstSeen: now,
                lastSeen: now
            )

            let mention1 = EntityMention(
                id: "m-1",
                entityId: "person:satya-nadella",
                articleId: "art-101",
                publisherId: "Reuters",
                publishedAt: now,
                passageOffset: 12,
                confidence: 0.92
            )
            let mention2 = EntityMention(
                id: "m-2",
                entityId: "person:satya-nadella",
                articleId: "art-102",
                publisherId: "Bloomberg",
                publishedAt: now,
                passageOffset: 45,
                confidence: 0.88
            )

            let coOccurrence = EntityCoOccurrence(
                targetEntityId: "person:satya-nadella",
                targetCanonicalName: "organization:microsoft",
                targetEntityType: .organization,
                coOccurrenceCount: 4
            )

            try await database.saveEntities(
                entities: [entity1, entity2],
                mentions: [mention1, mention2],
                coOccurrences: [coOccurrence]
            )

            // Test Fetch Entity
            let fetched = try await database.fetchEntity(id: "person:satya-nadella")
            #expect(fetched != nil)
            #expect(fetched?.canonicalName == "Satya Nadella")
            #expect(fetched?.mentionCount == 3)

            // Test Top Entities
            let topPersons = try await database.fetchTopEntities(type: .person, limit: 10)
            #expect(!topPersons.isEmpty)
            #expect(topPersons.first?.id == "person:satya-nadella")

            // Test Article Mentions
            let artMentions = try await database.fetchEntityMentions(articleId: "art-101")
            #expect(artMentions.count == 1)
            #expect(artMentions.first?.entityId == "person:satya-nadella")

            // Test Dossier Assembly
            let dossier = try await database.fetchEntityDossier(entityId: "person:satya-nadella", referenceDate: now)
            #expect(dossier != nil)
            #expect(dossier?.entity.canonicalName == "Satya Nadella")
            #expect(dossier?.publisherBreakdown.count == 2)
            #expect(dossier?.coOccurringEntities.count == 1)
            #expect(
                dossier?.coOccurringEntities.first?.targetEntityId == "organization:microsoft"
                    || dossier?.coOccurringEntities.first?.targetCanonicalName.contains("Microsoft") == true)

            // Verify publisher share sum
            let totalShare = dossier?.publisherBreakdown.reduce(0.0) { $0 + $1.share } ?? 0.0
            #expect(abs(totalShare - 1.0) < 0.001)
        }

        @Test func publisherHealthQualityFilter() async throws {
            let service = EntityExtractionService()
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("news-health-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let dbURL = tempDir.appendingPathComponent("test.sqlite3")
            let database = DatabaseEngine(path: dbURL.path)
            try await database.open()

            let paywalledArticle = FeedArticle(
                title: "Subscriber Exclusive Story",
                link: "https://wsj.com/sample",
                guid: "art-paywalled",
                description: "Teaser content only",
                pubDate: Date(),
                source: "The Wall Street Journal",
                fullContent: "Full body behind barrier"
            )
            try await database.recordReaderBarrier(.subscriber, articleID: paywalledArticle.id)

            let stored = try await service.extractAndStore(article: paywalledArticle, database: database)
            #expect(!stored)

            let count = try await database.fetchTopEntities(limit: 10).count
            #expect(count == 0)
        }
    }
}
