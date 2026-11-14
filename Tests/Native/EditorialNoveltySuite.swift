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

private typealias Fixture = EditorialNoveltyTests

/// Native port of the `EditorialNoveltyTests` atom (#1070): its five control functions as five tests, in the runner's
/// order, with each local `check` turned into `expectTrue` of NativeExpectations.swift (the runner log is invisible to
/// Swift Testing), so a failure is recorded and later tests still run. The non-asserting fixtures (`stamp`, `passage`,
/// `engine`, `OutcomeCounts`, `NoveltyTestEmbeddings`) stay in EditorialNoveltyTests.swift. The corpus evaluation the
/// runner starts when `NEWS_EDITORIAL_CORPUS` and `NEWS_EDITORIAL_OUTPUT` are set is a research mode
/// (`script/test_editorial_novelty.sh`) and is not ported. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EditorialNoveltySuite {
        @Test func routeMismatchReporting() {
            var counts = Fixture.OutcomeCounts()
            counts.recordRoute(.noAnchoredSentence, expected: "fallback", id: "mismatch")
            counts.recordRoute(.repetition, expected: "repetition", id: "match")
            expectTrue(counts.routeMismatchIDs == ["mismatch"], "route mismatches retain the case ID")
            expectTrue(
                counts.predictedRoutes["unanchored"] == 1 && counts.predictedRoutes["repetition"] == 1,
                "predicted routes are counted separately")
        }

        @Test func routesAndCitations() async throws {
            let provider = NoveltyTestEmbeddings()
            let subject = Fixture.engine(provider)
            let baseline = [Fixture.passage("baseline", Fixture.oldText)]
            let candidate = Fixture.passage("incoming", Fixture.oldText + " " + Fixture.newText, observed: 20)
            let result = try await subject.analyze(
                candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            if case .novel(let selection) = result {
                expectTrue(selection.sentence == Fixture.newText, "select the farthest anchored sentence verbatim")
                expectTrue(
                    selection.citation.articleID == candidate.passage.articleID, "citation retains incoming article")
                expectTrue(selection.citation.passageID == candidate.passage.id, "citation retains incoming passage")
                expectTrue(selection.citation.quote == Fixture.newText, "citation quote is the exact source sentence")
                expectTrue(selection.stamp.inputHash == Fixture.stamp.inputHash, "return the input stamp")
                expectTrue(
                    selection.stamp.membershipHash == Fixture.stamp.membershipHash, "return the membership stamp")
            } else {
                expectTrue(false, "a new anchored fact must remain a candidate")
            }
            let repeated = try await subject.analyze(
                candidate: Fixture.passage("repeat", Fixture.oldText, observed: 20), baseline: baseline,
                coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            if case .repetition = repeated {
                expectTrue(true, "repetition")
            } else {
                expectTrue(false, "identical evidence is repetition")
            }
            let unanchored = try await subject.analyze(
                candidate: Fixture.passage(
                    "boilerplate", "The company closed the eastern line after a cable fault.", observed: 20),
                baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            if case .noAnchoredSentence = unanchored {
                expectTrue(true, "unanchored")
            } else {
                expectTrue(false, "reject sentences without a core actor")
            }
            let shortEntityText = "US officials report new updates."
            let shortEntityRepeat = try await subject.analyze(
                candidate: Fixture.passage("short-repeat", shortEntityText, observed: 20),
                baseline: [Fixture.passage("short-baseline", shortEntityText)], coreEntities: ["US"],
                stamp: Fixture.stamp)
            if case .repetition = shortEntityRepeat {
                expectTrue(true, "short entity repetition")
            } else {
                expectTrue(false, "a short core entity reaches the retrieval query, so its repeat is repetition")
            }
            let stopwordEntityMiss = try await subject.analyze(
                candidate: Fixture.passage("phrase-miss", "The Fed met.", observed: 20),
                baseline: [Fixture.passage("phrase-baseline", "The satellites orbit.")], coreEntities: ["The Fed"],
                stamp: Fixture.stamp)
            if case .lowPrioritySemanticFallback = stopwordEntityMiss {
                expectTrue(true, "entity phrase lexical miss")
            } else {
                expectTrue(false, "an entity's stopword alone is not a lexical match")
            }
        }

        @Test func historicalBoundaries() async throws {
            let provider = NoveltyTestEmbeddings()
            let subject = Fixture.engine(provider)
            let candidate = Fixture.passage("incoming", Fixture.oldText, observed: 20)
            for baseline in [
                [Fixture.passage("future", Fixture.oldText, observed: 30)],
                [Fixture.passage("other", Fixture.oldText, event: "other")],
                [candidate],
                [Fixture.passage("unrelated", "Copper satellites orbit distant planets.")],
                [
                    EditorialPassage(
                        eventID: "event",
                        passage: EvidencePassage(id: "impossible", articleID: "impossible", text: Fixture.oldText),
                        publishedAt: Date(timeIntervalSince1970: 15), observedAt: Date(timeIntervalSince1970: 10))
                ],
            ] {
                let result = try await subject.analyze(
                    candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
                if case .lowPrioritySemanticFallback = result {
                    expectTrue(true, "historical lexical miss")
                } else {
                    expectTrue(false, "unavailable, unrelated and self evidence cannot enter the baseline")
                }
            }
            let count = await provider.count
            expectTrue(count == 0, "lexical misses do not start the embedder")
        }

        @Test func cacheAndEnergy() async throws {
            let provider = NoveltyTestEmbeddings()
            let subject = Fixture.engine(provider)
            let baseline = [Fixture.passage("baseline", Fixture.oldText)]
            let candidate = Fixture.passage("incoming", Fixture.oldText + " " + Fixture.newText, observed: 20)
            _ = try await subject.analyze(
                candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            let cold = await provider.count
            _ = try await subject.analyze(
                candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            let warm = await provider.count
            expectTrue(cold > 0 && warm == cold, "warm requests reuse text/model vectors")
            await subject.clearCache()
            _ = try await subject.analyze(
                candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            let refreshed = await provider.count
            expectTrue(refreshed > warm, "clear invalidates cached vectors")
            let pausedProvider = NoveltyTestEmbeddings()
            let paused = Fixture.engine(pausedProvider, energy: false)
            let result = try await paused.analyze(
                candidate: candidate, baseline: baseline, coreEntities: ["Aster Transit"], stamp: Fixture.stamp)
            if case .deferred = result {
                expectTrue(true, "energy deferral")
            } else {
                expectTrue(false, "energy policy defers semantic work")
            }
            let pausedCount = await pausedProvider.count
            expectTrue(pausedCount == 0, "energy deferral makes no model call")
        }

        @Test func clearWhileEmbedding() async throws {
            let provider = NoveltyTestEmbeddings(paused: true)
            let subject = Fixture.engine(provider)
            let task = Task {
                try await subject.analyze(
                    candidate: Fixture.passage("incoming", Fixture.oldText + " " + Fixture.newText, observed: 20),
                    baseline: [Fixture.passage("baseline", Fixture.oldText)], coreEntities: ["Aster Transit"],
                    stamp: Fixture.stamp)
            }
            defer { task.cancel() }
            await provider.waitUntilEntered()
            let concurrent = try await subject.analyze(
                candidate: Fixture.passage("parallel", Fixture.oldText + " " + Fixture.newText, observed: 20),
                baseline: [Fixture.passage("baseline", Fixture.oldText)], coreEntities: ["Aster Transit"],
                stamp: Fixture.stamp)
            if case .deferred = concurrent {
                expectTrue(true, "concurrent semantic work is deferred")
            } else {
                expectTrue(false, "one suspended analysis owns semantic work")
            }
            let inFlightCount = await provider.count
            expectTrue(inFlightCount == 2, "concurrent requests do not recompute the same vectors")
            await subject.clearCache()
            await provider.resume()
            do {
                let result = try await task.value
                if case .deferred = result {
                    expectTrue(true, "stale generation deferred")
                } else {
                    expectTrue(false, "a cleared generation cannot publish a result")
                }
            } catch is CancellationError { expectTrue(true, "stale generation rejected") }
            let stats = await subject.stats()
            expectTrue(stats.entries == 0, "an old embedding task cannot repopulate the cleared cache")
        }
    }
}
