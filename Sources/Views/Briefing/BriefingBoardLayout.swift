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
    /// Each story's key fact, keyed by feed entry id.
    var facts: [String: BriefingCitedFact] = [:]
    /// Ids of the reports already read; a read tile dims its headline and drops the unread dot.
    var readIDs: Set<String> = []
    /// Ids of the reports in Saved Stories.
    var savedIDs: Set<String> = []
    /// The id of the report whose tile draws the focus ring.
    var focusedID: String?
    /// What a tile does when it is opened or its read or saved state is toggled.
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
    /// When the next edition is selected.
    let nextEdition: Date
    /// Leaves Briefing for the Today page.
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
    /// The leading view's share of the width left after the spacing.
    var leadingFraction: CGFloat
    /// The narrowest width at which the two views sit side by side.
    var minimumWidth: CGFloat
    /// The gap between the views, beside or above each other.
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

// MARK: - Situational Awareness Layout

/// The slot a module takes in `BriefingSituationalLayout`.
enum BriefingSituationalRole: Int, LayoutValueKey {
    /// The hero carousel at the top of the leading column; the default.
    case hero = 0
    /// The trailing column: World Tension and Since your last briefing.
    case trailing = 1
    /// The Executive sitrep, under the hero carousel.
    case sitrep = 2

    static let defaultValue: BriefingSituationalRole = .hero
}

extension View {
    /// Places the view in the slot of a `BriefingSituationalLayout` that `role` names.
    func briefingSituationalRole(_ role: BriefingSituationalRole) -> some View {
        layoutValue(key: BriefingSituationalRole.self, value: role)
    }
}

/// Situational awareness module layout (#1211):
/// In wide windows (>= minimumWidth):
/// - The hero carousel takes 2/3 width on the left.
/// - The Executive sitrep sits directly under the hero carousel at 2/3 width, filling the space beside the right column without leaving an empty band.
/// - World Tension and Since your last briefing take 1/3 width in the trailing column on the right.
/// - If the trailing column is empty or absent, hero and sitrep take full width without leaving a hole.
/// In narrow windows (< minimumWidth):
/// - A single responsive column stacking Hero -> Trailing column (World Tension, Since your last briefing) -> Executive sitrep.
/// - Hiding any module leaves no gaps or holes.
struct BriefingSituationalLayout: Layout {
    /// Below this the trailing card (World Tension score row: 140 pt chart, spacing, score and level) no longer fits.
    static let defaultMinimumWidth: CGFloat = 1000

    /// The leading column's share of the width left after the spacing.
    var leadingFraction: CGFloat = 2.0 / 3.0
    /// The narrowest width with two columns.
    var minimumWidth: CGFloat = defaultMinimumWidth
    /// The gap between modules and between the columns.
    var spacing: CGFloat = AppLayout.cardGap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        let f = frames(width: width, subviews: subviews)
        let height = f.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let f = frames(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, f) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// The frame of each module; nil for a module that is absent.
    public struct ModuleFrames: Equatable {
        public var hero: CGRect?
        public var trailing: CGRect?
        public var sitrep: CGRect?

        public init(hero: CGRect? = nil, trailing: CGRect? = nil, sitrep: CGRect? = nil) {
            self.hero = hero
            self.trailing = trailing
            self.sitrep = sitrep
        }
    }

    /// Lays out modules of the given heights. Two columns when `width` reaches `minimumWidth`, the trailing module is
    /// present and so is the hero or the sitrep; otherwise one column of hero, trailing and sitrep. An absent module (a
    /// nil height) gets no frame and leaves no gap.
    static func computeFrames(
        width: CGFloat,
        heroHeight: CGFloat?,
        trailingHeight: CGFloat?,
        sitrepHeight: CGFloat?,
        leadingFraction: CGFloat = 2.0 / 3.0,
        minimumWidth: CGFloat = defaultMinimumWidth,
        spacing: CGFloat = AppLayout.cardGap
    ) -> ModuleFrames {
        if width >= minimumWidth, let trailingHeight, heroHeight != nil || sitrepHeight != nil {
            let leadingWidth = ((width - spacing) * leadingFraction).rounded()
            let trailingWidth = width - spacing - leadingWidth

            var leftY: CGFloat = 0
            var heroFrame: CGRect?
            if let heroHeight {
                heroFrame = CGRect(x: 0, y: leftY, width: leadingWidth, height: heroHeight)
                leftY += heroHeight + spacing
            }

            var sitrepFrame: CGRect?
            if let sitrepHeight {
                sitrepFrame = CGRect(x: 0, y: leftY, width: leadingWidth, height: sitrepHeight)
            }

            let trailingFrame = CGRect(x: leadingWidth + spacing, y: 0, width: trailingWidth, height: trailingHeight)
            return ModuleFrames(hero: heroFrame, trailing: trailingFrame, sitrep: sitrepFrame)
        }

        var y: CGFloat = 0
        var heroFrame: CGRect?
        if let heroHeight {
            heroFrame = CGRect(x: 0, y: y, width: width, height: heroHeight)
            y += heroHeight + spacing
        }

        var trailingFrame: CGRect?
        if let trailingHeight {
            trailingFrame = CGRect(x: 0, y: y, width: width, height: trailingHeight)
            y += trailingHeight + spacing
        }

        var sitrepFrame: CGRect?
        if let sitrepHeight {
            sitrepFrame = CGRect(x: 0, y: y, width: width, height: sitrepHeight)
            y += sitrepHeight + spacing
        }

        return ModuleFrames(hero: heroFrame, trailing: trailingFrame, sitrep: sitrepFrame)
    }

    /// Each subview's frame by its `BriefingSituationalRole`, with heights measured at the column widths; a subview
    /// whose role a later subview repeats gets a zero frame.
    func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var heroIndex: Int?
        var trailingIndex: Int?
        var sitrepIndex: Int?

        for (index, subview) in subviews.enumerated() {
            switch subview[BriefingSituationalRole.self] {
            case .hero: heroIndex = index
            case .trailing: trailingIndex = index
            case .sitrep: sitrepIndex = index
            }
        }

        let leadingWidth = ((width - spacing) * leadingFraction).rounded()
        // A lone trailing module has no leading column to sit beside, so it takes the full width.
        let isWide = width >= minimumWidth && trailingIndex != nil && (heroIndex != nil || sitrepIndex != nil)
        let targetLeftWidth = isWide ? leadingWidth : width
        let targetTrailingWidth = isWide ? (width - spacing - leadingWidth) : width

        let heroHeight = heroIndex.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: targetLeftWidth, height: nil)).height
        }
        let trailingHeight = trailingIndex.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: targetTrailingWidth, height: nil)).height
        }
        let sitrepHeight = sitrepIndex.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: targetLeftWidth, height: nil)).height
        }

        let computed = Self.computeFrames(
            width: width,
            heroHeight: heroHeight,
            trailingHeight: trailingHeight,
            sitrepHeight: sitrepHeight,
            leadingFraction: leadingFraction,
            minimumWidth: minimumWidth,
            spacing: spacing
        )

        var result = Array(repeating: CGRect.zero, count: subviews.count)
        if let heroIndex, let f = computed.hero { result[heroIndex] = f }
        if let trailingIndex, let f = computed.trailing { result[trailingIndex] = f }
        if let sitrepIndex, let f = computed.sitrep { result[sitrepIndex] = f }
        return result
    }
}
