import Foundation
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers
import UserNotifications
import os

/// Manages NLP-based notification triage, rich image attachments, and alert scheduling.
final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.marspater.news", category: "NotificationService")

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
        let signalScore = min(Double(Self.breakingSignalCount(in: fullText)) / 3.0, 1.0)
        score += signalScore * 0.30

        // 4. Baseline recency bonus
        score += 0.15

        return min(score, 1.0)
    }

    private static let breakingSignals = [
        "breaking", "just in", "urgent", "exclusive", "confirmed",
        "announces", "launches", "acquires", "dies", "killed",
        "arrested", "charged", "resigns", "fired", "recalled",
        "emergency", "crisis", "attack", "explosion", "earthquake",
        "replace", "ceo", "president", "elected", "indicted",
    ]

    /// Signal words present as whole words: "dies" must not fire on "studies", "diesel" or "bodies".
    static func breakingSignalCount(in text: String) -> Int {
        let padded = MuteRules.paddedPhrase(text)
        return breakingSignals.filter { padded.contains(MuteRules.paddedPhrase($0)) }.count
    }

    /// One report per event, the one that scores highest, in first-seen order; stories outside any event stand alone.
    /// Several publishers covering one story then notify once instead of once each (#523). Scoring tags every article,
    /// so it runs off the main actor.
    @concurrent nonisolated static func representatives(of articles: [FeedArticle], events: [String: String]) async
        -> [FeedArticle]
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
        return order.compactMap { best[$0]?.article }
    }

    /// NLP-driven triage: dispatches notifications according to the active NotificationMode.
    func triageAndNotify(
        newArticles: [FeedArticle],
        mode: AppSettings.NotificationMode,
        maxNotifications: Int = 3
    ) async {
        guard !newArticles.isEmpty else { return }

        switch mode {
        case .minimal:
            // ALWAYS exactly one coalesced notification with singular/plural grammar
            await triggerMinimalNotification(for: newArticles)

        case .privacy:
            // Exactly one generic notification with ZERO identifying source or headline details
            await triggerPrivateNotification()

        case .full:
            var scored: [(article: FeedArticle, score: Double)] = []
            for article in newArticles {
                let importance = computeImportance(title: article.title, description: article.description)
                scored.append((article, importance))
            }

            scored.sort { $0.score > $1.score }
            let threshold: Double = 0.45
            let toNotify = scored.filter { $0.score >= threshold }.prefix(maxNotifications)

            for item in toNotify {
                await triggerFullNotification(for: item.article)
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

        guard Bundle.main.bundleIdentifier != nil else {
            logger.debug("Skipping notification dispatch in non-bundled environment")
            return
        }

        let identifier = "news-minimal-summary"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.debug("Successfully scheduled minimal notification: \(identifier)")
        } catch {
            logger.error("Failed to schedule minimal notification '\(identifier)': \(error.localizedDescription)")
        }
    }

    private func triggerPrivateNotification() async {
        guard Bundle.main.bundleIdentifier != nil else {
            logger.debug("Skipping notification dispatch in non-bundled environment")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "News Update"
        content.body = "You have new articles available. Open to read."
        content.sound = .default

        let identifier = "news-generic-update"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.debug("Successfully scheduled private notification: \(identifier)")
        } catch {
            logger.error("Failed to schedule private notification '\(identifier)': \(error.localizedDescription)")
        }
    }

    private func triggerFullNotification(for article: FeedArticle) async {
        guard Bundle.main.bundleIdentifier != nil else {
            logger.debug("Skipping notification dispatch in non-bundled environment")
            return
        }

        let content = UNMutableNotificationContent()

        let sourceName = (article.source.components(separatedBy: "\n").first ?? article.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        content.title = sourceName
        content.subtitle = article.title
        content.body = article.description.isEmpty ? "" : String(article.description.prefix(200))
        content.sound = .default
        content.userInfo = ["articleLink": article.link, "articleID": article.id]

        if let imageUrl = FeedArticle.bestCardImage(in: [article]),
            let attachment = await downloadNotificationAttachment(from: imageUrl)
        {
            content.attachments = [attachment]
        }

        let identifier = Self.notificationIdentifier(for: article)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.debug(
                "Successfully scheduled full notification: \(identifier); attachments=\(content.attachments.count)")
        } catch {
            logger.error("Failed to schedule full notification '\(identifier)': \(error.localizedDescription)")
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
