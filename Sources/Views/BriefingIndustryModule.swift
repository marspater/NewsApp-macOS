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

/// Industry impact: sectors cited passages name across the edition (#850).
struct BriefingIndustryData: Equatable, Sendable {
    /// One cited industry item from one story's overview.
    struct Mention: Equatable, Sendable {
        let entry: FeedEntry
        let implication: String
        let citationIDs: [String]
    }

    struct Sector: Equatable, Sendable {
        let industry: String
        /// In edition order.
        let mentions: [Mention]
    }

    /// What one card shows under the current filter.
    struct Card: Equatable, Sendable, Identifiable {
        let industry: String
        let implication: String
        let storyCount: Int
        let passageCount: Int
        var id: String { industry }

        var sourceText: String {
            "From \(storyCount) \(storyCount == 1 ? "story" : "stories") · \(passageCount) cited "
                + (passageCount == 1 ? "passage" : "passages")
        }
    }

    /// Sectors in order of first mention.
    let sectors: [Sector]

    /// Groups the cited items by sector; nil when no item cites a passage.
    static func make(_ overviews: [(FeedEntry, EventOverviewDocument)]) -> Self? {
        var order: [String] = []
        var grouped: [String: [Mention]] = [:]
        for (entry, overview) in overviews {
            // Only items whose every citation resolves in this overview are named by a cited passage.
            for item in overview.industryImpact
            where !item.citationIDs.isEmpty && item.citationIDs.allSatisfy({ overview.citations[$0] != nil }) {
                if grouped[item.industry] == nil { order.append(item.industry) }
                grouped[item.industry, default: []].append(
                    Mention(entry: entry, implication: item.implication, citationIDs: item.citationIDs))
            }
        }
        guard !order.isEmpty else { return nil }
        return Self(sectors: order.map { Sector(industry: $0, mentions: grouped[$0] ?? []) })
    }

    func hasRows(under filter: BriefingBoardFilter) -> Bool { !cards(for: filter).isEmpty }

    /// The cards for the filter: sectors with a story inside it, most stories first.
    func cards(for filter: BriefingBoardFilter) -> [Card] {
        sectors.enumerated().compactMap { index, sector -> (Int, Card)? in
            let mentions = sector.mentions.filter { filter.includes($0.entry) }
            guard let first = mentions.first else { return nil }
            return (
                index,
                Card(
                    industry: sector.industry, implication: first.implication,
                    storyCount: Set(mentions.map(\.entry.id)).count,
                    // Citation IDs are local to each overview, so a passage is its story plus its ID.
                    passageCount: Set(
                        mentions.flatMap { mention in mention.citationIDs.map { "\(mention.entry.id):\($0)" } }
                    )
                    .count)
            )
        }
        .sorted { $0.1.storyCount != $1.1.storyCount ? $0.1.storyCount > $1.1.storyCount : $0.0 < $1.0 }
        .map(\.1)
    }

    /// nil hides the module.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        make(await BriefingOverviews.load(context.entries, store: store))
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        let corridor = BriefingRegionsData.sampleEntry(
            id: "industry-0", title: "Shipping corridor security tightens off Yemen", publishers: 11, date: now)
        let clinics = BriefingRegionsData.sampleEntry(
            id: "industry-1", title: "Containment perimeter widens in Uganda", publishers: 2, date: now)
        let minerals = BriefingRegionsData.sampleEntry(
            id: "industry-2", title: "Export rules on critical minerals tighten in China", publishers: 2, date: now)
        return Self(sectors: [
            Sector(
                industry: "Transportation",
                mentions: [
                    Mention(
                        entry: corridor,
                        implication: "Ships rerouting around the corridor add days to Asia–Europe routes.",
                        citationIDs: ["c1", "c2", "c3"]),
                    Mention(entry: minerals, implication: "Freight bookings were delayed.", citationIDs: ["c4"]),
                ]),
            Sector(
                industry: "Energy",
                mentions: [
                    Mention(
                        entry: corridor, implication: "Tanker insurance premiums rose after the incidents.",
                        citationIDs: ["c5", "c6"])
                ]),
            Sector(
                industry: "Healthcare",
                mentions: [
                    Mention(
                        entry: clinics, implication: "Clinics in the region report test shortages.", citationIDs: ["c7"]
                    )
                ]),
            Sector(
                industry: "Manufacturing",
                mentions: [
                    Mention(
                        entry: minerals, implication: "Factories face licence checks on two critical minerals.",
                        citationIDs: ["c8"])
                ]),
        ])
    }
}

/// The edition's event overviews, fetched once per module load.
enum BriefingOverviews {
    @MainActor static func load(_ entries: [FeedEntry], store: ArticleStore) async -> [(
        FeedEntry, EventOverviewDocument
    )] {
        var overviews: [(FeedEntry, EventOverviewDocument)] = []
        for entry in entries {
            let overview: EventOverviewDocument?
            switch entry {
            case .event(let summary, _, _): overview = try? await store.fetchEventOverview(eventID: summary.eventID)
            case .article(let article): overview = try? await store.fetchEventOverview(forArticleID: article.id)
            }
            if let overview { overviews.append((entry, overview)) }
        }
        return overviews
    }
}

private enum Metrics {
    static let columns = 2
}

struct BriefingIndustryModuleView: View {
    let data: BriefingIndustryData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View {
        let cards = data.cards(for: filter)
        if !cards.isEmpty { card(cards) }
    }

    private func card(_ cards: [BriefingIndustryData.Card]) -> some View {
        BriefingModuleCard(title: "Industry impact", caption: "only sectors a cited passage names") {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                IntelligenceLabel("Assessed on this Mac").font(AppTypography.caption)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: AppSpacing.sm, alignment: .topLeading),
                        count: Metrics.columns),
                    alignment: .leading, spacing: AppSpacing.sm
                ) {
                    ForEach(cards) { card in
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(card.industry)
                                .font(AppTypography.callout.weight(.semibold))
                                .foregroundStyle(AppColor.primaryText)
                            Text(card.implication)
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(card.sourceText)
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
