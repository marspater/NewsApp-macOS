import Foundation
import NaturalLanguage
import UserNotifications

/// Manages NLP-based notification triage, rich image attachments, and alert scheduling.
final class NotificationService: Sendable {
    static let shared = NotificationService()

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
        entityTagger.enumerateTags(in: fullText.startIndex..<fullText.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if let tag = tag, (tag == .personalName || tag == .organizationName || tag == .placeName) {
                entityCount += 1
            }
            return entityCount < 20
        }
        let entityScore = min(Double(entityCount) / 6.0, 1.0)
        score += entityScore * 0.30

        // 3. Breaking news signal words
        let breakingSignals = [
            "breaking", "just in", "urgent", "exclusive", "confirmed",
            "announces", "launches", "acquires", "dies", "killed",
            "arrested", "charged", "resigns", "fired", "recalled",
            "emergency", "crisis", "attack", "explosion", "earthquake",
            "replace", "ceo", "president", "elected", "indicted"
        ]
        let lower = fullText.lowercased()
        let signalHits = breakingSignals.filter { lower.contains($0) }.count
        let signalScore = min(Double(signalHits) / 3.0, 1.0)
        score += signalScore * 0.30

        // 4. Baseline recency bonus
        score += 0.15

        return min(score, 1.0)
    }

    /// NLP-driven triage: scores all new articles, picks the top N most important ones to notify.
    func triageAndNotify(
        newArticles: [FeedArticle],
        privateNotificationsEnabled: Bool,
        maxNotifications: Int = 3
    ) async {
        var scored: [(article: FeedArticle, score: Double)] = []
        for article in newArticles {
            let importance = computeImportance(title: article.title, description: article.description)
            scored.append((article, importance))
        }

        scored.sort { $0.score > $1.score }
        let threshold: Double = 0.45
        let toNotify = scored.filter { $0.score >= threshold }.prefix(maxNotifications)

        for item in toNotify {
            await triggerRichNotification(for: item.article, privateNotifications: privateNotificationsEnabled)
        }
    }

    private func triggerRichNotification(for article: FeedArticle, privateNotifications: Bool) async {
        let content = UNMutableNotificationContent()

        let sourceName = (article.source.components(separatedBy: "\n").first ?? article.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if privateNotifications {
            content.title = "New Article"
            content.subtitle = sourceName
            content.body = "Open the app to read the latest update."
        } else {
            content.title = sourceName
            content.subtitle = article.title
            content.body = article.description.isEmpty ? "" : String(article.description.prefix(200))
        }
        content.sound = .default
        content.userInfo = ["articleLink": article.link]

        if !privateNotifications, let imageUrlString = article.imageUrl, let imageUrl = URL(string: imageUrlString) {
            if let attachment = await downloadNotificationAttachment(from: imageUrl) {
                content.attachments = [attachment]
            }
        }

        let identifier = "news-\(article.link.hashValue)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func downloadNotificationAttachment(from url: URL) async -> UNNotificationAttachment? {
        do {
            let (data, response) = try await SecureHTTPClient.shared.fetchImage(from: url, allowHTTP: false)

            let mimeType = response.mimeType ?? "image/jpeg"
            let ext: String
            switch mimeType {
            case "image/png": ext = "png"
            case "image/gif": ext = "gif"
            case "image/webp": ext = "webp"
            default: ext = "jpg"
            }

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: fileURL)

            return try UNNotificationAttachment(
                identifier: UUID().uuidString,
                url: fileURL,
                options: [UNNotificationAttachmentOptionsThumbnailClippingRectKey: CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation]
            )
        } catch {
            return nil
        }
    }
}
