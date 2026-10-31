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

/// Priority developments: impact, momentum, original reports and the reported fact of the most-covered threads (#849).
struct BriefingPriorityData: Equatable, Sendable {
    enum Momentum: Equatable, Sendable {
        case rising, steady, fading

        var label: String {
            switch self {
            case .rising: return "▲ Rising"
            case .steady: return "– Steady"
            case .fading: return "▼ Fading"
            }
        }
    }

    /// Reported text with the publisher it came from.
    struct Quote: Equatable, Sendable {
        let text: String
        let publisher: String
        let url: URL?
    }

    struct Card: Equatable, Sendable, Identifiable {
        let id: String
        let summary: EventFeedSummary?
        let meta: String
        let state: String?
        let headline: String
        let impact: String
        let momentum: Momentum
        let original: String
        let reported: Quote?
        /// Two differing accounts, "[participant]: position", or empty.
        let accounts: [String]
        let notYetReported: Quote?
        let threadDay: Int?
        let isLead: Bool
    }

    let cards: [Card]

    /// Reports in the last six hours against the six hours before.
    static func momentum(dates: [Date], now: Date) -> Momentum {
        let window: TimeInterval = 6 * 3600
        let recent = dates.filter { $0 <= now && now.timeIntervalSince($0) < window }.count
        let before = dates.filter { now.timeIntervalSince($0) >= window && now.timeIntervalSince($0) < 2 * window }
            .count
        if recent > before { return .rising }
        if recent < before { return .fading }
        return .steady
    }

    /// A publisher's text that carries another agency's wire copy. A wire agency's own report is original.
    static func isWireCopy(text: String, publisher: String) -> Bool {
        OverviewPerspectivesExtractor.detectWireSource(in: text, articleSource: publisher) != nil
            && OverviewPerspectivesExtractor.detectWireSource(in: "", articleSource: publisher) == nil
    }

    /// Distinct publishers with at least one report that is not wire copy.
    static func originalReports(_ reports: [(publisher: String, text: String)]) -> Int {
        Set(reports.filter { !isWireCopy(text: $0.text, publisher: $0.publisher) }.map(\.publisher)).count
    }

    static func reportText(_ article: FeedArticle) -> String {
        [article.title, article.description, article.fullContent ?? ""].joined(separator: "\n")
    }

    private static let unconfirmedCues = [
        "unconfirmed", "not confirmed", "no independent confirmation", "could not verify",
    ]

    /// nil hides the module.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        let threads = Array(BriefingThread.ranked(context.entries).prefix(3))
        guard !threads.isEmpty else { return nil }
        let priorities =
            (try? await store.database.briefingPriorities(articleIDs: threads.map(\.representative.id))) ?? [:]
        var cards: [Card] = []
        for (index, thread) in threads.enumerated() {
            let summary = thread.summary
            let overview = try? await store.fetchEventOverview(eventID: summary.eventID)
            let members = (try? await store.eventMemberArticles(eventID: summary.eventID)) ?? []
            let original =
                members.isEmpty
                ? (overview.map { thread.publisherCount - Set($0.perspectives.compactMap(\.originalWireSource)).count }
                    ?? thread.publisherCount)
                : originalReports(members.map { ($0.publisherName, reportText($0)) })
            let firstReport = (try? await store.storyMemberArticles(eventID: summary.eventID))?.map(\.pubDate).min()
            let latest = summary.latestDate ?? thread.representative.pubDate
            cards.append(
                Card(
                    id: summary.eventID, summary: summary,
                    meta: "\(thread.publisherCount) publishers · \(BriefingThread.ago(latest, now: context.now))",
                    state: BriefingView.isDeveloping(
                        .event(
                            summary, representative: thread.representative,
                            visibleMembers: []), now: context.now)
                        ? "Developing" : summary.hasSubstantiveUpdate ? "Updated" : nil,
                    headline: thread.representative.title,
                    impact: impactText(priorities[thread.representative.id]?.importance),
                    momentum: momentum(dates: summary.members.map(\.date), now: context.now),
                    original: "\(max(0, original)) of \(thread.publisherCount)",
                    reported: overview.flatMap(reported), accounts: overview.map(accounts) ?? [],
                    notYetReported: overview.flatMap(notYetReported),
                    threadDay: firstReport.map {
                        (Calendar.current.dateComponents([.day], from: $0, to: context.now).day ?? 0) + 1
                    },
                    isLead: index == 0))
        }
        return Self(cards: cards)
    }

    private static func impactText(_ importance: StoryImportance?) -> String {
        switch importance {
        case .major: return "Major"
        case .notable: return "Notable"
        case .minor: return "Minor"
        case nil: return "Not rated"
        }
    }

    private static func quote(_ text: String, citationIDs: [String], in overview: EventOverviewDocument) -> Quote? {
        guard let citation = citationIDs.lazy.compactMap({ overview.citations[$0] }).first,
            let publisher = citation.sourceName
        else { return nil }
        return Quote(text: text, publisher: publisher, url: citation.sourceURL.flatMap(URL.init(string:)))
    }

    private static func reported(_ overview: EventOverviewDocument) -> Quote? {
        overview.facts.lazy.compactMap { quote($0.text, citationIDs: $0.citationIDs, in: overview) }.first
    }

    /// Two perspectives from different participants with different positions.
    private static func accounts(_ overview: EventOverviewDocument) -> [String] {
        guard let first = overview.perspectives.first,
            let second = overview.perspectives.first(where: {
                $0.participant.lowercased() != first.participant.lowercased()
                    && $0.position.lowercased() != first.position.lowercased()
            })
        else { return [] }
        return [first, second].map { "[\($0.participant)]: \($0.position)" }
    }

    /// Only a cited line that itself says something is unconfirmed; never written by the app.
    private static func notYetReported(_ overview: EventOverviewDocument) -> Quote? {
        let lines =
            overview.facts.map { ($0.text, $0.citationIDs) }
            + overview.perspectives.map { ($0.position, $0.citationIDs) }
        return lines.lazy.filter { text, _ in unconfirmedCues.contains { text.lowercased().contains($0) } }
            .compactMap { quote($0.0, citationIDs: $0.1, in: overview) }.first
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        Self(cards: [
            Card(
                id: "p1", summary: nil, meta: "11 publishers · 14 min ago", state: "Developing",
                headline: "Shipping corridor security tightens after new reported incidents", impact: "Major",
                momentum: .rising, original: "5 of 11",
                reported: Quote(
                    text: "Port authorities raised the security level for all inbound vessels.", publisher: "Reuters",
                    url: nil),
                accounts: [
                    "[Port authority]: seven vessels were targeted in the zone.",
                    "[Shipping group]: no commercial ship was damaged.",
                ],
                notYetReported: Quote(
                    text: "The number of vessels targeted could not be verified.", publisher: "Associated Press",
                    url: nil), threadDay: 4, isLead: true),
            Card(
                id: "p2", summary: nil, meta: "8 publishers · 1 h ago", state: "Developing",
                headline: "Protest bans extended in two capitals ahead of weekend marches", impact: "Notable",
                momentum: .steady, original: "6 of 8",
                reported: Quote(
                    text: "Police say the ban covers the city centre until Monday.", publisher: "BBC News", url: nil),
                accounts: [
                    "[Organisers]: the marches will go ahead.", "[Interior ministry]: gatherings will be dispersed.",
                ], notYetReported: nil, threadDay: 9, isLead: false),
            Card(
                id: "p3", summary: nil, meta: "6 publishers · 2 h ago", state: "Updated",
                headline: "Health officials widen containment perimeter after new cases", impact: "Not rated",
                momentum: .rising, original: "4 of 6",
                reported: Quote(
                    text: "Health officials confirmed cases in two districts outside the zone.",
                    publisher: "The Guardian",
                    url: nil), accounts: [], notYetReported: nil, threadDay: 3, isLead: false),
        ])
    }
}

struct BriefingPriorityModuleView: View {
    let data: BriefingPriorityData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    @Environment(\.effectiveContrast) private var contrast

    private enum Metrics {
        static let cardMinimum: CGFloat = 300
    }

    var body: some View {
        BriefingModuleCard(title: "Priority developments", caption: "The most-covered threads") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Metrics.cardMinimum), spacing: AppSpacing.md, alignment: .top)],
                alignment: .leading, spacing: AppSpacing.md
            ) {
                ForEach(data.cards) { card in
                    cardView(card)
                }
            }
        }
    }

    private func cardView(_ card: BriefingPriorityData.Card) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                Text(card.meta).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                Spacer(minLength: AppSpacing.xs)
                if let state = card.state { TagView(title: state, tint: AppColor.warning) }
            }
            Text(card.headline)
                .font(AppTypography.sectionTitle.leading(.tight))
                .fontDesign(.serif)
                .foregroundStyle(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            stats(card)
            Divider()
            if let reported = card.reported {
                layer("Reported") { quoteView(reported) }
            }
            if card.accounts.count == 2 {
                layer("Accounts differ") {
                    ForEach(card.accounts, id: \.self) { line in
                        Text(line).font(AppTypography.callout).foregroundStyle(AppColor.secondaryText)
                    }
                }
            }
            if let unknown = card.notYetReported {
                layer("Not yet reported") { quoteView(unknown) }
            }
            Spacer(minLength: 0)
            footer(card)
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(
                    card.isLead ? AppColor.accent : AppColor.border(for: contrast),
                    lineWidth: card.isLead
                        ? AppLayout.leadTileStroke
                        : contrast == .increased ? AppLayout.hoverStroke : AppLayout.hairline)
        )
        .accessibilityElement(children: .contain)
    }

    private func stats(_ card: BriefingPriorityData.Card) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            stat("Impact", card.impact)
            stat("Momentum", card.momentum.label)
            stat("Original reports", card.original)
        }
    }

    /// The thread's day and the way to its overview.
    private func footer(_ card: BriefingPriorityData.Card) -> some View {
        HStack(spacing: AppSpacing.xs) {
            if let day = card.threadDay {
                Text("Story thread · day \(day)").font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: AppSpacing.xs)
            Button("Open event overview") {
                if let summary = card.summary { actions.onOpenEvent(summary) }
            }
            .buttonStyle(.link)
            .font(AppTypography.caption)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
            EyebrowText(label).fixedSize(horizontal: false, vertical: true)
            Text(value).font(AppTypography.label.weight(.semibold)).foregroundStyle(AppColor.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func layer(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            EyebrowText(label)
            content()
        }
    }

    private func quoteView(_ quote: BriefingPriorityData.Quote) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
            Text("“\(quote.text)”")
                .font(AppTypography.quote)
                .foregroundStyle(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let url = quote.url {
                Button(quote.publisher) { actions.onOpenURL(url) }
                    .buttonStyle(.link)
                    .font(AppTypography.caption)
            } else {
                Text(quote.publisher).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
        }
    }
}
