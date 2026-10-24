import Foundation
import SQLite3
import os

// Events, event overviews, event matching state, reading state and article embeddings.
extension DatabaseEngine {
    // MARK: - Event Overviews

    /// Records an event overview only after deterministic verification of claims.
    /// If verification fails, converts the overview to a safe fallback excerpts document
    /// and stores that instead, guaranteeing a failed retelling is never stored as finished synthesized overview.
    func recordVerifiedOverview(
        _ overview: EventOverviewDocument,
        passages: [EvidencePassage],
        articles: [FeedArticle]
    ) throws -> (saved: Bool, document: EventOverviewDocument) {
        let report = OverviewClaimVerifier.verifyOverview(overview, passages: passages, articles: articles)
        let documentToStore: EventOverviewDocument
        if report.isFullyVerified {
            documentToStore = overview
        } else {
            documentToStore = OverviewClaimVerifier.createFallbackOverview(
                from: overview,
                passages: passages,
                articles: articles,
                report: report
            )
        }
        let saved = try recordEventOverview(documentToStore)
        return (saved: saved, document: documentToStore)
    }

    @discardableResult
    func recordEventOverview(_ overview: EventOverviewDocument, expectedArticleInputs: [String: String]? = nil) throws
        -> Bool
    {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

        if let expectedArticleInputs {
            for (id, hash) in expectedArticleInputs {
                guard try fetchArticles(limit: 1, id: id).first?.publisherInputHash == hash else { return false }
            }
        }

        // Check if an existing overview exists for this event
        var checkStmt: OpaquePointer?
        let checkSql = "SELECT id, membership_version FROM event_overviews WHERE event_id = ?;"
        guard sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare check statement for event overview"])
        }
        defer { sqlite3_finalize(checkStmt) }

        sqlite3_bind_text(checkStmt, 1, overview.eventID, -1, Self.sqliteTransient)
        var existingOverviewID: String?
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingVersion = Int(sqlite3_column_int(checkStmt, 1))
            // An older result never overwrites a newer version
            if existingVersion > overview.membershipVersion {
                return false
            }
            if let idText = sqlite3_column_text(checkStmt, 0) {
                existingOverviewID = String(cString: idText)
            }
        }

        // If an existing overview exists with older/same version, remove it first
        if let oldID = existingOverviewID {
            var delStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM event_overviews WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK
            else {
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to prepare overview deletion: \(String(cString: sqlite3_errmsg(db)))"
                    ])
            }
            defer { sqlite3_finalize(delStmt) }
            sqlite3_bind_text(delStmt, 1, oldID, -1, Self.sqliteTransient)
            let stepStatus = sqlite3_step(delStmt)
            guard stepStatus == SQLITE_DONE else {
                throw NSError(
                    domain: "DatabaseEngine", code: Int(stepStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to delete existing event overview: \(String(cString: sqlite3_errmsg(db)))"
                    ])
            }
        }

        let encoder = JSONEncoder()
        let factsJSON: String
        if let evidence = overview.content.evidenceSections, !evidence.isEmpty {
            struct OverviewFactsEnvelope: Codable {
                let facts: [OverviewFact]
                let evidenceSections: OverviewEvidenceSections?
            }
            let envelope = OverviewFactsEnvelope(facts: overview.facts, evidenceSections: evidence)
            factsJSON = String(decoding: try encoder.encode(envelope), as: UTF8.self)
        } else {
            factsJSON = String(decoding: try encoder.encode(overview.facts), as: UTF8.self)
        }
        let memberArticleIDsJSON = String(decoding: try encoder.encode(overview.memberArticleIDs), as: UTF8.self)
        var leadImageJSON: String?
        if let leadImage = overview.leadImage {
            leadImageJSON = String(decoding: try encoder.encode(leadImage), as: UTF8.self)
        }

        let insertOverviewSql = """
            INSERT INTO event_overviews (
                id, event_id, membership_version, input_text_hash,
                schema_version, analysis_version, title, summary,
                facts_json, lead_image_json, member_article_ids_json,
                kind, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var overviewStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertOverviewSql, -1, &overviewStmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare insert statement for event overview"])
        }
        defer { sqlite3_finalize(overviewStmt) }

        sqlite3_bind_text(overviewStmt, 1, overview.id, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 2, overview.eventID, -1, Self.sqliteTransient)
        sqlite3_bind_int(overviewStmt, 3, Int32(overview.membershipVersion))
        sqlite3_bind_text(overviewStmt, 4, overview.inputTextHash, -1, Self.sqliteTransient)
        sqlite3_bind_int(overviewStmt, 5, Int32(overview.schemaVersion))
        sqlite3_bind_int(overviewStmt, 6, Int32(overview.analysisVersion))
        sqlite3_bind_text(overviewStmt, 7, overview.title, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 8, overview.summary, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 9, factsJSON, -1, Self.sqliteTransient)
        if let lij = leadImageJSON {
            sqlite3_bind_text(overviewStmt, 10, lij, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(overviewStmt, 10)
        }
        sqlite3_bind_text(overviewStmt, 11, memberArticleIDsJSON, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 12, overview.kind.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_double(overviewStmt, 13, overview.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(overviewStmt, 14, overview.updatedAt.timeIntervalSince1970)

        guard sqlite3_step(overviewStmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to insert event overview: \(errMsg)"])
        }

        let insertCitationSql = """
            INSERT INTO event_overview_citations (
                id, overview_id, article_id, passage_id, passage_fingerprint,
                quote, source_title, source_name, source_url, published_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var citationStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertCitationSql, -1, &citationStmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare citation statement"])
        }
        defer { sqlite3_finalize(citationStmt) }

        for citation in overview.citations.values {
            sqlite3_reset(citationStmt)
            // Citation IDs are unique within one overview only (`cite_<passage>_<n>`), so the row key carries the
            // overview ID: another event citing the same passage must not collide with this one.
            sqlite3_bind_text(
                citationStmt, 1, Self.citationRowID(overviewID: overview.id, citationID: citation.id), -1,
                Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 2, overview.id, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 3, citation.articleID, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 4, citation.passageID, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 5, citation.passageFingerprint, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 6, citation.quote, -1, Self.sqliteTransient)
            if let st = citation.sourceTitle {
                sqlite3_bind_text(citationStmt, 7, st, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(citationStmt, 7)
            }
            if let sn = citation.sourceName {
                sqlite3_bind_text(citationStmt, 8, sn, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(citationStmt, 8)
            }
            if let su = citation.sourceURL {
                sqlite3_bind_text(citationStmt, 9, su, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(citationStmt, 9)
            }
            if let pa = citation.publishedAt {
                sqlite3_bind_double(citationStmt, 10, pa.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(citationStmt, 10)
            }

            guard sqlite3_step(citationStmt) == SQLITE_DONE else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to insert event overview citation: \(errMsg)"])
            }
        }

        try commitTransaction()
        return true
    }

    func fetchEventOverview(eventID: String) throws -> EventOverviewDocument? {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }

        let overviewSql = """
            SELECT id, event_id, membership_version, input_text_hash,
                   schema_version, analysis_version, title, summary,
                   facts_json, lead_image_json, member_article_ids_json,
                   kind, created_at, updated_at
            FROM event_overviews
            WHERE event_id = ?;
            """
        var overviewStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, overviewSql, -1, &overviewStmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetch overview statement"])
        }
        defer { sqlite3_finalize(overviewStmt) }

        sqlite3_bind_text(overviewStmt, 1, eventID, -1, Self.sqliteTransient)
        guard sqlite3_step(overviewStmt) == SQLITE_ROW else {
            return nil
        }

        let id = String(cString: sqlite3_column_text(overviewStmt, 0))
        let fetchedEventID = String(cString: sqlite3_column_text(overviewStmt, 1))
        let membershipVersion = Int(sqlite3_column_int(overviewStmt, 2))
        let inputTextHash = String(cString: sqlite3_column_text(overviewStmt, 3))
        let schemaVersion = Int(sqlite3_column_int(overviewStmt, 4))
        let analysisVersion = Int(sqlite3_column_int(overviewStmt, 5))
        let title = String(cString: sqlite3_column_text(overviewStmt, 6))
        let summary = String(cString: sqlite3_column_text(overviewStmt, 7))
        let factsJSON = String(cString: sqlite3_column_text(overviewStmt, 8))
        let leadImageJSON = sqlite3_column_text(overviewStmt, 9).map { String(cString: $0) }
        let memberArticleIDsJSON = String(cString: sqlite3_column_text(overviewStmt, 10))
        let kindString = String(cString: sqlite3_column_text(overviewStmt, 11))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(overviewStmt, 12))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(overviewStmt, 13))

        let decoder = JSONDecoder()
        var facts: [OverviewFact] = []
        var evidenceSections: OverviewEvidenceSections?
        let trimmedFacts = factsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFacts.hasPrefix("{") {
            struct OverviewFactsEnvelope: Codable {
                let facts: [OverviewFact]
                let evidenceSections: OverviewEvidenceSections?
            }
            if let envelope = try? decoder.decode(OverviewFactsEnvelope.self, from: Data(factsJSON.utf8)) {
                facts = envelope.facts
                evidenceSections = envelope.evidenceSections
            }
        } else {
            facts = (try? decoder.decode([OverviewFact].self, from: Data(factsJSON.utf8))) ?? []
        }
        let memberArticleIDs = (try? decoder.decode([String].self, from: Data(memberArticleIDsJSON.utf8))) ?? []
        var leadImage: OverviewLeadImage?
        if let lij = leadImageJSON, let data = lij.data(using: .utf8) {
            leadImage = try? decoder.decode(OverviewLeadImage.self, from: data)
        }
        let kind = OverviewKind(rawValue: kindString) ?? .synthesized

        // Fetch citations
        let citationSql = """
            SELECT id, article_id, passage_id, passage_fingerprint,
                   quote, source_title, source_name, source_url, published_at
            FROM event_overview_citations
            WHERE overview_id = ?;
            """
        var citationStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, citationSql, -1, &citationStmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetch citations statement"])
        }
        defer { sqlite3_finalize(citationStmt) }

        sqlite3_bind_text(citationStmt, 1, id, -1, Self.sqliteTransient)
        var citations: [OverviewCitation] = []
        while sqlite3_step(citationStmt) == SQLITE_ROW {
            let citID = Self.citationID(
                fromRowID: String(cString: sqlite3_column_text(citationStmt, 0)), overviewID: id)
            let articleID = String(cString: sqlite3_column_text(citationStmt, 1))
            let passageID = String(cString: sqlite3_column_text(citationStmt, 2))
            let passageFingerprint = String(cString: sqlite3_column_text(citationStmt, 3))
            let quote = String(cString: sqlite3_column_text(citationStmt, 4))
            let sourceTitle = sqlite3_column_text(citationStmt, 5).map { String(cString: $0) }
            let sourceName = sqlite3_column_text(citationStmt, 6).map { String(cString: $0) }
            let sourceURL = sqlite3_column_text(citationStmt, 7).map { String(cString: $0) }
            var publishedAt: Date?
            if sqlite3_column_type(citationStmt, 8) != SQLITE_NULL {
                publishedAt = Date(timeIntervalSince1970: sqlite3_column_double(citationStmt, 8))
            }
            citations.append(
                OverviewCitation(
                    id: citID,
                    articleID: articleID,
                    passageID: passageID,
                    passageFingerprint: passageFingerprint,
                    quote: quote,
                    source: OverviewSourceMetadata(
                        title: sourceTitle,
                        name: sourceName,
                        url: sourceURL,
                        publishedAt: publishedAt
                    )
                ))
        }

        return EventOverviewDocument(
            id: id,
            eventID: fetchedEventID,
            version: OverviewVersionContext(
                membershipVersion: membershipVersion,
                inputTextHash: inputTextHash,
                schemaVersion: schemaVersion,
                analysisVersion: analysisVersion
            ),
            content: OverviewContent(
                title: title,
                summary: summary,
                facts: facts,
                citations: citations,
                leadImage: leadImage,
                evidenceSections: evidenceSections
            ),
            provenance: OverviewProvenance(
                memberArticleIDs: memberArticleIDs,
                kind: kind,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )
    }

    static func citationRowID(overviewID: String, citationID: String) -> String {
        overviewID + "|" + citationID
    }

    /// Rows stored before overview-scoped keys carry the bare citation ID and are read unchanged.
    static func citationID(fromRowID rowID: String, overviewID: String) -> String {
        let prefix = overviewID + "|"
        return rowID.hasPrefix(prefix) ? String(rowID.dropFirst(prefix.count)) : rowID
    }

    /// Resolves the event overview associated with a given article ID (via event membership or citations).
    func fetchEventOverview(forArticleID articleID: String) throws -> EventOverviewDocument? {
        if let eventID = try eventID(forArticle: articleID),
            let overview = try fetchEventOverview(eventID: eventID)
        {
            return overview
        }

        // Fallback: check overview citations for direct article attribution
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        let sql = """
            SELECT o.event_id FROM event_overview_citations c
            JOIN event_overviews o ON o.id = c.overview_id
            WHERE c.article_id = ? LIMIT 1;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, articleID, -1, Self.sqliteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW, let eventIDText = sqlite3_column_text(stmt, 0) {
            let eventID = String(cString: eventIDText)
            return try fetchEventOverview(eventID: eventID)
        }
        return nil
    }

    @discardableResult
    func deleteEventOverview(eventID: String) throws -> Bool {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

        var stmt: OpaquePointer?
        let sql = "DELETE FROM event_overviews WHERE event_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare delete event overview statement"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, eventID, -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to delete event overview: \(errMsg)"])
        }
        let changes = sqlite3_changes(db)
        try commitTransaction()
        return changes > 0
    }

    func clearEventOverviews() throws {
        guard db != nil else { return }
        try executeSimple("DELETE FROM event_overviews;")
        logger.info("Cleared all event overviews and citations.")
    }

    // MARK: - Events

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

    /// The events currently holding the given stored article IDs; articles outside any event are absent.
    func eventIDs(forArticles articleIDs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            for row in try eventRows(
                "SELECT article_id, event_id FROM event_members WHERE article_id IN (\(placeholders));",
                slice.map { .text($0) })
            {
                if let article = row[0], let event = row[1] { result[article] = event }
            }
        }
        return result
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

    private func requireEvent(_ id: String) throws -> StoryEvent {
        guard let event = try fetchEvent(id: id) else { throw Self.eventError("Unknown event") }
        return event
    }

    private func liveEvent(_ id: String) throws -> (id: String, version: Int) {
        guard let live = try resolvedEventID(id),
            let version = try eventRows("SELECT membership_version FROM events WHERE id = ?;", [.text(live)]).first?[0]
                .flatMap({ Int($0) })
        else {
            throw Self.eventError("Unknown event")
        }
        return (live, version)
    }

    private func insertEvent(members: [String], at now: Double) throws -> String {
        guard !members.isEmpty else { throw Self.eventError("An event needs at least one article") }
        let id = UUID().uuidString
        try eventRows(
            "INSERT INTO events(id, membership_version, created_at, updated_at) VALUES (?, 1, ?, ?);",
            [.text(id), .real(now), .real(now)])
        _ = try assignMembers(members, to: id, joinedVersion: 1, at: now)
        return id
    }

    /// Membership references the surviving stored document, never an alias or a reconciled copy.
    private func memberArticleID(_ id: String) throws -> String? {
        var resolved = try resolvedArticleID(id)
        if let survivor = try eventRows(
            "SELECT survivor_id FROM article_reconciliations WHERE duplicate_id = ?;", [.text(resolved)]
        ).first?[0] {
            resolved = survivor
        }
        return try eventRows("SELECT 1 FROM articles WHERE id = ?;", [.text(resolved)]).isEmpty ? nil : resolved
    }

    private func resolvedMembers(_ articleIDs: [String]) throws -> [String] {
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
    private func assignMembers(_ members: [String], to eventID: String, joinedVersion: Int, at now: Double) throws
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

    private func bumpMembershipVersion(_ eventID: String, at now: Double) throws {
        try eventRows(
            "UPDATE events SET membership_version = membership_version + 1, updated_at = ? WHERE id = ?;",
            [.real(now), .text(eventID)])
    }

    /// Event-matching candidates: FTS hits within `window` of `date`, best ranked first and capped at
    /// `limit`. Hidden reconciled copies, `articleID` itself and members of events unchanged since
    /// `activeSince` are excluded, so closed events never grow.
    func eventCandidateRows(
        matching query: String, around date: Date, window: TimeInterval,
        activeSince: Date, excluding articleID: String, limit: Int
    ) throws -> [(id: String, title: String, description: String, eventID: String?)] {
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
        let center = date.timeIntervalSince1970
        return try eventRows(
            sql,
            [
                .text(query), .text(articleID), .real(center - window), .real(center + window),
                .real(activeSince.timeIntervalSince1970), .integer(limit),
            ]
        ).compactMap { row in
            guard let id = row[0], let title = row[1] else { return nil }
            return (id: id, title: title, description: row[2] ?? "", eventID: row[3])
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

    // MARK: - Event Matching

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
    func eventMatchMembers(eventID: String) throws -> (id: String, version: Int, members: [EventMatchRow])? {
        guard let live = try? liveEvent(eventID) else { return nil }
        let members = try eventMatchRows("\(Self.eventMatchColumns) WHERE m.event_id = ?;", [.text(live.id)])
        return (live.id, live.version, members)
    }

    /// Every live event updated since `activeSince`, with its members, for merging fragments of one story.
    func activeEventMembers(since activeSince: Date) throws -> [(id: String, version: Int, members: [EventMatchRow])] {
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
            return (id, row[1].flatMap { Int($0) } ?? 1, members.sorted { $0.id < $1.id })
        }
    }

    /// Apply a matcher upgrade only to the exact active membership/text snapshot that was assessed.
    /// The first group retains the event ID; all moves, invalidation and processed markers commit together.
    func repartitionEvent(
        _ eventID: String, expectedVersion: Int, expectedMembers: [EventMatchRow], groups: [[String]],
        matcherVersion: Int, activeSince: Date, at now: Date
    ) throws -> Set<String>? {
        try inEventTransaction {
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

    // MARK: - Event Reading State

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
        var summaries: [EventFeedSummary] = []
        for start in stride(from: 0, to: eventIDs.count, by: 400) {
            let slice = Array(eventIDs[start..<min(start + 400, eventIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
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
                """, slice.map { .text($0) })
            var current: (id: String, version: Int, seen: Int?, members: [EventFeedMember])?
            for row in rows {
                guard let eventID = row[0], let articleID = row[3] else { continue }
                if current?.id != eventID {
                    if let current {
                        summaries.append(
                            EventFeedSummary(
                                eventID: current.id, membershipVersion: current.version, seenVersion: current.seen,
                                members: current.members))
                    }
                    current = (eventID, row[1].flatMap { Int($0) } ?? 1, row[2].flatMap { Int($0) }, [])
                }
                current?.members.append(
                    EventFeedMember(
                        articleID: articleID, source: FeedCatalog.publisher(forLink: row[10] ?? "") ?? row[4] ?? "",
                        title: row[5] ?? "",
                        date: Date(timeIntervalSince1970: row[6].flatMap { Double($0) } ?? 0),
                        joinedVersion: row[7].flatMap { Int($0) } ?? 1,
                        isRead: row[8] == "1", isSaved: row[9] == "1"))
            }
            if let current {
                summaries.append(
                    EventFeedSummary(
                        eventID: current.id, membershipVersion: current.version, seenVersion: current.seen,
                        members: current.members))
            }
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

    // MARK: - Article Features and Pair Decisions (#522)

    /// Stored matcher signals of the given version, decoded; articles without a current record are absent.
    func fetchArticleFeatures(articleIDs: [String], version: Int) throws -> [String: EventFeatures] {
        var result: [String: EventFeatures] = [:]
        let decoder = JSONDecoder()
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            try Task.checkCancellation()
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try eventRows(
                "SELECT article_id, features FROM article_features WHERE version = ? AND article_id IN (\(placeholders))",
                [.integer(version)] + slice.map { .text($0) })
            for row in rows {
                guard let id = row[0], let json = row[1],
                    let features = try? decoder.decode(EventFeatures.self, from: Data(json.utf8))
                else { continue }
                result[id] = features
            }
        }
        return result
    }

    /// Stores matcher signals as JSON in one transaction; a deleted article has nothing to store.
    func upsertArticleFeatures(_ features: [String: EventFeatures], version: Int, at date: Date = Date()) throws {
        guard !features.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try inEventTransaction { () throws -> Void in
            for (articleID, value) in features {
                guard let json = String(bytes: try encoder.encode(value), encoding: .utf8) else { continue }
                try eventRows(
                    """
                    INSERT INTO article_features(article_id, version, features, computed_at)
                    SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM articles WHERE id = ?)
                    ON CONFLICT(article_id) DO UPDATE SET version = excluded.version, features = excluded.features,
                        computed_at = excluded.computed_at;
                    """,
                    [
                        .text(articleID), .integer(version), .text(json), .real(date.timeIntervalSince1970),
                        .text(articleID),
                    ])
            }
        }
    }

    /// Stores a clustering pass's signals, vectors and pair decisions and drops the rows of pairs that no longer
    /// qualify, in one actor turn. `readTexts` holds each article's title and description as the pass read them;
    /// values of an article that is gone or reads differently now are skipped: the rematch trigger dropped what was
    /// stored for the old text, and the next pass computes the new one (#522).
    func storeClusteringPass(
        features: [String: EventFeatures], embeddings: [String: [Float]], decisions: [PairDecision],
        cleared: [(String, String)], readTexts: [String: String], featureVersion: Int, embeddingVersion: Int,
        matcherVersion: Int, at date: Date = Date()
    ) throws {
        var current: [String: String] = [:]
        let ids = Array(readTexts.keys)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = ids[start..<min(start + 500, ids.count)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            for row in try eventRows(
                "SELECT id, title, coalesce(description, '') FROM articles WHERE id IN (\(marks));",
                chunk.map { .text($0) })
            {
                if let id = row[0] { current[id] = (row[1] ?? "") + "\n" + (row[2] ?? "") }
            }
        }
        let changed = Set(readTexts.filter { current[$0.key] != $0.value }.keys)
        try upsertArticleFeatures(features.filter { !changed.contains($0.key) }, version: featureVersion, at: date)
        try upsertArticleEmbeddings(embeddings.filter { !changed.contains($0.key) }, modelVersion: embeddingVersion)
        try upsertPairDecisions(
            decisions.filter { !changed.contains($0.articleID) && !changed.contains($0.otherArticleID) },
            matcherVersion: matcherVersion, at: date)
        guard !cleared.isEmpty else { return }
        try inEventTransaction { () throws -> Void in
            for (low, high) in cleared {
                try eventRows(
                    "DELETE FROM pair_assessments WHERE article_id = ? AND other_article_id = ?;",
                    [.text(low), .text(high)])
            }
        }
    }

    /// A clusterer decision about one pair, keyed low ID first.
    struct PairDecision: Hashable, Sendable {
        let articleID: String
        let otherArticleID: String
        /// "match", "related-act" or "borderline".
        let decision: String
        let reason: String
        let score: Double
    }

    func upsertPairDecisions(_ decisions: [PairDecision], matcherVersion: Int, at date: Date = Date()) throws {
        guard !decisions.isEmpty else { return }
        try inEventTransaction { () throws -> Void in
            for pair in decisions where pair.articleID < pair.otherArticleID {
                try eventRows(
                    """
                    INSERT INTO pair_assessments(article_id, other_article_id, matcher_version, decision, reason, score,
                        assessed_at)
                    SELECT ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM articles WHERE id = ?)
                        AND EXISTS (SELECT 1 FROM articles WHERE id = ?)
                    ON CONFLICT(article_id, other_article_id) DO UPDATE SET matcher_version = excluded.matcher_version,
                        decision = excluded.decision, reason = excluded.reason, score = excluded.score,
                        assessed_at = excluded.assessed_at;
                    """,
                    [
                        .text(pair.articleID), .text(pair.otherArticleID), .integer(matcherVersion),
                        .text(pair.decision), .text(pair.reason), .real(pair.score), .real(date.timeIntervalSince1970),
                        .text(pair.articleID), .text(pair.otherArticleID),
                    ])
            }
        }
    }

    /// Live events whose members the matcher judged a different act of the same story as this event's members
    /// (decision "related-act"), each by its earliest member, newest event first.
    func relatedActEvents(eventID: String, limit: Int = EventStoryRelation.linkLimit) throws -> [RelatedStoryEvent] {
        guard let live = try resolvedEventID(eventID) else { return [] }
        let rows = try eventRows(
            """
            SELECT other.event_id, a.id, a.title, a.published_at
            FROM event_members m
            JOIN pair_assessments p
                ON (p.article_id = m.article_id OR p.other_article_id = m.article_id) AND p.decision = 'related-act'
            JOIN event_members other
                ON other.article_id = CASE WHEN p.article_id = m.article_id THEN p.other_article_id ELSE p.article_id END
            JOIN events e ON e.id = other.event_id AND e.merged_into IS NULL
            JOIN articles a ON a.id = other.article_id
            WHERE m.event_id = ? AND other.event_id != ? AND \(Self.visibleArticle)
            ORDER BY a.published_at, a.id;
            """, [.text(live), .text(live)])
        var earliest: [String: RelatedStoryEvent] = [:]
        for row in rows {
            guard let id = row[0], earliest[id] == nil, let articleID = row[1], let title = row[2],
                let published = row[3].flatMap({ Double($0) })
            else { continue }
            earliest[id] = RelatedStoryEvent(
                eventID: id, articleID: articleID, title: title,
                firstPublishedAt: Date(timeIntervalSince1970: published))
        }
        return Array(
            earliest.values.sorted {
                $0.firstPublishedAt == $1.firstPublishedAt
                    ? $0.eventID < $1.eventID : $0.firstPublishedAt > $1.firstPublishedAt
            }.prefix(limit))
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
