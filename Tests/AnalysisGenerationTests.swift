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
            try await backgroundNeverSupersedesTheVisibleEvent()
            try await notificationBookkeepingIsAtomic()
            try await clusteringStorageFailuresEndThePass()
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

    /// A clustering pass whose storage fails ends with the error: a failed write is not a stored pass, and a failed
    /// inclusion read is not "no correction by the reader".
    static func clusteringStorageFailuresEndThePass() async throws {
        let now = Date(timeIntervalSince1970: 1_793_188_800 + 3600)
        for (failure, cause, message) in [
            (
                "CREATE TRIGGER fail_features BEFORE INSERT ON article_features BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
                "fixture", "A failed clustering write ends the pass with its error"
            ),
            ("DROP TABLE event_inclusions;", "no such table", "A failed inclusion read ends the pass with its error"),
        ] {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            try await db.upsertArticles([article("cluster-fail")])
            try await db.eventRows(failure)
            do {
                _ = try await EventClusterer.run(in: db, now: now, allowsEnergy: false)
                check(false, message)
            } catch {
                check(error.localizedDescription.contains(cause), message)
            }
            await db.close()
        }

        // Rows the energy rule deferred (#534) are still read again by a pass with energy after a failed write.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let floods = [
            ("Floods kill dozens across Pakistan after monsoon rains", 0.0),
            ("Pakistan flood death toll climbs as monsoon rains continue", 3.0),
        ].enumerated().map { index, story in
            FeedArticle(
                title: story.0, link: "https://grey.invalid/\(index)", guid: "grey-\(index)", description: "",
                pubDate: start.addingTimeInterval(story.1 * 3600), source: "Publisher \(index)")
        }
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        try await db.upsertArticles(floods)
        try await db.eventRows(
            "CREATE TRIGGER fail_features BEFORE INSERT ON article_features BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
        do {
            _ = try await EventClusterer.run(in: db, now: start.addingTimeInterval(4 * 3600), allowsEnergy: false)
            check(false, "The failed write ends the pass without energy")
        } catch {
            check(error.localizedDescription.contains("fixture"), "The fixture's write failure ends the pass")
        }
        let behind = try await db.eventRows(
            "SELECT count(*) FROM event_match_state WHERE matcher_version = ?;", [.integer(EventMatcher.version - 1)])
        check(behind.first?.first == "2", "Both deferred rows are marked one matcher version behind")
        try await db.eventRows("DROP TRIGGER fail_features;")
        let withEnergy = try await EventClusterer.run(
            in: db, now: start.addingTimeInterval(6 * 3600), allowsEnergy: true, pairProbability: { _, _ in 0.99 })
        check(withEnergy.processed >= 2, "Rows deferred before a failed write are read again with energy")
        await db.close()

        // A failed deferred marker still stores the batch's derived writes before the pass ends.
        let marking = DatabaseEngine(path: ":memory:")
        try await marking.open()
        try await marking.upsertArticles(floods)
        try await marking.eventRows(
            """
            CREATE TRIGGER fail_marker BEFORE UPDATE ON event_match_state
            WHEN NEW.matcher_version = \(EventMatcher.version - 1) BEGIN SELECT RAISE(ABORT, 'marker'); END;
            """)
        do {
            _ = try await EventClusterer.run(in: marking, now: start.addingTimeInterval(4 * 3600), allowsEnergy: false)
            check(false, "The failed marker ends the pass")
        } catch {
            check(error.localizedDescription.contains("marker"), "The fixture's marker failure ends the pass")
        }
        let features = try await marking.eventRows("SELECT count(*) FROM article_features;")
        check(features.first?.first == "2", "The batch's features are stored although the marker failed")
        await marking.close()

        // A row that throws inside the batch still leaves the rows before it deferred and stored (#952): here the
        // second report's own match marker fails.
        let midBatch = DatabaseEngine(path: ":memory:")
        try await midBatch.open()
        try await midBatch.upsertArticles(floods)
        try await midBatch.eventRows(
            """
            CREATE TRIGGER fail_second BEFORE INSERT ON event_match_state
            WHEN NEW.matcher_version = \(EventMatcher.version)
                AND (SELECT count(*) FROM event_match_state WHERE matcher_version = \(EventMatcher.version)) >= 1
            BEGIN SELECT RAISE(ABORT, 'second'); END;
            """)
        do {
            _ = try await EventClusterer.run(in: midBatch, now: start.addingTimeInterval(4 * 3600), allowsEnergy: false)
            check(false, "The second report's failure ends the pass")
        } catch {
            check(error.localizedDescription.contains("second"), "The second report's own error is reported")
        }
        let current = try await midBatch.eventRows(
            "SELECT count(*) FROM event_match_state WHERE matcher_version = ?;", [.integer(EventMatcher.version)])
        check(current.first?.first == "0", "No deferred report of the batch stays marked current")
        let storedFirst = try await midBatch.eventRows("SELECT count(*) FROM article_features;")
        check(storedFirst.first?.first == "2", "The batch's features are stored although a later row failed")
        await midBatch.close()

        // A cancelled rules-only pass still leaves the reports it deferred to a pass with energy (#952). Rows run newest
        // first, so older reports keep the batch running after the flood reports commit; a pass that finishes before
        // the cancel lands flushes them too.
        let cancelled = DatabaseEngine(path: ":memory:")
        try await cancelled.open()
        let fillers = (1...90).map { index in
            FeedArticle(
                title: "Harbour museum opens exhibit \(index) on regional shipbuilding",
                link: "https://filler.invalid/\(index)", guid: "filler-\(index)", description: "",
                pubDate: start.addingTimeInterval(Double(-index) * 600), source: "Gazette \(index)")
        }
        try await cancelled.upsertArticles(floods + fillers)
        let pass = Task {
            try await EventClusterer.run(in: cancelled, now: start.addingTimeInterval(4 * 3600), allowsEnergy: false)
        }
        await eventually("The pass commits its first report") {
            let marked = try? await cancelled.eventRows("SELECT count(*) FROM event_match_state;")
            return (marked?.first?.first ?? nil) != "0"
        }
        pass.cancel()
        _ = await pass.result
        // A flood report the cancel reached first has no marker and stays pending, which is fine; none stays current.
        let currentFloods = try await cancelled.eventRows(
            "SELECT count(*) FROM event_match_state WHERE article_id IN ('grey-0', 'grey-1') AND matcher_version = ?;",
            [.integer(EventMatcher.version)])
        check(currentFloods.first?.first == "0", "No flood report deferred before the cancel stays marked current")
        await cancelled.close()
    }

    /// A job counts as completed only when its write succeeded (#820), a changed input or a clear makes the story
    /// eligible again (#805, #820).
    @MainActor
    static func queueForgetsRefusedAndClearedWork() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let queue = EnrichmentQueue(store: store)
        store.analysisClearedHandler = { await queue.analysisCleared() }

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
        let initialGen = store.analysisGeneration
        // The clear returns only once the queue has reset, so an enqueue right after it is not skipped.
        try await store.clearAIAnalysis()
        check(store.analysisGeneration > initialGen, "Clear AI Analysis bumps store.analysisGeneration (#901)")
        check(
            store.analysisGeneration == (await db.analysisGeneration),
            "store.analysisGeneration matches db.analysisGeneration")
        check(await queue.state(for: stored.id) == nil, "Clear AI Analysis forgets what was classified")
        await queue.enqueue(article: stored, priority: .interactive)
        await eventually("The story is classified again after the clear") {
            await queue.state(for: stored.id) == .completed
        }

        // Clear Story Text also resets the queue (#886)
        let beforeTextGen = store.analysisGeneration
        try await store.clearArticleCache()
        check(store.analysisGeneration > beforeTextGen, "Clear Story Text bumps store.analysisGeneration (#901)")
        check(
            store.analysisGeneration == (await db.analysisGeneration),
            "store.analysisGeneration matches db.analysisGeneration after text clear")
        check(await queue.state(for: stored.id) == nil, "Clear Story Text forgets what was classified (#886)")

        // Clear All Database Cache also bumps analysisGeneration, published only after the reset handler finishes,
        // even when a refresh runs meanwhile; published earlier, it starts work the handler then cancels.
        let beforeAllGen = store.analysisGeneration
        var seenByHandler: Int?
        store.analysisClearedHandler = {
            _ = await store.refreshState()
            seenByHandler = store.analysisGeneration
            await queue.analysisCleared()
        }
        try await store.clearAllDatabaseCache()
        check(seenByHandler == beforeAllGen, "The generation is published after the clear's reset handler")

        // Overlapping clears: the one that finishes first while another reset runs publishes nothing.
        let beforeOverlap = store.analysisGeneration
        var publishedWhileOuterRan: Int?
        var nested = false
        store.analysisClearedHandler = {
            if !nested {
                nested = true
                try? await store.clearArticleCache()
                publishedWhileOuterRan = store.analysisGeneration
            }
            await queue.analysisCleared()
        }
        try await store.clearAllDatabaseCache()
        check(publishedWhileOuterRan == beforeOverlap, "Only the last overlapping reset publishes the generation")
        check(
            store.analysisGeneration == (await db.analysisGeneration), "The last reset publishes the final generation")
        check(store.analysisGeneration > beforeAllGen, "Clear All Database Cache bumps store.analysisGeneration (#901)")
        check(
            store.analysisGeneration == (await db.analysisGeneration),
            "store.analysisGeneration matches db.analysisGeneration after all clear")
    }

    /// A background warm-up never cancels the generation running for the visible event (#792): the rule, then the
    /// coordinator with a visible request held in flight.
    @MainActor
    static func backgroundNeverSupersedesTheVisibleEvent() async throws {
        check(
            !OverviewGenerationCoordinator.maySupersede(priority: .background, eventID: "e1", visibleEventID: "e1"),
            "A warm-up of the visible event waits")
        check(
            OverviewGenerationCoordinator.maySupersede(priority: .background, eventID: "e2", visibleEventID: "e1"),
            "A warm-up of another event may replace its stale generation")
        check(
            OverviewGenerationCoordinator.maySupersede(priority: .visibleEvent, eventID: "e1", visibleEventID: "e1"),
            "The reader's own request may replace a stale generation")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let reports = (1...3).map { index in
            FeedArticle(
                storedID: "visible-\(index)", title: "Port authority raises alert level \(index)",
                link: "https://example.com/visible/\(index)", guid: "visible-\(index)",
                description: "Vessels are rerouted around the port \(index).",
                pubDate: Date(timeIntervalSince1970: 1_793_188_800 + Double(index)), source: "Outlet \(index)")
        }
        try await db.upsertArticles(reports)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let queue = EnrichmentQueue(store: store)
        let coordinator = OverviewGenerationCoordinator(store: store, queue: queue)
        // Fill the bounded queue so the visible request stays in flight until the gate opens.
        let hold = OpenGate()
        for index in 0..<3 {
            Task {
                _ = await queue.scheduleOverviewGeneration(eventID: "hold-\(index)") {
                    await hold.wait()
                    return nil
                }
            }
        }
        await eventually("Held generations fill the overview queue") { await queue.activeJobCount() == 3 }
        let visible = Task {
            await coordinator.setVisibleEvent(
                eventID: "e1", eventTitle: reports[0].title, membershipVersion: 1, articles: reports, store: store,
                owner: UUID())
        }
        await eventually("The visible request is in flight") { await coordinator.inFlightInputHash(for: "e1") != nil }
        let visibleHash = await coordinator.inFlightInputHash(for: "e1")
        let warmed = await coordinator.requestOverview(
            eventID: "e1", eventTitle: reports[0].title, membershipVersion: 1, articles: Array(reports.prefix(2)),
            priority: .background, store: store)
        check(warmed == nil, "A warm-up with other inputs yields to the visible generation")
        check(
            await coordinator.inFlightInputHash(for: "e1") == visibleHash,
            "and the visible generation is still the one in flight")
        await coordinator.cancel(eventID: "e1")
        await hold.open()
        _ = await visible.value
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
