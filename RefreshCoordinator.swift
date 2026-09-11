// RefreshCoordinator.swift

import Foundation
import os

/// Actor-isolated single-flight coordinator for feed refresh operations.
/// Prevents concurrent execution of refresh tasks by coalescing simultaneous requests
/// onto the active in-flight task rather than dropping them or performing duplicate work.
actor RefreshCoordinator {
    static let shared = RefreshCoordinator()

    private var activeTask: Task<Void, Error>?
    private let logger = Logger(subsystem: "com.marspater.news", category: "RefreshCoordinator")

    /// Executes the provided refresh work, or joins the active in-flight refresh task
    /// if one is already running.
    func executeRefresh(_ work: @Sendable @escaping () async throws -> Void) async throws {
        if let current = activeTask {
            logger.debug("Refresh already in flight; coalescing caller onto active task.")
            try await current.value
            return
        }

        let task = Task<Void, Error> {
            try await work()
        }
        activeTask = task

        defer {
            activeTask = nil
        }

        try await task.value
    }

    /// Whether a refresh is currently running (useful for diagnostics & tests).
    var isRefreshing: Bool {
        activeTask != nil
    }
}
