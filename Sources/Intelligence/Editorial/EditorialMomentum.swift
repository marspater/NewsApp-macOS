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

// Angelia · Kairos (novelty and momentum) owns this file. Experimental, no production consumer.
// Register: docs/ANGELIA.md.

import Foundation

/// One stored article as the momentum replay reads it.
struct MomentumReport: Sendable {
    let articleID: String
    let eventID: String
    /// The report the article copies or is; articles sharing it count as one independent report. Nil or blank leaves
    /// the article out.
    let wireGroupID: String?
    /// The outlet that carried the article.
    let localPublisherID: String
    /// Who originated the report; one wire group must have one origin. Nil or blank leaves the article out.
    let originPublisherID: String?
    let publishedAt: Date
    /// When News first stored the article; never before `publishedAt`.
    let fetchedAt: Date
}

/// Bucket size, half-lives and floors for `EditorialMomentum.replay`; every interval is in seconds.
struct MomentumConfiguration: Sendable {
    /// The width of one replay bucket and the unit of the report rate.
    let bucketSeconds: TimeInterval
    /// Half-life of the fast moving average; must be shorter than `longHalfLife`.
    let shortHalfLife: TimeInterval
    /// Half-life of the slow moving average.
    let longHalfLife: TimeInterval
    /// Half-life of the signal line, a moving average of the MACD.
    let signalHalfLife: TimeInterval
    /// The trailing window whose independent reports and origins the floors count.
    let volumeWindow: TimeInterval
    /// Independent reports the volume window needs before a bucket can be accelerating.
    let minimumIndependentReports: Int
    /// Distinct origins the volume window needs before a bucket can be accelerating.
    let minimumOriginPublishers: Int
}

/// A bucket's momentum: accelerating needs a positive histogram and both floors; decelerating is a positive-to-negative
/// histogram crossover.
enum MomentumState: String, Sendable { case quiet, accelerating, decelerating }

/// The moving averages and state at the end of one bucket.
struct MomentumPoint: Sendable, Equatable {
    let bucketEnd: Date
    /// Independent reports in the trailing volume window.
    let independentCount: Int
    /// Distinct origins in the trailing volume window.
    let originCount: Int
    let shortEMA: Double
    let longEMA: Double
    /// `shortEMA` minus `longEMA`.
    let macd: Double
    let signal: Double
    /// `macd` minus `signal`.
    let histogram: Double
    let state: MomentumState
}

/// A replay's points and the data-quality counts behind them.
struct MomentumSummary: Sendable {
    let points: [MomentumPoint]
    var latestPoint: MomentumPoint? { points.last }
    /// Five times the longer of the long and signal half-lives; informational only.
    let warmupSeconds: TimeInterval
    /// Whether the window is at least `warmupSeconds` long.
    let warmupComplete: Bool
    /// The event's rows published and fetched inside the window.
    let rawRowsInWindow: Int
    let independentReportsInWindow: Int
    let independentOriginsInWindow: Int
    /// Rows in the window without a wire group or origin, which the replay leaves out.
    let unknownMetadataRows: Int
    /// Rows published after `through`.
    let futurePublicationRows: Int
    /// Rows fetched after `through`.
    let futureFetchRows: Int
    /// Rows in the window fetched more than one bucket after publication.
    let delayedFetchRows: Int
}

/// Why `EditorialMomentum.replay` refused its input: a bad configuration, a non-finite or out-of-order time, more than
/// 50,000 reports or 10,000 buckets, or one wire group with two origins.
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

    /// The timeline reports arrived so far and those still inside the trailing volume window.
    private struct ArrivalWindow {
        let timeline: [IndependentReport]
        var arrivalEnd: Int
        var recentStart: Int
        var recentOrigins: [String: Int] = [:]

        var recentCount: Int { arrivalEnd - recentStart }

        /// Admits reports published before `end`, or also at `end` when `inclusive`; returns how many arrived.
        mutating func admit(until end: Date, inclusive: Bool) -> Int {
            let first = arrivalEnd
            while arrivalEnd < timeline.count
                && (timeline[arrivalEnd].publication < end
                    || (inclusive && timeline[arrivalEnd].publication == end))
            {
                recentOrigins[timeline[arrivalEnd].origin, default: 0] += 1
                arrivalEnd += 1
            }
            return arrivalEnd - first
        }

        /// Drops reports published before `cutoff` from the trailing window.
        mutating func evict(before cutoff: Date) {
            while recentStart < arrivalEnd && timeline[recentStart].publication < cutoff {
                let origin = timeline[recentStart].origin
                recentOrigins[origin, default: 0] -= 1
                if recentOrigins[origin] == 0 { recentOrigins.removeValue(forKey: origin) }
                recentStart += 1
            }
        }
    }

    /// Replays one event's independent reports, the earliest per wire group, in publication buckets from `windowStart`
    /// to `through`.
    ///
    /// Throws `MomentumError` for invalid input and `CancellationError` when the task is cancelled between buckets.
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
        let points = try bucketPoints(
            timeline, bucketCount: bucketCount, windowStart: windowStart, through: through,
            configuration: configuration)
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

    private static func bucketPoints(
        _ timeline: [IndependentReport], bucketCount: Int, windowStart: Date, through: Date,
        configuration: MomentumConfiguration
    ) throws -> [MomentumPoint] {
        var points: [MomentumPoint] = []
        var short = 0.0
        var long = 0.0
        var signal = 0.0
        var previousHistogram = 0.0
        let firstInWindow = timeline.firstIndex { $0.publication >= windowStart } ?? timeline.count
        var arrivals = ArrivalWindow(timeline: timeline, arrivalEnd: firstInWindow, recentStart: firstInWindow)
        for bucket in 0..<bucketCount {
            try Task.checkCancellation()
            let start = windowStart.addingTimeInterval(Double(bucket) * configuration.bucketSeconds)
            let end = min(through, start.addingTimeInterval(configuration.bucketSeconds))
            let arrived = arrivals.admit(until: end, inclusive: bucket == bucketCount - 1)
            let elapsed = end.timeIntervalSince(start)
            // Reports per configured nominal bucket; a partial final bucket is scaled to the same unit.
            let rate = elapsed > 0 ? Double(arrived) / elapsed * configuration.bucketSeconds : 0
            guard rate.isFinite else { throw MomentumError.invalidConfiguration }
            short += alpha(elapsed, configuration.shortHalfLife) * (rate - short)
            long += alpha(elapsed, configuration.longHalfLife) * (rate - long)
            let macd = short - long
            signal += alpha(elapsed, configuration.signalHalfLife) * (macd - signal)
            let histogram = macd - signal
            arrivals.evict(before: max(windowStart, end.addingTimeInterval(-configuration.volumeWindow)))
            let floorMet =
                arrivals.recentCount >= configuration.minimumIndependentReports
                && arrivals.recentOrigins.count >= configuration.minimumOriginPublishers
            points.append(
                .init(
                    bucketEnd: end, independentCount: arrivals.recentCount, originCount: arrivals.recentOrigins.count,
                    shortEMA: short, longEMA: long, macd: macd, signal: signal, histogram: histogram,
                    state: classify(previous: previousHistogram, histogram: histogram, floorMet: floorMet)))
            previousHistogram = histogram
        }
        return points
    }

    /// Equality is neutral: deceleration requires a strictly positive-to-negative adjacent crossover.
    private static func classify(previous: Double, histogram: Double, floorMet: Bool) -> MomentumState {
        if previous > 0 && histogram < 0 { return .decelerating }
        return histogram > 0 && floorMet ? .accelerating : .quiet
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
