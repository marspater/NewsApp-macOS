import Foundation

struct FeedArticle: Identifiable, Codable, Hashable, Sendable {
    var queryOrderValue: Double? = nil
    // Database identity survives corrected publisher GUIDs and URLs. Absent in legacy JSON.
    var storedID: String? = nil
    // Present on incoming subscription articles; absent in legacy caches.
    var identityFeedURL: String? = nil

    var id: String {
        storedID
            ?? ArticleIdentity.computeId(
                guid: guid, link: link, title: title, source: source, pubDate: pubDate, feedURL: identityFeedURL)
    }
    let title: String
    let link: String
    let guid: String?
    let description: String
    let pubDate: Date
    let source: String
    var imageUrl: String?
    var aiSummary: String?
    var fullContent: String?
    var category: String?
    var contentFetched: Bool = false
    var keyPoints: [String]?
    var entities: [EntityResult]?
    var sentimentScore: Double?
    var sentimentLabel: String?
    var readerDocument: ReaderDocument?

    /// Publisher inputs only. Length prefixes prevent ambiguous field boundaries.
    var publisherInputHash: String {
        PublisherContentRevision.inputHash(title: title, description: description, content: fullContent)
    }

    /// The full publication date for the reader and accessibility labels ("October 10, 2026" in English).
    var publicationDateText: String {
        pubDate == DateParser.unknownDate ? "Date unavailable" : pubDate.formatted(date: .long, time: .omitted)
    }

    /// The short date cards show (DESIGN.md 8.2): relative within a day ("2 hr. ago"), then month and day, with the
    /// year only for earlier years.
    func cardDateText(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard pubDate != DateParser.unknownDate else { return "Date unavailable" }
        let age = now.timeIntervalSince(pubDate)
        if age < 60 { return "Just now" }
        if age < 24 * 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.dateTimeStyle = .numeric
            return formatter.localizedString(for: pubDate, relativeTo: now)
        }
        if calendar.component(.year, from: pubDate) == calendar.component(.year, from: now) {
            return pubDate.formatted(.dateTime.month(.abbreviated).day())
        }
        return pubDate.formatted(.dateTime.year().month(.abbreviated).day())
    }

    /// The publisher to show: the catalog's name for the story's site, else the first line of the feed's own title,
    /// which is often a section ("World news") or a slogan.
    var publisherName: String {
        FeedCatalog.publisher(forLink: link) ?? EventFeedSummary.displaySource(source)
    }

    var normalizedLink: String {
        ArticleIdentity.canonicalizeURL(link)
    }

    /// Picks among curated member leads. Known area wins; tied or unknown sizes prefer publisher-hosted media.
    static func bestCardImage(in articles: [FeedArticle]) -> URL? {
        rankedCardImages(in: articles).first?.url
    }

    /// Every distinct usable member lead, best first, for event cards that show more than one.
    static func cardImages(in articles: [FeedArticle]) -> [URL] {
        rankedCardImages(in: articles).map(\.url)
    }

    /// Distinct usable member leads ranked as `bestCardImage` chooses, each with the article it came from.
    static func rankedCardImages(in articles: [FeedArticle]) -> [(url: URL, article: FeedArticle)] {
        struct Candidate {
            let url: URL
            let article: FeedArticle
            let area: Int
            let own: Bool
            let offset: Int
        }
        let candidates = articles.enumerated().compactMap { offset, article -> Candidate? in
            guard let image = article.readerDocument?.selectedImage(fallback: article.imageUrl) ?? article.imageUrl,
                let url = URL(string: image)
            else { return nil }
            let metadata = article.readerDocument?.images?.first { $0.url == image }
            guard ReaderImageCandidate.usable(url: image, width: metadata?.width, height: metadata?.height),
                metadata?.aspectRatio.map({ $0 <= 4 && $0 >= 0.25 }) ?? true
            else { return nil }
            let host = URL(string: article.link)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
            let imageHost = url.host?.lowercased() ?? ""
            return Candidate(
                url: url, article: article, area: (metadata?.width ?? 0) * (metadata?.height ?? 0),
                own: !host.isEmpty && (imageHost == host || imageHost.hasSuffix("." + host)), offset: offset)
        }
        var seen = Set<URL>()
        return candidates.sorted { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            if lhs.own != rhs.own { return lhs.own }
            return lhs.offset < rhs.offset
        }
        .filter { seen.insert($0.url).inserted }
        .map { ($0.url, $0.article) }
    }
}

/// Navigation wrapper that pairs an active article with its contextual collection
/// (e.g. active filtered search, category, or unread stories).
struct FeedArticleWrap: Identifiable, Hashable, Sendable {
    let id: UUID
    let article: FeedArticle
    let contextArticles: [FeedArticle]
    let initialExperienceMode: ReaderExperienceMode?

    init(
        article: FeedArticle,
        contextArticles: [FeedArticle] = [],
        initialExperienceMode: ReaderExperienceMode? = nil
    ) {
        self.id = UUID()
        self.article = article
        self.contextArticles = contextArticles
        self.initialExperienceMode = initialExperienceMode
    }
}

/// Publisher-authored structure. Plain text remains separate for search and analysis.
public struct ReaderBlock: Codable, Hashable, Sendable {
    /// `standfirst` and `pullQuote` are publisher display text; a `table` holds tab-separated cells, one row per line, with `ordinal` 1 when the first row is a header;
    /// an `embed` stands for media the reader cannot show (a post, video or oversized table), its host in `text` and
    /// its address, when safe, in `imageURL`.
    public enum Kind: String, Codable, Sendable {
        case paragraph, heading, subheading, quote, listItem, code, figure, divider
        case standfirst, pullQuote, table, embed

        /// Unknown kinds from a newer reader read as paragraphs instead of failing the whole document.
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .paragraph
        }
    }
    public let kind: Kind
    public let text: String
    public var ordinal: Int? = nil
    public var imageURL: String? = nil
    public var imageAlt: String? = nil
    public var inlineRuns: [ReaderInlineRun]? = nil
    public var imageCredit: String? = nil
    public var imageWidth: Int? = nil
    public var imageHeight: Int? = nil
    /// Nesting depth of a list item; nil for a top-level item.
    public var level: Int? = nil
}

public struct ReaderDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 11
    public var version = currentVersion
    public let blocks: [ReaderBlock]
    public var images: [ReaderImageCandidate]? = nil
    public var leadImageURL: String? = nil
    public var isComplete: Bool? = nil

    public init(
        version: Int = currentVersion,
        blocks: [ReaderBlock],
        images: [ReaderImageCandidate]? = nil,
        leadImageURL: String? = nil,
        isComplete: Bool? = nil
    ) {
        self.version = version
        self.blocks = blocks
        self.images = images
        self.leadImageURL = leadImageURL
        self.isComplete = isComplete
    }

    func curated(feedImage: String?, title: String, excluding repeated: Set<String> = []) -> Self {
        var result = self
        var candidates = images ?? []
        if let feedImage, ReaderImageCandidate.usable(url: feedImage),
            !candidates.contains(where: { $0.url == feedImage })
        {
            candidates.append(ReaderImageCandidate(url: feedImage, origin: .feed))
        }
        candidates.removeAll { repeated.contains($0.url) }
        result.images = candidates
        result.leadImageURL = ReaderImageCandidate.select(from: candidates, title: title)?.url
        result = Self(
            version: result.version, blocks: blocks.filter { $0.imageURL.map { !repeated.contains($0) } ?? true },
            images: candidates, leadImageURL: result.leadImageURL, isComplete: result.isComplete)
        return result
    }

    /// Selects the best image for card and reader representation, falling back to usable extracted images or feed media.
    func selectedImage(fallback: String?) -> String? {
        if version >= 4 {
            if let leadImageURL, !leadImageURL.isEmpty {
                return leadImageURL
            }
            if let firstUsable = images?.first(where: {
                ReaderImageCandidate.usable(url: $0.url, width: $0.width, height: $0.height)
            })?.url {
                return firstUsable
            }
            return nil
        }
        return fallback
    }

    /// Feed media alone is not a reader document: only publisher text lets a stored document stand in for
    /// extraction or survive a refresh that brings none. `DatabaseEngine.upsertArticles` applies the same rule in SQL.
    var hasPublisherText: Bool {
        blocks.contains { ![.figure, .divider, .embed].contains($0.kind) }
    }

    /// True if this document represents a complete standalone article rather than a brief feed teaser/excerpt.
    public var hasCompleteArticleBody: Bool {
        guard hasPublisherText else { return false }
        if isComplete == false { return false }
        let textBlocks = blocks.filter { $0.kind == .paragraph || $0.kind == .quote || $0.kind == .listItem }
        let totalCount = textBlocks.map(\.text.count).reduce(0, +)
        if totalCount < 600 && textBlocks.count <= 2 { return false }
        if let last = textBlocks.last?.text.lowercased(),
            last.contains("continue reading")
                || last.contains("read full article")
                || last.contains("appeared first on")
                || (last.contains("the post") && last.contains("appeared first"))
        {
            return false
        }
        return true
    }
}

struct ArticleFilterQuery: Equatable, Sendable {
    var sourceFilter: String?
    var categoryFilter: String?
    var isReadFilter: Bool?
    var isSavedFilter: Bool?
    var terms: [String] = []

    var isEmpty: Bool {
        sourceFilter == nil && categoryFilter == nil && isReadFilter == nil && isSavedFilter == nil && terms.isEmpty
    }

    init(
        sourceFilter: String? = nil,
        categoryFilter: String? = nil,
        isReadFilter: Bool? = nil,
        isSavedFilter: Bool? = nil,
        terms: [String] = []
    ) {
        self.sourceFilter = sourceFilter
        self.categoryFilter = categoryFilter
        self.isReadFilter = isReadFilter
        self.isSavedFilter = isSavedFilter
        self.terms = terms
    }

    static func parse(_ rawText: String) -> ArticleFilterQuery {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ArticleFilterQuery() }

        var query = ArticleFilterQuery()
        // Words are separate terms with or without operators, so "trump tariffs" matches non-adjacent words.
        for token in trimmed.components(separatedBy: .whitespacesAndNewlines) {
            let lowerToken = token.lowercased()
            if lowerToken.hasPrefix("source:") {
                let publisher = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                query.sourceFilter = publisher == "ft" ? "financial times" : publisher
            } else if lowerToken.hasPrefix("category:") {
                query.categoryFilter = String(token.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            } else if lowerToken == "is:read" {
                query.isReadFilter = true
            } else if lowerToken == "is:unread" {
                query.isReadFilter = false
            } else if lowerToken == "is:saved" {
                query.isSavedFilter = true
            } else if lowerToken == "ft" {
                query.terms += ["financial", "times"]
            } else if !token.isEmpty {
                query.terms.append(lowerToken)
            }
        }

        return query
    }

    func matches(article: FeedArticle, isRead: Bool, isSaved: Bool) -> Bool {
        if isEmpty { return true }

        if let s = sourceFilter, !s.isEmpty,
            !article.source.lowercased().contains(s) && !article.publisherName.lowercased().contains(s)
        {
            return false
        }

        if let c = categoryFilter, !c.isEmpty {
            guard let cat = article.category?.lowercased(), cat.contains(c) else { return false }
        }

        if let r = isReadFilter, isRead != r { return false }

        if let sv = isSavedFilter, isSaved != sv { return false }

        if !terms.isEmpty {
            let combined =
                "\(article.title) \(article.description) \(article.category ?? "") \(article.source) \(article.publisherName)"
                .lowercased()
            for term in terms where !combined.contains(term) {
                return false
            }
        }

        return true
    }
}

struct ArticleQueryCursor: Equatable, Sendable {
    let value: Double
    let id: String

    init(_ article: FeedArticle) {
        value = article.queryOrderValue ?? article.pubDate.timeIntervalSince1970
        id = article.id
    }
}

extension FeedArticle {
    /// The date the library orders and windows by: the publication date, or ingestion time for an undated story.
    var orderDate: Date { queryOrderValue.map(Date.init(timeIntervalSince1970:)) ?? pubDate }
}

enum ArticleSection {
    static func matches(_ section: String, title: String, description: String, category: String?) -> Bool {
        if keywords[section] != nil, section != "U.S. Politics",
            let target = NewsCategory.match(from: section), let classified = category.flatMap(NewsCategory.match(from:))
        {
            if section == "Lifestyle" { return [.lifestyle, .fashion, .travel].contains(classified) }
            return classified == target
        }
        let terms = ((keywords[section] ?? [section]) + [NewsCategory.match(from: section)?.rawValue ?? section]).map(
            MuteRules.phrase
        ).joined(separator: "\n")
        return MuteRules.topicList(terms, mutes: title + "\n" + description + "\n" + (category ?? ""))
    }

    static let keywords: [String: [String]] = [
        "Entertainment": [
            "entertainment", "movie", "film", "celebrity", "music", "tv show", "television", "hollywood", "streaming",
            "netflix", "disney", "actor", "actress", "box office", "concert", "album", "grammy", "oscar", "emmy",
        ],
        "Politics": [
            "politic", "congress", "senate", "democrat", "republican", "election", "vote", "legislation", "government",
            "white house", "parliament", "policy", "campaign", "liberal", "conservative",
        ],
        "U.S. Politics": [
            "politic", "congress", "senate", "democrat", "republican", "election", "vote", "legislation", "white house",
            "biden", "trump", "campaign",
        ],
        "Business": [
            "business", "market", "stock", "economy", "finance", "wall street", "investor", "startup", "venture", "ipo",
            "revenue", "profit", "earnings", "trade", "inflation", "bank",
        ],
        "Tech": [
            "tech", "software", "hardware", "ai ", "artificial intelligence", "computer", "digital", "startup",
            "silicon valley", "apple", "google", "microsoft", "amazon", "cyber", "programming", "developer", "app ",
            "gadget", "robot", "machine learning", "chip", "semiconductor",
        ],
        "Food": [
            "food", "recipe", "restaurant", "chef", "cooking", "culinary", "dining", "meal", "cuisine", "ingredient",
        ],
        "Health & Wellness": [
            "health", "medical", "doctor", "hospital", "disease", "treatment", "vaccine", "mental health", "wellness",
            "fitness", "exercise", "nutrition", "diet", "therapy", "clinical",
        ],
        "Lifestyle": [
            "lifestyle", "fashion", "travel", "home", "design", "decor", "beauty", "style", "trend", "luxury",
            "wellness",
        ],
        "Science": [
            "science", "research", "study", "discovery", "space", "nasa", "physics", "biology", "chemistry", "climate",
            "environment", "species", "experiment", "laboratory", "quantum", "astronomy", "mars", "planet", "genome",
        ],
        "Fashion": [
            "fashion", "style", "designer", "runway", "clothing", "brand", "trend", "model", "outfit", "accessory",
        ],
        "Travel": [
            "travel", "flight", "airline", "hotel", "tourism", "destination", "vacation", "trip", "airport", "cruise",
        ],
        "Sports": [
            "sport", "football", "basketball", "soccer", "baseball", "nfl", "nba", "mlb", "athlete", "championship",
            "match", "team", "league", "coach", "score", "olympic", "tennis", "golf",
        ],
        "World": [
            "world", "international", "global", "europe", "asia", "africa", "foreign", "nation", "united nations",
            "war", "conflict", "diplomat", "treaty",
        ],
    ]

}

/// Runs retain publisher typography without storing or executing HTML.
public struct ReaderInlineRun: Codable, Hashable, Sendable {
    public var text: String
    public var strong = false
    public var emphasis = false
    public var code = false
    public var link: String? = nil
    /// 1 for superscript (`<sup>`), -1 for subscript (`<sub>`), nil on the baseline.
    public var baselineShift: Int? = nil
}

public struct ReaderImageCandidate: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case feed, openGraph, body }
    public var url: String
    public var origin: Origin
    public var width: Int? = nil
    public var height: Int? = nil
    public var caption: String? = nil
    public var credit: String? = nil
    public var alt: String? = nil

    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// Publisher association, never a guarantee of semantic relevance.
    static func select(from candidates: [Self], title: String) -> Self? {
        let words = Set(
            title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 3 })
        return candidates.filter { usable(url: $0.url, width: $0.width, height: $0.height) }
            .enumerated().max { lhs, rhs in
                func score(_ image: Self) -> Int {
                    let text = (image.alt ?? "") + " " + (image.caption ?? "")
                    let overlap = words.intersection(
                        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    ).count
                    return overlap * 10 + (image.origin == .body ? 3 : image.origin == .openGraph ? 2 : 1)
                }
                let a = score(lhs.element)
                let b = score(rhs.element)
                guard a == b else { return a < b }
                // Equal evidence: the larger known rendition, then the earlier candidate.
                let lhsWidth = lhs.element.width ?? 0
                let rhsWidth = rhs.element.width ?? 0
                return lhsWidth == rhsWidth ? lhs.offset > rhs.offset : lhsWidth < rhsWidth
            }?.element
    }

    /// BBC feeds link 240 px thumbnails; the same CDN path serves a rendition sharp enough for cards and the reader.
    static func preferredRendition(of url: URL) -> URL {
        guard url.host?.lowercased() == "ichef.bbci.co.uk" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Only the width segment changes; the rest of the CDN path is kept as published.
        components?.path = url.path.replacingOccurrences(
            of: #"(?<=^/ace/standard/)\d{2,3}(?=/)"#, with: "976", options: .regularExpression)
        return components?.url ?? url
    }

    static func usable(url: String, width: Int? = nil, height: Int? = nil) -> Bool {
        guard ContentExtractionPipeline.readerImageURL(url, baseURL: nil) != nil,
            width.map({ $0 >= 80 && $0 <= 16_384 }) ?? true,
            height.map({ $0 >= 80 && $0 <= 16_384 }) ?? true
        else { return false }
        let path = URL(string: url)?.path.lowercased() ?? ""
        return path.range(
            of: #"(?:^|[./_-])(?:logo|favicon|tracking|pixel|spacer|advertisement|avatar|banners?)(?:[./_-]|$)"#,
            options: .regularExpression) == nil
    }
}

/// Locally observed publisher-input versions, not verified correction or fact-check claims.
struct PublisherContentRevision: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case snapshot, extraction
        case publisherUpdate = "publisher_update"
    }
    let version: Int
    let observedAt: Date
    let kind: Kind
    let changedFields: Int
    let inputHash: String
    var id: Int { version }

    var changeDescription: String {
        [(1, "Title"), (2, "Feed summary"), (4, "Article body")]
            .filter { changedFields & $0.0 != 0 }.map { $0.1 }.joined(separator: ", ")
    }

    static func inputHash(title: String, description: String, content: String?) -> String {
        ArticleIdentity.sha256Hex([title, description, content ?? ""].map { "\($0.utf8.count):\($0)" }.joined())
    }
}
