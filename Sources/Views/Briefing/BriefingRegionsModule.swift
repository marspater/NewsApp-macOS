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

/// Regions: story count per region, selecting one filters the board (#850). The region tiles share this data.
struct BriefingRegionsData: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let region: TensionMacroRegion
        /// The region's stories, most publishers first (edition order breaks ties).
        let entries: [FeedEntry]
        var id: TensionMacroRegion { region }

        /// ponytail: the level is read from the story count alone (one band per 16 points), so the row says
        /// "stories"; use the tension reading's per-region classification once it records regions.
        var level: TensionLevel { TensionLevel(index: Double(entries.count * 16)) }
        var countText: String { "\(level.rawValue) · \(entries.count) \(entries.count == 1 ? "story" : "stories")" }
    }

    /// Regions with at least one story, most stories first.
    let rows: [Row]
    /// Every edition entry's regions, resolved once at load.
    let regionsByEntry: [String: Set<TensionMacroRegion>]
    /// Cited facts for the tiles, by entry ID.
    let facts: [String: BriefingCitedFact]
    let now: Date

    /// The entry's regions: its reports' countries when known, else the countries its headline names.
    func regions(of entry: FeedEntry) -> Set<TensionMacroRegion> {
        let raw = regionsByEntry[entry.id] ?? BriefingRegion.regions(of: entry.representative)
        return Set(raw.map(\.briefingRegion))
    }

    /// Resolves an entry's Briefing regions by prioritizing headline country/region mentions over description mentions,
    /// so secondary mentions in body text (e.g. "A US-brokered ceasefire in Ukraine...") never misclassify a story.
    static func resolveRegions(
        for entry: FeedEntry, features: [String: EventFeatures]
    ) -> Set<TensionMacroRegion> {
        let titleCodes = (features[entry.representative.id]?.titlePlaces ?? []).filter { $0.hasPrefix("@") }
        let repHeadline = BriefingRegion.headlineRegions(of: entry.representative).union(
            titleCodes.compactMap { BriefingRegion.region(code: String($0.dropFirst())) })
        if !repHeadline.isEmpty {
            return Set(repHeadline.map(\.briefingRegion))
        }
        var memberHeadline = Set<TensionMacroRegion>()
        for article in entry.visibleArticles {
            let codes = (features[article.id]?.titlePlaces ?? []).filter { $0.hasPrefix("@") }
            memberHeadline.formUnion(BriefingRegion.headlineRegions(of: article))
            memberHeadline.formUnion(codes.compactMap { BriefingRegion.region(code: String($0.dropFirst())) })
        }
        if !memberHeadline.isEmpty {
            return Set(memberHeadline.map(\.briefingRegion))
        }
        let descRegions = BriefingRegion.regions(of: entry.representative)
        if !descRegions.isEmpty {
            return Set(descRegions.map(\.briefingRegion))
        }
        let bodyCodes = (features[entry.representative.id]?.countries ?? [])
        let bodyRegions = Set(bodyCodes.compactMap { BriefingRegion.region(code: String($0.dropFirst())) })
        return Set(bodyRegions.map(\.briefingRegion))
    }

    /// Groups the entries by region; nil when no entry names a region.
    static func make(
        entries: [FeedEntry], regionsByEntry: [String: Set<TensionMacroRegion>],
        facts: [String: BriefingCitedFact], now: Date
    ) -> Self? {
        var normalizedMap: [String: Set<TensionMacroRegion>] = [:]
        for (id, set) in regionsByEntry {
            normalizedMap[id] = Set(set.map(\.briefingRegion))
        }
        var grouped: [TensionMacroRegion: [FeedEntry]] = [:]
        var seenInRegion: [TensionMacroRegion: Set<String>] = [:]
        for entry in entries {
            for region in normalizedMap[entry.id] ?? []
            where seenInRegion[region, default: []].insert(entry.id).inserted {
                grouped[region, default: []].append(entry)
            }
        }
        let rows = TensionMacroRegion.briefingRegions.compactMap { region -> Row? in
            guard let stories = grouped[region], !stories.isEmpty else { return nil }
            let ordered = stories.enumerated().sorted {
                $0.element.publisherCount != $1.element.publisherCount
                    ? $0.element.publisherCount > $1.element.publisherCount : $0.offset < $1.offset
            }
            return Row(region: region, entries: ordered.map(\.element))
        }
        .enumerated().sorted {
            $0.element.entries.count != $1.element.entries.count
                ? $0.element.entries.count > $1.element.entries.count : $0.offset < $1.offset
        }
        .map(\.element)
        guard !rows.isEmpty else { return nil }
        return Self(rows: rows, regionsByEntry: normalizedMap, facts: facts, now: now)
    }

    /// nil hides the module. Supplements the finite briefing edition with recent library stories so active regions
    /// are well-populated rather than showing a single isolated article.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        var candidateEntries = context.entries
        var seenEntryIDs = Set(context.entries.map(\.id))
        var seenArticleIDs = Set(context.entries.flatMap { $0.visibleArticles.map(\.id) })
        let window = context.now.addingTimeInterval(-72 * 3600)...context.now
        let unreadPool =
            (try? await store.database.fetchArticles(
                isRead: false, limit: 250, options: ArticleFetchOptions(publicationWindow: window, muting: store.muting)
            )) ?? []
        let fallbackPool: [FeedArticle]
        if unreadPool.count < 60 {
            fallbackPool =
                (try? await store.database.fetchArticles(
                    limit: 250, options: ArticleFetchOptions(publicationWindow: window, muting: store.muting))) ?? []
        } else {
            fallbackPool = []
        }
        var extraArticles: [FeedArticle] = []
        for article in unreadPool + fallbackPool where seenArticleIDs.insert(article.id).inserted {
            extraArticles.append(article)
        }
        if !extraArticles.isEmpty {
            let extraEvents = (try? await store.eventFeedSummaries(for: extraArticles.map(\.id))) ?? []
            let extraSnapshot = FeedSnapshot(articles: extraArticles, events: extraEvents)
            for entry in extraSnapshot.entries(.events) where seenEntryIDs.insert(entry.id).inserted {
                candidateEntries.append(entry)
            }
        }

        let features =
            (try? await store.database.fetchArticleFeatures(
                articleIDs: candidateEntries.flatMap { $0.visibleArticles.map(\.id) },
                version: EventFeatures.storageVersion)) ?? [:]
        var map: [String: Set<TensionMacroRegion>] = [:]
        let editionIDs = Set(context.entries.map(\.id))
        var regionCounts: [TensionMacroRegion: Int] = [:]
        var selectedEntries: [FeedEntry] = []

        for entry in candidateEntries {
            let resolved = resolveRegions(for: entry, features: features)
            guard !resolved.isEmpty else { continue }
            let isEditionEntry = editionIDs.contains(entry.id)
            let needsSupplement = resolved.contains { (regionCounts[$0] ?? 0) < Metrics.maxSupplementalPerRegion }
            guard isEditionEntry || needsSupplement else { continue }
            let filteredRegions =
                isEditionEntry
                ? resolved
                : Set(resolved.filter { (regionCounts[$0] ?? 0) < Metrics.maxSupplementalPerRegion })
            guard !filteredRegions.isEmpty else { continue }
            map[entry.id] = filteredRegions
            selectedEntries.append(entry)
            for region in filteredRegions {
                regionCounts[region, default: 0] += 1
            }
        }
        guard let grouped = make(entries: selectedEntries, regionsByEntry: map, facts: [:], now: context.now) else {
            return nil
        }
        var facts: [String: BriefingCitedFact] = [:]
        for row in grouped.rows {
            for entry in row.entries.prefix(Metrics.tilesPerRegion) where facts[entry.id] == nil {
                facts[entry.id] = await BriefingFactExtractor.extractFact(for: entry, store: store)
            }
        }
        return Self(rows: grouped.rows, regionsByEntry: grouped.regionsByEntry, facts: facts, now: context.now)
    }

    /// Sample data for `Tests/Harness/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        let stories: [SampleStory] = [
            SampleStory(
                title: "Shipping corridor security tightens off Yemen", publishers: 11, hoursAgo: 0.2,
                fact: "All inbound vessels are now escorted.",
                region: .middleEastNorthAfrica),
            SampleStory(
                title: "Drones intercepted near an oil terminal in Saudi Arabia", publishers: 4, hoursAgo: 0.6,
                fact: "Air defences engaged two drones overnight.",
                region: .middleEastNorthAfrica),
            SampleStory(
                title: "Ceasefire talks resume in Cairo", publishers: 3, hoursAgo: 2,
                fact: "Delegations met for four hours on Thursday.",
                region: .middleEastNorthAfrica),
            SampleStory(
                title: "Protest bans extended in two European capitals", publishers: 5, hoursAgo: 3,
                fact: "The ban now runs until the end of the month.",
                region: .europe),
            SampleStory(
                title: "Grid operators reinforce Baltic power links in Poland", publishers: 4, hoursAgo: 3.5,
                fact: "Reserve capacity was activated across three interconnectors.",
                region: .europe),
            SampleStory(
                title: "Rail freight talks resume in Berlin", publishers: 3, hoursAgo: 4,
                fact: "Operators agreed to a 48-hour cooling-off period.",
                region: .europe),
            SampleStory(
                title: "Export rules on critical minerals tighten in China", publishers: 5, hoursAgo: 4.5,
                fact: "Licences are now required for exports.",
                region: .southAsia),
            SampleStory(
                title: "Semiconductor investment package clears parliament in Japan", publishers: 4, hoursAgo: 5,
                fact: "Subsidies target domestic foundry capacity.",
                region: .southAsia),
            SampleStory(
                title: "Reserve Bank holds benchmark rate steady in Australia", publishers: 3, hoursAgo: 5.5,
                fact: "Policymakers cited easing goods inflation.",
                region: .southAsia),
            SampleStory(
                title: "Cross-border grid reliability compact signed in Ottawa", publishers: 4, hoursAgo: 6,
                fact: "Utilities in the US and Canada will share reserve margins.",
                region: .northAmerica),
            SampleStory(
                title: "Port automation agreement reached on US East Coast", publishers: 3, hoursAgo: 6.5,
                fact: "Cargo terminals remained open across six ports.",
                region: .northAmerica),
            SampleStory(
                title: "Central bank announces inflation target review in Brazil", publishers: 3, hoursAgo: 7,
                fact: "Policy bands remain unchanged through year-end.",
                region: .latinAmerica),
            SampleStory(
                title: "Nearshoring rail corridor expands in Mexico", publishers: 2, hoursAgo: 7.5,
                fact: "Freight capacity rose 14% along the northern border.",
                region: .latinAmerica),
        ]
        var entries: [FeedEntry] = []
        var map: [String: Set<TensionMacroRegion>] = [:]
        var facts: [String: BriefingCitedFact] = [:]
        for (index, story) in stories.enumerated() {
            let entry = sampleEntry(
                id: "region-\(index)", title: story.title, publishers: story.publishers,
                date: now.addingTimeInterval(-story.hoursAgo * 3600))
            entries.append(entry)
            map[entry.id] = [story.region]
            facts[entry.id] = BriefingCitedFact(
                text: story.fact, isCited: true, citationPublisher: "Publisher \(index + 1)")
        }
        return make(entries: entries, regionsByEntry: map, facts: facts, now: now)
    }

    /// A placeholder story for capture fixtures: an event when more than one publisher reports it.
    static func sampleEntry(id: String, title: String, publishers: Int, date: Date) -> FeedEntry {
        let article = FeedArticle(
            storedID: id, title: title, link: "https://example.com/\(id)", guid: id,
            description: "\(title). Reporting continues.", pubDate: date, source: "Publisher 1", imageUrl: nil,
            category: "World")
        guard publishers > 1 else { return .article(article) }
        let members = (0..<publishers).map { member in
            EventFeedMember(
                articleID: member == 0 ? id : "\(id)-\(member)", source: "Publisher \(member + 1)", title: title,
                date: date, joinedVersion: 1, isRead: false, isSaved: false)
        }
        return .event(
            EventFeedSummary(eventID: "event-\(id)", membershipVersion: 1, seenVersion: nil, members: members),
            representative: article, visibleMembers: [article])
    }
}

extension TensionMacroRegion {
    /// Canonical five-region taxonomy displayed on the Briefing board:
    /// Europe, North America (US & Canada), APAC, Middle East and Africa, and LATAM.
    static let briefingRegions: [TensionMacroRegion] = [
        .middleEastNorthAfrica, .europe, .northAmerica, .latinAmerica, .southAsia,
    ]

    /// Maps any legacy eight-region value onto the five canonical Briefing regions.
    var briefingRegion: TensionMacroRegion {
        switch self {
        case .middleEastNorthAfrica, .subSaharanAfrica:
            return .middleEastNorthAfrica
        case .europe:
            return .europe
        case .northAmerica:
            return .northAmerica
        case .latinAmerica:
            return .latinAmerica
        case .southAsia, .eastSoutheastAsia, .oceania:
            return .southAsia
        }
    }

    /// The region's name on the board.
    var briefingTitle: String {
        switch briefingRegion {
        case .middleEastNorthAfrica: return "Middle East and Africa"
        case .europe: return "Europe"
        case .southAsia: return "APAC"
        case .northAmerica: return "North America"
        case .latinAmerica: return "LATAM"
        default: return "World"
        }
    }
}

/// One capture fixture story.
private struct SampleStory {
    let title: String
    let publishers: Int
    let hoursAgo: Double
    let fact: String
    let region: TensionMacroRegion
}

private enum Metrics {
    static let levelDot: CGFloat = 8
    static let tilesPerRegion = 3
    static let regionsWithoutSelection = 5
    static let maxSupplementalPerRegion = 6
}

struct BriefingRegionsModuleView: View {
    let data: BriefingRegionsData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View {
        BriefingModuleCard(title: "Regions", caption: "select one to filter the board") {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                ForEach(data.rows) { row in
                    rowButton(row)
                }
            }
        }
    }

    private func rowButton(_ row: BriefingRegionsData.Row) -> some View {
        let isSelected = filter.region == row.region
        return Button {
            actions.onSelectRegion(isSelected ? nil : row.region)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Circle()
                    .fill(AppColor.tension(row.level))
                    .frame(width: Metrics.levelDot, height: Metrics.levelDot)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    Text(row.region.briefingTitle)
                        .font(AppTypography.callout.weight(.semibold))
                        .foregroundStyle(AppColor.primaryText)
                    if let top = row.entries.first {
                        Text(top.representative.title)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: AppSpacing.xs)
                Text(row.countText)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, AppSpacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AppColor.badgeBackground : AppColor.surface,
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.region.briefingTitle), \(row.countText)")
        .accessibilityHint(isSelected ? "Shows every region" : "Filters the board to this region")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The region tiles under the selected region's name, or under each of the busiest regions when none is selected.
struct BriefingRegionTilesModuleView: View {
    let data: BriefingRegionsData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    private var shownRows: [BriefingRegionsData.Row] {
        if let region = filter.region { return data.rows.filter { $0.region == region } }
        return Array(data.rows.prefix(Metrics.regionsWithoutSelection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ForEach(shownRows) { row in
                BriefingModuleCard(title: row.region.briefingTitle, caption: row.countText) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: AppLayout.gridColumnMinimum), spacing: AppSpacing.sm)],
                        alignment: .leading, spacing: AppSpacing.sm
                    ) {
                        ForEach(Array(row.entries.prefix(Metrics.tilesPerRegion).enumerated()), id: \.element.id) {
                            index, entry in
                            tile(entry, isLead: index == 0)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ entry: FeedEntry, isLead: Bool) -> some View {
        var summary: EventFeedSummary?
        if case .event(let event, _, _) = entry { summary = event }
        return BriefingTileView(
            article: entry.representative, eventSummary: summary, citedFact: data.facts[entry.id],
            state: BriefingTileState(isLead: isLead, isDeveloping: BriefingView.isDeveloping(entry, now: data.now)),
            onOpen: { actions.open(entry) },
            onToggleRead: { actions.onToggleRead(entry.representative) },
            onToggleSave: { actions.onToggleSave(entry.representative) })
    }
}
