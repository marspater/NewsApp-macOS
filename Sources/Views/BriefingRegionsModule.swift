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
        regionsByEntry[entry.id] ?? BriefingRegion.regions(of: entry.representative)
    }

    /// Groups the entries by region; nil when no entry names a region.
    static func make(
        entries: [FeedEntry], regionsByEntry: [String: Set<TensionMacroRegion>],
        facts: [String: BriefingCitedFact], now: Date
    ) -> Self? {
        var grouped: [TensionMacroRegion: [FeedEntry]] = [:]
        for entry in entries {
            for region in regionsByEntry[entry.id] ?? [] { grouped[region, default: []].append(entry) }
        }
        let rows = TensionMacroRegion.allCases.compactMap { region -> Row? in
            guard let stories = grouped[region] else { return nil }
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
        return Self(rows: rows, regionsByEntry: regionsByEntry, facts: facts, now: now)
    }

    /// nil hides the module.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        let features =
            (try? await store.database.fetchArticleFeatures(
                articleIDs: context.entries.flatMap { $0.visibleArticles.map(\.id) },
                version: EventFeatures.storageVersion)) ?? [:]
        var map: [String: Set<TensionMacroRegion>] = [:]
        for entry in context.entries {
            let codes = entry.visibleArticles.flatMap { features[$0.id]?.countries ?? [] }
            let regions = Set(codes.compactMap { BriefingRegion.region(code: String($0.dropFirst())) })
            map[entry.id] = regions.isEmpty ? BriefingRegion.regions(of: entry.representative) : regions
        }
        guard let grouped = make(entries: context.entries, regionsByEntry: map, facts: [:], now: context.now) else {
            return nil
        }
        var facts: [String: BriefingCitedFact] = [:]
        for row in grouped.rows {
            for entry in row.entries.prefix(Metrics.tilesPerRegion) where facts[entry.id] == nil {
                facts[entry.id] = await BriefingFactExtractor.extractFact(for: entry, store: store)
            }
        }
        return Self(rows: grouped.rows, regionsByEntry: map, facts: facts, now: context.now)
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
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
                title: "Protest bans extended in two capitals", publishers: 5, hoursAgo: 3,
                fact: "The ban now runs until the end of the month.",
                region: .europe),
            SampleStory(
                title: "Containment perimeter widens in Uganda", publishers: 2, hoursAgo: 4,
                fact: "Cases were confirmed in two more districts.",
                region: .subSaharanAfrica),
            SampleStory(
                title: "Export rules on critical minerals tighten in China", publishers: 2, hoursAgo: 5,
                fact: "Licences are now required for exports.",
                region: .eastSoutheastAsia),
            SampleStory(
                title: "Cyber incident at a regional utility in Canada", publishers: 1, hoursAgo: 6,
                fact: "Billing systems were taken offline.",
                region: .northAmerica),
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
    /// The region's name on the board.
    var briefingTitle: String {
        switch self {
        case .middleEastNorthAfrica: return "Middle East & North Africa"
        case .europe: return "Europe"
        case .subSaharanAfrica: return "Sub-Saharan Africa"
        case .southAsia: return "South Asia"
        case .eastSoutheastAsia: return "East & Southeast Asia"
        case .northAmerica: return "North America"
        case .latinAmerica: return "Latin America"
        case .oceania: return "Oceania"
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
    static let regionsWithoutSelection = 3
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
