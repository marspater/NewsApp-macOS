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
    /// W2 #716: the entity index, the co-reporting graph and the dossier.
    @Suite(.tags(.editorial, .integration)) struct EntityDossierSuite {
        static let now = Date(timeIntervalSince1970: 1_793_372_400)

        // MARK: Graph arithmetic

        @Test func slugFoldsCaseDiacriticsAndPunctuation() {
            #expect(EntityGraph.slug(name: "São Paulo", type: .place) == "place:sao-paulo")
            #expect(EntityGraph.slug(name: "SAO  PAULO!", type: .place) == "place:sao-paulo")
            #expect(EntityGraph.slug(name: "Vladimir Putin", type: .person) == "person:vladimir-putin")
            #expect(
                EntityGraph.slug(name: "Putin", type: .organization) != EntityGraph.slug(name: "Putin", type: .person))
        }

        @Test func recencyWeightFallsWithAgeButNeverToZero() {
            let weights = [0.5, 3, 10, 20, 90].map { EntityGraph.recencyWeight(ageDays: $0) }
            #expect(weights == [1.0, 0.7, 0.4, 0.2, 0.1])
            #expect(EntityGraph.recencySQL(ageDays: "x").contains("WHEN x < 2.0 THEN 1.0"))
        }

        @Test func pageRankSumsToOneAndRanksTheHub() {
            // H joins everyone; A and B join only H and each other.
            let graph: EntityGraph.Adjacency = [
                "H": [("A", 2), ("B", 2), ("C", 2)], "A": [("H", 2), ("B", 1)], "B": [("H", 2), ("A", 1)],
                "C": [("H", 2)],
            ]
            let rank = EntityGraph.pageRank(graph)
            #expect(abs(rank.values.reduce(0, +) - 1) < 1e-9)
            #expect(rank["H"]! > rank["A"]! && rank["A"]! > rank["C"]!)
            #expect(EntityGraph.pageRank([:]).isEmpty)
        }

        @Test func relatedEntitiesDiscountAHubAgainstItsCentrality() {
            // From S the hub H and the specific entity P are equally strong neighbours.
            let graph: EntityGraph.Adjacency = [
                "S": [("H", 3), ("P", 3)], "H": [("S", 3), ("X", 5), ("Y", 5)], "P": [("S", 3)],
            ]
            let walk = EntityGraph.personalizedPageRank(from: "S", in: graph)
            #expect(abs(walk.values.reduce(0, +) - 1) < 1e-9)
            #expect(walk["S"]! > walk["H"]!)

            let bare = EntityGraph.related(to: "S", in: graph, centrality: [:], floor: 0.1, limit: 2).map(\.id)
            #expect(Set(bare) == ["H", "P"])
            let discounted = EntityGraph.related(
                to: "S", in: graph, centrality: ["H": 0.6, "P": 0.02], floor: 0.1, limit: 2
            ).map(\.id)
            #expect(discounted.first == "P")
        }

        // MARK: Extraction

        @Test func indexerReadsReaderTagsWithoutThePublisherItself() async {
            let candidate = EntityIndexCandidate(
                articleID: "a", title: "Satya Nadella visits Microsoft campus in Seattle",
                description: "Reuters reports that Satya Nadella toured the Microsoft campus.",
                text: "Satya Nadella said Microsoft will hire in Seattle. Nadella thanked Reuters for the coverage.",
                publisher: "Reuters", publishedAt: Self.now, revision: 1)
            let entities = await EntityIndexer.shared.entities(of: candidate)
            #expect(!entities.isEmpty)
            #expect(entities.count <= EntityGraph.maximumEntitiesPerStory)
            #expect(entities.contains { $0.name.contains("Nadella") })
            #expect(!entities.contains { $0.name == "Reuters" })
            #expect(entities == entities.sorted { $0.score > $1.score })
        }

        // MARK: Store

        /// A library with four stories that name Harbour Authority; Maria Ortega and Northern Channel appear with it.
        private static func library() async throws -> (database: DatabaseEngine, directory: URL, ids: [String: String])
        {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "news-entity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
            try await database.open()
            func story(_ key: String, _ publisher: String, daysAgo: Double) -> FeedArticle {
                FeedArticle(
                    title: "Story \(key)", link: "https://example.com/\(key)", guid: key,
                    description: "Description \(key)", pubDate: now.addingTimeInterval(-daysAgo * 86_400),
                    source: publisher, fullContent: "Body of \(key)")
            }
            let articles = [
                story("one", "Reuters", daysAgo: 1), story("two", "Associated Press", daysAgo: 2),
                story("three", "Metro Desk", daysAgo: 3), story("old", "Reuters", daysAgo: 40),
            ]
            try await database.upsertArticles(articles)
            return (database, directory, Dictionary(uniqueKeysWithValues: articles.map { ($0.guid ?? "", $0.id) }))
        }

        private static let harbour = IndexedEntity(name: "Harbour Authority", type: .organization, score: 4)
        private static let maria = IndexedEntity(name: "Maria Ortega", type: .person, score: 5)
        private static let channel = IndexedEntity(name: "Northern Channel", type: .place, score: 2)

        private static func index(
            _ database: DatabaseEngine, _ lists: [String: [IndexedEntity]], generation: Int? = nil
        ) async throws -> Bool {
            let candidates = try await database.entityIndexCandidates(limit: 50)
            let batch = candidates.compactMap {
                candidate -> (candidate: EntityIndexCandidate, entities: [IndexedEntity])? in
                lists.first { candidate.title == "Story \($0.key)" }.map { (candidate, $0.value) }
            }
            let current = await database.analysisGeneration
            return try await database.saveEntityIndex(batch, expectedGeneration: generation ?? current)
        }

        @Test func indexingReadsEachStoryOnceAndSkipsBarriersAndDuplicates() async throws {
            let (database, directory, ids) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: directory) }

            try await database.recordReaderBarrier(.subscriber, articleID: ids["three"]!)
            let first = try await database.entityIndexCandidates(limit: 50)
            #expect(Set(first.map(\.articleID)) == [ids["one"]!, ids["two"]!, ids["old"]!])
            #expect(first.first?.articleID == ids["one"], "Newest first")

            #expect(try await Self.index(database, ["one": [Self.maria], "two": [Self.maria], "old": []]))
            #expect(try await database.entityIndexCandidates(limit: 50).isEmpty, "A story is read once")

            // The publisher changes the text: the story is a candidate again, and its mentions are replaced.
            try await database.upsertArticles([
                FeedArticle(
                    title: "Story one", link: "https://example.com/one", guid: "one", description: "A rewritten dek",
                    pubDate: Self.now.addingTimeInterval(-86_400), source: "Reuters", fullContent: "Body of one")
            ])
            #expect(try await database.entityIndexCandidates(limit: 50).map(\.articleID) == [ids["one"]!])
            #expect(try await Self.index(database, ["one": [Self.harbour]]))
            let maria = try await database.fetchEntity(id: "person:maria-ortega")
            #expect(maria?.storyCount == 1, "The rewritten story no longer names Maria Ortega")
        }

        @Test func countsStayExactWhenAStoryIsReadTwice() async throws {
            let (database, directory, _) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: directory) }
            let lists = ["one": [Self.harbour, Self.maria], "two": [Self.harbour], "three": [Self.harbour]]
            #expect(try await Self.index(database, lists))
            // Clearing the marker is what a publisher update does: read the same stories again.
            _ = try await database.eventRows("DELETE FROM entity_index;")
            #expect(try await Self.index(database, lists))

            let harbour = try await database.fetchEntity(id: "organization:harbour-authority")
            #expect(harbour?.storyCount == 3)
            #expect(try await database.fetchEntity(id: "person:maria-ortega")?.storyCount == 1)
            let rows = try await database.eventRows("SELECT count(*) FROM entity_mentions;")
            #expect(rows.first?[0] == "4")
        }

        @Test func graphDossierAndChips() async throws {
            let (database, directory, ids) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: directory) }
            let lone = IndexedEntity(name: "Lone Name", type: .person, score: 3)
            #expect(
                try await Self.index(
                    database,
                    [
                        "one": [Self.harbour, Self.maria, lone], "two": [Self.harbour, Self.maria, Self.channel],
                        "three": [Self.harbour, Self.channel], "old": [Self.maria],
                    ]))

            let report = try await database.refreshEntityGraph(
                now: Self.now, expectedGeneration: database.analysisGeneration)
            // Harbour–Maria (stories one, two) and Harbour–Channel (two, three) are relationships; Maria–Channel shares
            // only story two. Each is stored in both directions.
            #expect(report?.entities == 4)
            #expect(report?.edges == 4)
            let centrality = try await database.fetchEntity(id: "organization:harbour-authority")?.centrality ?? 0
            #expect(centrality > (try await database.fetchEntity(id: "person:maria-ortega")?.centrality ?? 1))

            let dossier = try #require(
                try await database.fetchEntityDossier(id: "organization:harbour-authority", now: Self.now))
            #expect(dossier.coverage.count == 30)
            #expect(
                dossier.coverage.last?.day == DatabaseEngine.windowStart(now: Self.now).addingTimeInterval(29 * 86_400))
            #expect(dossier.storiesInWindow == 3)
            #expect(abs(dossier.publishers.reduce(0) { $0 + $1.share } - 1) < 1e-9)
            #expect(Set(dossier.publishers.map(\.publisher)) == ["Reuters", "Associated Press", "Metro Desk"])
            #expect(dossier.recentStories.map(\.id) == [ids["one"]!, ids["two"]!, ids["three"]!], "Newest first")
            #expect(Set(dossier.related.map(\.entity.id)) == ["person:maria-ortega", "place:northern-channel"])
            #expect(dossier.related.allSatisfy { $0.sharedStories == 2 }, "Every relationship cites its stories")

            // The day a story was published lands in that UTC day's bar.
            let oneDay = Int(
                (Self.now.addingTimeInterval(-86_400).timeIntervalSince1970
                    - DatabaseEngine.windowStart(now: Self.now).timeIntervalSince1970) / 86_400)
            #expect(dossier.coverage[oneDay].storyCount == 1)

            // Maria's mention 40 days ago is outside the window but counts in her story total.
            let mariaDossier = try #require(
                try await database.fetchEntityDossier(id: "person:maria-ortega", now: Self.now))
            #expect(mariaDossier.entity.storyCount == 3)
            #expect(mariaDossier.storiesInWindow == 2)

            // Chips: an entity only one story names has no coverage to show.
            let chips = try await database.entities(forArticles: [ids["one"]!], limit: 8).map(\.id)
            #expect(Set(chips) == ["person:maria-ortega", "organization:harbour-authority"])
            #expect(try await database.entities(forArticles: [], limit: 8).isEmpty)
            #expect(try await database.fetchEntityDossier(id: "person:nobody", now: Self.now) == nil)
        }

        @Test func clearingDerivedDataEmptiesTheIndexAndRefusesStaleWrites() async throws {
            let (database, directory, _) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: directory) }
            let before = await database.analysisGeneration
            #expect(try await Self.index(database, ["one": [Self.harbour], "two": [Self.harbour]]))
            #expect(try await database.fetchEntity(id: "organization:harbour-authority") != nil)

            try await database.clearArticleEnrichment()
            #expect(try await database.fetchEntity(id: "organization:harbour-authority") == nil)
            #expect(try await database.entityIndexCandidates(limit: 50).count == 4, "Everything is unread again")

            // A pass that began before the clear must not bring its entities back.
            let candidates = try await database.entityIndexCandidates(limit: 50)
            let stale = try await database.saveEntityIndex(
                [(candidates[0], [Self.harbour])], expectedGeneration: before)
            #expect(!stale)
            #expect(try await database.topEntities().isEmpty)
            let graph = try await database.refreshEntityGraph(now: Self.now, expectedGeneration: before)
            #expect(graph == nil)
        }

        @Test func dossierQueriesAreAnsweredByIndexes() async throws {
            let (database, directory, _) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: directory) }
            let statements: [(sql: String, values: [DatabaseEngine.EventValue])] = [
                (DatabaseEngine.entityCoverageSQL, [.text("e"), .real(0)]),
                (DatabaseEngine.entityPublishersSQL, [.text("e"), .real(0)]),
                (DatabaseEngine.entityStoriesSQL, [.text("e")]),
                (DatabaseEngine.entityNeighboursSQL, [.text("e"), .text(EntityGraph.coReported), .integer(40)]),
            ]
            for statement in statements {
                let plan = try await database.eventRows("EXPLAIN QUERY PLAN " + statement.sql, statement.values)
                let details = plan.compactMap { $0.last ?? nil }
                #expect(
                    !details.contains { $0.hasPrefix("SCAN entity_") || $0.hasPrefix("SCAN articles") }, "\(details)")
                #expect(details.contains { $0.contains("SEARCH") }, "\(details)")
            }
        }
    }
}
