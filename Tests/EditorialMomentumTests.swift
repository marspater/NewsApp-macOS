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

/// Mathematical and historical controls for publication-time event momentum.
enum EditorialMomentumTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static let epoch = Date(timeIntervalSince1970: 1_793_491_200)

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ Momentum: \(message)")
        }
    }

    static func configuration(floor: Int = 2, origins: Int = 2) -> MomentumConfiguration {
        MomentumConfiguration(
            bucketSeconds: 60, shortHalfLife: 60, longHalfLife: 120,
            signalHalfLife: 60, volumeWindow: 180, minimumIndependentReports: floor, minimumOriginPublishers: origins)
    }

    static func report(
        _ id: String, wire: String? = nil, origin: String? = "origin", published: Double = 10,
        fetched: Double = 20, event: String = "event"
    ) -> MomentumReport {
        MomentumReport(
            articleID: id, eventID: event, wireGroupID: wire ?? id, localPublisherID: "local-" + id,
            originPublisherID: origin, publishedAt: epoch.addingTimeInterval(published),
            fetchedAt: epoch.addingTimeInterval(fetched))
    }

    static func replay(_ reports: [MomentumReport], seconds: Double = 240, config: MomentumConfiguration? = nil) throws
        -> MomentumSummary
    {
        try EditorialMomentum.replay(
            reports: reports, eventID: "event", windowStart: epoch,
            through: epoch.addingTimeInterval(seconds), configuration: config ?? configuration())
    }

    static func run() async {
        do {
            let empty = try replay([])
            check(empty.points.count == 4 && empty.points.allSatisfy { $0.state == .quiet }, "zero bins stay quiet")
            let one = try replay([report("a")], seconds: 60)
            let p = one.points[0]
            let longAlpha = 1 - pow(0.5, 0.5)
            check(abs(p.shortEMA - 0.5) < 1e-12, "short EMA hand calculation")
            check(abs(p.longEMA - longAlpha) < 1e-12, "long EMA hand calculation")
            check(abs(p.macd - (0.5 - longAlpha)) < 1e-12, "MACD is short minus long")
            check(
                abs(p.signal - p.macd * 0.5) < 1e-12 && abs(p.histogram - p.macd * 0.5) < 1e-12,
                "signal and histogram hand calculation")
            check(p.state == .quiet, "one article cannot clear independent volume floor")
            let copies = (0..<20).map {
                report("copy-\($0)", wire: "wire", origin: "wire-service", fetched: Double(20 + $0))
            }
            let syndicated = try replay(copies)
            check(
                syndicated.rawRowsInWindow == 20 && syndicated.independentReportsInWindow == 1,
                "twenty syndicated rows count once")
            check(syndicated.points.allSatisfy { $0.state != .accelerating }, "syndication cannot trigger acceleration")
            let repeated = try replay(Array(copies.reversed()) + copies)
            check(
                syndicated.points == repeated.points,
                "fetch order and repeated imports do not change publication signal")
            let independent = [report("a", origin: "one"), report("b", origin: "two", published: 20)]
            let burst = try replay(independent)
            check(burst.points.contains { $0.state == .accelerating }, "independent volume can accelerate")
            let delayed = [
                report("a", origin: "one", fetched: 200), report("b", origin: "two", published: 20, fetched: 210),
            ]
            check(try replay(delayed).points == burst.points, "backfills replay original publication time")
            let beforeFetch = try replay(delayed, seconds: 120)
            check(
                beforeFetch.independentReportsInWindow == 0, "an earlier as-of snapshot excludes unavailable backfills")
            let oldWire = try replay([
                report("old", wire: "wire", published: -60, fetched: -50), report("copy", wire: "wire"),
            ])
            check(oldWire.independentReportsInWindow == 0, "a new copy of a pre-window wire is not a new report")
            let unknown = try replay([report("unknown", origin: nil)])
            check(
                unknown.unknownMetadataRows == 1 && unknown.independentReportsInWindow == 0,
                "unknown provenance is explicit and does not inflate volume")
            let other = try replay([report("outside", event: "other")])
            check(other.independentReportsInWindow == 0, "events stay separate")
            do {
                _ = try replay([report("a", wire: "wire", origin: "one"), report("b", wire: "wire", origin: "two")])
                check(false, "conflicting wire origins must fail")
            } catch MomentumError.conflictingOrigin { check(true, "conflicting origin") }
            let future = try replay([report("future", published: 300, fetched: 310)])
            check(
                future.futurePublicationRows == 1 && future.futureFetchRows == 1
                    && future.independentReportsInWindow == 0, "future publication is unavailable, not present activity"
            )
            check(!burst.warmupComplete && burst.warmupSeconds == 600, "cold-start warmup remains explicit")
            check(
                burst.points.contains { $0.state == .decelerating },
                "negative histogram crossover remains distinct from acceleration volume floor")
            do {
                _ = try replay([], seconds: -1)
                check(false, "reversed time must fail")
            } catch MomentumError.invalidTime { check(true, "invalid time") }
            let invalid = MomentumConfiguration(
                bucketSeconds: .nan, shortHalfLife: 60, longHalfLife: 120,
                signalHalfLife: 60, volumeWindow: 180, minimumIndependentReports: 2, minimumOriginPublishers: 2)
            do {
                _ = try replay([], config: invalid)
                check(false, "nonfinite configuration must fail")
            } catch MomentumError.invalidConfiguration { check(true, "nonfinite configuration") }
            do {
                _ = try replay([], seconds: 600_001)
                check(false, "bucket limit must fail")
            } catch MomentumError.inputLimit { check(true, "bucket bound") }
            do {
                _ = try replay([report("invalid", published: 30, fetched: 20)])
                check(false, "impossible report chronology must fail")
            } catch MomentumError.invalidTime { check(true, "report chronology") }
            let cancelled = Task {
                while !Task.isCancelled { await Task.yield() }
                return try replay([])
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                check(false, "cancelled replay must stop")
            } catch is CancellationError { check(true, "cancellation") }
            let partial = try replay([report("a", published: 70, fetched: 75)], seconds: 90)
            check(
                partial.points.count == 2 && partial.points[1].bucketEnd == epoch.addingTimeInterval(90),
                "partial final bucket ends at snapshot")
            #if !EDITORIAL_STANDALONE
                let boundary = EditorialMomentumEvaluation.Case(
                    eventID: "boundary", scenario: "quiet", split: "tune", windowStart: 60, through: 120,
                    expectedBurst: false,
                    reports: [
                        .init(
                            articleID: "before", wireGroupID: "wire",
                            localPublisherID: "local", originPublisherID: "origin", publishedAt: 10, fetchedAt: 20)
                    ])
                let boundaryScore = try EditorialMomentumEvaluation.score(
                    [boundary], configuration: configuration(floor: 1, origins: 1))
                check(
                    boundaryScore.fp == 0 && boundaryScore.tn == 1,
                    "a bucket ending at the labelled start is outside the window")
                let unaligned = EditorialMomentumEvaluation.Case(
                    eventID: "boundary", scenario: "quiet", split: "tune", windowStart: 61, through: 120,
                    expectedBurst: false, reports: [])
                do {
                    _ = try EditorialMomentumEvaluation.score([unaligned], configuration: configuration())
                    check(false, "unaligned evaluation windows must fail")
                } catch { check(true, "unaligned window rejected") }
                if let input = ProcessInfo.processInfo.environment["NEWS_MOMENTUM_INPUT"],
                    let output = ProcessInfo.processInfo.environment["NEWS_MOMENTUM_OUTPUT"]
                {
                    try await EditorialMomentumEvaluation.run(
                        input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output))
                }
            #endif
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) momentum checks with \(failures) failures.")
        if failures > 0 { recordFailure("EditorialMomentumTests: \(failures) check failure(s)") }
    }
}

#if EDITORIAL_STANDALONE
    @main struct MomentumTestEntry { static func main() async { await EditorialMomentumTests.run() } }
#endif
