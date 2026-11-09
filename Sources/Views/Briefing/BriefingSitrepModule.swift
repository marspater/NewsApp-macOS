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

/// What orders the Briefing's stories: original reports first, wire copies counting once, then stored importance where
/// a rating exists, then distinct publishers, then edition order. Publisher count alone let one copied wire dispatch
/// outrank independent reporting. The hero carousel, executive sitrep, priority developments, source footprint and
/// since-last rows share it, so the lead story is the same everywhere. Selection reads stored ratings and never
/// requests one.
struct BriefingRanking: Equatable, Sendable {
    struct Signal: Equatable, Sendable {
        var originalCount: Int
        var importance: StoryImportance?
    }

    /// By entry id. A story without a signal (before the load finishes, or a single article) ranks by its publishers.
    var signals: [String: Signal] = [:]

    /// Distinct publishers with an original report, plus one for all wire copies together.
    static func signal(reports: [(publisher: String, text: String)], importance: StoryImportance?) -> Signal {
        var originals = Set<String>()
        var hasWireCopy = false
        for report in reports {
            if BriefingPriorityData.isWireCopy(text: report.text, publisher: report.publisher) {
                hasWireCopy = true
            } else {
                originals.insert(report.publisher)
            }
        }
        return Signal(originalCount: originals.count + (hasWireCopy ? 1 : 0), importance: importance)
    }

    /// Best first; an unrated story ranks below a rated one, and equal stories keep edition order.
    func order(_ entries: [FeedEntry]) -> [FeedEntry] {
        entries.enumerated().sorted {
            let (lhs, rhs) = (sortKey($0.element), sortKey($1.element))
            return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
        }.map(\.element)
    }

    private func sortKey(_ entry: FeedEntry) -> (Int, Int, Int) {
        let signal = signals[entry.id]
        return (signal?.originalCount ?? entry.publisherCount, signal?.importance?.rawValue ?? -1, entry.publisherCount)
    }

    /// Reads each event's members and the stored ratings, off the main actor (the database is an actor and the wire
    /// detection runs here); the cards never load member text.
    nonisolated static func load(entries: [FeedEntry], database: DatabaseEngine) async -> Self {
        var events: [(id: String, eventID: String, representativeID: String)] = []
        for entry in entries {
            guard case .event(let summary, let representative, _) = entry else { continue }
            events.append((entry.id, summary.eventID, representative.id))
        }
        var ranking = Self()
        guard !events.isEmpty else { return ranking }
        let priorities = (try? await database.briefingPriorities(articleIDs: events.map(\.representativeID))) ?? [:]
        for event in events where !Task.isCancelled {
            guard let members = try? await database.fetchArticles(limit: nil, eventID: event.eventID) else { continue }
            ranking.signals[event.id] = signal(
                reports: members.map { ($0.publisherName, BriefingPriorityData.reportText($0)) },
                importance: priorities[event.representativeID]?.importance)
        }
        return ranking
    }
}

/// The edition's event threads in `BriefingRanking` order; executive sitrep, priority developments and source
/// footprint share this ranking (#849).
struct BriefingThread: Equatable, Sendable {
    let summary: EventFeedSummary
    let representative: FeedArticle
    let publisherCount: Int

    static func ranked(_ entries: [FeedEntry], ranking: BriefingRanking = BriefingRanking()) -> [BriefingThread] {
        ranking.order(entries).compactMap { entry -> BriefingThread? in
            guard case .event(let summary, let representative, _) = entry else { return nil }
            return BriefingThread(
                summary: summary, representative: representative, publisherCount: entry.publisherCount)
        }
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

/// Executive sitrep: three lines from the three top-ranked threads (#849).
struct BriefingSitrepData: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let body: String
        let publisherCount: Int
        /// Written by the on-device model rather than taken from a highlight.
        let isGenerated: Bool
        /// Opens the thread; nil in captures.
        let summary: EventFeedSummary?
    }

    let lines: [Line]

    /// nil hides the module: it needs two threads with highlights.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        let model: NewsTextModel = AppSettings.shared.aiEnabled ? .onDevice : .unavailable
        var lines: [Line] = []
        for thread in BriefingThread.ranked(context.entries, ranking: context.ranking).prefix(3) {
            let eventID = thread.summary.eventID
            guard let overview = try? await store.fetchEventOverview(eventID: eventID), !overview.facts.isEmpty
            else { continue }
            let hash = DatabaseEngine.briefingSitrepInputHash(
                eventID: eventID, title: thread.representative.title, overview: overview)
            let body: String
            let isGenerated: Bool
            if let cached = try? await store.database.fetchBriefingSitrep(eventID: eventID), cached.inputHash == hash {
                body = cached.text
                isGenerated = cached.isGenerated
            } else {
                guard
                    let line = await BriefingSitrepComposer.compose(
                        title: thread.representative.title, highlights: BriefingSitrepComposer.highlights(of: overview),
                        model: model)
                else { continue }
                body = line.text
                isGenerated = line.isGenerated
                if line.isFinal {
                    _ = try? await store.database.saveBriefingSitrep(
                        eventID: eventID, articleID: thread.representative.id, inputHash: hash, text: line.text,
                        isGenerated: line.isGenerated)
                }
            }
            lines.append(
                Line(
                    id: eventID, title: BriefingThread.shortTitle(thread.representative.title, limit: 48), body: body,
                    publisherCount: thread.publisherCount, isGenerated: isGenerated, summary: thread.summary))
        }
        return lines.count >= 2 ? Self(lines: lines) : nil
    }

    /// Sample data for `Tests/Harness/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        Self(lines: [
            Line(
                id: "s1", title: "Corridor security tightens",
                body: "Three more publishers report incidents near a major shipping lane; insurers and ports respond.",
                publisherCount: 11, isGenerated: true, summary: nil),
            Line(
                id: "s2", title: "Protest bans face weekend tests",
                body: "Authorities in two capitals extend restrictions ahead of planned marches.", publisherCount: 8,
                isGenerated: true, summary: nil),
            Line(
                id: "s3", title: "Health emergency perimeter widens",
                body: "Officials report new cases outside the first containment zone.", publisherCount: 6,
                isGenerated: false, summary: nil),
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
        BriefingModuleCard(title: "Executive sitrep", caption: "From the \(data.lines.count) top-ranked threads") {
            // Side by side when each line gets its minimum width, else stacked.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppSpacing.md) { lineViews(minWidth: Metrics.lineMinimum) }
                VStack(alignment: .leading, spacing: AppSpacing.md) { lineViews(minWidth: nil) }
            }
            if data.lines.contains(where: \.isGenerated) {
                IntelligenceLabel("Assembled on this Mac from the cited passages")
                    .font(AppTypography.caption)
            }
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
