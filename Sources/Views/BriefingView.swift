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
    /// The story's read state and saved state, from a tile's accessibility actions.
    var onToggleRead: (FeedArticle) -> Void = { _ in
        // Captures have no read state to change.
    }
    var onToggleSave: (FeedArticle) -> Void = { _ in
        // Captures have no library to save to.
    }
    /// Filters the board to a region, or clears the filter with nil (Regions module, #850).
    var onSelectRegion: (TensionMacroRegion?) -> Void = { _ in
        // The board keeps the filter itself; the list needs no word of it.
    }
    /// Opens a quoted line's publisher page. Only http(s) links open (#799).
    var onOpenURL: (URL) -> Void = { url in
        if let safe = WebLink.url(url.absoluteString) { NSWorkspace.shared.open(safe) }
    }
    /// Presents the Customize Briefing sheet.
    var onCustomize: () -> Void = {
        // Captures have no sheet to present.
    }

    init(
        onOpenArticle: @escaping (FeedArticle) -> Void,
        onOpenEvent: @escaping (EventFeedSummary) -> Void,
        onStartNewBriefing: @escaping () -> Void,
        onBackToToday: @escaping () -> Void,
        onToggleRead: @escaping (FeedArticle) -> Void = { _ in },
        onToggleSave: @escaping (FeedArticle) -> Void = { _ in },
        onCustomize: @escaping () -> Void = {}
    ) {
        self.onOpenArticle = onOpenArticle
        self.onOpenEvent = onOpenEvent
        self.onStartNewBriefing = onStartNewBriefing
        self.onBackToToday = onBackToToday
        self.onToggleRead = onToggleRead
        self.onToggleSave = onToggleSave
        self.onCustomize = onCustomize
    }

    /// An event opens its overview and a single story its reader, as their cards do (DESIGN.md 8.3).
    func open(_ entry: FeedEntry) {
        switch entry {
        case .article(let article): onOpenArticle(article)
        case .event(let summary, _, _): onOpenEvent(summary)
        }
    }
}

extension FeedEntry {
    /// Distinct publishers reporting the story: an event's coverage, or one for a single story.
    var publisherCount: Int {
        if case .event(let summary, _, _) = self { return max(1, summary.sources.count) }
        return 1
    }
}

// MARK: - Hero Carousel Component

/// The top stories of the edition, one at a time over their best image (DESIGN.md 8.4). The app's only auto-advancing
/// motion: every 45 s a slow cross-fade, paused on hover, keyboard focus and while a story or sheet is open, and never
/// under Reduce Motion, where the first story stays. Arrows and dots always work.
struct BriefingHeroCarouselView: View {
    let entries: [FeedEntry]
    /// The best image across each event's reports, by entry ID; the story's own image otherwise.
    var images: [String: URL] = [:]
    var readIDs: Set<String> = []
    let clock: any CarouselClock
    var isReaderOpen: Bool = false
    let onOpen: (FeedEntry) -> Void

    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var activeIndex: Int = 0
    @State private var isHovered: Bool = false
    @FocusState private var isCarouselFocused: Bool
    @State private var timerResetToken: Int = 0

    static let autoAdvanceInterval: Double = 45.0
    private static let crossFade = Animation.easeInOut(duration: 0.6)

    private var shouldTimerRun: Bool {
        !reduceMotion && !isHovered && !isCarouselFocused && !isReaderOpen && entries.count > 1
    }

    private var timerReloadKey: String {
        "\(shouldTimerRun)-\(timerResetToken)-\(entries.map(\.id))"
    }

    private var currentIndex: Int { max(0, min(activeIndex, entries.count - 1)) }

    var body: some View {
        ZStack {
            if entries.indices.contains(currentIndex) {
                slide(entries[currentIndex])
                    .id(entries[currentIndex].id)
                    .transition(.opacity)
            }
            if entries.count > 1 { controls }
        }
        .frame(height: AppLayout.leadStoryHeight)
        .frame(maxWidth: .infinity)
        .background(AppColor.leadPlaceholder)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(
                    isCarouselFocused ? AppColor.accent : AppColor.border(for: contrast),
                    lineWidth: isCarouselFocused ? AppLayout.focusStroke : AppLayout.hairline)
        )
        .shadow(
            color: isCarouselFocused ? AppShadow.cardFocusRingColor : AppShadow.cardRestingColor,
            radius: isCarouselFocused ? AppShadow.cardFocusRingRadius : AppShadow.cardRestingRadius, x: 0,
            y: isCarouselFocused ? AppShadow.cardFocusRingY : AppShadow.cardRestingY
        )
        .onHover { isHovered = $0 }
        // Focusable, so keyboard focus pauses the rotation and the arrow keys move between stories.
        .focusable()
        .focused($isCarouselFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .onKeyPress(.space) {
            open()
            return .handled
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue { activeIndex = 0 }
        }
        .onChange(of: entries.map(\.id)) { _, _ in activeIndex = 0 }
        .task(id: timerReloadKey) {
            guard shouldTimerRun else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(seconds: Self.autoAdvanceInterval)
                    guard !Task.isCancelled, shouldTimerRun else { break }
                    withAnimation(Self.crossFade) {
                        activeIndex = (currentIndex + 1) % max(1, entries.count)
                    }
                } catch {
                    break
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top stories")
    }

    /// A manual move: instant under Reduce Motion, and the 45 s countdown starts again.
    private func step(_ offset: Int) {
        guard entries.count > 1 else { return }
        withAnimation(reduceMotion ? nil : Self.crossFade) {
            activeIndex = (currentIndex + offset + entries.count) % entries.count
        }
        timerResetToken += 1
    }

    private func open() {
        guard entries.indices.contains(currentIndex) else { return }
        onOpen(entries[currentIndex])
    }

    /// One story: its image, the scrim and the caption, a single click target (DESIGN.md 8.2).
    private func slide(_ entry: FeedEntry) -> some View {
        let story = entry.representative
        let isRead = readIDs.contains(story.id)
        return Button {
            onOpen(entry)
        } label: {
            ZStack(alignment: .bottomLeading) {
                image(for: entry)
                AppColor.leadScrimFade
                caption(story, publishers: entry.publisherCount, isRead: isRead)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(story.title), from \(story.publisherName), \(story.cardDateText())"
                + (entry.publisherCount > 1 ? ", \(entry.publisherCount) publishers" : "")
                + (isRead ? ". Read" : ". Unread")
        )
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func image(for entry: FeedEntry) -> some View {
        if let url = images[entry.id] ?? FeedArticle.bestCardImage(in: entry.visibleArticles) {
            ArticleRemoteImage(url: url) { phase in
                if let image = phase.image {
                    LeadImageFill(image: image, aspectRatio: DecodedImageCache.aspectRatio(for: url))
                } else {
                    AppColor.leadPlaceholder
                }
            }
            .accessibilityHidden(true)
        } else {
            AppColor.leadPlaceholder
        }
    }

    private func caption(_ story: FeedArticle, publishers: Int, isRead: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.eyebrowGap) {
                EyebrowText(story.publisherName, color: AppColor.leadSecondaryText)
                Text("·").font(AppTypography.caption).foregroundStyle(AppColor.leadSecondaryText)
                Text(story.cardDateText()).font(AppTypography.caption).monospacedDigit()
                    .foregroundStyle(AppColor.leadSecondaryText)
                if !isRead { UnreadDot() }
            }
            Text(story.title)
                .font(AppTypography.leadStoryHeadline)
                .foregroundStyle(isRead ? AppColor.leadSecondaryText : AppColor.leadText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if publishers > 1 {
                TagView(
                    title: "\(publishers) publishers", systemImage: "square.stack.3d.up", tint: AppColor.leadText,
                    foreground: AppColor.leadText)
            }
        }
        .padding(.horizontal, AppSpacing.lg + AppLayout.carouselControlSize)
        .padding(.top, AppSpacing.lg)
        // Room for the dots below the caption.
        .padding(.bottom, AppSpacing.lg + (entries.count > 1 ? AppLayout.carouselDotSize : 0))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Previous and next arrows at the edges and the page dots at the foot; each is its own click target.
    private var controls: some View {
        ZStack {
            HStack {
                arrow("chevron.left", label: "Previous story") { step(-1) }
                Spacer()
                arrow("chevron.right", label: "Next story") { step(1) }
            }
            .padding(.horizontal, AppSpacing.md)
            VStack {
                Spacer()
                HStack(spacing: AppSpacing.xs) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        dot(index, entry)
                    }
                }
                .padding(.bottom, AppSpacing.md)
            }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AppTypography.headline)
                .foregroundStyle(AppColor.leadText)
                .frame(width: AppLayout.carouselControlSize, height: AppLayout.carouselControlSize)
                .background(AppColor.carouselControl, in: Circle())
                .frame(width: AppLayout.minimumHitTarget, height: AppLayout.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func dot(_ index: Int, _ entry: FeedEntry) -> some View {
        let active = index == currentIndex
        return Button {
            guard index != currentIndex else { return }
            withAnimation(reduceMotion ? nil : Self.crossFade) { activeIndex = index }
            timerResetToken += 1
        } label: {
            Capsule()
                .fill(active ? AppColor.leadText : AppColor.carouselInactiveDot)
                .frame(
                    width: active ? AppLayout.carouselActiveDotWidth : AppLayout.carouselDotSize,
                    height: AppLayout.carouselDotSize
                )
                .padding(AppSpacing.xxs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Story \(index + 1) of \(entries.count): \(entry.representative.title)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

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

// MARK: - Root Briefing board

/// The Briefing war room (DESIGN.md 8.4): the modules of `BriefingLayout`, grouped under their pillars in board order,
/// each shown only when it has something true to show; then the completion banner. It scrolls with the list's
/// masthead inside the list's own scroll view and takes plain values; the list loads them. Only the World Tension tile
/// reads the window's model.
struct BriefingView: View {
    let entries: [FeedEntry]
    let briefing: FiniteBriefing?
    /// Every module's data, read from the library by the list.
    var data = BriefingBoardData()
    var layout = BriefingLayout.default
    var readIDs: Set<String> = []
    var savedIDs: Set<String> = []
    /// The story the list's keyboard focus is on, ringed like a focused card.
    var focusedID: String?
    /// A story or a sheet is open over the board, so the carousel holds still.
    var isMotionPaused = false
    var nextEdition = Date()
    let clock: any CarouselClock
    let actions: BriefingActions

    @State private var filter = BriefingBoardFilter()

    init(
        entries: [FeedEntry],
        briefing: FiniteBriefing?,
        data: BriefingBoardData = BriefingBoardData(),
        layout: BriefingLayout = .default,
        readIDs: Set<String> = [],
        savedIDs: Set<String> = [],
        focusedID: String? = nil,
        isMotionPaused: Bool = false,
        nextEdition: Date = Date(),
        clock: any CarouselClock = ContinuousCarouselClock(),
        actions: BriefingActions
    ) {
        self.entries = entries
        self.briefing = briefing
        self.data = data
        self.layout = layout
        self.readIDs = readIDs
        self.savedIDs = savedIDs
        self.focusedID = focusedID
        self.isMotionPaused = isMotionPaused
        self.nextEdition = nextEdition
        self.clock = clock
        self.actions = actions
    }

    /// The carousel's three to five stories: the most publishers first, edition order breaking ties.
    static func heroEntries(_ entries: [FeedEntry]) -> [FeedEntry] {
        Array(
            entries.enumerated()
                .sorted {
                    $0.element.publisherCount != $1.element.publisherCount
                        ? $0.element.publisherCount > $1.element.publisherCount : $0.offset < $1.offset
                }
                .map(\.element)
                .prefix(5))
    }

    /// The tiles grouped by topic: the story's category in the app's taxonomy, sections in the order their first story
    /// appears in the edition; a story without a category joins "More Stories" at the end.
    static func sections(_ entries: [FeedEntry]) -> [BriefingSection] {
        var order: [String] = []
        var grouped: [String: [FeedEntry]] = [:]
        for entry in entries {
            let title =
                entry.representative.category.flatMap { NewsCategory.match(from: $0) }?.rawValue ?? Self.otherSection
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(entry)
        }
        let titles = order.filter { $0 != Self.otherSection } + order.filter { $0 == Self.otherSection }
        return titles.map { BriefingSection(title: $0, entries: grouped[$0] ?? []) }
    }

    static let otherSection = "More Stories"

    /// The modules the board shows, in pillar and layout order: visible in the layout and with data.
    static func visibleModules(
        layout: BriefingLayout, data: BriefingBoardData, hasStories: Bool = true
    ) -> [BriefingModuleKind] {
        BriefingPillar.allCases.flatMap { pillar in
            layout.modules(in: pillar).filter { data.hasData(for: $0, hasStories: hasStories) }
        }
    }

    /// An event that gained a report in the last hour.
    static func isDeveloping(_ entry: FeedEntry, now: Date) -> Bool {
        guard case .event(let summary, _, _) = entry, summary.isConfirmed, let latest = summary.latestDate else {
            return false
        }
        return now.timeIntervalSince(latest) <= 3600
    }

    /// The board's actions, with region selection applied to the board's own filter first.
    private var boardActions: BriefingActions {
        var board = actions
        board.onSelectRegion = { [actions] region in
            filter.region = region
            actions.onSelectRegion(region)
        }
        return board
    }

    var body: some View {
        let modules = Self.visibleModules(layout: layout, data: data, hasStories: !entries.isEmpty)
        let pillars = BriefingPillar.allCases.filter { pillar in modules.contains { $0.pillar == pillar } }
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            ForEach(pillars.filter { $0 != .weakSignals && $0 != .forwardWatch }, id: \.self) { pillar in
                pillarSection(pillar, modules: modules.filter { $0.pillar == pillar })
            }
            signalsAndWatch(modules)
            if let briefing {
                VStack(spacing: 0) {
                    Divider()
                    BriefingCompletionBanner(
                        briefing: briefing, readIDs: readIDs, nextEdition: nextEdition,
                        onBackToToday: actions.onBackToToday)
                }
            }
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.bottom, AppSpacing.xl)
        .frame(maxWidth: AppLayout.briefingMaxWidth + 2 * AppLayout.pageInset)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Weak signals and Forward watch sit side by side on a wide board, as on the canvas.
    @ViewBuilder
    private func signalsAndWatch(_ modules: [BriefingModuleKind]) -> some View {
        let signals = modules.filter { $0.pillar == .weakSignals }
        let watch = modules.filter { $0.pillar == .forwardWatch }
        if !signals.isEmpty, !watch.isEmpty {
            BriefingSplitLayout(leadingFraction: 0.5, minimumWidth: AppLayout.briefingPairMinimum) {
                pillarSection(.weakSignals, modules: signals).frame(maxHeight: .infinity, alignment: .top)
                pillarSection(.forwardWatch, modules: watch).frame(maxHeight: .infinity, alignment: .top)
            }
        } else if !signals.isEmpty {
            pillarSection(.weakSignals, modules: signals)
        } else if !watch.isEmpty {
            pillarSection(.forwardWatch, modules: watch)
        }
    }

    private func pillarSection(_ pillar: BriefingPillar, modules: [BriefingModuleKind]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            BriefingPillarHeader(pillar)
            if pillar == .situationalAwareness {
                situationalAwareness(modules)
            } else {
                flow(modules)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// As the canvas lays it out: the carousel (two thirds) beside a column with World Tension and Since your last
    /// briefing in layout order, wrapping below the carousel on a narrow board; the Executive sitrep full width below.
    @ViewBuilder
    private func situationalAwareness(_ modules: [BriefingModuleKind]) -> some View {
        let column = modules.filter { $0 == .worldTension || $0 == .sinceLastBriefing }
        VStack(alignment: .leading, spacing: AppLayout.cardGap) {
            if modules.contains(.heroCarousel), !column.isEmpty {
                BriefingSplitLayout(leadingFraction: 2.0 / 3.0, minimumWidth: AppLayout.briefingSplitMinimum) {
                    module(.heroCarousel)
                    VStack(spacing: AppLayout.cardGap) {
                        ForEach(column, id: \.self) { module($0) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            } else if modules.contains(.heroCarousel) {
                module(.heroCarousel)
            } else {
                ForEach(column, id: \.self) { module($0) }
            }
            if modules.contains(.executiveSitrep) { module(.executiveSitrep) }
        }
    }

    /// The other pillars: full-width modules take their own row; the rest share rows in a grid, in layout order.
    private func flow(_ modules: [BriefingModuleKind]) -> some View {
        var rows: [[BriefingModuleKind]] = []
        for kind in modules {
            if kind.spansFullWidth || rows.last?.first?.spansFullWidth != false {
                rows.append([kind])
            } else {
                rows[rows.count - 1].append(kind)
            }
        }
        return VStack(alignment: .leading, spacing: AppLayout.cardGap) {
            ForEach(rows, id: \.self) { row in
                if row.count == 1 {
                    module(row[0])
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: AppLayout.briefingModuleMinimum), spacing: AppLayout.cardGap,
                                alignment: .top)
                        ],
                        alignment: .leading, spacing: AppLayout.cardGap
                    ) {
                        ForEach(row, id: \.self) { module($0) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func module(_ kind: BriefingModuleKind) -> some View {
        let actions = boardActions
        switch kind {
        case .heroCarousel:
            BriefingHeroCarouselView(
                entries: Self.heroEntries(entries.filter(filter.includes)), images: data.details.images,
                readIDs: readIDs, clock: clock, isReaderOpen: isMotionPaused, onOpen: actions.open)
        case .worldTension:
            // Reads the window's World Tension model, as the sidebar does (#781).
            BriefingTensionStripView(onOpenURL: actions.onOpenURL, onCustomize: actions.onCustomize)
        case .sinceLastBriefing:
            if let value = data.sinceLast { BriefingSinceLastModuleView(data: value, filter: filter, actions: actions) }
        case .executiveSitrep:
            if let value = data.sitrep { BriefingSitrepModuleView(data: value, filter: filter, actions: actions) }
        case .priorityDevelopments:
            if let value = data.priority { BriefingPriorityModuleView(data: value, filter: filter, actions: actions) }
        case .sourceFootprint:
            if let value = data.footprint {
                BriefingFootprintModuleView(data: value, filter: filter, actions: actions)
            }
        case .tensionDrivers:
            if let value = data.drivers { BriefingDriversModuleView(data: value, filter: filter, actions: actions) }
        case .industryImpact:
            if let value = data.industry { BriefingIndustryModuleView(data: value, filter: filter, actions: actions) }
        case .regions:
            if let value = data.regions { BriefingRegionsModuleView(data: value, filter: filter, actions: actions) }
        case .regionTiles:
            if let value = data.regions {
                BriefingRegionTilesModuleView(data: value, filter: filter, actions: actions)
            }
        case .weakSignals:
            if let value = data.weakSignals {
                BriefingWeakSignalsModuleView(data: value, filter: filter, actions: actions)
            }
        case .forwardWatch:
            if let value = data.forwardWatch {
                BriefingForwardWatchModuleView(data: value, filter: filter, actions: actions)
            }
        case .escalationTimeline:
            if let value = data.timeline { BriefingTimelineModuleView(data: value, filter: filter, actions: actions) }
        }
    }
}
