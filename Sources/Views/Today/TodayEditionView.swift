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

import SwiftUI

/// What the Today page asks of the list that hosts it.
struct TodayEditionActions {
    var open: (FeedEntry) -> Void
    /// A card scrolled into view, for the lane's image prefetch.
    var cardAppeared: (String) -> Void = { _ in
        // No prefetch by default.
    }
    /// The Latest's grid changed how many cards a row holds, which the keyboard map needs.
    var latestColumnsChanged: (Int) -> Void = { _ in
        // No keyboard map by default.
    }
    /// The reader scrolled a lane's row or paged it with its buttons.
    var laneMovedByReader: () -> Void = {
        // Nothing depends on it by default.
    }
    /// A lane's row scrolled: the card at its leading edge, which an arrow key entering the lane lands on.
    var leadingCardChanged: (TodayLane, String?) -> Void = { _, _ in
        // No keyboard map by default.
    }
    /// The reader moved The Lead to another slide with its dots or arrows.
    var leadSlideShown: (FeedEntry) -> Void = { _ in
        // No lane memory by default.
    }
}

/// The Today edition (docs/design/today.md; #935, #936): The Lead, the conditional lanes as horizontal rows, and
/// The Latest as a grid of Compact cards or, in the list layout, the list's own cards. The hosting list owns the
/// vertical scroll view, the masthead, keyboard focus and the update buffer.
struct TodayEditionView<LatestListCard: View>: View {
    let edition: TodayEdition
    var focusedID: String?
    var readIDs: Set<String> = []
    /// The detail column's size, which sizes The Lead.
    var columnSize: CGSize
    var gridLayout = true
    /// A story or sheet is open: The Lead holds still.
    var isMotionPaused = false
    var clock: any CarouselClock = ContinuousCarouselClock()
    let actions: TodayEditionActions
    /// The list layout's card for a story of The Latest.
    @ViewBuilder let latestListCard: (FeedEntry) -> LatestListCard

    @Namespace private var lanesRotor

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            if !edition.lead.isEmpty { lead }
            ForEach(edition.conditionalLanes) { lane in
                TodayLaneSection(
                    lane: lane, metadata: edition.metadata, focusedID: focusedID, generation: edition.generation,
                    actions: actions
                )
                .accessibilityRotorEntry(id: lane.lane, in: lanesRotor)
            }
            if !edition.latest.isEmpty { latest }
        }
        .padding(.bottom, AppSpacing.xl)
        .accessibilityRotor("Lanes") {
            ForEach(edition.lanes) { lane in
                AccessibilityRotorEntry(Text(lane.lane.rawValue), id: lane.lane, in: lanesRotor)
            }
        }
    }

    // MARK: - The Lead

    private var lead: some View {
        let stories = edition.lead
        return BriefingHeroCarouselView(
            entries: stories.map(\.entry),
            // The photo each slide shows is the one the photo rule, the prefetch and the lane cards use: the story's
            // listed reports first, then its event's (a restored edition's stored event photo would otherwise win).
            images: Dictionary(
                stories.compactMap { story in edition.imageURL(of: story).map { (story.id, $0) } },
                uniquingKeysWith: { first, _ in first }),
            readIDs: readIDs,
            clock: clock,
            isReaderOpen: isMotionPaused,
            lead: LeadPresentation(
                // ponytail: sized by the detail column, which is the window less the toolbar and the sidebar; read
                // the window itself if The Lead should not grow when the sidebar closes.
                height: AppLayout.leadHeight(windowHeight: columnSize.height),
                windowWidth: columnSize.width,
                metadata: edition.metadata,
                developingIDs: Set(stories.filter(\.isDeveloping).map(\.id)),
                focusedID: stories.contains { $0.id == focusedID } ? focusedID : nil),
            onShow: actions.leadSlideShown,
            onOpen: actions.open
        )
        .id(TodayEditionView.leadScrollID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TodayLane.theLead.rawValue). \(TodayLane.theLead.subtitle)")
        .accessibilityRotorEntry(id: TodayLane.theLead, in: lanesRotor)
    }

    /// The Lead's place in the page's scroll view; its slides share it.
    static var leadScrollID: String { "today-lead" }

    // MARK: - The Latest

    private var latest: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            TodayLaneHeader(lane: .theLatest)
            if gridLayout {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: AppLayout.compactColumnMinimum, maximum: AppLayout.gridColumnMaximum),
                            spacing: AppLayout.cardGap, alignment: .top)
                    ],
                    spacing: AppLayout.cardGap
                ) {
                    ForEach(edition.latest) { story in
                        TodayStoryCard(
                            story: story, metadata: edition.metadata[story.id] ?? StoryCardMetadata(),
                            variant: .compact, isFocused: story.id == focusedID, actions: actions)
                    }
                }
                .onGeometryChange(for: Int.self) { proxy in
                    AppLayout.gridColumnCount(width: proxy.size.width, minimum: AppLayout.compactColumnMinimum)
                } action: { columns in
                    actions.latestColumnsChanged(columns)
                }
            } else {
                LazyVStack(spacing: AppLayout.cardGap) {
                    ForEach(edition.latest) { story in latestListCard(story.entry) }
                }
                .frame(maxWidth: AppLayout.listMaxWidth)
                .frame(maxWidth: .infinity)
                .onAppear { actions.latestColumnsChanged(1) }
            }
        }
        .padding(.horizontal, AppLayout.pageInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TodayLane.theLatest.rawValue). \(TodayLane.theLatest.subtitle)")
        .accessibilityRotorEntry(id: TodayLane.theLatest, in: lanesRotor)
    }
}

extension TodayEditionView where LatestListCard == EmptyView {
    /// The grid-only page, for captures and previews.
    init(
        edition: TodayEdition, focusedID: String? = nil, readIDs: Set<String> = [], columnSize: CGSize,
        isMotionPaused: Bool = false, clock: any CarouselClock = ContinuousCarouselClock(),
        actions: TodayEditionActions
    ) {
        self.init(
            edition: edition, focusedID: focusedID, readIDs: readIDs, columnSize: columnSize, gridLayout: true,
            isMotionPaused: isMotionPaused, clock: clock, actions: actions, latestListCard: { _ in EmptyView() })
    }
}

/// A lane's name and its one-line description, with no count (docs/design/today.md, "Honesty").
struct TodayLaneHeader<Trailing: View>: View {
    let lane: TodayLane
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: AppSpacing.xs) {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                Text(lane.rawValue)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(lane.subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Spacer(minLength: AppSpacing.xs)
            trailing
        }
    }
}

extension TodayLaneHeader where Trailing == EmptyView {
    init(lane: TodayLane) {
        self.init(lane: lane) { EmptyView() }
    }
}

/// One conditional lane: its header and a horizontal row of cards that pass under the floating sidebar.
struct TodayLaneSection: View {
    let lane: TodayEdition.Lane
    let metadata: [String: StoryCardMetadata]
    var focusedID: String?
    var generation: Int
    let actions: TodayEditionActions

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    /// Where the row is scrolled to and how far it can go, read from the row itself so the header's buttons follow
    /// a trackpad or keyboard scroll too.
    @State private var scrollX: CGFloat = 0
    @State private var scrollMax: CGFloat = 0
    /// The row's own scroll offset, which the header's buttons set. A scroll reader's `scrollTo` moved the page
    /// instead of the row, and an id-bound position with view-aligned snapping did not move the row at all (live
    /// pass, 11 November 2026).
    @State private var rowPosition = ScrollPosition(edge: .leading)
    /// The height of the row's tallest card, so every card of the row ends level.
    @State private var rowHeight: CGFloat?

    private var ids: [String] { lane.stories.map(\.id) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                TodayLaneHeader(lane: lane.lane) {
                    pageButton("chevron.left", label: "Earlier in \(lane.lane.rawValue)", offset: -1)
                    pageButton("chevron.right", label: "More in \(lane.lane.rawValue)", offset: 1)
                }
                .padding(.horizontal, AppLayout.pageInset)
                row
                    // Keyboard focus moved to a card of this row: scroll only as far as showing it needs.
                    .onChange(of: focusedID) { _, focused in
                        guard let focused, ids.contains(focused) else { return }
                        withAnimation(reduceMotion ? nil : AppMotion.hover) { proxy.scrollTo(focused) }
                    }
                    // A lane that appears holding the focused card (an applied update moved it there) shows it.
                    .onAppear {
                        guard let focusedID, ids.contains(focusedID) else { return }
                        proxy.scrollTo(focusedID)
                    }
                    // The reader applied an update: the row shows the focused card when it still holds it, and
                    // otherwise returns to its leading edge.
                    .onChange(of: generation) { _, _ in
                        let kept = focusedID.flatMap { ids.contains($0) ? $0 : nil }
                        guard let target = kept ?? ids.first else { return }
                        withAnimation(reduceMotion ? nil : AppMotion.hover) {
                            if kept == nil {
                                rowPosition.scrollTo(edge: .leading)
                            } else {
                                proxy.scrollTo(target)
                            }
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.lane.rawValue). \(lane.lane.subtitle)")
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: AppLayout.cardGap) {
                ForEach(lane.stories) { story in
                    TodayStoryCard(
                        story: story, metadata: metadata[story.id] ?? StoryCardMetadata(),
                        variant: story.cardVariant, isFocused: story.id == focusedID, actions: actions
                    )
                    .frame(height: rowHeight)
                }
            }
            // Room for the hover lift and the focus ring, which would otherwise be cut at the row's edge, and the
            // page inset the cards scroll through on their way under the sidebar.
            .padding(.vertical, AppSpacing.xs)
            .padding(.horizontal, AppLayout.pageInset)
        }
        // The row is as tall as its tallest card; a lazy row would otherwise take the height of its first cards.
        .frame(height: rowHeight.map { $0 + AppSpacing.xs * 2 })
        .scrollPosition($rowPosition)
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.x
        } action: { _, offset in
            scrollX = offset
            // The card at the leading edge, for an arrow key entering the lane.
            let leading = Int((offset / cardStep).rounded())
            actions.leadingCardChanged(lane.lane, ids.indices.contains(leading) ? ids[leading] : nil)
        }
        .onScrollGeometryChange(for: CGFloat.self) {
            max(0, $0.contentSize.width - $0.containerSize.width)
        } action: { _, maximum in
            scrollMax = maximum
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { actions.laneMovedByReader() }
        }
        .scrollIndicators(.hidden)
        .modifier(UnderSidebarRow())
        .background(alignment: .topLeading) { heightProbe }
    }

    /// The row's tallest card, laid out unseen: a card's height depends on its variant and on which footer parts
    /// its metadata fills, never on the length of its text, so one probe per kind of card measures the row.
    private var heightProbe: some View {
        ZStack(alignment: .topLeading) {
            // Bare cards with no scroll id: a second view with a story's id would be a target for `scrollTo`.
            ForEach(probes, id: \.id) { story in
                ArticleCardView(
                    article: story.entry.representative, variant: story.cardVariant,
                    metadata: metadata[story.id] ?? StoryCardMetadata(),
                    action: {
                        // Probe only: it is measured, never clicked.
                    }, footer: EmptyView()
                )
                .frame(width: story.cardVariant.laneWidth)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            rowHeight = $0
        }
    }

    /// One story per distinct footer the row's cards can have; of those with the same footer, the one with the
    /// longest differing account, which sets the height of the row's tallest such card.
    private var probes: [TodayStoryAssignment] {
        var order: [String] = []
        var longest: [String: TodayStoryAssignment] = [:]
        for story in lane.stories {
            let data = metadata[story.id] ?? StoryCardMetadata()
            let key =
                "\(story.cardVariant):\((data.reportDays ?? 0) >= 3):\(data.differingAccount != nil):"
                + "\(data.coverageLine != nil):\(data.contentType != nil)"
            let length = data.differingAccount?.count ?? 0
            if let kept = longest[key] {
                if length > (metadata[kept.id]?.differingAccount?.count ?? 0) { longest[key] = story }
            } else {
                order.append(key)
                longest[key] = story
            }
        }
        return order.compactMap { longest[$0] }
    }

    /// The distance between two cards' leading edges.
    private var cardStep: CGFloat {
        (lane.stories.first?.cardVariant.laneWidth ?? AppLayout.laneCardWidth) + AppLayout.cardGap
    }

    /// Moves the row by two cards from where it is scrolled to now; the row itself scrolls freely with the trackpad.
    private func pageButton(_ symbol: String, label: String, offset: Int) -> some View {
        let step = cardStep
        let index = (scrollX / step).rounded()
        let target = max(0, min(scrollMax, (index + CGFloat(offset * 2)) * step))
        return Button {
            actions.laneMovedByReader()
            withAnimation(reduceMotion ? nil : AppMotion.navigation) {
                rowPosition.scrollTo(x: target)
            }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(abs(target - scrollX) < 1)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Cards pass under the floating glass sidebar on macOS 26 and later instead of being cut at the column's edge;
/// macOS 15 clips them there.
private struct UnderSidebarRow: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

/// One story of a lane as the lane's card. The whole card is one button that opens the story.
struct TodayStoryCard: View {
    let story: TodayStoryAssignment
    let metadata: StoryCardMetadata
    let variant: StoryCardVariant
    let isFocused: Bool
    let actions: TodayEditionActions

    var body: some View {
        let entry = story.entry
        ArticleCardView(
            article: entry.representative, isSelected: isFocused,
            imageFallbacks: entry.visibleArticles.filter { $0.id != entry.representative.id },
            variant: variant, metadata: metadata, action: { actions.open(entry) }, footer: EmptyView()
        )
        .equatable()
        .frame(width: variant.laneWidth)
        .id(story.id)
        .onAppear { actions.cardAppeared(story.id) }
    }
}
