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
        let values = try (0..<50).map { event -> Double in
            let reports = (0..<(event % 5 * 3)).map { index in
                MomentumReport(
                    articleID: "r-\(event)-\(index)", eventID: "event", wireGroupID: "wire-\(index)",
                    localPublisherID: "local-\(index)", originPublisherID: "origin-\(index%5)",
                    publishedAt: now.addingTimeInterval(-Double(index + 1) * 60),
                    fetchedAt: now.addingTimeInterval(-Double(index + 1) * 60 + 10))
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
