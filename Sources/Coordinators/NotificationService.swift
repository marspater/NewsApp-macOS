import CoreImage
import CoreImage.CIFilterBuiltins
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
    /// Normal banners in any rolling 60 minutes (#665).
    static let normalLimit = 5
    /// Individual priority banners in any rolling 30 minutes, plus one grouped banner.
    static let priorityLimit = 3
    static let priorityWindow: TimeInterval = 30 * 60
    /// A starred feed gets at most one banner per window.
    static let starredWindow: TimeInterval = 20 * 60

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
    /// a time, a pause apart (#587), and records each as soon as it posts (#665).
    func triageAndNotify(newArticles: [FeedArticle], delivery: NotificationDelivery) async {
        guard !newArticles.isEmpty else { return }

        switch delivery.mode {
        case .minimal:
            // ALWAYS exactly one coalesced notification with singular/plural grammar
            let ranked = await Self.representatives(of: newArticles, events: delivery.events)
            await triggerMinimalNotification(for: ranked.map(\.article))

        case .privacy:
            // Exactly one generic notification with ZERO identifying source or headline details
            await triggerPrivateNotification()

        case .full:
            var pending: [String: [(article: FeedArticle, score: Double)]] = [:]
            for (feed, articles) in delivery.starredPending { pending[feed] = await Self.scored(articles) }
            let plan = Self.plan(new: await Self.scored(newArticles), pending: pending, delivery: delivery)
            if !plan.queued.isEmpty { await delivery.queue(plan.queued) }
            for (index, banner) in plan.banners.enumerated() {
                if index > 0 { try? await Task.sleep(for: spacing) }
                guard !Task.isCancelled else { break }
                if await triggerFullNotification(banner, at: delivery.now) { await delivery.record(banner) }
            }
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

    /// The body of a grouped banner: the count, then up to two headlines on their own lines.
    static func groupedBody(_ banner: PlannedBanner) -> String {
        let noun = banner.lane == .priority ? "more major " : "new "
        let count = "\(banner.count) \(noun)\(banner.count == 1 ? "story" : "stories")"
        return ([count] + banner.headlines.prefix(2)).joined(separator: "\n")
    }

    /// Posts one banner. The thread groups later reports of the same story under it in Notification Center; a banner
    /// with sound interrupts like any alert, one without is passive (listed, no sound, no wake).
    private func triggerFullNotification(_ banner: PlannedBanner, at now: Date) async -> Bool {
        let content = UNMutableNotificationContent()
        content.sound = banner.sound ? .default : nil
        content.threadIdentifier = banner.thread
        content.interruptionLevel = banner.sound ? .active : .passive
        let identifier: String
        if let article = banner.article {
            content.title = Self.sourceName(article)
            content.subtitle = article.title
            content.body = article.description.isEmpty ? "" : String(article.description.prefix(200))
            content.userInfo = ["articleLink": article.link, "articleID": article.id]
            // Save, Mark as Read and Open (#560) act on one story, so only a story's own banner carries them.
            content.categoryIdentifier = NotificationActionIdentifier.category
            if let imageUrl = FeedArticle.bestCardImage(in: [article]),
                let attachment = await downloadNotificationAttachment(from: imageUrl)
            {
                content.attachments = [attachment]
            }
            identifier = Self.notificationIdentifier(for: article)
        } else {
            content.title = banner.title
            content.body = Self.groupedBody(banner)
            // Each group is its own banner; a later group must not replace an earlier one.
            identifier = "\(banner.thread)-\(Int(now.timeIntervalSince1970))"
        }
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
    /// The attachment is the tall fading crop of `notificationImage`, or the decoded image when the source is small.
    static func makeImageAttachment(data: Data) throws -> UNNotificationAttachment {
        let decoded = try SecureHTTPClient.decodeReaderImage(data)
        let image = notificationImage(decoded) ?? decoded
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

    /// Short side a source needs for the tall crop; smaller images stay as they are.
    static let notificationImageMinimumSide = 300
    /// Rendered width of the tall crop; the height is 1.5 times it.
    static let notificationImageWidth = 600

    /// A portrait crop (2:3) of the image, at most 600 × 900, that blurs progressively and fades to transparent toward
    /// its trailing edge (#589). macOS has no custom banner layout, so the effect is baked into the PNG the system
    /// places as the thumbnail. Rendered on the CPU, so the same input gives the same bytes. nil when the source's
    /// short side is under 300 px, when the square the system shows is the better choice.
    static func notificationImage(_ image: CGImage) -> CGImage? {
        guard min(image.width, image.height) >= notificationImageMinimumSide else { return nil }
        let width = Double(image.width)
        let height = Double(image.height)
        var cropWidth = width
        var cropHeight = height
        if cropWidth / cropHeight > 2.0 / 3.0 { cropWidth = cropHeight * 2 / 3 } else { cropHeight = cropWidth * 3 / 2 }
        let crop = CGRect(
            x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, width: cropWidth, height: cropHeight
        ).integral
        guard let cropped = image.cropping(to: crop) else { return nil }
        let scale = min(1, Double(notificationImageWidth) / Double(cropped.width))
        let source = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = source.extent.integral
        // Blur rises from nothing at 55% of the width to full at the trailing edge; the fade starts at 70%.
        func ramp(from start: Double) -> CIImage? {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: extent.minX + extent.width * start, y: extent.midY)
            gradient.point1 = CGPoint(x: extent.maxX, y: extent.midY)
            gradient.color0 = .black
            gradient.color1 = .white
            return gradient.outputImage?.cropped(to: extent)
        }
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = source
        blur.mask = ramp(from: 0.55)
        blur.radius = 18
        let fade = CIFilter.blendWithMask()
        fade.inputImage = CIImage(color: .clear).cropped(to: extent)
        fade.backgroundImage = blur.outputImage?.cropped(to: extent)
        fade.maskImage = ramp(from: 0.7)
        guard let output = fade.outputImage?.cropped(to: extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        return context.createCGImage(
            output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

typealias ScoredStory = (article: FeedArticle, score: Double)

/// One full-mode pass's lane decisions (#665, docs/notifications.md), filled lane by lane in posting order.
private struct LanePlanner {
    let delivery: NotificationDelivery
    var banners: [PlannedBanner] = []
    /// Keys a banner of this pass already covers.
    var taken = Set<String>()

    init(delivery: NotificationDelivery) { self.delivery = delivery }

    func key(_ article: FeedArticle) -> String { delivery.events[article.id] ?? article.id }

    func lead(_ article: FeedArticle) -> String {
        NotificationService.leadKey(of: article, event: key(article), delivery: delivery)
    }

    func announces(_ article: FeedArticle) -> [String: String] {
        delivery.events[article.id].map { [$0: lead(article)] } ?? [:]
    }

    func publishers(_ article: FeedArticle) -> Int {
        delivery.events[article.id].flatMap { delivery.publishers[$0] } ?? 1
    }

    /// Whether the story's key may post in `lane`: not announced, a new lead headline, or a higher lane.
    func fresh(_ article: FeedArticle, in lane: NotificationLane) -> Bool {
        guard let event = delivery.events[article.id], let seen = delivery.ledger.announced[event] else { return true }
        return seen.leadKey != lead(article) || lane > seen.lane
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
            if members[key(item.article)] == nil { order.append(key(item.article)) }
            members[key(item.article), default: []].append(item)
        }
        var priority: [ScoredStory] = []
        var normal: [ScoredStory] = []
        for id in order {
            let items = members[id, default: []].sorted { $0.score > $1.score }
            if let best = items.first(where: isPriority) {
                if fresh(best.article, in: .priority) { priority.append(best) }
            } else if !items.contains(where: { isStarred($0.article) }), let best = items.first(where: isNormal),
                fresh(best.article, in: .normal)
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
                    lane: .priority, grouped: false, article: item.article, thread: key(item.article), sound: true,
                    announces: announces(item.article)))
            taken.insert(key(item.article))
        }
        let newOverflow = keys.dropFirst(individual.count).map {
            QueuedPriority(
                event: key($0.article), title: $0.article.title, score: $0.score, leadKey: lead($0.article),
                story: $0.article.id)
        }
        let waiting = ledger.priorityQueue.filter { item in
            !newOverflow.contains { $0.event == item.event } && ledger.announced[item.event]?.lane != .priority
        }
        let overflow = (newOverflow + waiting).sorted { $0.score > $1.score }
        guard !overflow.isEmpty else { return [] }
        if ledger.priorityGroupLastHalfHour { return newOverflow }
        banners.append(
            PlannedBanner(
                lane: .priority, grouped: true, title: "Major news", headlines: overflow.prefix(2).map(\.title),
                count: overflow.count, thread: "priority", sound: true,
                announces: Dictionary(overflow.map { ($0.event, $0.leadKey) }) { first, _ in first },
                members: overflow.map(\.story).filter { !$0.isEmpty }))
        taken.formUnion(overflow.map(\.event))
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
            !taken.contains(key($0.article)) && fresh($0.article, in: .starred) && seen.insert(key($0.article)).inserted
        }
        guard let top = freshItems.first else { return }
        let covered = freshItems.reduce(into: [String: String]()) { $0.merge(announces($1.article)) { a, _ in a } }
        if items.count == 1 {
            banners.append(
                PlannedBanner(
                    lane: .starred, grouped: false, article: top.article, feedURL: feed, thread: key(top.article),
                    sound: top.score >= NotificationService.breakingScore, announces: covered))
        } else {
            let rest = items.filter { item in !freshItems.contains { $0.article.id == item.article.id } }
            banners.append(
                PlannedBanner(
                    lane: .starred, grouped: true, title: NotificationService.sourceName(top.article),
                    headlines: (freshItems + rest).prefix(2).map(\.article.title), count: items.count, feedURL: feed,
                    thread: "starred-\(feed)", sound: false, announces: covered, members: items.map(\.article.id)))
        }
        taken.formUnion(freshItems.map { key($0.article) })
    }

    /// Today's qualification, up to the rolling hour's remaining allowance.
    mutating func planNormal(_ keys: [ScoredStory]) {
        let allowance = max(0, NotificationService.normalLimit - delivery.ledger.normalLastHour)
        for item in keys.filter({ !taken.contains(key($0.article)) }).sorted(by: { $0.score > $1.score })
            .prefix(allowance)
        {
            banners.append(
                PlannedBanner(
                    lane: .normal, grouped: false, article: item.article, thread: key(item.article),
                    sound: item.score >= NotificationService.breakingScore, announces: announces(item.article)))
        }
    }
}
