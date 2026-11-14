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

import CoreGraphics
import Foundation
import Testing

/// Native port of the `EditorialIntelligenceTests` atom (#1070): its four `private` test functions as four tests, in
/// the runner's order, with each local `check` turned into `expectTrue` of NativeExpectations.swift and each force
/// unwrap into `#require` (the runner log is invisible to Swift Testing, and the runner exits on a failure), so a
/// failure is recorded and later tests still run. The entity graph test now throws to reach `#require`. DualReaderSuite,
/// HotspotMapSuite and EntityDossierSuite test the same services with their own cases; this file keeps the atom's. The
/// runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EditorialIntelligenceSuite {
        @Test func entityGraph() throws {
            expectTrue(EntityGraph.slug(name: "São Paulo", type: .place) == "place:sao-paulo", "Slugs fold diacritics")
            let graph: EntityGraph.Adjacency = ["H": [("A", 2), ("B", 2)], "A": [("H", 2)], "B": [("H", 2)]]
            let rank = EntityGraph.pageRank(graph)
            expectTrue(abs(rank.values.reduce(0, +) - 1) < 1e-9, "PageRank sums to one")
            expectTrue(try #require(rank["H"]) > (try #require(rank["A"])), "The hub is the most central entity")
        }

        @Test func dualReaderAlignment() async {
            let service = DualReaderAlignmentService()
            let leftTitle = "Global Energy Agreement Signed"
            let leftBody = """
                Participating nations agreed on formal emissions reductions targets during Friday's Geneva summit.

                Small businesses expressed anxiety about transitioning operational facilities before 2030 deadlines.
                """

            let rightTitle = "Global Energy Agreement Signed"
            let rightBody = """
                Participating nations agreed on formal emissions reductions targets during Friday's Geneva summit.

                Industry trade groups applauded the regulatory certainty provided by the new energy standards.
                """

            let session = await service.align(
                left: .init(
                    id: "left-101",
                    title: leftTitle,
                    content: leftBody,
                    publisher: "Times Wire"
                ),
                right: .init(
                    id: "right-101",
                    title: rightTitle,
                    content: rightBody,
                    publisher: "Market Gazette"
                ),
                clusterId: "cluster-55"
            )

            expectTrue(!session.passageAlignments.isEmpty, "Dual reader alignments generated")
            expectTrue(session.consensusCount >= 1, "Consensus detected for identical opening statement")
            expectTrue(session.consensusScore > 0, "Consensus score is positive")
            let blankPassages = await service.extractPassages(title: "  ", content: "short")
            expectTrue(blankPassages.isEmpty, "A blank article yields no passages, so no 100% blank match")
            let shortPassages = await service.extractPassages(
                title: "Resignation", content: "The president resigned.\n\nHe resigned.\n\nRead more")
            expectTrue(
                shortPassages == ["Resignation", "The president resigned.", "He resigned."],
                "Short sentences stay, labels go")
            expectTrue(DualReaderLayoutMode.mode(for: 1300) == .sideBySide, "Adaptive layout side-by-side above 1200pt")
            expectTrue(DualReaderLayoutMode.mode(for: 900) == .stacked, "Adaptive layout stacked below 1200pt")
        }

        @Test func hotspotMapProjection() {
            let service = HotspotProjectionService()
            let canvas = CGSize(width: 1000, height: 500)

            let origin = service.projectEquirectangular(
                coordinate: GeographicCoordinate(latitude: 0, longitude: 0),
                canvasSize: canvas
            )
            expectTrue(abs(origin.x - 500.0) < 0.1, "Equirectangular center X matches 500")
            expectTrue(abs(origin.y - 250.0) < 0.1, "Equirectangular center Y matches 250")

            let kyivCoord = service.resolveCoordinate(for: "Kyiv")
            expectTrue(kyivCoord != nil, "Resolved location coordinate for Kyiv")
            expectTrue(kyivCoord?.latitude ?? 0 > 40.0, "Kyiv latitude is in Northern hemisphere")

            let telAviv = service.resolveCoordinate(for: "Tel-Aviv")
            expectTrue(telAviv != nil, "Resolved location coordinate for Tel-Aviv")

            let indiana = service.resolveCoordinate(for: "Indiana")
            expectTrue(indiana == nil, "Unrelated substring Indiana returns nil")

            let closest = service.closestRegion(for: GeographicCoordinate(latitude: 49.0, longitude: 31.0))
            expectTrue(closest?.id == "UA", "Matched closest hotspot region UA for Ukraine coordinate")

            let sydney = GeographicCoordinate(latitude: -33.86, longitude: 151.2)
            expectTrue(
                service.closestRegion(for: sydney) == nil, "Distant coordinate outside standard regions returns nil")
            expectTrue(service.theater(forLocationNamed: "kyiv")?.id == "UA", "Kyiv belongs to Eastern Europe")
            expectTrue(service.theater(forLocationNamed: "seoul")?.id == "KR", "Seoul belongs to Korean Peninsula")
            expectTrue(
                service.theater(forLocationNamed: "beijing") == nil, "Beijing is not assigned to Korean Peninsula")
            expectTrue(service.theater(forLocationNamed: "warsaw") == nil, "Warsaw is not assigned to Western Europe")

            expectTrue(HotspotTensionLevel.level(for: 80.0) == .critical, "Tension score 80 is critical")
            expectTrue(HotspotTensionLevel.level(for: 50.0) == .significant, "Tension score 50 is significant")
            expectTrue(HotspotTensionLevel.level(for: 20.0) == .elevated, "Tension score 20 is elevated")

            let reading = WorldTensionReading(
                evaluatedAt: Date(timeIntervalSince1970: 1_793_300_435), inputHash: "hotspots",
                modelGeneration: "test",
                headlines: [
                    WorldTensionHeadline(id: "C1", title: "Airstrike hits Kyiv overnight", publisher: "Wire A"),
                    WorldTensionHeadline(id: "C2", title: "Weather mild in Paris this week", publisher: "Wire C"),
                ],
                assessment: WorldTensionAssessment(score: 50, summary: "", reasons: []))
            let hotspots = WorldTensionHotspots(reading: reading)
            expectTrue(
                hotspots.pins.map(\.id) == ["kyiv"], "Hotspot pins come from tension-cue headlines that name a place")
            expectTrue(hotspots.regions.map(\.id) == ["UA"], "A region no headline reaches is absent, not fixed")
        }

        @Test func entityIndexAndDossier() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "news-entity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
            try await database.open()
            let now = Date(timeIntervalSince1970: 1_793_372_400)
            let keys: [String] = ["one", "two", "three"]  // typed: `guid:` would make the literal `[String?]`
            let articles = keys.enumerated().map { index, key in
                FeedArticle(
                    title: "Story \(key)", link: "https://example.com/\(key)", guid: key, description: "Dek \(key)",
                    pubDate: now.addingTimeInterval(-Double(index + 1) * 86_400), source: "Publisher \(index)",
                    fullContent: "Body of \(key)")
            }
            try await database.upsertArticles(articles)
            let harbour = IndexedEntity(name: "Harbour Authority", type: .organization, score: 4)
            let maria = IndexedEntity(name: "Maria Ortega", type: .person, score: 5)
            let candidates = try await database.entityIndexCandidates(limit: 10)
            expectTrue(candidates.count == 3, "Every stored story waits for the index")
            let batch = candidates.map { ($0, $0.title == "Story three" ? [harbour] : [harbour, maria]) }
            let generation = await database.analysisGeneration
            let saved = try await database.saveEntityIndex(batch, expectedGeneration: generation)
            expectTrue(saved, "The index batch is written")
            expectTrue(try await database.entityIndexCandidates(limit: 10).isEmpty, "A story is read once")
            _ = try await database.refreshEntityGraph(now: now, expectedGeneration: generation, withCentrality: true)
            let dossier = try await database.fetchEntityDossier(id: "organization:harbour-authority", now: now)
            expectTrue(dossier?.coverage.count == 30, "A dossier covers 30 days")
            expectTrue(dossier?.storiesInWindow == 3, "Three stories name Harbour Authority")
            expectTrue(dossier?.related.map(\.entity.id) == ["person:maria-ortega"], "Related entities share stories")
            expectTrue(dossier?.related.first?.sharedStories == 2, "A relationship counts its shared stories")
            try await database.clearArticleEnrichment()
            expectTrue(
                try await database.fetchEntity(id: "organization:harbour-authority") == nil, "Clear removes entities")
            await database.close()
        }
    }
}
