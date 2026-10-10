// NewsSignposts.swift

import Foundation
import os

/// Structured OSSignposter wrappers for Apple Instruments performance profiling.
/// Emits lightweight signpost intervals with bounded metadata (no private/sensitive data).
enum NewsSignposts {
    static let subsystem = "com.marspater.news"

    static let feeds = OSSignposter(subsystem: subsystem, category: "Feeds")
    static let database = OSSignposter(subsystem: subsystem, category: "Database")
    static let enrichment = OSSignposter(subsystem: subsystem, category: "Enrichment")
    static let intelligence = OSSignposter(subsystem: subsystem, category: "Intelligence")
    static let launch = OSSignposter(subsystem: subsystem, category: "Launch")

    @MainActor private static var firstCardReported = false

    /// Records, once per process, when the first story card appears: an Instruments event plus a log line
    /// with the time since the process started, so launch can be measured on the shipping app.
    @MainActor
    static func firstCardAppeared() {
        guard !firstCardReported else { return }
        firstCardReported = true
        launch.emitEvent("FirstCard")
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_un.__p_starttime
        let elapsed = Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        Logger(subsystem: subsystem, category: "Launch").notice(
            "First card visible ms_since_process_start=\(elapsed * 1000, format: .fixed(precision: 3), privacy: .public)"
        )
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
