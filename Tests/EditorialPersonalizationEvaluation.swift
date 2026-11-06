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

/// Opt-in synthetic storage, allocation and ranking controls; not evidence of user relevance.
enum EditorialPersonalizationEvaluation {
    private static func dcg(_ grades: [Int]) -> Double {
        grades.enumerated().reduce(0) { $0 + (pow(2, Double($1.element)) - 1) / log2(Double($1.offset + 2)) }
    }

    private static func ndcg(_ selected: [EditorialRankingSelection], grades: [String: Int]) -> Double {
        let ideal = dcg(Array(grades.values.sorted(by: >).prefix(10)))
        return ideal == 0 ? 0 : dcg(selected.map { grades[$0.id, default: 0] }) / ideal
    }

    private static func ranking(profile: [Float], time: Date) throws -> [String: Any] {
        let candidates = (0..<500).map { index in
            var vector = Array(repeating: Float.zero, count: 384)
            vector[index / 50] = 1
            let preference = zip(profile, vector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            return EditorialRankingCandidate(
                id: String(format: "story-%04d", index), relevance: 0.5 + Double(index % 50) / 500,
                date: time, vector: vector, embeddingModelVersion: "synthetic-v1", preference: preference)
        }
        let neutral = EditorialRankingConfiguration(
            relevanceWeight: 0.7, temporalDecaySeconds: 21600, embeddingModelVersion: "synthetic-v1")
        let personalized = EditorialRankingConfiguration(
            relevanceWeight: 0.7, temporalDecaySeconds: 21600, embeddingModelVersion: "synthetic-v1",
            preferenceWeight: 0.2)
        let baseline = try EditorialRanking.rank(candidates: candidates, limit: 10, configuration: neutral)
        let selected = try EditorialRanking.rank(candidates: candidates, limit: 10, configuration: personalized)
        let lookup = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let baselineDiversity = try EditorialRanking.meanSemanticDiversity(baseline.compactMap { lookup[$0.id] })
        let selectedDiversity = try EditorialRanking.meanSemanticDiversity(selected.compactMap { lookup[$0.id] })
        var baselineNDCG = [Double]()
        var personalizedNDCG = [Double]()
        for topic in 0..<10 {
            let grades = Dictionary(
                uniqueKeysWithValues: candidates.enumerated().map { index, candidate in
                    (candidate.id, index / 50 == topic ? 3 : 0)
                })
            baselineNDCG.append(ndcg(baseline, grades: grades))
            personalizedNDCG.append(ndcg(selected, grades: grades))
        }
        guard let baselineDiversity, let selectedDiversity else { throw PersonalizationError.invalidInput }
        return [
            "candidateCount": 500, "judgementSets": 10, "judgementsPerSet": 500,
            "preferenceWeight": 0.2, "preference": "dot product of learned profile and constructed unit vector",
            "baselineNDCGAt10": baselineNDCG, "personalizedNDCGAt10": personalizedNDCG,
            "baselineMeanNDCGAt10": baselineNDCG.reduce(0, +) / 10,
            "personalizedMeanNDCGAt10": personalizedNDCG.reduce(0, +) / 10,
            "baselineSemanticDiversity": baselineDiversity, "personalizedSemanticDiversity": selectedDiversity,
            "baselineIDs": baseline.map(\.id), "personalizedIDs": selected.map(\.id),
            "limitations": [
                "Constructed unit vectors, rewards and topic judgements are synthetic controls, not user relevance evidence.",
                "The same learned synthetic profile is compared against ten distinct topic judgements; they are not ten user profiles.",
                "The preference weight is experimental, with no shipping default or production consumer.",
            ],
        ]
    }

    static func run(output: String) async throws {
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let time = Date(timeIntervalSince1970: 1_793_188_800)
        let policy = PersonalizationPolicy(halfLife: 86400, clickWeight: 1, saveWeight: 2, skipWeight: -1)
        let store = try EditorialPersonalization(
            policy: policy, modelVersion: "synthetic-v1", path: scratch.appendingPathComponent("store.sqlite").path,
            now: { time })
        var vector = Array(repeating: Float.zero, count: 384)
        vector[0] = 1
        var skipVector = Array(repeating: Float.zero, count: 384)
        skipVector[1] = 1
        try await store.recordRendered(
            .init(
                impressionID: "disabled", articleID: "disabled", topicID: "topic", vector: vector,
                modelVersion: "synthetic-v1", at: time))
        let disabledCount = try await store.counts().impressions
        await store.setEnabled(true)
        let start = Date()
        for index in 0..<1000 {
            let id = "episode-\(index)"
            try await store.recordRendered(
                .init(
                    impressionID: id, articleID: "article-\(index % 100)", topicID: "topic-\(index % 10)",
                    vector: index % 4 == 3 ? nil : (index % 4 == 2 ? skipVector : vector), modelVersion: "synthetic-v1",
                    at: time))
            switch index % 4 {
            case 0: try await store.recordClick(impressionID: id, at: time)
            case 1: try await store.recordSave(impressionID: id, at: time)
            case 2: try await store.recordScrolledPast(impressionID: id, at: time)
            default: break
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let counts = try await store.counts()
        let profile = try await store.profile(at: time)
        let candidates = [
            DiscoveryCandidate(
                articleID: "adjacent-under-1", topicID: "adjacent", isAdjacent: true, priorImpressions: 0),
            DiscoveryCandidate(
                articleID: "adjacent-under-2", topicID: "adjacent", isAdjacent: true, priorImpressions: 1),
            DiscoveryCandidate(articleID: "adjacent-equal", topicID: "adjacent", isAdjacent: true, priorImpressions: 3),
            DiscoveryCandidate(articleID: "nonadjacent", topicID: "other", isAdjacent: false, priorImpressions: 0),
        ]
        let allocation = try EditorialPersonalization.discoveryAllocation(
            batchSize: 20, remainder: 0, candidates: candidates, baselineExposure: 3)
        let remainder = try EditorialPersonalization.discoveryAllocation(
            batchSize: 1, remainder: 0, candidates: candidates, baselineExposure: 3)
        guard let profile else { throw PersonalizationError.invalidInput }
        let rankingResult = try ranking(profile: profile, time: time)
        let source = try Data(
            contentsOf: URL(fileURLWithPath: "Sources/Intelligence/Editorial/EditorialPersonalization.swift"))
        let process = ProcessInfo.processInfo
        let result: [String: Any] = [
            "schema_version": 1, "phase": 4,
            "basis": "synthetic_impressions_and_constructed_unit_vectors",
            "build_configuration": process.environment["NEWS_EDITORIAL_BUILD_CONFIGURATION"] ?? "unspecified",
            "source_sha256": ArticleIdentity.sha256Hex(String(decoding: source, as: UTF8.self)),
            "operating_system": process.operatingSystemVersionString,
            "processor_count": process.processorCount,
            "production_readiness": "not_established", "raw_retention_days": 30,
            "scope": "synthetic storage, allocation and ranking controls; no user relevance claims",
            "ranking": rankingResult,
            "disabledImpressions": disabledCount,
            "impressions": counts.impressions, "clicks": counts.clicks, "saves": counts.saves,
            "skips": counts.skips, "neutralImpressions": 250, "uniqueArticles": 100,
            "elapsedSeconds": elapsed, "storageBytes": try await store.storageBytes(),
            "profile": profile.map(Double.init),
            "discovery": [
                "batchSize": 20, "quotaNumerator": 3, "quotaDenominator": 20,
                "baselineExposure": 3, "requested": allocation.requested,
                "articleIDs": allocation.articleIDs, "shortage": allocation.shortage,
                "remainder": allocation.remainder, "singleItemRemainder": remainder.remainder,
                "candidates": candidates.map {
                    [
                        "articleID": $0.articleID, "topicID": $0.topicID,
                        "isAdjacent": $0.isAdjacent, "priorImpressions": $0.priorImpressions,
                    ] as [String: Any]
                },
            ] as [String: Any],
        ]
        guard disabledCount == 0, counts.impressions == 1000, counts.clicks == 250,
            counts.saves == 250, counts.skips == 250,
            allocation.requested == 3, allocation.articleIDs.count == 2, allocation.shortage == 1,
            remainder.remainder == 3
        else { throw PersonalizationError.invalidInput }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: directory.appendingPathComponent("personalization-evaluation.json"), options: .withoutOverwriting)
    }
}
