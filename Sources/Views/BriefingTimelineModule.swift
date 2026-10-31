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

/// Escalation timeline: turning points across the lead story's thread (#850).
struct BriefingTimelineData: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        let id: String
        let dayText: String
        let summary: String
        let date: Date
        /// The summary reports escalation explicitly (World Tension classifier cues).
        let isEscalating: Bool
    }

    /// One story with at least two dated past turning points.
    struct Thread: Equatable, Sendable {
        let entry: FeedEntry
        let items: [Item]
        /// Whole days from the first item to the edition.
        let day: Int

        var caption: String { "\(entry.representative.title) · day \(day)" }
    }

    /// Most publishers first.
    let threads: [Thread]

    func hasRows(under filter: BriefingBoardFilter) -> Bool { thread(for: filter) != nil }

    /// The lead thread inside the filter.
    func thread(for filter: BriefingBoardFilter) -> Thread? { threads.first { filter.includes($0.entry) } }

    /// Every timeline of the story's live events as one, keeping the first item of each identical summary.
    /// Plans, undated and future items are dropped first, so they never hide a dated past copy of the same summary.
    static func merged(_ timelines: [[OverviewTimelineItem]], now: Date) -> [OverviewTimelineItem] {
        var seen = Set<String>()
        return timelines.joined().filter { item in
            guard !item.isFuturePlan, let date = item.eventDate ?? item.publicationDate, date <= now else {
                return false
            }
            return seen.insert(item.summary).inserted
        }
    }

    /// Past, dated items in date order, the latest five; nil with fewer than two.
    static func items(_ timeline: [OverviewTimelineItem], now: Date) -> [Item]? {
        let dated = timeline.compactMap { item -> Item? in
            guard !item.isFuturePlan, let date = item.eventDate ?? item.publicationDate, date <= now else { return nil }
            let fact = PassageAnchoredFact(
                id: item.id, statement: item.summary, passageID: item.id, quote: item.summary, articleID: "")
            return Item(
                id: item.id, dayText: item.dateText, summary: item.summary, date: date,
                isEscalating: TensionEventClassifier.classify([fact], methodology: .v1).escalation == .escalating)
        }
        let latest = Array(dated.sorted { $0.date < $1.date }.suffix(Metrics.maximumItems))
        return latest.count >= 2 ? latest : nil
    }

    static func thread(entry: FeedEntry, timeline: [OverviewTimelineItem], now: Date) -> Thread? {
        guard let items = items(timeline, now: now), let first = items.first else { return nil }
        let calendar = Calendar.current
        let day = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: now)
        ).day
        return Thread(entry: entry, items: items, day: max(0, day ?? 0))
    }

    /// nil hides the module.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        let overviews = await BriefingOverviews.load(context.entries, store: store)
        var threads: [(Int, Thread)] = []
        for (index, pair) in overviews.enumerated() where !Task.isCancelled {
            var timelines = [pair.1.timeline]
            if case .event(let summary, _, _) = pair.0,
                let storyEvents = try? await store.database.storyEventIDs(summary.eventID)
            {
                for eventID in storyEvents where eventID != summary.eventID {
                    if let overview = try? await store.fetchEventOverview(eventID: eventID) {
                        timelines.append(overview.timeline)
                    }
                }
            }
            if let thread = thread(entry: pair.0, timeline: merged(timelines, now: context.now), now: context.now) {
                threads.append((index, thread))
            }
        }
        let ordered = threads.sorted {
            $0.1.entry.publisherCount != $1.1.entry.publisherCount
                ? $0.1.entry.publisherCount > $1.1.entry.publisherCount : $0.0 < $1.0
        }
        .map(\.1)
        return ordered.isEmpty ? nil : Self(threads: ordered)
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        let entry = BriefingRegionsData.sampleEntry(
            id: "timeline-0", title: "Shipping corridor security tightens off Yemen", publishers: 11, date: now)
        let steps: [SampleStep] = [
            SampleStep(day: "Mon", summary: "First incident reported in the corridor", daysAgo: 4),
            SampleStep(day: "Tue", summary: "Two more vessels named by the coast guard", daysAgo: 3),
            SampleStep(day: "Wed", summary: "Insurers suspend new war-risk cover", daysAgo: 2),
            SampleStep(day: "Thu", summary: "Attacks escalated as the security level is raised", daysAgo: 1),
            SampleStep(day: "Today", summary: "Naval escorts begin for inbound vessels", daysAgo: 0.1),
        ]
        let timeline = steps.map {
            OverviewTimelineItem(
                dateText: $0.day, summary: $0.summary, eventDate: now.addingTimeInterval(-$0.daysAgo * 86_400))
        }
        return thread(entry: entry, timeline: timeline, now: now).map { Self(threads: [$0]) }
    }
}

/// One capture fixture turning point.
private struct SampleStep {
    let day: String
    let summary: String
    let daysAgo: Double
}

private enum Metrics {
    static let maximumItems = 5
    static let dot: CGFloat = 8
    static let escalatingDot: CGFloat = 12
}

struct BriefingTimelineModuleView: View {
    let data: BriefingTimelineData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View {
        if let thread = data.thread(for: filter) { card(thread) }
    }

    private func card(_ thread: BriefingTimelineData.Thread) -> some View {
        BriefingModuleCard(title: "Escalation timeline", caption: thread.caption) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                IntelligenceLabel("Assessed on this Mac").font(AppTypography.caption)
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    ForEach(thread.items) { item in
                        column(item)
                    }
                }
            }
        }
    }

    private func column(_ item: BriefingTimelineData.Item) -> some View {
        let size = item.isEscalating ? Metrics.escalatingDot : Metrics.dot
        return VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack(spacing: AppSpacing.xxs) {
                Circle()
                    .fill(item.isEscalating ? AppColor.warning : AppColor.secondaryText)
                    .frame(width: size, height: size)
                    .frame(width: Metrics.escalatingDot, height: Metrics.escalatingDot)
                Rectangle().fill(AppColor.borderSubtle).frame(height: AppLayout.hairline)
            }
            .accessibilityHidden(true)
            Text(item.dayText)
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(AppColor.secondaryText)
            Text(item.summary)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isEscalating ? "Reports escalation" : "")
    }
}
