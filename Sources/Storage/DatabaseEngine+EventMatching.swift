import Foundation
import SQLite3
import os

// Event matching state, exclusions and matcher-driven membership changes.
extension DatabaseEngine {
    static let eventMatchColumns = """
        SELECT a.id, a.title, coalesce(a.description, ''), a.source, a.published_at, m.event_id,
            ms.article_id IS NOT NULL
        FROM articles a
        LEFT JOIN event_members m ON m.article_id = a.id
        LEFT JOIN event_match_state ms ON ms.article_id = a.id
        """

    func eventMatchRows(_ sql: String, _ values: [EventValue]) throws -> [EventMatchRow] {
        try eventRows(sql, values).compactMap { row in
            guard let id = row[0], let title = row[1] else { return nil }
            return EventMatchRow(
                id: id, title: title, description: row[2] ?? "", source: row[3] ?? "",
                date: Date(timeIntervalSince1970: row[4].flatMap { Double($0) } ?? 0), eventID: row[5],
                previouslyMatched: row[6] == "1")
        }
    }

    /// Pending recent articles and members of still-active events, oldest first. This also upgrades
    /// active events whose last publication is older than the window; inactive archived groups stay untouched.
    func pendingEventMatchRows(activeSince: Date, matcherVersion: Int, limit: Int) throws -> [EventMatchRow] {
        try eventMatchRows(
            """
            \(Self.eventMatchColumns)
            WHERE (ms.article_id IS NULL OR ms.matcher_version < ?)
                AND (\(Self.articleDateOrder) >= ? OR EXISTS (
                    SELECT 1 FROM events active WHERE active.id = m.event_id AND active.updated_at >= ?))
                AND \(Self.visibleArticle)
            ORDER BY \(Self.articleDateOrder), a.id
            LIMIT ?;
            """,
            [
                .integer(matcherVersion), .real(activeSince.timeIntervalSince1970),
                .real(activeSince.timeIntervalSince1970), .integer(limit),
            ])
    }

    func eventMatchRows(articleIDs: [String]) throws -> [EventMatchRow] {
        var rows: [EventMatchRow] = []
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            rows += try eventMatchRows(
                "\(Self.eventMatchColumns) WHERE a.id IN (\(placeholders));", slice.map { .text($0) })
        }
        return rows
    }

    /// The live event, its membership version and its members, for a whole-event check.
    func eventMatchMembers(eventID: String) throws -> EventMemberSnapshot? {
        guard let live = try? liveEvent(eventID) else { return nil }
        let members = try eventMatchRows("\(Self.eventMatchColumns) WHERE m.event_id = ?;", [.text(live.id)])
        return EventMemberSnapshot(id: live.id, version: live.version, members: members)
    }

    /// Every live event updated since `activeSince`, with its members, for merging fragments of one story.
    func activeEventMembers(since activeSince: Date) throws -> [EventMemberSnapshot] {
        let since = activeSince.timeIntervalSince1970
        let versions = try eventRows(
            "SELECT id, membership_version FROM events WHERE merged_into IS NULL AND updated_at >= ? ORDER BY id;",
            [.real(since)])
        let rows = try eventMatchRows(
            """
            \(Self.eventMatchColumns)
            JOIN events e ON e.id = m.event_id
            WHERE e.merged_into IS NULL AND e.updated_at >= ?;
            """, [.real(since)])
        let byEvent = Dictionary(grouping: rows) { $0.eventID ?? "" }
        return versions.compactMap { row in
            guard let id = row[0], let members = byEvent[id], !members.isEmpty else { return nil }
            return EventMemberSnapshot(
                id: id, version: row[1].flatMap { Int($0) } ?? 1, members: members.sorted { $0.id < $1.id })
        }
    }

    /// Apply a matcher upgrade only to the exact active membership/text snapshot that was assessed.
    /// The first group retains the event ID; all moves, invalidation and processed markers commit together.
    func repartitionEvent(
        _ expected: EventMemberSnapshot, groups: [[String]], matcherVersion: Int, activeSince: Date, at now: Date
    ) throws -> Set<String>? {
        let eventID = expected.id
        let expectedVersion = expected.version
        let expectedMembers = expected.members
        return try inEventTransaction { () throws -> Set<String>? in
            guard let event = try fetchEvent(id: eventID), event.id == eventID,
                event.membershipVersion == expectedVersion, event.updatedAt >= activeSince,
                let current = try eventMatchMembers(eventID: eventID),
                Set(current.members) == Set(expectedMembers)
            else { return nil }
            let ids = groups.flatMap { $0 }
            guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }),
                ids.count == expectedMembers.count, Set(ids).count == ids.count,
                Set(ids) == Set(expectedMembers.map(\.id))
            else { throw Self.eventError("Invalid matcher partition") }
            for group in groups {
                for member in group where try excluded(member, from: group) {
                    throw Self.eventError("Excluded reports cannot share a matcher partition")
                }
            }
            var changed: Set<String> = []
            if groups.count > 1 {
                changed.insert(eventID)
                for group in groups.dropFirst() {
                    changed.insert(try insertEvent(members: group, at: now.timeIntervalSince1970))
                }
                try eventRows("DELETE FROM event_overviews WHERE event_id = ?;", [.text(eventID)])
            }
            for id in ids { try markMatched(id, matcherVersion: matcherVersion, at: now.timeIntervalSince1970) }
            return changed
        }
    }

    /// Articles the user marked as a different event from `articleID`.
    func eventExclusions(of articleID: String) throws -> Set<String> {
        guard let member = try memberArticleID(articleID) else { return [] }
        return try eventExclusions(for: [member])[member] ?? []
    }

    /// A symmetric exclusion snapshot for stored member IDs, in bounded SQLite batches.
    func eventExclusions(for articleIDs: [String]) throws -> [String: Set<String>] {
        let ids = Set(articleIDs).sorted()
        var exclusions: [String: Set<String>] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            try Task.checkCancellation()
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try eventRows(
                """
                SELECT article_id, other_article_id FROM event_exclusions
                WHERE article_id IN (\(placeholders)) OR other_article_id IN (\(placeholders));
                """, (slice + slice).map { .text($0) })
            for row in rows {
                guard let first = row[0], let second = row[1] else { continue }
                exclusions[first, default: []].insert(second)
                exclusions[second, default: []].insert(first)
            }
        }
        return exclusions
    }

    func markEventMatchProcessed(_ articleIDs: [String], matcherVersion: Int, at date: Date = Date()) throws {
        try inEventTransaction { () throws -> Void in
            for articleID in articleIDs {
                try markMatched(articleID, matcherVersion: matcherVersion, at: date.timeIntervalSince1970)
            }
        }
    }

    private func markMatched(_ articleID: String, matcherVersion: Int, at now: Double) throws {
        // An article deleted in the meantime has nothing left to mark.
        try eventRows(
            """
            INSERT INTO event_match_state(article_id, matcher_version, processed_at)
            SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM articles WHERE id = ?)
            ON CONFLICT(article_id) DO UPDATE SET matcher_version = excluded.matcher_version, processed_at = excluded.processed_at;
            """, [.text(articleID), .integer(matcherVersion), .real(now), .text(articleID)])
    }

    private func excluded(_ articleID: String, from others: [String]) throws -> Bool {
        for other in others where other != articleID {
            let (low, high) = articleID < other ? (articleID, other) : (other, articleID)
            if try !eventRows(
                "SELECT 1 FROM event_exclusions WHERE article_id = ? AND other_article_id = ?;",
                [.text(low), .text(high)]
            ).isEmpty {
                return true
            }
        }
        return false
    }

    /// Applies a matcher decision only if the state it was made against still holds: the target event
    /// keeps the expected version, new-event partners are still unassigned and no pair is excluded.
    /// Otherwise nothing changes and the article stays pending for the next pass.
    func applyEventMatch(
        _ articleID: String, _ decision: EventMatchDecision, matcherVersion: Int, at date: Date = Date()
    ) throws -> EventMatchOutcome {
        try inEventTransaction { () throws -> EventMatchOutcome in
            let now = date.timeIntervalSince1970
            guard let member = try memberArticleID(articleID) else { return .conflict }
            switch decision {
            case .join(let eventID, let expectedVersion):
                guard try resolvedEventID(eventID) == eventID, let live = try? liveEvent(eventID),
                    live.version == expectedVersion
                else { return .conflict }
                let members = try eventRows(
                    "SELECT article_id FROM event_members WHERE event_id = ?;", [.text(eventID)]
                ).compactMap { $0[0] }
                guard !(try excluded(member, from: members)) else { return .conflict }
                if try assignMembers([member], to: eventID, joinedVersion: live.version + 1, at: now) {
                    try bumpMembershipVersion(eventID, at: now)
                }
                try markMatched(member, matcherVersion: matcherVersion, at: now)
                return .joined(eventID)
            case .create(let partners):
                var group = [member]
                for partner in partners {
                    guard let resolved = try memberArticleID(partner), !group.contains(resolved),
                        try eventRows("SELECT 1 FROM event_members WHERE article_id = ?;", [.text(resolved)]).isEmpty,
                        !(try excluded(resolved, from: group))
                    else { return .conflict }
                    group.append(resolved)
                }
                guard group.count >= 2 else { return .conflict }
                let id = try insertEvent(members: group, at: now)
                for article in group { try markMatched(article, matcherVersion: matcherVersion, at: now) }
                return .created(id)
            }
        }
    }

    /// "These are different events": takes the article out of the event and records an exclusion
    /// against every remaining member. Later passes may match it elsewhere, never back with them.
    @discardableResult
    func separateArticle(_ articleID: String, fromEvent eventID: String, at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let target = try liveEvent(eventID)
            guard let member = try memberArticleID(articleID) else {
                throw Self.eventError("Unknown event member article")
            }
            let members = try eventRows("SELECT article_id FROM event_members WHERE event_id = ?;", [.text(target.id)])
                .compactMap { $0[0] }
            guard members.contains(member) else { throw Self.eventError("The article is not part of this event") }
            let now = date.timeIntervalSince1970
            try eventRows(
                "DELETE FROM event_members WHERE article_id = ? AND event_id = ?;", [.text(member), .text(target.id)])
            try bumpMembershipVersion(target.id, at: now)
            for other in members where other != member {
                let (low, high) = member < other ? (member, other) : (other, member)
                try eventRows(
                    "INSERT OR IGNORE INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                    [.text(low), .text(high), .real(now)])
            }
            try eventRows("DELETE FROM event_match_state WHERE article_id = ?;", [.text(member)])
            return target.id
        }
        return try requireEvent(id)
    }
}

/// A live event, its membership version and its members, as the matcher assessed them.
struct EventMemberSnapshot {
    let id: String
    let version: Int
    let members: [EventMatchRow]
}
