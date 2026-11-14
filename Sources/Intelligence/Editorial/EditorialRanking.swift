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

// Angelia · Athena (editorial selection) owns this file. Experimental, no production consumer.
// Register: docs/ANGELIA.md.

import Accelerate
import Foundation

/// One already-formed candidate for `EditorialRanking.rank`; ids must be unique and non-empty.
struct EditorialRankingCandidate: Sendable {
    let id: String
    /// Base relevance from 0 to 1.
    let relevance: Double
    /// The time that decays the similarity between two candidates.
    let date: Date
    /// A unit-length 384-dimension embedding; nil contributes no similarity penalty.
    let vector: [Float]?
    /// The model that made `vector`; must match the configuration's when `vector` is set.
    let embeddingModelVersion: String?
    /// The reader's preference from -1 to 1, added to relevance scaled by `preferenceWeight`.
    let preference: Double?
}

/// Weights for `EditorialRanking.rank`.
struct EditorialRankingConfiguration: Sendable {
    /// From 0 to 1: the share of the score given to relevance; the rest penalizes similarity to picks already made.
    let relevanceWeight: Double
    /// The time constant of the exponential decay that makes far-apart candidates less similar; must be positive.
    let temporalDecaySeconds: TimeInterval
    /// From 0 to 1: how much a candidate's preference moves its relevance.
    let preferenceWeight: Double
    /// The only embedding model whose vectors are accepted; must not be empty.
    let embeddingModelVersion: String

    init(
        relevanceWeight: Double, temporalDecaySeconds: TimeInterval, embeddingModelVersion: String,
        preferenceWeight: Double = 0
    ) {
        self.relevanceWeight = relevanceWeight
        self.temporalDecaySeconds = temporalDecaySeconds
        self.preferenceWeight = preferenceWeight
        self.embeddingModelVersion = embeddingModelVersion
    }
}

/// One pick, in ranking order, with the score that chose it.
struct EditorialRankingSelection: Sendable {
    let id: String
    let score: Double
    /// Relevance after the preference adjustment, clamped to 0 through 1.
    let relevance: Double
    /// The highest time-decayed cosine similarity to an earlier pick.
    let penalty: Double
}

/// Why ranking refused its input: a weight out of range, an invalid or duplicate candidate, or more than 500 candidates
/// or a limit above 50.
enum EditorialRankingError: Error { case invalidConfiguration, invalidCandidate, inputLimit }

/// Bounded experimental reranking of already-formed candidates; event membership is unchanged.
enum EditorialRanking {
    /// Picks up to `limit` candidates greedily, maximal marginal relevance style: each pick maximizes weighted
    /// relevance minus the weighted similarity to earlier picks.
    ///
    /// Ties go to the lower id. Throws `EditorialRankingError` for invalid input and `CancellationError` when
    /// cancelled.
    static func rank(
        candidates: [EditorialRankingCandidate], limit: Int,
        configuration: EditorialRankingConfiguration
    ) throws -> [EditorialRankingSelection] {
        try validate(configuration)
        guard candidates.count <= 500, (0...50).contains(limit) else {
            throw EditorialRankingError.inputLimit
        }
        try validate(candidates, model: configuration.embeddingModelVersion)
        var remaining = candidates.sorted { $0.id < $1.id }
        var penalties = [Double](repeating: 0, count: remaining.count)
        var result: [EditorialRankingSelection] = []
        while !remaining.isEmpty && result.count < limit {
            try Task.checkCancellation()
            var bestIndex = 0
            var bestScore = -Double.infinity
            var bestRelevance = 0.0
            var bestPenalty = 0.0
            for (index, candidate) in remaining.enumerated() {
                let relevance = min(
                    1,
                    max(0, candidate.relevance + configuration.preferenceWeight * (candidate.preference ?? 0))
                )
                let penalty = penalties[index]
                let score =
                    configuration.relevanceWeight * relevance - (1 - configuration.relevanceWeight) * penalty
                if score > bestScore {
                    bestIndex = index
                    bestScore = score
                    bestRelevance = relevance
                    bestPenalty = penalty
                }
            }
            let candidate = remaining.remove(at: bestIndex)
            penalties.remove(at: bestIndex)
            result.append(
                .init(id: candidate.id, score: bestScore, relevance: bestRelevance, penalty: bestPenalty))
            for index in remaining.indices {
                penalties[index] = max(
                    penalties[index], similarity(remaining[index], candidate, tau: configuration.temporalDecaySeconds))
            }
        }
        return result
    }

    private static func validate(_ configuration: EditorialRankingConfiguration) throws {
        guard !configuration.embeddingModelVersion.isEmpty, configuration.relevanceWeight.isFinite,
            (0...1).contains(configuration.relevanceWeight), configuration.temporalDecaySeconds.isFinite,
            configuration.temporalDecaySeconds > 0, configuration.preferenceWeight.isFinite,
            (0...1).contains(configuration.preferenceWeight)
        else { throw EditorialRankingError.invalidConfiguration }
    }

    private static func validate(_ candidates: [EditorialRankingCandidate], model: String) throws {
        var ids = Set<String>()
        for candidate in candidates {
            try Task.checkCancellation()
            guard !candidate.id.isEmpty, ids.insert(candidate.id).inserted,
                candidate.relevance.isFinite, (0...1).contains(candidate.relevance),
                candidate.date.timeIntervalSince1970.isFinite,
                candidate.preference.map({ $0.isFinite && (-1...1).contains($0) }) ?? true,
                candidate.vector.map(validVector) ?? true,
                candidate.vector == nil || candidate.embeddingModelVersion == model
            else { throw EditorialRankingError.invalidCandidate }
        }
    }

    /// Mean 1 - cosine over vector-bearing pairs; nil when fewer than two vectors are available.
    static func meanSemanticDiversity(_ candidates: [EditorialRankingCandidate]) throws -> Double? {
        guard candidates.count <= 500 else { throw EditorialRankingError.inputLimit }
        let bearing = candidates.filter { $0.vector != nil }
        guard bearing.allSatisfy({ $0.embeddingModelVersion?.isEmpty == false }),
            Set(bearing.compactMap(\.embeddingModelVersion)).count <= 1
        else { throw EditorialRankingError.invalidCandidate }
        let vectors = candidates.compactMap(\.vector)
        guard vectors.allSatisfy(validVector) else { throw EditorialRankingError.invalidCandidate }
        guard vectors.count >= 2 else { return nil }
        var sum = 0.0
        var pairs = 0
        for i in 0..<(vectors.count - 1) {
            try Task.checkCancellation()
            for j in (i + 1)..<vectors.count {
                sum += 1 - cosine(vectors[i], vectors[j])
                pairs += 1
            }
        }
        return sum / Double(pairs)
    }

    private static func validVector(_ vector: [Float]) -> Bool {
        guard vector.count == 384, vector.allSatisfy(\.isFinite) else { return false }
        let normSquared = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        return abs(normSquared - 1) <= 0.001
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return min(1, max(-1, Double(dot)))
    }

    private static func similarity(
        _ a: EditorialRankingCandidate, _ b: EditorialRankingCandidate, tau: TimeInterval
    ) -> Double {
        guard let first = a.vector, let second = b.vector else { return 0 }
        let distance = abs(a.date.timeIntervalSince(b.date))
        return max(0, cosine(first, second)) * exp(-distance / tau)
    }
}
