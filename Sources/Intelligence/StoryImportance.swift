import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How much a story matters to a general reader following the news, decided on device from its headline and summary.
enum StoryImportance: Int, Sendable, Comparable {
    case minor = 0, notable = 1, major = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When a story appears in the main lists. An important story shows from its first report. A minor one waits until
/// more than `minorStorySources` publishers cover it, and expires unread after `minorStoryLifetime`. A story whose
/// importance is not known yet (no model, or not judged yet) shows, so nothing disappears for lack of a judgement.
enum StoryVisibilityPolicy {
    static let importantLevel = StoryImportance.notable
    static let minorStorySources = 3
    static let minorStoryLifetime: TimeInterval = 24 * 3600
    /// Expired stories are not ingested again while feeds still list them.
    static let expiryMemory: TimeInterval = 14 * 24 * 3600
}

/// Rates a story's importance; `nil` means no rating is available.
struct StoryImportanceJudge: Sendable {
    var isAvailable = true
    let rate: @Sendable (EventJudgeReport) async -> StoryImportance?

    static let unavailable = StoryImportanceJudge(isAvailable: false) { _ in nil }
    /// The on-device model when Apple Intelligence is ready; each call returns nil otherwise.
    static let onDevice = StoryImportanceJudge { await OnDeviceImportanceJudge.shared.rate($0) }
}

/// Asks the on-device model, once per report text. Reports are untrusted data, framed and sanitized.
actor OnDeviceImportanceJudge {
    static let shared = OnDeviceImportanceJudge()
    // ponytail: process-lifetime cache cleared at 5,000 entries; stories come from a 72-hour window.
    private var cache: [String: StoryImportance] = [:]

    func rate(_ report: EventJudgeReport) async -> StoryImportance? {
        let key = "\(report.id)\u{1}\(report.title)\u{1}\(report.summary.hashValue)"
        if let known = cache[key] { return known }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            // Like the event judge: news text needs the content-transformation guardrails and a plain-text answer.
            let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations))
            let response = try await session.respond(
                to: Self.prompt(report), options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 8))
            guard let level = Self.level(response.content) else { return nil }
            if cache.count >= 5_000 { cache.removeAll() }
            cache[key] = level
            return level
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The first word of the answer; anything else is no rating.
    static func level(_ answer: String) -> StoryImportance? {
        switch answer.uppercased().split(whereSeparator: { !$0.isLetter }).first {
        case "MAJOR": return .major
        case "NOTABLE": return .notable
        case "MINOR": return .minor
        default: return nil
        }
    }

    static func prompt(_ report: EventJudgeReport) -> String {
        """
        \(GenerationPromptDefense.untrustedDataSystemGuard)

        Rate how important this news story is for a general reader who follows world news.
        MAJOR: affects many people, a whole country or a market. Examples: wars and major attacks, disasters with \
        deaths, elections and major government decisions, major court rulings, deaths of prominent people, major \
        economic or company news, public health emergencies.
        NOTABLE: significant national or international news with a narrower reach.
        MINOR: local or niche news, celebrity and lifestyle, sports results, features, opinion, explainers, live blogs, \
        quizzes, how-to and shopping.
        Answer with exactly one word: MAJOR, NOTABLE or MINOR.

        \(GenerationPromptDefense.frameArticleData(title: report.title, description: report.summary))
        """
    }
}

/// After clustering: rates stories that have no rating yet, then expires stories that waited too long.
enum StoryCurator {
    struct Report: Equatable, Sendable {
        var rated = 0
        var expired = 0
        var changed: Bool { rated > 0 || expired > 0 }
    }

    static func run(
        in database: DatabaseEngine,
        judge: StoryImportanceJudge,
        budget: Int = 60,
        activeLifetime: TimeInterval = EventCandidatePolicy.standard.activeEventLifetime,
        now: Date = Date()
    ) async throws -> Report {
        var report = Report()
        if judge.isAvailable, budget > 0 {
            for row in try await database.pendingImportanceRows(activeSince: now.addingTimeInterval(-activeLifetime), limit: budget) {
                try Task.checkCancellation()
                guard let level = await judge.rate(EventClusterer.report(row)) else { continue }
                try await database.recordImportance(row.id, level, at: now)
                report.rated += 1
            }
        }
        report.expired = try await database.expireWaitingStories(now: now)
        return report
    }
}
