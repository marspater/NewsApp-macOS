import Foundation

// Opt-in audit tooling for `--overviews-live` and the overview quality tests (#549). It left the shipping target
// because the app reaches only `OverviewQualityAuditor.auditClaim`; Mars keeps the tooling available, so it moved
// here rather than being deleted. Types and functions are unchanged.

/// Serializable summary of a single claim audit result for persistence and reporting.
public struct ClaimAuditSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let claimText: String
    public let citationIDs: [String]
    public let statusKind: String
    public let detail: String?

    public init(id: String, claimText: String, citationIDs: [String], statusKind: String, detail: String? = nil) {
        self.id = id
        self.claimText = claimText
        self.citationIDs = citationIDs
        self.statusKind = statusKind
        self.detail = detail
    }
}

/// Breakdown of critical factual errors detected during overview quality audits.
public struct QualityErrorBreakdown: Sendable, Codable, Equatable {
    public let numberMismatchCount: Int
    public let dateMismatchCount: Int
    public let attributionErrorCount: Int

    public var totalCriticalErrors: Int {
        numberMismatchCount + dateMismatchCount + attributionErrorCount
    }

    public init(numberMismatchCount: Int = 0, dateMismatchCount: Int = 0, attributionErrorCount: Int = 0) {
        self.numberMismatchCount = numberMismatchCount
        self.dateMismatchCount = dateMismatchCount
        self.attributionErrorCount = attributionErrorCount
    }
}

/// Aggregate claim counts and support rates for overview quality audits.
public struct QualityClaimMetrics: Sendable, Codable, Equatable {
    public let totalClaims: Int
    public let supportedClaims: Int
    public let unsupportedClaims: Int

    public var supportRate: Double {
        guard totalClaims > 0 else { return 1.0 }
        return Double(supportedClaims) / Double(totalClaims)
    }

    public init(totalClaims: Int = 0, supportedClaims: Int = 0, unsupportedClaims: Int = 0) {
        self.totalClaims = totalClaims
        self.supportedClaims = supportedClaims
        self.unsupportedClaims = unsupportedClaims
    }
}

/// Timing metrics capturing percentiles for overview generation latencies.
public struct QualityTimingMetrics: Sendable, Codable, Equatable {
    public let p50Duration: TimeInterval?
    public let p95Duration: TimeInterval?

    public init(p50Duration: TimeInterval? = nil, p95Duration: TimeInterval? = nil) {
        self.p50Duration = p50Duration
        self.p95Duration = p95Duration
    }
}

/// Formal quality report for an event overview against verified source passages and labeled control sample.
public struct OverviewQualityReport: Sendable, Codable, Equatable {
    public let overviewID: String
    public let eventID: String
    public let metrics: QualityClaimMetrics
    public let errors: QualityErrorBreakdown
    public let duration: TimeInterval?
    public let claimSummaries: [ClaimAuditSummary]

    public var totalClaims: Int { metrics.totalClaims }
    public var supportedClaims: Int { metrics.supportedClaims }
    public var unsupportedClaims: Int { metrics.unsupportedClaims }
    public var supportRate: Double { metrics.supportRate }

    public var numberMismatchCount: Int { errors.numberMismatchCount }
    public var dateMismatchCount: Int { errors.dateMismatchCount }
    public var attributionErrorCount: Int { errors.attributionErrorCount }
    public var totalCriticalErrors: Int { errors.totalCriticalErrors }

    public var canReleaseGenerativeOverview: Bool {
        totalCriticalErrors == 0
    }

    public var isReleaseBlocked: Bool {
        !canReleaseGenerativeOverview
    }

    public init(
        overviewID: String,
        eventID: String,
        metrics: QualityClaimMetrics,
        errors: QualityErrorBreakdown,
        duration: TimeInterval? = nil,
        claimSummaries: [ClaimAuditSummary] = []
    ) {
        self.overviewID = overviewID
        self.eventID = eventID
        self.metrics = metrics
        self.errors = errors
        self.duration = duration
        self.claimSummaries = claimSummaries
    }
}

/// Aggregate quality report for an entire benchmark suite of control samples.
public struct ControlSuiteQualityReport: Sendable, Codable, Equatable {
    public let totalSamples: Int
    public let metrics: QualityClaimMetrics
    public let errors: QualityErrorBreakdown
    public let timing: QualityTimingMetrics
    public let sampleReports: [OverviewQualityReport]

    public var totalClaims: Int { metrics.totalClaims }
    public var supportedClaims: Int { metrics.supportedClaims }
    public var unsupportedClaims: Int { metrics.unsupportedClaims }
    public var supportRate: Double { metrics.supportRate }

    public var numberMismatchCount: Int { errors.numberMismatchCount }
    public var dateMismatchCount: Int { errors.dateMismatchCount }
    public var attributionErrorCount: Int { errors.attributionErrorCount }
    public var totalCriticalErrors: Int { errors.totalCriticalErrors }

    public var p50Duration: TimeInterval? { timing.p50Duration }
    public var p95Duration: TimeInterval? { timing.p95Duration }

    public var canReleaseGenerativeOverview: Bool {
        totalCriticalErrors == 0
    }

    public var isReleaseBlocked: Bool {
        !canReleaseGenerativeOverview
    }

    public init(
        totalSamples: Int,
        metrics: QualityClaimMetrics,
        errors: QualityErrorBreakdown,
        timing: QualityTimingMetrics,
        sampleReports: [OverviewQualityReport] = []
    ) {
        self.totalSamples = totalSamples
        self.metrics = metrics
        self.errors = errors
        self.timing = timing
        self.sampleReports = sampleReports
    }
}

/// Explicit release gate decision returned by the quality auditor.
public enum ReleaseGateDecision: Sendable, Equatable {
    case passed(supportedClaims: Int, totalClaims: Int)
    case blocked(criticalErrors: Int, reasons: [String])
}

// MARK: - Performance & Timing Tracker

/// Thread-safe tracker for recording and computing p50/p95 overview generation durations.
public final class OverviewTimingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [TimeInterval] = []

    public init() {}

    public func record(duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        recordedDurations.append(duration)
    }

    public var durations: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDurations
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedDurations.removeAll()
    }

    public var p50Duration: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return Self.calculatePercentile(50.0, from: recordedDurations)
    }

    public var p95Duration: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return Self.calculatePercentile(95.0, from: recordedDurations)
    }

    public var averageDuration: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard !recordedDurations.isEmpty else { return nil }
        return recordedDurations.reduce(0, +) / Double(recordedDurations.count)
    }

    /// Computes an exact percentile from an array of duration samples using linear interpolation.
    public static func calculatePercentile(_ percentile: Double, from samples: [TimeInterval]) -> TimeInterval? {
        guard !samples.isEmpty else { return nil }
        guard samples.count > 1 else { return samples[0] }
        let sorted = samples.sorted()
        let p = max(0.0, min(100.0, percentile)) / 100.0
        let index = Double(sorted.count - 1) * p
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper {
            return sorted[lower]
        }
        let weight = index - Double(lower)
        return sorted[lower] * (1.0 - weight) + sorted[upper] * weight
    }

    @discardableResult
    public func measure<T>(_ block: () throws -> T) rethrows -> (result: T, duration: TimeInterval) {
        let signpostState = NewsSignposts.begin(NewsSignposts.intelligence, name: "AIOverviewGeneration")
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            NewsSignposts.end(NewsSignposts.intelligence, name: "AIOverviewGeneration", state: signpostState)
        }
        let result = try block()
        let duration = CFAbsoluteTimeGetCurrent() - start
        record(duration: duration)
        return (result, duration)
    }
}

// MARK: - Control Sample Definition

/// A labeled control sample representing a verified event with known facts and evidence passages.
public struct OverviewControlSample: Sendable, Identifiable {
    public let id: String
    public let eventID: String
    public let title: String
    public let passages: [EvidencePassage]
    public let groundTruthFacts: [PassageAnchoredFact]
    internal let articles: [FeedArticle]

    internal init(
        id: String,
        eventID: String,
        title: String,
        passages: [EvidencePassage],
        groundTruthFacts: [PassageAnchoredFact],
        articles: [FeedArticle] = []
    ) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.passages = passages
        self.groundTruthFacts = groundTruthFacts
        self.articles = articles
    }

    /// Curated standard control benchmark for testing generative overview quality and release gates.
    internal static func standardBenchmark(fixtureHost: String = "news.example.com") -> [OverviewControlSample] {
        let fundingPassage = EvidencePassage(
            id: "pass-fund-1",
            articleID: "art-fund-1",
            text:
                "On October 1, 2026, SwiftCloud announced it has raised $50 million in Series B funding led by Horizon Ventures. CEO Jane Doe stated: 'This capital accelerates our distributed systems deployment across Europe.' The round values the company at $400 million.",
            ordinal: 1
        )
        let fundingArticle = FeedArticle(
            storedID: "art-fund-1",
            title: "SwiftCloud Secures $50 Million Series B Funding",
            link: "feed://\(fixtureHost)/stories/fund-1",
            guid: "guid-fund-1",
            description: "Distributed infrastructure startup raises fresh growth capital.",
            pubDate: Date(timeIntervalSince1970: 1_790_800_000),
            source: "Venture Journal"
        )
        let fundingFacts = [
            PassageAnchoredFact(
                id: "fact-fund-1",
                statement: "SwiftCloud raised $50 million in Series B funding led by Horizon Ventures.",
                passageID: "pass-fund-1",
                quote: "raised $50 million in Series B funding led by Horizon Ventures",
                articleID: "art-fund-1"
            ),
            PassageAnchoredFact(
                id: "fact-fund-2",
                statement:
                    "CEO Jane Doe announced the capital accelerates distributed systems deployment across Europe.",
                passageID: "pass-fund-1",
                quote: "This capital accelerates our distributed systems deployment across Europe.",
                articleID: "art-fund-1"
            ),
            PassageAnchoredFact(
                id: "fact-fund-3",
                statement: "The financing round values SwiftCloud at $400 million.",
                passageID: "pass-fund-1",
                quote: "values the company at $400 million",
                articleID: "art-fund-1"
            ),
        ]
        let sample1 = OverviewControlSample(
            id: "ctrl-fund",
            eventID: "evt-fund-001",
            title: "SwiftCloud Secures $50 Million Series B Funding",
            passages: [fundingPassage],
            groundTruthFacts: fundingFacts,
            articles: [fundingArticle]
        )

        let clinicalPassage = EvidencePassage(
            id: "pass-trial-1",
            articleID: "art-trial-1",
            text:
                "A peer-reviewed study published on September 15, 2026 revealed that candidate vaccine VX-42 achieved 88% efficacy in a 12,000-patient trial. Lead investigator Dr. Marcus Vance reported zero severe adverse events during the observation period.",
            ordinal: 1
        )
        let clinicalArticle = FeedArticle(
            storedID: "art-trial-1",
            title: "Phase 3 Trial Demonstrates 88% Efficacy Against Respiratory Virus",
            link: "feed://\(fixtureHost)/stories/trial-1",
            guid: "guid-trial-1",
            description: "Clinical milestone reached for new immunization platform.",
            pubDate: Date(timeIntervalSince1970: 1_789_400_000),
            source: "Medical Gazette"
        )
        let clinicalFacts = [
            PassageAnchoredFact(
                id: "fact-trial-1",
                statement: "Candidate vaccine VX-42 achieved 88% efficacy in a 12,000-patient trial.",
                passageID: "pass-trial-1",
                quote: "achieved 88% efficacy in a 12,000-patient trial",
                articleID: "art-trial-1"
            ),
            PassageAnchoredFact(
                id: "fact-trial-2",
                statement: "Lead investigator Dr. Marcus Vance reported zero severe adverse events.",
                passageID: "pass-trial-1",
                quote: "reported zero severe adverse events",
                articleID: "art-trial-1"
            ),
            PassageAnchoredFact(
                id: "fact-trial-3",
                statement: "The peer-reviewed study results were published on September 15, 2026.",
                passageID: "pass-trial-1",
                quote: "published on September 15, 2026",
                articleID: "art-trial-1"
            ),
        ]
        let sample2 = OverviewControlSample(
            id: "ctrl-trial",
            eventID: "evt-trial-002",
            title: "Phase 3 Trial Demonstrates 88% Efficacy Against Respiratory Virus",
            passages: [clinicalPassage],
            groundTruthFacts: clinicalFacts,
            articles: [clinicalArticle]
        )

        let energyPassage = EvidencePassage(
            id: "pass-grid-1",
            articleID: "art-grid-1",
            text:
                "On August 20, 2026, the Nordic Energy Commission connected 1.5 gigawatts of offshore wind capacity to the regional power network. Energy Commissioner Astrid Lind noted the project will supply power to 850,000 households.",
            ordinal: 1
        )
        let energyArticle = FeedArticle(
            storedID: "art-grid-1",
            title: "Nordic Grid Integrates 1.5 Gigawatts of Offshore Wind",
            link: "feed://\(fixtureHost)/stories/grid-1",
            guid: "guid-grid-1",
            description: "Renewable capacity added to North Sea distribution network.",
            pubDate: Date(timeIntervalSince1970: 1_787_100_000),
            source: "Nordic Energy Dispatch"
        )
        let energyFacts = [
            PassageAnchoredFact(
                id: "fact-grid-1",
                statement: "The Nordic Energy Commission connected 1.5 gigawatts of offshore wind capacity.",
                passageID: "pass-grid-1",
                quote: "connected 1.5 gigawatts of offshore wind capacity",
                articleID: "art-grid-1"
            ),
            PassageAnchoredFact(
                id: "fact-grid-2",
                statement: "Energy Commissioner Astrid Lind noted the project will supply power to 850,000 households.",
                passageID: "pass-grid-1",
                quote: "supply power to 850,000 households",
                articleID: "art-grid-1"
            ),
            PassageAnchoredFact(
                id: "fact-grid-3",
                statement: "The regional grid interconnection took place on August 20, 2026.",
                passageID: "pass-grid-1",
                quote: "On August 20, 2026, the Nordic Energy Commission connected",
                articleID: "art-grid-1"
            ),
        ]
        let sample3 = OverviewControlSample(
            id: "ctrl-grid",
            eventID: "evt-grid-003",
            title: "Nordic Grid Integrates 1.5 Gigawatts of Offshore Wind",
            passages: [energyPassage],
            groundTruthFacts: energyFacts,
            articles: [energyArticle]
        )

        return [sample1, sample2, sample3]
    }
}

extension OverviewQualityAuditor {
    // MARK: - Overview Document Audit

    /// Audits an entire event overview document against source passages and optional control sample.
    public static func auditOverview(
        _ overview: EventOverviewDocument,
        passages: [EvidencePassage],
        duration: TimeInterval? = nil
    ) -> OverviewQualityReport {
        var supportedCount = 0
        var unsupportedCount = 0
        var numberMismatchCount = 0
        var dateMismatchCount = 0
        var attributionErrorCount = 0
        var summaries: [ClaimAuditSummary] = []

        for fact in overview.allClaims {
            let result = auditClaim(fact, citations: overview.citations, passages: passages)
            let statusKind: String
            var detail: String? = nil

            switch result.status {
            case .supported:
                supportedCount += 1
                statusKind = "supported"
            case .unsupported(let reason):
                unsupportedCount += 1
                statusKind = "unsupported"
                detail = reason
            case .criticalError(let kind, let errorDetail):
                detail = errorDetail
                switch kind {
                case .numberMismatch:
                    numberMismatchCount += 1
                    statusKind = "criticalNumberMismatch"
                case .dateMismatch:
                    dateMismatchCount += 1
                    statusKind = "criticalDateMismatch"
                case .attributionError:
                    attributionErrorCount += 1
                    statusKind = "criticalAttributionError"
                }
            }

            summaries.append(
                ClaimAuditSummary(
                    id: fact.id,
                    claimText: fact.text,
                    citationIDs: fact.citationIDs,
                    statusKind: statusKind,
                    detail: detail
                )
            )
        }

        return OverviewQualityReport(
            overviewID: overview.id,
            eventID: overview.eventID,
            metrics: QualityClaimMetrics(
                totalClaims: overview.allClaims.count,
                supportedClaims: supportedCount,
                unsupportedClaims: unsupportedCount
            ),
            errors: QualityErrorBreakdown(
                numberMismatchCount: numberMismatchCount,
                dateMismatchCount: dateMismatchCount,
                attributionErrorCount: attributionErrorCount
            ),
            duration: duration,
            claimSummaries: summaries
        )
    }

    // MARK: - Control Suite Audit

    /// Runs a batch audit across a suite of control samples with recorded timings.
    public static func auditControlSamples(
        _ pairs: [(sample: OverviewControlSample, overview: EventOverviewDocument, duration: TimeInterval?)]
    ) -> ControlSuiteQualityReport {
        var sampleReports: [OverviewQualityReport] = []
        var totalClaims = 0
        var supportedClaims = 0
        var unsupportedClaims = 0
        var numberMismatches = 0
        var dateMismatches = 0
        var attributionErrors = 0
        var durations: [TimeInterval] = []

        for (sample, overview, duration) in pairs {
            let report = auditOverview(overview, passages: sample.passages, duration: duration)
            sampleReports.append(report)
            totalClaims += report.totalClaims
            supportedClaims += report.supportedClaims
            unsupportedClaims += report.unsupportedClaims
            numberMismatches += report.numberMismatchCount
            dateMismatches += report.dateMismatchCount
            attributionErrors += report.attributionErrorCount
            if let dur = duration {
                durations.append(dur)
            }
        }

        let p50 = OverviewTimingTracker.calculatePercentile(50.0, from: durations)
        let p95 = OverviewTimingTracker.calculatePercentile(95.0, from: durations)

        return ControlSuiteQualityReport(
            totalSamples: pairs.count,
            metrics: QualityClaimMetrics(
                totalClaims: totalClaims,
                supportedClaims: supportedClaims,
                unsupportedClaims: unsupportedClaims
            ),
            errors: QualityErrorBreakdown(
                numberMismatchCount: numberMismatches,
                dateMismatchCount: dateMismatches,
                attributionErrorCount: attributionErrors
            ),
            timing: QualityTimingMetrics(p50Duration: p50, p95Duration: p95),
            sampleReports: sampleReports
        )
    }

    // MARK: - Release Gate Evaluation

    /// Evaluates if the generative overview release is blocked by critical errors.
    public static func isReleaseBlocked(by report: OverviewQualityReport) -> Bool {
        report.isReleaseBlocked
    }

    /// Evaluates if the generative release is blocked for an entire control suite.
    public static func isReleaseBlocked(by suiteReport: ControlSuiteQualityReport) -> Bool {
        suiteReport.isReleaseBlocked
    }

    /// Computes a structured release gate decision with detailed error breakdown.
    public static func evaluateReleaseGate(report: OverviewQualityReport) -> ReleaseGateDecision {
        if report.totalCriticalErrors > 0 {
            var reasons: [String] = []
            if report.numberMismatchCount > 0 {
                reasons.append("\(report.numberMismatchCount) critical number mismatch(es)")
            }
            if report.dateMismatchCount > 0 {
                reasons.append("\(report.dateMismatchCount) critical date mismatch(es)")
            }
            if report.attributionErrorCount > 0 {
                reasons.append("\(report.attributionErrorCount) critical attribution error(s)")
            }
            return .blocked(criticalErrors: report.totalCriticalErrors, reasons: reasons)
        }
        return .passed(supportedClaims: report.supportedClaims, totalClaims: report.totalClaims)
    }

}
