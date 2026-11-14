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

private typealias Fixture = EditorialMomentumTests

/// Native port of the `EditorialMomentumTests` atom (#1070): its one control function as one test, with each local
/// `check` turned into `expectTrue` of NativeExpectations.swift (the runner log is invisible to Swift Testing), so a
/// failure is recorded instead of only counted. The non-asserting fixtures (`epoch`, `configuration`, `report`,
/// `replay`) stay in EditorialMomentumTests.swift. The two evaluation boundary checks run here as they do in the runner
/// (the `EDITORIAL_STANDALONE` build that leaves them out is a separate script target); the evaluation the runner
/// starts when `NEWS_MOMENTUM_INPUT` and `NEWS_MOMENTUM_OUTPUT` are set is a research mode
/// (`script/test_editorial_momentum.sh`) and is not ported. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EditorialMomentumSuite {
        @Test func replayControls() async throws {
            let empty = try Fixture.replay([])
            expectTrue(
                empty.points.count == 4 && empty.points.allSatisfy { $0.state == .quiet }, "zero bins stay quiet")
            let one = try Fixture.replay([Fixture.report("a")], seconds: 60)
            let p = one.points[0]
            let longAlpha = 1 - pow(0.5, 0.5)
            expectTrue(abs(p.shortEMA - 0.5) < 1e-12, "short EMA hand calculation")
            expectTrue(abs(p.longEMA - longAlpha) < 1e-12, "long EMA hand calculation")
            expectTrue(abs(p.macd - (0.5 - longAlpha)) < 1e-12, "MACD is short minus long")
            expectTrue(
                abs(p.signal - p.macd * 0.5) < 1e-12 && abs(p.histogram - p.macd * 0.5) < 1e-12,
                "signal and histogram hand calculation")
            expectTrue(p.state == .quiet, "one article cannot clear independent volume floor")
            let copies = (0..<20).map {
                Fixture.report("copy-\($0)", wire: "wire", origin: "wire-service", fetched: Double(20 + $0))
            }
            let syndicated = try Fixture.replay(copies)
            expectTrue(
                syndicated.rawRowsInWindow == 20 && syndicated.independentReportsInWindow == 1,
                "twenty syndicated rows count once")
            expectTrue(
                syndicated.points.allSatisfy { $0.state != .accelerating }, "syndication cannot trigger acceleration")
            let repeated = try Fixture.replay(Array(copies.reversed()) + copies)
            expectTrue(
                syndicated.points == repeated.points,
                "fetch order and repeated imports do not change publication signal")
            let independent = [Fixture.report("a", origin: "one"), Fixture.report("b", origin: "two", published: 20)]
            let burst = try Fixture.replay(independent)
            expectTrue(burst.points.contains { $0.state == .accelerating }, "independent volume can accelerate")
            let delayed = [
                Fixture.report("a", origin: "one", fetched: 200),
                Fixture.report("b", origin: "two", published: 20, fetched: 210),
            ]
            expectTrue(try Fixture.replay(delayed).points == burst.points, "backfills replay original publication time")
            let beforeFetch = try Fixture.replay(delayed, seconds: 120)
            expectTrue(
                beforeFetch.independentReportsInWindow == 0, "an earlier as-of snapshot excludes unavailable backfills")
            let oldWire = try Fixture.replay([
                Fixture.report("old", wire: "wire", published: -60, fetched: -50), Fixture.report("copy", wire: "wire"),
            ])
            expectTrue(oldWire.independentReportsInWindow == 0, "a new copy of a pre-window wire is not a new report")
            let unknown = try Fixture.replay([Fixture.report("unknown", origin: nil)])
            expectTrue(
                unknown.unknownMetadataRows == 1 && unknown.independentReportsInWindow == 0,
                "unknown provenance is explicit and does not inflate volume")
            let other = try Fixture.replay([Fixture.report("outside", event: "other")])
            expectTrue(other.independentReportsInWindow == 0, "events stay separate")
            do {
                _ = try Fixture.replay([
                    Fixture.report("a", wire: "wire", origin: "one"), Fixture.report("b", wire: "wire", origin: "two"),
                ])
                expectTrue(false, "conflicting wire origins must fail")
            } catch MomentumError.conflictingOrigin { expectTrue(true, "conflicting origin") }
            let future = try Fixture.replay([Fixture.report("future", published: 300, fetched: 310)])
            expectTrue(
                future.futurePublicationRows == 1 && future.futureFetchRows == 1
                    && future.independentReportsInWindow == 0, "future publication is unavailable, not present activity"
            )
            expectTrue(!burst.warmupComplete && burst.warmupSeconds == 600, "cold-start warmup remains explicit")
            expectTrue(
                burst.points.contains { $0.state == .decelerating },
                "negative histogram crossover remains distinct from acceleration volume floor")
            do {
                _ = try Fixture.replay([], seconds: -1)
                expectTrue(false, "reversed time must fail")
            } catch MomentumError.invalidTime { expectTrue(true, "invalid time") }
            let invalid = MomentumConfiguration(
                bucketSeconds: .nan, shortHalfLife: 60, longHalfLife: 120,
                signalHalfLife: 60, volumeWindow: 180, minimumIndependentReports: 2, minimumOriginPublishers: 2)
            do {
                _ = try Fixture.replay([], config: invalid)
                expectTrue(false, "nonfinite configuration must fail")
            } catch MomentumError.invalidConfiguration { expectTrue(true, "nonfinite configuration") }
            do {
                _ = try Fixture.replay([], seconds: 600_001)
                expectTrue(false, "bucket limit must fail")
            } catch MomentumError.inputLimit { expectTrue(true, "bucket bound") }
            do {
                _ = try Fixture.replay([Fixture.report("invalid", published: 30, fetched: 20)])
                expectTrue(false, "impossible report chronology must fail")
            } catch MomentumError.invalidTime { expectTrue(true, "report chronology") }
            let cancelled = Task {
                while !Task.isCancelled { await Task.yield() }
                return try Fixture.replay([])
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                expectTrue(false, "cancelled replay must stop")
            } catch is CancellationError { expectTrue(true, "cancellation") }
            let partial = try Fixture.replay([Fixture.report("a", published: 70, fetched: 75)], seconds: 90)
            expectTrue(
                partial.points.count == 2 && partial.points[1].bucketEnd == Fixture.epoch.addingTimeInterval(90),
                "partial final bucket ends at snapshot")
            let boundary = EditorialMomentumEvaluation.Case(
                eventID: "boundary", scenario: "quiet", split: "tune", windowStart: 60, through: 120,
                expectedBurst: false,
                reports: [
                    .init(
                        articleID: "before", wireGroupID: "wire",
                        localPublisherID: "local", originPublisherID: "origin", publishedAt: 10, fetchedAt: 20)
                ])
            let boundaryScore = try EditorialMomentumEvaluation.score(
                [boundary], configuration: Fixture.configuration(floor: 1, origins: 1))
            expectTrue(
                boundaryScore.fp == 0 && boundaryScore.tn == 1,
                "a bucket ending at the labelled start is outside the window")
            let unaligned = EditorialMomentumEvaluation.Case(
                eventID: "boundary", scenario: "quiet", split: "tune", windowStart: 61, through: 120,
                expectedBurst: false, reports: [])
            do {
                _ = try EditorialMomentumEvaluation.score([unaligned], configuration: Fixture.configuration())
                expectTrue(false, "unaligned evaluation windows must fail")
            } catch { expectTrue(true, "unaligned window rejected") }
        }
    }
}
