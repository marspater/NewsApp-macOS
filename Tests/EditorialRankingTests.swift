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

enum EditorialRankingTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static let now = Date(timeIntervalSince1970: 1_793_491_200)
    static func vector(_ axis: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 384)
        result[axis] = 1
        return result
    }
    static func candidate(_ id: String, _ relevance: Double, _ axis: Int?, age: Double = 0, preference: Double? = nil)
        -> EditorialRankingCandidate
    {
        .init(
            id: id, relevance: relevance, date: now.addingTimeInterval(-age), vector: axis.map(vector),
            embeddingModelVersion: axis == nil ? nil : "test-v1", preference: preference)
    }
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ Ranking: \(message)")
        }
    }
    static func config(_ lambda: Double = 0.5, tau: Double = 3600, preference: Double = 0)
        -> EditorialRankingConfiguration
    {
        .init(
            relevanceWeight: lambda, temporalDecaySeconds: tau, embeddingModelVersion: "test-v1",
            preferenceWeight: preference)
    }
    static func run() async {
        do {
            let input = [candidate("a", 1, 0), candidate("b", 0.99, 0), candidate("c", 0.8, 1)]
            let diverse = try EditorialRanking.rank(candidates: input, limit: 3, configuration: config())
            check(
                diverse.map(\.id) == ["a", "c", "b"], "MMR selects the relevant distinct story before a near-duplicate")
            check(abs(diverse[1].penalty) < 1e-12 && abs(diverse[2].penalty - 1) < 1e-12, "known cosine penalties")
            let retained = try EditorialRanking.rank(
                candidates: [
                    candidate("a", 1, 0), candidate("b", 0.99, 0), candidate("c", 0.8, 1), candidate("d", 0.7, 2),
                ],
                limit: 4, configuration: config())
            check(
                retained.map(\.id) == ["a", "c", "d", "b"] && retained.last?.penalty == 1,
                "maximum penalty survives later orthogonal selections")
            let pure = try EditorialRanking.rank(candidates: input, limit: 3, configuration: config(1))
            check(pure.map(\.id) == ["a", "b", "c"], "lambda one preserves base relevance")
            let old = [candidate("a", 1, 0), candidate("b", 0.99, 0, age: 86400), candidate("c", 0.8, 1)]
            let recap = try EditorialRanking.rank(candidates: old, limit: 3, configuration: config())
            check(recap.map(\.id) == ["a", "b", "c"], "continuous temporal decay permits an older recap")
            let tie = try EditorialRanking.rank(
                candidates: [candidate("b", 0.5, nil), candidate("a", 0.5, nil)], limit: 2, configuration: config())
            check(tie.map(\.id) == ["a", "b"], "stable IDs resolve ties without labels")
            let pref = [candidate("a", 0.9, nil, preference: -1), candidate("b", 0.5, nil, preference: 1)]
            let neutral = try EditorialRanking.rank(candidates: pref, limit: 2, configuration: config(1))
            check(neutral.first?.id == "a", "preference is neutral before integration")
            let personal = try EditorialRanking.rank(
                candidates: pref, limit: 2, configuration: config(1, preference: 0.5))
            check(personal.first?.id == "b", "explicit preference integration changes only requested selection")
            let same = try EditorialRanking.meanSemanticDiversity([candidate("a", 1, 0), candidate("b", 1, 0)])
            let distinct = try EditorialRanking.meanSemanticDiversity([candidate("a", 1, 0), candidate("b", 1, 1)])
            check(same == 0 && distinct == 1, "pairwise semantic diversity matches hand examples")
            let missing = try EditorialRanking.meanSemanticDiversity([candidate("a", 1, nil)])
            check(missing == nil, "unknown diversity is not fabricated")
            check(
                try EditorialRanking.rank(candidates: [], limit: 0, configuration: config()).isEmpty, "empty selection")
            do {
                _ = try EditorialRanking.rank(
                    candidates: [candidate("same", 1, 0), candidate("same", 0.5, 1)], limit: 2, configuration: config())
                check(false, "duplicate IDs must fail")
            } catch EditorialRankingError.invalidCandidate { check(true, "duplicate IDs") }
            let invalid = EditorialRankingCandidate(
                id: "bad", relevance: 1, date: now, vector: [1, 0], embeddingModelVersion: "test-v1", preference: nil)
            do {
                _ = try EditorialRanking.rank(candidates: [invalid], limit: 1, configuration: config())
                check(false, "bad vector must fail")
            } catch EditorialRankingError.invalidCandidate { check(true, "bad dimensions") }
            do {
                _ = try EditorialRanking.rank(candidates: input, limit: 51, configuration: config())
                check(false, "selection bound must fail")
            } catch EditorialRankingError.inputLimit { check(true, "selection bound") }
            do {
                _ = try EditorialRanking.rank(candidates: input, limit: 1, configuration: config(tau: 0))
                check(false, "invalid decay must fail")
            } catch EditorialRankingError.invalidConfiguration { check(true, "decay validation") }
            let mixed = EditorialRankingCandidate(
                id: "mixed", relevance: 1, date: now, vector: vector(0), embeddingModelVersion: "other-model",
                preference: nil)
            do {
                _ = try EditorialRanking.rank(candidates: [mixed], limit: 1, configuration: config())
                check(false, "mixed model must fail")
            } catch EditorialRankingError.invalidCandidate { check(true, "model provenance") }
            let large = (0..<500).map { candidate(String(format: "%04d", $0), Double(500 - $0) / 500, $0 % 384) }
            let selected = try EditorialRanking.rank(candidates: large, limit: 10, configuration: config())
            check(
                selected.count == 10 && Set(selected.map(\.id)).count == 10,
                "500-vector selection returns unique formed stories")
            let cancelled = Task {
                while !Task.isCancelled { await Task.yield() }
                return try EditorialRanking.rank(candidates: input, limit: 1, configuration: config())
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                check(false, "cancellation must stop ranking")
            } catch is CancellationError { check(true, "cancellation") }
            #if !EDITORIAL_STANDALONE
                if let output = ProcessInfo.processInfo.environment["NEWS_RANKING_OUTPUT"] {
                    try EditorialRankingEvaluation.run(output: URL(fileURLWithPath: output))
                }
            #endif
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) ranking checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
#if EDITORIAL_STANDALONE
    @main struct RankingTestEntry { static func main() async { await EditorialRankingTests.run() } }
#endif
