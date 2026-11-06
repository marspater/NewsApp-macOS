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
        var article: WireIdentityArticle {
            WireIdentityArticle(
                articleID: articleID, publisher: publisher, title: title, description: description, content: content,
                publishedAt: Date(timeIntervalSince1970: publishedAt), fetchedAt: Date(timeIntervalSince1970: fetchedAt)
            )
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
        for members in events.values {
            let publishers = Dictionary(uniqueKeysWithValues: members.map { ($0.articleID, $0.publisher) })
            let identities = EditorialWireIdentity.identities(
                event: members.map(\.article), textContainment: textContainment)
            for identity in identities {
                byBasis[identity.basis.rawValue, default: 0] += 1
                if identity.wireGroupID != nil { knownWire += 1 }
                if identity.originPublisherID != nil { knownOrigin += 1 }
                if identity.wireGroupID == nil {
                    unknownByPublisher[publishers[identity.articleID] ?? "", default: 0] += 1
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
            "unknown_by_publisher": unknownByPublisher,
        ]
    }

    /// Replays every event; with `assumeOwn`, also counts each unknown row as its publisher's own report, the
    /// independence-by-default policy this mapping refuses, to show what that policy would change.
    static func replays(_ rows: [Row], assumeOwn: Bool) throws -> [String: Any] {
        let events = Dictionary(grouping: rows.filter { $0.eventID != nil }, by: { $0.eventID ?? "" })
        var raw = 0
        var outsideWindow = 0
        var unknown = 0
        var independent = 0
        var reachingFloor = 0
        var accelerating = 0
        var multiReport = 0
        for (eventID, members) in events {
            let reports = EditorialWireIdentity.momentumReports(eventID: eventID, members: members.map(\.article))
                .map { assumeOwn ? assumed($0) : $0 }
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

    static func run(input: URL, output: URL) throws {
        let fixture = try JSONDecoder().decode(Input.self, from: Data(contentsOf: input))
        guard fixture.basis == "copied_library", let latest = fixture.articles.map(\.fetchedAt).max() else {
            throw CocoaError(.coderInvalidValue)
        }
        let recent = fixture.articles.filter { min($0.publishedAt, $0.fetchedAt) >= latest - 259_200 }
        let members = fixture.articles.filter { $0.eventID != nil }
        let report: [String: Any] = [
            "schema_version": 1, "basis": fixture.basis, "latest_fetch_epoch": latest,
            "library": coverage(fixture.articles), "recent_72h": coverage(recent), "event_members": coverage(members),
            "event_members_textContainment_0_4": coverage(members, textContainment: 0.4),
            "momentum_configuration": EditorialMomentumEvaluation.fields(configuration),
            "replay": try replays(members, assumeOwn: false),
            "replay_if_unknown_counted_as_own": try replays(members, assumeOwn: true),
            "members_stamped_after_storage_clamped": members.filter { $0.publishedAt > $0.fetchedAt }.count,
            "members_undated_left_out": members.filter {
                Date(timeIntervalSince1970: $0.publishedAt) == DateParser.unknownDate
            }.count,
            "limitations": [
                "No labels: no accuracy claim, and acceleration counts are not validated bursts.",
                "Thresholds were read off this same library copy; there is no holdout.",
            ],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Wire identity evaluation wrote \(output.path)")
    }
}
