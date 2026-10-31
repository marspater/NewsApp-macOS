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

/// What drives World Tension: the event types today's stories report, severity beside coverage (#850).
struct BriefingDriversData: Equatable, Sendable {
    /// One story whose cited highlights the World Tension classifier gave a type.
    struct Event: Equatable, Sendable {
        let entry: FeedEntry
        let type: TensionEventType
        /// Regions of the reporting publishers in the catalog; publishers without one are left out.
        var publisherRegions: Set<TensionMacroRegion> = []
    }

    /// One type under the current filter. Severity and coverage stay separate values (DESIGN.md 8.4).
    struct Row: Equatable, Sendable, Identifiable {
        let type: TensionEventType
        /// The type's calibrated weight relative to the heaviest type, 0...1.
        let severity: Double
        /// Distinct publishers across the type's stories.
        let publishers: Int
        /// Where the type's publishers are based, shown apart from severity and coverage.
        var publisherRegions: Set<TensionMacroRegion> = []
        var id: TensionEventType { type }

        /// "Publishers in Europe, North America", in the regions' canonical order; nil when none is known.
        var regionsText: String? {
            let names = TensionMacroRegion.allCases.filter(publisherRegions.contains).map(\.briefingTitle)
            return names.isEmpty ? nil : "Publishers in " + names.joined(separator: ", ")
        }
        var coverageText: String { BriefingDriversData.coverageText(publishers: publishers) }
    }

    let events: [Event]

    static func coverageText(publishers: Int) -> String {
        switch publishers {
        case 5...: return "well covered"
        case 2...: return "thin coverage"
        default: return "one report"
        }
    }

    static func title(_ type: TensionEventType) -> String {
        switch type {
        case .armedConflict: return "Armed conflict"
        case .terrorism: return "Terrorism"
        case .civilUnrest: return "Civil unrest"
        case .coercion: return "Military or economic pressure"
        case .disaster: return "Disaster"
        case .healthEmergency: return "Health emergency"
        case .cyberAttack: return "Cyberattack"
        }
    }

    func hasRows(under filter: BriefingBoardFilter) -> Bool { !rows(for: filter).isEmpty }

    /// Types with a story inside the filter, most severe first.
    func rows(for filter: BriefingBoardFilter) -> [Row] {
        let weights = TensionWeights.calibratedV1.typeWeights
        let heaviest = weights.values.max() ?? 1
        let visible = events.filter { filter.includes($0.entry) }
        return TensionEventType.allCases.compactMap { type -> Row? in
            let stories = visible.filter { $0.type == type }
            guard !stories.isEmpty else { return nil }
            let publishers = Set(stories.flatMap { Self.publishers(of: $0.entry) }).count
            return Row(
                type: type, severity: (weights[type] ?? 0) / heaviest, publishers: publishers,
                publisherRegions: stories.reduce(into: []) { $0.formUnion($1.publisherRegions) })
        }
        .sorted { $0.severity > $1.severity }
    }

    static func publishers(of entry: FeedEntry) -> [String] {
        if case .event(let summary, _, _) = entry { return summary.sources }
        return [entry.representative.source]
    }

    /// The catalog regions of the entry's publishers; a publisher missing from the catalog or listed as global adds
    /// nothing.
    static func publisherRegions(of entry: FeedEntry) -> Set<TensionMacroRegion> {
        Set(
            publishers(of: entry).compactMap { publisher in
                FeedCatalog.allFeeds.first { $0.publisher == publisher }.flatMap {
                    BriefingRegion.region(code: $0.region)
                }
            })
    }

    /// Classifies each overview's highlights by the publisher quotes they cite; nil when nothing has a type.
    static func make(_ overviews: [(FeedEntry, EventOverviewDocument)]) -> Self? {
        let events = overviews.compactMap { entry, overview -> Event? in
            let facts = overview.facts.flatMap { fact in
                fact.citationIDs.compactMap { id -> PassageAnchoredFact? in
                    guard let citation = overview.citations[id] else { return nil }
                    return PassageAnchoredFact(
                        id: "\(fact.id):\(id)", statement: fact.text, passageID: citation.passageID,
                        quote: citation.quote, articleID: citation.articleID)
                }
            }
            guard let type = TensionEventClassifier.classify(facts, methodology: .v1).type else { return nil }
            return Event(entry: entry, type: type, publisherRegions: publisherRegions(of: entry))
        }
        return events.isEmpty ? nil : Self(events: events)
    }

    /// nil hides the module.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        make(await BriefingOverviews.load(context.entries, store: store))
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        let samples: [SampleDriver] = [
            SampleDriver(
                title: "Drones intercepted near an oil terminal in Saudi Arabia", publishers: 6, type: .armedConflict,
                regions: [.middleEastNorthAfrica, .europe]),
            SampleDriver(
                title: "Protest bans extended in two capitals", publishers: 5, type: .civilUnrest,
                regions: [.europe]),
            SampleDriver(
                title: "Containment perimeter widens in Uganda", publishers: 3, type: .healthEmergency,
                regions: [.subSaharanAfrica]),
            SampleDriver(
                title: "Cyber incident at a regional utility in Canada", publishers: 1, type: .cyberAttack,
                regions: []),
        ]
        return Self(
            events: samples.enumerated().map { index, sample in
                Event(
                    entry: BriefingRegionsData.sampleEntry(
                        id: "driver-\(index)", title: sample.title, publishers: sample.publishers, date: now),
                    type: sample.type, publisherRegions: sample.regions)
            })
    }
}

/// One capture fixture story.
private struct SampleDriver {
    let title: String
    let publishers: Int
    let type: TensionEventType
    let regions: Set<TensionMacroRegion>
}

private enum Metrics {
    static let barHeight: CGFloat = 6
    static let labelWidth: CGFloat = 200
    static let coverageWidth: CGFloat = 96
}

struct BriefingDriversModuleView: View {
    let data: BriefingDriversData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View {
        let rows = data.rows(for: filter)
        if !rows.isEmpty { card(rows) }
    }

    private func card(_ rows: [BriefingDriversData.Row]) -> some View {
        BriefingModuleCard(title: "What drives World Tension", caption: "severity and coverage shown apart") {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                IntelligenceLabel("Assessed on this Mac").font(AppTypography.caption)
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                        bar(row)
                        if let regions = row.regionsText {
                            Text(regions)
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private func bar(_ row: BriefingDriversData.Row) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Text(BriefingDriversData.title(row.type))
                .font(AppTypography.callout)
                .foregroundStyle(AppColor.primaryText)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.badgeBackground)
                    Capsule().fill(AppColor.secondaryText)
                        .frame(width: proxy.size.width * row.severity)
                }
            }
            .frame(height: Metrics.barHeight)
            Text(row.coverageText)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                .frame(width: Metrics.coverageWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(BriefingDriversData.title(row.type)), severity \(Int((row.severity * 10).rounded())) of 10, "
                + row.coverageText)
    }
}
