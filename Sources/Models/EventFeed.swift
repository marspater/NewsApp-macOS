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
    /// A matcher version processed the article since its title and description last changed.
    var previouslyMatched = false
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
        return members.contains {
            $0.joinedVersion > seenVersion && !$0.isRead && !known.contains(Self.titleKey($0.title))
        }
    }

    /// Keep article and distinct-publisher counts explicit, including repeated coverage by one publisher.
    var coverageText: String {
        "\(members.count) \(members.count == 1 ? "story" : "stories") · \(sources.count) \(sources.count == 1 ? "publisher" : "publishers")"
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
    static func entries(for articles: [FeedArticle], events: [EventFeedSummary], mode: FeedGroupingMode) -> [FeedEntry]
    {
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
            entries.append(
                .event(summary, representative: article, visibleMembers: listed[summary.eventID] ?? [article]))
        }
        return entries
    }

    /// Lightweight version of `entries(for:events:mode:)` that only computes the resulting IDs,
    /// avoiding the allocation of intermediate `FeedEntry` objects.
    static func entryIDs(for articles: [FeedArticle], events: [EventFeedSummary], mode: FeedGroupingMode) -> [String] {
        var seenArticles = Set<String>()
        let uniqueArticles = articles.filter { seenArticles.insert($0.id).inserted }
        guard mode == .events else { return uniqueArticles.map(\.id) }
        var eventOf: [String: String] = [:]
        for summary in events where summary.isConfirmed {
            for member in summary.members { eventOf[member.articleID] = summary.eventID }
        }
        var emitted = Set<String>()
        var ids: [String] = []
        for article in uniqueArticles {
            guard let eventID = eventOf[article.id] else {
                ids.append(article.id)
                continue
            }
            guard emitted.insert(eventID).inserted else { continue }
            ids.append(article.id)
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
    /// Bursts of store revisions are debounced, but a section's first page is shown at once.
    static func debouncesReload(isPaging: Bool, isNewQuery: Bool, hasStories: Bool) -> Bool {
        !isPaging && !isNewQuery && hasStories
    }

    mutating func receive(_ snapshot: FeedSnapshot, holding: Bool, mode: FeedGroupingMode, hasMore: Bool = false)
        -> FeedUpdateResult
    {
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

/// Existing local signals; selecting a Briefing never runs an importance model.
struct BriefingPriority: Equatable, Sendable {
    var sourceCount = 1
    var importance: StoryImportance?
    var eventID: String? = nil
}

/// A daily edition, after Kagi News: selected once per day at the edition hour and frozen until the next edition
/// or until the reader asks for a new one; ordinary refresh is independent. Every window shows the same edition.
struct FiniteBriefing: Equatable, Sendable {
    static let maximumStories = 10
    static let candidateLimit = 500
    static let duration: TimeInterval = 24 * 60 * 60
    static let defaultEditionHour = 7

    let startedAt: Date
    let articles: [FeedArticle]

    /// A stored edition, restored in its saved order.
    init(startedAt: Date, articles: [FeedArticle]) {
        self.startedAt = startedAt
        self.articles = articles
    }

    /// When the edition current at `now` was due: today's edition hour, or yesterday's before that hour.
    static func editionStart(now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let hour = min(23, max(0, hour))
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// When the following edition is due: the next day at the edition hour, in calendar days so daylight-saving
    /// changes keep the configured local time.
    static func nextEditionStart(now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let current = editionStart(now: now, hour: hour, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(duration)
        return calendar.date(bySettingHour: min(23, max(0, hour)), minute: 0, second: 0, of: nextDay) ?? nextDay
    }

    /// A stored edition is reused while it was selected at or after the edition currently due.
    static func isCurrent(selectedAt: Date, now: Date, hour: Int, calendar: Calendar = .current) -> Bool {
        selectedAt >= editionStart(now: now, hour: hour, calendar: calendar) && selectedAt <= now
    }

    init(
        candidates: [FeedArticle], readIDs: Set<String>, now: Date = Date(),
        priorities: [String: BriefingPriority] = [:], interests: [String: Int] = [:]
    ) {
        startedAt = now
        var remaining = Self.prepareCandidates(candidates, readIDs: readIDs, now: now)
        var selected: [FeedArticle] = []
        var sources: [String: Int] = [:]
        var categories: [String: Int] = [:]
        var selectedEvents = Set<String>()
        // ponytail: scan at most 500 candidates ten times; use buckets if the briefing cap grows.
        while selected.count < Self.maximumStories && !remaining.isEmpty {
            remaining.removeAll {
                sources[Self.source($0), default: 0] >= 2
                    || priorities[$0.id]?.eventID.map(selectedEvents.contains) == true
            }
            guard !remaining.isEmpty else { break }
            let index = remaining.indices.min { left, right in
                func rank(_ article: FeedArticle) -> [Int] {
                    Self.rank(
                        priority: priorities[article.id] ?? BriefingPriority(),
                        interest: interests[Self.category(article), default: 0],
                        sourceCount: sources[Self.source(article), default: 0],
                        categoryCount: categories[Self.category(article), default: 0])
                }
                let a = rank(remaining[left])
                let b = rank(remaining[right])
                return a == b ? left < right : b.lexicographicallyPrecedes(a)
            }!
            let article = remaining.remove(at: index)
            if let eventID = priorities[article.id]?.eventID { selectedEvents.insert(eventID) }
            selected.append(article)
            sources[Self.source(article), default: 0] += 1
            categories[Self.category(article), default: 0] += 1
        }
        articles = selected
    }

    private static func prepareCandidates(_ candidates: [FeedArticle], readIDs: Set<String>, now: Date) -> [FeedArticle]
    {
        var seen = Set<String>()
        return Array(
            candidates.filter {
                !readIDs.contains($0.id) && $0.pubDate >= now.addingTimeInterval(-Self.duration)
                    && $0.pubDate <= now && seen.insert($0.id).inserted
            }.sorted { $0.pubDate == $1.pubDate ? $0.id < $1.id : $0.pubDate > $1.pubDate }.prefix(Self.candidateLimit))
    }

    private static func source(_ article: FeedArticle) -> String {
        EventFeedSummary.displaySource(article.publisherName).lowercased()
    }

    private static func category(_ article: FeedArticle) -> String {
        (NewsCategory.match(from: article.category ?? "")?.rawValue ?? "Uncategorized").lowercased()
    }

    /// Higher lexicographic ranks win; negative counts prefer underrepresented publishers and categories.
    private static func rank(
        priority: BriefingPriority, interest: Int, sourceCount: Int, categoryCount: Int
    ) -> [Int] {
        [
            (priority.importance ?? .notable).rawValue, priority.sourceCount, interest,
            -(sourceCount + categoryCount), -sourceCount,
        ]
    }

    func readCount(_ readIDs: Set<String>) -> Int { articles.filter { readIDs.contains($0.id) }.count }
    func isComplete(_ readIDs: Set<String>) -> Bool { !articles.isEmpty && readCount(readIDs) == articles.count }
}
