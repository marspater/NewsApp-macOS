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
    static let shared = OverviewGenerationCoordinator(extractText: { link in
        await ContentExtractionPipeline.shared.extractArticleWithIdentity(from: link).outcome
    })
    private let logger = Logger(subsystem: "com.marspater.news", category: "OverviewCoordinator")

    /// A running generation and the inputs it was started from.
    private struct InFlightGeneration {
        let task: Task<EventOverviewDocument?, Never>
        let membershipVersion: Int
        let inputTextHash: String
        let articleInputs: [String: String]
    }

    private var memoryCache: [String: EventOverviewDocument] = [:]
    private var inFlightTasks: [String: InFlightGeneration] = [:]
    /// The inputs of the most recent request per event. Only a result built from them may be committed:
    /// an article edit changes the input hash without bumping the membership version.
    private var latestRequestedInputs: [String: (membershipVersion: Int, inputTextHash: String)] = [:]
    private var currentVisibleEventID: String?
    /// The reader that set the visible event; only it may clear it (`clearVisibleEvent(owner:)`).
    private var currentVisibleOwner: UUID?

    private let store: ArticleStore?
    private let queue: EnrichmentQueue
    private let allowsEnergy: @Sendable () async -> Bool

    /// Publisher text for an overview's representatives (#308). Nil keeps the stored text only, as in tests.
    nonisolated let extractText: (@Sendable (_ link: String) async -> ExtractionOutcome)?
    /// Each page fetch ends by this deadline, counted from when it starts, so a slow publisher cannot hold up an overview.
    nonisolated let extractionDeadline: Duration
    static let maxEvidenceFetches = 4
    static let maxConcurrentExtractions = 2
    /// Running page fetches by article ID; overlapping requests join them instead of fetching again.
    private var extractionTasks: [String: Task<Void, Never>] = [:]
    /// Article ID plus publisher input of fetches that failed or timed out; not retried this session.
    // ponytail: grows with articles seen in one session; prune by age if sessions get long.
    private var failedExtractions: Set<String> = []
    private var activeExtractions = 0

    init(
        store: ArticleStore? = nil, queue: EnrichmentQueue = .shared,
        // Compatibility for audit callers; production excerpts never use a model.
        textModel _: NewsTextModel = .unavailable,
        allowsModel _: @escaping @Sendable () async -> Bool = { false },
        allowsEnergy: (@Sendable () async -> Bool)? = nil,
        extractText: (@Sendable (_ link: String) async -> ExtractionOutcome)? = nil,
        extractionDeadline: Duration = .seconds(4)
    ) {
        self.store = store
        self.queue = queue
        self.allowsEnergy =
            allowsEnergy ?? {
                let info = ProcessInfo.processInfo
                return !info.isLowPowerModeEnabled
                    && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
            }
        self.extractText = extractText
        self.extractionDeadline = extractionDeadline
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
        priority: OverviewRequestPriority = .onDemand,
        store: ArticleStore? = nil,
        excludingFromExtraction excluded: Set<String> = []
    ) async -> EventOverviewDocument? {
        guard !Task.isCancelled else { return nil }
        let energyAllowed = await allowsEnergy()
        guard !Task.isCancelled else { return nil }

        let targetStore: ArticleStore
        if let store {
            targetStore = store
        } else if let selfStore = self.store {
            targetStore = selfStore
        } else {
            targetStore = await ArticleStore.shared
        }
        let multiSource = Set(articles.map { $0.source.lowercased() }).count > 1
        // Publisher text first: storing it changes the articles' inputs, so the inputs, cache key and
        // expected article versions below are all taken from the reloaded articles.
        let articles =
            energyAllowed && multiSource
            ? await articlesWithPublisherText(articles, excluding: excluded, store: targetStore) : articles
        guard !Task.isCancelled else { return nil }
        // Storage rejects the result if any article's publisher input changed while it was generated.
        let expectedArticleInputs = Dictionary(
            articles.map { ($0.id, $0.publisherInputHash) }, uniquingKeysWith: { first, _ in first })

        // Step A: Token-budgeted representative passage selection
        let selection = OverviewPassageSelector().selectPassages(
            from: articles,
            budget: OverviewTokenBudget()
        )
        let sortedFingerprints = selection.passages.map { $0.fingerprint }.sorted().joined(separator: ":")
        let inputTextHash = ArticleIdentity.sha256Hex(sortedFingerprints.isEmpty ? eventTitle : sortedFingerprints)
        recordRequestedInputs(eventID: eventID, membershipVersion: membershipVersion, inputTextHash: inputTextHash)

        // Persistent storage is authoritative: publisher-input changes atomically remove old overviews.
        do {
            if let stored = try await targetStore.fetchEventOverview(eventID: eventID),
                !stored.isStale(currentMembershipVersion: membershipVersion, currentInputTextHash: inputTextHash)
            {
                guard !Task.isCancelled else { return nil }
                logger.debug("Store cache hit for event \(eventID) v\(membershipVersion)")
                if let cached = memoryCache[eventID], cached.id == stored.id,
                    !cached.isStale(currentMembershipVersion: membershipVersion, currentInputTextHash: inputTextHash)
                {
                    return cached
                }
                storeInMemoryCache(stored, for: eventID)
                return stored
            }
        } catch {
            if !(error is CancellationError) {
                logger.error("Failed to fetch event overview for \(eventID): \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled else { return nil }

        // 3. Join a running generation only if it was started from the same inputs; otherwise it is superseded
        if let running = inFlightTasks[eventID] {
            if running.membershipVersion == membershipVersion && running.inputTextHash == inputTextHash
                && running.articleInputs == expectedArticleInputs
            {
                let result = await running.task.value
                return Task.isCancelled ? nil : result
            }
            running.task.cancel()
            inFlightTasks.removeValue(forKey: eventID)
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
            let isCurrent = await self.commitGeneratedOverview(
                generated,
                eventID: eventID,
                membershipVersion: membershipVersion,
                inputTextHash: inputTextHash,
                targetStore: targetStore,
                expectedArticleInputs: expectedArticleInputs
            )
            return isCurrent ? generated : nil
        }

        inFlightTasks[eventID] = InFlightGeneration(
            task: task, membershipVersion: membershipVersion, inputTextHash: inputTextHash,
            articleInputs: expectedArticleInputs)
        // Another request may join this generation, so a cancelled caller stops waiting without cancelling it;
        // `cancel(eventID:)` stops it for every caller.
        let result = await task.value
        // A newer request may have replaced this entry while it ran.
        if inFlightTasks[eventID]?.task == task {
            inFlightTasks.removeValue(forKey: eventID)
        }
        return Task.isCancelled ? nil : result
    }

    // MARK: - Publisher Text for Overview Evidence (#308)

    /// Stores publisher text for up to four representatives that have none and returns the articles as stored
    /// afterwards. Every fetch ends by its deadline; failed ones keep the feed summary. A cancelled caller stops
    /// waiting at once, while shared fetches finish by their own deadlines for the requests that joined them.
    func articlesWithPublisherText(
        _ articles: [FeedArticle], excluding excluded: Set<String>, store: ArticleStore
    ) async -> [FeedArticle] {
        guard extractText != nil else { return articles }
        let candidates = Set(
            OverviewRepresentativeSelector().selectRepresentatives(from: articles).map(\.id).filter {
                !excluded.contains($0)
            })
        // Callers may hold copies from before an earlier extraction; storage has the current text and inputs.
        let current = await Self.reloaded(articles, ids: candidates, store: store)
        let missing = current.filter {
            candidates.contains($0.id) && !Self.hasPublisherText($0)
                && !failedExtractions.contains($0.id + $0.publisherInputHash)
        }.prefix(Self.maxEvidenceFetches)
        guard !missing.isEmpty else { return current }
        for article in missing { startExtraction(of: article, store: store) }
        while !Task.isCancelled, missing.contains(where: { extractionTasks[$0.id] != nil }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return articles }
        return await Self.reloaded(current, ids: Set(missing.map(\.id)), store: store)
    }

    private static func reloaded(_ articles: [FeedArticle], ids: Set<String>, store: ArticleStore) async
        -> [FeedArticle]
    {
        var current = articles
        for (index, article) in articles.enumerated() where ids.contains(article.id) {
            if let stored = try? await store.database.fetchArticles(limit: 1, id: article.id).first {
                current[index] = stored
            }
        }
        return current
    }

    /// Already extracted, reader text, or feed content long enough to stand in for it.
    static func hasPublisherText(_ article: FeedArticle) -> Bool {
        article.contentFetched || article.readerDocument?.hasPublisherText == true
            || (article.fullContent?.count ?? 0) >= 600
    }

    /// Starts a fetch that stores accepted text and finishes by the deadline, unless one is already running.
    private func startExtraction(of article: FeedArticle, store: ArticleStore) {
        guard extractionTasks[article.id] == nil else { return }
        let deadline = extractionDeadline
        let task = Task {
            let work = Task { await self.extractAndStore(article, store: store) }
            let stored = await Self.result(of: work, cancellingAt: deadline)
            self.finishExtraction(article, stored: stored)
        }
        extractionTasks[article.id] = task
    }

    /// The work's result, or false at the deadline. At the deadline the work is cancelled but not awaited, so an
    /// extractor that ignores cancellation cannot hold the overview past it; a cancelled fetch never stores, and it
    /// releases its slot only when it actually ends.
    private static func result(of work: Task<Bool, Never>, cancellingAt deadline: Duration) async -> Bool {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)
        let timerTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            let timer = Task {
                try? await Task.sleep(for: deadline)
                work.cancel()
                pending.withLock { $0.take() }?.resume(returning: false)
            }
            timerTask.withLock { $0 = timer }
            Task {
                let value = await work.value
                timerTask.withLock { $0?.cancel() }
                pending.withLock { $0.take() }?.resume(returning: value)
            }
        }
    }

    /// Fetches the page and stores its text only if extraction passed its quality checks, the fetch was not cut off
    /// by the deadline, and the publisher input is unchanged.
    private nonisolated func extractAndStore(_ article: FeedArticle, store: ArticleStore) async -> Bool {
        guard let extractText, await acquireExtractionSlot() else { return false }
        let outcome = await extractText(article.link)
        await releaseExtractionSlot()
        guard !Task.isCancelled, case .success(let content, let imageUrl, let document) = outcome,
            content.count > article.description.count, !ArticleContentRedactor.redactAndSplit(content).isEmpty
        else { return false }
        return await store.updateEnrichment(
            id: article.id, content: content, image: imageUrl, readerDocument: document,
            expectedInputHash: article.publisherInputHash)
    }

    /// Waits for one of the shared extraction slots; false if cancelled while waiting.
    private func acquireExtractionSlot() async -> Bool {
        while activeExtractions >= Self.maxConcurrentExtractions {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        activeExtractions += 1
        return true
    }

    private func releaseExtractionSlot() {
        activeExtractions = max(0, activeExtractions - 1)
    }

    private func finishExtraction(_ article: FeedArticle, stored: Bool) {
        extractionTasks[article.id] = nil
        if !stored {
            if failedExtractions.count >= 1000 { failedExtractions.removeAll() }
            failedExtractions.insert(article.id + article.publisherInputHash)
        }
    }

    /// Returns false when the result was built from superseded inputs, or storage rejected it, and must not reach the caller.
    private func commitGeneratedOverview(
        _ document: EventOverviewDocument,
        eventID: String,
        membershipVersion: Int,
        inputTextHash: String,
        targetStore: ArticleStore,
        expectedArticleInputs: [String: String]
    ) async -> Bool {
        // A result from inputs that are no longer the latest requested is stale, even at the same membership version
        if let latest = latestRequestedInputs[eventID],
            latest.membershipVersion != membershipVersion || latest.inputTextHash != inputTextHash
        {
            logger.info("Dropping overview result for \(eventID) built from superseded inputs")
            return false
        }

        // If memory cache already holds a newer membership version, drop stale result
        if let existing = memoryCache[eventID], existing.membershipVersion > membershipVersion {
            logger.info(
                "Dropping stale overview result for \(eventID): v\(membershipVersion) < current v\(existing.membershipVersion)"
            )
            return true
        }

        // DatabaseEngine also atomically prevents an older result from overwriting newer
        let saved: Bool
        do {
            saved = try await targetStore.recordEventOverview(document, expectedArticleInputs: expectedArticleInputs)
        } catch {
            if !(error is CancellationError) {
                logger.error("Failed to commit overview for event \(eventID): \(error.localizedDescription)")
            }
            saved = false
        }
        if saved {
            storeInMemoryCache(document, for: eventID)
            logger.debug("Committed overview for event \(eventID) v\(membershipVersion)")
        }
        return saved
    }

    // MARK: - Visible Event Management & Automatic Cancellation

    /// Warm only three covered events from the current visible feed, under the same energy policy.
    func warmVisibleOverviews(store: ArticleStore, muting: MuteRules) async {
        guard await allowsEnergy(), !Task.isCancelled else { return }
        let articles: [FeedArticle]
        let events: [EventFeedSummary]
        do {
            articles = try await store.database.fetchArticles(
                limit: 100,
                publicationWindow: Date().addingTimeInterval(-72 * 3600)...Date(), muting: muting)
            events = try await store.eventFeedSummaries(for: articles.map(\.id))
        } catch {
            if !(error is CancellationError) {
                logger.error(
                    "Failed to fetch articles or summaries for visible overviews warming: \(error.localizedDescription)"
                )
            }
            return
        }
        let top = events.filter { $0.sources.count > 1 }.sorted {
            if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
            return ($0.latestDate ?? .distantPast) > ($1.latestDate ?? .distantPast)
        }.prefix(3)
        for event in top {
            guard !Task.isCancelled, await allowsEnergy() else { return }
            let members: [FeedArticle]
            do {
                members = try await store.database.fetchArticles(
                    limit: nil, eventID: event.eventID, muting: muting)
            } catch {
                if !(error is CancellationError) {
                    logger.error("Failed to fetch event members for \(event.eventID): \(error.localizedDescription)")
                }
                continue
            }
            guard let first = members.first else { continue }
            _ = await requestOverview(
                eventID: event.eventID, eventTitle: first.title,
                membershipVersion: event.membershipVersion, articles: members, priority: .background, store: store)
        }
    }

    /// Updates the currently visible event.
    /// Automatically cancels generation for the previous event if it changed.
    @discardableResult
    func setVisibleEvent(
        eventID: String?,
        eventTitle: String? = nil,
        membershipVersion: Int? = nil,
        articles: [FeedArticle]? = nil,
        store: ArticleStore? = nil,
        owner: UUID? = nil,
        readerArticleID: String? = nil
    ) async -> EventOverviewDocument? {
        guard !Task.isCancelled else { return nil }
        let previous = currentVisibleEventID
        currentVisibleEventID = eventID
        currentVisibleOwner = eventID == nil ? nil : owner

        // If visible event changed, cancel generation for the previous event
        if let oldID = previous, oldID != eventID {
            await cancel(eventID: oldID, reason: .user)
        }

        // Cancellation above suspends this actor; a newer reader may now own the visible event.
        guard !Task.isCancelled, currentVisibleEventID == eventID,
            currentVisibleOwner == (eventID == nil ? nil : owner)
        else { return nil }

        // If new event is visible and data provided, trigger generation with visibleEvent priority
        if let newID = eventID, let title = eventTitle, let version = membershipVersion, let arts = articles {
            return await requestOverview(
                eventID: newID,
                eventTitle: title,
                membershipVersion: version,
                articles: arts,
                priority: .visibleEvent,
                store: store,
                // The reader extracts its own article; fetching it here too would request the page twice.
                excludingFromExtraction: Set([readerArticleID].compactMap { $0 })
            )
        }
        return nil
    }

    /// Clears the visible event when the reader that set it closes. A reader that closes after another one
    /// has made the same or a different event visible changes nothing, so it cannot cancel that reader's overview.
    func clearVisibleEvent(owner: UUID) async {
        guard currentVisibleOwner == owner, let eventID = currentVisibleEventID else { return }
        currentVisibleEventID = nil
        currentVisibleOwner = nil
        await cancel(eventID: eventID, reason: .user)
    }

    // MARK: - Cancellation

    /// Cancels generation when the reader closes or event changes. The queue job is cancelled before this
    /// returns, so a request for the same event made afterwards is never cancelled by it.
    func cancel(eventID: String, reason: EnrichmentCancellationReason = .user) async {
        if let running = inFlightTasks.removeValue(forKey: eventID) {
            running.task.cancel()
        }
        await queue.cancelOverview(eventID: eventID, reason: reason)
        logger.debug("Cancelled overview generation for \(eventID): \(reason.rawValue)")
    }

    /// Cancels all in-flight overview generations.
    func cancelAll() {
        for (_, running) in inFlightTasks {
            running.task.cancel()
        }
        inFlightTasks.removeAll()
        logger.info("Cancelled all in-flight overview generation tasks")
    }

    /// The input hash of the generation running for an event, if any.
    func inFlightInputHash(for eventID: String) -> String? {
        inFlightTasks[eventID]?.inputTextHash
    }

    /// The reader that set the visible event, if any.
    func visibleEventOwner() -> UUID? {
        currentVisibleOwner
    }

    // MARK: - Cache Access

    func cachedOverview(
        for eventID: String,
        currentMembershipVersion: Int,
        currentInputTextHash: String,
        store: ArticleStore? = nil
    ) async -> EventOverviewDocument? {
        if let cached = memoryCache[eventID],
            !cached.isStale(
                currentMembershipVersion: currentMembershipVersion, currentInputTextHash: currentInputTextHash)
        {
            return cached
        }
        let targetStore: ArticleStore
        if let store {
            targetStore = store
        } else if let selfStore = self.store {
            targetStore = selfStore
        } else {
            targetStore = await ArticleStore.shared
        }
        do {
            if let stored = try await targetStore.fetchEventOverview(eventID: eventID),
                !stored.isStale(
                    currentMembershipVersion: currentMembershipVersion, currentInputTextHash: currentInputTextHash)
            {
                storeInMemoryCache(stored, for: eventID)
                return stored
            }
        } catch {
            if !(error is CancellationError) {
                logger.error("Failed to fetch event overview for \(eventID): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func storeInMemoryCache(_ document: EventOverviewDocument, for eventID: String) {
        if memoryCache.count >= 100 {
            memoryCache.remove(at: memoryCache.startIndex)
        }
        memoryCache[eventID] = document
    }

    private func recordRequestedInputs(eventID: String, membershipVersion: Int, inputTextHash: String) {
        if latestRequestedInputs.count >= 500 {
            latestRequestedInputs.remove(at: latestRequestedInputs.startIndex)
        }
        latestRequestedInputs[eventID] = (membershipVersion, inputTextHash)
    }

    func clearCache() {
        memoryCache.removeAll()
        latestRequestedInputs.removeAll()
        failedExtractions.removeAll()
    }
}
