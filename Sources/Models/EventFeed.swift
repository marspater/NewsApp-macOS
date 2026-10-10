import Foundation

// MARK: - Matching records

/// The few columns event matching reads for one stored article.
struct EventMatchRow: Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let source: String
    /// Publication date, or ingestion time for undated articles.
    let date: Date
    let eventID: String?
}

/// A matcher decision, applied by the database only if the state it was made against still holds.
enum EventMatchDecision: Hashable, Sendable {
    case join(eventID: String, expectedVersion: Int)
    /// A new event with these still unassigned partners.
    case create(with: [String])
}

enum EventMatchOutcome: Hashable, Sendable {
    case joined(String)
    case created(String)
    /// Something changed since the decision was made; nothing was written.
    case conflict
}

// MARK: - Feed presentation

enum FeedGroupingMode: String, Sendable {
    /// One card per confirmed event.
    case events
    /// Every publication on its own card.
    case publications
}

struct EventFeedMember: Hashable, Sendable {
    let articleID: String
    let source: String
    let title: String
    let date: Date
    let joinedVersion: Int
    let isRead: Bool
    let isSaved: Bool
}

/// What a feed card needs to know about an event: its visible members (newest first) and the
/// version the reader last saw. Reading state of the event never changes article state.
struct EventFeedSummary: Hashable, Sendable {
    let eventID: String
    let membershipVersion: Int
    let seenVersion: Int?
    let members: [EventFeedMember]

    /// A single remaining member is shown as an ordinary publication.
    var isConfirmed: Bool { members.count >= 2 }

    /// Distinct publishers in member order.
    var sources: [String] {
        var seen = Set<String>()
        return members.map { Self.displaySource($0.source) }.filter { seen.insert($0.lowercased()).inserted }
    }

    var latestDate: Date? { members.map(\.date).max() }

    /// New reporting since the reader last opened the event: an unread member that joined after the
    /// seen version and does not repeat a headline the reader already had. Reprints of a known
    /// headline do not count, and an event never opened is new rather than updated.
    var hasSubstantiveUpdate: Bool {
        guard let seenVersion, seenVersion < membershipVersion else { return false }
        let known = Set(members.filter { $0.joinedVersion <= seenVersion }.map { Self.titleKey($0.title) })
        return members.contains { $0.joinedVersion > seenVersion && !$0.isRead && !known.contains(Self.titleKey($0.title)) }
    }

    /// "5 sources" or, for one publisher, "3 articles from Example News".
    var coverageText: String {
        let sources = sources
        if sources.count > 1 { return "\(sources.count) sources" }
        return "\(members.count) \(members.count == 1 ? "article" : "articles") from \(sources.first ?? "one source")"
    }

    static func displaySource(_ source: String) -> String {
        (source.components(separatedBy: "\n").first ?? source).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func titleKey(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

enum FeedEntry: Identifiable, Hashable, Sendable {
    case article(FeedArticle)
    /// `representative` is the first member in the current list order, so filters that keep a
    /// publication always keep it visible as the card's own article.
    case event(EventFeedSummary, representative: FeedArticle, visibleMembers: [FeedArticle])

    var id: String { representative.id }

    var representative: FeedArticle {
        switch self {
        case .article(let article): return article
        case .event(_, let representative, _): return representative
        }
    }

    var visibleArticles: [FeedArticle] {
        switch self {
        case .article(let article): return [article]
        case .event(_, _, let members): return members
        }
    }
}

enum EventFeedGrouping {
    /// Groups an already filtered, ordered list. Grouping never removes a listed article: each
    /// confirmed event appears once, at its first listed member, with that member on the card.
    static func entries(for articles: [FeedArticle], events: [EventFeedSummary], mode: FeedGroupingMode) -> [FeedEntry] {
        var seenArticles = Set<String>()
        let articles = articles.filter { seenArticles.insert($0.id).inserted }
        guard mode == .events else { return articles.map(FeedEntry.article) }
        var eventOf: [String: EventFeedSummary] = [:]
        for summary in events where summary.isConfirmed {
            for member in summary.members { eventOf[member.articleID] = summary }
        }
        var listed: [String: [FeedArticle]] = [:]
        for article in articles {
            if let summary = eventOf[article.id] { listed[summary.eventID, default: []].append(article) }
        }
        var emitted = Set<String>()
        var entries: [FeedEntry] = []
        for article in articles {
            guard let summary = eventOf[article.id] else {
                entries.append(.article(article))
                continue
            }
            guard emitted.insert(summary.eventID).inserted else { continue }
            entries.append(.event(summary, representative: article, visibleMembers: listed[summary.eventID] ?? [article]))
        }
        return entries
    }

    /// Identical to `entries(for:events:mode:).map(\.id)` but avoids allocating groupings and FeedEntry values.
    static func entryIDs(for articles: [FeedArticle], events: [EventFeedSummary], mode: FeedGroupingMode) -> [String] {
        var seenArticles = Set<String>()
        var uniqueArticles: [FeedArticle] = []
        for article in articles {
            if seenArticles.insert(article.id).inserted { uniqueArticles.append(article) }
        }
        guard mode == .events else { return uniqueArticles.map(\.id) }
        var eventOf: [String: String] = [:]
        for summary in events where summary.isConfirmed {
            for member in summary.members { eventOf[member.articleID] = summary.eventID }
        }
        var emitted = Set<String>()
        var ids: [String] = []
        ids.reserveCapacity(uniqueArticles.count)
        for article in uniqueArticles {
            if let eventID = eventOf[article.id] {
                if emitted.insert(eventID).inserted { ids.append(article.id) }
            } else {
                ids.append(article.id)
            }
        }
        return ids
    }
}

struct FeedSnapshot: Equatable, Sendable {
    var articles: [FeedArticle] = []
    var events: [EventFeedSummary] = []

    func entries(_ mode: FeedGroupingMode) -> [FeedEntry] {
        EventFeedGrouping.entries(for: articles, events: events, mode: mode)
    }

    func entryIDs(_ mode: FeedGroupingMode) -> [String] {
        EventFeedGrouping.entryIDs(for: articles, events: events, mode: mode)
    }
}

enum FeedUpdateResult: Equatable, Sendable {
    /// The refreshed page replaced the list.
    case replaced
    /// Nothing moved; listed content was refreshed in place and further pages stayed.
    case refreshedInPlace
    /// The update waits until the reader asks for it.
    case waiting
}

/// Keeps the list still while it is being read. Refreshed results that would move, add or remove
/// cards wait behind an explicit update; content of cards that stay is refreshed in place.
struct FeedUpdateBuffer: Equatable, Sendable {
    private(set) var displayed = FeedSnapshot()
    private(set) var pending: FeedSnapshot?

    /// A different query, or the reader asked to see the update.
    mutating func replace(with snapshot: FeedSnapshot) {
        displayed = snapshot
        pending = nil
    }

    mutating func applyPending() {
        guard let pending else { return }
        replace(with: pending)
    }

    /// A further page the reader asked for; `events` covers every listed article.
    mutating func append(_ page: [FeedArticle], events: [EventFeedSummary]) {
        let known = Set(displayed.articles.map(\.id))
        displayed.articles += page.filter { !known.contains($0.id) }
        displayed.events = events
    }

    /// A refreshed first page. `hasMore` says further pages follow it, so pages already loaded
    /// beyond it are a continuation and stay when the first page is unchanged.
    @discardableResult
    mutating func receive(_ snapshot: FeedSnapshot, holding: Bool, mode: FeedGroupingMode, hasMore: Bool = false) -> FeedUpdateResult {
        guard !displayed.articles.isEmpty else {
            replace(with: snapshot)
            return .replaced
        }
        let currentIDs = displayed.entryIDs(mode)
        let incomingIDs = snapshot.entryIDs(mode)
        let fresh = Dictionary(snapshot.articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var refreshed = displayed
        refreshed.articles = displayed.articles.map { fresh[$0.id] ?? $0 }
        // Adopt new event state only when it leaves every listed card where it is.
        let incomingEvents = Set(snapshot.events.map(\.eventID))
        var adopted = refreshed
        adopted.events = snapshot.events + displayed.events.filter { !incomingEvents.contains($0.eventID) }
        let groupingStays = adopted.entryIDs(mode) == currentIDs

        let samePage = hasMore ? Array(currentIDs.prefix(incomingIDs.count)) == incomingIDs : currentIDs == incomingIDs
        if samePage && groupingStays {
            // Same order: nothing moves, and pages loaded beyond the first stay.
            displayed = adopted
            pending = nil
            return .refreshedInPlace
        }
        guard holding else {
            replace(with: snapshot)
            return .replaced
        }
        displayed = groupingStays ? adopted : refreshed
        pending = snapshot
        return .waiting
    }

    /// Cards in the waiting update that show none of the currently listed articles.
    func newEntryCount(_ mode: FeedGroupingMode) -> Int {
        guard let pending else { return 0 }
        let listed = Set(displayed.articles.map(\.id))
        return pending.entries(mode).filter { entry in
            !entry.visibleArticles.contains { listed.contains($0.id) }
        }.count
    }
}

// MARK: - Optional finite briefing

/// A window-local reading session. Membership, order and publisher snapshots stay frozen
/// until the reader explicitly starts another briefing; ordinary refresh is independent.
struct FiniteBriefing: Equatable, Sendable {
    static let maximumStories = 10
    static let candidateLimit = 500
    static let duration: TimeInterval = 24 * 60 * 60

    let startedAt: Date
    let articles: [FeedArticle]

    init(candidates: [FeedArticle], readIDs: Set<String>, now: Date = Date()) {
        startedAt = now
        var seen = Set<String>()
        var remaining = candidates.filter {
            !readIDs.contains($0.id) && $0.pubDate >= now.addingTimeInterval(-Self.duration)
                && $0.pubDate <= now && seen.insert($0.id).inserted
        }.sorted { $0.pubDate == $1.pubDate ? $0.id < $1.id : $0.pubDate > $1.pubDate }
        remaining = Array(remaining.prefix(Self.candidateLimit))
        var selected: [FeedArticle] = []
        var sources: [String: Int] = [:], categories: [String: Int] = [:]
        func source(_ article: FeedArticle) -> String { EventFeedSummary.displaySource(article.source).lowercased() }
        func category(_ article: FeedArticle) -> String { (article.category ?? "Uncategorized").lowercased() }
        // ponytail: scan at most 500 candidates ten times; use buckets if the briefing cap grows.
        while selected.count < Self.maximumStories && !remaining.isEmpty {
            let index = remaining.indices.min { left, right in
                let a = remaining[left], b = remaining[right]
                let aSource = sources[source(a), default: 0], bSource = sources[source(b), default: 0]
                return (aSource + categories[category(a), default: 0], aSource, left)
                    < (bSource + categories[category(b), default: 0], bSource, right)
            }!
            let article = remaining.remove(at: index)
            selected.append(article)
            sources[source(article), default: 0] += 1
            categories[category(article), default: 0] += 1
        }
        articles = selected
    }

    func readCount(_ readIDs: Set<String>) -> Int { articles.filter { readIDs.contains($0.id) }.count }
    func isComplete(_ readIDs: Set<String>) -> Bool { !articles.isEmpty && readCount(readIDs) == articles.count }
}
