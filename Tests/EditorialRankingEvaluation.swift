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
/// section 5). `current` is the Lead as the app shows it. `base` ranks the stories the Lead may show by Athena's Z2
/// editorial score, with publisher affinity neutral and no diversity term. `base+mmr` passes the same stories and
/// scores through `EditorialRanking`. `leadArms` is the whole mechanism and reads plain rows, so the fixture smoke
/// check and the snapshot run share it; `writeLeadArms` feeds it from a `--today-shadow` run. Nothing here changes
/// what the app ranks.
extension EditorialRankingEvaluation {
    static let leadArmNames = ["current", "base", "base+mmr"]

    /// One candidate of the pool.
    struct LeadArmStory {
        let id: String
        /// The Z2 editorial score (`TodayEditionAssigner.computeEditorialScore`), which holds no publisher affinity.
        let score: Double
        let originalReports: Int
        /// The reader's affinity for the publisher: the shipped Lead's third tie-break, which `base` leaves out.
        let affinity: Double
        /// The newest report's date: the last tie-break, and the date of MMR's temporal decay.
        let date: Date
        let hasPhoto: Bool
        let vector: [Float]?
        let event: String
        let publisher: String
    }

    /// The display depth is the Lead's slide cap. The MMR parameters are not frozen: the tune run sets them.
    struct LeadArmSettings {
        var displayDepth = TodayLane.theLead.cap ?? 5
        var relevanceWeight = 0.7
        var temporalDecaySeconds: TimeInterval = 21_600
        var embeddingModel = "fixture"
    }

    struct LeadArmMeasures: Encodable {
        /// Stories the arm shows: `current` can show fewer than the display depth, the other arms fill it.
        let shown: Int
        /// One minus the mean pairwise cosine similarity of the shown stories that have a vector; nil under two.
        let diversity: Double?
        let vectorsShown: Int
        let eventsShown: Int
        let publishersShown: Int
        let overlapCurrent: Int
        let overlapBase: Int
        /// For `base` only: Spearman, over the eligible pool, with the shipped Lead precedence (affinity included).
        let rankCorrelationCurrent: Double?
        let selectionMs: Double?
    }

    struct LeadArmsReport: Encodable {
        let candidates: Int
        /// Candidates the photo rule leaves, which `base` and `base+mmr` rank.
        let eligible: Int
        let displayDepth: Int
        let listDepth: Int
        let relevanceWeight: Double
        let temporalDecaySeconds: Double
        let embeddingModel: String
        let baseRelevance: String
        let displayRules: String
        let storiesWithVector: Int
        /// False when `current`'s slides are not in the mirrored shipped precedence: the mirror is then wrong.
        let currentFollowsShippedOrder: Bool
        /// True when `current` and `base` show the same stories in the same places. That is a control, not a
        /// failure: `base+mmr` against `base` then isolates MMR.
        let currentAndBaseCoincide: Bool
        let arms: [String: LeadArmMeasures]
    }

    struct LeadArms {
        /// Per arm, story ids from the first place: `current`'s slides, the eligible pool for `base`, `listDepth`
        /// stories for `base+mmr`.
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

    /// The shipped Lead precedence, mirrored from the private `TodayEditionAssigner.leadPrecedes`: score, original
    /// reports, publisher affinity, newest report, id. Without `affinity` it is the order of `base`.
    static func leadPrecedes(_ a: LeadArmStory, _ b: LeadArmStory, affinity: Bool) -> Bool {
        if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
        if a.originalReports != b.originalReports { return a.originalReports > b.originalReports }
        if affinity, abs(a.affinity - b.affinity) > 1e-9 { return a.affinity > b.affinity }
        return a.date == b.date ? a.id < b.id : a.date > b.date
    }

    /// The relevance `EditorialRanking` gets for stories in `base` order: the Z2 score itself, lowered by 1e-12 a
    /// place where it would not otherwise fall, so that ties keep the place `base` gave them. It falls strictly
    /// along the order, which makes `EditorialRanking` at relevance weight 1 return `base`.
    static func baseRelevance(_ base: [LeadArmStory]) -> [Double] {
        var relevance: [Double] = []
        for story in base { relevance.append(max(0, min(1, story.score, (relevance.last ?? 2) - 1e-12))) }
        return relevance
    }

    private static func candidate(_ story: LeadArmStory, relevance: Double, model: String)
        -> EditorialRankingCandidate
    {
        EditorialRankingCandidate(
            id: story.id, relevance: relevance, date: story.date, vector: story.vector,
            embeddingModelVersion: story.vector == nil ? nil : model, preference: nil)
    }

    /// `currentShown` is the Lead's slides in shown order. The experimental arms get the Lead's display rules that
    /// can be applied from here: the photo rule (a story without a photo is out while any story has one; when none
    /// has, one story is shown) and the slide cap as the display depth.
    static func leadArms(
        stories: [LeadArmStory], currentShown: [String], settings: LeadArmSettings, currentSelectionMs: Double?,
        listDepth: Int = TodayShadowEvaluation.leadRankingDepth
    ) throws -> LeadArms {
        guard (1...listDepth).contains(settings.displayDepth) else { throw EditorialRankingError.invalidConfiguration }
        let pictured = stories.filter(\.hasPhoto)
        let eligible = pictured.isEmpty ? stories : pictured
        let depth = pictured.isEmpty ? 1 : settings.displayDepth
        guard eligible.count <= 500 else { throw EditorialRankingError.inputLimit }

        var base: [LeadArmStory] = []
        var baseMs: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            base = eligible.sorted { leadPrecedes($0, $1, affinity: false) }
            baseMs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let candidates = zip(base, baseRelevance(base)).map {
            candidate($0, relevance: $1, model: settings.embeddingModel)
        }
        let configuration = EditorialRankingConfiguration(
            relevanceWeight: settings.relevanceWeight, temporalDecaySeconds: settings.temporalDecaySeconds,
            embeddingModelVersion: settings.embeddingModel)
        var mmr: [String] = []
        var mmrMs: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            mmr = try EditorialRanking.rank(candidates: candidates, limit: listDepth, configuration: configuration)
                .map(\.id)
            mmrMs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }

        let shipped = eligible.sorted { leadPrecedes($0, $1, affinity: true) }.map(\.id)
        let shippedPlace = Dictionary(uniqueKeysWithValues: shipped.enumerated().map { ($0.element, $0.offset) })
        let currentPlaces = currentShown.map { shippedPlace[$0] ?? -1 }
        let orders = ["current": currentShown, "base": base.map(\.id), "base+mmr": mmr]
        let story = Dictionary(uniqueKeysWithValues: stories.map { ($0.id, $0) })
        let currentTop = Array(currentShown.prefix(depth))
        let baseTop = Array(base.prefix(depth).map(\.id))
        func measures(_ arm: String, correlation: Double?, ms: Double?) throws -> LeadArmMeasures {
            let shown = (orders[arm] ?? []).prefix(depth).compactMap { story[$0] }
            return LeadArmMeasures(
                shown: shown.count,
                diversity: try EditorialRanking.meanSemanticDiversity(
                    shown.map { candidate($0, relevance: 0, model: settings.embeddingModel) }),
                vectorsShown: shown.filter { $0.vector != nil }.count,
                eventsShown: Set(shown.map(\.event)).count, publishersShown: Set(shown.map(\.publisher)).count,
                overlapCurrent: Set(currentTop).intersection(shown.map(\.id)).count,
                overlapBase: Set(baseTop).intersection(shown.map(\.id)).count, rankCorrelationCurrent: correlation,
                selectionMs: ms)
        }
        let arms = [
            "current": try measures("current", correlation: nil, ms: currentSelectionMs),
            "base": try measures(
                "base", correlation: rankCorrelation(shipped, base.map(\.id)), ms: baseMs.sorted()[2]),
            "base+mmr": try measures("base+mmr", correlation: nil, ms: mmrMs.sorted()[2]),
        ]
        return LeadArms(
            orders: orders,
            report: LeadArmsReport(
                candidates: stories.count, eligible: eligible.count, displayDepth: depth, listDepth: listDepth,
                relevanceWeight: settings.relevanceWeight, temporalDecaySeconds: settings.temporalDecaySeconds,
                embeddingModel: settings.embeddingModel,
                baseRelevance: "Z2 editorial score; ties by original reports, newest report, id; affinity left out",
                displayRules: "photo rule and slide cap on every arm; the score and confidence bars of slides 2 to 5 "
                    + "on current only",
                storiesWithVector: eligible.filter { $0.vector != nil }.count,
                currentFollowsShippedOrder: !currentPlaces.contains(-1)
                    && zip(currentPlaces, currentPlaces.dropFirst()).allSatisfy { $0 < $1 },
                currentAndBaseCoincide: currentTop == baseTop, arms: arms))
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

    /// 30 constructed stories in pairs that share a score. The pair's higher id wins the tie, by original reports
    /// in even pairs and by date in odd ones, so id order never agrees with `base`. The first pair has no photo;
    /// `s02` and `s06` have a publisher the reader favours; topics run in blocks of four stories; every tenth
    /// story has no vector.
    static func leadArmFixture() -> [LeadArmStory] {
        (0..<30).map { index in
            let (pair, second) = (index / 2, index % 2 == 1)
            return LeadArmStory(
                id: String(format: "s%02d", index), score: 0.9 - 0.02 * Double(pair),
                originalReports: pair % 2 == 0 ? (second ? 3 : 1) : 2, affinity: index == 2 || index == 6 ? 0.8 : 0,
                date: EditorialRankingTests.now.addingTimeInterval(second ? 0 : -600), hasPhoto: pair > 0,
                vector: index % 10 == 0 ? nil : EditorialRankingTests.vector(index / 4 % 4), event: "e\(pair)",
                publisher: "p\(index % 3)")
        }
    }

    /// Harness smoke check on the fixture, run with the ranking atom. It shows that the arms rank one pool under
    /// the same display rules and that the measures count as designed, and nothing about real news.
    /// `NEWS_RANKING_OUTPUT` also leaves the fixture's report beside `ranking.json`.
    static func leadArmsSmoke() {
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        do {
            let stories = leadArmFixture()
            // The Lead as the shipped rules would show it here: affinity breaks two ties, and a fifth slide
            // that misses its bar leaves four.
            let shown = ["s02", "s03", "s05", "s04"]
            let arms = try leadArms(
                stories: stories, currentShown: shown, settings: LeadArmSettings(), currentSelectionMs: nil)
            let report = arms.report
            let baseOrder = arms.orders["base"] ?? []
            check(Set(arms.orders.keys) == Set(leadArmNames) && arms.orders["current"] == shown, "three named arms")
            check(
                report.candidates == 30 && report.eligible == 28 && !baseOrder.contains("s00")
                    && arms.orders["base+mmr"]?.contains("s01") == false,
                "the photo rule takes the same stories out of both experimental arms")
            check(
                Array(baseOrder.prefix(5)) == ["s03", "s02", "s05", "s04", "s07"],
                "base orders by score, original reports and date, not by affinity or id")
            let base = baseOrder.compactMap { id in stories.first { $0.id == id } }
            let relevance = baseRelevance(base)
            check(
                zip(relevance, relevance.dropFirst()).allSatisfy { $0 > $1 }
                    && zip(relevance, base).allSatisfy { abs($0 - $1.score) < 1e-9 },
                "relevance is the score, strictly falling along base")
            let pure = try EditorialRanking.rank(
                candidates: zip(base, relevance).map { candidate($0, relevance: $1, model: "fixture") }, limit: 20,
                configuration: EditorialRankingConfiguration(
                    relevanceWeight: 1, temporalDecaySeconds: 21_600, embeddingModelVersion: "fixture")
            ).map(\.id)
            check(Array(baseOrder.prefix(20)) == pure, "base is EditorialRanking at relevance weight 1")
            let mmrOrder = arms.orders["base+mmr"] ?? []
            check(
                mmrOrder.count == 20 && mmrOrder.first == "s03" && Set(mmrOrder).isSubset(of: Set(baseOrder))
                    && mmrOrder != pure,
                "MMR reorders the same eligible stories")
            let (current, baseArm, mmr) = (report.arms["current"], report.arms["base"], report.arms["base+mmr"])
            check(current?.shown == 4 && baseArm?.shown == 5 && mmr?.shown == 5, "shown counts")
            check(
                report.currentFollowsShippedOrder && !report.currentAndBaseCoincide && baseArm?.overlapCurrent == 4
                    && current?.overlapBase == 4,
                "current against base at the display depth")
            let correlation = baseArm?.rankCorrelationCurrent ?? 1
            check(
                correlation > 0.99 && correlation < 1 && current?.rankCorrelationCurrent == nil
                    && mmr?.rankCorrelationCurrent == nil,
                "affinity moves two neighbours in the shipped order")
            check(abs((baseArm?.diversity ?? 0) - 0.6) < 1e-9, "base diversity: four of ten pairs share a topic")
            check(
                (mmr?.diversity ?? 0) > (baseArm?.diversity ?? 1) && (mmr?.overlapBase ?? 5) < 5
                    && baseArm?.overlapBase == 5,
                "MMR shows a more varied top than base")
            check(baseArm?.eventsShown == 3 && baseArm?.publishersShown == 3 && baseArm?.vectorsShown == 5, "counts")
            check(report.storiesWithVector == 26, "vectors in the eligible pool")
            check(baseArm?.selectionMs != nil && mmr?.selectionMs != nil && current?.selectionMs == nil, "timing")
            let ranks = leadArmRanks(arms.orders, depth: 20)
            check(
                ["base", "base+mmr"].allSatisfy { arm in ranks.values.filter { $0[arm] != nil }.count == 20 }
                    && ranks.values.filter { $0["current"] != nil }.count == 4 && ranks["s03"]?["base"] == 1
                    && ranks["s02"]?["current"] == 1,
                "the key holds current's slides and 20 places of each experimental arm")

            let neutral = stories.map {
                LeadArmStory(
                    id: $0.id, score: $0.score, originalReports: $0.originalReports, affinity: 0, date: $0.date,
                    hasPhoto: $0.hasPhoto, vector: $0.vector, event: $0.event, publisher: $0.publisher)
            }
            let control = try leadArms(
                stories: neutral, currentShown: Array(baseOrder.prefix(5)), settings: LeadArmSettings(),
                currentSelectionMs: 1)
            check(
                control.report.currentAndBaseCoincide && control.report.arms["base"]?.rankCorrelationCurrent == 1
                    && control.report.arms["base"]?.overlapCurrent == 5 && control.orders["base+mmr"] == mmrOrder,
                "current and base coinciding is reported as a control")
            let dark = try leadArms(
                stories: stories.map {
                    LeadArmStory(
                        id: $0.id, score: $0.score, originalReports: $0.originalReports, affinity: 0, date: $0.date,
                        hasPhoto: false, vector: $0.vector, event: $0.event, publisher: $0.publisher)
                }, currentShown: ["s01"], settings: LeadArmSettings(), currentSelectionMs: nil)
            check(
                dark.report.displayDepth == 1 && dark.report.eligible == 30 && dark.report.currentAndBaseCoincide
                    && dark.report.arms["base+mmr"]?.shown == 1,
                "no photo anywhere: one story, as the Lead shows")
            let swapped = try leadArms(
                stories: stories, currentShown: ["s03", "s02"], settings: LeadArmSettings(), currentSelectionMs: nil)
            check(!swapped.report.currentFollowsShippedOrder, "slides out of the shipped precedence are flagged")
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
    /// The key of a three-arm run: the #934 key with the display depth (`shown`) and the neutral codes under
    /// which the redundancy sheet presents each arm's shown list (`lists`).
    struct LeadArmsKey: Encodable {
        let pool: String
        let nowTimestamp: Double
        let candidates: Int
        let depth: Int
        let shown: Int
        let lists: [String: String]
        let stories: [TodayShadowEvaluation.PrivateLeadRankingRow]
    }

    struct LeadArmsSnapshotReport: Encodable {
        let pool: String
        let nowTimestamp: Double
        /// Stories with no photo to show, by the shadow run's reading of every such event.
        let storiesWithoutPhoto: Int
        /// Vectors the library holds for the model but `EditorialRanking` would refuse (not unit length); left out.
        let vectorsRefused: Int
        let comparison: LeadArmsReport
    }

    /// Ranks the shadow run's candidates by the three arms and writes, into `arms/` of the private output
    /// directory, `lead-rankings-private.json` (the key) and `lead-arms-report.json` (aggregates only).
    /// `currentLead` is the Lead lane the run assigns with the photo rule, in shown order, and `imageless` the set
    /// that rule read. Scores, original report counts and dates are those of the run's own assignments; affinity
    /// is read from the run's profile only to mirror the shipped precedence; vectors are the stored sentence
    /// vectors of each story's representative.
    /// `NEWS_LEAD_ARMS_DEPTH`, `NEWS_LEAD_ARMS_RELEVANCE_WEIGHT` and `NEWS_LEAD_ARMS_DECAY_SECONDS` set the display
    /// depth and the MMR parameters.
    static func writeLeadArms(
        of candidates: [TodayStoryAssignment], currentLead: [TodayStoryAssignment], imageless: Set<String>,
        profile: TodayUserProfile, pool: String, now: Date, database: DatabaseEngine, currentSelectionMs: Double,
        privateOutput: URL
    ) async throws {
        let env = ProcessInfo.processInfo.environment
        var settings = LeadArmSettings(embeddingModel: "sentence-v\(SentenceEmbedder.modelVersion)")
        if let depth = env["NEWS_LEAD_ARMS_DEPTH"].flatMap(Int.init) { settings.displayDepth = depth }
        if let weight = env["NEWS_LEAD_ARMS_RELEVANCE_WEIGHT"].flatMap(Double.init) {
            settings.relevanceWeight = weight
        }
        if let decay = env["NEWS_LEAD_ARMS_DECAY_SECONDS"].flatMap(Double.init) {
            settings.temporalDecaySeconds = decay
        }

        let stored = try await database.fetchArticleEmbeddings(
            articleIDs: candidates.map(\.entry.representative.id), modelVersion: SentenceEmbedder.modelVersion)
        let vectors = stored.filter { abs($0.value.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) <= 0.001 }
        let stories = candidates.map { item in
            let representative = item.entry.representative
            var event = item.id
            if case .event(let summary, _, _) = item.entry { event = summary.eventID }
            return LeadArmStory(
                id: item.id, score: item.score, originalReports: item.originalReportCount,
                affinity: profile.publisherAffinity(for: representative.publisherName), date: item.sortKey,
                hasPhoto: !imageless.contains(item.id), vector: vectors[representative.id], event: event,
                publisher: representative.publisherName)
        }
        let arms: LeadArms
        do {
            arms = try leadArms(
                stories: stories, currentShown: currentLead.map(\.id), settings: settings,
                currentSelectionMs: currentSelectionMs)
        } catch EditorialRankingError.inputLimit {
            throw NSError(
                domain: "EditorialRankingEvaluation", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The three-arm run ranks at most 500 stories (EditorialRanking's bound); this pool has "
                        + "\(candidates.count). Use NEWS_TODAY_POOL=page."
                ])
        }

        let ranks = leadArmRanks(arms.orders, depth: arms.report.listDepth)
        let rows = candidates.filter { ranks[$0.id] != nil }.sorted { $0.id < $1.id }.map { item in
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
                LeadArmsKey(
                    pool: pool, nowTimestamp: now.timeIntervalSince1970, candidates: candidates.count,
                    depth: arms.report.listDepth, shown: arms.report.displayDepth,
                    lists: Dictionary(uniqueKeysWithValues: zip(["A", "B", "C"], leadArmNames.shuffled())),
                    stories: rows)),
            to: directory.appendingPathComponent("lead-rankings-private.json"), replacing: true)
        try StoryCorpus.writePrivate(
            try encoder.encode(
                LeadArmsSnapshotReport(
                    pool: pool, nowTimestamp: now.timeIntervalSince1970,
                    storiesWithoutPhoto: stories.filter { !$0.hasPhoto }.count,
                    vectorsRefused: stored.count - vectors.count, comparison: arms.report)),
            to: directory.appendingPathComponent("lead-arms-report.json"), replacing: true)
    }
}
