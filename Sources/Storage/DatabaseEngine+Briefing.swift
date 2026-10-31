// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import SQLite3

/// One event of a saved Briefing edition, as "Since your last briefing" compares it.
struct BriefingEditionSnapshotRow: Equatable, Sendable {
    let eventID: String
    let membershipVersion: Int
    let publisherCount: Int
    /// `TensionEscalation` raw value when a cited passage supports it, else nil.
    let escalation: String?
}

/// Briefing storage: edition snapshots and the sitrep cache (#849).
extension DatabaseEngine {
    /// The stamp of a sitrep line's inputs: the event, its overview version and the highlights the line restates.
    static func briefingSitrepInputHash(eventID: String, overview: EventOverviewDocument) -> String {
        let facts = overview.facts.prefix(BriefingSitrepComposer.factLimit).map(\.text)
        return ArticleIdentity.sha256Hex(
            ([eventID, String(overview.membershipVersion)] + facts).joined(separator: "\n"))
    }

    func fetchBriefingSitrep(eventID: String) throws -> (inputHash: String, text: String, isGenerated: Bool)? {
        guard
            let row = try eventRows(
                "SELECT input_hash, text, is_generated FROM briefing_sitrep WHERE event_id = ?;", [.text(eventID)]
            ).first, let hash = row[0], let text = row[1]
        else { return nil }
        return (hash, text, row[2] == "1")
    }

    /// Saves a sitrep line only while its inputs are current: inside the transaction the stamp is recomputed from the
    /// stored overview, and a line made from older inputs is refused (#844).
    @discardableResult
    func saveBriefingSitrep(eventID: String, inputHash: String, text: String, isGenerated: Bool) throws -> Bool {
        try inEventTransaction {
            guard let overview = try fetchEventOverview(eventID: eventID),
                Self.briefingSitrepInputHash(eventID: eventID, overview: overview) == inputHash
            else { return false }
            try eventRows(
                """
                INSERT OR REPLACE INTO briefing_sitrep (event_id, input_hash, text, is_generated, created_at)
                VALUES (?, ?, ?, ?, ?);
                """,
                [
                    .text(eventID), .text(inputHash), .text(text), .integer(isGenerated ? 1 : 0),
                    .real(Date().timeIntervalSince1970),
                ])
            return true
        }
    }

    /// The newest edition saved before `date`, with its events.
    func latestBriefingSnapshot(before date: Date) throws -> (startedAt: Date, rows: [BriefingEditionSnapshotRow])? {
        guard
            let started = try eventRows(
                "SELECT MAX(edition_started_at) FROM briefing_edition_snapshots WHERE edition_started_at < ?;",
                [.real(date.timeIntervalSince1970)]
            ).first?[0].flatMap(Double.init)
        else { return nil }
        let rows = try eventRows(
            """
            SELECT event_id, membership_version, publisher_count, escalation FROM briefing_edition_snapshots
            WHERE edition_started_at = ?;
            """, [.real(started)]
        ).compactMap { row -> BriefingEditionSnapshotRow? in
            guard let id = row[0] else { return nil }
            return BriefingEditionSnapshotRow(
                eventID: id, membershipVersion: row[1].flatMap { Int($0) } ?? 0,
                publisherCount: row[2].flatMap { Int($0) } ?? 0, escalation: row[3])
        }
        return (Date(timeIntervalSince1970: started), rows)
    }

    /// Writes the edition's events; saving the same edition again replaces its rows.
    func saveBriefingSnapshot(startedAt: Date, rows: [BriefingEditionSnapshotRow]) throws {
        try inEventTransaction {
            let started = EventValue.real(startedAt.timeIntervalSince1970)
            try eventRows("DELETE FROM briefing_edition_snapshots WHERE edition_started_at = ?;", [started])
            for row in rows {
                try eventRows(
                    """
                    INSERT OR REPLACE INTO briefing_edition_snapshots
                        (edition_started_at, event_id, membership_version, publisher_count, escalation)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    [
                        started, .text(row.eventID), .integer(row.membershipVersion), .integer(row.publisherCount),
                        row.escalation.map { .text($0) } ?? .null,
                    ])
            }
        }
    }
}
