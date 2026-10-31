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

/// Background intelligence writes are saved only if their inputs are still current (#844): the generation every
/// derived write carries, the enrichment queue's session state (#805, #820), the visible event's overview (#792)
/// and notification bookkeeping in one transaction (#814).
enum AnalysisGenerationTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [AnalysisGenerationTests.swift:\(line)]: \(message)")
        }
    }

    static func run() async {
        print("=== Running analysis generation (#844) tests ===")
        do {
            try await staleWritesAreRefused()
            try await queueForgetsRefusedAndClearedWork()
            backgroundNeverSupersedesTheVisibleEvent()
            try await notificationBookkeepingIsAtomic()
        } catch {
            check(false, "Unexpected error: \(error)")
        }
        print("Finished \(checks) analysis generation checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }

    static func article(_ id: String, title: String = "Port authority raises alert level") -> FeedArticle {
        FeedArticle(
            title: title, link: "https://example.com/\(id)", guid: id, description: "Vessels are rerouted.",
            pubDate: Date(timeIntervalSince1970: 1_793_188_800), source: "Harbor Times")
    }

    static func eventually(_ message: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool)
        async
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(await condition(), message)
    }

    /// Every derived kind refuses a write that started before a clear of derived data.
    static func staleWritesAreRefused() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let story = article("gen-1")
        try await db.upsertArticles([story])
        guard let stored = try await db.fetchArticles(limit: 1, id: story.id).first else {
            return check(false, "The story is stored")
        }
        let before = await db.analysisGeneration
        try await db.clearArticleEnrichment()
        let after = await db.analysisGeneration
        check(after == before + 1, "A clear bumps the generation")

        // Classification.
        var update = DatabaseEngine.EnrichmentUpdate()
        update.category = "World"
        update.expectedGeneration = before
        check(
            try await db.updateEnrichment(articleId: stored.id, update: update) == false,
            "A classification started before the clear is refused")
        check(try await db.fetchArticles(limit: 1, id: stored.id).first?.category == nil, "and writes nothing")
        update.expectedGeneration = after
        check(try await db.updateEnrichment(articleId: stored.id, update: update), "The current generation writes")

        // Reader analysis.
        let analysis = ArticleAnalysis(
            summary: "Summary", keyPoints: [], entities: [], category: "World", sentiment: nil,
            modelIdentifier: "test", analysisVersion: 2)
        check(
            try await db.saveArticleAnalysis(analysis, for: stored.id, expectedGeneration: before) == false,
            "An analysis started before the clear is refused")
        check(await db.fetchArticleAnalysis(for: stored.id) == nil, "and stores nothing")
        check(
            try await db.saveArticleAnalysis(analysis, for: stored.id, expectedGeneration: after),
            "The current generation stores the analysis")

        // Event overview.
        let event = try await db.createEvent(memberArticleIDs: [stored.id])
        let overview = EventOverviewDocument(
            eventID: event.id,
            version: OverviewVersionContext(membershipVersion: event.membershipVersion, inputTextHash: "input"),
            content: OverviewContent(title: "Overview", summary: "", facts: [], citations: []),
            provenance: OverviewProvenance(memberArticleIDs: [stored.id], kind: .fallbackExcerpts))
        check(
            try await db.recordEventOverview(overview, expectedGeneration: before) == false,
            "An overview generated before the clear is refused")
        check(try await db.fetchEventOverview(eventID: event.id) == nil, "and none is stored")
        check(
            try await db.recordEventOverview(overview, expectedGeneration: after),
            "The current generation stores the overview")

        // Clustering pass.
        let vector = [Float](repeating: 0.1, count: 384)
        let writes = DatabaseEngine.ClusteringPassWrites(
            embeddings: [stored.id: vector], readTexts: [stored.id: stored.title + "\n" + stored.description])
        check(
            try await db.storeClusteringPass(writes, expectedGeneration: before) == false,
            "A clustering pass started before the clear stores nothing")
        check(
            try await db.fetchArticleEmbeddings(
                articleIDs: [stored.id], modelVersion: SentenceEmbedder.modelVersion
            ).isEmpty, "no vector")
        check(
            try await db.storeClusteringPass(writes, expectedGeneration: after),
            "The current generation stores the pass")
        check(
            try await db.fetchArticleEmbeddings(
                articleIDs: [stored.id], modelVersion: SentenceEmbedder.modelVersion
            ).count == 1, "one vector")
    }

    /// A job counts as completed only when its write succeeded (#820), a changed input or a clear makes the story
    /// eligible again (#805, #820).
    @MainActor
    static func queueForgetsRefusedAndClearedWork() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let store = ArticleStore(database: db)
        let queue = EnrichmentQueue(store: store)

        // A story the store does not hold: its write fails, so it never counts as classified.
        let missing = article("missing")
        await queue.enqueue(article: missing, priority: .interactive)
        await eventually("A refused write leaves no job behind") {
            let state = await queue.state(for: missing.id)
            let retained = await queue.retainsJob(for: missing.id)
            return state == nil && !retained
        }

        let story = article("queued")
        try await db.upsertArticles([story])
        guard let stored = try await db.fetchArticles(limit: 1, id: story.id).first else {
            return check(false, "The story is stored")
        }
        await queue.enqueue(article: stored, priority: .interactive)
        await eventually("The stored story is classified") { await queue.state(for: stored.id) == .completed }
        await queue.enqueue(article: stored, priority: .interactive)
        check(await queue.state(for: stored.id) == .completed, "The same input is not classified again")

        // The publisher changed the story: the new input is classified again.
        let changed = article("queued", title: "Port authority lifts the alert")
        check(changed.publisherInputHash != stored.publisherInputHash, "A new title is a new input")
        await queue.enqueue(article: changed, priority: .interactive)
        check(await queue.state(for: stored.id) != .completed, "A changed input queues the story again")

        await eventually("The changed input settles") { await queue.retainsJob(for: stored.id) == false }
        await queue.analysisCleared()
        check(await queue.state(for: stored.id) == nil, "Clear AI Analysis forgets what was classified")
        await queue.enqueue(article: stored, priority: .interactive)
        await eventually("The story is classified again after the clear") {
            await queue.state(for: stored.id) == .completed
        }
    }

    /// A background warm-up never cancels the generation running for the visible event (#792).
    static func backgroundNeverSupersedesTheVisibleEvent() {
        check(
            !OverviewGenerationCoordinator.maySupersede(priority: .background, eventID: "e1", visibleEventID: "e1"),
            "A warm-up of the visible event waits")
        check(
            OverviewGenerationCoordinator.maySupersede(priority: .background, eventID: "e2", visibleEventID: "e1"),
            "A warm-up of another event may replace its stale generation")
        check(
            OverviewGenerationCoordinator.maySupersede(priority: .visibleEvent, eventID: "e1", visibleEventID: "e1"),
            "The reader's own request may replace a stale generation")
    }

    /// A banner is recorded in one transaction: a failed step leaves no delivery row behind (#814).
    static func notificationBookkeepingIsAtomic() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let story = article("banner")
        try await db.upsertArticles([story])
        guard let stored = try await db.fetchArticles(limit: 1, id: story.id).first else {
            return check(false, "The story is stored")
        }
        let event = try await db.createEvent(memberArticleIDs: [stored.id])
        try await db.executeSimple(
            "CREATE TRIGGER fail_announce BEFORE INSERT ON event_notifications BEGIN SELECT RAISE(ABORT, 'test'); END;"
        )
        let banner = PlannedBanner(
            lane: .normal, grouped: false, thread: event.id, sound: false, announces: [event.id: "key"])
        var failed = false
        do { try await db.recordNotification(banner, at: Date()) } catch { failed = true }
        check(failed, "The failed announcement surfaces")
        let deliveries = try await db.eventRows("SELECT count(*) FROM notification_deliveries;").first?.first ?? nil
        check(deliveries == "0", "and the delivery row is rolled back with it")
        try await db.executeSimple("DROP TRIGGER fail_announce;")
        try await db.recordNotification(banner, at: Date())
        let ledger = try await db.notificationLedger(now: Date())
        check(ledger.normalLastHour == 1 && ledger.announced[event.id] != nil, "A whole banner is recorded")
    }
}
