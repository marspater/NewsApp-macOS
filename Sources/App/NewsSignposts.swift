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

// NewsSignposts.swift

import Foundation
import os

/// Structured OSSignposter wrappers for Apple Instruments performance profiling.
/// Emits lightweight signpost intervals with bounded metadata (no private/sensitive data).
enum NewsSignposts {
    /// The logging subsystem every category shares.
    static let subsystem = "com.marspater.news"

    /// One category per area (#564): the area's log lines and its signposts share it.
    static let feedsLog = Logger(subsystem: subsystem, category: "Feeds")
    /// Log lines of the database area.
    static let databaseLog = Logger(subsystem: subsystem, category: "Database")
    /// Log lines of launch timing.
    static let launchLog = Logger(subsystem: subsystem, category: "Launch")

    /// Signposts of feed refresh, logged with `feedsLog`.
    static let feeds = OSSignposter(logger: feedsLog)
    /// Signposts of database work, logged with `databaseLog`.
    static let database = OSSignposter(logger: databaseLog)
    /// Signposts of enrichment jobs.
    static let enrichment = OSSignposter(subsystem: subsystem, category: "Enrichment")
    /// Signposts of on-device analysis.
    static let intelligence = OSSignposter(subsystem: subsystem, category: "Intelligence")
    /// Signposts of launch, logged with `launchLog`.
    static let launch = OSSignposter(logger: launchLog)

    @MainActor private static var firstCardReported = false

    /// Records, once per process, when the first story card appears: an Instruments event plus a log line
    /// with the time since the process started, so launch can be measured on the shipping app.
    @MainActor
    static func firstCardAppeared(restored: Bool = false) {
        guard !firstCardReported else { return }
        firstCardReported = true
        launch.emitEvent("FirstCard")
        guard let start = processStart() else { return }
        let elapsed = Date().timeIntervalSince(start)
        // A card of a restored edition is on screen sooner than its fresh edition is ready: the two are told apart.
        launchLog.notice(
            "First card visible ms_since_process_start=\(elapsed * 1000, format: .fixed(precision: 3), privacy: .public) restored=\(restored, privacy: .public)"
        )
    }

    /// Logs an event of the launch with the time since the process started, also after the first card: when the
    /// fresh Today edition is ready behind a restored one, and what became of it (#937).
    @MainActor
    static func launchEvent(_ name: String, detail: String) {
        guard let start = processStart() else { return }
        let elapsed = Date().timeIntervalSince(start) * 1000
        launchLog.notice(
            "Launch event \(name, privacy: .public) \(detail, privacy: .public) ms_since_process_start=\(elapsed, format: .fixed(precision: 3), privacy: .public)"
        )
    }

    /// Logs a launch milestone with the time since the process started, until the first card is on screen, so the
    /// stages before it can be read from the shipping app's log.
    @MainActor
    static func launchMilestone(_ name: String) {
        guard !firstCardReported, let start = processStart() else { return }
        let elapsed = Date().timeIntervalSince(start) * 1000
        launchLog.notice(
            "Launch milestone \(name, privacy: .public) ms_since_process_start=\(elapsed, format: .fixed(precision: 3), privacy: .public)"
        )
    }

    /// Times the consecutive stages of one piece of launch work and logs each stage's duration.
    struct StageTimer {
        /// The name of the work every stage line carries.
        let work: String
        private var mark = ContinuousClock.now

        /// Starts timing the first stage of `work`.
        init(_ work: String) { self.work = work }

        /// Logs the time since the previous lap, or since the timer started, as `stage`, with an optional item count.
        mutating func lap(_ stage: String, count: Int? = nil) {
            let now = ContinuousClock.now
            let duration = now - mark
            mark = now
            let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            let work = work
            NewsSignposts.launchLog.notice(
                "\(work, privacy: .public) stage=\(stage, privacy: .public) ms=\(ms, format: .fixed(precision: 3), privacy: .public) count=\(count ?? -1, privacy: .public)"
            )
        }
    }

    /// When this process started, from the kernel.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Begins a signpost interval and returns the state token.
    @inline(__always)
    static func begin(
        _ signposter: OSSignposter,
        name: StaticString,
        metadata: String? = nil
    ) -> OSSignpostIntervalState {
        let signpostID = signposter.makeSignpostID()
        if let meta = metadata {
            return signposter.beginInterval(name, id: signpostID, "\(meta, privacy: .public)")
        } else {
            return signposter.beginInterval(name, id: signpostID)
        }
    }

    /// Ends a signpost interval using the provided state token.
    @inline(__always)
    static func end(
        _ signposter: OSSignposter,
        name: StaticString,
        state: OSSignpostIntervalState
    ) {
        signposter.endInterval(name, state)
    }

    /// Convenience wrapper to measure synchronous work and propagate errors.
    @discardableResult
    static func measure<T>(
        signposter: OSSignposter,
        name: StaticString,
        metadata: String? = nil,
        work: () throws -> T
    ) rethrows -> T {
        let state = begin(signposter, name: name, metadata: metadata)
        defer { end(signposter, name: name, state: state) }
        return try work()
    }

    /// Convenience wrapper to measure asynchronous work and propagate errors.
    @discardableResult
    static func measure<T>(
        signposter: OSSignposter,
        name: StaticString,
        metadata: String? = nil,
        work: () async throws -> T
    ) async rethrows -> T {
        let state = begin(signposter, name: name, metadata: metadata)
        defer { end(signposter, name: name, state: state) }
        return try await work()
    }
}
