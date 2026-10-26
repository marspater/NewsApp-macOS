import Foundation
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers
import UserNotifications
import os

/// What a refresh hands the notification service besides the new stories: the mode, the event of each story (so one
/// event notifies once and later reports thread under the first banner, #587) and what full-mode triage reads
/// (#588). Everything here comes from the reader's own library and settings.
struct NotificationDelivery: Sendable {
    var mode: AppSettings.NotificationMode
    /// Story id → event id, for stories clustering has grouped; a story outside any event is absent.
    var events: [String: String] = [:]
    /// Event id → number of distinct publishers among its members.
    var publishers: [String: Int] = [:]
    /// The reader's top interest categories, lowercased `NewsCategory` raw values.
    var interests: Set<String> = []
    /// Feeds whose every story notifies.
    var starredFeedURLs: Set<String> = []
    /// Events notified in the last day → the headline key (`EventFeedSummary.titleKey`) of their lead story then.
    var notifiedEvents: [String: String] = [:]
    /// Event id → the title of its lead story now (the story that opened the event).
    var leadTitles: [String: String] = [:]
    /// Called with the stories posted as banners, so the refresh can record their events.
    var recordPosted: @Sendable ([FeedArticle]) async -> Void = { _ in }
}

/// Manages NLP-based notification triage, rich image attachments, and alert scheduling.
final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.marspater.news", category: "NotificationService")
    /// Posts one request; the default goes to the user notification center and skips unbundled test processes.
    private let post: @Sendable (UNNotificationRequest) async throws -> Void
    /// Pause between two banners of one refresh: posted at once, macOS stacks them and one hides behind the other.
    private let spacing: Duration

    /// A story this strong is breaking news: it notifies on its own, and its banner sounds and interrupts like any
    /// alert; the rest are passive.
    static let breakingScore = 0.6
    /// An interest story needs this many publishers on its event before it notifies.
    static let interestPublishers = 3
    /// Banners per refresh in full mode; starred feeds are not counted.
    static let bannerLimit = 5

    init(
        post: (@Sendable (UNNotificationRequest) async throws -> Void)? = nil, spacing: Duration = .seconds(2)
    ) {
        self.post =
            post ?? { request in
                guard Bundle.main.bundleIdentifier != nil else { return }
                try await UNUserNotificationCenter.current().add(request)
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

    /// One report per event, the one that scores highest, in first-seen order, with its score; stories outside any
    /// event stand alone. Several publishers covering one story then notify once instead of once each (#523), in
    /// every mode (#587). Scoring tags every article once, so it runs off the main actor.
    @concurrent nonisolated static func representatives(of articles: [FeedArticle], events: [String: String]) async
        -> [(article: FeedArticle, score: Double)]
    {
        var order: [String] = []
        var best: [String: (article: FeedArticle, score: Double)] = [:]
        for article in articles {
            let key = events[article.id] ?? article.id
            let score = shared.computeImportance(title: article.title, description: article.description)
            if let current = best[key], current.score >= score { continue }
            if best[key] == nil { order.append(key) }
            best[key] = (article, score)
        }
        return order.compactMap { best[$0] }
    }

    /// Full-mode triage (#588): a story notifies when its feed is starred, when it is breaking (score ≥ 0.6), or when
    /// it is in one of the reader's top interest categories and three or more publishers cover its event. Everything
    /// else is silent. Starred feeds are not counted against the banner limit. Otherwise an event notified in the last
    /// day stays quiet while its lead headline is the one notified; a new lead headline notifies again (#545).
    static func triage(_ ranked: [(article: FeedArticle, score: Double)], delivery: NotificationDelivery)
        -> [(article: FeedArticle, score: Double)]
    {
        var chosen: [(article: FeedArticle, score: Double)] = []
        var budget = bannerLimit
        for item in ranked {
            let article = item.article
            if let feed = article.identityFeedURL, delivery.starredFeedURLs.contains(feed) {
                chosen.append(item)
                continue
            }
            if let event = delivery.events[article.id], let notified = delivery.notifiedEvents[event],
                notified == leadKey(of: article, event: event, delivery: delivery)
            {
                continue
            }
            guard budget > 0 else { continue }
            let category = article.category.flatMap(NewsCategory.match(from:))?.rawValue.lowercased()
            let publishers = delivery.events[article.id].flatMap { delivery.publishers[$0] } ?? 1
            let interest = category.map(delivery.interests.contains) == true && publishers >= interestPublishers
            guard item.score >= breakingScore || interest else { continue }
            chosen.append(item)
            budget -= 1
        }
        return chosen
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

    /// NLP-driven triage: dispatches notifications according to the active NotificationMode. Full mode posts the
    /// triaged reports one at a time, a pause apart, each threaded under its story.
    func triageAndNotify(newArticles: [FeedArticle], delivery: NotificationDelivery) async {
        guard !newArticles.isEmpty else { return }
        let ranked = await Self.representatives(of: newArticles, events: delivery.events)

        switch delivery.mode {
        case .minimal:
            // ALWAYS exactly one coalesced notification with singular/plural grammar
            await triggerMinimalNotification(for: ranked.map(\.article))

        case .privacy:
            // Exactly one generic notification with ZERO identifying source or headline details
            await triggerPrivateNotification()

        case .full:
            let toNotify = Self.triage(ranked.sorted { $0.score > $1.score }, delivery: delivery)
            var posted: [FeedArticle] = []
            for (index, item) in toNotify.enumerated() {
                if index > 0 { try? await Task.sleep(for: spacing) }
                guard !Task.isCancelled else { break }
                if await triggerFullNotification(
                    for: item.article, thread: delivery.events[item.article.id] ?? item.article.id,
                    breaking: item.score >= Self.breakingScore)
                {
                    posted.append(item.article)
                }
            }
            if !posted.isEmpty { await delivery.recordPosted(posted) }
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

    /// Posts one banner. The thread groups later reports of the same story under it in Notification Center; a
    /// breaking story sounds and interrupts like any alert, a lesser one is passive (listed, no sound, no wake).
    private func triggerFullNotification(for article: FeedArticle, thread: String, breaking: Bool) async -> Bool {
        let content = UNMutableNotificationContent()

        let sourceName = (article.source.components(separatedBy: "\n").first ?? article.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        content.title = sourceName
        content.subtitle = article.title
        content.body = article.description.isEmpty ? "" : String(article.description.prefix(200))
        content.sound = breaking ? .default : nil
        content.threadIdentifier = thread
        content.interruptionLevel = breaking ? .active : .passive
        content.userInfo = ["articleLink": article.link, "articleID": article.id]

        if let imageUrl = FeedArticle.bestCardImage(in: [article]),
            let attachment = await downloadNotificationAttachment(from: imageUrl)
        {
            content.attachments = [attachment]
        }

        let identifier = Self.notificationIdentifier(for: article)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await post(request)
            logger.debug(
                "Successfully scheduled full notification: \(identifier); attachments=\(content.attachments.count)")
            return true
        } catch {
            logger.error("Failed to schedule full notification '\(identifier)': \(error.localizedDescription)")
            return false
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

    /// Notification attachments do not support every format the protected reader can decode (notably WebP/AVIF).
    static func makeImageAttachment(data: Data) throws -> UNNotificationAttachment {
        let image = try SecureHTTPClient.decodeReaderImage(data)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= 10_000_000 else {
            throw URLError(.cannotDecodeContentData)
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try (encoded as Data).write(to: fileURL)
            // The notification framework takes ownership after successful attachment creation.
            return try UNNotificationAttachment(identifier: UUID().uuidString, url: fileURL, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }
}
