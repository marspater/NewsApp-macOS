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

/// Constructed vector controls measure ranking mechanics and cost, not production relevance.
enum EditorialRankingEvaluation {
    static func dcg(_ grades: [Int]) -> Double {
        grades.enumerated().reduce(0) { $0 + (pow(2, Double($1.element)) - 1) / log2(Double($1.offset + 2)) }
    }
    static func ndcg(_ ids: [String], grades: [String: Int]) -> Double {
        let ideal = dcg(Array(grades.values.sorted(by: >).prefix(10)))
        return ideal == 0 ? 0 : dcg(ids.prefix(10).map { grades[$0, default: 0] }) / ideal
    }
    static func momentum(now: Date) throws -> [Double] {
        let config = MomentumConfiguration(
            bucketSeconds: 300, shortHalfLife: 1800, longHalfLife: 10800,
            signalHalfLife: 1800, volumeWindow: 3600, minimumIndependentReports: 3, minimumOriginPublishers: 2)
        let values = try (0..<50).map { (event: Int) throws -> Double in
            let reports = (0..<(event % 5 * 3)).map { (index: Int) -> MomentumReport in
                let ageSeconds = Double(index + 1) * 60
                return MomentumReport(
                    articleID: "r-\(event)-\(index)", eventID: "event", wireGroupID: "wire-\(index)",
                    localPublisherID: "local-\(index)", originPublisherID: "origin-\(index % 5)",
                    publishedAt: now.addingTimeInterval(-ageSeconds),
                    fetchedAt: now.addingTimeInterval(10 - ageSeconds))
            }
            let summary = try EditorialMomentum.replay(
                reports: reports, eventID: "event", windowStart: now.addingTimeInterval(-172800), through: now,
                configuration: config)
            return max(0, summary.latestPoint?.macd ?? 0)
        }
        let maximum = values.max() ?? 0
        return maximum == 0 ? values : values.map { $0 / maximum }
    }
    static func run(output: URL) throws {
        let now = Date(timeIntervalSince1970: 1_793_491_200)
        let signals = try momentum(now: now)
        let candidates = (0..<500).map { index in
            EditorialRankingCandidate(
                id: String(format: "story-%04d", index), relevance: signals[index / 10],
                date: now.addingTimeInterval(-Double(index) * 60),
                vector: EditorialRankingTests.vector(index / 50), embeddingModelVersion: "constructed-v1",
                preference: nil)
        }
        let config = EditorialRankingConfiguration(
            relevanceWeight: 0.7, temporalDecaySeconds: 21600, embeddingModelVersion: "constructed-v1")
        let baseline = candidates.sorted { $0.relevance == $1.relevance ? $0.id < $1.id : $0.relevance > $1.relevance }
        var latency: [Double] = []
        var selected: [EditorialRankingSelection] = []
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            selected = try EditorialRanking.rank(candidates: candidates, limit: 10, configuration: config)
            latency.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let selectedIDs = selected.map(\.id)
        let lookup = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var baseNDCG: [Double] = []
        var mmrNDCG: [Double] = []
        for query in 0..<10 {
            let grades = Dictionary(
                uniqueKeysWithValues: candidates.enumerated().map { index, candidate in
                    let topic = index / 50
                    let grade = topic == query ? 3 : ((topic == (query + 1) % 10 || topic == (query + 9) % 10) ? 1 : 0)
                    return (candidate.id, grade)
                })
            baseNDCG.append(ndcg(baseline.prefix(10).map(\.id), grades: grades))
            mmrNDCG.append(ndcg(selectedIDs, grades: grades))
        }
        let baseDiversity = try EditorialRanking.meanSemanticDiversity(Array(baseline.prefix(10)))
        let mmrDiversity = try EditorialRanking.meanSemanticDiversity(selectedIDs.compactMap { lookup[$0] })
        let source = try Data(contentsOf: URL(fileURLWithPath: "Sources/Intelligence/Editorial/EditorialRanking.swift"))
        let report: [String: Any] = [
            "schema_version": 1, "phase": 3, "basis": "constructed_unit_vectors_and_momentum_controls",
            "candidate_count": 500, "selection_count": 10, "judgement_sets": 10, "judgements_per_set": 500,
            "base_relevance": "normalized Phase2 MACD; equal source weights; neutral preference",
            "relevance_weight": 0.7, "temporal_decay_seconds": 21600, "embedding_model_version": "constructed-v1",
            "baseline_ndcg_at_10": baseNDCG, "mmr_ndcg_at_10": mmrNDCG,
            "baseline_mean_ndcg": baseNDCG.reduce(0, +) / 10, "mmr_mean_ndcg": mmrNDCG.reduce(0, +) / 10,
            "baseline_semantic_diversity": baseDiversity ?? 0, "mmr_semantic_diversity": mmrDiversity ?? 0,
            "ranking_500_vectors_ms": latency, "selected_ids": selectedIDs,
            "source_sha256": ArticleIdentity.sha256Hex(String(decoding: source, as: UTF8.self)),
            "build_configuration": ProcessInfo.processInfo.environment["NEWS_EDITORIAL_BUILD_CONFIGURATION"]
                ?? "unspecified",
            "production_readiness": "not_established",
            "limitations": [
                "Synthetic one-hot vectors and authored topic judgements are constructed controls, not learned embeddings or production ranking accuracy.",
                "This is not the current Briefing comparator or a real-news holdout; no consumer is enabled.",
            ],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Ranking experiment wrote \(output.path)")
    }
}

/// The three-arm Lead comparison of W7 (#999, protocol: docs/audits/2026-11-13-editorial-evaluation-protocols.md,
/// section 5): `current`, `base` and `base+mmr` rank one candidate pool. `leadArms` is the whole mechanism and reads
/// plain rows, so the fixture smoke check and the snapshot run share it; `writeLeadArms` feeds it from the pool of a
/// `--today-shadow` run. Nothing here changes what the app ranks.
extension EditorialRankingEvaluation {
    static let leadArmNames = ["current", "base", "base+mmr"]

    /// One story of the pool, in the place `current` gives it.
    struct LeadArmStory {
        let id: String
        /// The story's Phase 2 signal before the pool normalises it: the latest MACD of its event, never below zero.
        let momentum: Double
        let date: Date
        let vector: [Float]?
        let event: String
        let publisher: String
    }

    /// Not frozen: section 6 of the protocol leaves the display depth and the MMR parameters to the tune run.
    struct LeadArmSettings {
        var displayDepth = 5
        var relevanceWeight = 0.7
        var temporalDecaySeconds: TimeInterval = 21_600
        var embeddingModel = "fixture"
    }

    struct LeadArmMeasures: Encodable {
        /// One minus the mean pairwise cosine similarity of the shown stories that have a vector; nil under two.
        let diversity: Double?
        let vectorsShown: Int
        let eventsShown: Int
        let publishersShown: Int
        /// Shown stories whose base relevance is zero: their place in `base` is the tie-break alone.
        let zeroRelevanceShown: Int
        let overlapCurrent: Int
        /// Spearman over the whole pool. Nil for `base+mmr`: `EditorialRanking` selects at most 50 stories.
        let rankCorrelationCurrent: Double?
        let selectionMs: Double?
    }

    struct LeadArmsReport: Encodable {
        let candidates: Int
        let displayDepth: Int
        let listDepth: Int
        let relevanceWeight: Double
        let temporalDecaySeconds: Double
        let embeddingModel: String
        let baseRelevance: String
        let storiesWithVector: Int
        let storiesWithPositiveRelevance: Int
        /// Pool stories that share the base relevance of the last shown `base` story; above 1, story ids decide the cut.
        let baseTiedAtCut: Int
        /// False when `current` and `base` show the same stories: the run then says nothing about base relevance.
        let currentAndBaseDistinct: Bool
        let arms: [String: LeadArmMeasures]
    }

    struct LeadArms {
        /// Per arm, story ids from the first place: the whole pool for `current` and `base`, `listDepth` for MMR.
        let orders: [String: [String]]
        let report: LeadArmsReport
    }

    /// Spearman's rank correlation of two orders of the same ids; nil under two ids.
    static func rankCorrelation(_ first: [String], _ second: [String]) -> Double? {
        let count = Double(first.count)
        guard first.count >= 2, Set(first) == Set(second) else { return nil }
        let place = Dictionary(uniqueKeysWithValues: second.enumerated().map { ($0.element, $0.offset) })
        let squares = first.enumerated().reduce(0.0) { $0 + pow(Double($1.offset - (place[$1.element] ?? 0)), 2) }
        return 1 - 6 * squares / (count * (count * count - 1))
    }

    /// `current` is the given order. `base` orders by momentum over the pool maximum (equal source weights, neutral
    /// preference) with the story id as tie-break, which is the order `EditorialRanking` gives at relevance weight 1.
    /// `base+mmr` passes the same relevance through `EditorialRanking.rank`.
    static func leadArms(
        current: [LeadArmStory], settings: LeadArmSettings, currentSelectionMs: Double?,
        listDepth: Int = TodayShadowEvaluation.leadRankingDepth
    ) throws -> LeadArms {
        guard (1...listDepth).contains(settings.displayDepth) else { throw EditorialRankingError.invalidConfiguration }
        let maximum = current.map(\.momentum).max() ?? 0
        let candidates = current.map {
            EditorialRankingCandidate(
                id: $0.id, relevance: maximum > 0 ? $0.momentum / maximum : 0, date: $0.date, vector: $0.vector,
                embeddingModelVersion: $0.vector == nil ? nil : settings.embeddingModel, preference: nil)
        }
        let configuration = EditorialRankingConfiguration(
            relevanceWeight: settings.relevanceWeight, temporalDecaySeconds: settings.temporalDecaySeconds,
            embeddingModelVersion: settings.embeddingModel)
        var base: [EditorialRankingCandidate] = []
        var mmr: [String] = []
        var baseMs: [Double] = []
        var mmrMs: [Double] = []
        for _ in 0..<5 {
            var start = ProcessInfo.processInfo.systemUptime
            base = candidates.sorted { $0.relevance == $1.relevance ? $0.id < $1.id : $0.relevance > $1.relevance }
            baseMs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            start = ProcessInfo.processInfo.systemUptime
            mmr = try EditorialRanking.rank(candidates: candidates, limit: listDepth, configuration: configuration)
                .map(\.id)
            mmrMs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let orders = ["current": current.map(\.id), "base": base.map(\.id), "base+mmr": mmr]
        let story = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let candidate = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let depth = settings.displayDepth
        let currentShown = Set(current.prefix(depth).map(\.id))
        func measures(_ arm: String, correlation: Double?, ms: Double?) throws -> LeadArmMeasures {
            let shown = (orders[arm] ?? []).prefix(depth)
            let shownCandidates = shown.compactMap { candidate[$0] }
            return LeadArmMeasures(
                diversity: try EditorialRanking.meanSemanticDiversity(shownCandidates),
                vectorsShown: shownCandidates.filter { $0.vector != nil }.count,
                eventsShown: Set(shown.compactMap { story[$0]?.event }).count,
                publishersShown: Set(shown.compactMap { story[$0]?.publisher }).count,
                zeroRelevanceShown: shownCandidates.filter { $0.relevance == 0 }.count,
                overlapCurrent: currentShown.intersection(shown).count, rankCorrelationCurrent: correlation,
                selectionMs: ms)
        }
        let arms = [
            "current": try measures("current", correlation: current.count >= 2 ? 1 : nil, ms: currentSelectionMs),
            "base": try measures(
                "base", correlation: rankCorrelation(current.map(\.id), base.map(\.id)), ms: baseMs.sorted()[2]),
            "base+mmr": try measures("base+mmr", correlation: nil, ms: mmrMs.sorted()[2]),
        ]
        let cut = base.prefix(depth).last?.relevance
        return LeadArms(
            orders: orders,
            report: LeadArmsReport(
                candidates: current.count, displayDepth: depth, listDepth: listDepth,
                relevanceWeight: settings.relevanceWeight, temporalDecaySeconds: settings.temporalDecaySeconds,
                embeddingModel: settings.embeddingModel,
                baseRelevance: "max(0, latest MACD) of the story's event over the pool maximum; ties by story id",
                storiesWithVector: candidates.filter { $0.vector != nil }.count,
                storiesWithPositiveRelevance: candidates.filter { $0.relevance > 0 }.count,
                baseTiedAtCut: candidates.filter { $0.relevance == cut }.count,
                currentAndBaseDistinct: currentShown != Set(base.prefix(depth).map(\.id)), arms: arms))
    }

    /// Each story's place in each arm, from 1, for the stories in the first `depth` of at least one arm: the `ranks`
    /// of the key file `script/evaluation/lead_review.py` reads.
    static func leadArmRanks(_ orders: [String: [String]], depth: Int) -> [String: [String: Int]] {
        var ranks: [String: [String: Int]] = [:]
        for (arm, order) in orders {
            for (index, id) in order.prefix(depth).enumerated() { ranks[id, default: [:]][arm] = index + 1 }
        }
        return ranks
    }

    /// 30 constructed stories: `current` is their index order, momentum a permutation of it, the vectors four
    /// one-hot topics (every tenth story has none), two stories to an event and three publishers.
    static func leadArmFixture() -> [LeadArmStory] {
        (0..<30).map { index in
            LeadArmStory(
                id: String(format: "s%02d", index), momentum: Double(index * 7 % 30),
                date: EditorialRankingTests.now.addingTimeInterval(-Double(index) * 600),
                vector: index % 10 == 9 ? nil : EditorialRankingTests.vector(index % 4), event: "e\(index / 2)",
                publisher: "p\(index % 3)")
        }
    }

    /// Harness smoke check on the fixture, run with the ranking atom. It shows that the three arms rank one pool
    /// and that the measures count as designed, and nothing about real news. `NEWS_RANKING_OUTPUT` also leaves the
    /// fixture's report beside `ranking.json`.
    static func leadArmsSmoke() {
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        do {
            let stories = leadArmFixture()
            let arms = try leadArms(current: stories, settings: LeadArmSettings(), currentSelectionMs: nil)
            let report = arms.report
            let pool = Set(stories.map(\.id))
            check(Set(arms.orders.keys) == Set(leadArmNames), "three named arms")
            check(arms.orders.values.allSatisfy { Set($0).isSubset(of: pool) }, "every arm ranks the same pool")
            check(arms.orders["current"] == stories.map(\.id), "current keeps the given order")
            check(
                arms.orders["base"].map { Array($0.prefix(5)) } == ["s17", "s04", "s21", "s08", "s25"],
                "base orders by momentum alone")
            let pure = try EditorialRanking.rank(
                candidates: stories.map {
                    EditorialRankingCandidate(
                        id: $0.id, relevance: $0.momentum / 29, date: $0.date, vector: $0.vector,
                        embeddingModelVersion: $0.vector == nil ? nil : "fixture", preference: nil)
                }, limit: 20,
                configuration: EditorialRankingConfiguration(
                    relevanceWeight: 1, temporalDecaySeconds: 21_600, embeddingModelVersion: "fixture")
            ).map(\.id)
            check(arms.orders["base"].map { Array($0.prefix(20)) } == pure, "base is EditorialRanking without MMR")
            check(arms.orders["base+mmr"]?.count == 20 && arms.orders["base+mmr"]?.first == "s17", "MMR list")
            check(arms.orders["base+mmr"] != pure, "MMR reorders the base list")
            let (current, base, mmr) = (report.arms["current"], report.arms["base"], report.arms["base+mmr"])
            check(report.currentAndBaseDistinct && base?.overlapCurrent == 1, "current and base differ at the depth")
            check(current?.overlapCurrent == 5 && current?.rankCorrelationCurrent == 1, "current against itself")
            let correlation = base?.rankCorrelationCurrent ?? 1
            check(
                correlation > -1 && correlation < 1 && mmr?.rankCorrelationCurrent == nil,
                "rank correlation over the pool, for base only")
            check(abs((base?.diversity ?? 0) - 0.6) < 1e-9, "base diversity: four of ten pairs share a topic")
            check((mmr?.diversity ?? 0) > (base?.diversity ?? 1), "MMR shows a more varied top")
            check(base?.eventsShown == 5 && base?.publishersShown == 3 && current?.eventsShown == 3, "events shown")
            check(report.storiesWithVector == 27 && report.storiesWithPositiveRelevance == 29, "pool counts")
            check(report.baseTiedAtCut == 1 && base?.zeroRelevanceShown == 0, "no tie at the base cut")
            check(base?.selectionMs != nil && mmr?.selectionMs != nil && current?.selectionMs == nil, "timing")
            let ranks = leadArmRanks(arms.orders, depth: 20)
            check(
                leadArmNames.allSatisfy { arm in ranks.values.filter { $0[arm] != nil }.count == 20 }
                    && ranks["s17"]?["base"] == 1 && ranks["s00"]?["current"] == 1,
                "the key holds 20 places an arm")
            let flat = try leadArms(
                current: stories.map {
                    LeadArmStory(
                        id: $0.id, momentum: 0, date: $0.date, vector: $0.vector, event: $0.event,
                        publisher: $0.publisher)
                }, settings: LeadArmSettings(), currentSelectionMs: 1)
            check(
                !flat.report.currentAndBaseDistinct && flat.report.baseTiedAtCut == 30
                    && flat.report.arms["base"]?.zeroRelevanceShown == 5,
                "a pool without momentum is reported as a tie, not as a ranking")
            if let output = ProcessInfo.processInfo.environment["NEWS_RANKING_OUTPUT"] {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(
                    to: URL(fileURLWithPath: output).deletingLastPathComponent()
                        .appendingPathComponent("lead-arms-fixture.json"), options: .withoutOverwriting)
            }
        } catch { failures.append("unexpected error: \(error)") }
        print("Finished lead-arm smoke checks with \(failures.count) failures.")
        for failure in failures { recordFailure("EditorialRankingEvaluation lead arms: \(failure)") }
    }
}

/// The snapshot side of the three-arm run: compiled with the runner, exercised only by `script/today_lead.sh arms`.
extension EditorialRankingEvaluation {
    struct LeadArmsSnapshotReport: Encodable {
        let pool: String
        let nowTimestamp: Double
        let momentumClock: Double
        /// Vectors the library holds for the model but `EditorialRanking` would refuse (not unit length); left out.
        let vectorsRefused: Int
        /// Events whose replay failed on conflicting origins; their stories get base relevance 0.
        let replaysFailed: Int
        /// Summed over the pool's events: rows in the 48-hour window, rows without a wire group or origin (the
        /// replay skips them) and rows stored after the momentum clock (not yet available, skipped).
        let momentumRowsInWindow: Int
        let momentumRowsUnknownOrigin: Int
        let momentumRowsStoredAfterClock: Int
        let comparison: LeadArmsReport
    }

    /// Ranks the shadow run's candidates three ways and writes, into `arms/` of the private output directory,
    /// `lead-rankings-private.json` (the key, in the format of the #934 key, with the arm names as rankings) and
    /// `lead-arms-report.json` (aggregates only). `current` is the run's own Z2 order; vectors are the stored
    /// sentence vectors of each story's representative; momentum is replayed over the reports of the story's event
    /// as `EditorialWireIdentity` maps them, at the 6 November sweep values.
    /// `NEWS_LEAD_ARMS_DEPTH`, `NEWS_LEAD_ARMS_RELEVANCE_WEIGHT` and `NEWS_LEAD_ARMS_DECAY_SECONDS` set the display
    /// depth and the MMR parameters; `NEWS_LEAD_ARMS_MOMENTUM_CLOCK` (epoch seconds) moves the replay's clock off
    /// the run's.
    static func writeLeadArms(
        of candidates: [TodayStoryAssignment], pool: String, now: Date, database: DatabaseEngine,
        currentSelectionMs: Double, privateOutput: URL
    ) async throws {
        guard candidates.count <= 500 else {
            throw NSError(
                domain: "EditorialRankingEvaluation", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The three-arm run ranks at most 500 stories (EditorialRanking's bound); this pool has "
                        + "\(candidates.count). Use NEWS_TODAY_POOL=page."
                ])
        }
        let env = ProcessInfo.processInfo.environment
        var settings = LeadArmSettings(embeddingModel: "sentence-v\(SentenceEmbedder.modelVersion)")
        if let depth = env["NEWS_LEAD_ARMS_DEPTH"].flatMap(Int.init) { settings.displayDepth = depth }
        if let weight = env["NEWS_LEAD_ARMS_RELEVANCE_WEIGHT"].flatMap(Double.init) {
            settings.relevanceWeight = weight
        }
        if let decay = env["NEWS_LEAD_ARMS_DECAY_SECONDS"].flatMap(Double.init) {
            settings.temporalDecaySeconds = decay
        }
        let clock =
            env["NEWS_LEAD_ARMS_MOMENTUM_CLOCK"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            ?? now

        let current = await TodayShadowEvaluation.leadRankings(of: candidates, database: database).z2
        let stored = try await database.fetchArticleEmbeddings(
            articleIDs: current.map(\.entry.representative.id), modelVersion: SentenceEmbedder.modelVersion)
        let vectors = stored.filter { abs($0.value.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) <= 0.001 }
        var replaysFailed = 0
        var rowsInWindow = 0
        var rowsUnknown = 0
        var rowsAfterClock = 0
        var stories: [LeadArmStory] = []
        for item in current {
            let representative = item.entry.representative
            var event = item.id
            var members = [representative]
            if case .event(let summary, _, _) = item.entry {
                event = summary.eventID
                members = try await database.fetchArticles(
                    limit: nil, options: ArticleFetchOptions(eventID: summary.eventID, wholeStory: true))
            }
            let storedAt = try await database.storedAt(members.map(\.id))
            let reports = EditorialWireIdentity.momentumReports(
                eventID: event,
                members: members.map {
                    WireIdentityArticle(
                        articleID: $0.id, publisher: $0.source, title: $0.title, description: $0.description,
                        content: $0.fullContent, publishedAt: $0.pubDate,
                        fetchedAt: storedAt[$0.id].map { Date(timeIntervalSince1970: $0) } ?? $0.pubDate,
                        author: $0.author)
                })
            var momentum = 0.0
            do {
                let summary = try EditorialMomentum.replay(
                    reports: reports, eventID: event, windowStart: clock.addingTimeInterval(-172_800), through: clock,
                    configuration: EditorialWireIdentityEvaluation.configuration)
                momentum = max(0, summary.latestPoint?.macd ?? 0)
                rowsInWindow += summary.rawRowsInWindow
                rowsUnknown += summary.unknownMetadataRows
                rowsAfterClock += summary.futureFetchRows
            } catch MomentumError.conflictingOrigin { replaysFailed += 1 }
            stories.append(
                LeadArmStory(
                    id: item.id, momentum: momentum, date: item.sortKey, vector: vectors[representative.id],
                    event: event, publisher: representative.publisherName))
        }
        let arms = try leadArms(current: stories, settings: settings, currentSelectionMs: currentSelectionMs)

        let ranks = leadArmRanks(arms.orders, depth: arms.report.listDepth)
        let rows = current.filter { ranks[$0.id] != nil }.sorted { $0.id < $1.id }.map { item in
            let story = item.entry.representative
            return TodayShadowEvaluation.PrivateLeadRankingRow(
                id: item.id, publisher: story.publisherName, title: story.title,
                summary: String(story.description.prefix(240)), ranks: ranks[item.id] ?? [:])
        }
        let directory = privateOutput.appendingPathComponent("arms")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StoryCorpus.writePrivate(
            try encoder.encode(
                TodayShadowEvaluation.PrivateLeadRankings(
                    pool: pool, nowTimestamp: now.timeIntervalSince1970, candidates: candidates.count,
                    depth: arms.report.listDepth, stories: rows)),
            to: directory.appendingPathComponent("lead-rankings-private.json"), replacing: true)
        try StoryCorpus.writePrivate(
            try encoder.encode(
                LeadArmsSnapshotReport(
                    pool: pool, nowTimestamp: now.timeIntervalSince1970, momentumClock: clock.timeIntervalSince1970,
                    vectorsRefused: stored.count - vectors.count, replaysFailed: replaysFailed,
                    momentumRowsInWindow: rowsInWindow, momentumRowsUnknownOrigin: rowsUnknown,
                    momentumRowsStoredAfterClock: rowsAfterClock, comparison: arms.report)),
            to: directory.appendingPathComponent("lead-arms-report.json"), replacing: true)
    }
}

extension DatabaseEngine {
    /// When each article was first stored (`created_at`): the fetch time of a momentum replay.
    fileprivate func storedAt(_ articleIDs: [String]) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = articleIDs[start..<min(start + 400, articleIDs.count)]
            let marks = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            let rows = try eventRows(
                "SELECT id, created_at FROM articles WHERE id IN (\(marks));", slice.map { EventValue.text($0) })
            for row in rows {
                if let id = row[0], let stored = row[1].flatMap(Double.init) { result[id] = stored }
            }
        }
        return result
    }
}
