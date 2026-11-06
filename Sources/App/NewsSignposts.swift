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
    static let subsystem = "com.marspater.news"

    /// One category per area (#564): the area's log lines and its signposts share it.
    static let feedsLog = Logger(subsystem: subsystem, category: "Feeds")
    static let databaseLog = Logger(subsystem: subsystem, category: "Database")
    static let launchLog = Logger(subsystem: subsystem, category: "Launch")

    static let feeds = OSSignposter(logger: feedsLog)
    static let database = OSSignposter(logger: databaseLog)
    static let enrichment = OSSignposter(subsystem: subsystem, category: "Enrichment")
    static let intelligence = OSSignposter(subsystem: subsystem, category: "Intelligence")
    static let launch = OSSignposter(logger: launchLog)

    @MainActor private static var firstCardReported = false

    /// Records, once per process, when the first story card appears: an Instruments event plus a log line
    /// with the time since the process started, so launch can be measured on the shipping app.
    @MainActor
    static func firstCardAppeared() {
        guard !firstCardReported else { return }
        firstCardReported = true
        launch.emitEvent("FirstCard")
        guard let start = processStart() else { return }
        let elapsed = Date().timeIntervalSince(start)
        launchLog.notice(
            "First card visible ms_since_process_start=\(elapsed * 1000, format: .fixed(precision: 3), privacy: .public)"
        )
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
