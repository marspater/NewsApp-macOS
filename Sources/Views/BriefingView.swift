// Sources/Views/BriefingView.swift
// Epic R (#608) — Briefing Redesign as a Situation Board
// Strict conformance to docs/DESIGN.md (§8.4, §13, §16, §17, §18)

import AppKit
import Charts
import Foundation
import SwiftUI

// MARK: - Actions

/// Action callback bundle for user interactions within the Situation Board.
struct BriefingActions {
    /// Callback invoked to open a story article.
    let onOpenArticle: (FeedArticle) -> Void
    /// Callback invoked to open an event overview.
    let onOpenEvent: (EventFeedSummary) -> Void
    /// Callback invoked to request generation of a fresh daily briefing.
    let onStartNewBriefing: () -> Void
    /// Callback invoked to navigate back to the Today timeline.
    let onBackToToday: () -> Void

    init(
        onOpenArticle: @escaping (FeedArticle) -> Void,
        onOpenEvent: @escaping (EventFeedSummary) -> Void,
        onStartNewBriefing: @escaping () -> Void,
        onBackToToday: @escaping () -> Void
    ) {
        self.onOpenArticle = onOpenArticle
        self.onOpenEvent = onOpenEvent
        self.onStartNewBriefing = onStartNewBriefing
        self.onBackToToday = onBackToToday
    }
}

// MARK: - Hero Carousel Component

/// Hero carousel component displaying the top 3 to 5 ranked daily stories with a 45-second auto-advance cycle.
struct BriefingHeroCarouselView: View {
    let stories: [FeedArticle]
    let clock: any CarouselClock
    var isReaderOpen: Bool = false
    let onOpenStory: (FeedArticle) -> Void

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var activeIndex: Int = 0
    @State private var isHovered: Bool = false
    @FocusState private var isCarouselFocused: Bool
    @State private var timerResetToken: Int = 0

    private static let autoAdvanceInterval: Double = 45.0
    private static let transitionDuration: Double = 0.6

    init(
        stories: [FeedArticle],
        clock: any CarouselClock,
        isReaderOpen: Bool = false,
        onOpenStory: @escaping (FeedArticle) -> Void
    ) {
        self.stories = stories
        self.clock = clock
        self.isReaderOpen = isReaderOpen
        self.onOpenStory = onOpenStory
    }

    private var shouldTimerRun: Bool {
        !reduceMotion && !isHovered && !isCarouselFocused && !isReaderOpen && stories.count > 1
    }

    private var timerReloadKey: String {
        "\(shouldTimerRun)-\(timerResetToken)-\(stories.count)"
    }

    var body: some View {
        ZStack {
            if let current = currentStory {
                Button {
                    onOpenStory(current)
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        carouselBackground(current)
                        carouselOverlay(current)
                    }
                    .frame(height: AppLayout.leadStoryHeight)
                    .frame(maxWidth: AppLayout.listMaxWidth)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppColor.surface)
                    .frame(height: AppLayout.leadStoryHeight)
            }
        }
        .onHover { isHovered = $0 }
        .focused($isCarouselFocused)
        .onChange(of: reduceMotion) { _, newValue in
            if newValue { activeIndex = 0 }
        }
        .task(id: timerReloadKey) {
            guard shouldTimerRun else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(seconds: Self.autoAdvanceInterval)
                    guard !Task.isCancelled, shouldTimerRun else { break }
                    withAnimation(reduceMotion ? nil : .smooth(duration: Self.transitionDuration)) {
                        activeIndex = (activeIndex + 1) % max(1, stories.count)
                    }
                } catch {
                    break
                }
            }
        }
    }

    private var currentStory: FeedArticle? {
        guard !stories.isEmpty else { return nil }
        let index = max(0, min(activeIndex, stories.count - 1))
        return stories[index]
    }

    @ViewBuilder
    private func carouselBackground(_ story: FeedArticle) -> some View {
        AppColor.leadPlaceholder
            .overlay(AppColor.leadScrim)
    }

    @ViewBuilder
    private func carouselOverlay(_ story: FeedArticle) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            EyebrowText(story.publisherName, color: AppColor.leadSecondaryText)
            Text(story.title)
                .font(AppTypography.headline)
                .foregroundStyle(AppColor.leadText)
                .lineLimit(2)
        }
        .padding(AppSpacing.lg)
    }
}

// MARK: - Story Tiles Grid Component

/// Responsive grid component arranging dense story tiles across adaptive columns.
struct BriefingTileGridView: View {
    let entries: [FeedEntry]
    let onOpenArticle: (FeedArticle) -> Void
    let onOpenEvent: (EventFeedSummary) -> Void

    init(
        entries: [FeedEntry],
        onOpenArticle: @escaping (FeedArticle) -> Void,
        onOpenEvent: @escaping (EventFeedSummary) -> Void
    ) {
        self.entries = entries
        self.onOpenArticle = onOpenArticle
        self.onOpenEvent = onOpenEvent
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: AppLayout.gridColumnMinimum, maximum: AppLayout.gridColumnMaximum),
                    spacing: AppLayout.cardGap
                )
            ],
            spacing: AppLayout.cardGap
        ) {
            ForEach(entries, id: \.id) { entry in
                let summary: EventFeedSummary? = {
                    switch entry {
                    case .article: return nil
                    case .event(let s, _, _): return s
                    }
                }()
                BriefingTileView(
                    article: entry.representative,
                    eventSummary: summary,
                    citedFact: nil,
                    onOpen: {
                        switch entry {
                        case .article(let article):
                            onOpenArticle(article)
                        case .event(let summary, _, _):
                            onOpenEvent(summary)
                        }
                    }
                )
            }
        }
    }
}

// MARK: - Root Briefing Situation Board Shell

/// Root Situation Board view presenting the finite daily Briefing (Epic R).
///
/// Features a prominent 45-second auto-advancing hero carousel, a live World Tension strip with 7-day
/// sparkline trend, and dense categorized story tiles with cited highlights.
struct BriefingView: View {
    let entries: [FeedEntry]
    let briefing: FiniteBriefing?
    /// The World Tension state the sidebar and the sheet show (#781).
    let tension: WorldTensionState
    let clock: any CarouselClock
    let actions: BriefingActions

    init(
        entries: [FeedEntry],
        briefing: FiniteBriefing?,
        tension: WorldTensionState,
        clock: any CarouselClock = ContinuousCarouselClock(),
        actions: BriefingActions
    ) {
        self.entries = entries
        self.briefing = briefing
        self.tension = tension
        self.clock = clock
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // Carousel
                let carouselStories = entries.map(\.representative).prefix(5)
                if !carouselStories.isEmpty {
                    BriefingHeroCarouselView(
                        stories: Array(carouselStories),
                        clock: clock,
                        onOpenStory: actions.onOpenArticle
                    )
                }

                // Tension Strip
                BriefingTensionStripView(state: tension)

                // Tiles Grid
                BriefingTileGridView(
                    entries: entries,
                    onOpenArticle: actions.onOpenArticle,
                    onOpenEvent: actions.onOpenEvent
                )
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.vertical, AppSpacing.lg)
            .frame(maxWidth: AppLayout.listMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
