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

/// Offline controls for the experimental novelty engine; ordinary runs never load Core ML.
enum EditorialNoveltyTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ Editorial novelty: \(message)")
        }
    }

    static let stamp = EditorialNoveltyStamp(inputHash: "input", membershipHash: "members", analysisVersion: 1)
    static let oldText = "Aster Transit closed the eastern line after a cable fault."
    static let newText = "Aster Transit added three replacement buses."

    static func passage(_ id: String, _ text: String, event: String = "event", observed: Double = 10)
        -> EditorialPassage
    {
        EditorialPassage(
            eventID: event, passage: EvidencePassage(id: id, articleID: "article-" + id, text: text),
            publishedAt: Date(timeIntervalSince1970: observed - 1), observedAt: Date(timeIntervalSince1970: observed))
    }

    static func engine(_ provider: NoveltyTestEmbeddings, energy: Bool = true) -> EditorialNovelty {
        EditorialNovelty(
            policy: EditorialNoveltyPolicy(repeatSimilarity: 0.9, strongLexicalOverlap: 0.4), modelVersion: "2",
            embeddingProvider: { await provider.embed($0) }, allowsEnergy: { energy })
    }

    static func run() async {
        do {
            routeMismatchReporting()
            try await routesAndCitations()
            try await historicalBoundaries()
            try await cacheAndEnergy()
            try await clearWhileEmbedding()
            if let corpus = ProcessInfo.processInfo.environment["NEWS_EDITORIAL_CORPUS"],
                let output = ProcessInfo.processInfo.environment["NEWS_EDITORIAL_OUTPUT"]
            {
                try await evaluate(corpus: URL(fileURLWithPath: corpus), output: URL(fileURLWithPath: output))
            }
        } catch {
            check(false, "Unexpected error: \(error)")
        }
        print("Finished \(checks) editorial novelty checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }

    static func routeMismatchReporting() {
        var counts = OutcomeCounts()
        counts.recordRoute(.noAnchoredSentence, expected: "fallback", id: "mismatch")
        counts.recordRoute(.repetition, expected: "repetition", id: "match")
        check(counts.routeMismatchIDs == ["mismatch"], "route mismatches retain the case ID")
        check(
            counts.predictedRoutes["unanchored"] == 1 && counts.predictedRoutes["repetition"] == 1,
            "predicted routes are counted separately")
    }

    static func routesAndCitations() async throws {
        let provider = NoveltyTestEmbeddings()
        let subject = engine(provider)
        let baseline = [passage("baseline", oldText)]
        let candidate = passage("incoming", oldText + " " + newText, observed: 20)
        let result = try await subject.analyze(
            candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
        if case .novel(let selection) = result {
            check(selection.sentence == newText, "select the farthest anchored sentence verbatim")
            check(selection.citation.articleID == candidate.passage.articleID, "citation retains incoming article")
            check(selection.citation.passageID == candidate.passage.id, "citation retains incoming passage")
            check(selection.citation.quote == newText, "citation quote is the exact source sentence")
            check(selection.stamp.inputHash == stamp.inputHash, "return the input stamp")
            check(selection.stamp.membershipHash == stamp.membershipHash, "return the membership stamp")
        } else {
            check(false, "a new anchored fact must remain a candidate")
        }
        let repeated = try await subject.analyze(
            candidate: passage("repeat", oldText, observed: 20), baseline: baseline, coreEntities: ["Aster Transit"],
            stamp: stamp)
        if case .repetition = repeated {
            check(true, "repetition")
        } else {
            check(false, "identical evidence is repetition")
        }
        let unanchored = try await subject.analyze(
            candidate: passage("boilerplate", "The company closed the eastern line after a cable fault.", observed: 20),
            baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
        if case .noAnchoredSentence = unanchored {
            check(true, "unanchored")
        } else {
            check(false, "reject sentences without a core actor")
        }
    }

    static func historicalBoundaries() async throws {
        let provider = NoveltyTestEmbeddings()
        let subject = engine(provider)
        let candidate = passage("incoming", oldText, observed: 20)
        for baseline in [
            [passage("future", oldText, observed: 30)],
            [passage("other", oldText, event: "other")],
            [candidate],
            [passage("unrelated", "Copper satellites orbit distant planets.")],
            [
                EditorialPassage(
                    eventID: "event",
                    passage: EvidencePassage(id: "impossible", articleID: "impossible", text: oldText),
                    publishedAt: Date(timeIntervalSince1970: 15), observedAt: Date(timeIntervalSince1970: 10))
            ],
        ] {
            let result = try await subject.analyze(
                candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
            if case .lowPrioritySemanticFallback = result {
                check(true, "historical lexical miss")
            } else {
                check(false, "unavailable, unrelated and self evidence cannot enter the baseline")
            }
        }
        let count = await provider.count
        check(count == 0, "lexical misses do not start the embedder")
    }

    static func cacheAndEnergy() async throws {
        let provider = NoveltyTestEmbeddings()
        let subject = engine(provider)
        let baseline = [passage("baseline", oldText)]
        let candidate = passage("incoming", oldText + " " + newText, observed: 20)
        _ = try await subject.analyze(
            candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
        let cold = await provider.count
        _ = try await subject.analyze(
            candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
        let warm = await provider.count
        check(cold > 0 && warm == cold, "warm requests reuse text/model vectors")
        await subject.clearCache()
        _ = try await subject.analyze(
            candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
        let refreshed = await provider.count
        check(refreshed > warm, "clear invalidates cached vectors")
        let pausedProvider = NoveltyTestEmbeddings()
        let paused = engine(pausedProvider, energy: false)
        let result = try await paused.analyze(
            candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: stamp)
        if case .deferred = result {
            check(true, "energy deferral")
        } else {
            check(false, "energy policy defers semantic work")
        }
        let pausedCount = await pausedProvider.count
        check(pausedCount == 0, "energy deferral makes no model call")
    }

    static func clearWhileEmbedding() async throws {
        let provider = NoveltyTestEmbeddings(paused: true)
        let subject = engine(provider)
        let task = Task {
            try await subject.analyze(
                candidate: passage("incoming", oldText + " " + newText, observed: 20),
                baseline: [passage("baseline", oldText)], coreEntities: ["Aster Transit"], stamp: stamp)
        }
        defer { task.cancel() }
        await provider.waitUntilEntered()
        let concurrent = try await subject.analyze(
            candidate: passage("parallel", oldText + " " + newText, observed: 20),
            baseline: [passage("baseline", oldText)], coreEntities: ["Aster Transit"], stamp: stamp)
        if case .deferred = concurrent {
            check(true, "concurrent semantic work is deferred")
        } else {
            check(false, "one suspended analysis owns semantic work")
        }
        let inFlightCount = await provider.count
        check(inFlightCount == 2, "concurrent requests do not recompute the same vectors")
        await subject.clearCache()
        await provider.resume()
        do {
            let result = try await task.value
            if case .deferred = result {
                check(true, "stale generation deferred")
            } else {
                check(false, "a cleared generation cannot publish a result")
            }
        } catch is CancellationError { check(true, "stale generation rejected") }
        let stats = await subject.stats()
        check(stats.entries == 0, "an old embedding task cannot repopulate the cleared cache")
    }
}

extension EditorialNoveltyTests {
    struct CorpusPassage: Decodable {
        let id: String
        let articleID: String
        let text: String
        let publishedAt: Double
        let observedAt: Double

        func evidence(eventID: String) -> EditorialPassage {
            EditorialPassage(
                eventID: eventID, passage: EvidencePassage(id: id, articleID: articleID, text: text),
                publishedAt: Date(timeIntervalSince1970: publishedAt),
                observedAt: Date(timeIntervalSince1970: observedAt))
        }
    }

    struct CorpusCase: Decodable {
        let id: String
        let split: String
        let eventID: String
        let coreEntities: [String]
        let baseline: [CorpusPassage]
        let incoming: CorpusPassage
        let expected: String
    }

    struct OutcomeCounts {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var deferred = 0
        var latency: [Double] = []
        var predictedRoutes: [String: Int] = [:]
        var routeMismatchIDs: [String] = []

        mutating func recordRoute(_ result: EditorialNoveltyResult, expected: String, id: String) {
            let route: String
            switch result {
            case .novel: route = "novel"
            case .repetition: route = "repetition"
            case .noAnchoredSentence: route = "unanchored"
            case .lowPrioritySemanticFallback: route = "fallback"
            case .deferred: route = "deferred"
            }
            predictedRoutes[route, default: 0] += 1
            if route != expected { routeMismatchIDs.append(id) }
        }

        var report: [String: Any] {
            let proposed = truePositive + falsePositive
            return [
                "true_positive": truePositive, "false_positive": falsePositive, "false_negative": falseNegative,
                "precision": proposed == 0 ? NSNull() : Double(truePositive) / Double(proposed),
                "recall": truePositive + falseNegative == 0
                    ? NSNull() : Double(truePositive) / Double(truePositive + falseNegative),
                "deferred": deferred, "predicted_routes": predictedRoutes, "route_mismatch_ids": routeMismatchIDs,
                "latency_ms": latency,
            ]
        }
    }

    static func score(_ cases: [CorpusCase], subject: EditorialNovelty) async throws -> OutcomeCounts {
        var counts = OutcomeCounts()
        for item in cases {
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await subject.analyze(
                candidate: item.incoming.evidence(eventID: item.eventID),
                baseline: item.baseline.map { $0.evidence(eventID: item.eventID) }, coreEntities: item.coreEntities,
                stamp: EditorialNoveltyStamp(
                    inputHash: ArticleIdentity.sha256Hex(item.incoming.text), membershipHash: item.eventID,
                    analysisVersion: 1))
            counts.latency.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            counts.recordRoute(result, expected: item.expected, id: item.id)
            if case .novel(let selection) = result {
                guard item.incoming.text.contains(selection.sentence), selection.citation.quote == selection.sentence
                else {
                    throw CocoaError(.coderInvalidValue)
                }
                if item.expected == "novel" { counts.truePositive += 1 } else { counts.falsePositive += 1 }
            } else {
                if item.expected == "novel" { counts.falseNegative += 1 }
                if case .deferred = result { counts.deferred += 1 }
            }
        }
        return counts
    }

    /// The authored tune split selects an experimental threshold; the holdout is scored once afterward.
    static func evaluate(corpus: URL, output: URL) async throws {
        guard IntelligencePolicy.allowsEnergy() else { throw CocoaError(.userCancelled) }
        let raw = try Data(contentsOf: corpus)
        let cases = try JSONDecoder().decode([CorpusCase].self, from: raw)
        let tune = cases.filter { $0.split == "tune" }
        let holdout = cases.filter { $0.split == "holdout" }
        guard tune.count == 24, holdout.count == 24,
            Set(tune.map(\.eventID)).isDisjoint(with: Set(holdout.map(\.eventID)))
        else { throw CocoaError(.coderInvalidValue) }
        let provider = NoveltyMeasuredEmbeddings()
        var best: (Double, OutcomeCounts, EditorialNovelty)?
        var sweep: [[String: Any]] = []
        for threshold in [0.85, 0.9, 0.95] {
            let subject = EditorialNovelty(
                policy: EditorialNoveltyPolicy(repeatSimilarity: threshold, strongLexicalOverlap: 0.4),
                modelVersion: String(SentenceEmbedder.modelVersion), embeddingProvider: { await provider.embed($0) })
            let counts = try await score(tune, subject: subject)
            guard counts.deferred == 0 else { throw CocoaError(.featureUnsupported) }
            sweep.append(["repeat_similarity": threshold, "metrics": counts.report])
            if best == nil || counts.falsePositive < best!.1.falsePositive
                || (counts.falsePositive == best!.1.falsePositive && counts.truePositive > best!.1.truePositive)
            {
                best = (threshold, counts, subject)
            }
        }
        guard let selected = best else { throw CocoaError(.coderInvalidValue) }
        let held = try await score(holdout, subject: selected.2)
        guard held.deferred == 0 else { throw CocoaError(.featureUnsupported) }
        let coldStats = await selected.2.stats()
        let warmed = try await score(holdout, subject: selected.2)
        guard warmed.deferred == 0 else { throw CocoaError(.featureUnsupported) }
        let warmStats = await selected.2.stats()
        let model = await provider.report()
        let source = try Data(contentsOf: URL(fileURLWithPath: "Sources/Intelligence/Editorial/EditorialNovelty.swift"))
        let report: [String: Any] = [
            "schema_version": 1, "phase": 1, "basis": "fictional_authored_smoke_controls",
            "build_configuration": ProcessInfo.processInfo.environment["NEWS_EDITORIAL_BUILD_CONFIGURATION"]
                ?? "unspecified",
            "embedding_model_version": SentenceEmbedder.modelVersion,
            "vector_dimension": SentenceEmbedder.vectorDimension,
            "source_sha256": ArticleIdentity.sha256Hex(String(decoding: source, as: UTF8.self)),
            "corpus_sha256": ArticleIdentity.sha256Hex(String(decoding: raw, as: UTF8.self)),
            "tune_cases": tune.count, "holdout_cases": holdout.count,
            "selection_rule": "fewest tune false positives, then most true positives, then first threshold",
            "selected_repeat_similarity": selected.0, "strong_lexical_overlap": 0.4,
            "tune_sweep": sweep, "holdout": held.report, "warm_holdout": warmed.report,
            "cache_before_warm": [
                "hits": coldStats.cacheHits, "misses": coldStats.cacheMisses, "entries": coldStats.entries,
            ],
            "cache_after_warm": [
                "hits": warmStats.cacheHits, "misses": warmStats.cacheMisses, "entries": warmStats.entries,
            ],
            "model": model, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "ane_spin_up_ms": NSNull(), "ane_cpu_power_draw": NSNull(),
            "hardware_status": "application latency measured; ANE attribution and power unmeasured",
            "production_readiness": "not_established",
            "limitations": [
                "Paired fictional templates across splits limit generalization.",
                "Two holdout repetition controls have independently noted ambiguity.",
                "No consumer is enabled by this report.",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Editorial novelty experiment wrote \(output.path)")
    }
}

actor NoveltyMeasuredEmbeddings {
    private var vectors: [String: [Float]] = [:]
    private var calls = 0
    private var milliseconds: [Double] = []

    func embed(_ texts: [String]) async -> [[Float]?] {
        let missing = texts.filter { vectors[$0] == nil }
        if !missing.isEmpty {
            let start = ProcessInfo.processInfo.systemUptime
            let batch = await SentenceEmbedder.shared.embedBatch(missing)
            milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            calls += 1
            for (text, vector) in zip(missing, batch) { if let vector { vectors[text] = vector } }
        }
        return texts.map { vectors[$0] }
    }

    func report() -> [String: Any] {
        [
            "provider_calls": calls, "unique_texts": vectors.count, "batch_ms": milliseconds,
            "cache_scope": "shared across experimental tune candidates; engine cache stats reported separately",
        ]
    }
}

actor NoveltyTestEmbeddings {
    private(set) var count = 0
    private var paused: Bool
    private var entered = false
    private var pending: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?

    init(paused: Bool = false) { self.paused = paused }

    func embed(_ texts: [String]) async -> [[Float]?] {
        count += texts.count
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if paused { await withCheckedContinuation { pending = $0 } }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: 384)
            vector[text.contains("replacement") ? 1 : 0] = 1
            return vector
        }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }

    func resume() {
        paused = false
        pending?.resume()
        pending = nil
    }
}
