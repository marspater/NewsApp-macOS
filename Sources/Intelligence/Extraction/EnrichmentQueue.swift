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

// Angelia · Metis (linguistic signals) owns this file. Register: docs/ANGELIA.md.

import Foundation
import os

/// Priority levels for enrichment jobs.
enum EnrichmentPriority: Int, Comparable, Sendable {
    case background = 0  // Batch feed ingest backlog
    case high = 1  // Visible unread headlines in active section
    case interactive = 2  // Currently focused / opened by user

    static func < (lhs: EnrichmentPriority, rhs: EnrichmentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Reasons for job cancellation.
enum EnrichmentCancellationReason: String, Sendable, Equatable {
    case user
    case superseded
    case timeout
}

/// Lifecycle states for an enrichment job.
enum EnrichmentJobState: Equatable, Sendable {
    case queued(EnrichmentPriority)
    case running
    case completed
    case cancelled(EnrichmentCancellationReason)
    case failed(String)
}

/// Enriched product emitted by the pipeline to be persisted by ArticleStore.
struct EnrichmentResult: Sendable, Equatable {
    let articleId: String
    let summary: String?
    let category: String?
    let confidence: Double?
    let content: String?
    let image: String?

    init(
        articleId: String,
        summary: String? = nil,
        category: String? = nil,
        confidence: Double? = nil,
        content: String? = nil,
        image: String? = nil
    ) {
        self.articleId = articleId
        self.summary = summary
        self.category = category
        self.confidence = confidence
        self.content = content
        self.image = image
    }
}

/// Actor-isolated priority enrichment queue with bounded concurrency,
/// duplicate-job prevention, dynamic promotion, and cooperative cancellation.
actor EnrichmentQueue {
    static let shared = EnrichmentQueue()
    private let logger = Logger(subsystem: "com.marspater.news", category: "EnrichmentQueue")

    private struct Job: Identifiable {
        let id: String  // article.id
        let generation = UUID()
        let article: FeedArticle
        let allowHTTP: Bool
        var priority: EnrichmentPriority
        let queuedAt: Date
        var state: EnrichmentJobState
        var task: Task<Void, Never>?
    }

    private struct QueuedEntry: Equatable {
        let id: String
        let generation: UUID
        let priority: EnrichmentPriority
        let queuedAt: Date
    }

    private let maxConcurrency: Int = 3
    private var activeCount: Int = 0
    /// Indexed by articleId (active and queued; completed and cancelled removed, #535, #986).
    private var jobs: [String: Job] = [:]
    private var cancelledCounts: [String: Int] = [:]
    /// Publisher input hash each article was classified from this session (#820): a changed input, or a clear of
    /// derived data, makes the article eligible again.
    private var completedInputs: [String: String] = [:]
    private var completedClassificationsThisSession = 0
    /// Only a bounded recent deduplication window is needed; the database keeps the durable classification.
    private static let completedInputLimit = 12_000
    private static let completedInputEvictionBatch = 3_000
    private var completedInputOrder: [(id: String, hash: String)] = []
    private var queuedHeap: [QueuedEntry] = []

    private let store: ArticleStore?

    init(store: ArticleStore? = nil) {
        self.store = store
    }

    // MARK: - Enqueue & Promotion

    /// Enqueues an article for NLP analysis, summary, and content scraping.
    /// If the article is already queued with a lower priority, promotes it.
    func enqueue(
        article: FeedArticle,
        priority: EnrichmentPriority = .background,
        allowHTTP: Bool = false
    ) {
        enqueue(articles: [article], priority: priority, allowHTTP: allowHTTP)
    }

    /// Enqueues a batch of articles for NLP analysis, summary, and content scraping.
    /// If an article is already queued with a lower priority, promotes it.
    func enqueue(
        articles: [FeedArticle],
        priority: EnrichmentPriority = .background,
        allowHTTP: Bool = false
    ) {
        guard !articles.isEmpty else { return }
        for article in articles {
            let articleId = article.id

            // 1. Check for existing or completed job (Duplicate-Job Prevention)
            if completedInputs[articleId] == article.publisherInputHash {
                continue
            }
            if var existing = jobs[articleId] {
                switch existing.state {
                case .queued(let currentPriority):
                    if priority > currentPriority {
                        logger.debug(
                            "Promoting article '\(articleId)' from \(currentPriority.rawValue) to \(priority.rawValue)")
                        existing.priority = priority
                        existing.state = .queued(priority)
                        jobs[articleId] = existing
                        pushHeap(
                            QueuedEntry(
                                id: articleId,
                                generation: existing.generation,
                                priority: priority,
                                queuedAt: existing.queuedAt
                            )
                        )
                    }
                    continue
                case .running, .completed:
                    continue
                case .cancelled, .failed:
                    break
                }
            }

            // 2. Create new job
            let now = Date()
            let job = Job(
                id: articleId,
                article: article,
                allowHTTP: allowHTTP,
                priority: priority,
                queuedAt: now,
                state: .queued(priority),
                task: nil
            )
            jobs[articleId] = job
            pushHeap(
                QueuedEntry(
                    id: articleId,
                    generation: job.generation,
                    priority: priority,
                    queuedAt: now
                )
            )
        }

        processNextJobs()
    }

    // MARK: - Cancellation

    /// Cancels a specific article's enrichment job.
    func cancel(articleId: String, reason: EnrichmentCancellationReason = .user) {
        guard let job = jobs[articleId] else { return }
        job.task?.cancel()
        jobs.removeValue(forKey: articleId)
        cancelledCounts[reason.rawValue, default: 0] += 1
        logger.debug("Cancelled enrichment for '\(articleId)': \(reason.rawValue)")
    }

    /// Cancels all pending and in-flight jobs (e.g. on feed refresh or settings change).
    func cancelAll(reason: EnrichmentCancellationReason = .superseded) {
        for (id, job) in jobs {
            // Finished work stays finished, so a refresh does not classify the same articles again.
            if case .completed = job.state { continue }
            job.task?.cancel()
            jobs.removeValue(forKey: id)
            cancelledCounts[reason.rawValue, default: 0] += 1
        }
        queuedHeap.removeAll()
        for (eventID, task) in overviewTasks {
            task.cancel()
            logger.debug("Cancelled overview generation for '\(eventID)': \(reason.rawValue)")
        }
        overviewTasks.removeAll()
        // Also invalidate generations waiting for a worker slot, which have no task to cancel yet.
        overviewGenerations.removeAll()
        // Cancelled tasks occupy slots until their deferred cleanup runs.
        logger.info("Cancelled all enrichment jobs: \(reason.rawValue)")
    }

    // MARK: - Overview Generation Integration

    private var overviewTasks: [String: Task<EventOverviewDocument?, Never>] = [:]
    /// A request owns its event from enqueue time, including time spent waiting for capacity.
    private var overviewGenerations: [String: UUID] = [:]

    /// Runs overview generation using the enrichment queue's bounded concurrency and cancellation tracking.
    func scheduleOverviewGeneration(
        eventID: String,
        priority _: EnrichmentPriority = .high,
        operation: @escaping @Sendable () async -> EventOverviewDocument?
    ) async -> EventOverviewDocument? {
        cancelOverview(eventID: eventID, reason: .superseded)
        let generation = UUID()
        overviewGenerations[eventID] = generation
        defer {
            if overviewGenerations[eventID] == generation { overviewGenerations.removeValue(forKey: eventID) }
        }

        while activeCount >= maxConcurrency {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
            guard !Task.isCancelled, overviewGenerations[eventID] == generation else { return nil }
        }
        guard !Task.isCancelled, overviewGenerations[eventID] == generation else { return nil }

        activeCount += 1
        defer {
            activeCount = max(0, activeCount - 1)
            processNextJobs()
        }

        let task = Task<EventOverviewDocument?, Never> {
            if Task.isCancelled { return nil }
            return await operation()
        }
        overviewTasks[eventID] = task
        defer { if overviewTasks[eventID] == task { overviewTasks.removeValue(forKey: eventID) } }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // A cancelled or superseded operation may ignore cancellation; never publish its stale result.
        guard !Task.isCancelled, overviewGenerations[eventID] == generation else { return nil }
        return result
    }

    /// Cancels overview generation for a specific event, even before it acquires a worker slot.
    func cancelOverview(eventID: String, reason: EnrichmentCancellationReason = .user) {
        overviewGenerations.removeValue(forKey: eventID)
        if let task = overviewTasks.removeValue(forKey: eventID) {
            task.cancel()
            logger.debug("Cancelled overview generation for '\(eventID)': \(reason.rawValue)")
        }
    }

    // MARK: - Queue State Queries

    /// Jobs by state, plus the stories classified this session, for the diagnostics export (#1006).
    func stateCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for job in jobs.values {
            let name: String
            switch job.state {
            case .queued: name = "queued"
            case .running: name = "running"
            case .completed: name = "completed"
            case .cancelled(let reason): name = "cancelled (\(reason.rawValue))"
            case .failed: name = "failed"
            }
            counts[name, default: 0] += 1
        }
        for (reason, count) in cancelledCounts {
            counts["cancelled (\(reason))", default: 0] += count
        }
        if completedClassificationsThisSession > 0 {
            counts["classified this session"] = completedClassificationsThisSession
        }
        return counts
    }

    func state(for articleId: String) -> EnrichmentJobState? {
        if let state = jobs[articleId]?.state { return state }
        return completedInputs[articleId] == nil ? nil : .completed
    }

    /// Clear AI Analysis ran (#805): queued and running work is cancelled (its writes are refused anyway) and every
    /// story is eligible for classification again.
    func analysisCleared() {
        completedInputs.removeAll()
        completedClassificationsThisSession = 0
        completedInputOrder.removeAll()
        cancelAll(reason: .superseded)
    }

    func activeJobCount() -> Int {
        activeCount
    }

    /// Overview requests that own an event but have not acquired a worker slot.
    func queuedOverviewCount() -> Int {
        overviewGenerations.count - overviewTasks.count
    }

    func retainsJob(for articleId: String) -> Bool {
        jobs[articleId] != nil
    }

    // MARK: - Scheduler Execution

    private static func isHigherPriority(_ lhs: QueuedEntry, _ rhs: QueuedEntry) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        if lhs.queuedAt != rhs.queuedAt {
            return lhs.queuedAt < rhs.queuedAt
        }
        return lhs.id < rhs.id
    }

    private func pushHeap(_ entry: QueuedEntry) {
        queuedHeap.append(entry)
        var child = queuedHeap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if Self.isHigherPriority(queuedHeap[child], queuedHeap[parent]) {
                queuedHeap.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private func popHeap() -> QueuedEntry? {
        guard !queuedHeap.isEmpty else { return nil }
        if queuedHeap.count == 1 {
            return queuedHeap.removeLast()
        }
        let top = queuedHeap[0]
        queuedHeap[0] = queuedHeap.removeLast()
        var parent = 0
        let count = queuedHeap.count
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var candidate = parent
            if left < count && Self.isHigherPriority(queuedHeap[left], queuedHeap[candidate]) {
                candidate = left
            }
            if right < count && Self.isHigherPriority(queuedHeap[right], queuedHeap[candidate]) {
                candidate = right
            }
            if candidate == parent { break }
            queuedHeap.swapAt(parent, candidate)
            parent = candidate
        }
        return top
    }

    private func processNextJobs() {
        while activeCount < maxConcurrency, let entry = popHeap() {
            guard var job = jobs[entry.id],
                job.generation == entry.generation,
                case .queued(let currentPriority) = job.state,
                currentPriority == entry.priority
            else {
                continue
            }

            activeCount += 1
            job.state = .running
            let id = job.id
            let article = job.article
            let allowHTTP = job.allowHTTP
            let generation = job.generation

            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.executeJob(article: article, allowHTTP: allowHTTP, generation: generation)
            }
            job.task = task
            jobs[id] = job
        }
    }

    private func executeJob(article: FeedArticle, allowHTTP _: Bool, generation: UUID) async {
        let articleId = article.id

        defer {
            activeCount = max(0, activeCount - 1)
            processNextJobs()
        }

        // Check cancellation before heavy work. A cancelled job was already evicted by `cancel` or `cancelAll`, and an
        // article enqueued again since has a newer generation: this task never evicts its replacement (#986).
        if jobs[articleId]?.generation != generation { return }
        if Task.isCancelled {
            evictJob(articleId, generation: generation)
            return
        }

        let signpostState = NewsSignposts.begin(
            NewsSignposts.enrichment, name: "EnrichmentJob", metadata: "source=\(article.source)")
        defer { NewsSignposts.end(NewsSignposts.enrichment, name: "EnrichmentJob", state: signpostState) }

        // Queue computes. Store persists. The write carries the generation the work started under (#844).
        let destination: ArticleStore
        if let store { destination = store } else { destination = await ArticleStore.shared }
        let analysisGeneration = await destination.database.analysisGeneration

        // Background feed ingestion: strictly lightweight topic classification.
        // Deep semantic analysis (summary, key points, entities) is performed lazily when the user opens an article.
        let topicResult = await ArticleClassifier.shared.classify(
            title: article.title,
            description: article.description,
            text: article.fullContent,
            // Stored categories may be earlier classifier output; never feed that output back as a publisher hint.
            rssCategory: nil
        )

        if jobs[articleId]?.generation != generation { return }
        if Task.isCancelled {
            evictJob(articleId, generation: generation)
            return
        }

        let result = EnrichmentResult(
            articleId: articleId,
            summary: nil,
            category: topicResult.category,
            confidence: topicResult.confidence,
            content: nil,
            image: nil
        )

        let stored = await destination.updateEnrichment(
            id: result.articleId,
            summary: nil,
            category: result.category,
            sentiment: nil,
            entities: nil,
            topics: nil,
            content: nil,
            image: nil,
            expectedInputHash: article.publisherInputHash,
            expectedGeneration: analysisGeneration,
            coalescesPublication: true
        )

        guard jobs[articleId]?.generation == generation else { return }
        evictJob(articleId, generation: generation)
        // A refused write (the publisher changed the story, or the analysis was cleared) leaves the story eligible
        // for the next enqueue instead of counting as classified (#820).
        if stored, !Task.isCancelled { recordCompletedInput(articleId, hash: article.publisherInputHash) }
    }

    /// Evicts old deduplication entries in batches to avoid indefinite session growth without O(n) work per result.
    private func recordCompletedInput(_ articleId: String, hash: String) {
        completedClassificationsThisSession += 1
        // The same article may be reclassified after its publisher input changes.
        if completedInputs[articleId] != nil { completedInputOrder.removeAll { $0.id == articleId } }
        completedInputs[articleId] = hash
        completedInputOrder.append((articleId, hash))
        if completedInputOrder.count > Self.completedInputLimit {
            for old in completedInputOrder.prefix(Self.completedInputEvictionBatch)
            where completedInputs[old.id] == old.hash {
                completedInputs.removeValue(forKey: old.id)
            }
            completedInputOrder.removeFirst(Self.completedInputEvictionBatch)
        }
    }

    /// Drops a finished or cancelled job and the story it retains, unless the article was enqueued again since.
    private func evictJob(_ articleId: String, generation: UUID) {
        if jobs[articleId]?.generation == generation { jobs.removeValue(forKey: articleId) }
    }
}
