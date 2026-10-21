import Foundation
import SQLite3
import os

// Event reading state, feed summaries and article embeddings.
extension DatabaseEngine {
    /// Records that the reader has seen the event up to `version` (the current version by default,
    /// never beyond it). Seen versions only grow. Article read and saved state is not touched.
    @discardableResult
    func markEventSeen(_ eventID: String, version: Int? = nil, at date: Date = Date()) throws -> Int {
        try inEventTransaction { () throws -> Int in
            let live = try liveEvent(eventID)
            let seen = max(1, min(version ?? live.version, live.version))
            try eventRows(
                """
                INSERT INTO event_state(event_id, seen_version, seen_at) VALUES (?, ?, ?)
                ON CONFLICT(event_id) DO UPDATE SET seen_version = max(seen_version, excluded.seen_version), seen_at = excluded.seen_at;
                """, [.text(live.id), .integer(seen), .real(date.timeIntervalSince1970)])
            return try eventRows("SELECT seen_version FROM event_state WHERE event_id = ?;", [.text(live.id)]).first?[0]
                .flatMap { Int($0) } ?? seen
        }
    }

    func eventSeenVersion(_ eventID: String) throws -> Int? {
        guard let live = try resolvedEventID(eventID) else { return nil }
        return try eventRows("SELECT seen_version FROM event_state WHERE event_id = ?;", [.text(live)]).first?[0]
            .flatMap { Int($0) }
    }

    /// Every visible member of the events that hold any of `articleIDs`, newest first, with the
    /// state a feed card needs. No article text beyond the title is read.
    func eventFeedSummaries(forArticles articleIDs: [String]) throws -> [EventFeedSummary] {
        let eventIDs = try eventIDs(containing: articleIDs)
        var summaries: [EventFeedSummary] = []
        for start in stride(from: 0, to: eventIDs.count, by: 400) {
            summaries += try feedSummaries(ofEvents: Array(eventIDs[start..<min(start + 400, eventIDs.count)]))
        }
        return summaries
    }

    /// Distinct events holding any of `articleIDs`, in first-seen order.
    private func eventIDs(containing articleIDs: [String]) throws -> [String] {
        var eventIDs: [String] = []
        var seen = Set<String>()
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            for row in try eventRows(
                "SELECT DISTINCT event_id FROM event_members WHERE article_id IN (\(placeholders));",
                slice.map { .text($0) })
            {
                if let id = row[0], seen.insert(id).inserted { eventIDs.append(id) }
            }
        }
        return eventIDs
    }

    /// Summaries of at most 400 events; rows arrive grouped by event, newest member first.
    private func feedSummaries(ofEvents eventIDs: [String]) throws -> [EventFeedSummary] {
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ", ")
        let rows = try eventRows(
            """
            SELECT m.event_id, e.membership_version, st.seen_version, a.id, a.source, a.title,
                   \(Self.articleDateOrder), m.joined_version, s.is_read, s.is_saved, a.canonical_url
            FROM event_members m
            JOIN events e ON e.id = m.event_id
            JOIN articles a ON a.id = m.article_id
            JOIN article_state s ON s.article_id = a.id
            LEFT JOIN event_state st ON st.event_id = m.event_id
            WHERE m.event_id IN (\(placeholders)) AND \(Self.visibleArticle)
            ORDER BY m.event_id, \(Self.articleDateOrder) DESC, a.id;
            """, eventIDs.map { .text($0) })
        var headers: [EventFeedSummary] = []
        var members: [[EventFeedMember]] = []
        for row in rows {
            guard let eventID = row[0], let articleID = row[3] else { continue }
            if headers.last?.eventID != eventID {
                headers.append(
                    EventFeedSummary(
                        eventID: eventID, membershipVersion: row[1].flatMap { Int($0) } ?? 1,
                        seenVersion: row[2].flatMap { Int($0) }, members: []))
                members.append([])
            }
            members[members.count - 1].append(
                EventFeedMember(
                    articleID: articleID, source: FeedCatalog.publisher(forLink: row[10] ?? "") ?? row[4] ?? "",
                    title: row[5] ?? "",
                    date: Date(timeIntervalSince1970: row[6].flatMap { Double($0) } ?? 0),
                    joinedVersion: row[7].flatMap { Int($0) } ?? 1,
                    isRead: row[8] == "1", isSaved: row[9] == "1"))
        }
        let summaries = zip(headers, members).map { header, members in
            EventFeedSummary(
                eventID: header.eventID, membershipVersion: header.membershipVersion,
                seenVersion: header.seenVersion, members: members)
        }
        return summaries
    }

    /// Drops events left without members unless an overview still refers to them. A forward dies with
    /// its survivor; merges keep forwards one hop deep, so two passes clear them.
    func pruneEmptyEvents() throws {
        for _ in 0..<2 {
            try executeSimple(
                """
                DELETE FROM events WHERE merged_into IS NULL
                    AND NOT EXISTS (SELECT 1 FROM event_members m WHERE m.event_id = events.id)
                    AND NOT EXISTS (SELECT 1 FROM event_overviews o WHERE o.event_id = events.id);
                """)
        }
    }

    // MARK: - Article Embeddings (#127, #307)

    /// Retrieves stored normalized embedding vectors for the given article IDs matching the model version.
    func fetchArticleEmbeddings(articleIDs: [String], modelVersion: Int) throws -> [String: [Float]] {
        guard !articleIDs.isEmpty else { return [:] }
        var result: [String: [Float]] = [:]
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            let sql =
                "SELECT article_id, vector FROM article_embeddings WHERE model_version = ? AND article_id IN (\(placeholders));"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to prepare embedding query"])
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(modelVersion))
            for (idx, id) in slice.enumerated() {
                sqlite3_bind_text(statement, Int32(idx + 2), id, -1, Self.sqliteTransient)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                    let blobBytes = sqlite3_column_blob(statement, 1)
                else { continue }
                let id = String(cString: idText)
                let byteCount = Int(sqlite3_column_bytes(statement, 1))
                let floatCount = byteCount / MemoryLayout<Float>.stride
                guard floatCount == 384 else { continue }
                // SQLite does not promise Float alignment for blob memory, so copy the bytes instead of rebinding them.
                let floats = [Float](unsafeUninitializedCapacity: floatCount) { buffer, initialized in
                    memcpy(buffer.baseAddress!, blobBytes, floatCount * MemoryLayout<Float>.stride)
                    initialized = floatCount
                }
                result[id] = floats
            }
        }
        return result
    }

    /// Stores normalized float vectors for articles inside a single transaction.
    func upsertArticleEmbeddings(_ embeddings: [String: [Float]], modelVersion: Int) throws {
        guard !embeddings.isEmpty else { return }
        try beginTransaction()
        do {
            let sql = """
                INSERT INTO article_embeddings (article_id, model_version, vector) VALUES (?, ?, ?)
                ON CONFLICT(article_id) DO UPDATE SET model_version = excluded.model_version, vector = excluded.vector;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to prepare embedding upsert"])
            }
            defer { sqlite3_finalize(statement) }

            for (articleID, vector) in embeddings {
                guard vector.count == 384 else { continue }
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, articleID, -1, Self.sqliteTransient)
                sqlite3_bind_int(statement, 2, Int32(modelVersion))
                let byteCount = vector.count * MemoryLayout<Float>.stride
                _ = vector.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, 3, raw.baseAddress, Int32(byteCount), Self.sqliteTransient)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to insert article embedding for \(articleID)"])
                }
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }
}
