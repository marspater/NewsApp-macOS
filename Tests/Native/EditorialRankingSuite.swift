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
import Testing

private typealias Fixture = EditorialRankingTests
private typealias Evaluation = EditorialRankingEvaluation

/// Native port of the `EditorialRankingTests` atom (#1070): its control function and the lead-arm smoke check the
/// runner dispatches after it (`EditorialRankingEvaluation.leadArmsSmoke`) as two tests, in the runner's order, with
/// each local `check` turned into `expectTrue` of NativeExpectations.swift (the runner log is invisible to Swift
/// Testing), so a failure is recorded and later tests still run. The non-asserting fixtures (`now`, `vector`,
/// `candidate`, `config`, and the lead-arm fixture and arms of EditorialRankingEvaluation.swift) stay in the runner
/// files; the evaluation's `private` candidate builder is inlined. The evaluation and the lead-arm fixture report the
/// runner writes when `NEWS_RANKING_OUTPUT` is set are a research mode (`script/test_editorial_ranking.sh`) and are not
/// ported. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EditorialRankingSuite {
        @Test func rankingControls() async throws {
            let input = [Fixture.candidate("a", 1, 0), Fixture.candidate("b", 0.99, 0), Fixture.candidate("c", 0.8, 1)]
            let diverse = try EditorialRanking.rank(candidates: input, limit: 3, configuration: Fixture.config())
            expectTrue(
                diverse.map(\.id) == ["a", "c", "b"], "MMR selects the relevant distinct story before a near-duplicate")
            expectTrue(
                abs(diverse[1].penalty) < 1e-12 && abs(diverse[2].penalty - 1) < 1e-12, "known cosine penalties")
            let retained = try EditorialRanking.rank(
                candidates: [
                    Fixture.candidate("a", 1, 0), Fixture.candidate("b", 0.99, 0), Fixture.candidate("c", 0.8, 1),
                    Fixture.candidate("d", 0.7, 2),
                ],
                limit: 4, configuration: Fixture.config())
            expectTrue(
                retained.map(\.id) == ["a", "c", "d", "b"] && retained.last?.penalty == 1,
                "maximum penalty survives later orthogonal selections")
            let pure = try EditorialRanking.rank(candidates: input, limit: 3, configuration: Fixture.config(1))
            expectTrue(pure.map(\.id) == ["a", "b", "c"], "lambda one preserves base relevance")
            let old = [
                Fixture.candidate("a", 1, 0), Fixture.candidate("b", 0.99, 0, age: 86400),
                Fixture.candidate("c", 0.8, 1),
            ]
            let recap = try EditorialRanking.rank(candidates: old, limit: 3, configuration: Fixture.config())
            expectTrue(recap.map(\.id) == ["a", "b", "c"], "continuous temporal decay permits an older recap")
            let tie = try EditorialRanking.rank(
                candidates: [Fixture.candidate("b", 0.5, nil), Fixture.candidate("a", 0.5, nil)], limit: 2,
                configuration: Fixture.config())
            expectTrue(tie.map(\.id) == ["a", "b"], "stable IDs resolve ties without labels")
            let pref = [
                Fixture.candidate("a", 0.9, nil, preference: -1), Fixture.candidate("b", 0.5, nil, preference: 1),
            ]
            let neutral = try EditorialRanking.rank(candidates: pref, limit: 2, configuration: Fixture.config(1))
            expectTrue(neutral.first?.id == "a", "preference is neutral before integration")
            let personal = try EditorialRanking.rank(
                candidates: pref, limit: 2, configuration: Fixture.config(1, preference: 0.5))
            expectTrue(personal.first?.id == "b", "explicit preference integration changes only requested selection")
            let same = try EditorialRanking.meanSemanticDiversity([
                Fixture.candidate("a", 1, 0), Fixture.candidate("b", 1, 0),
            ])
            let distinct = try EditorialRanking.meanSemanticDiversity([
                Fixture.candidate("a", 1, 0), Fixture.candidate("b", 1, 1),
            ])
            expectTrue(same == 0 && distinct == 1, "pairwise semantic diversity matches hand examples")
            let missing = try EditorialRanking.meanSemanticDiversity([Fixture.candidate("a", 1, nil)])
            expectTrue(missing == nil, "unknown diversity is not fabricated")
            expectTrue(
                try EditorialRanking.rank(candidates: [], limit: 0, configuration: Fixture.config()).isEmpty,
                "empty selection")
            do {
                _ = try EditorialRanking.rank(
                    candidates: [Fixture.candidate("same", 1, 0), Fixture.candidate("same", 0.5, 1)], limit: 2,
                    configuration: Fixture.config())
                expectTrue(false, "duplicate IDs must fail")
            } catch EditorialRankingError.invalidCandidate { expectTrue(true, "duplicate IDs") }
            let invalid = EditorialRankingCandidate(
                id: "bad", relevance: 1, date: Fixture.now, vector: [1, 0], embeddingModelVersion: "test-v1",
                preference: nil)
            do {
                _ = try EditorialRanking.rank(candidates: [invalid], limit: 1, configuration: Fixture.config())
                expectTrue(false, "bad vector must fail")
            } catch EditorialRankingError.invalidCandidate { expectTrue(true, "bad dimensions") }
            do {
                _ = try EditorialRanking.rank(candidates: input, limit: 51, configuration: Fixture.config())
                expectTrue(false, "selection bound must fail")
            } catch EditorialRankingError.inputLimit { expectTrue(true, "selection bound") }
            do {
                _ = try EditorialRanking.rank(candidates: input, limit: 1, configuration: Fixture.config(tau: 0))
                expectTrue(false, "invalid decay must fail")
            } catch EditorialRankingError.invalidConfiguration { expectTrue(true, "decay validation") }
            let mixed = EditorialRankingCandidate(
                id: "mixed", relevance: 1, date: Fixture.now, vector: Fixture.vector(0),
                embeddingModelVersion: "other-model", preference: nil)
            do {
                _ = try EditorialRanking.rank(candidates: [mixed], limit: 1, configuration: Fixture.config())
                expectTrue(false, "mixed model must fail")
            } catch EditorialRankingError.invalidCandidate { expectTrue(true, "model provenance") }
            let large = (0..<500).map {
                Fixture.candidate(String(format: "%04d", $0), Double(500 - $0) / 500, $0 % 384)
            }
            let selected = try EditorialRanking.rank(candidates: large, limit: 10, configuration: Fixture.config())
            expectTrue(
                selected.count == 10 && Set(selected.map(\.id)).count == 10,
                "500-vector selection returns unique formed stories")
            let cancelled = Task {
                while !Task.isCancelled { await Task.yield() }
                return try EditorialRanking.rank(candidates: input, limit: 1, configuration: Fixture.config())
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                expectTrue(false, "cancellation must stop ranking")
            } catch is CancellationError { expectTrue(true, "cancellation") }
        }

        @Test func leadArmsSmoke() throws {
            let stories = Evaluation.leadArmFixture()
            // The Lead as the shipped rules would show it here: affinity breaks two ties, and a fifth slide
            // that misses its bar leaves four.
            let shown = ["s02", "s03", "s05", "s04"]
            let arms = try Evaluation.leadArms(
                stories: stories, currentShown: shown, settings: Evaluation.LeadArmSettings())
            let report = arms.report
            let baseOrder = arms.orders["base"] ?? []
            expectTrue(
                Set(arms.orders.keys) == Set(Evaluation.leadArmNames) && arms.orders["current"] == shown,
                "three named arms")
            expectTrue(
                report.candidates == 30 && report.eligible == 28 && !baseOrder.contains("s00")
                    && arms.orders["base+mmr"]?.contains("s01") == false,
                "the photo rule takes the same stories out of both experimental arms")
            expectTrue(
                Array(baseOrder.prefix(5)) == ["s03", "s02", "s05", "s04", "s07"],
                "base orders by score, original reports and date, not by affinity or id")
            let base = baseOrder.compactMap { id in stories.first { $0.id == id } }
            let relevance = Evaluation.baseRelevance(base)
            expectTrue(
                zip(relevance, relevance.dropFirst()).allSatisfy { $0 > $1 }
                    && zip(relevance, base).allSatisfy { abs($0 - $1.score) < 1e-9 },
                "relevance is the score, strictly falling along base")
            // EditorialRankingEvaluation.candidate(_:relevance:model:) is private; the same candidate, built here.
            let pure = try EditorialRanking.rank(
                candidates: zip(base, relevance).map { story, relevance in
                    EditorialRankingCandidate(
                        id: story.id, relevance: relevance, date: story.date, vector: story.vector,
                        embeddingModelVersion: story.vector == nil ? nil : "fixture", preference: nil)
                }, limit: 20,
                configuration: EditorialRankingConfiguration(
                    relevanceWeight: 1, temporalDecaySeconds: 21_600, embeddingModelVersion: "fixture")
            ).map(\.id)
            expectTrue(Array(baseOrder.prefix(20)) == pure, "base is EditorialRanking at relevance weight 1")
            let mmrOrder = arms.orders["base+mmr"] ?? []
            expectTrue(
                mmrOrder.count == 20 && mmrOrder.first == "s03" && Set(mmrOrder).isSubset(of: Set(baseOrder))
                    && mmrOrder != pure,
                "MMR reorders the same eligible stories")
            let (current, baseArm, mmr) = (report.arms["current"], report.arms["base"], report.arms["base+mmr"])
            expectTrue(current?.shown == 4 && baseArm?.shown == 5 && mmr?.shown == 5, "shown counts")
            expectTrue(
                report.currentFollowsShippedOrder && !report.currentAndBaseCoincide && baseArm?.overlapCurrent == 4
                    && current?.overlapBase == 4,
                "current against base at the display depth")
            let correlation = baseArm?.rankCorrelationCurrent ?? 1
            expectTrue(
                correlation > 0.99 && correlation < 1 && current?.rankCorrelationCurrent == nil
                    && mmr?.rankCorrelationCurrent == nil,
                "affinity moves two neighbours in the shipped order")
            expectTrue(abs((baseArm?.diversity ?? 0) - 0.6) < 1e-9, "base diversity: four of ten pairs share a topic")
            expectTrue(
                (mmr?.diversity ?? 0) > (baseArm?.diversity ?? 1) && (mmr?.overlapBase ?? 5) < 5
                    && baseArm?.overlapBase == 5,
                "MMR shows a more varied top than base")
            expectTrue(
                baseArm?.eventsShown == 3 && baseArm?.publishersShown == 3 && baseArm?.vectorsShown == 5, "counts")
            expectTrue(report.storiesWithVector == 26, "vectors in the eligible pool")
            expectTrue(
                baseArm?.selectionMs != nil && mmr?.selectionMs != nil && current?.selectionMs == nil, "timing")
            let ranks = Evaluation.leadArmRanks(arms.orders, depth: 20)
            expectTrue(
                ["base", "base+mmr"].allSatisfy { arm in ranks.values.filter { $0[arm] != nil }.count == 20 }
                    && ranks.values.filter { $0["current"] != nil }.count == 4 && ranks["s03"]?["base"] == 1
                    && ranks["s02"]?["current"] == 1,
                "the key holds current's slides and 20 places of each experimental arm")

            let neutral = stories.map {
                Evaluation.LeadArmStory(
                    id: $0.id, score: $0.score, originalReports: $0.originalReports, affinity: 0, date: $0.date,
                    hasPhoto: $0.hasPhoto, vector: $0.vector, event: $0.event, publisher: $0.publisher)
            }
            let control = try Evaluation.leadArms(
                stories: neutral, currentShown: Array(baseOrder.prefix(5)), settings: Evaluation.LeadArmSettings())
            expectTrue(
                control.report.currentAndBaseCoincide && control.report.arms["base"]?.rankCorrelationCurrent == 1
                    && control.report.arms["base"]?.overlapCurrent == 5 && control.orders["base+mmr"] == mmrOrder,
                "current and base coinciding is reported as a control")
            let dark = try Evaluation.leadArms(
                stories: stories.map {
                    Evaluation.LeadArmStory(
                        id: $0.id, score: $0.score, originalReports: $0.originalReports, affinity: 0, date: $0.date,
                        hasPhoto: false, vector: $0.vector, event: $0.event, publisher: $0.publisher)
                }, currentShown: ["s01"], settings: Evaluation.LeadArmSettings())
            expectTrue(
                dark.report.displayDepth == 1 && dark.report.eligible == 30 && dark.report.currentAndBaseCoincide
                    && dark.report.arms["base+mmr"]?.shown == 1,
                "no photo anywhere: one story, as the Lead shows")
            let swapped = try Evaluation.leadArms(
                stories: stories, currentShown: ["s03", "s02"], settings: Evaluation.LeadArmSettings())
            expectTrue(!swapped.report.currentFollowsShippedOrder, "slides out of the shipped precedence are flagged")
        }
    }
}
