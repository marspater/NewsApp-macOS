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

/// Briefing strategic impact (#850): region mapping and filter, industry grouping, drivers coverage wording and the
/// escalation timeline. Drives production types only (#804).
enum BriefingImpactTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [BriefingImpactTests.swift:\(line)]: \(message)")
        }
    }

    static func run() async {
        print("=== Running Briefing strategic impact (#850) tests ===")
        regionMapping()
        regionFilter()
        industryGrouping()
        driversCoverage()
        timelineOrdering()
        print("Finished \(checks) Briefing strategic impact checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }

    static let now = Date(timeIntervalSince1970: 1_793_372_400)

    static func regionMapping() {
        check(BriefingRegion.region(code: "IR") == .middleEastNorthAfrica, "Iran is Middle East")
        check(BriefingRegion.region(code: "IL") == .middleEastNorthAfrica, "Western Asia is Middle East")
        check(BriefingRegion.region(code: "LY") == .middleEastNorthAfrica, "Libya is North Africa")
        check(BriefingRegion.region(code: "NG") == .subSaharanAfrica, "Nigeria is Sub-Saharan Africa")
        check(BriefingRegion.region(code: "FR") == .europe, "France is Europe")
        check(BriefingRegion.region(code: "US") == .northAmerica, "US is North America")
        check(BriefingRegion.region(code: "MX") == .latinAmerica, "Mexico is Latin America")
        check(BriefingRegion.region(code: "KZ") == .southAsia, "Central Asia joins South Asia")
        check(BriefingRegion.region(code: "VN") == .eastSoutheastAsia, "Vietnam is East & Southeast Asia")
        check(BriefingRegion.region(code: "AU") == .oceania, "Australia is Oceania")
        let story = BriefingRegionsData.sampleEntry(
            id: "impact-text", title: "Ceasefire talks resume in Egypt as Ukrainian aid arrives", publishers: 1,
            date: now)
        check(
            BriefingRegion.regions(of: story.representative) == [.middleEastNorthAfrica, .europe],
            "headline countries map to their regions")
        let nested = BriefingRegionsData.sampleEntry(
            id: "impact-nested", title: "Aid reaches South Sudan", publishers: 1, date: now)
        check(
            BriefingRegion.regions(of: nested.representative) == [.subSaharanAfrica], "South Sudan never counts Sudan")
    }

    static func regionFilter() {
        let cairo = BriefingRegionsData.sampleEntry(
            id: "impact-filter-cairo", title: "Talks resume in Egypt", publishers: 3, date: now)
        let tokyo = BriefingRegionsData.sampleEntry(
            id: "impact-filter-tokyo", title: "Election called in Japan", publishers: 1, date: now)
        var filter = BriefingBoardFilter()
        check(filter.includes(cairo) && filter.includes(tokyo), "no region includes everything")
        filter.region = .middleEastNorthAfrica
        check(filter.includes(cairo), "Egypt is in Middle East & North Africa")
        check(!filter.includes(tokyo), "Japan is outside Middle East & North Africa")
        // The loader's resolved regions win over the headline.
        filter.regionsByEntry = [tokyo.id: [.middleEastNorthAfrica]]
        check(filter.includes(tokyo), "resolved regions are used when known")
        filter.regionsByEntry = [:]
        let data = BriefingRegionsData.make(
            entries: [tokyo, cairo],
            regionsByEntry: [cairo.id: [.middleEastNorthAfrica], tokyo.id: [.eastSoutheastAsia]],
            facts: [:], now: now)
        check(data?.rows.map(\.region) == [.middleEastNorthAfrica, .eastSoutheastAsia], "ties keep canonical order")
        check(data?.rows.first?.countText == "Zen · 1 story", "count text says stories")
        check(
            BriefingRegionsData.make(entries: [tokyo], regionsByEntry: [:], facts: [:], now: now) == nil, "empty is nil"
        )
    }

    static func industryGrouping() {
        let cairo = BriefingRegionsData.sampleEntry(
            id: "impact-ind-cairo", title: "Talks in Cairo", publishers: 2, date: now)
        let paris = BriefingRegionsData.sampleEntry(
            id: "impact-ind-paris", title: "Strike in France", publishers: 2, date: now)
        typealias Mention = BriefingIndustryData.Mention
        let data = BriefingIndustryData(sectors: [
            .init(
                industry: "Energy",
                mentions: [Mention(entry: cairo, implication: "Fuel costs rose.", citationIDs: ["a"])]),
            .init(
                industry: "Transportation",
                mentions: [
                    Mention(entry: cairo, implication: "Ships rerouted.", citationIDs: ["b", "c"]),
                    Mention(entry: paris, implication: "Trains stopped.", citationIDs: ["c", "d"]),
                ]),
        ])
        let cards = data.cards(for: BriefingBoardFilter())
        check(cards.map(\.industry) == ["Transportation", "Energy"], "most stories first")
        check(cards.first?.sourceText == "From 2 stories · 4 cited passages", "citation IDs count per story")
        check(cards.first?.implication == "Ships rerouted.", "first implication")
        check(cards.last?.sourceText == "From 1 story · 1 cited passage", "singular wording")
        let europe = data.cards(for: BriefingBoardFilter(region: .europe))
        check(europe.map(\.industry) == ["Transportation"], "sectors outside the region hide")
        check(europe.first?.sourceText == "From 1 story · 2 cited passages", "filtered counts")
        check(BriefingIndustryData.make([]) == nil, "no overviews is nil")
        check(data.hasRows(under: BriefingBoardFilter()), "rows without a filter")
        check(!data.hasRows(under: BriefingBoardFilter(region: .oceania)), "no rows outside every story's region")
        let made = BriefingIndustryData.make([
            (cairo, overview(items: [("Energy", ["c1"]), ("Retail & E-commerce", ["missing"])])),
            (paris, overview(items: [("Energy", ["c1"])])),
        ])
        check(made?.sectors.map(\.industry) == ["Energy"], "an item citing no stored passage is dropped")
        check(
            made?.cards(for: BriefingBoardFilter()).first?.sourceText == "From 2 stories · 2 cited passages",
            "the same citation ID in two stories is two passages")
    }

    static func overview(items: [(String, [String])]) -> EventOverviewDocument {
        EventOverviewDocument(
            eventID: "event-\(UUID().uuidString)",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "input"),
            content: OverviewContent(
                title: "Story", summary: "",
                citations: [
                    OverviewCitation(
                        id: "c1", articleID: "a1", passageID: "p1", passageFingerprint: "f1", quote: "Quote.")
                ],
                evidenceSections: OverviewEvidenceSections(
                    industryImpact: items.map {
                        OverviewIndustryImpact(industry: $0.0, implication: "Costs rose.", citationIDs: $0.1)
                    })),
            provenance: OverviewProvenance(memberArticleIDs: ["a1"], kind: .synthesized))
    }

    static func driversCoverage() {
        check(BriefingDriversData.coverageText(publishers: 1) == "one report", "one report")
        check(BriefingDriversData.coverageText(publishers: 3) == "thin coverage", "thin coverage")
        check(BriefingDriversData.coverageText(publishers: 5) == "well covered", "well covered")
        let rows = BriefingDriversData.captureFixture?.rows(for: BriefingBoardFilter()) ?? []
        check(rows.first?.type == .armedConflict && rows.first?.severity == 1, "armed conflict is the full bar")
        check(
            rows.map(\.coverageText) == ["well covered", "well covered", "thin coverage", "one report"],
            "coverage apart")
        check(BriefingDriversData.make([]) == nil, "no classified events is nil")
    }

    static func timelineOrdering() {
        let day: TimeInterval = 86_400
        let timeline = [
            OverviewTimelineItem(
                id: "3", dateText: "Wed", summary: "Fighting escalated overnight", eventDate: now - day),
            OverviewTimelineItem(id: "1", dateText: "Mon", summary: "First report", eventDate: now - 3 * day),
            OverviewTimelineItem(
                id: "f", dateText: "Fri", summary: "Talks planned", isFuturePlan: true, eventDate: now - day),
            OverviewTimelineItem(id: "n", dateText: "Later", summary: "Next week", eventDate: now + day),
            OverviewTimelineItem(id: "2", dateText: "Tue", summary: "Second report", publicationDate: now - 2 * day),
        ]
        let items = BriefingTimelineData.items(timeline, now: now)
        check(items?.map(\.id) == ["1", "2", "3"], "past dated items in date order")
        check(items?.map(\.isEscalating) == [false, false, true], "escalating item marked")
        check(BriefingTimelineData.items(Array(timeline.prefix(1)), now: now) == nil, "one item is not a timeline")
        let entry = BriefingRegionsData.sampleEntry(id: "impact-timeline", title: "Thread", publishers: 4, date: now)
        check(BriefingTimelineData.thread(entry: entry, timeline: timeline, now: now)?.day == 3, "day count")
        let many = (0..<8).map {
            OverviewTimelineItem(
                id: "\($0)", dateText: "D\($0)", summary: "Step", eventDate: now - Double(8 - $0) * day)
        }
        let other = [
            OverviewTimelineItem(id: "x", dateText: "Mon", summary: "First report", eventDate: now - 3 * day),
            OverviewTimelineItem(id: "4", dateText: "Thu", summary: "Talks begin", eventDate: now - day / 2),
        ]
        let merged = BriefingTimelineData.merged([timeline, other], now: now)
        check(merged.filter { $0.summary == "First report" }.map(\.id) == ["1"], "identical summaries merge once")
        check(
            BriefingTimelineData.items(merged, now: now)?.map(\.id) == ["1", "2", "3", "4"],
            "both events' timelines in date order")
        let shadowed = BriefingTimelineData.merged(
            [
                [OverviewTimelineItem(id: "plan", dateText: "Soon", summary: "Escorts begin", isFuturePlan: true)],
                [OverviewTimelineItem(id: "undated", dateText: "", summary: "Escorts begin")],
                [OverviewTimelineItem(id: "real", dateText: "Thu", summary: "Escorts begin", eventDate: now - day)],
            ], now: now)
        check(shadowed.map(\.id) == ["real"], "a plan or undated copy never hides the dated past one")
        check(BriefingDriversData.captureFixture?.hasRows(under: BriefingBoardFilter()) == true, "drivers have rows")
        check(
            BriefingTimelineData.captureFixture?.hasRows(under: BriefingBoardFilter(region: .oceania)) == false,
            "no thread outside the filter")
        check(BriefingTimelineData.items(many, now: now)?.map(\.id) == ["3", "4", "5", "6", "7"], "latest five")
    }
}
