// Sources/Views/BriefingComponents.swift
// Epic R (#608) — Briefing Redesign as a Situation Board
// Strict conformance to docs/DESIGN.md (§8.4, §13, §16, §17, §18)

import AppKit
import Charts
import Foundation
import SwiftUI

// MARK: - Carousel Clock Protocol & Implementations

/// Injectable timing clock abstraction for the Situation Board hero carousel.
public protocol CarouselClock: Sendable {
    /// Suspends the current task for the specified duration in seconds.
    ///
    /// - Parameter seconds: The duration to suspend.
    func sleep(seconds: Double) async throws
}

/// Standard continuous system clock implementation of ``CarouselClock``.
public struct ContinuousCarouselClock: CarouselClock {
    /// Initializes a standard continuous clock.
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

// MARK: - Story Details

/// What the board reads from the library for its stories: one cited key fact per story from stored overview highlights
/// and, for the carousel, the best image across each event's reports. The list loads it once per edition; nothing is
/// generated here or at render time.
struct BriefingStoryDetails: Equatable, Sendable {
    var facts: [String: BriefingCitedFact] = [:]
    var images: [String: URL] = [:]

    @MainActor
    static func load(for entries: [FeedEntry], heroIDs: Set<String>, store: ArticleStore) async -> Self {
        var details = Self()
        for entry in entries {
            details.facts[entry.id] = await BriefingFactExtractor.extractFact(for: entry, store: store)
            if heroIDs.contains(entry.id), case .event(let summary, let representative, let visible) = entry {
                // The edition lists one report per event; the image may come from any of its reports, as on cards.
                let members = (try? await store.storyMemberArticles(eventID: summary.eventID)) ?? []
                details.images[entry.id] = FeedArticle.bestCardImage(in: [representative] + visible + members)
            }
            if Task.isCancelled { break }
        }
        return details
    }
}

// MARK: - World Tension Strip Component

/// The Briefing's World Tension strip (DESIGN.md 8.4): the reading under the page's one intelligence label, its state
/// in the words the sidebar and the sheet use (#781), the 7-day trend and up to three driving headlines. Without a
/// reading it says why, in the same words.
struct BriefingTensionStripView: View {
    /// The window's model, so the strip cannot be handed anything but what the sidebar shows (#781).
    @Environment(WorldTensionModel.self) private var model
    private var state: WorldTensionState { model.state }

    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let reading = state.reading {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                        // The generated reading carries the board's one sparkles glyph (DESIGN.md 9).
                        IntelligenceLabel("World Tension").font(AppTypography.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(state.note ?? "Assessed on this Mac")
                            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                        scoreHeader(reading)
                    }
                    Spacer(minLength: AppSpacing.md)
                    VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                        EyebrowText("7-day trend")
                        BriefingTensionSparklineView(readings: state.trend(days: 7), baseline: reading.assessment.score)
                    }
                }
                let drivers = Array(reading.drivingHeadlines.prefix(3))
                if !drivers.isEmpty {
                    Divider()
                    driversSection(drivers)
                }
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
                Label {
                    VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                        Text("World Tension: \(state.note ?? "")").foregroundStyle(AppColor.primaryText)
                        if let explanation = state.explanation { Text(explanation) }
                    }
                } icon: {
                    Image(systemName: "globe")
                }
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func scoreHeader(_ reading: WorldTensionReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text("\(reading.assessment.score)°")
                .font(AppTypography.tensionReading)
                .monospacedDigit()
                .foregroundStyle(AppColor.primaryText)
            Label {
                Text(reading.level.rawValue)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(AppColor.primaryText)
            } icon: {
                Image(systemName: "circle.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tension(reading.level))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "World tension \(reading.assessment.score) degrees, \(reading.level.rawValue)"
                + (state.note.map { ", \($0)" } ?? ""))
    }

    /// Three columns on a wide board, two at the narrowest window, one below that.
    private func driversSection(_ drivers: [WorldTensionHeadline]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            EyebrowText("Key drivers")
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: AppLayout.tensionDriverMinimum), spacing: AppSpacing.md, alignment: .top)
                ],
                alignment: .leading,
                spacing: AppSpacing.sm
            ) {
                ForEach(drivers, id: \.id) { driver in
                    driverCell(driver)
                }
            }
        }
    }

    /// A driving headline opens its story in the browser, as in the sheet; panel stories need not be in the library.
    @ViewBuilder
    private func driverCell(_ driver: WorldTensionHeadline) -> some View {
        let cell = VStack(alignment: .leading, spacing: AppSpacing.textStack) {
            EyebrowText(driver.publisher)
            Text(driver.title)
                .font(AppTypography.callout)
                .foregroundStyle(AppColor.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if let url = driver.webURL {
            Button {
                openURL(url)
            } label: {
                cell
            }
            .buttonStyle(.plain)
            .help("Open the story in your browser")
        } else {
            cell
        }
    }
}

/// The last seven UTC days of readings as a small line; a missing day breaks the line. One reading or none shows a
/// flat baseline.
struct BriefingTensionSparklineView: View {
    let readings: [WorldTensionReading]
    /// Where the flat line sits without two readings this week: the reading shown, which may be older than the week.
    var baseline: Int = 50

    private static let chartWidth: CGFloat = 140
    private static let chartHeight: CGFloat = 36

    var body: some View {
        let segments = WorldTensionState.segments(readings)
        Chart {
            if readings.count >= 2 {
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, item in
                    LineMark(
                        x: .value("Day", item.id),
                        y: .value("Reading", item.assessment.score),
                        series: .value("Segment", segments[index])
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(AppColor.secondaryText)

                    PointMark(
                        x: .value("Day", item.id),
                        y: .value("Reading", item.assessment.score)
                    )
                    .foregroundStyle(AppColor.tension(item.level))
                }
            } else {
                RuleMark(y: .value("Baseline", readings.last?.assessment.score ?? baseline))
                    .foregroundStyle(AppColor.borderSubtle)
                    .lineStyle(StrokeStyle(lineWidth: AppLayout.hairline, dash: [4, 4]))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: Self.chartWidth, height: Self.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World tension seven-day trend")
        .accessibilityValue(readings.map { "\($0.assessment.score) degrees" }.joined(separator: ", "))
    }
}

// MARK: - Dense Story Tile Component

/// Presentation state configuration for a ``BriefingTileView``.
struct BriefingTileState: Equatable, Sendable {
    /// Whether the tile currently holds keyboard focus or selection.
    var isSelected: Bool = false
    /// Whether the story has been marked as read.
    var isRead: Bool = false
    /// Whether the story is bookmarked in Saved Stories.
    var isSaved: Bool = false
}

/// Dynamic visual styling properties calculated for a story tile.
struct BriefingTileAppearance {
    let border: Color
    let width: CGFloat
    let shadow: Color
    let radius: CGFloat
    let y: CGFloat
}

/// Dense story card displaying a categorized headline, cited fact highlight, and source badge.
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
        state: BriefingTileState = BriefingTileState(),
        onOpen: @escaping () -> Void,
        onToggleRead: @escaping () -> Void = {},
        onToggleSave: @escaping () -> Void = {}
    ) {
        self.article = article
        self.eventSummary = eventSummary
        self.citedFact = citedFact
        self.isSelected = state.isSelected
        self.isRead = state.isRead
        self.isSaved = state.isSaved
        self.onOpen = onOpen
        self.onToggleRead = onToggleRead
        self.onToggleSave = onToggleSave
    }

    /// Distinct publishers of the story's event, as on the hero and the event card's coverage row.
    private var publisherCount: Int { eventSummary.map { max(1, $0.sources.count) } ?? 1 }

    private var appearance: BriefingTileAppearance {
        if isSelected {
            return BriefingTileAppearance(
                border: AppColor.accent,
                width: AppLayout.focusStroke,
                shadow: AppShadow.cardFocusRingColor,
                radius: AppShadow.cardFocusRingRadius,
                y: AppShadow.cardFocusRingY
            )
        }
        if isHovered {
            return BriefingTileAppearance(
                border: AppColor.hoverBorder,
                width: AppLayout.hoverStroke,
                shadow: AppShadow.cardHoverColor,
                radius: AppShadow.cardHoverRadius,
                y: AppShadow.cardHoverY
            )
        }
        return BriefingTileAppearance(
            border: AppColor.border(for: contrast),
            width: contrast == .increased ? AppLayout.hoverStroke : AppLayout.hairline,
            shadow: AppShadow.cardRestingColor,
            radius: AppShadow.cardRestingRadius,
            y: AppShadow.cardRestingY
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
            // Tiles of a row share its height, with footers on one line, as in the board design.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            StoryContextMenuItems(article: article)
        }
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
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: AppSpacing.xs) {
            if publisherCount > 1 {
                TagView(title: "\(publisherCount) publishers", systemImage: "square.stack.3d.up")
            }
            Spacer()
            if isSaved {
                Image(systemName: "bookmark.fill")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AppColor.accentText)
                    .accessibilityLabel("Saved")
            }
        }
    }

    @ViewBuilder
    private var factOrSummaryView: some View {
        if let fact = citedFact, fact.isCited && !fact.text.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("“\(fact.text)”")
                    .font(AppTypography.callout.italic())
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(3, reservesSpace: true)
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
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var accessibilityDescription: String {
        let readState = isRead ? "Read" : "Unread"
        let savedState = isSaved ? ", saved in your library" : ""
        var desc =
            "\(article.title), from \(article.publisherName), \(article.cardDateText()). \(readState)\(savedState)."
            + (publisherCount > 1 ? " \(publisherCount) publishers." : "")
        if let fact = citedFact, fact.isCited && !fact.text.isEmpty {
            desc += " Quoting: \(fact.text)."
            if let pub = fact.citationPublisher, !pub.isEmpty {
                desc += " Cited by \(pub)."
            }
        }
        return desc
    }
}
