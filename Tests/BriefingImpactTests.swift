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
import SwiftUI

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
        await regionSupplementDeduplication()
        await regionTileState()
        await regionSupplementNavigation()
        industryGrouping()
        driversCoverage()
        timelineOrdering()
        timelineBuilderPartialDates()
        timelineDistinctDates()
        await dynamicIndicatorsAndOverviewQuality()
        await comprehensiveCoverageVerification()
        print("Finished \(checks) Briefing strategic impact checks with \(failures) failures.")
        if failures > 0 { recordFailure("BriefingImpactTests: \(failures) check failure(s)") }
    }

    static let now = Date(timeIntervalSince1970: 1_793_372_400)

    static func regionMapping() {
        check(BriefingRegion.region(code: "IR") == .middleEastNorthAfrica, "Iran is Middle East and Africa")
        check(BriefingRegion.region(code: "IL") == .middleEastNorthAfrica, "Western Asia is Middle East and Africa")
        check(BriefingRegion.region(code: "LY") == .middleEastNorthAfrica, "Libya is Middle East and Africa")
        check(BriefingRegion.region(code: "NG") == .middleEastNorthAfrica, "Nigeria is Middle East and Africa")
        check(BriefingRegion.region(code: "FR") == .europe, "France is Europe")
        check(BriefingRegion.region(code: "US") == .northAmerica, "US is North America")
        check(BriefingRegion.region(code: "CA") == .northAmerica, "Canada is North America")
        check(BriefingRegion.region(code: "BM") == nil, "North America is restricted to US and Canada")
        check(BriefingRegion.region(code: "MX") == .latinAmerica, "Mexico is LATAM")
        check(BriefingRegion.region(code: "BR") == .latinAmerica, "Brazil is LATAM")
        check(BriefingRegion.region(code: "KZ") == .southAsia, "Central Asia joins APAC")
        check(BriefingRegion.region(code: "VN") == .southAsia, "Vietnam is APAC")
        check(BriefingRegion.region(code: "AU") == .southAsia, "Australia is APAC")
        check(BriefingRegion.region(code: "JP") == .southAsia, "Japan is APAC")
        check(TensionMacroRegion.southAsia.briefingTitle == "APAC", "APAC title")
        check(TensionMacroRegion.middleEastNorthAfrica.briefingTitle == "Middle East and Africa", "MEA title")
        check(TensionMacroRegion.latinAmerica.briefingTitle == "LATAM", "LATAM title")
        let story = BriefingRegionsData.sampleEntry(
            id: "impact-text", title: "Ceasefire talks resume in Egypt as Ukrainian aid arrives", publishers: 1,
            date: now)
        check(
            BriefingRegion.regions(of: story.representative) == [.middleEastNorthAfrica, .europe],
            "headline countries map to their regions")
        let nested = BriefingRegionsData.sampleEntry(
            id: "impact-nested", title: "Aid reaches South Sudan", publishers: 1, date: now)
        check(
            BriefingRegion.regions(of: nested.representative) == [.middleEastNorthAfrica],
            "South Sudan maps to Middle East and Africa without double-counting Sudan")
        let ukraineArticle = FeedArticle(
            storedID: "ukraine-ceasefire",
            title: "Ukraine: Six-day localized ceasefire in Oleshky comes to end",
            link: "https://www.dw.com/en/ukraine-ceasefire",
            guid: "ukraine-ceasefire",
            description:
                "A US-brokered ceasefire in Ukraine's southern Kherson region ended on Sunday night with no violations reported.",
            pubDate: now,
            source: "Deutsche Welle")
        let ukraineEntry = FeedEntry.article(ukraineArticle)
        let ukraineFeatures = EventFeatures(places: ["@UA", "@US"], date: now)
        let resolvedUkraine = BriefingRegionsData.resolveRegions(
            for: ukraineEntry, features: [ukraineArticle.id: ukraineFeatures])
        check(
            resolvedUkraine == Set([TensionMacroRegion.europe]),
            "Ukraine story with US-brokered in description resolves strictly to Europe, not North America: \(resolvedUkraine)"
        )
    }

    static func regionFilter() {
        let cairo = BriefingRegionsData.sampleEntry(
            id: "impact-filter-cairo", title: "Talks resume in Egypt", publishers: 3, date: now)
        let tokyo = BriefingRegionsData.sampleEntry(
            id: "impact-filter-tokyo", title: "Election called in Japan", publishers: 1, date: now)
        var filter = BriefingBoardFilter()
        check(filter.includes(cairo) && filter.includes(tokyo), "no region includes everything")
        filter.region = .middleEastNorthAfrica
        check(filter.includes(cairo), "Egypt is in Middle East and Africa")
        check(!filter.includes(tokyo), "Japan is outside Middle East and Africa")
        // The loader's resolved regions win over the headline.
        filter.regionsByEntry = [tokyo.id: [.middleEastNorthAfrica]]
        check(filter.includes(tokyo), "resolved regions are used when known")
        filter.regionsByEntry = [:]
        let data = BriefingRegionsData.make(
            entries: [tokyo, cairo],
            regionsByEntry: [cairo.id: [.middleEastNorthAfrica], tokyo.id: [.eastSoutheastAsia]],
            facts: [:], now: now)
        check(data?.rows.map(\.region) == [.middleEastNorthAfrica, .southAsia], "ties keep canonical order")
        check(data?.rows.first?.countText == "Zen · 1 story", "count text says stories")
        check(
            BriefingRegionsData.make(entries: [tokyo], regionsByEntry: [:], facts: [:], now: now) == nil, "empty is nil"
        )
    }

    /// #1311/5: A grouped edition event may have one listed article, while recent articles from the
    /// same event enter through the supplement query with a different representative.
    @MainActor static func regionSupplementDeduplication() async {
        let first = FeedArticle(
            storedID: "region-1311-a", title: "France debates rail investment",
            link: "https://example.com/france-a", guid: "region-1311-a",
            description: "Rail investment in France", pubDate: now.addingTimeInterval(-3600), source: "Wire A")
        let second = FeedArticle(
            storedID: "region-1311-b", title: "France debates rail investment",
            link: "https://example.com/france-b", guid: "region-1311-b",
            description: "Rail investment in France", pubDate: now.addingTimeInterval(-7200), source: "Wire B")
        let database = DatabaseEngine(path: ":memory:")
        do {
            try await database.open()
            _ = try await database.upsertArticles([first, second])
            let event = try await database.createEvent(memberArticleIDs: [first.id, second.id], at: now)
            guard let summary = try await database.eventFeedSummaries(forArticles: [first.id]).first else {
                check(false, "confirmed edition event must have a summary")
                return
            }
            let edition: FeedEntry = .event(summary, representative: first, visibleMembers: [first])
            let store = ArticleStore(database: database, spotlightIndexer: MockSpotlightIndexer())
            let context = BriefingLoadContext(
                entries: [edition], heroIDs: [], briefing: nil, now: now, tension: WorldTensionState(),
                readIDs: [], previousEditionStartedAt: nil)
            guard let loaded = await BriefingRegionsData.load(context, store: store) else {
                check(false, "Regions loader should return the France edition event")
                return
            }
            let europe = loaded.rows.first { $0.region == .europe }
            check(europe?.entries.count == 1, "supplement does not duplicate an edition event")
            check(europe?.countText == "Zen · 1 story", "region count and level use the unique event")
            check(
                europe?.entries.first?.id == first.id,
                "edition representative survives the supplemental event with a different article")
            check(summary.eventID == event.id, "fixture's extra article belongs to the same event")
        } catch {
            check(false, "Regions loader integration regression failed: \(error)")
        }
    }

    /// #1311/8: The same read/save state as other Briefing tiles reaches Regions tiles.
    @MainActor static func regionTileState() {
        let entry = BriefingRegionsData.sampleEntry(
            id: "region-state", title: "France debates rail investment", publishers: 1, date: now)
        let id = entry.representative.id
        let active = BriefingRegionTilesModuleView.tileState(
            for: entry, isLead: true, now: now, readIDs: [id], savedIDs: [id])
        check(active.isRead && active.isSaved, "Regions tiles honor read and saved state")
        check(active.isLead, "Regions tiles retain the lead accent")
        let clear = BriefingRegionTilesModuleView.tileState(
            for: entry, isLead: false, now: now, readIDs: [], savedIDs: [])
        check(!clear.isRead && !clear.isSaved, "Regions tiles show unread and unsaved only when true")
    }

    /// #1311/4: Region events not in the edition still reach the list's entry-opening action.
    @MainActor static func regionSupplementNavigation() async {
        let supplemental = BriefingRegionsData.sampleEntry(
            id: "supplement-outside-edition", title: "Talks resume in France",
            publishers: 3, date: now)
        var opened: FeedEntry?
        let actions = BriefingActions(
            onOpenEntry: { opened = $0 }, onStartNewBriefing: {}, onBackToToday: {})
        actions.open(supplemental)
        check(opened == supplemental, "supplemental event opens by its original entry, not an edition lookup")

        let regions = BriefingRegionsData.make(
            entries: [supplemental], regionsByEntry: [supplemental.id: [.europe]], facts: [:], now: now)
        let savedIDs = BriefingRegionsData.savedIDs(edition: [], regions: regions) {
            $0.id == supplemental.representative.id
        }
        check(
            savedIDs == Set([supplemental.representative.id]),
            "saved supplemental region articles reach the Briefing tiles (#1311/8)")
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

    /// #1241: builder items carry no event date; their ordering date places them in the story thread, and the row
    /// shows the stated text, so a date stated without a year is shown without one.
    static func timelineBuilderPartialDates() {
        let article = FeedArticle(
            storedID: "brief-1241", title: "Port strike", link: "https://example.com/brief-1241", guid: "brief-1241",
            description: "", pubDate: now - 3_600, source: "Wire")
        let sentences = [
            "The ports reopened on 28 October.",
            "Contract talks collapsed on 1 October 2026.",
            "The strike began on 26 October.",
            "Pickets gathered yesterday morning.",
        ]
        let passages = sentences.enumerated().map {
            EvidencePassage(id: "brief-p\($0.offset)", articleID: article.id, text: $0.element, ordinal: $0.offset)
        }
        let facts = passages.map {
            PassageAnchoredFact(
                id: "f-\($0.id)", statement: $0.text, passageID: $0.id, quote: $0.text, articleID: article.id)
        }
        let timeline = OverviewTimelineBuilder.build(
            facts: facts, passages: passages, articles: [article], locale: Locale(identifier: "en_US")
        ).items
        check(timeline.allSatisfy { $0.eventDate == nil }, "builder items carry no event date")
        let items = BriefingTimelineData.items(timeline, now: now)
        check(
            items?.map(\.summary) == [sentences[1], sentences[2], sentences[0]],
            "builder items, partial dates included, appear in date order")
        let partial = items?.first { $0.summary == sentences[2] }
        check(
            partial?.dayText == "Oct 26",
            "a date stated without a year is shown without one: \(partial?.dayText ?? "-")")
        check(items?.first?.dayText.contains("2026") == true, "a stated year is shown")
        check(
            timeline.contains { $0.dateKind == .anchor } && items?.contains { $0.summary == sentences[3] } == false,
            "a relative anchor stays in the overview but out of the Briefing thread")
    }

    /// #1241 decisions 4 and 6: a thread needs two distinct occurrence dates among the rows it shows, distinct only when
    /// their spans do not overlap; "day N" needs a day-precision first row.
    static func timelineDistinctDates() {
        let day: TimeInterval = 86_400
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: now)
        func row(_ id: String, _ text: String, _ date: Date, _ precision: OverviewTimelineItem.DatePrecision = .day)
            -> OverviewTimelineItem
        {
            OverviewTimelineItem(
                id: id, dateText: text, datePrecision: precision, summary: "Step \(id)",
                orderingDateMayHoldInferredYear: date)
        }
        let entry = BriefingRegionsData.sampleEntry(id: "distinct", title: "Thread", publishers: 4, date: now)
        check(
            BriefingTimelineData.items(
                [row("a", "Nov 4", today - 3 * day), row("b", "Nov 4", today - 3 * day)], now: now)
                == nil, "two rows with one date are no thread (71756C1C)")
        check(
            BriefingTimelineData.items(
                [row("a", "Nov 4", today - 3 * day), row("b", "2026 Nov 4", today - 3 * day)], now: now)
                == nil, "one day written two ways is one date")
        let monthStart = utc.dateInterval(of: .month, for: today - 40 * day)!.start
        check(
            BriefingTimelineData.items(
                [row("m", "October 2026", monthStart, .month), row("d", "Oct 9", monthStart + 8 * day)], now: now)
                == nil,
            "a month and a day inside it are one date")
        check(
            BriefingTimelineData.items(
                [row("a", "Nov 3", today - 4 * day), row("b", "Nov 4", today - 3 * day)], now: now)?
                .count == 2, "two real days are a thread")
        check(
            BriefingTimelineData.thread(
                entry: entry, timeline: [row("a", "Nov 3", today - 4 * day), row("b", "Nov 4", today - 3 * day)],
                now: now)?
                .day != nil, "a day-precision start counts days")
        let monthLed = BriefingTimelineData.thread(
            entry: entry,
            timeline: [
                row("m", "September 2026", utc.dateInterval(of: .month, for: today - 70 * day)!.start, .month),
                row("d", "Nov 4", today - 3 * day),
            ], now: now)
        check(monthLed != nil && monthLed?.day == nil, "a month-only start shows no day count")
        check(monthLed?.caption == "Thread", "the caption drops the count")
        let publication = OverviewTimelineItem(
            id: "p", dateText: "Nov 2", dateKind: .publication, summary: "Filed", publicationDate: today - 5 * day)
        check(
            BriefingTimelineData.items([publication, row("b", "Nov 4", today - 3 * day)], now: now) == nil,
            "a publication date never makes the second date")

        let savedTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = savedTimeZone }
        let utcStart = utc.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 0))!
        let utcSecond = utc.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 0))!
        let utcNow = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
        let laThread = BriefingTimelineData.thread(
            entry: entry, timeline: [row("u1", "Nov 3", utcStart), row("u2", "Nov 4", utcSecond)], now: utcNow)
        check(
            laThread?.day == 2,
            "day count uses UTC calendar rather than local time zone (got \(laThread?.day.map(String.init) ?? "nil"))")
    }

    static func timelineOrdering() {
        let day: TimeInterval = 86_400
        let timeline = [
            OverviewTimelineItem(
                id: "3", dateText: "Wed", datePrecision: .day, summary: "Fighting escalated overnight",
                eventDate: now - day),
            OverviewTimelineItem(
                id: "1", dateText: "Mon", datePrecision: .day, summary: "First report", eventDate: now - 3 * day),
            OverviewTimelineItem(
                id: "f", dateText: "Fri", datePrecision: .day, summary: "Talks planned", isFuturePlan: true,
                eventDate: now - day),
            OverviewTimelineItem(
                id: "n", dateText: "Later", datePrecision: .day, summary: "Next week", eventDate: now + day),
            OverviewTimelineItem(id: "2", dateText: "Tue", summary: "Second report", publicationDate: now - 2 * day),
        ]
        let items = BriefingTimelineData.items(timeline, now: now)
        check(items?.map(\.id) == ["1", "3"], "past occurrence dates in date order; a publication date is none")
        check(items?.map(\.isEscalating) == [false, true], "escalating item marked")
        check(BriefingTimelineData.items(Array(timeline.prefix(1)), now: now) == nil, "one item is not a timeline")
        let entry = BriefingRegionsData.sampleEntry(id: "impact-timeline", title: "Thread", publishers: 4, date: now)
        check(BriefingTimelineData.thread(entry: entry, timeline: timeline, now: now)?.day == 3, "day count")
        let many = (0..<8).map {
            OverviewTimelineItem(
                id: "\($0)", dateText: "D\($0)", datePrecision: .day, summary: "Step",
                eventDate: now - Double(8 - $0) * day)
        }
        let other = [
            OverviewTimelineItem(
                id: "x", dateText: "Mon", datePrecision: .day, summary: "First report", eventDate: now - 3 * day),
            OverviewTimelineItem(
                id: "4", dateText: "Thu", datePrecision: .day, summary: "Talks begin", eventDate: now - day / 2),
        ]
        let merged = BriefingTimelineData.merged([("a", timeline), ("b", other)], now: now)
        check(merged.filter { $0.summary == "First report" }.map(\.id) == ["a/1"], "identical summaries merge once")
        check(
            BriefingTimelineData.items(merged, now: now)?.map(\.id) == ["a/1", "a/3", "b/4"],
            "both events' timelines in date order")
        // #1241: every overview numbers its items from timeline_1, so ids are prefixed with the event once merged.
        let twin = BriefingTimelineData.merged(
            [
                (
                    "e1",
                    [
                        OverviewTimelineItem(
                            id: "timeline_1", dateText: "Mon", datePrecision: .day, summary: "Port closed",
                            eventDate: now - 2 * day)
                    ]
                ),
                (
                    "e2",
                    [
                        OverviewTimelineItem(
                            id: "timeline_1", dateText: "Tue", datePrecision: .day, summary: "Port reopened",
                            eventDate: now - day)
                    ]
                ),
            ], now: now)
        check(
            Set(twin.map(\.id)).count == 2 && twin.map(\.id) == ["e1/timeline_1", "e2/timeline_1"],
            "merged rows of several events have unique, stable ids")
        let shadowed = BriefingTimelineData.merged(
            [
                (
                    "p",
                    [OverviewTimelineItem(id: "plan", dateText: "Soon", summary: "Escorts begin", isFuturePlan: true)]
                ),
                ("u", [OverviewTimelineItem(id: "undated", dateText: "", summary: "Escorts begin")]),
                (
                    "r",
                    [
                        OverviewTimelineItem(
                            id: "real", dateText: "Thu", datePrecision: .day, summary: "Escorts begin",
                            eventDate: now - day)
                    ]
                ),
            ], now: now)
        check(shadowed.map(\.id) == ["r/real"], "a plan or undated copy never hides the dated past one")
        check(BriefingDriversData.captureFixture?.hasRows(under: BriefingBoardFilter()) == true, "drivers have rows")
        check(
            BriefingTimelineData.captureFixture?.hasRows(under: BriefingBoardFilter(region: .oceania)) == false,
            "no thread outside the filter")
        check(BriefingTimelineData.items(many, now: now)?.map(\.id) == ["3", "4", "5", "6", "7"], "latest five")
    }

    static func dynamicIndicatorsAndOverviewQuality() async {
        // 1. Priority Developments dynamic Impact rating (never nil / "Not rated")
        let majorEntry = BriefingRegionsData.sampleEntry(
            id: "imp-major", title: "Ukraine: Six-day localized ceasefire in Oleshky comes to end", publishers: 6,
            date: now)
        check(
            BriefingPriorityData.assessImportance(
                publisherCount: majorEntry.publisherCount, representative: majorEntry.representative, momentum: .fading)
                == .major,
            "High-coverage ceasefire story is rated Major")
        let notableEntry = BriefingRegionsData.sampleEntry(
            id: "imp-notable", title: "Parliament committee reviews trade tariff proposals", publishers: 3, date: now)
        check(
            BriefingPriorityData.assessImportance(
                publisherCount: notableEntry.publisherCount, representative: notableEntry.representative,
                momentum: .steady) == .notable,
            "Multi-publisher story thread is rated Notable")
        let conflictEntry = BriefingRegionsData.sampleEntry(
            id: "imp-conflict", title: "Missile strikes kill 50 people across frontline cities",
            publishers: 6, date: now)
        check(
            BriefingPriorityData.assessImportance(
                publisherCount: conflictEntry.publisherCount, representative: conflictEntry.representative,
                momentum: .rising) == .major,
            "Armed conflict story is rated Major")
        let nonTensionEntry = BriefingRegionsData.sampleEntry(
            id: "imp-culture", title: "Local gallery exhibits retrospective of classical landscape paintings",
            publishers: 1, date: now)
        check(
            BriefingPriorityData.assessImportance(
                publisherCount: nonTensionEntry.publisherCount, representative: nonTensionEntry.representative,
                momentum: .steady) == .minor,
            "Low-coverage culture story is rated Minor")

        // 2. World Tension sparkline tight dynamic Y-axis domain
        let domain = BriefingTensionSparklineView.yDomain(for: [], baseline: 38)
        check(domain.upperBound - domain.lowerBound <= 20, "Sparkline domain zooms to week's range rather than 0...100")

        // 3. Source Footprint clear footer copy
        check(
            BriefingFootprintModuleView.footerText(originalCount: 7, wireCopyCount: 0)
                == "All 7 original reports are independent publisher reporting (no syndicated wire-agency reprints).",
            "Clear human-readable footprint summary when wireCopyCount is 0")

        // 4. Highlights terminal period normalization
        check(
            OverviewComposer.ensureTerminalPeriod(
                "Trump invites Michigan Democrat Stevens to join the Republican Party")
                == "Trump invites Michigan Democrat Stevens to join the Republican Party.",
            "Highlight without period receives a terminal period")

        // 5. Perspectives: nested quote attribution ("I don't know Haley...," Trump said)
        let haleyQuoteText =
            "\"I don't know Haley. I've never met Haley. But Haley said what few people were willing to say,\" Trump said."
        let haleyPassage = EvidencePassage(id: "p_haley", articleID: "a_haley", text: haleyQuoteText)
        let haleyArticle = FeedArticle(
            storedID: "a_haley", title: "Michigan Senate Race", link: "https://bbc.com/haley",
            guid: "g_haley", description: haleyQuoteText, pubDate: now, source: "BBC News")
        let haleyCit = OverviewCitation(
            id: "c_haley", articleID: "a_haley", passageID: "p_haley",
            passageFingerprint: haleyPassage.fingerprint, quote: haleyQuoteText)
        let haleyPerspectives = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [haleyPassage], articles: [haleyArticle], existingCitations: ["c_haley": haleyCit])
        check(
            haleyPerspectives.map(\.participant) == ["Trump"],
            "Nested speech inside Trump's quote is not attributed to Haley")
        check(
            EventOverviewReaderView.cleanDisplayPosition(haleyPerspectives.first?.position ?? "").hasSuffix(",")
                == false,
            "Display position strips trailing comma")

        // 6. Perspectives: Mr. Nawrocki vs Nawrocki voice collapse, abbreviation period handling, and Tusk fragment rejection
        let nawrockiText =
            "\"Tonight, there was a breach of public order in the Republic of Poland and a forcible takeover of a constitutional body,\" Mr. Nawrocki said in a statement read out by an aide outside the court early on Saturday (October 31, 2026), after the President had turned back mid-flight from a trip to Africa to address the situation."
        let tribunalText =
            "The Constitutional Tribunal said its longest-serving judge Anna Korwin-Piotrowska had suspended Bogdan Swieczkowski, the tribunal's president and an appointee of Mr. Nawrocki."
        let tuskText = "\"And everything is clear,\" Tusk wrote on X."
        let pNawrocki = EvidencePassage(id: "p_naw", articleID: "a_hindu", text: nawrockiText)
        let pTribunal = EvidencePassage(id: "p_trib", articleID: "a_hindu", text: tribunalText)
        let pTusk = EvidencePassage(id: "p_tusk", articleID: "a_guardian", text: tuskText)
        let artHindu = FeedArticle(
            storedID: "a_hindu", title: "Poland court dispute", link: "https://thehindu.com/poland",
            guid: "g_hindu", description: nawrockiText, pubDate: now, source: "The Hindu")
        let artGuardian = FeedArticle(
            storedID: "a_guardian", title: "Poland tribunal crisis", link: "https://theguardian.com/poland",
            guid: "g_guardian", description: tuskText, pubDate: now, source: "The Guardian")
        let cits: [String: OverviewCitation] = [
            "c_naw": OverviewCitation(
                id: "c_naw", articleID: "a_hindu", passageID: "p_naw",
                passageFingerprint: pNawrocki.fingerprint, quote: nawrockiText),
            "c_trib": OverviewCitation(
                id: "c_trib", articleID: "a_hindu", passageID: "p_trib",
                passageFingerprint: pTribunal.fingerprint, quote: tribunalText),
            "c_tusk": OverviewCitation(
                id: "c_tusk", articleID: "a_guardian", passageID: "p_tusk",
                passageFingerprint: pTusk.fingerprint, quote: tuskText),
        ]
        let polandPerspectives = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [pNawrocki, pTribunal, pTusk], articles: [artHindu, artGuardian], existingCitations: cits)
        check(
            polandPerspectives.map(\.participant) == ["Mr. Nawrocki"],
            "Single article with direct quote emits only Mr. Nawrocki (no duplicate Nawrocki or unquoted paraphrase, and Tusk fragment rejected)"
        )
        let tribunalOnly = OverviewPerspectivesExtractor.extractPerspectives(
            passages: [pTribunal], articles: [artHindu], existingCitations: ["c_trib": cits["c_trib"]!])
        check(
            tribunalOnly.first?.position.hasSuffix("appointee of Mr. Nawrocki") == true,
            "Abbreviation 'Mr.' does not truncate statement at 'Mr'")

        // 7. Hyphenated compound place names match both regions
        let hyphenRegions = BriefingRegion.regions(in: "Russia-Ukraine ceasefire agreement signed")
        check(hyphenRegions.contains(.europe), "Hyphenated country names match regions")
        let meRegions = BriefingRegion.regions(in: "Israel-Iran tensions escalate")
        check(meRegions.contains(.middleEastNorthAfrica), "Middle East hyphenated names match")

        // 8. Canonical speaker equality and distinct institution preservation
        let justice = OverviewPerspectivesExtractor.canonicalParticipantTokens("Justice Department")
        let state = OverviewPerspectivesExtractor.canonicalParticipantTokens("State Department")
        check(
            OverviewPerspectivesExtractor.isSameCanonicalSpeaker(justice, state) == false,
            "Justice Department and State Department are distinct canonical speakers")
        let mrNawrocki = OverviewPerspectivesExtractor.canonicalParticipantTokens("Mr. Nawrocki")
        let nawrocki = OverviewPerspectivesExtractor.canonicalParticipantTokens("Nawrocki")
        check(
            OverviewPerspectivesExtractor.isSameCanonicalSpeaker(mrNawrocki, nawrocki) == true,
            "Mr. Nawrocki and Nawrocki collapse to same canonical speaker")

        // 9. Card date and relative update text
        let articleJustNow = FeedArticle(
            storedID: "art-now", title: "Breaking", link: "https://example.com/now",
            guid: "now", description: "Desc", pubDate: now.addingTimeInterval(-30), source: "Test")
        await MainActor.run {
            check(articleJustNow.cardDateText(now: now) == "Just now", "Under 60 seconds is Just now")
            let updateAbbr = FeedArticle.relativeUpdateText(
                for: now.addingTimeInterval(-120), now: now, abbreviated: true)
            check(!updateAbbr.isEmpty, "Abbreviated relative update text generates non-empty string")
            let updateFull = FeedArticle.relativeUpdateText(
                for: now.addingTimeInterval(-120), now: now, abbreviated: false)
            check(!updateFull.isEmpty, "Full relative update text generates non-empty string")
        }

        // 10. Footprint footer text variants
        check(
            BriefingFootprintModuleView.footerText(originalCount: 1, wireCopyCount: 0)
                == "1 original publisher report (no syndicated wire-agency reprints).",
            "Single original report without wire copy")
        check(
            BriefingFootprintModuleView.footerText(originalCount: 2, wireCopyCount: 0)
                == "All 2 original reports are independent publisher reporting (no syndicated wire-agency reprints).",
            "Multiple original reports without wire copy")
        check(
            BriefingFootprintModuleView.footerText(originalCount: 5, wireCopyCount: 1)
                == "5 original reports from independent newsrooms · 1 outlet republished a wire-agency dispatch.",
            "Footprint with 1 wire copy")
        check(
            BriefingFootprintModuleView.footerText(originalCount: 4, wireCopyCount: 3)
                == "4 original reports from independent newsrooms · 3 outlets republished wire-agency dispatches.",
            "Footprint with multiple wire copies")

        // 11. Priority impact text helper coverage
        check(BriefingPriorityData.impactText(.major) == "Major", "Major text")
        check(BriefingPriorityData.impactText(.notable) == "Notable", "Notable text")
        check(BriefingPriorityData.impactText(.minor) == "Minor", "Minor text")
        check(BriefingPriorityData.impactText(nil) == "Notable", "Default text is Notable")
    }

    @MainActor
    static func comprehensiveCoverageVerification() async {
        // 1. BriefingHeroCarouselView evaluation
        let sampleArticle = FeedArticle(
            storedID: "hero-1", title: "Global climate summit opens with new emissions accord",
            link: "https://example.com/hero-1", guid: "hero-1",
            description:
                "World leaders gathered for the annual climate plenary in Paris with full delegations present.",
            pubDate: now, source: "Publisher"
        )
        let sampleEntry = FeedEntry.article(sampleArticle)
        let heroCarousel = BriefingHeroCarouselView(
            entries: [sampleEntry], clock: ContinuousCarouselClock(), onOpen: { _ in }
        )
        _ = heroCarousel.body

        // 2. BriefingTensionSparklineView evaluation across reading counts
        let r1 = WorldTensionReading(
            evaluatedAt: now, inputHash: "h1", modelGeneration: "g1", headlines: [],
            assessment: WorldTensionAssessment(score: 45, summary: "Tension steady", reasons: [])
        )
        let r2 = WorldTensionReading(
            evaluatedAt: now.addingTimeInterval(86400), inputHash: "h2", modelGeneration: "g2", headlines: [],
            assessment: WorldTensionAssessment(score: 55, summary: "Tension rising", reasons: [])
        )
        let sparklineMulti = BriefingTensionSparklineView(readings: [r1, r2], baseline: 38)
        _ = sparklineMulti.body
        let sparklineSingle = BriefingTensionSparklineView(readings: [r1], baseline: 38)
        _ = sparklineSingle.body
        let sparklineEmpty = BriefingTensionSparklineView(readings: [], baseline: 38)
        _ = sparklineEmpty.body

        let tightDomain = BriefingTensionSparklineView.yDomain(for: [r1, r1], baseline: 45)
        check(tightDomain.count >= 8, "Tight span clamps to minimum padding")
        let singleDomain = BriefingTensionSparklineView.yDomain(for: [r1], baseline: 45)
        check(!singleDomain.isEmpty, "Single reading domain is valid range")

        // 3. BriefingTileView evaluation (lead and non-lead)
        let tileResting = BriefingTileView(
            article: sampleArticle, eventSummary: nil, citedFact: nil,
            state: BriefingTileState(isLead: false, isDeveloping: false),
            onOpen: {}, onToggleRead: {}, onToggleSave: {}
        )
        _ = tileResting.body
        let tileDeveloping = BriefingTileView(
            article: sampleArticle, eventSummary: nil, citedFact: nil,
            state: BriefingTileState(isLead: true, isDeveloping: true),
            onOpen: {}, onToggleRead: {}, onToggleSave: {}
        )
        _ = tileDeveloping.body
        check(
            BriefingTileView.restingWidth(isLead: true, contrast: .standard) == AppLayout.leadTileStroke,
            "Lead tile stroke is leadTileStroke")
        check(
            BriefingTileView.restingWidth(isLead: false, contrast: .increased) == AppLayout.hoverStroke,
            "Increased contrast non-lead resting stroke is hoverStroke")
        check(
            BriefingTileView.restingWidth(isLead: false, contrast: .standard) == AppLayout.hairline,
            "Standard contrast non-lead resting stroke is hairline")

        // 4. BriefingRegionsModuleView & BriefingRegionTilesModuleView evaluation
        if let regionsData = BriefingRegionsData.captureFixture {
            var actions = BriefingActions(
                onOpenArticle: { _ in }, onOpenEvent: { _ in }, onStartNewBriefing: {}, onBackToToday: {}
            )
            actions.onSelectRegion = { _ in }
            let modView = BriefingRegionsModuleView(data: regionsData, filter: BriefingBoardFilter(), actions: actions)
            _ = modView.body
            let modFiltered = BriefingRegionsModuleView(
                data: regionsData, filter: BriefingBoardFilter(region: .europe), actions: actions)
            _ = modFiltered.body
            let tilesView = BriefingRegionTilesModuleView(
                data: regionsData, filter: BriefingBoardFilter(), actions: actions)
            _ = tilesView.body
            let tilesFiltered = BriefingRegionTilesModuleView(
                data: regionsData, filter: BriefingBoardFilter(region: .europe), actions: actions)
            _ = tilesFiltered.body
        }

        // 5. BriefingPriorityModuleView evaluation
        if let priorityData = BriefingPriorityData.captureFixture {
            let actions = BriefingActions(
                onOpenArticle: { _ in }, onOpenEvent: { _ in }, onStartNewBriefing: {}, onBackToToday: {}
            )
            let priorityView = BriefingPriorityModuleView(
                data: priorityData, filter: BriefingBoardFilter(), actions: actions)
            _ = priorityView.body
            check(
                BriefingPriorityModuleView.strokeLineWidth(isLead: true, contrast: .standard)
                    == AppLayout.leadTileStroke,
                "Lead card stroke is leadTileStroke")
            check(
                BriefingPriorityModuleView.strokeLineWidth(isLead: false, contrast: .increased)
                    == AppLayout.hoverStroke,
                "Increased contrast non-lead card stroke is hoverStroke")
            check(
                BriefingPriorityModuleView.strokeLineWidth(isLead: false, contrast: .standard) == AppLayout.hairline,
                "Standard contrast non-lead card stroke is hairline")
        }

        // Test BriefingActions default closure bodies
        let defaultActions = BriefingActions(
            onOpenArticle: { _ in }, onOpenEvent: { _ in }, onStartNewBriefing: {}, onBackToToday: {}
        )
        defaultActions.onToggleRead(sampleArticle)
        defaultActions.onToggleSave(sampleArticle)

        // 6. BriefingFootprintModuleView evaluation
        let footprintData = BriefingFootprintData.make([
            ("Reuters", "Independent reporting by Reuters."),
            ("The Guardian", "Associated Press dispatch republished."),
            ("BBC News", "BBC original reporting."),
        ])
        let actions = BriefingActions(
            onOpenArticle: { _ in }, onOpenEvent: { _ in }, onStartNewBriefing: {}, onBackToToday: {}
        )
        let footprintView = BriefingFootprintModuleView(
            data: footprintData, filter: BriefingBoardFilter(), actions: actions)
        _ = footprintView.body

        // 7. CardDateText & CoverageRowLabel evaluation
        let cardDate = CardDateText(article: sampleArticle)
        _ = cardDate.body
        let coverageLabel1 = CoverageRowLabel(
            coverageText: "4 publishers", latestDate: now, hasUpdate: true,
            isExpanded: false, isGrid: false, now: now
        )
        _ = coverageLabel1.body
        let coverageLabel2 = CoverageRowLabel(
            coverageText: "4 publishers", latestDate: nil, hasUpdate: false,
            isExpanded: true, isGrid: true, now: now
        )
        _ = coverageLabel2.body

        // 8. EventOverviewReaderView evaluation
        let testOverview = EventOverviewDocument(
            eventID: "ev-test",
            version: OverviewVersionContext(membershipVersion: 1, inputTextHash: "input"),
            content: OverviewContent(
                title: "Headline statement",
                summary: "First summary sentence. Second summary sentence.",
                facts: [
                    OverviewFact(id: "f-1", text: "Important fact without period", citationIDs: ["cit-1"])
                ],
                citations: [
                    OverviewCitation(
                        id: "cit-1", articleID: sampleArticle.id, passageID: "pass-1",
                        passageFingerprint: "fg-1", quote: "A direct quote.",
                        source: OverviewSourceMetadata(
                            title: sampleArticle.title, name: sampleArticle.source, url: sampleArticle.link,
                            publishedAt: now
                        )
                    )
                ],
                evidenceSections: OverviewEvidenceSections(
                    perspectives: [
                        OverviewPerspective(
                            id: "p-1", participant: "Minister of Energy",
                            position: "Supply commitments will be met,", citationIDs: ["cit-1"],
                            sourcePublisher: "The Guardian", originalWireSource: "Reuters"
                        )
                    ]
                )
            ),
            provenance: OverviewProvenance(memberArticleIDs: [sampleArticle.id], kind: .synthesized)
        )
        let readerView = EventOverviewReaderView(
            overview: testOverview, memberArticles: [sampleArticle],
            onSelectArticle: { _ in }, onSelectCitation: { _, _ in }
        )
        _ = readerView.body

        // 9. All TensionMacroRegion briefingRegion and briefingTitle cases
        check(TensionMacroRegion.middleEastNorthAfrica.briefingRegion == .middleEastNorthAfrica, "MENA maps to MENA")
        check(TensionMacroRegion.subSaharanAfrica.briefingRegion == .middleEastNorthAfrica, "Africa maps to MENA")
        check(TensionMacroRegion.europe.briefingRegion == .europe, "Europe maps to Europe")
        check(TensionMacroRegion.northAmerica.briefingRegion == .northAmerica, "NA maps to NA")
        check(TensionMacroRegion.latinAmerica.briefingRegion == .latinAmerica, "LATAM maps to LATAM")
        check(TensionMacroRegion.southAsia.briefingRegion == .southAsia, "South Asia maps to APAC")
        check(TensionMacroRegion.eastSoutheastAsia.briefingRegion == .southAsia, "East Asia maps to APAC")
        check(TensionMacroRegion.oceania.briefingRegion == .southAsia, "Oceania maps to APAC")

        check(TensionMacroRegion.subSaharanAfrica.briefingTitle == "Middle East and Africa", "Africa title")
        check(TensionMacroRegion.eastSoutheastAsia.briefingTitle == "APAC", "East Asia title")
        check(TensionMacroRegion.oceania.briefingTitle == "APAC", "Oceania title")

        // 10. BriefingPriorityData momentum velocity branches
        let t0 = now
        let burstDates = [t0.addingTimeInterval(-1800), t0.addingTimeInterval(-3600)]
        check(BriefingPriorityData.momentum(dates: burstDates, now: t0) == .rising, "Burst with no prior is rising")
        let priorDates = (7...10).map { t0.addingTimeInterval(-Double($0) * 3600) }
        check(
            BriefingPriorityData.momentum(dates: burstDates + priorDates, now: t0) == .steady,
            "Burst with larger prior window is steady, not fading"
        )
        let fadingDates = [t0.addingTimeInterval(-4 * 3600)] + (7...9).map { t0.addingTimeInterval(-Double($0) * 3600) }
        check(
            BriefingPriorityData.momentum(dates: fadingDates, now: t0) == .fading,
            "No burst and recent < before is fading")

        // 11. BriefingPriorityData assessImportance without originalCount inflation
        let routineArticle = FeedArticle(
            storedID: "art-routine", title: "Routine bilateral trade talks open in Geneva",
            link: "https://example.com/routine", guid: "routine",
            description:
                "Delegates began the second round of bilateral consultations on Thursday with plenary sessions.",
            pubDate: now, source: "Publisher"
        )
        check(
            BriefingPriorityData.assessImportance(
                publisherCount: 8, originalCount: nil, representative: routineArticle) == .notable,
            "Missing originalCount with 8 publishers yields Notable (score 3), not Major"
        )
        check(
            BriefingPriorityData.assessImportance(
                publisherCount: 8, originalCount: 5, representative: routineArticle) == .major,
            "Confirmed 5 original reports with 8 publishers yields Major (score 4)"
        )

        // 12. Hyphenated compound place names with multi-word components
        let nyFlights = BriefingRegion.regions(in: "New York-London flights resume after snow clearing")
        check(nyFlights.contains(.northAmerica), "New York before hyphen is North America")
        check(nyFlights.contains(.europe), "London after hyphen is Europe")

        let londonNy = BriefingRegion.regions(in: "London-New York flights resume")
        check(londonNy.contains(.europe), "London before hyphen is Europe")
        check(londonNy.contains(.northAmerica), "New York after hyphen is North America")

        // 13. OverviewComposer.ensureTerminalPeriod all punctuation branches
        check(OverviewComposer.ensureTerminalPeriod("") == "", "Empty string unchanged")
        check(
            OverviewComposer.ensureTerminalPeriod("Ended with comma,") == "Ended with comma.",
            "Trailing comma to period")
        check(
            OverviewComposer.ensureTerminalPeriod("Ended with semicolon;") == "Ended with semicolon.",
            "Trailing semicolon to period")
        check(
            OverviewComposer.ensureTerminalPeriod("Ended with colon:") == "Ended with colon.",
            "Trailing colon to period")
        check(OverviewComposer.ensureTerminalPeriod("Question?") == "Question?", "Question mark preserved")
        check(OverviewComposer.ensureTerminalPeriod("Exclamation!") == "Exclamation!", "Exclamation mark preserved")
        check(
            OverviewComposer.ensureTerminalPeriod("\"Quoted sentence.\"") == "\"Quoted sentence.\"",
            "Quoted terminal preserved")
        check(
            OverviewComposer.ensureTerminalPeriod("\"Quoted sentence,\"") == "\"Quoted sentence\".",
            "Quoted comma converted to period")
        check(
            OverviewComposer.ensureTerminalPeriod("\"Quoted sentence\"") == "\"Quoted sentence\".",
            "Unpunctuated quote gets terminal")

        // 14. EventOverviewReaderView display deduplication & cleanDisplayPosition
        check(
            EventOverviewReaderView.cleanDisplayPosition("Text with comma,") == "Text with comma",
            "Trailing comma stripped")
        check(
            EventOverviewReaderView.cleanDisplayPosition("Text with colon:") == "Text with colon",
            "Trailing colon stripped")
        check(
            EventOverviewReaderView.cleanDisplayPosition("Text with semicolon;") == "Text with semicolon",
            "Trailing semicolon stripped")

        let dupPerspectives = [
            OverviewPerspective(
                id: "1", participant: "Mr. Nawrocki", position: "First valid statement.", citationIDs: ["c1"]),
            OverviewPerspective(
                id: "2", participant: "Nawrocki", position: "Second valid statement.", citationIDs: ["c1"]),
            OverviewPerspective(
                id: "3", participant: "Speaker", position: "And everything is clear,", citationIDs: ["c1"]),
            OverviewPerspective(
                id: "4", participant: "Haley", position: "what few people were willing to say,\" Trump said",
                citationIDs: ["c1"]),
            OverviewPerspective(
                id: "5", participant: "Justice Department", position: "Indictment unsealed.", citationIDs: ["c1"]),
            OverviewPerspective(
                id: "6", participant: "State Department", position: "Sanctions announced.", citationIDs: ["c1"]),
        ]
        let deduped = EventOverviewReaderView.deduplicateDisplayPerspectives(dupPerspectives)
        check(deduped.contains { $0.participant == "Mr. Nawrocki" }, "Mr. Nawrocki kept")
        check(!deduped.contains { $0.participant == "Nawrocki" }, "Duplicate Nawrocki dropped")
        check(!deduped.contains { $0.position.contains("And everything is clear") }, "Conversational fragment dropped")
        check(!deduped.contains { $0.participant == "Haley" }, "Leaked quotation tail dropped")
        check(deduped.contains { $0.participant == "Justice Department" }, "Justice Department kept")
        check(deduped.contains { $0.participant == "State Department" }, "State Department kept")

        // 15. BriefingDriversData.Row.regionsText
        let driversRow = BriefingDriversData.Row(
            type: .armedConflict, severity: 1.0, publishers: 4, publisherRegions: [.europe, .middleEastNorthAfrica]
        )
        check(
            driversRow.regionsText == "Publishers in Middle East and Africa, Europe", "Drivers regions text formatted")
        let emptyDriversRow = BriefingDriversData.Row(
            type: .armedConflict, severity: 1.0, publishers: 4, publisherRegions: []
        )
        check(emptyDriversRow.regionsText == nil, "Empty drivers regions text is nil")
    }
}
