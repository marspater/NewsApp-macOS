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

/// Briefing core intelligence (#849): sitrep cache stamps, edition snapshots, momentum, original reports and the
/// source footprint, through the production types.
enum BriefingIntelligenceTests {
    nonisolated(unsafe) private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("❌ FAILURE: \(message)")
        }
    }

    static func run() async {
        await testSitrepSaveRefusedWhenStale()
        await testSnapshotDiffAcrossEditions()
        testMomentum()
        testOriginalReports()
        testFootprintGrouping()
        await testSitrepComposerFallsBack()
        if failures > 0 {
            print("❌ BriefingIntelligenceTests: \(failures) failure(s)")
            exit(1)
        }
        print("Finished BriefingIntelligenceTests.")
    }

    private static func overview(version: Int, facts: [String]) -> EventOverviewDocument {
        EventOverviewDocument(
            eventID: "event-1",
            version: OverviewVersionContext(membershipVersion: version, inputTextHash: "input-\(version)"),
            content: OverviewContent(
                title: "Corridor", summary: "",
                facts: facts.enumerated().map { OverviewFact(id: "f\($0.offset)", text: $0.element, citationIDs: []) },
                citations: []),
            provenance: OverviewProvenance(memberArticleIDs: ["a1"], kind: .fallbackExcerpts))
    }

    private static func testSitrepSaveRefusedWhenStale() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let first = overview(version: 1, facts: ["Port authorities raised the security level."])
            check(try await db.recordEventOverview(first), "Stores the first overview")
            _ = try await db.upsertArticles([BriefingTestFactory.makeArticle(id: "a1", title: "Corridor")])
            let hash = DatabaseEngine.briefingSitrepInputHash(eventID: "event-1", title: "Corridor", overview: first)
            let renamed = DatabaseEngine.briefingSitrepInputHash(eventID: "event-1", title: "Renamed", overview: first)
            check(
                try await !db.saveBriefingSitrep(
                    eventID: "event-1", articleID: "a1", inputHash: renamed, text: "Line", isGenerated: true),
                "A line made under a headline the stored article no longer has is refused")
            check(
                try await db.saveBriefingSitrep(
                    eventID: "event-1", articleID: "a1", inputHash: hash, text: "Line", isGenerated: true),
                "A sitrep line made from the current overview is saved")
            check(try await db.fetchBriefingSitrep(eventID: "event-1")?.text == "Line", "The saved line reads back")
            let second = overview(version: 2, facts: ["Port authorities raised the security level."])
            check(try await db.recordEventOverview(second), "Stores the newer overview")
            check(
                try await !db.saveBriefingSitrep(
                    eventID: "event-1", articleID: "a1", inputHash: hash, text: "Stale", isGenerated: true),
                "A line made from an older overview version is refused")
            check(
                try await db.fetchBriefingSitrep(eventID: "event-1")?.text == "Line",
                "The refused save leaves the cache unchanged")
            await db.close()
        } catch {
            check(false, "Sitrep stamp test threw \(error)")
        }
    }

    private static func testSnapshotDiffAcrossEditions() async {
        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            let monday = Date(timeIntervalSince1970: 1_790_000_000)
            let tuesday = monday.addingTimeInterval(86_400)
            let old = [
                BriefingEditionSnapshotRow(eventID: "a", membershipVersion: 1, publisherCount: 3, escalation: nil),
                BriefingEditionSnapshotRow(eventID: "b", membershipVersion: 1, publisherCount: 2, escalation: nil),
            ]
            try await db.saveBriefingSnapshot(startedAt: monday, rows: old)
            try await db.saveBriefingSnapshot(startedAt: monday, rows: old)
            check(try await db.latestBriefingSnapshot(before: monday) == nil, "No edition precedes the first")
            let current = [
                BriefingSinceLastData.Current(
                    snapshot: BriefingEditionSnapshotRow(
                        eventID: "a", membershipVersion: 2, publisherCount: 6, escalation: nil), title: "Corridor"),
                BriefingSinceLastData.Current(
                    snapshot: BriefingEditionSnapshotRow(
                        eventID: "b", membershipVersion: 1, publisherCount: 2, escalation: "deescalating"),
                    title: "Border"),
                BriefingSinceLastData.Current(
                    snapshot: BriefingEditionSnapshotRow(
                        eventID: "c", membershipVersion: 1, publisherCount: 2, escalation: nil), title: "Ports"),
            ]
            try await db.saveBriefingSnapshot(startedAt: tuesday, rows: current.map(\.snapshot))
            guard let previous = try await db.latestBriefingSnapshot(before: tuesday) else {
                check(false, "The earlier edition is found")
                return
            }
            check(previous.startedAt == monday, "The previous edition is Monday's")
            check(previous.rows.count == 2, "Saving an edition twice keeps one row per event")
            let empty = tuesday.addingTimeInterval(-3600)
            try await db.saveBriefingSnapshot(startedAt: empty, rows: [])
            let emptyPrevious = try await db.latestBriefingSnapshot(before: tuesday)
            check(
                emptyPrevious?.startedAt == empty && emptyPrevious?.rows.isEmpty == true,
                "An edition without events is still the previous edition")
            try await db.eventRows(
                "DELETE FROM briefing_edition_snapshots WHERE edition_started_at = ?;",
                [.real(empty.timeIntervalSince1970)])
            let rows = BriefingSinceLastData.changes(
                previous: previous.rows, previousAt: previous.startedAt, current: current)
            check(
                rows.map(\.kind) == [.newEvent, .moreCoverage, .easing],
                "Rows are new event, more coverage, easing: \(rows.map(\.kind))")
            check(rows.first?.text == "Ports", "The new event is the one missing from Monday")
            check(
                rows.dropFirst().first?.meta.hasPrefix("+3 publishers since") == true, "More coverage counts the gain")
            check(
                BriefingSinceLastData.changes(
                    previous: current.map(\.snapshot), previousAt: tuesday, current: current
                ).isEmpty, "An unchanged edition yields no rows")
            await db.close()
        } catch {
            check(false, "Snapshot test threw \(error)")
        }
    }

    private static func testMomentum() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func hoursAgo(_ hours: [Double]) -> [Date] { hours.map { now.addingTimeInterval(-$0 * 3600) } }
        check(BriefingPriorityData.momentum(dates: hoursAgo([1, 2, 3, 8]), now: now) == .rising, "More recent: rising")
        check(BriefingPriorityData.momentum(dates: hoursAgo([1, 7]), now: now) == .steady, "Equal halves: steady")
        check(
            BriefingPriorityData.momentum(dates: hoursAgo([2, 7, 9, 11]), now: now) == .fading, "Fewer recent: fading")
        check(
            BriefingPriorityData.momentum(dates: hoursAgo([13, 20]), now: now) == .steady, "Old reports only: steady")
    }

    private static func testOriginalReports() {
        let reports: [(publisher: String, text: String)] = [
            ("Reuters", "LONDON (Reuters) - Ports raised security."),
            ("The Guardian", "Our correspondent saw ships turned back."),
            ("Daily Example", "LONDON (Reuters) - Ports raised security."),
            ("Daily Example", "(Reuters) - Insurers raised premiums."),
            ("Other Times", "Officials met on Monday."),
        ]
        check(
            BriefingPriorityData.originalReports(reports) == 3,
            "A wire agency's own report counts; a paper running only wire copy does not")
        check(BriefingPriorityData.isWireCopy(text: "(AP) - Text", publisher: "Daily Example"), "AP copy is wire")
        check(!BriefingPriorityData.isWireCopy(text: "(Reuters) - Text", publisher: "Reuters"), "Reuters is original")
    }

    private static func testFootprintGrouping() {
        guard
            let global = FeedCatalog.allFeeds.first(where: {
                $0.region == "global"
                    && OverviewPerspectivesExtractor.detectWireSource(in: "", articleSource: $0.publisher) == nil
            })?.publisher,
            let british = FeedCatalog.allFeeds.first(where: { $0.region == "GB" })?.publisher
        else {
            check(false, "The catalog holds a global and a British publisher")
            return
        }
        let data = BriefingFootprintData.make([
            (global, "Ships turned back."), (british, "AFP - Ships turned back."), (british, "Second report."),
            ("Reuters", "Ships turned back."), ("Unknown Gazette", "Ships turned back."),
        ])
        let groups = Dictionary(uniqueKeysWithValues: data.groups.map { ($0.label, $0.count) })
        check(data.publisherCount == 4, "Publishers count once each")
        check(groups["International"] == 1, "A global publisher is International: \(groups)")
        check(groups["Europe"] == 1, "A British publisher goes by its continent: \(groups)")
        check(groups[BriefingFootprintData.wireAgencies] == 1, "Reuters is a wire agency: \(groups)")
        check(groups["Other"] == 1, "A publisher outside the catalog is Other: \(groups)")
        check(data.wireCopyCount == 0, "A publisher with one original report is not wire copy")
        check(data.originalCount == 4, "Every publisher has an original report")
    }

    private static func testSitrepComposerFallsBack() async {
        let highlights = [
            BriefingSitrepComposer.Highlight(text: "Port authorities raised the security level.", publisher: "Reuters")
        ]
        let invented = NewsTextModel { _, _ in "Port authorities in Rotterdam raised the security level for vessels." }
        let invent = await BriefingSitrepComposer.compose(title: "Corridor", highlights: highlights, model: invented)
        check(invent?.isGenerated == false, "A sentence naming something the inputs lack falls back")
        check(invent?.text == highlights[0].text, "The fallback is the first highlight")
        let figure = NewsTextModel { _, _ in "Port authorities raised the security level to 3, Reuters reports." }
        let numbered = await BriefingSitrepComposer.compose(title: "Corridor", highlights: highlights, model: figure)
        check(numbered?.isGenerated == false, "A sentence with an invented figure falls back")
        check(numbered?.isFinal == true, "A rejected model answer is cached as the highlight")
        let off = await BriefingSitrepComposer.compose(title: "Corridor", highlights: highlights, model: .unavailable)
        check(off?.isFinal == false, "A line made with the model off is not cached")
        let negated = [
            BriefingSitrepComposer.Highlight(text: "Officials denied that ships were damaged.", publisher: nil)
        ]
        let dropped = await BriefingSitrepComposer.compose(
            title: "Corridor", highlights: negated,
            model: NewsTextModel { _, _ in "Officials said that ships were damaged in the corridor." })
        check(dropped?.isGenerated == false, "A sentence that drops the facts' negation falls back")
        check(
            BriefingSitrepComposer.keepsQualifiers("Officials denied damage.", facts: [negated[0].text]),
            "A sentence keeping the negation passes")
        let faithful = NewsTextModel { _, _ in "Port authorities raised the security level, Reuters reports." }
        let kept = await BriefingSitrepComposer.compose(title: "Corridor", highlights: highlights, model: faithful)
        check(kept?.isGenerated == true, "A sentence restating the inputs is kept")
        let busy = await BriefingSitrepComposer.compose(
            title: "Corridor", highlights: highlights,
            model: NewsTextModel { _, _ in throw NewsTextModel.TemporarilyUnavailable() })
        check(busy?.isFinal == false, "A line made while the model is busy is not final")
        check(
            await BriefingSitrepComposer.compose(title: "Corridor", highlights: [], model: faithful) == nil,
            "No highlights, no line")
    }
}
