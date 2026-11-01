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

/// Since your last briefing: what changed since the previous edition (#849). Each edition saves a snapshot of its
/// events; the next edition compares itself with the newest snapshot before it.
struct BriefingSinceLastData: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case newEvent = "New event"
        case moreCoverage = "More coverage"
        case escalation = "Escalation"
        case easing = "Easing"
    }

    struct Row: Equatable, Sendable, Identifiable {
        var id: String { "\(kind.rawValue)|\(eventID)" }
        let eventID: String
        let kind: Kind
        let text: String
        let meta: String
    }

    /// An event of the current edition, with the headline its row shows.
    struct Current: Equatable, Sendable {
        let snapshot: BriefingEditionSnapshotRow
        let title: String
    }

    static let rowLimit = 5

    let rows: [Row]
    /// How long ago the previous edition was, "6 h ago".
    let caption: String

    /// New events, then more coverage, escalation and easing, in edition order within each kind.
    static func changes(previous: [BriefingEditionSnapshotRow], previousAt: Date, current: [Current]) -> [Row] {
        let before = Dictionary(previous.map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        let time = previousAt.formatted(date: .omitted, time: .shortened)
        var rows: [Row] = []
        for kind in [Kind.newEvent, .moreCoverage, .escalation, .easing] {
            for event in current {
                let now = event.snapshot
                let old = before[now.eventID]
                switch kind {
                case .newEvent where old == nil:
                    rows.append(
                        Row(eventID: now.eventID, kind: kind, text: event.title, meta: "not in your last briefing"))
                case .moreCoverage:
                    guard let old, now.publisherCount > old.publisherCount else { continue }
                    let gained = now.publisherCount - old.publisherCount
                    rows.append(
                        Row(
                            eventID: now.eventID, kind: kind, text: event.title,
                            meta: "+\(gained) publisher\(gained == 1 ? "" : "s") since \(time)"))
                case .escalation
                where old != nil && now.escalation == TensionEscalation.escalating.rawValue
                    && old?.escalation != now.escalation:
                    rows.append(
                        Row(eventID: now.eventID, kind: kind, text: event.title, meta: "reporting describes escalation")
                    )
                case .easing
                where old != nil && now.escalation == TensionEscalation.deescalating.rawValue
                    && old?.escalation != now.escalation:
                    rows.append(
                        Row(
                            eventID: now.eventID, kind: kind, text: event.title,
                            meta: "reporting describes de-escalation"))
                default: continue
                }
            }
        }
        return Array(rows.prefix(rowLimit))
    }

    /// nil hides the module: there is no earlier edition or nothing changed. Saves this edition's snapshot either way.
    @MainActor static func load(_ context: BriefingLoadContext, store: ArticleStore) async -> Self? {
        guard let startedAt = context.briefing?.startedAt else { return nil }
        var current: [Current] = []
        for thread in BriefingThread.ranked(context.entries) {
            let overview = try? await store.fetchEventOverview(eventID: thread.summary.eventID)
            current.append(
                Current(
                    snapshot: BriefingEditionSnapshotRow(
                        eventID: thread.summary.eventID, membershipVersion: thread.summary.membershipVersion,
                        publisherCount: thread.publisherCount, escalation: overview.flatMap(escalation)),
                    title: BriefingThread.shortTitle(thread.representative.title)))
        }
        let previous = try? await store.database.latestBriefingSnapshot(before: startedAt)
        try? await store.database.saveBriefingSnapshot(startedAt: startedAt, rows: current.map(\.snapshot))
        guard let previous else { return nil }
        let rows = changes(previous: previous.rows, previousAt: previous.startedAt, current: current)
        guard !rows.isEmpty else { return nil }
        return Self(rows: rows, caption: BriefingThread.ago(previous.startedAt, now: context.now))
    }

    /// Escalating or de-escalating only when a cited highlight carries the cue.
    static func escalation(of overview: EventOverviewDocument) -> String? {
        let facts = overview.facts.map { fact in
            PassageAnchoredFact(
                id: fact.id, statement: fact.text, passageID: fact.citationIDs.first ?? fact.id,
                quote: fact.citationIDs.first.flatMap { overview.citations[$0]?.quote } ?? fact.text,
                articleID: fact.citationIDs.first.flatMap { overview.citations[$0]?.articleID } ?? "")
        }
        let classification = TensionEventClassifier.classify(facts)
        guard !classification.escalationEvidence.isEmpty else { return nil }
        switch classification.escalation {
        case .escalating, .deescalating: return classification.escalation.rawValue
        default: return nil
        }
    }

    /// Sample data for `Tests/OverviewCaptures.swift`.
    static var captureFixture: Self? {
        Self(
            rows: [
                Row(
                    eventID: "e1", kind: .moreCoverage, text: "Shipping corridor incidents",
                    meta: "+3 publishers since 11:40"),
                Row(
                    eventID: "e2", kind: .newEvent, text: "Additional port security measures announced",
                    meta: "not in your last briefing"),
                Row(
                    eventID: "e3", kind: .easing, text: "Border crossing reopens to freight",
                    meta: "reporting describes de-escalation"),
            ], caption: "6 h ago")
    }
}

struct BriefingSinceLastModuleView: View {
    let data: BriefingSinceLastData
    let filter: BriefingBoardFilter
    let actions: BriefingActions

    var body: some View {
        BriefingModuleCard(title: "Since your last briefing", caption: data.caption) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(data.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        TagView(title: row.kind.rawValue, tint: tint(row.kind))
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text(row.text).font(AppTypography.body).foregroundStyle(AppColor.primaryText)
                            Text(row.meta).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func tint(_ kind: BriefingSinceLastData.Kind) -> Color {
        switch kind {
        case .newEvent: return AppColor.warning
        case .moreCoverage: return AppColor.accent
        case .escalation: return AppColor.danger
        case .easing: return AppColor.success
        }
    }
}
