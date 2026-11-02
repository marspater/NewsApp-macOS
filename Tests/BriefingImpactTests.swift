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
        dynamicIndicatorsAndOverviewQuality()
        print("Finished \(checks) Briefing strategic impact checks with \(failures) failures.")
        if failures > 0 { exit(1) }
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

    static func dynamicIndicatorsAndOverviewQuality() {
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
        Task { @MainActor in
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
}
