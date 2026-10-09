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
                to: Self.prompt(report), options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 8))
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
        Media or industry business news, such as programme cuts at a broadcaster, is MINOR unless it affects a \
        whole sector or national policy.
        Incidents at military sites count by consequence: trespass arrests are MINOR; damage, sabotage, terrorism \
        charges or a real security breach are NOTABLE.
        Nationwide price changes of staple goods are NOTABLE; a change by one company or in one region is MINOR.
        Answer with exactly one word: MAJOR, NOTABLE or MINOR.

        \(GenerationPromptDefense.frameArticleData(title: report.title, description: report.summary))
        """
    }
}

/// After clustering: rates stories that have no rating yet, expires stories that waited too long, then looks up lead
/// images for shown stories whose events have none.
enum StoryCurator {
    struct Report: Equatable, Sendable {
        var rated = 0
        var expired = 0
        var imagesFound = 0
        var imagesChecked = 0
        var changed: Bool { rated > 0 || expired > 0 || imagesChecked > 0 }
    }

    static func run(
        in database: DatabaseEngine,
        judge: StoryImportanceJudge,
        imageFinder: StoryImageFinder = .unavailable,
        budget: Int = 60,
        imageBudget: Int = 30,
        muting: MuteRules = MuteRules(),
        keepingFeedURLs: [String] = [],
        activeLifetime: TimeInterval = EventCandidatePolicy.standard.activeEventLifetime,
        now: Date = Date()
    ) async throws -> Report {
        var report = Report()
        if judge.isAvailable, budget > 0 {
            for row in try await database.pendingImportanceRows(activeSince: now.addingTimeInterval(-activeLifetime), limit: budget) {
                try Task.checkCancellation()
                guard let level = await judge.rate(EventClusterer.report(row)) else { continue }
                try Task.checkCancellation()
                if try await database.recordImportance(row.id, level, at: now, expectedTitle: row.title, expectedDescription: row.description) {
                    report.rated += 1
                }
            }
        }
        report.expired = try await database.expireWaitingStories(now: now, keepingFeedURLs: keepingFeedURLs)
        if imageFinder.isAvailable, imageBudget > 0 {
            // ponytail: rows read once per pass; one lookup per event, the rest of an event waits for the next pass.
            var lookedUp = Set<String>()
            for row in try await database.imagelessStoryRows(activeSince: now.addingTimeInterval(-activeLifetime), limit: imageBudget * 3, muting: muting)
            where lookedUp.count < imageBudget {
                try Task.checkCancellation()
                if let event = row.eventID, lookedUp.contains(event) { continue }
                lookedUp.insert(row.eventID ?? row.id)
                switch await imageFinder.find(row.link) {
                case .found(let url):
                    try Task.checkCancellation()
                    if try await database.recordStoryImage(row.id, imageURL: url, at: now, expectedLink: row.link) { report.imagesFound += 1 }
                    report.imagesChecked += 1
                case .none:
                    try Task.checkCancellation()
                    try await database.recordStoryImage(row.id, imageURL: nil, at: now, expectedLink: row.link)
                    report.imagesChecked += 1
                case .unreachable:
                    continue
                }
            }
        }
        return report
    }
}

/// Result of looking for a story's lead image on its publisher page.
enum StoryImageLookup: Equatable, Sendable {
    case found(String)
    /// The page was read and declares no usable image.
    case none
    /// The page could not be read (offline, refused); try again on a later pass.
    case unreachable
}

/// Finds the lead image a publisher declares for a story (`og:image`, `twitter:image`) when its feed carries none.
struct StoryImageFinder: Sendable {
    var isAvailable = true
    let find: @Sendable (_ link: String) async -> StoryImageLookup

    static let unavailable = StoryImageFinder(isAvailable: false) { _ in .unreachable }
    /// The article page through the protected client; http links are requested over https.
    static let publisherPages = publisherPages(using: .shared)

    static func publisherPages(using client: SecureHTTPClient) -> StoryImageFinder {
        StoryImageFinder { link in
        guard var components = URLComponents(string: link) else { return .none }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard let url = components.url,
              let (data, response) = try? await client.fetchArticleHead(from: url),
              response.statusCode < 400 else { return .unreachable }
        guard !Task.isCancelled else { return .unreachable }
        return leadImage(in: ContentExtractionPipeline.shared.decodeHTML(data: data, response: response),
                         pageURL: response.url?.absoluteString ?? url.absoluteString)
        }
    }

    /// The page's declared lead image, resolved against the page and filtered like any reader image.
    static func leadImage(in html: String, pageURL: String) -> StoryImageLookup {
        let pipeline = ContentExtractionPipeline.shared
        for declared in pipeline.extractLeadImages(from: html) {
            if let url = ContentExtractionPipeline.readerImageURL(pipeline.decodeHTMLEntities(declared), baseURL: pageURL),
               ReaderImageCandidate.usable(url: url) { return .found(url) }
        }
        return .none
    }
}
