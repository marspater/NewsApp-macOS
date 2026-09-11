import Foundation
import os

/// Priority levels for enrichment jobs.
enum EnrichmentPriority: Int, Comparable, Sendable {
    case background = 0   // Batch feed ingest backlog
    case high = 1         // Visible unread headlines in active section
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
        let id: String // article.id
        let article: FeedArticle
        let allowHTTP: Bool
        var priority: EnrichmentPriority
        let queuedAt: Date
        var state: EnrichmentJobState
        var task: Task<Void, Never>?
    }

    private let maxConcurrency: Int = 3
    private var activeCount: Int = 0
    private var jobs: [String: Job] = [:] // Indexed by articleId

    init() {}

    // MARK: - Enqueue & Promotion

    /// Enqueues an article for NLP analysis, summary, and content scraping.
    /// If the article is already queued with a lower priority, promotes it.
    func enqueue(
        article: FeedArticle,
        priority: EnrichmentPriority = .background,
        allowHTTP: Bool = false
    ) {
        let articleId = article.id

        // 1. Check for existing job (Duplicate-Job Prevention)
        if var existing = jobs[articleId] {
            switch existing.state {
            case .queued(let currentPriority):
                if priority > currentPriority {
                    logger.debug("Promoting article '\(articleId)' from \(currentPriority.rawValue) to \(priority.rawValue)")
                    existing.priority = priority
                    existing.state = .queued(priority)
                    jobs[articleId] = existing
                }
                return
            case .running:
                // Already running
                return
            case .completed:
                // Already enriched
                return
            case .cancelled, .failed:
                // Re-enqueue
                break
            }
        }

        // 2. Create new job
        let job = Job(
            id: articleId,
            article: article,
            allowHTTP: allowHTTP,
            priority: priority,
            queuedAt: Date(),
            state: .queued(priority),
            task: nil
        )
        jobs[articleId] = job

        processNextJobs()
    }

    /// Explicitly promotes an article to interactive priority (e.g. user clicked).
    func promote(articleId: String, to priority: EnrichmentPriority = .interactive) {
        if var job = jobs[articleId], case .queued(let cur) = job.state {
            if priority > cur {
                job.priority = priority
                job.state = .queued(priority)
                jobs[articleId] = job
                processNextJobs()
            }
        }
    }

    // MARK: - Cancellation

    /// Cancels a specific article's enrichment job.
    func cancel(articleId: String, reason: EnrichmentCancellationReason = .user) {
        guard var job = jobs[articleId] else { return }
        job.task?.cancel()
        job.state = .cancelled(reason)
        jobs[articleId] = job
        logger.debug("Cancelled enrichment for '\(articleId)': \(reason.rawValue)")
    }

    /// Cancels all pending and in-flight jobs (e.g. on feed refresh or settings change).
    func cancelAll(reason: EnrichmentCancellationReason = .superseded) {
        for (id, var job) in jobs {
            job.task?.cancel()
            job.state = .cancelled(reason)
            jobs[id] = job
        }
        activeCount = 0
        logger.info("Cancelled all enrichment jobs: \(reason.rawValue)")
    }

    // MARK: - Queue State Queries

    func state(for articleId: String) -> EnrichmentJobState? {
        jobs[articleId]?.state
    }

    func activeJobCount() -> Int {
        activeCount
    }

    func pendingJobCount() -> Int {
        jobs.values.filter {
            if case .queued = $0.state { return true }
            return false
        }.count
    }

    // MARK: - Scheduler Execution

    private func processNextJobs() {
        guard activeCount < maxConcurrency else { return }

        // Find highest-priority queued jobs
        let queuedJobs = jobs.values.filter {
            if case .queued = $0.state { return true }
            return false
        }

        guard !queuedJobs.isEmpty else { return }

        // Sort by priority DESC, then by queuedAt ASC
        let sorted = queuedJobs.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.queuedAt < $1.queuedAt
        }

        let capacity = maxConcurrency - activeCount
        let toRun = sorted.prefix(capacity)

        for var job in toRun {
            activeCount += 1
            job.state = .running
            let id = job.id
            let article = job.article
            let allowHTTP = job.allowHTTP

            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.executeJob(article: article, allowHTTP: allowHTTP)
            }
            job.task = task
            jobs[id] = job
        }
    }

    private func executeJob(article: FeedArticle, allowHTTP: Bool) async {
        let articleId = article.id

        defer {
            activeCount = max(0, activeCount - 1)
            processNextJobs()
        }

        // Check cancellation before heavy work
        if Task.isCancelled || isJobCancelled(articleId) {
            markJobState(articleId: articleId, state: .cancelled(.superseded))
            return
        }

        let signpostState = NewsSignposts.begin(NewsSignposts.enrichment, name: "EnrichmentJob", metadata: "source=\(article.source)")
        defer { NewsSignposts.end(NewsSignposts.enrichment, name: "EnrichmentJob", state: signpostState) }

        // 1. NLP Sentiment & Entity Analysis
        let summaryText = await ArticleIntelligence.shared.analyzeArticle(
            title: article.title,
            description: article.description
        )

        if Task.isCancelled || isJobCancelled(articleId) {
            markJobState(articleId: articleId, state: .cancelled(.superseded))
            return
        }

        // 2. Topic Categorization with confidence
        let topicResult = await ArticleIntelligence.shared.categorizeArticle(
            title: article.title,
            description: article.description,
            text: article.fullContent,
            rssCategory: article.category
        )

        if Task.isCancelled || isJobCancelled(articleId) {
            markJobState(articleId: articleId, state: .cancelled(.superseded))
            return
        }

        // 3. Web Scraping / Content Extraction (if missing)
        var fetchedContent: String?
        var fetchedImage: String?
        if article.fullContent == nil || article.fullContent!.isEmpty {
            let extracted = await ContentExtractionPipeline.shared.extractArticle(from: article.link, allowHTTP: allowHTTP)
            fetchedContent = extracted.content
            fetchedImage = extracted.imageUrl
        }

        if Task.isCancelled || isJobCancelled(articleId) {
            markJobState(articleId: articleId, state: .cancelled(.superseded))
            return
        }

        // 4. Extractive Summarization if full content exists
        var finalSummary = summaryText
        if let content = fetchedContent, !content.isEmpty {
            let extractedSummary = await ArticleIntelligence.shared.summarizeArticle(title: article.title, content: content)
            if !extractedSummary.text.isEmpty {
                finalSummary = extractedSummary.text
            }
        }

        let result = EnrichmentResult(
            articleId: articleId,
            summary: finalSummary,
            category: topicResult?.category,
            confidence: topicResult?.confidence,
            content: fetchedContent,
            image: fetchedImage
        )

        // 5. "Queue computes. Store persists."
        await ArticleStore.shared.updateEnrichment(
            id: result.articleId,
            summary: result.summary,
            category: result.category,
            sentiment: nil,
            entities: nil,
            topics: nil,
            content: result.content,
            image: result.image
        )

        markJobState(articleId: articleId, state: .completed)
    }

    private func isJobCancelled(_ articleId: String) -> Bool {
        if let state = jobs[articleId]?.state, case .cancelled = state {
            return true
        }
        return false
    }

    private func markJobState(articleId: String, state: EnrichmentJobState) {
        if var job = jobs[articleId] {
            job.state = state
            jobs[articleId] = job
        }
    }
}
