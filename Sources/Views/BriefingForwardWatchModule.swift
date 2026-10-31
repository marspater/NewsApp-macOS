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

/// Forward watch: scheduled, expected and conditional items stated in cited reporting, in the publisher's words
/// (#851). The app schedules nothing and never infers a date (DESIGN.md 8.4).
struct BriefingForwardWatchData: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let item: ForwardWatchItem
        /// Distinct publishers across the edition whose cited facts produced the same line.
        let publishers: [String]
        /// The cited passage's publisher page, when it has one.
        let sourceURL: URL?
        /// The story that carries the citation.
        let entry: FeedEntry?
        var id: String { ForwardWatchExtractor.key(item.text) }

        var caption: String {
            let many = publishers.count > 1
            let who = publishers.first ?? item.publisher ?? "one publisher"
            guard let date = item.dateText else {
                return many ? "As reported by \(publishers.count) publishers" : "Stated by \(who), cited once"
            }
            return many
                ? "\(date), as reported by \(publishers.count) publishers" : "\(date), stated by \(who), cited once"
        }
    }

    let rows: [Row]

    /// One extracted line with where it came from: the citation's link and the story it was found in.
    struct Candidate: Sendable {
        let item: ForwardWatchItem
        var url: URL? = nil
        var entry: FeedEntry? = nil
    }

    /// Merges per-story items: one row per line prefix, publishers collected across stories, scheduled first.
    static func make(_ found: [Candidate]) -> Self? {
        var order: [String] = []
        var first: [String: Candidate] = [:]
        var publishers: [String: [String]] = [:]
        for candidate in found {
            let key = ForwardWatchExtractor.key(candidate.item.text)
            if first[key] == nil {
                first[key] = candidate
                order.append(key)
            }
            if let publisher = candidate.item.publisher, !(publishers[key] ?? []).contains(publisher) {
                publishers[key, default: []].append(publisher)
            }
        }
        let items = ForwardWatchExtractor.sorted(order.compactMap { first[$0]?.item })
        let rows = items.prefix(ForwardWatchExtractor.maximumItems).compactMap { item -> Row? in
            let key = ForwardWatchExtractor.key(item.text)
            guard let candidate = first[key] else { return nil }
            return Row(item: item, publishers: publishers[key] ?? [], sourceURL: candidate.url, entry: candidate.entry)
        }
        return rows.isEmpty ? nil : Self(rows: Array(rows))
    }

    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        var found: [Candidate] = []
        for entry in context.entries {
            let overview: EventOverviewDocument?
            if case .event(let summary, _, _) = entry {
                overview = try? await store.fetchEventOverview(eventID: summary.eventID)
            } else {
                overview = try? await store.fetchEventOverview(forArticleID: entry.id)
            }
            guard let overview else { continue }
            let items = ForwardWatchExtractor.extract(
                facts: overview.facts, citations: overview.citations, publishedAt: entry.representative.pubDate)
            for item in items {
                let url = item.citationID.flatMap { overview.citations[$0]?.sourceURL }.flatMap(WebLink.url)
                found.append(Candidate(item: item, url: url, entry: entry))
            }
        }
        return make(found)
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        make([
            Candidate(
                item: ForwardWatchItem(
                    kind: .scheduled,
                    text: "The Security Council will meet on Tuesday to discuss the shipping corridor.",
                    dateText: "Tuesday", publisher: "Harbor Times", citationID: "c1")
            ),
            Candidate(
                item: ForwardWatchItem(
                    kind: .scheduled,
                    text: "The Security Council will meet on Tuesday to discuss the shipping corridor.",
                    dateText: "Tuesday", publisher: "Wire Service", citationID: "c2")
            ),
            Candidate(
                item: ForwardWatchItem(
                    kind: .expected, text: "Shipping insurers are expected to review war-risk rates later this week.",
                    dateText: "later this week", publisher: "Market Wire", citationID: "c3")
            ),
            Candidate(
                item: ForwardWatchItem(
                    kind: .conditional, text: "Port operators will close the terminal if attacks on vessels continue.",
                    dateText: nil, publisher: "Port Authority Bulletin", citationID: "c4")
            ),
        ])
    }
}

struct BriefingForwardWatchModuleView: View {
    let data: BriefingForwardWatchData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    private enum Metrics {
        static let kindColumn: CGFloat = 96
    }

    var body: some View {
        let rows = data.rows.filter { $0.entry.map(filter.includes) ?? true }
        BriefingModuleCard(title: "Forward watch", caption: "Stated in reporting") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    Button {
                        open(row)
                    } label: {
                        rowView(row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.item.kind.title): \(row.item.text) \(row.caption)")
                    .accessibilityHint(row.sourceURL == nil ? "Opens the story" : "Opens the publisher's page")
                }
            }
        }
    }

    private func open(_ row: BriefingForwardWatchData.Row) {
        if let url = row.sourceURL {
            actions.onOpenURL(url)
        } else if let entry = row.entry {
            actions.open(entry)
        }
    }

    private func rowView(_ row: BriefingForwardWatchData.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            TagView(title: row.item.kind.title)
                .frame(width: Metrics.kindColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text(row.item.text)
                    .font(AppTypography.headline)
                    .foregroundStyle(AppColor.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.caption)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.sm)
        .contentShape(Rectangle())
    }
}
