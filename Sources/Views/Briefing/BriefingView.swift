// Sources/Views/Briefing/BriefingView.swift
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
        onToggleRead: @escaping (FeedArticle) -> Void = { _ in
            // Default no-op for previews and standalone usage
        },
        onToggleSave: @escaping (FeedArticle) -> Void = { _ in
            // Default no-op for previews and standalone usage
        },
        onCustomize: @escaping () -> Void = {
            // Default no-op for previews and standalone usage
        }
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

    /// The region filter with the Regions loader's map, so modules filter by resolved regions, not headlines alone.
    private var boardFilter: BriefingBoardFilter { Self.effectiveFilter(filter, layout: layout, data: data) }

    /// The filter the board applies: a region stays selected only while the Regions control that can clear it is
    /// shown and still lists that region; otherwise the board shows everything again.
    static func effectiveFilter(
        _ filter: BriefingBoardFilter, layout: BriefingLayout, data: BriefingBoardData
    ) -> BriefingBoardFilter {
        var effective = filter
        effective.regionsByEntry = data.regions?.regionsByEntry ?? [:]
        if let region = filter.region,
            !layout.isVisible(.regions) || !(data.regions?.rows.contains { $0.region == region } ?? false)
        {
            effective.region = nil
        }
        return effective
    }

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
        layout: BriefingLayout, data: BriefingBoardData, hasStories: Bool = true,
        filter: BriefingBoardFilter = BriefingBoardFilter()
    ) -> [BriefingModuleKind] {
        BriefingPillar.allCases.flatMap { pillar in
            layout.modules(in: pillar).filter { data.hasData(for: $0, hasStories: hasStories, filter: filter) }
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
        let modules = Self.visibleModules(
            layout: layout, data: data, hasStories: entries.contains(where: boardFilter.includes), filter: boardFilter)
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
        // A selection the board can no longer honour is forgotten, so it does not return with the Regions module.
        .onChange(of: boardFilter.region == nil && filter.region != nil) { _, stale in
            guard stale else { return }
            filter.region = nil
            actions.onSelectRegion(nil)
        }
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

    /// One module by its pillar, each pillar's views in their own builder.
    @ViewBuilder
    private func module(_ kind: BriefingModuleKind) -> some View {
        switch kind.pillar {
        case .situationalAwareness: situationalModule(kind)
        case .intelligenceAssessment: intelligenceModule(kind)
        case .strategicImpact: strategicModule(kind)
        case .weakSignals: weakSignalsModule(kind)
        case .forwardWatch: forwardWatchModule(kind)
        }
    }

    @ViewBuilder
    private func situationalModule(_ kind: BriefingModuleKind) -> some View {
        let actions = boardActions
        switch kind {
        case .heroCarousel:
            BriefingHeroCarouselView(
                entries: Self.heroEntries(entries.filter(boardFilter.includes)), images: data.details.images,
                readIDs: readIDs, clock: clock, isReaderOpen: isMotionPaused, onOpen: actions.open)
        case .worldTension:
            // Reads the window's World Tension model, as the sidebar does (#781).
            BriefingTensionStripView(onOpenURL: actions.onOpenURL, onCustomize: actions.onCustomize)
        case .sinceLastBriefing:
            if let value = data.sinceLast {
                BriefingSinceLastModuleView(data: value, filter: boardFilter, actions: actions)
            }
        case .executiveSitrep:
            if let value = data.sitrep { BriefingSitrepModuleView(data: value, filter: boardFilter, actions: actions) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func intelligenceModule(_ kind: BriefingModuleKind) -> some View {
        let actions = boardActions
        switch kind {
        case .priorityDevelopments:
            if let value = data.priority {
                BriefingPriorityModuleView(data: value, filter: boardFilter, actions: actions)
            }
        case .sourceFootprint:
            if let value = data.footprint {
                BriefingFootprintModuleView(data: value, filter: boardFilter, actions: actions)
            }
        case .tensionDrivers:
            if let value = data.drivers {
                BriefingDriversModuleView(data: value, filter: boardFilter, actions: actions)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func strategicModule(_ kind: BriefingModuleKind) -> some View {
        let actions = boardActions
        switch kind {
        case .industryImpact:
            if let value = data.industry {
                BriefingIndustryModuleView(data: value, filter: boardFilter, actions: actions)
            }
        case .regions:
            if let value = data.regions {
                BriefingRegionsModuleView(data: value, filter: boardFilter, actions: actions)
            }
        case .regionTiles:
            if let value = data.regions {
                BriefingRegionTilesModuleView(data: value, filter: boardFilter, actions: actions)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func weakSignalsModule(_ kind: BriefingModuleKind) -> some View {
        if kind == .weakSignals, let value = data.weakSignals {
            BriefingWeakSignalsModuleView(data: value, filter: boardFilter, actions: boardActions)
        }
    }

    @ViewBuilder
    private func forwardWatchModule(_ kind: BriefingModuleKind) -> some View {
        let actions = boardActions
        switch kind {
        case .forwardWatch:
            if let value = data.forwardWatch {
                BriefingForwardWatchModuleView(data: value, filter: boardFilter, actions: actions)
            }
        case .escalationTimeline:
            if let value = data.timeline {
                BriefingTimelineModuleView(data: value, filter: boardFilter, actions: actions)
            }
        default:
            EmptyView()
        }
    }
}
