import Foundation
import os

/// Priority for overview generation requests.
enum OverviewRequestPriority: Sendable, Comparable {
    case visibleEvent
    case onDemand
    case background

    var enrichmentPriority: EnrichmentPriority {
        switch self {
        case .onDemand:
            return .interactive
        case .visibleEvent:
            return .high
        case .background:
            return .background
        }
    }
}

/// Actor that coordinates on-demand and visible-event overview generation,
/// caching, cooperative cancellation, staleness checks, and version supersession.
/// Reuses the existing `EnrichmentQueue` to respect bounded concurrency and system resources.
actor OverviewGenerationCoordinator {
    static let shared = OverviewGenerationCoordinator()
    private let logger = Logger(subsystem: "com.marspater.news", category: "OverviewCoordinator")

    private var memoryCache: [String: EventOverviewDocument] = [:]
    private var inFlightTasks: [String: Task<EventOverviewDocument?, Never>] = [:]
    private var currentVisibleEventID: String?

    private let store: ArticleStore?
    private let queue: EnrichmentQueue

    init(store: ArticleStore? = nil, queue: EnrichmentQueue = .shared) {
        self.store = store
        self.queue = queue
    }

    // MARK: - On-Demand & Visible Event Requests

    /// Requests an overview for an event.
    /// Returns the cached result immediately if it exists and is not stale.
    /// If regeneration is needed, executes under the bounded enrichment queue.
    func requestOverview(
        eventID: String,
        eventTitle: String,
        membershipVersion: Int,
        articles: [FeedArticle],
        priority: OverviewRequestPriority = .onDemand
    ) async -> EventOverviewDocument? {
        // Step A: Token-budgeted representative passage selection
        let selection = OverviewPassageSelector().selectPassages(
            from: articles,
            budget: OverviewTokenBudget()
        )
        let sortedFingerprints = selection.passages.map { $0.fingerprint }.sorted().joined(separator: ":")
        let inputTextHash = ArticleIdentity.sha256Hex(sortedFingerprints.isEmpty ? eventTitle : sortedFingerprints)

        // 1. Check memory cache first
        if let cached = memoryCache[eventID],
           !cached.isStale(currentMembershipVersion: membershipVersion, currentInputTextHash: inputTextHash) {
            logger.debug("Memory cache hit for event \(eventID) v\(membershipVersion)")
            return cached
        }

        // 2. Check persistent store cache
        let targetStore: ArticleStore
        if let store { targetStore = store } else { targetStore = await ArticleStore.shared }

        if let stored = try? await targetStore.fetchEventOverview(eventID: eventID),
           !stored.isStale(currentMembershipVersion: membershipVersion, currentInputTextHash: inputTextHash) {
            logger.debug("Store cache hit for event \(eventID) v\(membershipVersion)")
            memoryCache[eventID] = stored
            return stored
        }

        // 3. Return existing in-flight task if identical request is already running
        if let running = inFlightTasks[eventID] {
            return await running.value
        }

        let passages = selection.passages

        // 4. Reuse EnrichmentQueue to schedule generation under bounded concurrency
        let task = Task<EventOverviewDocument?, Never> { [weak self] in
            guard let self = self else { return nil }

            let document = await self.queue.scheduleOverviewGeneration(
                eventID: eventID,
                priority: priority.enrichmentPriority
            ) {
                if Task.isCancelled { return nil }

                if Task.isCancelled { return nil }

                // Step B: Passage-anchored fact extraction
                let verifiedFacts = PassageFactExtractor.deterministicExtract(passages: passages)

                if Task.isCancelled { return nil }

                // Step C: Overview composition
                let overview = OverviewComposer.composeOverview(
                    eventID: eventID,
                    eventTitle: eventTitle,
                    verifiedFacts: verifiedFacts,
                    passages: passages,
                    articles: articles,
                    leadImage: nil,
                    membershipVersion: membershipVersion
                )

                return overview
            }

            guard let generated = document, !Task.isCancelled else { return nil }

            // Stale check before saving: a stale result never overwrites a newer version
            await self.commitGeneratedOverview(
                generated,
                eventID: eventID,
                membershipVersion: membershipVersion,
                targetStore: targetStore
            )

            return generated
        }

        inFlightTasks[eventID] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: eventID)
        return result
    }

    private func commitGeneratedOverview(
        _ document: EventOverviewDocument,
        eventID: String,
        membershipVersion: Int,
        targetStore: ArticleStore
    ) async {
        // If memory cache already holds a newer membership version, drop stale result
        if let existing = memoryCache[eventID], existing.membershipVersion > membershipVersion {
            logger.info("Dropping stale overview result for \(eventID): v\(membershipVersion) < current v\(existing.membershipVersion)")
            return
        }

        // DatabaseEngine also atomically prevents an older result from overwriting newer
        let saved = (try? await targetStore.recordEventOverview(document)) ?? false
        if saved {
            memoryCache[eventID] = document
            logger.debug("Committed overview for event \(eventID) v\(membershipVersion)")
        }
    }

    // MARK: - Visible Event Management & Automatic Cancellation

    /// Updates the currently visible event.
    /// Automatically cancels generation for the previous event if it changed.
    func setVisibleEvent(
        eventID: String?,
        eventTitle: String? = nil,
        membershipVersion: Int? = nil,
        articles: [FeedArticle]? = nil
    ) async {
        let previous = currentVisibleEventID
        currentVisibleEventID = eventID

        // If visible event changed, cancel generation for the previous event
        if let oldID = previous, oldID != eventID {
            cancel(eventID: oldID, reason: .user)
        }

        // If new event is visible and data provided, trigger generation with visibleEvent priority
        if let newID = eventID, let title = eventTitle, let version = membershipVersion, let arts = articles {
            _ = await requestOverview(
                eventID: newID,
                eventTitle: title,
                membershipVersion: version,
                articles: arts,
                priority: .visibleEvent
            )
        }
    }

    // MARK: - Cancellation

    /// Cancels generation when the reader closes or event changes.
    func cancel(eventID: String, reason: EnrichmentCancellationReason = .user) {
        if let task = inFlightTasks.removeValue(forKey: eventID) {
            task.cancel()
        }
        Task {
            await queue.cancelOverview(eventID: eventID, reason: reason)
        }
        logger.debug("Cancelled overview generation for \(eventID): \(reason.rawValue)")
    }

    /// Cancels all in-flight overview generations.
    func cancelAll() {
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
        logger.info("Cancelled all in-flight overview generation tasks")
    }

    // MARK: - Cache Access

    func cachedOverview(
        for eventID: String,
        currentMembershipVersion: Int,
        currentInputTextHash: String
    ) async -> EventOverviewDocument? {
        if let cached = memoryCache[eventID],
           !cached.isStale(currentMembershipVersion: currentMembershipVersion, currentInputTextHash: currentInputTextHash) {
            return cached
        }
        let targetStore: ArticleStore
        if let store { targetStore = store } else { targetStore = await ArticleStore.shared }
        if let stored = try? await targetStore.fetchEventOverview(eventID: eventID),
           !stored.isStale(currentMembershipVersion: currentMembershipVersion, currentInputTextHash: currentInputTextHash) {
            memoryCache[eventID] = stored
            return stored
        }
        return nil
    }

    func clearCache() {
        memoryCache.removeAll()
    }
}
