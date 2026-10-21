import Foundation
import SQLite3
import os

/// Stored overview facts with optional evidence sections; legacy rows hold a bare facts array.
private struct OverviewFactsEnvelope: Codable {
    let facts: [OverviewFact]
    let evidenceSections: OverviewEvidenceSections?
}

// Event overviews and their citations.
extension DatabaseEngine {
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
        let db = try openDatabase()
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

        if let expectedArticleInputs {
            for (id, hash) in expectedArticleInputs {
                guard try fetchArticles(limit: 1, id: id).first?.publisherInputHash == hash else { return false }
            }
        }
        guard try removeSupersededOverview(for: overview, in: db) else { return false }
        try insertOverviewRow(overview, in: db)
        try insertOverviewCitations(overview, in: db)
        try commitTransaction()
        return true
    }

    /// Deletes the stored overview this one replaces. Returns false when a newer membership version is stored:
    /// an older result never overwrites it.
    private func removeSupersededOverview(for overview: EventOverviewDocument, in db: OpaquePointer) throws -> Bool {
        let checkStmt = try prepare(
            "SELECT id, membership_version FROM event_overviews WHERE event_id = ?;", in: db,
            failure: "Failed to prepare check statement for event overview")
        defer { sqlite3_finalize(checkStmt) }
        sqlite3_bind_text(checkStmt, 1, overview.eventID, -1, Self.sqliteTransient)
        guard sqlite3_step(checkStmt) == SQLITE_ROW else { return true }
        if Int(sqlite3_column_int(checkStmt, 1)) > overview.membershipVersion { return false }
        guard let idText = sqlite3_column_text(checkStmt, 0) else { return true }

        let delStmt = try prepare(
            "DELETE FROM event_overviews WHERE id = ?;", in: db,
            failure: "Failed to prepare overview deletion: \(String(cString: sqlite3_errmsg(db)))")
        defer { sqlite3_finalize(delStmt) }
        sqlite3_bind_text(delStmt, 1, String(cString: idText), -1, Self.sqliteTransient)
        let stepStatus = sqlite3_step(delStmt)
        guard stepStatus == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(stepStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to delete existing event overview: \(String(cString: sqlite3_errmsg(db)))"
                ])
        }
        return true
    }

    private func insertOverviewRow(_ overview: EventOverviewDocument, in db: OpaquePointer) throws {
        let encoder = JSONEncoder()
        let factsData: Data
        if let evidence = overview.content.evidenceSections, !evidence.isEmpty {
            factsData = try encoder.encode(OverviewFactsEnvelope(facts: overview.facts, evidenceSections: evidence))
        } else {
            factsData = try encoder.encode(overview.facts)
        }
        let leadImageJSON = try overview.leadImage.map { Self.utf8(try encoder.encode($0)) }

        let overviewStmt = try prepare(
            """
            INSERT INTO event_overviews (
                id, event_id, membership_version, input_text_hash,
                schema_version, analysis_version, title, summary,
                facts_json, lead_image_json, member_article_ids_json,
                kind, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, in: db, failure: "Failed to prepare insert statement for event overview")
        defer { sqlite3_finalize(overviewStmt) }

        sqlite3_bind_text(overviewStmt, 1, overview.id, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 2, overview.eventID, -1, Self.sqliteTransient)
        sqlite3_bind_int(overviewStmt, 3, Int32(overview.membershipVersion))
        sqlite3_bind_text(overviewStmt, 4, overview.inputTextHash, -1, Self.sqliteTransient)
        sqlite3_bind_int(overviewStmt, 5, Int32(overview.schemaVersion))
        sqlite3_bind_int(overviewStmt, 6, Int32(overview.analysisVersion))
        sqlite3_bind_text(overviewStmt, 7, overview.title, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 8, overview.summary, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 9, Self.utf8(factsData), -1, Self.sqliteTransient)
        Self.bind(leadImageJSON, at: 10, in: overviewStmt)
        sqlite3_bind_text(
            overviewStmt, 11, Self.utf8(try encoder.encode(overview.memberArticleIDs)), -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 12, overview.kind.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_double(overviewStmt, 13, overview.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(overviewStmt, 14, overview.updatedAt.timeIntervalSince1970)

        guard sqlite3_step(overviewStmt) == SQLITE_DONE else {
            throw Self.storageError("Failed to insert event overview: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func insertOverviewCitations(_ overview: EventOverviewDocument, in db: OpaquePointer) throws {
        let citationStmt = try prepare(
            """
            INSERT INTO event_overview_citations (
                id, overview_id, article_id, passage_id, passage_fingerprint,
                quote, source_title, source_name, source_url, published_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, in: db, failure: "Failed to prepare citation statement")
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
            Self.bind(citation.sourceTitle, at: 7, in: citationStmt)
            Self.bind(citation.sourceName, at: 8, in: citationStmt)
            Self.bind(citation.sourceURL, at: 9, in: citationStmt)
            if let publishedAt = citation.publishedAt {
                sqlite3_bind_double(citationStmt, 10, publishedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(citationStmt, 10)
            }
            guard sqlite3_step(citationStmt) == SQLITE_DONE else {
                throw Self.storageError(
                    "Failed to insert event overview citation: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    func fetchEventOverview(eventID: String) throws -> EventOverviewDocument? {
        let db = try openDatabase()
        let overviewStmt = try prepare(
            """
            SELECT id, event_id, membership_version, input_text_hash,
                   schema_version, analysis_version, title, summary,
                   facts_json, lead_image_json, member_article_ids_json,
                   kind, created_at, updated_at
            FROM event_overviews
            WHERE event_id = ?;
            """, in: db, failure: "Failed to prepare fetch overview statement")
        defer { sqlite3_finalize(overviewStmt) }

        sqlite3_bind_text(overviewStmt, 1, eventID, -1, Self.sqliteTransient)
        guard sqlite3_step(overviewStmt) == SQLITE_ROW else { return nil }

        func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(overviewStmt, column)) }
        let id = text(0)
        let decoder = JSONDecoder()
        let content = Self.decodeFacts(text(8))
        let leadImage = sqlite3_column_text(overviewStmt, 9).flatMap {
            try? decoder.decode(OverviewLeadImage.self, from: Data(String(cString: $0).utf8))
        }
        return EventOverviewDocument(
            id: id,
            eventID: text(1),
            version: OverviewVersionContext(
                membershipVersion: Int(sqlite3_column_int(overviewStmt, 2)),
                inputTextHash: text(3),
                schemaVersion: Int(sqlite3_column_int(overviewStmt, 4)),
                analysisVersion: Int(sqlite3_column_int(overviewStmt, 5))
            ),
            content: OverviewContent(
                title: text(6),
                summary: text(7),
                facts: content.facts,
                citations: try fetchOverviewCitations(overviewID: id, in: db),
                leadImage: leadImage,
                evidenceSections: content.evidenceSections
            ),
            provenance: OverviewProvenance(
                memberArticleIDs: (try? decoder.decode([String].self, from: Data(text(10).utf8))) ?? [],
                kind: OverviewKind(rawValue: text(11)) ?? .synthesized,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(overviewStmt, 12)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(overviewStmt, 13))
            )
        )
    }

    /// Facts stored either as an envelope with evidence sections or, in older rows, as a bare array.
    /// Malformed JSON reads as no facts rather than failing the overview.
    static func decodeFacts(_ json: String) -> OverviewFactsContent {
        let decoder = JSONDecoder()
        if json.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard let envelope = try? decoder.decode(OverviewFactsEnvelope.self, from: Data(json.utf8)) else {
                return OverviewFactsContent(facts: [], evidenceSections: nil)
            }
            return OverviewFactsContent(facts: envelope.facts, evidenceSections: envelope.evidenceSections)
        }
        let facts = (try? decoder.decode([OverviewFact].self, from: Data(json.utf8))) ?? []
        return OverviewFactsContent(facts: facts, evidenceSections: nil)
    }

    struct OverviewFactsContent {
        let facts: [OverviewFact]
        let evidenceSections: OverviewEvidenceSections?
    }

    private func fetchOverviewCitations(overviewID id: String, in db: OpaquePointer) throws -> [OverviewCitation] {
        let citationStmt = try prepare(
            """
            SELECT id, article_id, passage_id, passage_fingerprint,
                   quote, source_title, source_name, source_url, published_at
            FROM event_overview_citations
            WHERE overview_id = ?;
            """, in: db, failure: "Failed to prepare fetch citations statement")
        defer { sqlite3_finalize(citationStmt) }

        sqlite3_bind_text(citationStmt, 1, id, -1, Self.sqliteTransient)
        func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(citationStmt, column)) }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_text(citationStmt, column).map { String(cString: $0) }
        }
        var citations: [OverviewCitation] = []
        while sqlite3_step(citationStmt) == SQLITE_ROW {
            let publishedAt =
                sqlite3_column_type(citationStmt, 8) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(citationStmt, 8))
            citations.append(
                OverviewCitation(
                    id: Self.citationID(fromRowID: text(0), overviewID: id),
                    articleID: text(1),
                    passageID: text(2),
                    passageFingerprint: text(3),
                    quote: text(4),
                    source: OverviewSourceMetadata(
                        title: optionalText(5),
                        name: optionalText(6),
                        url: optionalText(7),
                        publishedAt: publishedAt
                    )
                ))
        }
        return citations
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

    // MARK: - Statement helpers

    func openDatabase() throws -> OpaquePointer {
        guard let db = db else { throw Self.storageError("Database not open") }
        return db
    }

    /// A prepared statement the caller finalizes; `failure` names the statement when preparation fails.
    func prepare(_ sql: String, in db: OpaquePointer, failure: @autoclosure () -> String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.storageError(failure())
        }
        return statement
    }

    static func bind(_ text: String?, at index: Int32, in statement: OpaquePointer) {
        if let text {
            sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    /// Text of JSON the encoder produced, which is always UTF-8.
    static func utf8(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }

    static func storageError(_ message: String) -> NSError {
        NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
