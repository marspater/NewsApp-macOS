import Foundation
import NaturalLanguage
import UserNotifications

class FeedManager: NSObject, ObservableObject, XMLParserDelegate {
    @Published var articles: [FeedArticle] = []
    @Published var feedURLs: [String] = []
    @Published var userSections: [String] = []

    // XML parsing state
    private var currentElement = ""
    private var currentTitle = ""
    private var currentDescription = ""
    private var currentLink = ""
    private var currentPubDate = ""
    private var currentImageUrl = ""
    private var currentCategory = ""
    private var currentContentEncoded = ""
    private var insideItem = false
    private var channelTitle = ""
    private var parsingChannelTitle = false

    private var parsedArticles: [FeedArticle] = []
    private var currentFeedSource = ""
    private var backgroundTimer: Timer?

    /// Maximum notifications per fetch cycle to avoid spamming the user
    private let maxNotificationsPerCycle = 3
    private let cacheKey = "feed_articles_cache"
    private let feedURLsKey = "saved_feed_urls"
    private let userSectionsKey = "user_sections"

    private let defaultSections = [
        "Entertainment", "Politics", "Business", "Tech",
        "Food", "Health & Wellness", "Lifestyle", "Science"
    ]

    override init() {
        super.init()
        if let savedUrls = UserDefaults.standard.stringArray(forKey: feedURLsKey) {
            feedURLs = savedUrls
        } else {
            feedURLs = [
                "https://feeds.arstechnica.com/arstechnica/index",
                "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml",
                "https://feeds.bbci.co.uk/news/rss.xml"
            ]
        }
        if let savedSections = UserDefaults.standard.stringArray(forKey: userSectionsKey) {
            userSections = savedSections
        } else {
            userSections = defaultSections
        }
        loadCachedArticles()
        startBackgroundFetch()
    }

    // MARK: - Feed URL Management

    func addFeed(url: String) {
        var finalURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalURL.hasPrefix("http://") {
            finalURL = finalURL.replacingOccurrences(of: "http://", with: "https://")
        } else if !finalURL.hasPrefix("https://") {
            finalURL = "https://" + finalURL
        }
        guard URL(string: finalURL) != nil else { return }
        guard !feedURLs.contains(finalURL) else { return }
        feedURLs.append(finalURL)
        UserDefaults.standard.set(feedURLs, forKey: feedURLsKey)
        fetchFeeds()
    }

    func removeFeed(url: String) {
        feedURLs.removeAll { $0 == url }
        UserDefaults.standard.set(feedURLs, forKey: feedURLsKey)
        fetchFeeds()
    }

    // MARK: - Section Management

    func addSection(_ name: String) {
        guard !userSections.contains(name) else { return }
        userSections.append(name)
        UserDefaults.standard.set(userSections, forKey: userSectionsKey)
    }

    func removeSection(_ name: String) {
        userSections.removeAll { $0 == name }
        UserDefaults.standard.set(userSections, forKey: userSectionsKey)
    }

    // MARK: - Filtering (keyword-based auto-categorization)

    private static let sectionKeywords: [String: [String]] = [
        "Entertainment": ["entertainment", "movie", "film", "celebrity", "music", "tv show", "television", "hollywood", "streaming", "netflix", "disney", "actor", "actress", "box office", "concert", "album", "grammy", "oscar", "emmy"],
        "Politics": ["politic", "congress", "senate", "democrat", "republican", "election", "vote", "legislation", "government", "white house", "parliament", "policy", "campaign", "liberal", "conservative"],
        "U.S. Politics": ["politic", "congress", "senate", "democrat", "republican", "election", "vote", "legislation", "white house", "biden", "trump", "campaign"],
        "Business": ["business", "market", "stock", "economy", "finance", "wall street", "investor", "startup", "venture", "ipo", "revenue", "profit", "earnings", "trade", "inflation", "bank"],
        "Tech": ["tech", "software", "hardware", "ai ", "artificial intelligence", "computer", "digital", "startup", "silicon valley", "apple", "google", "microsoft", "amazon", "cyber", "programming", "developer", "app ", "gadget", "robot", "machine learning", "chip", "semiconductor"],
        "Food": ["food", "recipe", "restaurant", "chef", "cooking", "culinary", "dining", "meal", "cuisine", "ingredient"],
        "Health & Wellness": ["health", "medical", "doctor", "hospital", "disease", "treatment", "vaccine", "mental health", "wellness", "fitness", "exercise", "nutrition", "diet", "therapy", "clinical"],
        "Lifestyle": ["lifestyle", "fashion", "travel", "home", "design", "decor", "beauty", "style", "trend", "luxury", "wellness"],
        "Science": ["science", "research", "study", "discovery", "space", "nasa", "physics", "biology", "chemistry", "climate", "environment", "species", "experiment", "laboratory", "quantum", "astronomy", "mars", "planet", "genome"],
        "Fashion": ["fashion", "style", "designer", "runway", "clothing", "brand", "trend", "model", "outfit", "accessory"],
        "Travel": ["travel", "flight", "airline", "hotel", "tourism", "destination", "vacation", "trip", "airport", "cruise"],
        "Sports": ["sport", "football", "basketball", "soccer", "baseball", "nfl", "nba", "mlb", "athlete", "championship", "match", "team", "league", "coach", "score", "olympic", "tennis", "golf"],
        "World": ["world", "international", "global", "europe", "asia", "africa", "foreign", "nation", "united nations", "war", "conflict", "diplomat", "treaty"]
    ]

    func articles(for section: String) -> [FeedArticle] {
        if section == "Today" || section == "Saved Stories" || section == "History" { return articles }

        guard let keywords = FeedManager.sectionKeywords[section] else {
            // Fallback: match on category or title
            return articles.filter { article in
                let text = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
                return text.contains(section.lowercased())
            }
        }

        return articles.filter { article in
            let text = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
            return keywords.contains { text.contains($0) }
        }
    }

    // MARK: - Caching

    func loadCachedArticles() {
        if let cached = CacheManager.shared.load(forKey: cacheKey, as: [FeedArticle].self) {
            self.articles = cached
        }
    }

    // MARK: - Background Fetch

    func startBackgroundFetch() {
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.fetchFeeds()
        }
    }

    // MARK: - Fetch Pipeline

    func fetchFeeds() {
        let group = DispatchGroup()
        var allParsed = [FeedArticle]()
        let lock = NSLock()

        for urlString in feedURLs {
            guard let url = URL(string: urlString) else { continue }
            group.enter()

            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                defer { group.leave() }
                guard let _ = self, let data = data, error == nil else { return }

                // Parse this feed synchronously on the background thread
                let sniffer = String(data: data.prefix(30), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let articlesRes: [FeedArticle]
                if sniffer.hasPrefix("{") || sniffer.hasPrefix("[") {
                    articlesRes = JSONFeedParser.parse(data: data, feedURL: urlString) ?? []
                } else {
                    let feedParser = FeedXMLParser(data: data, feedURL: urlString)
                    articlesRes = feedParser.parse()
                }

                lock.lock()
                allParsed.append(contentsOf: articlesRes)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            // Sort by newest
            allParsed.sort { $0.pubDate > $1.pubDate }

            // Check for new articles — use NLP importance scoring
            let existingIds = Set(self.articles.map { $0.id })
            let newArticles = allParsed.filter { !existingIds.contains($0.id) }

            self.articles = allParsed
            CacheManager.shared.save(self.articles, forKey: self.cacheKey)

            // Fire notifications asynchronously with AI triage
            if !newArticles.isEmpty {
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.triageAndNotify(newArticles)
                }
            }

            // Async AI enrichment + background content fetching
            self.enrichArticlesInBackground()
        }
    }

    // MARK: - Background Enrichment (AI + Full Content + Categorization)

    private func enrichArticlesInBackground() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let snapshot = await MainActor.run { self.articles }

            for (index, article) in snapshot.enumerated() {
                // 1. AI summary
                let summary = await AIManager.shared.analyzeArticle(
                    title: article.title,
                    description: article.description
                )

                // 2. AI-powered categorization (NLP first, keyword fallback)
                let aiCategory = await Task { () -> String? in
                    AIManager.shared.categorizeArticle(
                        title: article.title,
                        description: article.description,
                        rssCategory: article.category
                    )
                }.value

                // 3. Full content fetch + NLP cleaning
                var fetchedContent: String?
                var fetchedImage: String?
                if article.fullContent == nil || article.fullContent!.isEmpty {
                    let fetchRes = await self.fetchFullContentAndImage(for: article.link)
                    fetchedContent = fetchRes.0
                    fetchedImage = fetchRes.1
                } else {
                    fetchedContent = article.fullContent
                }

                // Clean content with NLP prose detection
                if let content = fetchedContent, !content.isEmpty {
                    let cleaned = AIManager.shared.cleanExtractedContent(content)
                    if !cleaned.isEmpty {
                        fetchedContent = cleaned
                    }
                }

                let contentResult = fetchedContent
                let summaryResult = summary
                let categoryResult = aiCategory
                let imageResult = fetchedImage
                await MainActor.run {
                    guard index < self.articles.count else { return }
                    self.articles[index].aiSummary = summaryResult

                    // Use AI category if RSS didn't provide one
                    if self.articles[index].category == nil || self.articles[index].category!.isEmpty {
                        self.articles[index].category = categoryResult
                    }
                    
                    if (self.articles[index].imageUrl == nil || self.articles[index].imageUrl!.isEmpty), let fImg = imageResult {
                        self.articles[index].imageUrl = fImg
                    }

                    if let content = contentResult, !content.isEmpty {
                        self.articles[index].fullContent = content
                        self.articles[index].contentFetched = true
                    } else {
                        self.articles[index].fullContent = article.description
                        self.articles[index].contentFetched = true
                    }
                }
            }

            // Save enriched articles to cache
            await MainActor.run {
                CacheManager.shared.save(self.articles, forKey: self.cacheKey)
            }
        }
    }

    private func fetchFullContentAndImage(for link: String) async -> (String?, String?) {
        guard let url = URL(string: link) else { return (nil, nil) }

        do {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return (nil, nil) }

            // Extract og:image
            var extractedImageUrl: String? = nil
            let ogPattern = "<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']"
            if let regex = try? NSRegularExpression(pattern: ogPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                extractedImageUrl = String(html[range])
            }

            // Step 1: Remove boilerplate HTML blocks
            let cleaned = removeBoilerplateBlocks(from: html)

            // Step 2: Try to isolate the article container
            let articleHTML = extractArticleContainer(from: cleaned) ?? cleaned

            // Step 3: Convert HTML to plain text using NSAttributedString (handles nested tags properly)
            let plainText = htmlToPlainText(articleHTML)

            // Step 4: Filter paragraphs
            let paragraphs = plainText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { paragraph in
                    guard paragraph.count > 50 else { return false }
                    // Must look like prose (has sentence punctuation)
                    let hasSentence = paragraph.contains(".") || paragraph.contains("?") || paragraph.contains("!")
                    guard hasSentence else { return false }
                    // Filter junk
                    let lower = paragraph.lowercased()
                    let isJunk = FeedManager.junkPhrases.contains { lower.contains($0) }
                    return !isJunk
                }

            let result = paragraphs.joined(separator: "\n\n")
            if result.count > 200 { return (result, extractedImageUrl) }
            return (nil, extractedImageUrl)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - HTML Processing Helpers

    /// Remove script, style, nav, footer, aside, header, form blocks
    private func removeBoilerplateBlocks(from html: String) -> String {
        var result = html
        for tag in ["script", "style", "nav", "footer", "aside", "header", "form", "noscript", "iframe", "svg", "figcaption"] {
            let pattern = "<\(tag)[\\s>].*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        // Remove comments
        if let commentRegex = try? NSRegularExpression(pattern: "<!--.*?-->", options: .dotMatchesLineSeparators) {
            result = commentRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Remove divs with social/share/newsletter/related classes
        let junkClassPattern = "<div[^>]*class=\"[^\"]*(?:share|social|related|sidebar|widget|ad-|comment|newsletter|promo|footer|nav)[^\"]*\"[^>]*>.*?</div>"
        if let junkRegex = try? NSRegularExpression(pattern: junkClassPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = junkRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    /// Try to find the main article container using common CSS class/tag patterns
    private func extractArticleContainer(from html: String) -> String? {
        // Try <article> first
        if let articleContent = extractFirstTag(from: html, tag: "article") {
            if articleContent.count > 500 { return articleContent }
        }

        // Try common content container classes
        let contentPatterns = [
            "entry-content", "post-content", "article-body", "article__body",
            "story-body", "story-body__inner", "caas-body", "article-text",
            "story-content", "post-body", "content-body", "article__content",
            "field-body", "c-entry-content", "article-content",
            // Heuristics derived from NetNewsWire structure
            "content", "rich-text", "post_content", "main-content", "article",
            "post-entry", "entry", "story", "page-content"
        ]

        for className in contentPatterns {
            // Match div, section, main, or article with this exact strict class boundary
            let pattern = "<(?:div|section|main|article)[^>]*class=\"[^\"]*\\b\(className)\\b[^\"]*\"[^>]*>(.*)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let content = String(html[range])
                if content.count > 500 { return content }
            }
        }

        return nil
    }

    private func extractFirstTag(from html: String, tag: String) -> String? {
        // Find opening tag
        guard let openPattern = try? NSRegularExpression(pattern: "<\(tag)[\\s>]", options: .caseInsensitive),
              let openMatch = openPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let openRange = Range(openMatch.range, in: html) else { return nil }

        let startIdx = openRange.lowerBound
        let afterOpen = html[startIdx...]

        // Find the closing tag
        let closeTag = "</\(tag)>"
        guard let closeRange = afterOpen.range(of: closeTag, options: .caseInsensitive) else { return nil }

        return String(html[startIdx..<closeRange.upperBound])
    }

    /// Convert HTML to plain text using NSAttributedString — handles nested tags, entities, everything
    private func htmlToPlainText(_ html: String) -> String {
        // Wrap in basic HTML structure so NSAttributedString can parse it
        let wrappedHTML = "<html><body>\(html)</body></html>"
        guard wrappedHTML.data(using: .utf8) != nil else {
            return stripHTMLRegex(html)
        }

        // NSAttributedString HTML parsing must run on main thread, but we're in background
        // Use a simpler approach: regex strip + entity decode
        return stripHTMLRegex(html)
    }

    /// Regex-based HTML stripping with comprehensive entity decoding
    private func stripHTMLRegex(_ html: String) -> String {
        var result = html
        // Replace <br> and <br/> with newlines
        result = result.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        // Replace </p>, </div>, </li>, </h*> with newlines for paragraph breaks
        result = result.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        // Strip all remaining tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode HTML entities
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
            ("&#8217;", "\u{2019}"), ("&#8216;", "\u{2018}"),
            ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}"),
            ("&#8211;", "\u{2013}"), ("&#8212;", "\u{2014}"),
            ("&#8230;", "\u{2026}"), ("&rsquo;", "\u{2019}"),
            ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"),
            ("&ldquo;", "\u{201C}"), ("&mdash;", "\u{2014}"),
            ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"),
            ("&trade;", "\u{2122}"), ("&copy;", "\u{00A9}"),
            ("&reg;", "\u{00AE}")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Decode numeric entities like &#123;
        if let numericRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let nsResult = NSMutableString(string: result)
            let matches = numericRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                if let numRange = Range(match.range(at: 1), in: result) {
                    let numStr = String(result[numRange])
                    if let num = Int(numStr), let scalar = Unicode.Scalar(num) {
                        nsResult.replaceCharacters(in: match.range, with: String(scalar))
                    }
                }
            }
            result = nsResult as String
        }
        // Collapse whitespace
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let junkPhrases: [String] = [
        "share this", "follow us", "join the conversation", "newsletter",
        "subscribe", "sign up", "log in", "sign in", "cookie", "privacy policy",
        "terms of service", "terms & conditions", "terms and conditions",
        "preferred source", "flipboard", "all rights reserved",
        "contact me with", "receive email", "trusted partners",
        "by submitting your", "add us as", "related articles",
        "advertisement", "sponsored", "promoted",
        "leave a reply", "your email address",
        "share on", "tweet this", "pin it", "whatsapp",
        "copy link", "print this", "get app", "download our", "available on"
    ]

    // MARK: - NLP Notification Triage

    /// Scores article importance using NLP sentiment intensity + named entity density + breaking news signals.
    /// Returns a 0.0–1.0 importance score. Only articles scoring above the threshold get notified.
    private func computeImportance(title: String, description: String) -> Double {
        let fullText = "\(title). \(description)"
        var score: Double = 0.0

        // 1. Sentiment intensity — extreme sentiment (very positive or very negative) is more notable
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = fullText
        let (sentiment, _) = tagger.tag(at: fullText.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let sentimentValue = abs(Double(sentiment?.rawValue ?? "0") ?? 0.0)
        score += sentimentValue * 0.25  // 0–0.25 contribution

        // 2. Named entity density — articles about specific people, orgs, places are more newsworthy
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
        score += entityScore * 0.30  // 0–0.30 contribution

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
        score += signalScore * 0.30  // 0–0.30 contribution

        // 4. Recency bonus — articles published within the last 2 hours get a boost
        // (title/description don't carry date, but this is called right after parsing)
        score += 0.15  // baseline recency bonus for brand-new articles

        return min(score, 1.0)
    }

    /// NLP-driven triage: scores all new articles, picks the top N most important ones to notify.
    private func triageAndNotify(_ newArticles: [FeedArticle]) async {
        // Score each article
        var scored: [(article: FeedArticle, score: Double)] = []
        for article in newArticles {
            let importance = computeImportance(title: article.title, description: article.description)
            scored.append((article, importance))
        }

        // Sort by importance descending, take only the top N
        scored.sort { $0.score > $1.score }
        let threshold: Double = 0.45
        let toNotify = scored.filter { $0.score >= threshold }.prefix(maxNotificationsPerCycle)

        for item in toNotify {
            await triggerRichNotification(for: item.article)
        }
    }

    // MARK: - Rich Notifications

    /// Fires a rich macOS notification with the article's image as an attachment.
    private func triggerRichNotification(for article: FeedArticle) async {
        let content = UNMutableNotificationContent()

        // Clean source name
        let sourceName = (article.source.components(separatedBy: "\n").first ?? article.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = sourceName
        content.subtitle = article.title
        content.body = article.description.isEmpty ? "" : String(article.description.prefix(200))
        content.sound = .default

        // Embed article link for deep-linking on click
        content.userInfo = ["articleLink": article.link]

        // Attach article image if available
        if let imageUrlString = article.imageUrl, let imageUrl = URL(string: imageUrlString) {
            if let attachment = await downloadNotificationAttachment(from: imageUrl) {
                content.attachments = [attachment]
            }
        }

        // Use article link as identifier to prevent duplicates
        let identifier = "news-\(article.link.hashValue)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Downloads an image from URL and creates a UNNotificationAttachment.
    private func downloadNotificationAttachment(from url: URL) async -> UNNotificationAttachment? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Determine file extension from MIME type
            let mimeType = (response as? HTTPURLResponse)?.mimeType ?? "image/jpeg"
            let ext: String
            switch mimeType {
            case "image/png": ext = "png"
            case "image/gif": ext = "gif"
            case "image/webp": ext = "webp"
            default: ext = "jpg"
            }

            // Write to temp file (UNNotificationAttachment requires a file URL)
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: fileURL)

            let attachment = try UNNotificationAttachment(
                identifier: UUID().uuidString,
                url: fileURL,
                options: [UNNotificationAttachmentOptionsThumbnailClippingRectKey: CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation]
            )
            return attachment
        } catch {
            return nil
        }
    }
}

// MARK: - Standalone XML Parser (no delegate deadlock risk)

private class FeedXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let feedURL: String
    private var articles = [FeedArticle]()

    private var currentElement = ""
    private var insideItem = false
    private var channelTitle = ""
    private var parsingChannelTitle = false

    private var itemTitle = ""
    private var itemDescription = ""
    private var itemLink = ""
    private var itemPubDate = ""
    private var itemImageUrl = ""
    private var itemCategory = ""
    private var itemContentEncoded = ""
    private var isCollectingContentEncoded = false

    init(data: Data, feedURL: String = "") {
        self.data = data
        self.feedURL = feedURL
    }

    func parse() -> [FeedArticle] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.parse()

        // Post-parse: if channelTitle is still empty, extract from feedURL
        if channelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            channelTitle = extractSourceFromURL(feedURL)
        }

        // Apply channelTitle to any article that has "Feed" or empty source
        for i in 0..<articles.count {
            let src = articles[i].source
            if src.isEmpty || src == "Feed" || src == "Unknown" {
                let name = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    articles[i] = FeedArticle(
                        title: articles[i].title, link: articles[i].link,
                        description: articles[i].description, pubDate: articles[i].pubDate,
                        source: name, imageUrl: articles[i].imageUrl,
                        aiSummary: articles[i].aiSummary, fullContent: articles[i].fullContent,
                        category: articles[i].category, contentFetched: articles[i].contentFetched
                    )
                }
            }
        }
        return articles
    }

    private func extractSourceFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        var name = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
            .replacingOccurrences(of: "rss.", with: "")
        if let dotRange = name.range(of: ".", options: .backwards) {
            name = String(name[..<dotRange.lowerBound])
        }
        if let dotRange = name.range(of: ".", options: .backwards) {
            name = String(name[name.index(after: dotRange.lowerBound)...])
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName

        // RSS uses <channel>, Atom uses <feed> — both contain the feed-level <title>
        if elementName == "channel" || elementName == "feed" {
            parsingChannelTitle = true
        }

        if elementName == "item" || elementName == "entry" {
            insideItem = true
            parsingChannelTitle = false
            itemTitle = ""
            itemDescription = ""
            itemLink = ""
            itemPubDate = ""
            itemImageUrl = ""
            itemCategory = ""
            itemContentEncoded = ""
        }

        // content:encoded
        if elementName == "content:encoded" || (elementName == "content" && insideItem) {
            isCollectingContentEncoded = true
            itemContentEncoded = ""
        }

        // Image from enclosure or media:content
        if insideItem && (elementName == "enclosure" || elementName == "media:content" || elementName == "media:thumbnail") {
            if let url = attributeDict["url"], !url.isEmpty {
                if let type = attributeDict["type"], type.hasPrefix("image") {
                    itemImageUrl = url
                } else if itemImageUrl.isEmpty {
                    itemImageUrl = url
                }
            }
        }

        // Atom link
        if insideItem && elementName == "link" {
            if let href = attributeDict["href"] {
                itemLink = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollectingContentEncoded {
            itemContentEncoded += string
            return
        }

        if !insideItem && parsingChannelTitle && currentElement == "title" {
            channelTitle += string
        }

        guard insideItem else { return }
        switch currentElement {
        case "title": itemTitle += string
        case "description", "summary": itemDescription += string
        case "link": itemLink += string
        case "pubDate", "published", "updated": itemPubDate += string
        case "category", "dc:subject": itemCategory += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let str = String(data: CDATABlock, encoding: .utf8) else { return }

        if isCollectingContentEncoded {
            itemContentEncoded += str
        } else if !insideItem && parsingChannelTitle && currentElement == "title" {
            channelTitle += str
        } else if insideItem && currentElement == "description" {
            itemDescription += str
        } else if insideItem && currentElement == "title" {
            itemTitle += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "content:encoded" || (elementName == "content" && isCollectingContentEncoded) {
            isCollectingContentEncoded = false
        }

        if elementName == "item" || elementName == "entry" {
            insideItem = false

            let date = DateParser.parse(itemPubDate)

            // Clean description
            let cleanDesc = stripHTMLSimple(itemDescription).trimmingCharacters(in: .whitespacesAndNewlines)

            // Clean content:encoded
            var fullContent: String? = nil
            let trimmedContent = itemContentEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                fullContent = stripHTMLSimple(trimmedContent)
            }

            // Determine source name — multiple fallback strategies
            var sourceName = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)

            // If channel title is empty, extract from article URL
            if sourceName.isEmpty || sourceName == "Unknown" {
                sourceName = extractSourceFromURL(itemLink.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            // Clean common suffixes like "NYT > Top Stories", "BBC News - Home"
            if let dashRange = sourceName.range(of: " - ", options: .backwards) {
                let before = sourceName[..<dashRange.lowerBound]
                if before.count > 2 { sourceName = String(before) }
            }
            if let gtRange = sourceName.range(of: " > ") {
                let before = sourceName[..<gtRange.lowerBound]
                if before.count > 2 { sourceName = String(before) }
            }
            if let pipeRange = sourceName.range(of: " | ") {
                let before = sourceName[..<pipeRange.lowerBound]
                if before.count > 2 { sourceName = String(before) }
            }

            // Extract image from description HTML if not found in enclosure
            if itemImageUrl.isEmpty {
                itemImageUrl = extractImageFromHTML(itemDescription) ?? ""
            }
            if itemImageUrl.isEmpty, fullContent != nil {
                itemImageUrl = extractImageFromHTML(itemContentEncoded) ?? ""
            }

            let article = FeedArticle(
                title: itemTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                link: itemLink.trimmingCharacters(in: .whitespacesAndNewlines),
                description: cleanDesc,
                pubDate: date,
                source: sourceName.isEmpty ? "Feed" : sourceName,
                imageUrl: itemImageUrl.isEmpty ? nil : itemImageUrl,
                aiSummary: nil,
                fullContent: fullContent,
                category: itemCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : itemCategory.trimmingCharacters(in: .whitespacesAndNewlines),
                contentFetched: fullContent != nil
            )
            articles.append(article)
        }
    }


    private func stripHTMLSimple(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8220;", with: "\u{201C}")
            .replacingOccurrences(of: "&#8221;", with: "\u{201D}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractImageFromHTML(_ html: String) -> String? {
        let pattern = "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let captureRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[captureRange])
    }
}
