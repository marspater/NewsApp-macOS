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
import NewsCore
import SwiftUI

// MARK: - Story Tiles Grid Component

/// One titled group of the board's tiles: the stories of one topic, in edition order.
struct BriefingSection: Identifiable, Equatable {
    let title: String
    let entries: [FeedEntry]
    var id: String { title }
}

/// The edition's stories as dense tiles, grouped by topic under section titles (DESIGN.md 8.4).
struct BriefingTileGridView: View {
    let sections: [BriefingSection]
    var facts: [String: BriefingCitedFact] = [:]
    var readIDs: Set<String> = []
    var savedIDs: Set<String> = []
    var focusedID: String?
    let actions: BriefingActions

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(section.title)
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColor.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: AppLayout.gridColumnMinimum, maximum: AppLayout.gridColumnMaximum),
                                spacing: AppLayout.cardGap, alignment: .top)
                        ],
                        alignment: .leading,
                        spacing: AppLayout.cardGap
                    ) {
                        ForEach(section.entries) { entry in
                            tile(entry)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ entry: FeedEntry) -> some View {
        let article = entry.representative
        let summary: EventFeedSummary? = {
            if case .event(let summary, _, _) = entry { return summary }
            return nil
        }()
        return BriefingTileView(
            article: article,
            eventSummary: summary,
            citedFact: facts[entry.id],
            state: BriefingTileState(
                isSelected: focusedID == article.id, isRead: readIDs.contains(article.id),
                isSaved: savedIDs.contains(article.id)),
            onOpen: { actions.open(entry) },
            onToggleRead: { actions.onToggleRead(article) },
            onToggleSave: { actions.onToggleSave(article) }
        )
        .id(entry.id)
    }
}

// MARK: - Completion Banner

/// Progress through the edition and when the next one arrives, with the way back to Today (DESIGN.md 8.4).
struct BriefingCompletionBanner: View {
    let briefing: FiniteBriefing
    let readIDs: Set<String>
    let nextEdition: Date
    let onBackToToday: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Text(
                briefing.isComplete(readIDs)
                    ? "Briefing complete"
                    : "\(briefing.readCount(readIDs)) of \(briefing.articles.count) stories read"
            )
            .font(AppTypography.sectionTitle)
            .foregroundStyle(AppColor.primaryText)
            .monospacedDigit()
            Text(
                "Briefing selected at \(briefing.startedAt.formatted(date: .omitted, time: .shortened)). The next briefing arrives at \(nextEdition.formatted(date: .omitted, time: .shortened)). New stories stay in Today."
            )
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
            .multilineTextAlignment(.center)
            Button("Back to Today", action: onBackToToday)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Split row

/// Two views side by side, the leading one taking `leadingFraction` of the width, both as tall as the taller; below
/// `minimumWidth` they stack. The canvas's flex rows (carousel 2 : column 1, Weak signals 1 : Forward watch 1).
struct BriefingSplitLayout: Layout {
    var leadingFraction: CGFloat
    var minimumWidth: CGFloat
    var spacing: CGFloat = AppLayout.cardGap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else {
            var y: CGFloat = 0
            return subviews.map { subview in
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                defer { y += height + spacing }
                return CGRect(x: 0, y: y, width: width, height: height)
            }
        }
        if width >= minimumWidth {
            let leading = ((width - spacing) * leadingFraction).rounded()
            let trailing = width - spacing - leading
            let height = max(
                subviews[0].sizeThatFits(ProposedViewSize(width: leading, height: nil)).height,
                subviews[1].sizeThatFits(ProposedViewSize(width: trailing, height: nil)).height)
            return [
                CGRect(x: 0, y: 0, width: leading, height: height),
                CGRect(x: leading + spacing, y: 0, width: trailing, height: height),
            ]
        }
        let first = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let second = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return [
            CGRect(x: 0, y: 0, width: width, height: first),
            CGRect(x: 0, y: first + spacing, width: width, height: second),
        ]
    }
}
