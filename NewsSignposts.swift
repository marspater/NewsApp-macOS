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

