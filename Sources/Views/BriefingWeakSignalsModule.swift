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

/// Weak signals: low-coverage stories that also carry a major rating, a link to a big thread, rising momentum or a
/// named industry impact (#851). Low coverage alone never qualifies.
struct BriefingWeakSignalsData: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let entry: FeedEntry
        let headline: String
        /// "2 publishers · 5 h".
        let caption: String
        let reasons: [String]
        var id: String { entry.id }
    }

    /// What the loader found about one low-coverage story.
    struct Evidence: Equatable, Sendable {
        var isMajor = false
        /// Headline of a related thread with big coverage in this edition.
        var linkedThread: String?
        var momentumRising = false
        var sector: String?
    }

    let rows: [Row]

    static let lowCoverageLimit = 2
    static let bigThreadPublishers = 5
    /// The view shows at most this many rows that pass the region filter; the data keeps every qualifying row.
    static let maximumRows = 5
    static let footer =
        "Low coverage alone never qualifies: a story needs a major rating, a link to a big thread, rising momentum, or a cited industry impact."

    /// The reason pills; empty means the story does not qualify.
    static func reasons(_ evidence: Evidence) -> [String] {
        var reasons: [String] = []
        if evidence.isMajor { reasons.append("Major rating") }
        if let thread = evidence.linkedThread { reasons.append("Linked to \(threadName(thread)) thread") }
        if evidence.momentumRising { reasons.append("Momentum rising") }
        if let sector = evidence.sector { reasons.append("Industry impact: \(sector)") }
        return reasons
    }

    /// More reports in the last six hours than in the six before.
    static func isMomentumRising(_ dates: [Date], now: Date) -> Bool {
        let window: TimeInterval = 6 * 3600
        let recent = dates.filter { $0 <= now && $0 > now - window }.count
        let before = dates.filter { $0 <= now - window && $0 > now - 2 * window }.count
        return recent > before
    }

    /// A thread headline trimmed to its first four words.
    static func threadName(_ headline: String) -> String {
        let words = headline.split(whereSeparator: \.isWhitespace)
        return words.prefix(4).joined(separator: " ").lowercased()
    }

    /// The sector of the first industry-impact item that carries a citation; uncited items never qualify a story.
    static func citedSector(_ impacts: [OverviewIndustryImpact]) -> String? {
        impacts.first { !$0.citationIDs.isEmpty }?.industry
    }

    /// Whether any row survives the board's region filter.
    func hasRows(under filter: BriefingBoardFilter) -> Bool { rows.contains { filter.includes($0.entry) } }

    static func isCandidate(_ entry: FeedEntry) -> Bool { entry.publisherCount <= lowCoverageLimit }

    /// Rows for the qualifying candidates in edition order; nil when none qualifies.
    static func make(entries: [FeedEntry], evidence: [String: Evidence], captions: [String: String]) -> Self? {
        let rows = entries.filter(isCandidate).compactMap { entry -> Row? in
            let reasons = reasons(evidence[entry.id] ?? Evidence())
            guard !reasons.isEmpty else { return nil }
            return Row(
                entry: entry, headline: entry.representative.title, caption: captions[entry.id] ?? "",
                reasons: reasons)
        }
        return rows.isEmpty ? nil : Self(rows: rows)
    }

    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        let candidates = context.entries.filter(isCandidate)
        guard !candidates.isEmpty else { return nil }
        let priorities =
            (try? await store.database.briefingPriorities(articleIDs: candidates.map(\.id))) ?? [:]
        var bigThreads: [String: String] = [:]
        for entry in context.entries where entry.publisherCount >= bigThreadPublishers {
            if case .event(let summary, _, _) = entry { bigThreads[summary.eventID] = entry.representative.title }
            for article in entry.visibleArticles { bigThreads[article.id] = entry.representative.title }
        }
        var evidence: [String: Evidence] = [:]
        var captions: [String: String] = [:]
        for entry in candidates {
            var found = Evidence()
            found.isMajor = priorities[entry.id]?.importance == .major
            let overview: EventOverviewDocument?
            if case .event(let summary, _, _) = entry {
                found.momentumRising = isMomentumRising(summary.members.map(\.date), now: context.now)
                let related = (try? await store.relatedStoryEvents(eventID: summary.eventID)) ?? []
                found.linkedThread =
                    related.lazy.compactMap { bigThreads[$0.eventID] ?? bigThreads[$0.articleID] }
                    .first
                overview = try? await store.fetchEventOverview(eventID: summary.eventID)
            } else {
                overview = try? await store.fetchEventOverview(forArticleID: entry.id)
            }
            found.sector = citedSector(overview?.industryImpact ?? [])
            evidence[entry.id] = found
            let count = entry.publisherCount
            captions[entry.id] =
                "\(count) \(count == 1 ? "publisher" : "publishers") · \(entry.representative.cardDateText(now: context.now))"
        }
        return make(entries: context.entries, evidence: evidence, captions: captions)
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        let now = Date(timeIntervalSince1970: 1_793_188_800)
        func entry(_ id: String, _ title: String, _ publisher: String) -> FeedEntry {
            .article(
                FeedArticle(
                    storedID: id, title: title, link: "https://example.com/\(id)", guid: id, description: "",
                    pubDate: now, source: publisher))
        }
        return Self(rows: [
            Row(
                entry: entry("weak-1", "Undersea cable fault cuts regional bandwidth", "Harbor Times"),
                headline: "Undersea cable fault cuts regional bandwidth", caption: "2 publishers · 5 h",
                reasons: ["Major rating", "Linked to shipping corridor thread"]),
            Row(
                entry: entry("weak-2", "Export licences required for two critical minerals", "Metals Daily"),
                headline: "Export licences required for two critical minerals", caption: "1 publisher · 3 h",
                reasons: ["Major rating", "Industry impact: Manufacturing"]),
            Row(
                entry: entry("weak-3", "Unusual overnight liquidity operation by a central bank", "Market Wire"),
                headline: "Unusual overnight liquidity operation by a central bank", caption: "2 publishers · 7 h",
                reasons: ["Momentum rising"]),
        ])
    }
}

struct BriefingWeakSignalsModuleView: View {
    let data: BriefingWeakSignalsData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View {
        let rows = Array(data.rows.filter { filter.includes($0.entry) }.prefix(BriefingWeakSignalsData.maximumRows))
        if !rows.isEmpty {
            card(rows)
        }
    }

    private func card(_ rows: [BriefingWeakSignalsData.Row]) -> some View {
        BriefingModuleCard(title: "Weak signals") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    Button {
                        actions.open(row.entry)
                    } label: {
                        rowView(row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.headline), \(row.caption). \(row.reasons.joined(separator: ", "))")
                    .accessibilityHint("Opens the story")
                }
            }
            Text(BriefingWeakSignalsData.footer)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowView(_ row: BriefingWeakSignalsData.Row) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Text(row.headline)
                    .font(AppTypography.headline)
                    .foregroundStyle(AppColor.primaryText)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: AppSpacing.xs)
                Text(row.caption)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            FlowPills(titles: row.reasons)
        }
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Reason pills that wrap onto further lines.
private struct FlowPills: View {
    let titles: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.eyebrowGap) { pills }
            VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) { pills }
        }
    }

    private var pills: some View {
        ForEach(titles, id: \.self) { TagView(title: $0, font: AppTypography.caption) }
    }
}
