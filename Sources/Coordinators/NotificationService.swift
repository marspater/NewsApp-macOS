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

import AppKit
import Foundation
import NaturalLanguage
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

/// Where a story banner is drawn (#926, DESIGN.md 8.7). macOS asks `willPresent` only while News is the active app, so
/// with a News window on screen behind another app the decision is made here, when the notification is posted.
enum StoryBannerRoute: Equatable, Sendable {
    /// The app drew the banner and nothing was added: macOS has no API to file a notification in Notification Center
    /// without its banner outside `willPresent`. The story stays in Today and Unread.
    case appBanner
    /// Added to the notification center: the system draws the banner, or `willPresent` hands it to the app while
    /// News is active.
    case notificationCenter

    /// The reader's settings under which the app may draw a story banner: banners on, in the Banners style (an Alert
    /// stays until dismissed, as the system draws it) and with previews shown (hidden previews redact).
    static func allowsAppBanner(
        alert: UNNotificationSetting, style: UNAlertStyle, previews: UNShowPreviewsSetting
    ) -> Bool {
        alert == .enabled && style == .banner && previews != .never
    }

    /// Delivers one request. Only a story's own banner (the one carrying Save, Mark as Read and Open), posted while
    /// News is not active, is offered to `present`, which draws it when a News window is open on screen; anything it
    /// declines is added, so there is always exactly one banner.
    static func deliver(
        _ request: UNNotificationRequest, active: Bool,
        settings: @Sendable () async -> (UNNotificationSetting, UNAlertStyle, UNShowPreviewsSetting),
        present: @Sendable (UNNotificationRequest) async -> Bool,
        add: @Sendable (UNNotificationRequest) async throws -> Void
    ) async throws -> StoryBannerRoute {
        if !active, request.content.categoryIdentifier == NotificationActionIdentifier.category {
            let (alert, style, previews) = await settings()
            if allowsAppBanner(alert: alert, style: style, previews: previews), await present(request) {
                return .appBanner
            }
        }
        try await add(request)
        return .notificationCenter
    }
}

/// Manages NLP-based notification triage, rich image attachments, and alert scheduling.
final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.marspater.news", category: "NotificationService")
    /// Posts one request; the default goes to the user notification center and skips unbundled test processes.
    private let post: @Sendable (UNNotificationRequest) async throws -> Void
    /// Pause between two banners of one refresh, so a refresh reads as a trickle of stories, not one burst.
    private let spacing: Duration
    /// Five minutes (#587, docs/notifications.md); a pass of five normal banners takes 20 minutes.
    static let bannerSpacing: Duration = .seconds(5 * 60)

    /// A story this strong is breaking news: it notifies on its own, and its banner sounds and interrupts like any
    /// alert; the rest are passive.
    static let breakingScore = 0.6
    /// An interest story needs this many publishers on its event before it notifies.
    static let interestPublishers = 3
    /// Largest encoded notification image attachment in bytes; the same ceiling as the image fetch, so the two agree.
    static let attachmentLimit = Int(SecureHTTPClient.defaultImageLimit)
    /// Normal banners in any rolling 60 minutes (#665).
    static let normalLimit = 5
    /// Individual priority banners in any rolling 30 minutes, plus one grouped banner.
    static let priorityLimit = 3
    static let priorityWindow: TimeInterval = 30 * 60
    /// A starred feed gets at most one banner per window.
    static let starredWindow: TimeInterval = 20 * 60

    /// Draws a story banner in the app and says whether it did; installed by the app delegate, which owns the
    /// presenter. Nil (tests, helper processes) leaves every banner to the system.
    @MainActor static var presentAppBanner: ((UNNotificationRequest) -> Bool)?

    init(
        post: (@Sendable (UNNotificationRequest) async throws -> Void)? = nil, spacing: Duration = bannerSpacing
    ) {
        self.post =
            post ?? { request in
                guard Bundle.main.bundleIdentifier != nil else { return }
                let log = Logger(subsystem: "com.marspater.news", category: "StoryBanner")
                let active = await MainActor.run { NSApplication.shared.isActive }
                log.notice(
                    "post \(request.identifier, privacy: .private(mask: .hash)) active=\(active, privacy: .public) level=\(request.content.interruptionLevel.rawValue, privacy: .public)"
                )
                // macOS skipped `willPresent` for a post made while News was behind another app (#926, log of
                // 3 November), so the app decides here.
                let route = try await StoryBannerRoute.deliver(
                    request, active: active,
                    settings: {
                        let settings = await UNUserNotificationCenter.current().notificationSettings()
                        return (settings.alertSetting, settings.alertStyle, settings.showPreviewsSetting)
                    },
                    present: { request in
                        // A request is immutable once made (its content is copied in), so the main actor may read it.
                        nonisolated(unsafe) let request = request
                        return await MainActor.run { NotificationService.presentAppBanner?(request) ?? false }
                    },
                    add: { try await UNUserNotificationCenter.current().add($0) })
                log.notice(
                    "posted \(request.identifier, privacy: .private(mask: .hash)) route=\(String(describing: route), privacy: .public)"
                )
            }
        self.spacing = spacing
    }

    /// Scores article importance using NLP sentiment intensity + named entity density + breaking news signals.
    /// Returns a 0.0–1.0 score.
    func computeImportance(title: String, description: String) -> Double {
        let fullText = "\(title). \(description)"
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
            if !plan.queued.isEmpty { await delivery.queue(plan.queued) }
            for (index, banner) in plan.banners.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: spacing)
                    guard await delivery.continues() else { break }
                }
                guard !Task.isCancelled else { break }
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
    /// `continues` is asked before the image download and the post, as for a real banner, so a reader outside Full
    /// mode gets no headline and no image request.
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
        var generator = SystemRandomNumberGenerator()
        return sampleStory(from: stories, using: &generator)
    }

    /// What Settings says after a test banner: why nothing was sent, why macOS refused it, or what the reader's
    /// notification settings make of it. Sentence case, no claim beyond what the outcome and settings show.
    static func sampleStatus(
        _ outcome: PostOutcome, authorization: UNAuthorizationStatus, alert: UNNotificationSetting, style: UNAlertStyle,
        previews: UNShowPreviewsSetting
    ) -> String {
        let systemSettings = "System Settings › Notifications › News"
        switch outcome {
        case .halted:
            return
                "Not sent: notifications are off or not at Full detail. Turn on Enable Notifications and choose Full."
        case .failed(let domain, let code):
            if domain == UNErrorDomain, code == UNError.Code.notificationsNotAllowed.rawValue {
                return "macOS refused it: notifications for News are not allowed. Allow them in \(systemSettings)."
            }
            return "macOS refused it (\(domain) \(code)). Help › Export Diagnostics has the log."
        case .posted:
            break
        }
        switch authorization {
        case .denied: return "Sent, but notifications for News are turned off. Allow them in \(systemSettings)."
        case .notDetermined:
            return "Sent, but macOS has not asked for permission yet. News asks after the first refresh with stories."
        default: break
        }
        if alert != .enabled { return "Sent, but alerts for News are off. Turn them on in \(systemSettings)." }
        switch style {
        case .none: return "Sent, but the alert style is None, so nothing shows. Choose Banners in \(systemSettings)."
        case .alert: return "Sent. macOS shows it as an alert that stays until dismissed."
        default: break
        }
        if previews == .never {
            return "Sent. macOS shows it as a banner with hidden previews; News does not draw its own banner then."
        }
        return
            "Sent. With News in front, or a News window open behind another app, News draws the banner itself; otherwise macOS shows it."
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
        let content = UNMutableNotificationContent()
        content.title = "News Update"

        // Deduplicate unique sources
        let sources = Set(
            articles.map {
                ($0.source.components(separatedBy: "\n").first ?? $0.source)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })

        content.body = Self.formatMinimalSummary(
            articleCount: articles.count, uniqueSourcesCount: max(1, sources.count))
        content.sound = .default

        let identifier = "news-minimal-summary"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await post(request)
            logger.debug("Successfully scheduled minimal notification: \(identifier)")
        } catch {
            logger.error("Failed to schedule minimal notification '\(identifier)': \(error.localizedDescription)")
        }
    }

    private func triggerPrivateNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "News Update"
        content.body = "You have new articles available. Open to read."
        content.sound = .default

        let identifier = "news-generic-update"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await post(request)
            logger.debug("Successfully scheduled private notification: \(identifier)")
        } catch {
            logger.error("Failed to schedule private notification '\(identifier)': \(error.localizedDescription)")
        }
    }

    /// The body of a grouped banner: the count, then up to two headlines on their own lines.
    static func groupedBody(_ banner: PlannedBanner) -> String {
        let noun = banner.lane == .priority ? "more major " : "new "
        let count = "\(banner.count) \(noun)\(banner.count == 1 ? "story" : "stories")"
        return ([count] + banner.headlines.prefix(2)).joined(separator: "\n")
    }

    /// Posts one banner. The thread groups later reports of the same story under it in Notification Center; a banner
    /// with sound interrupts like any alert, one without is passive (listed, no sound, no wake).
    /// Posts one full-mode banner; `continues` is asked again right before the post, after the image download,
    /// so a reader who switched to Privacy or turned notifications off during the download sees no headline.
    /// How one banner ended: posted, refused by the notification center, or halted because the pass may not go on.
    enum PostOutcome: Equatable, Sendable {
        case posted, halted
        /// The error's domain and code, public in the log as well (#926).
        case failed(domain: String, code: Int)
    }

    private func triggerFullNotification(
        _ banner: PlannedBanner, at now: Date, identifier sampleIdentifier: String? = nil,
        continues: @Sendable () async -> Bool = { true }
    ) async -> PostOutcome {
        let content = UNMutableNotificationContent()
        content.sound = banner.sound ? .default : nil
        content.threadIdentifier = banner.thread
        // The Help sample is active: macOS may deliver a passive notification without asking the app (#926).
        content.interruptionLevel = banner.sound || sampleIdentifier != nil ? .active : .passive
        let identifier: String
        if let article = banner.article {
            content.title = Self.sourceName(article)
            content.subtitle = article.title
            content.body = article.description.isEmpty ? "" : String(article.description.prefix(200))
            content.userInfo = ["articleLink": article.link, "articleID": article.id]
            // Save, Mark as Read and Open (#560) act on one story, so only a story's own banner carries them.
            content.categoryIdentifier = NotificationActionIdentifier.category
            // No image request once the reader has left Full mode (PRIVACY.md): asked right before the download.
            guard await continues(), !Task.isCancelled else { return .halted }
            if let imageUrl = FeedArticle.bestCardImage(in: [article]),
                let attachment = await downloadNotificationAttachment(from: imageUrl)
            {
                content.attachments = [attachment]
                // The app-drawn banner loads the photo again through the reader's image cache.
                content.userInfo["imageURL"] = imageUrl.absoluteString
            }
            identifier = sampleIdentifier ?? Self.notificationIdentifier(for: article)
        } else {
            content.title = banner.title
            content.body = Self.groupedBody(banner)
            // Each group is its own banner; a later group must not replace an earlier one.
            identifier = "\(banner.thread)-\(Int(now.timeIntervalSince1970))"
        }
        // Every banner, grouped ones included, asks right before posting: the image download swallows
        // cancellation, and the settings can change while it runs or while the banner was prepared. Cancellation
        // is read again after the callback, which may have suspended across a stop.
        guard await continues(), !Task.isCancelled else { return .halted }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await post(request)
            logger.debug(
                "Successfully scheduled full notification: \(identifier); attachments=\(content.attachments.count)")
            return .posted
        } catch {
            // The domain and code are public, so `log show` says why macOS refused it (#926); the identifier is not.
            let error = error as NSError
            logger.error(
                "Failed to schedule full notification '\(identifier)': domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) \(error.localizedDescription)"
            )
            return .failed(domain: error.domain, code: error.code)
        }
    }

    private func downloadNotificationAttachment(from url: URL) async -> UNNotificationAttachment? {
        do {
            let (data, _) = try await SecureHTTPClient.shared.fetchImage(from: url, allowHTTP: false)
            try Task.checkCancellation()
            return try Self.makeImageAttachment(data: data)
        } catch {
            let error = error as NSError
            logger.error(
                "Notification image attachment failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
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
