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

/// The edition's event threads, most publishers first; executive sitrep, priority developments and source footprint
/// share this ranking (#849).
struct BriefingThread: Equatable, Sendable {
    let summary: EventFeedSummary
    let representative: FeedArticle
    let publisherCount: Int

    static func ranked(_ entries: [FeedEntry]) -> [BriefingThread] {
        let threads = entries.compactMap { entry -> BriefingThread? in
            guard case .event(let summary, let representative, _) = entry else { return nil }
            return BriefingThread(
                summary: summary, representative: representative, publisherCount: entry.publisherCount)
        }
        // Stable: equal counts keep edition order.
        return threads.enumerated().sorted {
            ($0.element.publisherCount, -$0.offset) > ($1.element.publisherCount, -$1.offset)
        }.map(\.element)
    }

    /// The headline cut at a word boundary, for the short serif titles.
    static func shortTitle(_ title: String, limit: Int = 70) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let cut = clean.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// "14 min ago", "6 h ago", "3 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(max(1, minutes)) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) days ago"
    }
}

/// Executive sitrep: three lines from the three most-covered threads (#849).
struct BriefingSitrepData: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let body: String
        let publisherCount: Int
        /// Opens the thread; nil in captures.
        let summary: EventFeedSummary?
    }

    let lines: [Line]

    /// nil hides the module: it needs two threads with highlights.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        let model: NewsTextModel = AppSettings.shared.aiEnabled ? .onDevice : .unavailable
        var lines: [Line] = []
        for thread in BriefingThread.ranked(context.entries).prefix(3) {
            let eventID = thread.summary.eventID
            guard let overview = try? await store.fetchEventOverview(eventID: eventID), !overview.facts.isEmpty
            else { continue }
            let hash = DatabaseEngine.briefingSitrepInputHash(eventID: eventID, overview: overview)
            let body: String
            if let cached = try? await store.database.fetchBriefingSitrep(eventID: eventID), cached.inputHash == hash {
                body = cached.text
            } else {
                let highlights = overview.facts.prefix(BriefingSitrepComposer.factLimit).map { fact in
                    BriefingSitrepComposer.Highlight(
                        text: fact.text,
                        publisher: fact.citationIDs.lazy.compactMap { overview.citations[$0]?.sourceName }.first)
                }
                guard
                    let line = await BriefingSitrepComposer.compose(
                        title: thread.representative.title, highlights: highlights, model: model)
                else { continue }
                body = line.text
                if line.isFinal {
                    _ = try? await store.database.saveBriefingSitrep(
                        eventID: eventID, inputHash: hash, text: line.text, isGenerated: line.isGenerated)
                }
            }
            lines.append(
                Line(
                    id: eventID, title: BriefingThread.shortTitle(thread.representative.title, limit: 48), body: body,
                    publisherCount: thread.publisherCount, summary: thread.summary))
        }
        return lines.count >= 2 ? Self(lines: lines) : nil
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        Self(lines: [
            Line(
                id: "s1", title: "Corridor security tightens",
                body: "Three more publishers report incidents near a major shipping lane; insurers and ports respond.",
                publisherCount: 11, summary: nil),
            Line(
                id: "s2", title: "Protest bans face weekend tests",
                body: "Authorities in two capitals extend restrictions ahead of planned marches.", publisherCount: 8,
                summary: nil),
            Line(
                id: "s3", title: "Health emergency perimeter widens",
                body: "Officials report new cases outside the first containment zone.", publisherCount: 6,
                summary: nil),
        ])
    }
}

struct BriefingSitrepModuleView: View {
    let data: BriefingSitrepData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    private enum Metrics {
        static let lineMinimum: CGFloat = 240
    }

    var body: some View {
        BriefingModuleCard(title: "Executive sitrep", caption: "From the \(data.lines.count) most-covered threads") {
            // Side by side when each line gets its minimum width, else stacked.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppSpacing.md) { lineViews(minWidth: Metrics.lineMinimum) }
                VStack(alignment: .leading, spacing: AppSpacing.md) { lineViews(minWidth: nil) }
            }
            IntelligenceLabel("Assembled on this Mac from the cited passages")
                .font(AppTypography.caption)
        }
    }

    private func lineViews(minWidth: CGFloat?) -> some View {
        ForEach(Array(data.lines.enumerated()), id: \.element.id) { index, line in
            lineView(line, number: index + 1)
                .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func lineView(_ line: BriefingSitrepData.Line, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text("\(number)")
                .font(AppTypography.sectionTitle.monospacedDigit())
                .foregroundStyle(AppColor.tertiaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(line.title)
                    .font(AppTypography.quote.weight(.semibold))
                    .foregroundStyle(AppColor.primaryText)
                Text(line.body)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("\(line.publisherCount) publishers · open thread") {
                    if let summary = line.summary { actions.onOpenEvent(summary) }
                }
                .buttonStyle(.link)
                .font(AppTypography.caption)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
