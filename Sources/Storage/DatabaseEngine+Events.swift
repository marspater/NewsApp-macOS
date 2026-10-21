import Foundation
import SQLite3
import os

// Event records, membership and developing-story lookups.
extension DatabaseEngine {
    enum EventValue {
        case text(String)
        case integer(Int)
        case real(Double)
        case null
    }

    static func eventError(_ message: String) -> NSError {
        NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Runs one statement and returns its rows as text columns (NULL as nil).
    @discardableResult
    func eventRows(_ sql: String, _ values: [EventValue] = []) throws -> [[String?]] {
        guard let db = db else { throw Self.eventError("Database not open") }
        var statement: OpaquePointer?
        // Callers interpolate only static SQL fragments and generated `?` lists; every value is bound below.
        // nosemgrep: swift.sqllite.sqllite-injection-audit.swift-potential-sqlite-injection
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.eventError("Cannot prepare event statement: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.sqliteTransient)
            case .integer(let number): sqlite3_bind_int64(statement, position, Int64(number))
            case .real(let number): sqlite3_bind_double(statement, position, number)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(
                (0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw Self.eventError("Cannot execute event statement: \(String(cString: sqlite3_errmsg(db)))")
        }
        return rows
    }

    func inEventTransaction<T>(_ body: () throws -> T) throws -> T {
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }
        let result = try body()
        try commitTransaction()
        return result
    }

    /// When the on-device model generation differs from the one that produced stored results, every overview and
    /// article summary is marked provisional (analysis version 0), so each is regenerated with the current model the
    /// next time it is requested. Importance ratings and event memberships are decisions already applied to the
    /// library and stay. Returns whether stored results were invalidated.
    @discardableResult
    func reconcileModelGeneration(_ current: String) throws -> Bool {
        try inEventTransaction { () throws -> Bool in
            guard try eventRows("SELECT value FROM model_generation WHERE id = 1;").first?[0] != current else {
                return false
            }
            try eventRows(
                "UPDATE event_overviews SET analysis_version = 0 WHERE kind != ?;",
                [.text(OverviewKind.fallbackExcerpts.rawValue)])
            try eventRows("UPDATE article_enrichment SET analysis_version = 0 WHERE summary IS NOT NULL;")
            try eventRows("INSERT OR REPLACE INTO model_generation(id, value) VALUES (1, ?);", [.text(current)])
            return true
        }
    }

    /// The live event an ID refers to, following merge forwards; nil once the event is gone.
    func resolvedEventID(_ id: String) throws -> String? {
        var current = id
        var visited = Set<String>()
        while visited.insert(current).inserted {
            guard let row = try eventRows("SELECT merged_into FROM events WHERE id = ?;", [.text(current)]).first else {
                return nil
            }
            guard let next = row[0] else { return current }
            current = next
        }
        return nil
    }

    func fetchEvent(id: String) throws -> StoryEvent? {
        guard let live = try resolvedEventID(id),
            let row = try eventRows(
                "SELECT membership_version, created_at, updated_at FROM events WHERE id = ?;", [.text(live)]
            ).first
        else {
            return nil
        }
        let members = try eventRows(
            "SELECT article_id FROM event_members WHERE event_id = ? ORDER BY article_id;", [.text(live)]
        ).compactMap { $0[0] }
        return StoryEvent(
            id: live,
            membershipVersion: row[0].flatMap { Int($0) } ?? 1,
            memberArticleIDs: members,
            createdAt: Date(timeIntervalSince1970: row[1].flatMap { Double($0) } ?? 0),
            updatedAt: Date(timeIntervalSince1970: row[2].flatMap { Double($0) } ?? 0)
        )
    }

    /// The event that currently holds an article; old article IDs resolve to the stored document.
    func eventID(forArticle articleID: String) throws -> String? {
        guard let member = try memberArticleID(articleID) else { return nil }
        return try eventRows("SELECT event_id FROM event_members WHERE article_id = ?;", [.text(member)]).first?[0]
    }

    /// Creates an event with a new stable ID. Articles already in another event move here.
    @discardableResult
    func createEvent(memberArticleIDs articleIDs: [String], at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            try insertEvent(members: try resolvedMembers(articleIDs), at: date.timeIntervalSince1970)
        }
        return try requireEvent(id)
    }

    @discardableResult
    func addArticles(_ articleIDs: [String], toEvent eventID: String, at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let target = try liveEvent(eventID)
            let now = date.timeIntervalSince1970
            if try assignMembers(
                try resolvedMembers(articleIDs), to: target.id, joinedVersion: target.version + 1, at: now)
            {
                try bumpMembershipVersion(target.id, at: now)
            }
            return target.id
        }
        return try requireEvent(id)
    }

    /// Removes articles from an event. An event left empty keeps its ID until retention drops it.
    @discardableResult
    func removeArticles(_ articleIDs: [String], fromEvent eventID: String, at date: Date = Date()) throws -> StoryEvent
    {
        let id = try inEventTransaction { () throws -> String in
            let target = try liveEvent(eventID)
            var changed = false
            for member in try resolvedMembers(articleIDs) {
                try eventRows(
                    "DELETE FROM event_members WHERE article_id = ? AND event_id = ?;",
                    [.text(member), .text(target.id)])
                if sqlite3_changes(db) > 0 { changed = true }
            }
            if changed { try bumpMembershipVersion(target.id, at: date.timeIntervalSince1970) }
            return target.id
        }
        return try requireEvent(id)
    }

    /// Moves every member of `absorbedID` into `survivorID`. The absorbed ID forwards to the survivor,
    /// so stored links keep resolving; article rows and their read/save state are untouched.
    @discardableResult
    /// With `expectedVersions`, the merge is refused if either event changed since the caller read it.
    func mergeEvents(
        _ absorbedID: String, into survivorID: String, expectedVersions: (absorbed: Int, survivor: Int)? = nil,
        at date: Date = Date()
    ) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let survivor = try liveEvent(survivorID)
            let absorbed = try liveEvent(absorbedID)
            guard absorbed.id != survivor.id else { return survivor.id }
            if let expectedVersions,
                expectedVersions.absorbed != absorbed.version || expectedVersions.survivor != survivor.version
            {
                throw Self.eventError("An event changed before it could be merged")
            }
            let now = date.timeIntervalSince1970
            try eventRows(
                "UPDATE event_members SET event_id = ?, joined_version = ? WHERE event_id = ?;",
                [.text(survivor.id), .integer(survivor.version + 1), .text(absorbed.id)])
            let moved = sqlite3_changes(db) > 0
            // Forwards stay one hop deep.
            try eventRows(
                "UPDATE events SET merged_into = ? WHERE merged_into = ?;", [.text(survivor.id), .text(absorbed.id)])
            try eventRows(
                "UPDATE events SET merged_into = ?, membership_version = membership_version + 1, updated_at = ? WHERE id = ?;",
                [.text(survivor.id), .real(now), .text(absorbed.id)])
            if moved { try bumpMembershipVersion(survivor.id, at: now) }
            return survivor.id
        }
        return try requireEvent(id)
    }

    /// Moves some members into a new event with its own stable ID. The original keeps its ID and the
    /// remaining members; both member sets stay non-empty.
    @discardableResult
    func splitEvent(_ eventID: String, movingArticles articleIDs: [String], at date: Date = Date()) throws -> StoryEvent
    {
        let id = try inEventTransaction { () throws -> String in
            let source = try liveEvent(eventID)
            let moving = try resolvedMembers(articleIDs)
            let memberRows = try eventRows(
                "SELECT article_id FROM event_members WHERE event_id = ?;", [.text(source.id)])
            let current = Set(memberRows.compactMap { $0[0] })
            guard !moving.isEmpty, Set(moving).isSubset(of: current), moving.count < current.count else {
                throw Self.eventError("A split moves some, but not all, members of the event")
            }
            return try insertEvent(members: moving, at: date.timeIntervalSince1970)
        }
        return try requireEvent(id)
    }

    func requireEvent(_ id: String) throws -> StoryEvent {
        guard let event = try fetchEvent(id: id) else { throw Self.eventError("Unknown event") }
        return event
    }

    func liveEvent(_ id: String) throws -> (id: String, version: Int) {
        guard let live = try resolvedEventID(id),
            let version = try eventRows("SELECT membership_version FROM events WHERE id = ?;", [.text(live)]).first?[0]
                .flatMap({ Int($0) })
        else {
            throw Self.eventError("Unknown event")
        }
        return (live, version)
    }

    func insertEvent(members: [String], at now: Double) throws -> String {
        guard !members.isEmpty else { throw Self.eventError("An event needs at least one article") }
        let id = UUID().uuidString
        try eventRows(
            "INSERT INTO events(id, membership_version, created_at, updated_at) VALUES (?, 1, ?, ?);",
            [.text(id), .real(now), .real(now)])
        _ = try assignMembers(members, to: id, joinedVersion: 1, at: now)
        return id
    }

    /// Membership references the surviving stored document, never an alias or a reconciled copy.
    func memberArticleID(_ id: String) throws -> String? {
        var resolved = try resolvedArticleID(id)
        if let survivor = try eventRows(
            "SELECT survivor_id FROM article_reconciliations WHERE duplicate_id = ?;", [.text(resolved)]
        ).first?[0] {
            resolved = survivor
        }
        return try eventRows("SELECT 1 FROM articles WHERE id = ?;", [.text(resolved)]).isEmpty ? nil : resolved
    }

    func resolvedMembers(_ articleIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        var members: [String] = []
        for articleID in articleIDs {
            guard let member = try memberArticleID(articleID) else {
                throw Self.eventError("Unknown event member article")
            }
            if seen.insert(member).inserted { members.append(member) }
        }
        return members
    }

    /// Moves members into `eventID`; every event that loses an article gains one membership version.
    /// Returns whether the target's member set changed.
    func assignMembers(_ members: [String], to eventID: String, joinedVersion: Int, at now: Double) throws
        -> Bool
    {
        var losing = Set<String>()
        var changed = false
        for member in members {
            try Task.checkCancellation()
            let previous = try eventRows("SELECT event_id FROM event_members WHERE article_id = ?;", [.text(member)])
                .first?[0]
            if previous == eventID { continue }
            if let previous { losing.insert(previous) }
            try eventRows(
                """
                INSERT INTO event_members(article_id, event_id, joined_version) VALUES (?, ?, ?)
                ON CONFLICT(article_id) DO UPDATE SET event_id = excluded.event_id, joined_version = excluded.joined_version;
                """, [.text(member), .text(eventID), .integer(joinedVersion)])
            changed = true
        }
        for event in losing {
            try bumpMembershipVersion(event, at: now)
        }
        return changed
    }

    func bumpMembershipVersion(_ eventID: String, at now: Double) throws {
        try eventRows(
            "UPDATE events SET membership_version = membership_version + 1, updated_at = ? WHERE id = ?;",
            [.real(now), .text(eventID)])
    }

    /// Event-matching candidates: FTS hits within `window` of `date`, best ranked first and capped at
    /// `limit`. Hidden reconciled copies, `articleID` itself and members of events unchanged since
    /// `activeSince` are excluded, so closed events never grow.
    func eventCandidateRows(
        matching query: String, in span: EventTimeSpan, activeSince: Date, excluding articleID: String, limit: Int
    ) throws -> [EventCandidateRow] {
        let sql = """
            SELECT a.id, a.title, coalesce(a.description, ''), m.event_id
            FROM articles_fts fts
            JOIN article_fts_rows f ON f.fts_rowid = fts.rowid
            JOIN articles a ON a.id = f.article_id
            LEFT JOIN event_members m ON m.article_id = a.id
            LEFT JOIN events e ON e.id = m.event_id
            WHERE articles_fts MATCH ? AND a.id != ?
                AND \(Self.articleDateOrder) BETWEEN ? AND ?
                AND \(Self.visibleArticle)
                AND (m.event_id IS NULL OR e.updated_at >= ?)
            ORDER BY fts.rank, a.id
            LIMIT ?;
            """
        let center = span.around.timeIntervalSince1970
        let window = span.window
        return try eventRows(
            sql,
            [
                .text(query), .text(articleID), .real(center - window), .real(center + window),
                .real(activeSince.timeIntervalSince1970), .integer(limit),
            ]
        ).compactMap { row in
            guard let id = row[0], let title = row[1] else { return nil }
            return EventCandidateRow(id: id, title: title, description: row[2] ?? "", eventID: row[3])
        }
    }

    /// One actor-isolated snapshot; no memberships, analysis, read or saved state are written.
    /// Publication time stays unknown here rather than falling back to ingestion time.
    func relatedStoryEventRows(eventID: String) throws
        -> (target: [EventMatchRow], candidates: [(id: String, members: [EventMatchRow])])
    {
        try Task.checkCancellation()
        guard let live = try resolvedEventID(eventID) else { return ([], []) }
        func members(_ id: String) throws -> [EventMatchRow] {
            try eventMatchRows(
                """
                SELECT a.id, a.title, coalesce(a.description, ''), a.source, a.published_at, m.event_id, 0
                FROM event_members m JOIN articles a ON a.id = m.article_id
                WHERE m.event_id = ? AND \(Self.visibleArticle)
                ORDER BY a.published_at, a.id LIMIT ?;
                """, [.text(id), .integer(EventStoryRelation.memberLimit + 1)])
        }
        let target = try members(live)
        guard !target.isEmpty, target.count <= EventStoryRelation.memberLimit,
            target.allSatisfy({ $0.date != DateParser.unknownDate }), let first = target.first,
            let query = EventMatchKey(title: first.title, description: first.description).ftsQuery
        else { return ([], []) }
        // Search only the preceding window and return at most 80 ranked FTS rows. Repeated
        // coverage can crowd out candidates, an accepted recall limit for this experiment.
        let rows = try eventRows(
            """
            SELECT m.event_id FROM articles_fts fts
            JOIN article_fts_rows f ON f.fts_rowid = fts.rowid
            JOIN articles a ON a.id = f.article_id
            JOIN event_members m ON m.article_id = a.id
            JOIN events e ON e.id = m.event_id
            WHERE articles_fts MATCH ? AND m.event_id != ? AND e.merged_into IS NULL
                AND a.published_at >= ? AND a.published_at < ? AND \(Self.visibleArticle)
            ORDER BY fts.rank, a.id LIMIT ?;
            """,
            [
                .text(query), .text(live),
                .real(first.date.addingTimeInterval(-EventStoryRelation.window).timeIntervalSince1970),
                .real(first.date.timeIntervalSince1970), .integer(EventStoryRelation.candidateLimit * 2),
            ])
        var seen = Set<String>()
        var candidates: [(id: String, members: [EventMatchRow])] = []
        for row in rows {
            try Task.checkCancellation()
            guard let id = row[0], seen.insert(id).inserted else { continue }
            candidates.append((id, try members(id)))
            if candidates.count == EventStoryRelation.candidateLimit { break }
        }
        return (target, candidates)
    }

    /// Names that appear in more than `share` of the events published in the window before `end`, and in at least
    /// `minimumEvents` of them: too common to tie two events to one developing story (a head of state appears across
    /// unrelated stories). The minimum keeps a small or new library from treating every name as common.
    func commonStoryTerms(_ terms: Set<String>, before end: Date, share: Double, minimumEvents: Int = 10) throws
        -> Set<String>
    {
        try Task.checkCancellation()
        let start = end.addingTimeInterval(-EventStoryRelation.window).timeIntervalSince1970
        let total =
            try eventRows(
                """
                SELECT count(DISTINCT m.event_id) FROM articles a JOIN event_members m ON m.article_id = a.id
                WHERE a.published_at >= ? AND a.published_at < ? AND \(Self.visibleArticle);
                """, [.real(start), .real(end.timeIntervalSince1970)]
            ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
        guard total > 0 else { return [] }
        var common = Set<String>()
        for term in terms.sorted().prefix(64) {
            try Task.checkCancellation()
            let words = term.split { !$0.isLetter && !$0.isNumber }
            guard !words.isEmpty else { continue }
            let phrase = "\"" + words.joined(separator: " ") + "\""
            let count =
                try eventRows(
                    """
                    SELECT count(DISTINCT m.event_id) FROM articles_fts fts
                    JOIN article_fts_rows f ON f.fts_rowid = fts.rowid
                    JOIN articles a ON a.id = f.article_id
                    JOIN event_members m ON m.article_id = a.id
                    WHERE articles_fts MATCH ? AND a.published_at >= ? AND a.published_at < ?
                        AND \(Self.visibleArticle);
                    """, [.text(phrase), .real(start), .real(end.timeIntervalSince1970)]
                ).first?.first.flatMap { $0.flatMap(Int.init) } ?? 0
            if count >= minimumEvents && Double(count) > Double(total) * share { common.insert(term) }
        }
        return common
    }
}

/// A publication time and the window either side of it.
struct EventTimeSpan {
    let around: Date
    let window: TimeInterval
}

/// An event-matching candidate from full-text search.
struct EventCandidateRow: Equatable {
    let id: String
    let title: String
    let description: String
    let eventID: String?
}
