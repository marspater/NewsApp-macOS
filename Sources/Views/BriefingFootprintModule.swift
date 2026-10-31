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

/// Source footprint: where the lead thread's publishers come from and how many carry wire copy (#849).
struct BriefingFootprintData: Equatable, Sendable {
    struct Group: Equatable, Sendable, Identifiable {
        var id: String { label }
        let label: String
        let count: Int
    }

    let groups: [Group]
    let publisherCount: Int
    let originalCount: Int
    let wireCopyCount: Int

    static let wireAgencies = "Wire agencies"

    /// Groups distinct publishers: wire agencies, then catalog regions ("global" is International, a country goes by
    /// its continent), and Other for publishers outside the catalog. Largest group first.
    static func make(_ reports: [(publisher: String, text: String)]) -> Self {
        var texts: [String: [String]] = [:]
        for report in reports { texts[report.publisher, default: []].append(report.text) }
        var counts: [String: Int] = [:]
        for publisher in texts.keys { counts[group(of: publisher), default: 0] += 1 }
        let wireCopies = texts.filter { publisher, texts in
            texts.allSatisfy { BriefingPriorityData.isWireCopy(text: $0, publisher: publisher) }
        }.count
        return Self(
            groups: counts.map { Group(label: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.label) > ($1.count, $0.label) },
            publisherCount: texts.count, originalCount: texts.count - wireCopies, wireCopyCount: wireCopies)
    }

    static func group(of publisher: String) -> String {
        if OverviewPerspectivesExtractor.detectWireSource(in: "", articleSource: publisher) != nil {
            return wireAgencies
        }
        guard let region = FeedCatalog.allFeeds.first(where: { $0.publisher == publisher })?.region else {
            return "Other"
        }
        if region == "global" { return "International" }
        guard let continent = Locale.Region(region).continent,
            let name = Locale(identifier: "en").localizedString(forRegionCode: continent.identifier)
        else { return "Other" }
        return name
    }

    /// nil hides the module: the lead thread needs two publishers.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        guard let lead = BriefingThread.ranked(context.entries).first, lead.publisherCount > 1,
            let members = try? await store.eventMemberArticles(eventID: lead.summary.eventID)
        else { return nil }
        let data = make(members.map { ($0.publisherName, BriefingPriorityData.reportText($0)) })
        return data.publisherCount > 1 ? data : nil
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        Self(
            groups: [
                Group(label: "International", count: 4), Group(label: "Europe", count: 3),
                Group(label: wireAgencies, count: 2), Group(label: "Other", count: 2),
            ], publisherCount: 11, originalCount: 5, wireCopyCount: 6)
    }
}

struct BriefingFootprintModuleView: View {
    let data: BriefingFootprintData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    private var footer: String {
        let original = "\(data.originalCount) original report\(data.originalCount == 1 ? "" : "s")"
        switch data.wireCopyCount {
        case 0: return "\(original); none carry a wire agency's text."
        case 1: return "\(original); 1 carries a wire agency's text, so it counts once."
        default: return "\(original); \(data.wireCopyCount) carry a wire agency's text, so they count once."
        }
    }

    private enum Metrics {
        static let labelWidth: CGFloat = 130
        static let barHeight: CGFloat = 8
        static let countWidth: CGFloat = 28
    }

    var body: some View {
        BriefingModuleCard(title: "Source footprint", caption: "Lead story · \(data.publisherCount) publishers") {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(data.groups) { group in
                    HStack(spacing: AppSpacing.sm) {
                        Text(group.label)
                            .font(AppTypography.callout)
                            .foregroundStyle(AppColor.secondaryText)
                            .frame(width: Metrics.labelWidth, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(AppColor.badgeBackground)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(AppColor.secondaryText)
                                        .frame(
                                            width: proxy.size.width * CGFloat(group.count)
                                                / CGFloat(max(1, data.publisherCount)))
                                }
                        }
                        .frame(height: Metrics.barHeight)
                        Text("\(group.count)")
                            .font(AppTypography.callout.monospacedDigit())
                            .foregroundStyle(AppColor.primaryText)
                            .frame(width: Metrics.countWidth, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(group.label): \(group.count) of \(data.publisherCount) publishers")
                }
            }
            Text(footer)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}
