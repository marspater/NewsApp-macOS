// Sources/Views/BriefingView.swift
// Epic R (#608) — Briefing Redesign as a Situation Board
// Strict conformance to docs/DESIGN.md (§8.4, §13, §16, §17, §18)

import AppKit
import Charts
import Foundation
import SwiftUI

// MARK: - Carousel Clock Protocol & Implementations

public protocol CarouselClock: Sendable {
    func sleep(seconds: Double) async throws
}

public struct ContinuousCarouselClock: CarouselClock {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Briefing Cited Fact Model & Extractor

public struct BriefingCitedFact: Sendable, Hashable {
    public let text: String
    public let isCited: Bool
    public let citationPublisher: String?

    public init(text: String, isCited: Bool, citationPublisher: String? = nil) {
        self.text = text
        self.isCited = isCited
        self.citationPublisher = citationPublisher
    }
}

enum BriefingFactExtractor {
    /// Deterministically extracts the primary cited highlight fact or falls back to segmented summary/dek.
    static func extractFact(
        from overview: EventOverviewDocument?,
        fallbackArticle: FeedArticle
    ) -> BriefingCitedFact {
        // 1. Overview facts: first fact is the top-ranked highlight
        if let fact = overview?.facts.first,
            !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let trimmedText = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var publisherName: String? = nil
            if let firstCitID = fact.citationIDs.first, let citation = overview?.citations[firstCitID] {
                publisherName = citation.sourceName ?? citation.sourceTitle
            }
            if publisherName == nil || publisherName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                publisherName = fallbackArticle.source
            }
            return BriefingCitedFact(
                text: trimmedText,
                isCited: true,
                citationPublisher: publisherName
            )
        }

        // 2. Fallback candidate from overview summary, article aiSummary, or article description
        let rawCandidate =
            (overview?.summary.isEmpty == false ? overview?.summary : nil)
            ?? fallbackArticle.aiSummary
            ?? fallbackArticle.description

        let cleaned = FeedXMLParser.stripHTMLSimple(rawCandidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return BriefingCitedFact(text: "", isCited: false, citationPublisher: nil)
        }

        // 3. Segment sentences with abbreviation protection
        let ranges = PassageFactExtractor.segmentedSentences(in: cleaned)
        let firstSentence: String
        if let firstRange = ranges.first {
            firstSentence = String(cleaned[firstRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            firstSentence = cleaned
        }

        return BriefingCitedFact(
            text: firstSentence,
            isCited: false,
            citationPublisher: nil
        )
    }

    /// Asynchronously resolves the fact for a FeedEntry using ArticleStore.
    static func extractFact(
        for entry: FeedEntry,
        store: ArticleStore
    ) async -> BriefingCitedFact {
        let overview: EventOverviewDocument?
        switch entry {
        case .event(let summary, let rep, _):
            if let doc = try? await store.fetchEventOverview(eventID: summary.eventID) {
                overview = doc
            } else {
                overview = try? await store.fetchEventOverview(forArticleID: rep.id)
            }
        case .article(let article):
            overview = try? await store.fetchEventOverview(forArticleID: article.id)
        }
        return extractFact(from: overview, fallbackArticle: entry.representative)
    }
}

// MARK: - World Tension Strip Component

struct BriefingTensionStripView: View {
    let reading: WorldTensionReading?
    let history: [WorldTensionReading]
    var onOpenHeadline: ((WorldTensionHeadline) -> Void)? = nil

    @Environment(\.effectiveContrast) private var contrast

    private static let driverMinWidthWide: CGFloat = 280
    private static let driverMinWidthCompact: CGFloat = 260

    init(
        reading: WorldTensionReading?,
        history: [WorldTensionReading],
        onOpenHeadline: ((WorldTensionHeadline) -> Void)? = nil
    ) {
        self.reading = reading
        self.history = history
        self.onOpenHeadline = onOpenHeadline
    }

    var body: some View {
        if let reading {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                // Top Row: Score + Level + 7-Day Sparkline
                HStack(alignment: .center) {
                    scoreHeader(reading)
                    Spacer(minLength: AppSpacing.md)
                    trendSparkline(reading)
                }

                Divider()

                // Drivers Row: Key Drivers Grid
                driversSection(reading)
            }
            .padding(AppSpacing.md)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(
                        AppColor.border(for: contrast),
                        lineWidth: contrast == .increased ? AppLayout.hoverStroke : AppLayout.hairline
                    )
            )
            .shadow(
                color: AppShadow.cardRestingColor,
                radius: AppShadow.cardRestingRadius,
                x: 0,
                y: AppShadow.cardRestingY
            )
        } else {
            NoticeView {
                Label(
                    "World Tension assessment unavailable. Enable on-device AI and panel collection in Settings.",
                    systemImage: "globe"
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
            }
        }
    }

    private func scoreHeader(_ reading: WorldTensionReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text("\(reading.assessment.score)")
                .font(AppTypography.tensionReading)
                .monospacedDigit()
                .foregroundStyle(AppColor.primaryText)

            Text("°")
                .font(AppTypography.headline)
                .foregroundStyle(AppColor.secondaryText)

            Label {
                Text(reading.level.rawValue)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(AppColor.primaryText)
            } icon: {
                Image(systemName: "circle.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tension(reading.level))
            }

            if reading.assessment.isEstimate == true {
                TagView(title: "Keyword estimate", tint: AppColor.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("World tension \(reading.assessment.score) degrees, \(reading.level.rawValue)")
    }

    private func trendSparkline(_ reading: WorldTensionReading) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            EyebrowText("7-DAY TREND")

            BriefingTensionSparklineView(
                history: history,
                currentReading: reading
            )
        }
    }

    private func driversSection(_ reading: WorldTensionReading) -> some View {
        let drivers = Array(reading.drivingHeadlines.prefix(3))
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            EyebrowText("KEY DRIVERS")

            ViewThatFits(in: .horizontal) {
                // Wide (>= 1100 pt): 3 columns
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    ForEach(drivers, id: \.id) { driver in
                        driverCard(driver)
                            .frame(minWidth: Self.driverMinWidthWide, maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Compact (900–1099 pt): 2 columns
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: AppSpacing.sm),
                        GridItem(.flexible(), spacing: AppSpacing.sm),
                    ],
                    spacing: AppSpacing.sm
                ) {
                    ForEach(drivers, id: \.id) { driver in
                        driverCard(driver)
                            .frame(minWidth: Self.driverMinWidthCompact, maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Narrow (< 900 pt): 1 column
                VStack(spacing: AppSpacing.xs) {
                    ForEach(drivers, id: \.id) { driver in
                        driverCard(driver)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func driverCard(_ driver: WorldTensionHeadline) -> some View {
        Button {
            onOpenHeadline?(driver)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                EyebrowText(driver.publisher)
                Text(driver.title)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.xs)
            .background(
                AppColor.elevatedSurface,
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

struct BriefingTensionSparklineView: View {
    let history: [WorldTensionReading]
    let currentReading: WorldTensionReading?

    private static let chartWidth: CGFloat = 140
    private static let chartHeight: CGFloat = 36

    init(history: [WorldTensionReading], currentReading: WorldTensionReading?) {
        self.history = history
        self.currentReading = currentReading
    }

    private var recentHistory: [WorldTensionReading] {
        Array(history.suffix(7))
    }

    var body: some View {
        Group {
            if recentHistory.count >= 2 {
                Chart {
                    ForEach(recentHistory) { item in
                        LineMark(
                            x: .value("Day", item.evaluatedAt),
                            y: .value("Score", item.assessment.score)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(AppColor.secondaryText)

                        PointMark(
                            x: .value("Day", item.evaluatedAt),
                            y: .value("Score", item.assessment.score)
                        )
                        .foregroundStyle(AppColor.tension(item.level))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            } else if let reading = currentReading {
                Chart {
                    RuleMark(y: .value("Baseline", reading.assessment.score))
                        .foregroundStyle(AppColor.borderSubtle)
                        .lineStyle(StrokeStyle(lineWidth: AppLayout.hairline, dash: [4, 4]))

                    PointMark(
                        x: .value("Day", reading.evaluatedAt),
                        y: .value("Score", reading.assessment.score)
                    )
                    .foregroundStyle(AppColor.tension(reading.level))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            } else {
                Chart {
                    RuleMark(y: .value("Baseline", 50))
                        .foregroundStyle(AppColor.borderSubtle)
                        .lineStyle(StrokeStyle(lineWidth: AppLayout.hairline, dash: [4, 4]))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            }
        }
        .frame(width: Self.chartWidth, height: Self.chartHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("World tension seven-day trend")
    }
}

// MARK: - Dense Story Tile Component

struct BriefingTileView: View {
    let article: FeedArticle
    let eventSummary: EventFeedSummary?
    let citedFact: BriefingCitedFact?
    let isSelected: Bool
    let isRead: Bool
    let isSaved: Bool
    let onOpen: () -> Void
    var onToggleRead: () -> Void = {}
    var onToggleSave: () -> Void = {}

    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        article: FeedArticle,
        eventSummary: EventFeedSummary?,
        citedFact: BriefingCitedFact?,
        isSelected: Bool,
        isRead: Bool,
        isSaved: Bool,
        onOpen: @escaping () -> Void,
        onToggleRead: @escaping () -> Void = {},
        onToggleSave: @escaping () -> Void = {}
    ) {
        self.article = article
        self.eventSummary = eventSummary
        self.citedFact = citedFact
        self.isSelected = isSelected
        self.isRead = isRead
        self.isSaved = isSaved
        self.onOpen = onOpen
        self.onToggleRead = onToggleRead
        self.onToggleSave = onToggleSave
    }

    private var appearance: (border: Color, width: CGFloat, shadow: Color, radius: CGFloat, y: CGFloat) {
        if isSelected {
            return (
                AppColor.accent, AppLayout.focusStroke, AppShadow.cardFocusRingColor, AppShadow.cardFocusRingRadius,
                AppShadow.cardFocusRingY
            )
        }
        if isHovered {
            return (
                AppColor.hoverBorder, AppLayout.hoverStroke, AppShadow.cardHoverColor, AppShadow.cardHoverRadius,
                AppShadow.cardHoverY
            )
        }
        return (
            AppColor.border(for: contrast),
            contrast == .increased ? AppLayout.hoverStroke : AppLayout.hairline,
            AppShadow.cardRestingColor, AppShadow.cardRestingRadius,
            AppShadow.cardRestingY
        )
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                eyebrowRow
                headlineRow
                factOrSummaryView
                Spacer(minLength: AppSpacing.xxs)
                footerRow
            }
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(appearance.border, lineWidth: appearance.width)
        )
        .shadow(color: appearance.shadow, radius: appearance.radius, x: 0, y: appearance.y)
        .animation(reduceMotion ? nil : AppMotion.hover, value: isHovered)
        .animation(reduceMotion ? nil : AppMotion.state, value: isSelected)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAction(named: isRead ? "Mark as Unread" : "Mark as Read") { onToggleRead() }
        .accessibilityAction(named: isSaved ? "Remove from Saved" : "Save Story") { onToggleSave() }
    }

    @ViewBuilder
    private var eyebrowRow: some View {
        HStack(spacing: AppSpacing.eyebrowGap) {
            EyebrowText(article.publisherName)
            Text("·")
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.tertiaryText(for: contrast))
            Text(article.cardDateText())
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.tertiaryText(for: contrast))
                .monospacedDigit()
            Spacer()
            if !isRead {
                UnreadDot()
            }
        }
    }

    @ViewBuilder
    private var headlineRow: some View {
        Text(article.title)
            .font(AppTypography.headline)
            .foregroundStyle(isRead ? AppColor.secondaryText : AppColor.primaryText)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: AppSpacing.xs) {
            let publisherCount = eventSummary?.members.count ?? 1
            if publisherCount > 1 {
                TagView(title: "\(publisherCount) publishers", systemImage: "square.stack.3d.up")
            }
            Spacer()
            if isSaved {
                Image(systemName: "bookmark.fill")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AppColor.accent)
                    .accessibilityLabel("Saved")
            }
        }
    }

    @ViewBuilder
    private var factOrSummaryView: some View {
        if let fact = citedFact, fact.isCited && !fact.text.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("\"\(fact.text)\"")
                    .font(AppTypography.callout.italic())
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let pub = fact.citationPublisher, !pub.isEmpty {
                    TagView(title: pub, tint: AppColor.secondaryText)
                }
            }
        } else {
            let fallback = citedFact?.text ?? article.aiSummary ?? article.description
            let clean = ArticleContentRedactor.cleanText(fallback)
            if !clean.isEmpty {
                Text(clean)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var accessibilityDescription: String {
        let readState = isRead ? "Read" : "Unread"
        let savedState = isSaved ? ", saved in your library" : ""
        var desc =
            "\(article.title), from \(article.publisherName), \(article.cardDateText()). \(readState)\(savedState)."
        if let fact = citedFact, fact.isCited && !fact.text.isEmpty {
            desc += " Quoting: \(fact.text)."
            if let pub = fact.citationPublisher, !pub.isEmpty {
                desc += " Cited by \(pub)."
            }
        }
        return desc
    }
}

// MARK: - Hero Carousel Component (Milestone 3 Stub & Architecture)

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

// MARK: - Story Tiles Grid Component (Milestone 3 Stub)

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
                    isSelected: false,
                    isRead: false,
                    isSaved: false,
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

// MARK: - Root Briefing Situation Board Shell (Milestone 3 Stub)

struct BriefingView: View {
    let entries: [FeedEntry]
    let briefing: FiniteBriefing?
    let tensionReading: WorldTensionReading?
    let tensionHistory: [WorldTensionReading]
    let clock: any CarouselClock
    let onOpenArticle: (FeedArticle) -> Void
    let onOpenEvent: (EventFeedSummary) -> Void
    let onStartNewBriefing: () -> Void
    let onBackToToday: () -> Void

    init(
        entries: [FeedEntry],
        briefing: FiniteBriefing?,
        tensionReading: WorldTensionReading?,
        tensionHistory: [WorldTensionReading],
        clock: any CarouselClock = ContinuousCarouselClock(),
        onOpenArticle: @escaping (FeedArticle) -> Void,
        onOpenEvent: @escaping (EventFeedSummary) -> Void,
        onStartNewBriefing: @escaping () -> Void,
        onBackToToday: @escaping () -> Void
    ) {
        self.entries = entries
        self.briefing = briefing
        self.tensionReading = tensionReading
        self.tensionHistory = tensionHistory
        self.clock = clock
        self.onOpenArticle = onOpenArticle
        self.onOpenEvent = onOpenEvent
        self.onStartNewBriefing = onStartNewBriefing
        self.onBackToToday = onBackToToday
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
                        onOpenStory: onOpenArticle
                    )
                }

                // Tension Strip
                BriefingTensionStripView(
                    reading: tensionReading,
                    history: tensionHistory
                )

                // Tiles Grid
                BriefingTileGridView(
                    entries: entries,
                    onOpenArticle: onOpenArticle,
                    onOpenEvent: onOpenEvent
                )
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.vertical, AppSpacing.lg)
            .frame(maxWidth: AppLayout.listMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
