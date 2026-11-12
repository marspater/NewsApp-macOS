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

// Angelia · Athena (editorial selection) owns the notification triage in this file. Register: docs/ANGELIA.md.

import AppKit
import Foundation
import Intents
import NaturalLanguage
import Security
import UserNotifications
import os

/// What a refresh hands the notification service besides the new stories: the mode, the event of each story (so one
/// event notifies once and later reports thread under the first banner, #587) and what full-mode triage reads
/// (#588). Everything here comes from the reader's own library and settings.
struct NotificationDelivery: Sendable {
    var mode: AppSettings.NotificationMode
    /// Story id → event id, for stories clustering has grouped; a story outside any event is absent.
    var events: [String: String] = [:]
    /// Event id → the story it belongs to (#581), for this pass's events and the ledger's announced events; an event
    /// that is its own story is absent. Banners count once per story (#740).
    var stories: [String: String] = [:]
    /// Event id → number of distinct publishers among its members.
    var publishers: [String: Int] = [:]
    /// The reader's top interest categories, lowercased `NewsCategory` raw values.
    var interests: Set<String> = []
    /// Feeds whose every story is eligible for the starred lane (at most three, #588).
    var starredFeedURLs: Set<String> = []
    /// Event id → the title of its lead story now (the story that opened the event).
    var leadTitles: [String: String] = [:]
    /// When the pass runs; every window in docs/notifications.md is measured from it.
    var now = Date()
    /// What earlier banners left in the delivery tables (#665).
    var ledger = NotificationLedger()
    /// Starred feed → its pending stories: visible, unmuted, created since its last starred banner, its star time or
    /// 24 h ago, whichever is latest. Includes this pass's new stories from the feed.
    var starredPending: [String: [FeedArticle]] = [:]
    /// Asked before each banner after the first: whether full banners may still post. The pass copies the mode when
    /// it starts and its banners are minutes apart, so a reader who switches to Privacy or turns notifications off
    /// meanwhile must not get the rest.
    var continues: @Sendable () async -> Bool = { true }
    /// The story with the images its card shows now, asked when its banner is posted: the library's curation drops a
    /// publisher's repeated logo and adds the photo the page lookup recorded. The pass keeps each story as it was at
    /// triage and posts minutes later, so a feed without images (Al Jazeera, CNBC) had no photo on its banner
    /// although one was recorded meanwhile (#1201).
    var curated: @Sendable (FeedArticle) async -> FeedArticle = { story in
        // Without a library the story is shown as it came.
        story
    }
    /// Called after each banner posts, so the pass records it before the next.
    var record: @Sendable (PlannedBanner) async -> Void = { _ in
        // Without a library (tests, summary modes) there is nothing to record.
    }
    /// Called with priority keys over both priority limits, which wait for the next grouped priority banner.
    var queue: @Sendable ([QueuedPriority]) async -> Void = { _ in
        // Without a library there is no queue to keep.
    }
}

/// Notification lanes (#665, docs/notifications.md). The raw value is stored; a higher lane wins.
enum NotificationLane: Int, Comparable, Sendable {
    case normal = 0
    case starred = 1
    case priority = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A priority key waiting for the next grouped priority banner.
struct QueuedPriority: Sendable, Equatable {
    var event: String
    var title: String
    var score: Double
    var leadKey: String
    /// The story that qualified the key, for `PlannedBanner.stories`; empty for a key queued by an earlier build.
    var story = ""
}

/// The delivery tables as a pass reads them, with every time clamped to the pass's clock.
struct NotificationLedger: Sendable {
    /// Normal banners in the last 60 minutes.
    var normalLastHour = 0
    /// Individual priority banners in the last 30 minutes.
    var priorityLastHalfHour = 0
    /// Whether a grouped priority banner posted in the last 30 minutes.
    var priorityGroupLastHalfHour = false
    /// Starred feed → its latest starred banner.
    var lastStarred: [String: Date] = [:]
    /// Events announced in the last 24 h → their lead headline key then and the highest lane that covered them.
    var announced: [String: Announcement] = [:]
    /// Priority keys still waiting, at most 24 h old.
    var priorityQueue: [QueuedPriority] = []

    struct Announcement: Sendable, Equatable {
        var leadKey: String
        var lane: NotificationLane
    }
}

/// One banner a pass will post, in posting order.
struct PlannedBanner: Sendable {
    var lane: NotificationLane
    var grouped: Bool
    /// The story an individual banner shows; nil for a grouped banner.
    var article: FeedArticle?
    /// A grouped banner's title and headlines (two at most).
    var title = ""
    var headlines: [String] = []
    /// Stories (starred) or keys (priority) a grouped banner stands for.
    var count = 1
    var feedURL: String?
    var thread: String
    var sound: Bool
    /// Event id → lead headline key, for each event the banner announces.
    var announces: [String: String] = [:]
    /// The stories a grouped banner stands for.
    var members: [String] = []

    /// The stories the banner covers: its own story, or a grouped banner's members (#584).
    var stories: [String] { article.map { [$0.id] } ?? members }
}

/// Why a banner was not drawn.
enum BannerSuppression: String, Sendable, Equatable {
    /// Permission is not granted: denied, or macOS has not asked yet.
    case notAuthorized
    case alertsOff
    case styleNone
    /// A Focus is on, so News draws nothing until it ends.
    case focus
}

/// Thrown by a post that drew nothing on purpose; the banner is not recorded, so its story may notify again.
struct BannerSuppressed: Error, Equatable {
    let reason: BannerSuppression
}

/// What the reader's System Settings and Focus make of a banner (#926). The app draws every banner itself; the
/// notification center is only asked for permission and its settings, never to deliver, since a second path shows
/// every story twice.
enum BannerGate: Equatable, Sendable {
    /// Draw it. `redacted` when previews are hidden, `persistent` in the Alerts style, which stays until closed.
    case show(redacted: Bool, persistent: Bool)
    case suppress(BannerSuppression)

    static func decide(
        authorization: UNAuthorizationStatus, alert: UNNotificationSetting, style: UNAlertStyle,
        previews: UNShowPreviewsSetting, focused: Bool?
    ) -> BannerGate {
        guard authorization == .authorized || authorization == .provisional else { return .suppress(.notAuthorized) }
        guard alert == .enabled else { return .suppress(.alertsOff) }
        guard style != .none else { return .suppress(.styleNone) }
        // Unknown (Focus status not shared with News) counts as not focused.
        if focused == true { return .suppress(.focus) }
        return .show(redacted: previews == .never, persistent: style == .alert)
    }
}

/// The only way to honour Focus: macOS gives an app no notification callback, so the banner asks `INFocusStatusCenter`.
/// It functions with `NSFocusStatusUsageDescription` in Info.plist when signed or entitled (#1214). Banners handle
/// environments without Focus configuration gracefully without error spew.
@MainActor
enum FocusStatus {
    /// Injected provider for unit tests.
    static var provider: (@MainActor () -> Bool?)?

    /// Whether the app possesses the communication notifications entitlement required by DoNotDisturb framework.
    static let hasCommunicationEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let entitlement = "com.apple.developer.usernotifications.communication" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, entitlement, nil) else { return false }
        if let boolVal = value as? Bool { return boolVal }
        return false
    }()

    /// Whether the host application is configured to access Focus status.
    static var isConfigured: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil
    }

    /// Asks once; macOS remembers the answer.
    static func requestAuthorization() {
        guard isConfigured || hasCommunicationEntitlement else { return }
        INFocusStatusCenter.default.requestAuthorization { _ in
            // The answer is read when a banner is drawn.
        }
    }

    /// Whether a Focus is on; nil while the reader has not allowed it, lacks configuration, or shares no Focus status.
    static var isFocused: Bool? {
        if let provider { return provider() }
        guard isConfigured || hasCommunicationEntitlement else { return nil }
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return nil }
        return center.focusStatus.isFocused
    }
}

extension NotificationService {
    /// Draws one banner when the reader's settings allow it. Nothing is added to the notification center. A banner the
    /// settings or a Focus refuse throws `BannerSuppressed`; one that cannot be drawn throws the failure.
    static func deliver(_ banner: StoryBanner) async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let log = StoryBannerPresenter.log
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let sounds = settings.soundSetting == .enabled
        let gate = await MainActor.run {
            BannerGate.decide(
                authorization: settings.authorizationStatus, alert: settings.alertSetting,
                style: settings.alertStyle, previews: settings.showPreviewsSetting, focused: FocusStatus.isFocused)
        }
        switch gate {
        case .suppress(let reason):
            // `route=` is what Export Diagnostics counts.
            log.notice(
                "deliver \(banner.id, privacy: .private(mask: .hash)) route=suppressed_\(reason.rawValue, privacy: .public)"
            )
            throw BannerSuppressed(reason: reason)
        case .show(let redacted, let persistent):
            let drawn = await MainActor.run {
                StoryBannerPresenter.shared.present(redacted ? banner.redacted : banner, persistent: persistent)
            }
            guard drawn else {
                throw NSError(
                    domain: "com.marspater.news.banner", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The banner could not be drawn."])
            }
            log.notice(
                "deliver \(banner.id, privacy: .private(mask: .hash)) route=appBanner redacted=\(redacted, privacy: .public)"
            )
            // Nothing is added, so the system plays no sound: a banner that sounds plays the reader's alert sound,
            // when the reader's settings allow sound.
            if banner.sound, sounds { await MainActor.run { NSSound.beep() } }
        }
    }
}

/// Manages NLP-based notification triage and the app-drawn banners.
final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.marspater.news", category: "NotificationService")
    /// The importance of a text is a pure function of it and costs two language-model passes; Today scores a whole
    /// page on every layout, so the scores are remembered for the life of the process.
    private let importanceScores = OSAllocatedUnfairLock(initialState: [String: Double]())
    /// Draws one banner; the default is the app's own panel and skips unbundled test processes.
    private let post: @Sendable (StoryBanner) async throws -> Void
    /// Pause between two banners of one refresh, so a refresh reads as a trickle of stories, not one burst.
    private let spacing: Duration
    /// Five minutes (#587, docs/notifications.md); a pass of five normal banners takes 20 minutes.
    static let bannerSpacing: Duration = .seconds(5 * 60)

    /// A story this strong is breaking news: it notifies on its own, and its banner sounds and interrupts like any
    /// alert; the rest are passive.
    static let breakingScore = 0.6
    /// An interest story needs this many publishers on its event before it notifies.
    static let interestPublishers = 3
    /// Normal banners in any rolling 60 minutes (#665).
    static let normalLimit = 5
    /// Individual priority banners in any rolling 30 minutes, plus one grouped banner.
    static let priorityLimit = 3
    static let priorityWindow: TimeInterval = 30 * 60
    /// A starred feed gets at most one banner per window.
    static let starredWindow: TimeInterval = 20 * 60

    init(post: (@Sendable (StoryBanner) async throws -> Void)? = nil, spacing: Duration = bannerSpacing) {
        self.post = post ?? { try await NotificationService.deliver($0) }
        self.spacing = spacing
    }

    /// Scores article importance using NLP sentiment intensity + named entity density + breaking news signals.
    /// Returns a 0.0–1.0 score.
    func computeImportance(title: String, description: String) -> Double {
        let fullText = "\(title). \(description)"
        if let known = importanceScores.withLock({ $0[fullText] }) { return known }
        let score = Self.scoreImportance(of: fullText)
        importanceScores.withLock { scores in
            // ponytail: emptied when full rather than evicting by age; a library's listed stories are far fewer.
            if scores.count >= 10_000 { scores.removeAll(keepingCapacity: true) }
            scores[fullText] = score
        }
        return score
    }

    /// Scores a page's stories ahead of the Today layout, across cores and off the caller's thread, so the lane
    /// assignment finds them known (#937). A story scored twice in a race gets the same score both times.
    func prepareImportance(of articles: [FeedArticle]) {
        let texts = articles.map { (title: $0.title, description: $0.description) }
        Task.detached(priority: .userInitiated) {
            DispatchQueue.concurrentPerform(iterations: texts.count) { index in
                _ = self.computeImportance(title: texts[index].title, description: texts[index].description)
            }
        }
    }

    private static func scoreImportance(of fullText: String) -> Double {
        var score: Double = 0.0

        // 1. Sentiment intensity
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = fullText
        let (sentiment, _) = tagger.tag(at: fullText.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let sentimentValue = abs(Double(sentiment?.rawValue ?? "0") ?? 0.0)
        score += sentimentValue * 0.25

        // 2. Named entity density
        let entityTagger = NLTagger(tagSchemes: [.nameType])
        entityTagger.string = fullText
        var entityCount = 0
        entityTagger.enumerateTags(
            in: fullText.startIndex..<fullText.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, _ in
            if let tag = tag, tag == .personalName || tag == .organizationName || tag == .placeName {
                entityCount += 1
            }
            return entityCount < 20
        }
        let entityScore = min(Double(entityCount) / 6.0, 1.0)
        score += entityScore * 0.30

        // 3. Breaking news signal words
        let signalScore = min(Self.breakingSignalWeight(in: fullText) / 3.0, 1.0)
        score += signalScore * 0.30

        // 4. Baseline recency bonus
        score += 0.15

        return min(score, 1.0)
    }

    /// Words that mark breaking news weigh a full point; words that merely mark announcements and office holders
    /// ("president", "announces", "launches") weigh half, so a routine press release does not pass for an alert (#545).
    static let breakingSignals: [String: Double] = [
        "breaking": 1, "just in": 1, "urgent": 1, "dies": 1, "killed": 1, "arrested": 1, "charged": 1, "indicted": 1,
        "resigns": 1, "recalled": 1, "emergency": 1, "crisis": 1, "attack": 1, "explosion": 1, "earthquake": 1,
        "exclusive": 0.5, "confirmed": 0.5, "announces": 0.5, "launches": 0.5, "acquires": 0.5, "fired": 0.5,
        "replace": 0.5, "ceo": 0.5, "president": 0.5, "elected": 0.5,
    ]

    /// Summed weight of the signal words present as whole words: "dies" must not fire on "studies", "diesel" or
    /// "bodies".
    static func breakingSignalWeight(in text: String) -> Double {
        let padded = MuteRules.paddedPhrase(text)
        return breakingSignals.filter { padded.contains(MuteRules.paddedPhrase($0.key)) }.map(\.value).reduce(0, +)
    }

    /// Exceptional news (#665, docs/notifications.md): a score this high, a full-weight signal word in the headline and
    /// this many publishers on the story's event. Stricter than breaking; a story outside any event never qualifies.
    static let priorityScore = 0.75
    static let priorityPublishers = 4

    static func isPriority(title: String, score: Double, publishers: Int) -> Bool {
        guard score >= priorityScore, publishers >= priorityPublishers else { return false }
        let padded = MuteRules.paddedPhrase(title)
        return breakingSignals.contains { $0.value >= 1 && padded.contains(MuteRules.paddedPhrase($0.key)) }
    }

    /// One report per event, the one that scores highest, in first-seen order, with its score; stories outside any
    /// event stand alone. Several publishers covering one story then count once in a summary instead of once each
    /// (#523, #587). Scoring tags every article once, so it runs off the main actor.
    @concurrent nonisolated static func representatives(of articles: [FeedArticle], events: [String: String]) async
        -> [(article: FeedArticle, score: Double)]
    {
        var order: [String] = []
        var best: [String: (article: FeedArticle, score: Double)] = [:]
        for (article, score) in await scored(articles) {
            let key = events[article.id] ?? article.id
            if let current = best[key], current.score >= score { continue }
            if best[key] == nil { order.append(key) }
            best[key] = (article, score)
        }
        return order.compactMap { best[$0] }
    }

    /// Scores each story once, off the main actor (#545).
    @concurrent nonisolated static func scored(_ articles: [FeedArticle]) async -> [(
        article: FeedArticle, score: Double
    )] {
        articles.map { ($0, shared.computeImportance(title: $0.title, description: $0.description)) }
    }

    /// Full-mode delivery (#665): the banners of one pass, in posting order, and the priority keys left waiting. The
    /// rules, with their reasons, are docs/notifications.md; this reads only the delivery and the scored stories.
    static func plan(
        new: [(article: FeedArticle, score: Double)], pending: [String: [(article: FeedArticle, score: Double)]],
        delivery: NotificationDelivery
    ) -> (banners: [PlannedBanner], queued: [QueuedPriority]) {
        var planner = LanePlanner(delivery: delivery)
        let (priorityKeys, normalKeys) = planner.classify(new)
        let queued = planner.planPriority(priorityKeys)
        planner.planStarred(pending)
        planner.planNormal(normalKeys)
        return (planner.banners, queued)
    }

    static func sourceName(_ article: FeedArticle) -> String {
        (article.source.components(separatedBy: "\n").first ?? article.source).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// The headline key recorded for an event when a banner is posted: its lead story's, else the posted report's.
    static func leadKey(of article: FeedArticle, event: String, delivery: NotificationDelivery) -> String {
        EventFeedSummary.titleKey(delivery.leadTitles[event] ?? article.title)
    }

    /// The reader's top interest categories (lowercased raw values) from the Briefing's interest weights, strongest
    /// first; ties break alphabetically so the list is stable.
    static func rankedInterests(_ weights: [String: Int], limit: Int = 3) -> [String] {
        weights.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }

    static func topInterests(_ weights: [String: Int], limit: Int = 3) -> Set<String> {
        Set(rankedInterests(weights, limit: limit))
    }

    /// Dispatches notifications according to the active NotificationMode. Full mode posts the planned banners one at
    /// a time, `spacing` apart (#587), and records each as soon as it posts (#665). Cancelling the pass (quitting)
    /// drops the banners not yet posted.
    func triageAndNotify(newArticles: [FeedArticle], delivery: NotificationDelivery) async {
        guard !newArticles.isEmpty else { return }

        switch delivery.mode {
        case .minimal:
            // ALWAYS exactly one coalesced notification with singular/plural grammar
            let ranked = await Self.representatives(
                of: newArticles, events: delivery.events.mapValues { delivery.stories[$0] ?? $0 })
            // Scoring takes a moment; a pass stopped meanwhile posts nothing.
            guard !Task.isCancelled else { return }
            await triggerMinimalNotification(for: ranked.map(\.article))

        case .privacy:
            // Exactly one generic notification with ZERO identifying source or headline details
            guard !Task.isCancelled else { return }
            await triggerPrivateNotification()

        case .full:
            var pending: [String: [(article: FeedArticle, score: Double)]] = [:]
            for (feed, articles) in delivery.starredPending { pending[feed] = await Self.scored(articles) }
            let plan = Self.plan(new: await Self.scored(newArticles), pending: pending, delivery: delivery)
            guard !Task.isCancelled else { return }
            if !plan.queued.isEmpty { await delivery.queue(plan.queued) }
            for (index, banner) in plan.banners.enumerated() {
                if index > 0 {
                    do {
                        try await Task.sleep(for: spacing)
                    } catch {
                        break  // A cancelled pass must not continue posting old banners.
                    }
                    guard await delivery.continues() else { break }
                }
                guard !Task.isCancelled else { break }
                var banner = banner
                if let story = banner.article { banner.article = await delivery.curated(story) }
                let outcome = await triggerFullNotification(banner, at: delivery.now, continues: delivery.continues)
                // A halt is final: the pass must not wait out another gap and post its old banners once Full is back.
                if outcome == .halted { break }
                if outcome == .posted { await delivery.record(banner) }
            }
        }
    }

    /// Posts one story banner now, outside triage and its limits (Help > Show Sample Notification, Settings >
    /// Notifications > Send Test Notification), so the banner can be checked without waiting for a refresh. Nothing is
    /// recorded in the delivery log, and its own identifier keeps it from replacing or clearing the story's real banner.
    /// `continues` is asked right before the banner shows, as for a real banner, so a reader outside Full mode gets
    /// no headline and no image request.
    @discardableResult
    func postSample(_ article: FeedArticle, continues: @Sendable () async -> Bool) async -> PostOutcome {
        let banner = PlannedBanner(lane: .normal, grouped: false, article: article, thread: "news-sample", sound: false)
        return await triggerFullNotification(banner, at: Date(), identifier: "news-sample", continues: continues)
    }

    /// A random story of the list for a test banner, one with a photo when the list has any (#926).
    static func sampleStory<Generator: RandomNumberGenerator>(
        from stories: [FeedArticle], using generator: inout Generator
    ) -> FeedArticle? {
        let withPhoto = stories.filter { FeedArticle.bestCardImage(in: [$0]) != nil }
        return (withPhoto.isEmpty ? stories : withPhoto).randomElement(using: &generator)
    }

    static func sampleStory(from stories: [FeedArticle]) -> FeedArticle? {
        let withPhoto = stories.filter { FeedArticle.bestCardImage(in: [$0]) != nil }
        return (withPhoto.isEmpty ? stories : withPhoto).randomElement()
    }

    /// What Settings says after a test banner: why nothing showed, or how the reader's notification settings shaped
    /// it. Sentence case, no claim beyond what the outcome and settings show.
    static func sampleStatus(
        _ outcome: PostOutcome, authorization: UNAuthorizationStatus, alert _: UNNotificationSetting,
        style: UNAlertStyle, previews: UNShowPreviewsSetting
    ) -> String {
        let systemSettings = "System Settings › Notifications › News"
        switch outcome {
        case .halted:
            return
                "Not shown: notifications are off or not at Full detail. Turn on Enable Notifications and choose Full."
        case .failed(let domain, let code):
            return "The banner could not be drawn (\(domain) \(code)). Help › Export Diagnostics has the log."
        case .suppressed(let reason):
            switch reason {
            case .notAuthorized:
                return authorization == .notDetermined
                    ? "Not shown: macOS has not asked for permission yet. News asks after the first refresh with stories."
                    : "Not shown: notifications for News are turned off. Allow them in \(systemSettings)."
            case .alertsOff: return "Not shown: alerts for News are off. Turn them on in \(systemSettings)."
            case .styleNone:
                return "Not shown: the alert style is None. Choose Banners or Alerts in \(systemSettings)."
            case .focus: return "Not shown: a Focus is on. News draws no banner until it ends."
            }
        case .posted:
            if previews == .never { return "Shown with the story hidden, as Show Previews asks in \(systemSettings)." }
            return style == .alert
                ? "Shown. It stays until you close it, as the Alerts style asks in \(systemSettings)." : "Shown."
        }
    }

    /// Stable across launches, so a story replaces its earlier banner; `hashValue` is reseeded per process.
    static func notificationIdentifier(for article: FeedArticle) -> String {
        "news-\(article.id)"
    }

    /// Formats the minimal notification summary string with singular/plural grammar.
    static func formatMinimalSummary(articleCount: Int, uniqueSourcesCount: Int) -> String {
        let articleText = articleCount == 1 ? "1 new article" : "\(articleCount) new articles"
        let sourceText: String
        if uniqueSourcesCount == 1 {
            sourceText = "from 1 source"
        } else {
            sourceText = "across \(uniqueSourcesCount) sources"
        }
        return "\(articleText) \(sourceText)"
    }

    private func triggerMinimalNotification(for articles: [FeedArticle]) async {
        // Deduplicate unique sources
        let sources = Set(
            articles.map {
                ($0.source.components(separatedBy: "\n").first ?? $0.source)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        let banner = StoryBanner(
            id: "news-minimal-summary", title: "News Update",
            body: Self.formatMinimalSummary(articleCount: articles.count, uniqueSourcesCount: max(1, sources.count)),
            sound: true)
        await postSummary(banner)
    }

    private func triggerPrivateNotification() async {
        let banner = StoryBanner(
            id: "news-generic-update", title: "News Update", body: "You have new articles available. Open to read.",
            sound: true)
        await postSummary(banner)
    }

    /// A summary banner: no story, no headline and no photo, from Minimal or Private mode.
    private func postSummary(_ banner: StoryBanner) async {
        do {
            try await post(banner)
            logger.debug("Showed summary banner: \(banner.id)")
        } catch {
            logger.error("Failed to show summary banner '\(banner.id)': \(error.localizedDescription)")
        }
    }

    /// The body of a grouped banner: the count, then up to two headlines on their own lines.
    static func groupedBody(_ banner: PlannedBanner) -> String {
        let noun = banner.lane == .priority ? "more major " : "new "
        let count = "\(banner.count) \(noun)\(banner.count == 1 ? "story" : "stories")"
        return ([count] + banner.headlines.prefix(2)).joined(separator: "\n")
    }

    /// How one banner ended: shown, refused on purpose (settings or Focus), failed to draw, or halted because the pass
    /// may not go on.
    enum PostOutcome: Equatable, Sendable {
        case posted, halted
        case suppressed(BannerSuppression)
        /// The error's domain and code, public in the log as well (#926).
        case failed(domain: String, code: Int)
    }

    /// Draws one full-mode banner. The thread groups later reports of the same story under it; a banner with sound
    /// plays the reader's alert sound, one without is silent. `continues` is asked right before the banner shows, so a
    /// reader who switched to Privacy or turned notifications off meanwhile sees no headline; Private and Minimal banners
    /// are never photos, and a story banner asks the photo from the reader's image cache only once it shows.
    private func triggerFullNotification(
        _ banner: PlannedBanner, at now: Date, identifier sampleIdentifier: String? = nil,
        continues: @Sendable () async -> Bool = { true }
    ) async -> PostOutcome {
        var content: StoryBanner
        if let article = banner.article {
            content = StoryBanner(
                id: sampleIdentifier ?? Self.notificationIdentifier(for: article), title: Self.sourceName(article),
                headline: article.title,
                body: article.description.isEmpty ? "" : String(article.description.prefix(200)),
                articleID: article.id, articleLink: article.link,
                // The lead, then the other candidates (#1010): a lead that decodes as a page is not the only photo.
                imageURLs: Array(FeedArticle.attachmentImages(for: article).prefix(3)), actions: true)
        } else {
            // Each group is its own banner; a later group must not replace an earlier one.
            content = StoryBanner(
                id: "\(banner.thread)-\(Int(now.timeIntervalSince1970))", title: banner.title,
                body: Self.groupedBody(banner))
        }
        content.thread = banner.thread
        content.sound = banner.sound
        // Asked right before the banner shows: the settings can change while the pass waits.
        guard await continues(), !Task.isCancelled else { return .halted }
        do {
            try await post(content)
            logger.debug("Showed full banner: \(content.id)")
            return .posted
        } catch let suppressed as BannerSuppressed {
            logger.notice("Banner '\(content.id)' not shown: \(suppressed.reason.rawValue, privacy: .public)")
            return .suppressed(suppressed.reason)
        } catch {
            // The domain and code are public, so `log show` says why it failed (#926); the identifier is not.
            let error = error as NSError
            logger.error(
                "Failed to show full banner '\(content.id)': domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) \(error.localizedDescription)"
            )
            return .failed(domain: error.domain, code: error.code)
        }
    }

    /// Fetches an image and creates a notification attachment, logging the exact failing stage on error (#1010).
    func downloadNotificationAttachment(from url: URL) async -> UNNotificationAttachment? {
        do {
            let (data, response) = try await SecureHTTPClient.shared.fetchImage(from: url, allowHTTP: false)
            try Task.checkCancellation()
            return try Self.makeImageAttachment(data: data, contentType: response.mimeType)
        } catch {
            if !ImageLoadFailure.isCancellation(error) {
                logger.error(
                    "Notification image attachment failed: \(ImageLoadFailure.describe(error), privacy: .public)")
            }
            return nil
        }
    }
}

typealias ScoredStory = (article: FeedArticle, score: Double)

/// One full-mode pass's lane decisions (#665, docs/notifications.md), filled lane by lane in posting order.
private struct LanePlanner {
    let delivery: NotificationDelivery
    var banners: [PlannedBanner] = []
    /// Stories a banner of this pass already covers.
    var taken = Set<String>()
    /// Story → the highest lane any of its events was announced in during the last 24 h.
    let storyLanes: [String: NotificationLane]

    init(delivery: NotificationDelivery) {
        self.delivery = delivery
        storyLanes = delivery.ledger.announced.reduce(into: [:]) { lanes, entry in
            let story = delivery.stories[entry.key] ?? entry.key
            lanes[story] = max(lanes[story] ?? entry.value.lane, entry.value.lane)
        }
    }

    /// The event a story is announced and queued under; the story itself outside any event.
    func key(_ article: FeedArticle) -> String { delivery.events[article.id] ?? article.id }

    /// The story the event belongs to (#740): banners group, dedupe and thread by it, so two events of one story
    /// notify once.
    func story(_ article: FeedArticle) -> String {
        let event = key(article)
        return delivery.stories[event] ?? event
    }

    func lead(_ article: FeedArticle) -> String {
        NotificationService.leadKey(of: article, event: key(article), delivery: delivery)
    }

    /// The keys a banner announces: the story itself and its event, if any, so any event the story is in later counts
    /// as announced (#790).
    func announces(_ article: FeedArticle) -> [String: String] {
        Dictionary([(key(article), lead(article)), (article.id, lead(article))]) { first, _ in first }
    }

    func publishers(_ article: FeedArticle) -> Int {
        delivery.events[article.id].flatMap { delivery.publishers[$0] } ?? 1
    }

    /// Whether the story's key may post in `lane`: not announced, a new lead headline, or a higher lane. A new event of
    /// a story another of whose events was announced adds to that story and posts only in a higher lane (#740).
    func fresh(_ article: FeedArticle, in lane: NotificationLane) -> Bool {
        if let seen = delivery.ledger.announced[key(article)] {
            // A new lead notifies again; a higher lane only above the story's highest announced lane.
            return seen.leadKey != lead(article) || lane > max(seen.lane, storyLanes[story(article)] ?? seen.lane)
        }
        return storyLanes[story(article)].map { lane > $0 } ?? true
    }

    func isPriority(_ item: ScoredStory) -> Bool {
        delivery.events[item.article.id] != nil
            && NotificationService.isPriority(
                title: item.article.title, score: item.score, publishers: publishers(item.article))
    }

    func isNormal(_ item: ScoredStory) -> Bool {
        let category = item.article.category.flatMap(NewsCategory.match(from:))?.rawValue.lowercased()
        let interest =
            category.map(delivery.interests.contains) == true
            && publishers(item.article) >= NotificationService.interestPublishers
        return item.score >= NotificationService.breakingScore || interest
    }

    func isStarred(_ article: FeedArticle) -> Bool {
        article.identityFeedURL.map(delivery.starredFeedURLs.contains) == true
    }

    /// Each key takes its highest lane; its representative is the strongest story that qualifies for that lane. Keys
    /// with a starred story belong to the starred lane, which works from the feeds' pending stories.
    func classify(_ new: [ScoredStory]) -> (priority: [ScoredStory], normal: [ScoredStory]) {
        var order: [String] = []
        var members: [String: [ScoredStory]] = [:]
        for item in new {
            if members[story(item.article)] == nil { order.append(story(item.article)) }
            members[story(item.article), default: []].append(item)
        }
        var priority: [ScoredStory] = []
        var normal: [ScoredStory] = []
        for id in order {
            // The representative is the strongest story of the key's lane that may still post: in a story of two
            // events, an unchanged announced event must not hide the other event's new lead headline (#740). A starred
            // story leaves the key to the starred lane only while it may still post there; a stale priority event
            // leaves its siblings to the lower lanes.
            let items = members[id, default: []].sorted { $0.score > $1.score }
            if let best = items.first(where: { isPriority($0) && fresh($0.article, in: .priority) }) {
                priority.append(best)
            } else if !items.contains(where: { isStarred($0.article) && fresh($0.article, in: .starred) }),
                let best = items.first(where: { isNormal($0) && fresh($0.article, in: .normal) })
            {
                normal.append(best)
            }
        }
        return (priority.sorted { $0.score > $1.score }, normal)
    }

    /// Individual banners up to the limit, then one grouped banner for the rest and any waiting keys. Returns the keys
    /// that must wait because the grouped banner's window is still running.
    mutating func planPriority(_ keys: [ScoredStory]) -> [QueuedPriority] {
        let ledger = delivery.ledger
        let individual = keys.prefix(max(0, NotificationService.priorityLimit - ledger.priorityLastHalfHour))
        for item in individual {
            banners.append(
                PlannedBanner(
                    lane: .priority, grouped: false, article: item.article, thread: story(item.article), sound: true,
                    announces: announces(item.article)))
            taken.insert(story(item.article))
        }
        let newOverflow = keys.dropFirst(individual.count).map {
            QueuedPriority(
                event: key($0.article), title: $0.article.title, score: $0.score, leadKey: lead($0.article),
                story: $0.article.id)
        }
        // A waiting key drops out when this pass already covers its story, by a banner or a new key of another of
        // the story's events, or when the story was announced in the priority lane, unless the key's own event was
        // announced under another lead headline: that change may notify again (#740).
        let stories = delivery.stories
        let story = { (event: String) in stories[event] ?? event }
        let newStories = Set(newOverflow.map { story($0.event) })
        let waiting = ledger.priorityQueue.filter { item in
            !newStories.contains(story(item.event)) && !taken.contains(story(item.event))
                && (storyLanes[story(item.event)] != .priority
                    || ledger.announced[item.event].map { $0.leadKey != item.leadKey } == true)
        }
        let overflow = (newOverflow + waiting).sorted { $0.score > $1.score }
        guard !overflow.isEmpty else { return [] }
        if ledger.priorityGroupLastHalfHour { return newOverflow }
        // The queue may hold two events of one story from earlier passes; the banner counts and names each story
        // once, its strongest key, and announces every key it covers.
        var named = Set<String>()
        let perStory = overflow.filter { named.insert(story($0.event)).inserted }
        banners.append(
            PlannedBanner(
                lane: .priority, grouped: true, title: "Major news", headlines: perStory.prefix(2).map(\.title),
                count: perStory.count, thread: "priority", sound: true,
                announces: Dictionary(
                    overflow.flatMap { [($0.event, $0.leadKey), ($0.story, $0.leadKey)] }.filter { !$0.0.isEmpty }
                ) { first, _ in first },
                members: overflow.map(\.story).filter { !$0.isEmpty }))
        taken.formUnion(overflow.map { delivery.stories[$0.event] ?? $0.event })
        return []
    }

    /// One banner per feed and window, standing for every pending story, once one of them is fresh.
    mutating func planStarred(_ pending: [String: [ScoredStory]]) {
        for feed in delivery.starredFeedURLs.sorted() {
            if let last = delivery.ledger.lastStarred[feed],
                delivery.now.timeIntervalSince(last) < NotificationService.starredWindow
            {
                continue
            }
            planStarredFeed(feed, items: (pending[feed] ?? []).sorted { $0.score > $1.score })
        }
    }

    private mutating func planStarredFeed(_ feed: String, items: [ScoredStory]) {
        var seen = Set<String>()
        let freshItems = items.filter {
            !taken.contains(story($0.article)) && fresh($0.article, in: .starred)
                && seen.insert(story($0.article)).inserted
        }
        guard let top = freshItems.first else { return }
        let covered = freshItems.reduce(into: [String: String]()) { $0.merge(announces($1.article)) { a, _ in a } }
        if items.count == 1 {
            banners.append(
                PlannedBanner(
                    lane: .starred, grouped: false, article: top.article, feedURL: feed, thread: story(top.article),
                    sound: top.score >= NotificationService.breakingScore, announces: covered))
        } else {
            let rest = items.filter { item in !freshItems.contains { $0.article.id == item.article.id } }
            banners.append(
                PlannedBanner(
                    lane: .starred, grouped: true, title: NotificationService.sourceName(top.article),
                    headlines: (freshItems + rest).prefix(2).map(\.article.title), count: items.count, feedURL: feed,
                    thread: "starred-\(feed)", sound: false, announces: covered, members: items.map(\.article.id)))
        }
        taken.formUnion(freshItems.map { story($0.article) })
    }

    /// Today's qualification, up to the rolling hour's remaining allowance.
    mutating func planNormal(_ keys: [ScoredStory]) {
        let allowance = max(0, NotificationService.normalLimit - delivery.ledger.normalLastHour)
        for item in keys.filter({ !taken.contains(story($0.article)) }).sorted(by: { $0.score > $1.score })
            .prefix(allowance)
        {
            banners.append(
                PlannedBanner(
                    lane: .normal, grouped: false, article: item.article, thread: story(item.article),
                    sound: item.score >= NotificationService.breakingScore, announces: announces(item.article)))
        }
    }
}
