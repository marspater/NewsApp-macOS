import Foundation

struct FeedArticle: Identifiable, Codable, Hashable, Sendable {
    var queryOrderValue: Double? = nil
    // Database identity survives corrected publisher GUIDs and URLs. Absent in legacy JSON.
    var storedID: String? = nil
    // Present on incoming subscription articles; absent in legacy caches.
    var identityFeedURL: String? = nil

    var id: String {
        storedID ?? ArticleIdentity.computeId(guid: guid, link: link, title: title, source: source, pubDate: pubDate, feedURL: identityFeedURL)
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

    var publicationDateText: String {
        pubDate == DateParser.unknownDate ? "Date unavailable" : pubDate.formatted(date: .abbreviated, time: .omitted)
    }

    var normalizedLink: String {
        ArticleIdentity.canonicalizeURL(link)
    }

    static func normalizeURL(_ urlString: String) -> String {
        ArticleIdentity.canonicalizeURL(urlString)
    }
}

/// Navigation wrapper that pairs an active article with its contextual collection
/// (e.g. active filtered search, category, or unread stories).
struct FeedArticleWrap: Identifiable, Hashable, Sendable {
    let id: UUID
    let article: FeedArticle
    let contextArticles: [FeedArticle]

    init(article: FeedArticle, contextArticles: [FeedArticle] = []) {
        self.id = UUID()
        self.article = article
        self.contextArticles = contextArticles
    }
}

/// Publisher-authored structure. Plain text remains separate for search and analysis.
public struct ReaderBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case paragraph, heading, subheading, quote, listItem, code, figure
    }
    public let kind: Kind
    public let text: String
    public var ordinal: Int? = nil
    public var imageURL: String? = nil
    public var imageAlt: String? = nil
}

public struct ReaderDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 3
    public var version = currentVersion
    public let blocks: [ReaderBlock]
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
        let lowerText = trimmed.lowercased()

        if lowerText.contains("source:") || lowerText.contains("category:") || lowerText.contains("is:") {
            for token in trimmed.components(separatedBy: .whitespaces) {
                let lowerToken = token.lowercased()
                if lowerToken.hasPrefix("source:") {
                    query.sourceFilter = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if lowerToken.hasPrefix("category:") {
                    query.categoryFilter = String(token.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } else if lowerToken == "is:read" {
                    query.isReadFilter = true
                } else if lowerToken == "is:unread" {
                    query.isReadFilter = false
                } else if lowerToken == "is:saved" {
                    query.isSavedFilter = true
                } else if !token.isEmpty {
                    query.terms.append(lowerToken)
                }
            }
        } else {
            query.terms = [lowerText]
        }

        return query
    }

    func matches(article: FeedArticle, isRead: Bool, isSaved: Bool) -> Bool {
        if isEmpty { return true }

        if let s = sourceFilter, !s.isEmpty, !article.source.lowercased().contains(s) { return false }

        if let c = categoryFilter, !c.isEmpty {
            guard let cat = article.category?.lowercased(), cat.contains(c) else { return false }
        }

        if let r = isReadFilter, isRead != r { return false }

        if let sv = isSavedFilter, isSaved != sv { return false }

        if !terms.isEmpty {
            let combined = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
            for term in terms {
                if !combined.contains(term) { return false }
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

enum ArticleSection {
    static let keywords: [String: [String]] = [
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

}
