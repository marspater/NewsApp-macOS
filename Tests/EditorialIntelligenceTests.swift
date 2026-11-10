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
        testEntityGraph()
        await testDualReaderAlignment()
        testHotspotMapProjection()
        do {
            try await testEntityIndexAndDossier()
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

    private static func testEntityGraph() {
        check(EntityGraph.slug(name: "São Paulo", type: .place) == "place:sao-paulo", "Slugs fold diacritics")
        let graph: EntityGraph.Adjacency = ["H": [("A", 2), ("B", 2)], "A": [("H", 2)], "B": [("H", 2)]]
        let rank = EntityGraph.pageRank(graph)
        check(abs(rank.values.reduce(0, +) - 1) < 1e-9, "PageRank sums to one")
        check(rank["H"]! > rank["A"]!, "The hub is the most central entity")
    }

    private static func testEntityIndexAndDossier() async throws {
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
        check(candidates.count == 3, "Every stored story waits for the index")
        let batch = candidates.map { ($0, $0.title == "Story three" ? [harbour] : [harbour, maria]) }
        let generation = await database.analysisGeneration
        let saved = try await database.saveEntityIndex(batch, expectedGeneration: generation)
        check(saved, "The index batch is written")
        check(try await database.entityIndexCandidates(limit: 10).isEmpty, "A story is read once")
        _ = try await database.refreshEntityGraph(now: now, expectedGeneration: generation, withCentrality: true)
        let dossier = try await database.fetchEntityDossier(id: "organization:harbour-authority", now: now)
        check(dossier?.coverage.count == 30, "A dossier covers 30 days")
        check(dossier?.storiesInWindow == 3, "Three stories name Harbour Authority")
        check(dossier?.related.map(\.entity.id) == ["person:maria-ortega"], "Related entities share stories")
        check(dossier?.related.first?.sharedStories == 2, "A relationship counts its shared stories")
        try await database.clearArticleEnrichment()
        check(try await database.fetchEntity(id: "organization:harbour-authority") == nil, "Clear removes entities")
        await database.close()
    }

    private static func testDualReaderAlignment() async {
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

        check(!session.passageAlignments.isEmpty, "Dual reader alignments generated")
        check(session.consensusCount >= 1, "Consensus detected for identical opening statement")
        check(session.consensusScore > 0, "Consensus score is positive")
        let blankPassages = await service.extractPassages(title: "  ", content: "short")
        check(blankPassages.isEmpty, "A blank article yields no passages, so no 100% blank match")
        let shortPassages = await service.extractPassages(
            title: "Resignation", content: "The president resigned.\n\nHe resigned.\n\nRead more")
        check(
            shortPassages == ["Resignation", "The president resigned.", "He resigned."],
            "Short sentences stay, labels go")
        check(DualReaderLayoutMode.mode(for: 1300) == .sideBySide, "Adaptive layout side-by-side above 1200pt")
        check(DualReaderLayoutMode.mode(for: 900) == .stacked, "Adaptive layout stacked below 1200pt")
    }

    private static func testHotspotMapProjection() {
        let service = HotspotProjectionService()
        let canvas = CGSize(width: 1000, height: 500)

        let origin = service.projectEquirectangular(
            coordinate: GeographicCoordinate(latitude: 0, longitude: 0),
            canvasSize: canvas
        )
        check(abs(origin.x - 500.0) < 0.1, "Equirectangular center X matches 500")
        check(abs(origin.y - 250.0) < 0.1, "Equirectangular center Y matches 250")

        let kyivCoord = service.resolveCoordinate(for: "Kyiv")
        check(kyivCoord != nil, "Resolved location coordinate for Kyiv")
        check(kyivCoord?.latitude ?? 0 > 40.0, "Kyiv latitude is in Northern hemisphere")

        let telAviv = service.resolveCoordinate(for: "Tel-Aviv")
        check(telAviv != nil, "Resolved location coordinate for Tel-Aviv")

        let indiana = service.resolveCoordinate(for: "Indiana")
        check(indiana == nil, "Unrelated substring Indiana returns nil")

        let closest = service.closestRegion(for: GeographicCoordinate(latitude: 49.0, longitude: 31.0))
        check(closest?.id == "UA", "Matched closest hotspot region UA for Ukraine coordinate")

        let sydney = GeographicCoordinate(latitude: -33.86, longitude: 151.2)
        check(service.closestRegion(for: sydney) == nil, "Distant coordinate outside standard regions returns nil")
        check(service.theater(forLocationNamed: "kyiv")?.id == "UA", "Kyiv belongs to Eastern Europe")
        check(service.theater(forLocationNamed: "seoul")?.id == "KR", "Seoul belongs to Korean Peninsula")
        check(service.theater(forLocationNamed: "beijing") == nil, "Beijing is not assigned to Korean Peninsula")
        check(service.theater(forLocationNamed: "warsaw") == nil, "Warsaw is not assigned to Western Europe")

        check(HotspotTensionLevel.level(for: 80.0) == .critical, "Tension score 80 is critical")
        check(HotspotTensionLevel.level(for: 50.0) == .significant, "Tension score 50 is significant")
        check(HotspotTensionLevel.level(for: 20.0) == .elevated, "Tension score 20 is elevated")

        let reading = WorldTensionReading(
            evaluatedAt: Date(timeIntervalSince1970: 1_793_300_435), inputHash: "hotspots", modelGeneration: "test",
            headlines: [
                WorldTensionHeadline(id: "C1", title: "Airstrike hits Kyiv overnight", publisher: "Wire A"),
                WorldTensionHeadline(id: "C2", title: "Weather mild in Paris this week", publisher: "Wire C"),
            ],
            assessment: WorldTensionAssessment(score: 50, summary: "", reasons: []))
        let hotspots = WorldTensionHotspots(reading: reading)
        check(hotspots.pins.map(\.id) == ["kyiv"], "Hotspot pins come from tension-cue headlines that name a place")
        check(hotspots.regions.map(\.id) == ["UA"], "A region no headline reaches is absent, not fixed")
    }
}
