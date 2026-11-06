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

struct MomentumReport: Sendable {
    let articleID: String
    let eventID: String
    let wireGroupID: String?
    let localPublisherID: String
    let originPublisherID: String?
    let publishedAt: Date
    let fetchedAt: Date
}

struct MomentumConfiguration: Sendable {
    let bucketSeconds: TimeInterval
    let shortHalfLife: TimeInterval
    let longHalfLife: TimeInterval
    let signalHalfLife: TimeInterval
    let volumeWindow: TimeInterval
    let minimumIndependentReports: Int
    let minimumOriginPublishers: Int
}

enum MomentumState: String, Sendable { case quiet, accelerating, decelerating }

struct MomentumPoint: Sendable, Equatable {
    let bucketEnd: Date
    let independentCount: Int
    let originCount: Int
    let shortEMA: Double
    let longEMA: Double
    let macd: Double
    let signal: Double
    let histogram: Double
    let state: MomentumState
}

struct MomentumSummary: Sendable {
    let points: [MomentumPoint]
    var latestPoint: MomentumPoint? { points.last }
    let warmupSeconds: TimeInterval
    let warmupComplete: Bool
    let rawRowsInWindow: Int
    let independentReportsInWindow: Int
    let independentOriginsInWindow: Int
    let unknownMetadataRows: Int
    let futurePublicationRows: Int
    let futureFetchRows: Int
    let delayedFetchRows: Int
}

enum MomentumError: Error { case invalidConfiguration, invalidTime, inputLimit, conflictingOrigin }

/// Experimental retrospective replay, using all reports available as of `through` and bucketing by publication time.
/// Earlier points can include reports fetched after their bucket ended: never use them as historical as-of predictions.
/// EMAs start at zero at `windowStart`; warmup is informational and does not gate states. The volume and origin
/// floors gate acceleration only; deceleration remains a strictly positive-to-negative histogram crossover.
enum EditorialMomentum {
    private struct IndependentReport {
        let wire: String
        let origin: String
        let publication: Date
    }

    static func replay(
        reports: [MomentumReport], eventID: String, windowStart: Date, through: Date,
        configuration: MomentumConfiguration
    ) throws -> MomentumSummary {
        try validate(configuration, windowStart: windowStart, through: through, count: reports.count)
        let relevant = reports.filter { $0.eventID == eventID }
        let timeline = try independentTimeline(relevant, through: through)
        let duration = through.timeIntervalSince(windowStart)
        let bucketCount = max(1, Int(ceil(duration / configuration.bucketSeconds)))
        guard bucketCount <= 10_000 else { throw MomentumError.inputLimit }
        var points: [MomentumPoint] = []
        var short = 0.0
        var long = 0.0
        var signal = 0.0
        var previousHistogram = 0.0
        var arrivalEnd = timeline.firstIndex { $0.publication >= windowStart } ?? timeline.count
        var recentStartIndex = arrivalEnd
        var recentOrigins: [String: Int] = [:]
        for bucket in 0..<bucketCount {
            try Task.checkCancellation()
            let start = windowStart.addingTimeInterval(Double(bucket) * configuration.bucketSeconds)
            let end = min(through, start.addingTimeInterval(configuration.bucketSeconds))
            let last = bucket == bucketCount - 1
            let arrivalStart = arrivalEnd
            while arrivalEnd < timeline.count
                && (timeline[arrivalEnd].publication < end
                    || (last && timeline[arrivalEnd].publication == end))
            {
                recentOrigins[timeline[arrivalEnd].origin, default: 0] += 1
                arrivalEnd += 1
            }
            let elapsed = end.timeIntervalSince(start)
            // Reports per configured nominal bucket; a partial final bucket is scaled to the same unit.
            let rate =
                elapsed > 0 ? Double(arrivalEnd - arrivalStart) / elapsed * configuration.bucketSeconds : 0
            guard rate.isFinite else { throw MomentumError.invalidConfiguration }
            short += alpha(elapsed, configuration.shortHalfLife) * (rate - short)
            long += alpha(elapsed, configuration.longHalfLife) * (rate - long)
            let macd = short - long
            signal += alpha(elapsed, configuration.signalHalfLife) * (macd - signal)
            let histogram = macd - signal
            let recentStart = max(windowStart, end.addingTimeInterval(-configuration.volumeWindow))
            while recentStartIndex < arrivalEnd && timeline[recentStartIndex].publication < recentStart {
                let origin = timeline[recentStartIndex].origin
                recentOrigins[origin, default: 0] -= 1
                if recentOrigins[origin] == 0 { recentOrigins.removeValue(forKey: origin) }
                recentStartIndex += 1
            }
            let recentCount = arrivalEnd - recentStartIndex
            let origins = recentOrigins.count
            let floorMet =
                recentCount >= configuration.minimumIndependentReports
                && origins >= configuration.minimumOriginPublishers
            // Equality is neutral: deceleration requires a strictly positive-to-negative adjacent crossover.
            let state: MomentumState =
                previousHistogram > 0 && histogram < 0
                ? .decelerating : (histogram > 0 && floorMet ? .accelerating : .quiet)
            points.append(
                .init(
                    bucketEnd: end, independentCount: recentCount, originCount: origins,
                    shortEMA: short, longEMA: long, macd: macd, signal: signal, histogram: histogram,
                    state: state))
            previousHistogram = histogram
        }
        let windowRows = relevant.filter {
            $0.publishedAt >= windowStart && $0.publishedAt <= through && $0.fetchedAt <= through
        }
        let windowReports = timeline.filter {
            $0.publication >= windowStart && $0.publication <= through
        }
        let warmup = max(configuration.longHalfLife, configuration.signalHalfLife) * 5
        return .init(
            points: points, warmupSeconds: warmup, warmupComplete: duration >= warmup,
            rawRowsInWindow: windowRows.count, independentReportsInWindow: windowReports.count,
            independentOriginsInWindow: Set(windowReports.map(\.origin)).count,
            unknownMetadataRows: windowRows.filter {
                known($0.wireGroupID) == nil || known($0.originPublisherID) == nil
            }.count,
            futurePublicationRows: relevant.filter { $0.publishedAt > through }.count,
            futureFetchRows: relevant.filter { $0.fetchedAt > through }.count,
            delayedFetchRows: windowRows.filter {
                $0.fetchedAt.timeIntervalSince($0.publishedAt) > configuration.bucketSeconds
            }.count)
    }

    private static func validate(
        _ configuration: MomentumConfiguration, windowStart: Date, through: Date, count: Int
    ) throws {
        let intervals = [
            configuration.bucketSeconds, configuration.shortHalfLife, configuration.longHalfLife,
            configuration.signalHalfLife, configuration.volumeWindow,
        ]
        guard intervals.allSatisfy({ $0.isFinite && $0 > 0 }),
            configuration.shortHalfLife < configuration.longHalfLife,
            configuration.minimumIndependentReports > 0, configuration.minimumOriginPublishers > 0,
            max(configuration.longHalfLife, configuration.signalHalfLife) <= Double
                .greatestFiniteMagnitude / 5
        else {
            throw MomentumError.invalidConfiguration
        }
        guard windowStart.timeIntervalSince1970.isFinite, through.timeIntervalSince1970.isFinite,
            through > windowStart
        else { throw MomentumError.invalidTime }
        guard count <= 50_000,
            through.timeIntervalSince(windowStart) / configuration.bucketSeconds <= 10_000
        else {
            throw MomentumError.inputLimit
        }
    }

    private static func known(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func independentTimeline(_ reports: [MomentumReport], through: Date) throws
        -> [IndependentReport]
    {
        var byWire: [String: IndependentReport] = [:]
        for report in reports {
            guard report.publishedAt.timeIntervalSince1970.isFinite,
                report.fetchedAt.timeIntervalSince1970.isFinite,
                report.publishedAt <= report.fetchedAt
            else { throw MomentumError.invalidTime }
            guard report.publishedAt <= through, report.fetchedAt <= through,
                let wire = known(report.wireGroupID), let origin = known(report.originPublisherID)
            else { continue }
            if let prior = byWire[wire], prior.origin != origin { throw MomentumError.conflictingOrigin }
            if byWire[wire] == nil || report.publishedAt < byWire[wire]!.publication {
                byWire[wire] = .init(wire: wire, origin: origin, publication: report.publishedAt)
            }
        }
        return byWire.values.sorted {
            if $0.publication != $1.publication { return $0.publication < $1.publication }
            return $0.wire < $1.wire
        }
    }

    private static func alpha(_ seconds: Double, _ halfLife: Double) -> Double {
        -expm1(-log(2) * seconds / halfLife)
    }
}
