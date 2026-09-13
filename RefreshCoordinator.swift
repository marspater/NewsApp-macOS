// RefreshCoordinator.swift

import Foundation
import os

/// Actor-isolated single-flight coordinator for feed refresh operations.
/// Prevents concurrent execution of refresh tasks by coalescing simultaneous requests
/// onto the active in-flight task rather than dropping them or performing duplicate work.
actor RefreshCoordinator {
    static let shared = RefreshCoordinator()

    private var activeTask: Task<Void, Error>?
    private var currentRunID: UUID?
    private let logger = Logger(subsystem: "com.marspater.news", category: "RefreshCoordinator")

    /// Executes the provided refresh work, or joins the active in-flight refresh task
    /// if one is already running. Subsequent callers coalesce onto the in-flight task.
    func executeRefresh(_ work: @Sendable @escaping () async throws -> Void) async throws {
        if let current = activeTask {
            logger.debug("Refresh already in flight; coalescing caller onto active task.")
            try await current.value
            return
        }

        let runID = UUID()
        self.currentRunID = runID

        let task = Task.detached(priority: .userInitiated) {
            do {
                try await work()
                await self.finishRun(runID: runID)
            } catch {
                await self.finishRun(runID: runID)
                throw error
            }
        }

        self.activeTask = task

        try await task.value
    }

    private func finishRun(runID: UUID) async {
        if self.currentRunID == runID {
            self.activeTask = nil
            self.currentRunID = nil
            logger.debug("Refresh run \(runID) completed and cleared.")
        }
    }

    /// Explicitly resets coordinator state (useful for tests or teardown).
    func reset() {
        activeTask?.cancel()
        activeTask = nil
        currentRunID = nil
    }

    /// Whether a refresh is currently running (useful for diagnostics & tests).
    var isRefreshing: Bool {
        activeTask != nil
    }
}

