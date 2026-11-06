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

/// Opt-in coverage and replay over an exported library copy. The report holds aggregates only, never article text.
enum EditorialWireIdentityEvaluation {
    struct Row: Decodable {
        let articleID: String
        let eventID: String?
        let publisher: String
        let title: String
        let description: String
        let content: String?
        let publishedAt: Double
        let fetchedAt: Double
        let canonicalURL: String
        var author: String?
        var article: WireIdentityArticle {
            WireIdentityArticle(
                articleID: articleID, publisher: publisher, title: title, description: description, content: content,
                publishedAt: Date(timeIntervalSince1970: publishedAt),
                fetchedAt: Date(timeIntervalSince1970: fetchedAt),
                author: author)
        }
    }
    struct Input: Decodable {
        let basis: String
        let articles: [Row]
    }

    /// The values the synthetic sweep selected (docs/audits/2026-11-06-editorial-momentum.md), not shipping defaults.
    static let configuration = MomentumConfiguration(
        bucketSeconds: 300, shortHalfLife: 1_800, longHalfLife: 10_800, signalHalfLife: 1_800, volumeWindow: 3_600,
        minimumIndependentReports: 3, minimumOriginPublishers: 2)

    /// Identities over `rows`: event members together, an article outside any event alone.
    static func coverage(_ rows: [Row], textContainment: Double = 0.8) -> [String: Any] {
        let events = Dictionary(grouping: rows) { $0.eventID ?? "single:\($0.articleID)" }
        var byBasis = Dictionary(uniqueKeysWithValues: WireIdentity.Basis.allCases.map { ($0.rawValue, 0) })
        var knownWire = 0
        var knownOrigin = 0
        var rowsInGroups = 0
        var groups = 0
        var crossOutletGroups = 0
        var eventsWithCollapse = 0
        var unknownByPublisher: [String: Int] = [:]
        var unknownWithAuthor = 0
        for members in events.values {
            let publishers = Dictionary(uniqueKeysWithValues: members.map { ($0.articleID, $0.publisher) })
            let authored = Set(members.filter { $0.author != nil }.map(\.articleID))
            let identities = EditorialWireIdentity.identities(
                event: members.map(\.article), textContainment: textContainment)
            for identity in identities {
                byBasis[identity.basis.rawValue, default: 0] += 1
                if identity.wireGroupID != nil { knownWire += 1 }
                if identity.originPublisherID != nil { knownOrigin += 1 }
                if identity.wireGroupID == nil {
                    unknownByPublisher[publishers[identity.articleID] ?? "", default: 0] += 1
                    if authored.contains(identity.articleID) { unknownWithAuthor += 1 }
                }
            }
            let collapsed = Dictionary(
                grouping: identities.filter { $0.wireGroupID != nil }, by: { $0.wireGroupID ?? "" }
            )
            .values.filter { $0.count > 1 }
            groups += collapsed.count
            rowsInGroups += collapsed.reduce(0) { $0 + $1.count }
            let crossing = collapsed.filter { Set($0.map { publishers[$0.articleID] ?? "" }).count > 1 }.count
            crossOutletGroups += crossing
            if crossing > 0 { eventsWithCollapse += 1 }
        }
        return [
            "articles": rows.count, "events": events.count, "by_basis": byBasis,
            "known_wire_group": knownWire, "known_wire_group_share": share(knownWire, rows.count),
            "known_origin": knownOrigin, "known_origin_share": share(knownOrigin, rows.count),
            "rows_in_multi_row_groups": rowsInGroups, "multi_row_groups": groups,
            "groups_crossing_outlets": crossOutletGroups, "events_with_cross_outlet_group": eventsWithCollapse,
            "unknown_by_publisher": unknownByPublisher, "unknown_rows_with_a_non_agency_author": unknownWithAuthor,
            "rows_with_author": rows.filter { $0.author != nil }.count,
        ]
    }

    /// Replays every event; `adjust` can restate a row's report to show what a policy the mapping refuses would change.
    static func replays(
        _ rows: [Row], adjust: (Row, MomentumReport) -> MomentumReport = { $1 }
    ) throws -> [String: Any] {
        let events = Dictionary(grouping: rows.filter { $0.eventID != nil }, by: { $0.eventID ?? "" })
        var raw = 0
        var outsideWindow = 0
        var unknown = 0
        var independent = 0
        var reachingFloor = 0
        var accelerating = 0
        var multiReport = 0
        for (eventID, members) in events {
            let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.articleID, $0) })
            let reports = EditorialWireIdentity.momentumReports(eventID: eventID, members: members.map(\.article))
                .map { report in byID[report.articleID].map { adjust($0, report) } ?? report }
            guard let through = members.map({ Date(timeIntervalSince1970: $0.fetchedAt) }).max() else { continue }
            let summary = try EditorialMomentum.replay(
                reports: reports, eventID: eventID, windowStart: through.addingTimeInterval(-172_800), through: through,
                configuration: configuration)
            raw += summary.rawRowsInWindow
            outsideWindow += reports.count - summary.rawRowsInWindow
            unknown += summary.unknownMetadataRows
            independent += summary.independentReportsInWindow
            if summary.independentReportsInWindow >= 2 { multiReport += 1 }
            if summary.points.contains(where: {
                $0.independentCount >= configuration.minimumIndependentReports
                    && $0.originCount >= configuration.minimumOriginPublishers
            }) {
                reachingFloor += 1
            }
            if summary.points.contains(where: { $0.state == .accelerating }) { accelerating += 1 }
        }
        return [
            "events": events.count, "raw_rows_in_window": raw, "rows_outside_window": outsideWindow,
            "unknown_metadata_rows": unknown, "unknown_share": share(unknown, raw),
            "independent_reports": independent, "events_with_two_or_more_reports": multiReport,
            "events_reaching_volume_and_origin_floor": reachingFloor, "events_accelerating": accelerating,
        ]
    }

    private static func assumed(_ report: MomentumReport) -> MomentumReport {
        let wire = report.wireGroupID ?? "report:\(report.articleID)"
        return MomentumReport(
            articleID: report.articleID, eventID: report.eventID, wireGroupID: wire,
            localPublisherID: report.localPublisherID,
            originPublisherID: report.originPublisherID
                ?? (report.wireGroupID == nil ? "publisher:\(report.localPublisherID)" : "unattributed:\(wire)"),
            publishedAt: report.publishedAt, fetchedAt: report.fetchedAt)
    }

    private static func share(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) / Double(whole) }

    /// Every feed in a fetched snapshot through the production parser: authors by stored link, and fill rates.
    static func feedSnapshot(
        directory: URL
    ) throws -> (authors: [String: String], namedPublishers: Set<String>, report: [String: Any]) {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" }.sorted { $0.path < $1.path }
        var authors: [String: String] = [:]
        var byPublisher: [String: [Int]] = [:]
        var unreadable = 0
        for file in files {
            let items = FeedXMLParser(data: try Data(contentsOf: file)).parse()
            if items.isEmpty { unreadable += 1 }
            for item in items {
                var counts = byPublisher[item.publisherName, default: [0, 0, 0, 0]]
                counts[0] += 1
                if let author = item.author {
                    authors[item.normalizedLink] = author
                    counts[1] += 1
                    if !EditorialWireIdentity.bylineAgencies(author).isEmpty { counts[2] += 1 }
                    if namedPerson(author, publisher: item.publisherName) { counts[3] += 1 }
                }
                byPublisher[item.publisherName] = counts
            }
        }
        let total = byPublisher.values.reduce(into: [0, 0, 0, 0]) { sum, counts in
            for index in sum.indices { sum[index] += counts[index] }
        }
        let namedPublishers = byPublisher.filter { Double($0.value[3]) >= namedPublisherShare * Double($0.value[0]) }
        return (
            authors, Set(namedPublishers.keys),
            [
                "feeds": files.count, "feeds_without_items": unreadable, "items": total[0],
                "items_with_author": total[1], "items_with_agency_author": total[2],
                "items_with_named_person": total[3], "publishers_mostly_named": namedPublishers.keys.sorted(),
                "by_publisher_items_authored_agency_named": byPublisher,
            ]
        )
    }

    /// Opens a copy with the production engine and compares what must survive, then the copy it keeps to roll back to.
    static func migrationReview(copy: String) async throws -> [String: Any] {
        func counts(_ path: String) -> [String: Int] {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_close(handle) }
            let queries = [
                "version": "PRAGMA user_version", "articles": "SELECT count(*) FROM articles",
                "read": "SELECT count(*) FROM article_state WHERE is_read = 1",
                "saved": "SELECT count(*) FROM article_state WHERE is_saved = 1",
                "event_members": "SELECT count(*) FROM event_members",
                "searchable": "SELECT count(*) FROM articles_fts",
                "feeds": "SELECT count(*) FROM feeds",
            ]
            return queries.compactMapValues { sql in
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                    sqlite3_step(statement) == SQLITE_ROW
                else { return nil }
                return Int(sqlite3_column_int(statement, 0))
            }
        }
        let before = counts(copy)
        let engine = DatabaseEngine(path: copy)
        try await engine.open()
        let readOnly = await engine.isReadOnly
        await engine.close()
        let folder = URL(fileURLWithPath: copy).deletingLastPathComponent()
        let rollback = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains("-before-v") && $0.pathExtension == "sqlite3" }
        return [
            "before": before, "after": counts(copy), "opened_read_only": readOnly,
            "rollback_copy": rollback.map { counts($0.path) } ?? [:],
        ]
    }

    /// A publisher counts as naming its reporters in the steady-state estimate when this share of its feed items does.
    static let namedPublisherShare = 0.8
    private static let deskWords: Set<String> = [
        "agencies", "agency", "desk", "editorial", "editors", "news", "newsroom", "press", "redaction", "rédaction",
        "report", "reports", "staff", "team", "wires",
    ]

    /// Whether a feed author reads as a person rather than a desk, the outlet or an agency: at least two words starting
    /// with a capital, no digit, no desk word, not the publisher's name. For the estimate only; the mapping never reads it.
    /// ponytail: a word filter, so an odd desk label passes; replace it if this policy ever ships.
    static func namedPerson(_ author: String, publisher: String) -> Bool {
        var name = author
        if name.contains("@") {
            // RSS "address (Name)": a bare address names nobody.
            guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return false }
            name = String(name[name.index(after: open)...].dropLast())
        }
        if name.hasPrefix("By ") { name = String(name.dropFirst(3)) }
        let words = name.split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard words.count >= 2, words[0].first?.isUppercase == true, !name.contains(where: \.isNumber),
            deskWords.isDisjoint(with: words.map { $0.lowercased() }),
            EditorialWireIdentity.bylineAgencies(name).isEmpty
        else { return false }
        return !name.lowercased().contains(publisher.lowercased())
    }

    /// Coverage if a row with a named author counted as its publisher's own report, and how often such rows are in fact
    /// copies: a named row in a group crossing outlets disproves the assumption for that row.
    static func namedCoverage(_ rows: [Row], isNamed: (Row) -> Bool) -> [String: Any] {
        var named = 0
        var known = 0
        var namedInCopies = 0
        var gained = 0
        var gainedByBasis: [String: Int] = [:]
        var gainedByPublisher: [String: Int] = [:]
        for members in Dictionary(grouping: rows, by: { $0.eventID ?? "single:\($0.articleID)" }).values {
            let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.articleID, $0) })
            let identities = EditorialWireIdentity.identities(event: members.map(\.article))
            var outlets: [String: Set<String>] = [:]
            for identity in identities {
                guard let wire = identity.wireGroupID, let row = byID[identity.articleID] else { continue }
                outlets[wire, default: []].insert(row.publisher)
            }
            for identity in identities {
                guard let row = byID[identity.articleID] else { continue }
                if identity.wireGroupID != nil { known += 1 }
                guard isNamed(row) else { continue }
                named += 1
                if let wire = identity.wireGroupID {
                    if outlets[wire, default: []].count > 1 { namedInCopies += 1 }
                } else {
                    gained += 1
                    gainedByBasis[identity.basis.rawValue, default: 0] += 1
                    gainedByPublisher[row.publisher, default: 0] += 1
                }
            }
        }
        return [
            "articles": rows.count, "rows_named": named, "named_rows_in_copies_across_outlets": namedInCopies,
            "unknown_rows_gaining_identity": gained, "gained_by_basis": gainedByBasis,
            "gained_by_publisher": gainedByPublisher, "known_wire_group_share_before": share(known, rows.count),
            "known_wire_group_share_after": share(known + gained, rows.count),
        ]
    }

    /// One named-author scenario: coverage over both scopes and the replay, with named unknown rows as own reports.
    static func namedEstimate(_ rows: [Row], since: Double, isNamed: (Row) -> Bool) throws -> [String: Any] {
        let members = rows.filter { $0.eventID != nil }
        return [
            "recent_72h": namedCoverage(rows.filter { min($0.publishedAt, $0.fetchedAt) >= since }, isNamed: isNamed),
            "event_members": namedCoverage(members, isNamed: isNamed),
            "replay": try replays(members) { row, report in
                report.wireGroupID == nil && isNamed(row) ? assumed(report) : report
            },
        ]
    }

    /// The same measures with today's feed authors laid over the rows those feeds still serve, and the named-author
    /// estimates: rows that have an author now, and a steady state where publishers that mostly name people always did.
    static func measured(
        _ rows: [Row], authors: [String: String], namedPublishers: Set<String>, since: Double
    ) throws -> [String: Any] {
        let authored = rows.map { row -> Row in
            var row = row
            row.author = row.author ?? authors[row.canonicalURL]
            return row
        }
        let members = authored.filter { $0.eventID != nil }
        return [
            "library": coverage(authored), "event_members": coverage(members),
            "recent_72h": coverage(authored.filter { min($0.publishedAt, $0.fetchedAt) >= since }),
            "replay": try replays(members),
            "named_author_rows_with_author_now": try namedEstimate(authored, since: since) {
                $0.author.map { [publisher = $0.publisher] in namedPerson($0, publisher: publisher) } ?? false
            },
            "named_author_steady_state": try namedEstimate(authored, since: since) { row in
                row.author.map { namedPerson($0, publisher: row.publisher) } ?? namedPublishers.contains(row.publisher)
            },
        ]
    }

    static func run(input: URL, output: URL) async throws {
        let fixture = try JSONDecoder().decode(Input.self, from: Data(contentsOf: input))
        guard fixture.basis == "copied_library", let latest = fixture.articles.map(\.fetchedAt).max() else {
            throw CocoaError(.coderInvalidValue)
        }
        let recent = fixture.articles.filter { min($0.publishedAt, $0.fetchedAt) >= latest - 259_200 }
        let members = fixture.articles.filter { $0.eventID != nil }
        let environment = ProcessInfo.processInfo.environment
        var report: [String: Any] = [
            "schema_version": 2, "basis": fixture.basis, "latest_fetch_epoch": latest,
            "library": coverage(fixture.articles), "recent_72h": coverage(recent), "event_members": coverage(members),
            "event_members_textContainment_0_4": coverage(members, textContainment: 0.4),
            "momentum_configuration": EditorialMomentumEvaluation.fields(configuration),
            "replay": try replays(members),
            "replay_if_unknown_counted_as_own": try replays(members) { _, report in assumed(report) },
            "members_stamped_after_storage_clamped": members.filter { $0.publishedAt > $0.fetchedAt }.count,
            "members_undated_left_out": members.filter {
                Date(timeIntervalSince1970: $0.publishedAt) == DateParser.unknownDate
            }.count,
            "limitations": [
                "No labels: no accuracy claim, and acceleration counts are not validated bursts.",
                "Thresholds were read off this same library copy; there is no holdout.",
            ],
        ]
        if let copy = environment["NEWS_WIRE_IDENTITY_MIGRATE"] {
            report["migration"] = try await migrationReview(copy: copy)
        }
        if let feeds = environment["NEWS_WIRE_IDENTITY_FEEDS"] {
            let snapshot = try feedSnapshot(directory: URL(fileURLWithPath: feeds))
            report["feed_snapshot"] = snapshot.report
            report["with_feed_authors"] = try measured(
                fixture.articles, authors: snapshot.authors, namedPublishers: snapshot.namedPublishers,
                since: latest - 259_200)
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Wire identity evaluation wrote \(output.path)")
    }
}
