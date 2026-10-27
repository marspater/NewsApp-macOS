// EventOverviewReaderView.swift
// NewsApp Event Overview Reader Mode & Source Navigation

import AppKit
import SwiftUI

/// Native SwiftUI reader view for multi-source event overviews.
/// Implements the 6 editorial sections in order:
/// 1. Title, update time, article count and publisher count
/// 2. Short introduction (1–2 paragraphs)
/// 3. Fitting main image with caption and attribution
/// 4. Highlights: key verified facts with passage-anchored citation links
/// 5. Evidence sections: participant perspectives, timeline, thematic angle (Kagi News story order), then
///    "Earlier in This Story": related earlier events, each opening its own overview (#314)
/// 6. Sources: every member publication, read here or opened on the publisher's site
/// Sections without enough data are absent.
struct EventOverviewReaderView: View {
    let overview: EventOverviewDocument
    let memberArticles: [FeedArticle]
    let textScale: CGFloat
    /// The reading style the body text follows; harnesses keep the default.
    let theme: ArticleThemeType
    let onSelectArticle: (FeedArticle) -> Void
    let onSelectCitation: (OverviewCitation, FeedArticle?) -> Void
    /// Earlier events of the same developing story; merged into this one only when the reader says so.
    let relatedEvents: [RelatedStoryEvent]
    let onSelectRelatedEvent: (RelatedStoryEvent) -> Void
    /// "Same Event": the reader says a related event reports this one (#524); nil hides the action.
    let onCombineRelatedEvent: ((RelatedStoryEvent) -> Void)?

    init(
        overview: EventOverviewDocument,
        memberArticles: [FeedArticle],
        textScale: CGFloat = 1.0,
        theme: ArticleThemeType = .edition,
        relatedEvents: [RelatedStoryEvent] = [],
        onSelectArticle: @escaping (FeedArticle) -> Void,
        onSelectCitation: @escaping (OverviewCitation, FeedArticle?) -> Void,
        onSelectRelatedEvent: @escaping (RelatedStoryEvent) -> Void = { _ in
            // Callers without navigation (harnesses, previews) pass no related events, so nothing calls this.
        },
        onCombineRelatedEvent: ((RelatedStoryEvent) -> Void)? = nil
    ) {
        self.overview = overview
        self.memberArticles = memberArticles
        self.textScale = textScale
        self.theme = theme
        self.relatedEvents = relatedEvents
        self.onSelectArticle = onSelectArticle
        self.onSelectCitation = onSelectCitation
        self.onSelectRelatedEvent = onSelectRelatedEvent
        self.onCombineRelatedEvent = onCombineRelatedEvent
    }

    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    /// Collapsed until the person opens it; their choice holds for the rest of the session (DESIGN.md 9, #596).
    @MainActor static var sourcesExpandedThisSession = false
    @State private var isSourcesExpanded = Self.sourcesExpandedThisSession

    // MARK: - Layout Metrics & Bounds
    static let horizontalPageInset = AppLayout.pageInset

    static func readingColumnMaxWidth(for scale: CGFloat) -> CGFloat {
        AppLayout.readingColumnMaxWidth(for: scale)
    }

    // MARK: - Contrast & Color Scalers
    static func borderStrokeColor(for contrast: ColorSchemeContrast) -> Color {
        AppColor.border(for: contrast)
    }

    static func dividerOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.60 : 0.20
    }

    static func pillBorderOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.60 : 0.0
    }

    static func pillBackgroundOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.22 : 0.12
    }

    static func secondaryTextColor(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? AppColor.primaryText : AppColor.secondaryText
    }

    static func tertiaryTextColor(for contrast: ColorSchemeContrast) -> Color {
        AppColor.tertiaryText(for: contrast)
    }

    private var currentBorderStrokeColor: Color {
        Self.borderStrokeColor(for: contrast)
    }

    private var currentSecondaryTextColor: Color {
        Self.secondaryTextColor(for: contrast)
    }

    private var currentTertiaryTextColor: Color {
        Self.tertiaryTextColor(for: contrast)
    }

    // MARK: - Animation Policy
    static func readerAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : AppMotion.navigation
    }

    // MARK: - Citation Resolution Helper
    static func matchingArticle(for citation: OverviewCitation, in memberArticles: [FeedArticle]) -> FeedArticle? {
        if let match = memberArticles.first(where: { $0.id == citation.articleID }) {
            return match
        }
        if let url = citation.sourceURL, !url.isEmpty,
            let match = memberArticles.first(where: { $0.link == url })
        {
            return match
        }
        if let title = citation.sourceTitle, !title.isEmpty,
            let match = memberArticles.first(where: { $0.title == title })
        {
            return match
        }
        if let name = citation.sourceName, !name.isEmpty,
            let match = memberArticles.first(where: { $0.source.caseInsensitiveCompare(name) == .orderedSame })
        {
            return match
        }
        return nil
    }

    private func matchingArticle(for citation: OverviewCitation) -> FeedArticle? {
        Self.matchingArticle(for: citation, in: memberArticles)
    }

    // MARK: - Sparse Section Filtering
    static func hasSummaryContent(_ summary: String) -> Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasLeadImageContent(_ leadImage: OverviewLeadImage?) -> Bool {
        guard let leadImage = leadImage else { return false }
        return !leadImage.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func filterValidFacts(_ facts: [OverviewFact]) -> [OverviewFact] {
        facts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func filterValidTimeline(_ timeline: [OverviewTimelineItem]) -> [OverviewTimelineItem] {
        timeline.filter {
            !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func sortTimelineItems(_ items: [OverviewTimelineItem]) -> [OverviewTimelineItem] {
        items.enumerated().sorted { left, right in
            let a = left.element
            let b = right.element
            if a.isFuturePlan != b.isFuturePlan {
                return !a.isFuturePlan && b.isFuturePlan
            }
            let dateA = a.eventDate ?? a.publicationDate
            let dateB = b.eventDate ?? b.publicationDate
            if let dateA, let dateB, dateA != dateB {
                return dateA < dateB
            }
            if dateA != nil && dateB == nil { return true }
            if dateA == nil && dateB != nil { return false }
            if a.eventDate != nil && b.eventDate == nil { return true }
            if a.eventDate == nil && b.eventDate != nil { return false }
            return left.offset < right.offset
        }.map(\.element)
    }

    static func filterValidPerspectives(_ perspectives: [OverviewPerspective]) -> [OverviewPerspective] {
        perspectives.filter {
            !$0.participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.position.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func filterValidIndustryImpact(_ impact: [OverviewIndustryImpact]) -> [OverviewIndustryImpact] {
        impact.filter {
            !$0.industry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.implication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func hasThematicAngleContent(_ angle: OverviewThematicAngle?) -> Bool {
        guard let angle = angle else { return false }
        let title = angle.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = angle.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let validFacts = angle.facts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !title.isEmpty || !summary.isEmpty || !validFacts.isEmpty
    }

    /// The extractor builds the summary from the first facts, so it shows only when there are no bullets to repeat.
    static func showsThematicAngleSummary(_ angle: OverviewThematicAngle) -> Bool {
        !angle.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filterValidFacts(angle.facts).isEmpty
    }

    /// Coverage sentiment stays in the data for Briefing interests and is never shown (DESIGN.md 9, #597).
    static func hasEvidenceContent(
        timeline: [OverviewTimelineItem],
        perspectives: [OverviewPerspective],
        industryImpact: [OverviewIndustryImpact] = [],
        thematicAngle: OverviewThematicAngle?
    ) -> Bool {
        !filterValidTimeline(timeline).isEmpty || !filterValidPerspectives(perspectives).isEmpty
            || !filterValidIndustryImpact(industryImpact).isEmpty || hasThematicAngleContent(thematicAngle)
    }

    private var validFacts: [OverviewFact] {
        Self.filterValidFacts(overview.facts)
    }

    private var validTimeline: [OverviewTimelineItem] {
        Self.filterValidTimeline(overview.timeline)
    }

    private var sortedTimeline: [OverviewTimelineItem] {
        Self.sortTimelineItems(validTimeline)
    }

    private var validPerspectives: [OverviewPerspective] {
        Self.filterValidPerspectives(overview.perspectives)
    }

    private var validIndustryImpact: [OverviewIndustryImpact] {
        Self.filterValidIndustryImpact(overview.industryImpact)
    }

    // MARK: - VoiceOver Accessibility Labels
    static func headerMetadataAccessibilityLabel(
        formattedUpdateTime: String,
        articleCountText: String,
        publisherCountText: String
    ) -> String {
        "Updated \(formattedUpdateTime), \(articleCountText), \(publisherCountText)"
    }

    static func leadImageAccessibilityLabel(_ leadImage: OverviewLeadImage) -> String {
        let caption = leadImage.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credit = leadImage.credit?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let caption = caption, !caption.isEmpty {
            parts.append(caption)
        } else {
            parts.append("Event lead image")
        }
        if let credit = credit, !credit.isEmpty {
            parts.append("Credit: \(credit)")
        }
        return parts.joined(separator: ". ")
    }

    static func citationAccessibilityLabel(sourceName: String, quote: String) -> String {
        "Citation from \(sourceName): \(quote)"
    }

    static func readArticleAccessibilityLabel(title: String, source: String) -> String {
        "Read \(title) from \(source) in Source publication mode"
    }

    static func openWebArticleAccessibilityLabel(title: String, source: String) -> String {
        "Open original publication: \(title) on \(source)"
    }

    static func highlightAccessibilityLabel(
        takeaway: String, publisher: String?, citations: [OverviewCitation] = []
    ) -> String {
        let trimmed = takeaway.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        if let publisher, !publisher.isEmpty {
            return "\(base). Source: \(publisher)"
        }
        let sources = citations.compactMap(\.sourceName).filter { !$0.isEmpty }.joined(separator: ", ")
        if !sources.isEmpty {
            return "\(base). Source: \(sources)"
        }
        return trimmed
    }

    static func perspectiveAccessibilityLabel(
        participant: String, position: String, source: String?, citations: [OverviewCitation] = []
    ) -> String {
        let pPart = participant.trimmingCharacters(in: .whitespacesAndNewlines)
        let pPosTrimmed = position.trimmingCharacters(in: .whitespacesAndNewlines)
        let pPos = pPosTrimmed.hasSuffix(".") ? String(pPosTrimmed.dropLast()) : pPosTrimmed
        var parts = [pPart, pPos]
        if let source, !source.isEmpty {
            parts.append(source)
        } else {
            let sources = citations.compactMap(\.sourceName).filter { !$0.isEmpty }.joined(separator: ", ")
            if !sources.isEmpty {
                parts.append("Source: \(sources)")
            }
        }
        return parts.joined(separator: ". ")
    }

    static func industryImpactAccessibilityLabel(
        industry: String, implication: String, citations: [OverviewCitation] = []
    ) -> String {
        let trimmed = implication.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        let sources = citations.compactMap(\.sourceName).filter { !$0.isEmpty }.joined(separator: ", ")
        if !sources.isEmpty {
            return "\(industry): \(base). Source: \(sources)"
        }
        return "\(industry): \(trimmed)"
    }

    static func formatPerspectiveSource(wire: String?, publisher: String?) -> String? {
        if let wire = wire?.trimmingCharacters(in: .whitespacesAndNewlines), !wire.isEmpty {
            let cleanWire = wire.hasPrefix("via ") ? String(wire.dropFirst(4)) : wire
            return "via \(cleanWire) syndicate"
        }
        if let pub = publisher?.trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty {
            let cleanPub = pub.hasPrefix("via ") ? String(pub.dropFirst(4)) : pub
            return "via \(cleanPub)"
        }
        return nil
    }

    static func timelineItemAccessibilityLabel(
        item: OverviewTimelineItem, citations: [OverviewCitation] = []
    ) -> String {
        var parts: [String] = []
        let displayDate: String
        if !item.dateText.isEmpty {
            displayDate = item.dateText
        } else if let pubDate = item.publicationDate {
            displayDate = timelineDateFormatter.string(from: pubDate)
        } else {
            displayDate = ""
        }

        if !displayDate.isEmpty {
            if item.eventDate != nil {
                parts.append(displayDate)
            } else {
                let label = displayDate.hasPrefix("Reported ") ? displayDate : "Reported \(displayDate)"
                parts.append(label)
            }
        }
        if item.isFuturePlan {
            parts.append("Planned")
        }
        let summaryTrimmed = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summaryTrimmed.hasSuffix(".") ? String(summaryTrimmed.dropLast()) : summaryTrimmed
        parts.append(summary)
        let sources = citations.compactMap(\.sourceName).filter { !$0.isEmpty }.joined(separator: ", ")
        if !sources.isEmpty {
            parts.append("Source: \(sources)")
        }
        return parts.joined(separator: ". ")
    }

    private var uniquePublishers: [String] {
        var set = Set<String>()
        var list: [String] = []
        for article in memberArticles {
            let src = article.publisherName
            if !src.isEmpty && !set.contains(src) {
                set.insert(src)
                list.append(src)
            }
        }
        if list.isEmpty {
            for citation in overview.citations.values {
                if let name = citation.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                    !set.contains(name)
                {
                    set.insert(name)
                    list.append(name)
                }
            }
        }
        return list
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let timelineDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var formattedUpdateTime: String {
        Self.relativeFormatter.localizedString(for: overview.updatedAt, relativeTo: Date())
    }

    private func formatTimelineDate(_ date: Date) -> String {
        Self.timelineDateFormatter.string(from: date)
    }

    private var articleCountText: String {
        let count = max(memberArticles.count, overview.memberArticleIDs.count)
        return count == 1 ? "1 story" : "\(count) stories"
    }

    private var publisherCountText: String {
        let count = max(uniquePublishers.count, 1)
        return count == 1 ? "1 publisher" : "\(count) publishers"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    // 1. Header: Eyebrow, Title, Update Time, Article & Publisher Counts
                    headerSection

                    // 2. Short introduction: one or two paragraphs
                    if Self.hasSummaryContent(overview.summary) {
                        introductionSection
                    }

                    // 3. Fitting main image with caption and source
                    if Self.hasLeadImageContent(overview.leadImage), let leadImage = overview.leadImage {
                        leadImageSection(leadImage)
                    }

                    // 4. Three to five key facts with links
                    if !validFacts.isEmpty {
                        keyFactsSection
                    }

                    // 5. With evidence: participant positions, timeline, thematic angle
                    evidenceSections

                    if !relatedEvents.isEmpty {
                        earlierInStorySection
                    }

                    // 6. Sources: one list that reads each publication here or opens it on the publisher's site
                    if !memberArticles.isEmpty {
                        compactSourcesSection
                    }
                }
                .modifier(ReadingColumn(textScale: textScale))
            }
            .frame(maxWidth: .infinity)
        }
        .background(AppColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Event overview: \(overview.title)")
    }

    // MARK: - Section 1: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            IntelligenceLabel("Event overview")
                .font(AppTypography.overviewFont(.eyebrow, scale: textScale))
                .help("Assembled on this Mac from the cited passages")
                .accessibilityElement(children: .combine)

            Text(overview.title)
                .font(AppTypography.overviewFont(.title, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .textSelection(.enabled)

            HStack(spacing: AppSpacing.eyebrowGap) {
                (Text("Updated ") + Text(overview.updatedAt, style: .relative) + Text(" ago"))
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .monospacedDigit()

                Text("·")
                    .foregroundStyle(currentSecondaryTextColor)
                    .accessibilityHidden(true)

                Text(articleCountText)
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .monospacedDigit()

                Text("·")
                    .foregroundStyle(currentSecondaryTextColor)
                    .accessibilityHidden(true)

                Text(publisherCountText)
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Self.headerMetadataAccessibilityLabel(
                    formattedUpdateTime: formattedUpdateTime,
                    articleCountText: articleCountText,
                    publisherCountText: publisherCountText
                ))
        }
    }

    // MARK: - Section 2: Introduction

    private var introductionSection: some View {
        let paragraphs = overview.summary
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let introduction = overview.content.evidenceSections?.introduction, !introduction.isEmpty {
                ForEach(introduction) { fact in
                    Text(fact.text)
                        .font(AppTypography.overviewFont(.introduction, scale: textScale))
                        .lineSpacing(AppSpacing.eyebrowGap * textScale)
                        .foregroundStyle(AppColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    ReaderTagLayout(spacing: AppSpacing.eyebrowGap) {
                        ForEach(fact.citationIDs, id: \.self) { id in
                            if let citation = overview.citations[id] { citationPill(citation) }
                        }
                    }
                }
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(AppTypography.overviewFont(.introduction, scale: textScale))
                        .lineSpacing(AppSpacing.eyebrowGap * textScale)
                        .foregroundStyle(AppColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Section 3: Lead Image

    @ViewBuilder
    private func leadImageSection(_ leadImage: OverviewLeadImage) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let url = URL(string: leadImage.url) {
                // The same figure as the reader: fills the measure, portrait cap, contrast-aware border.
                ReaderFigureView(
                    block: ReaderBlock(kind: .figure, text: "", imageURL: leadImage.url, imageAlt: leadImage.caption),
                    url: url, textScale: textScale
                )
                .accessibilityHidden(true)
            }

            if let caption = leadImage.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
                !caption.isEmpty
            {
                Text(caption)
                    .font(AppTypography.overviewFont(.annotation, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .textSelection(.enabled)
            }

            if let credit = leadImage.credit?.trimmingCharacters(in: .whitespacesAndNewlines),
                !credit.isEmpty
            {
                Text(credit)
                    .font(AppTypography.overviewFont(.annotation, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .textSelection(.enabled)
            }
        }
        // Ignore, not combine: the caption and credit are selectable (AppKit-backed) text, and the label already
        // carries both (DESIGN.md 16).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.leadImageAccessibilityLabel(leadImage))
    }

    /// The 1-based number of the member article a citation comes from, as listed under Sources.
    static func sourceIndex(for citation: OverviewCitation, in memberArticles: [FeedArticle]) -> Int? {
        if let match = matchingArticle(for: citation, in: memberArticles),
            let idx = memberArticles.firstIndex(where: { $0.id == match.id })
        {
            return idx + 1
        }
        if let pub = citation.sourceName,
            let idx = memberArticles.firstIndex(where: {
                $0.publisherName.localizedCaseInsensitiveContains(pub)
                    || pub.localizedCaseInsensitiveContains($0.publisherName)
            })
        {
            return idx + 1
        }
        return nil
    }

    /// Each cited source number once, in source order, paired with the item's first citation from that source,
    /// so a superscript opens its own source's passage.
    static func citedSources(
        _ citationIDs: [String], citations: [String: OverviewCitation], memberArticles: [FeedArticle]
    ) -> [(index: Int, citation: OverviewCitation)] {
        var seen = Set<Int>()
        return citationIDs.compactMap { id -> (index: Int, citation: OverviewCitation)? in
            guard let citation = citations[id], let index = sourceIndex(for: citation, in: memberArticles),
                seen.insert(index).inserted
            else { return nil }
            return (index, citation)
        }
        .sorted { $0.index < $1.index }
    }

    private func citedSources(_ citationIDs: [String]) -> [(index: Int, citation: OverviewCitation)] {
        Self.citedSources(citationIDs, citations: overview.citations, memberArticles: memberArticles)
    }

    private func factPublisher(_ fact: OverviewFact) -> String? {
        for citID in fact.citationIDs {
            if let citation = overview.citations[citID] {
                if let name = citation.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    return name
                }
                if let match = matchingArticle(for: citation), !match.publisherName.isEmpty {
                    return match.publisherName
                }
            }
        }
        return nil
    }

    // MARK: - Section 4: Key Facts

    private var keyFactsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Highlights")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(validFacts) { fact in
                    highlightRow(fact)
                }
            }
            .padding(.vertical, AppSpacing.xxs)
        }
    }

    @ViewBuilder
    private func highlightRow(_ fact: OverviewFact) -> some View {
        let publisher = factPublisher(fact)
        let citations = fact.citationIDs.compactMap { overview.citations[$0] }
        let sources = citedSources(fact.citationIDs)

        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Circle()
                .frame(width: AppSpacing.xxs, height: AppSpacing.xxs)
                .foregroundStyle(AppColor.accent)
                .padding(.top, AppLayout.bulletTopInset * textScale)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(fact.text)
                    .font(bodyFont)
                    .lineSpacing(bodyLineSpacing)
                    .foregroundStyle(AppColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                let hasPublisher = publisher != nil && !publisher!.isEmpty
                let hasCitations = !citations.isEmpty

                if hasPublisher || hasCitations {
                    ReaderTagLayout(spacing: AppSpacing.eyebrowGap) {
                        if let publisher, !publisher.isEmpty {
                            Text(publisher)
                                .font(AppTypography.overviewFont(.annotation, scale: textScale))
                                .foregroundStyle(currentSecondaryTextColor)
                        }

                        ForEach(fact.citationIDs, id: \.self) { id in
                            if let citation = overview.citations[id] {
                                citationPill(citation)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.highlightAccessibilityLabel(
                takeaway: fact.text,
                publisher: publisher,
                citations: citations
            )
        )
        .accessibilityActions { citationAccessibilityActions(sources) }
    }

    private func factWithSuperscript(_ fact: OverviewFact) -> some View {
        citedText(fact.text, citationIDs: fact.citationIDs, font: bodyFont)
            .foregroundStyle(AppColor.primaryText)
    }

    private var bodyFont: Font { AppTypography.bodyFont(for: theme, scale: textScale) }
    private var bodyLineSpacing: CGFloat { AppTypography.bodyLineSpacing(for: theme) * textScale }

    /// One text with the source numbers as superscript links (`news-citation://<index>`), so the citations wrap
    /// with the sentence; VoiceOver offers "Open source N" actions instead of separate buttons.
    private func citedText(_ text: String, citationIDs: [String], font: Font) -> some View {
        let sources = citedSources(citationIDs)
        return Text(Self.citedAttributedString(text, sources: sources.map(\.index), scale: textScale))
            .font(font)
            .lineSpacing(bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, citationOpenURLAction(sources))
            .accessibilityActions { citationAccessibilityActions(sources) }
    }

    /// Opens the source a `news-citation://<index>` link names; every other link keeps the system behaviour.
    private func citationOpenURLAction(_ sources: [(index: Int, citation: OverviewCitation)]) -> OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == Self.citationScheme, let index = url.host.flatMap({ Int($0) }),
                let source = sources.first(where: { $0.index == index })
            else { return .systemAction }
            onSelectCitation(source.citation, matchingArticle(for: source.citation))
            return .handled
        }
    }

    private func citationAccessibilityActions(_ sources: [(index: Int, citation: OverviewCitation)]) -> some View {
        ForEach(sources, id: \.index) { source in
            Button("Open source \(source.index), \(source.citation.sourceName ?? "source")") {
                onSelectCitation(source.citation, matchingArticle(for: source.citation))
            }
        }
    }

    static let citationScheme = "news-citation"

    /// The sentence followed by its source numbers as accent superscripts linking to `news-citation://<index>`.
    static func citedAttributedString(_ text: String, sources: [Int], scale: CGFloat) -> AttributedString {
        var result = AttributedString(text)
        for index in sources {
            var mark = AttributedString("[\(index)]")
            mark.link = URL(string: "\(citationScheme)://\(index)")
            mark.font = AppTypography.overviewFont(.micro, scale: scale).bold()
            mark.baselineOffset = AppTypography.superscriptOffset
            mark.foregroundColor = AppColor.accent
            result.append(AttributedString(" "))
            result.append(mark)
        }
        return result
    }

    @ViewBuilder
    private func citationPill(_ citation: OverviewCitation) -> some View {
        let match = matchingArticle(for: citation)
        let label = citation.sourceName ?? match?.source ?? "Source"

        Button {
            onSelectCitation(citation, match)
        } label: {
            TagView(
                title: label,
                systemImage: "link",
                tint: AppColor.accent,
                font: AppTypography.overviewFont(.eyebrow, scale: textScale)
            )
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.capsule)
        .help("Open in source publication: “\(citation.quote)”")
        .accessibilityLabel(Self.citationAccessibilityLabel(sourceName: label, quote: citation.quote))
        .accessibilityHint("Opens source publication at cited passage")
    }

    // MARK: - Section 6: Sources

    private var compactSourcesSection: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { isSourcesExpanded },
                set: { val in
                    Self.sourcesExpandedThisSession = val
                    if reduceMotion {
                        isSourcesExpanded = val
                    } else {
                        withAnimation(Self.readerAnimation(reduceMotion: reduceMotion)) {
                            isSourcesExpanded = val
                        }
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(Array(memberArticles.enumerated()), id: \.element.id) { index, article in
                    HStack(alignment: .center, spacing: AppSpacing.sm) {
                        Text("[\(index + 1)]")
                            .font(AppTypography.overviewFont(.annotation, scale: textScale))
                            .foregroundStyle(AppColor.accent)
                            .bold()
                            .monospacedDigit()
                            .frame(
                                width: AppLayout.overviewIndexColumnWidth(count: memberArticles.count),
                                alignment: .leading)

                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            EyebrowText(
                                article.publisherName,
                                color: AppColor.accent,
                                font: AppTypography.overviewFont(.eyebrow, scale: textScale)
                            )

                            Text(article.title)
                                .font(AppTypography.overviewFont(.metadata, scale: textScale))
                                .foregroundStyle(AppColor.primaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)

                            Text(article.publicationDateText)
                                .font(AppTypography.overviewFont(.annotation, scale: textScale))
                                .foregroundStyle(currentSecondaryTextColor)
                                .monospacedDigit()
                        }

                        Spacer(minLength: 8)

                        Button("Read") {
                            onSelectArticle(article)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Read this story in Source publication mode")
                        .accessibilityLabel(
                            Self.readArticleAccessibilityLabel(title: article.title, source: article.publisherName))

                        if let url = URL(string: article.link) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                                    .imageScale(.small)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(currentSecondaryTextColor)
                            .help("Open original web publication")
                            .accessibilityLabel(
                                Self.openWebArticleAccessibilityLabel(
                                    title: article.title, source: article.publisherName))
                        }
                    }
                    .padding(.vertical, AppSpacing.xxs)

                    if article.id != memberArticles.last?.id {
                        Divider()
                            .opacity(Self.dividerOpacity(for: contrast))
                    }
                }
            }
            .padding(.top, AppSpacing.xs)
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "newspaper")
                    .imageScale(.small)
                    .foregroundStyle(AppColor.accent)
                    .accessibilityHidden(true)

                Text("Sources (\(memberArticles.count))")
                    .font(AppTypography.overviewFont(.subheading, scale: textScale))
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
            }
        }
        .padding(AppSpacing.sm)
        .overviewCardSurface(borderColor: currentBorderStrokeColor, contrast: contrast)
    }

    // MARK: - Earlier in This Story (#314)

    /// Each row opens its own event; read and saved state stay with that event.
    private var earlierInStorySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Earlier in This Story")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(relatedEvents, id: \.eventID) { event in
                    Button {
                        onSelectRelatedEvent(event)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                            Text(event.firstPublishedAt.formatted(.dateTime.month(.abbreviated).day()))
                                .font(AppTypography.overviewFont(.annotation, scale: textScale))
                                .foregroundStyle(currentSecondaryTextColor)
                                .monospacedDigit()
                            Text(event.title)
                                .font(AppTypography.overviewFont(.body, scale: textScale))
                                .foregroundStyle(AppColor.primaryText)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: AppSpacing.xs)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(currentTertiaryTextColor)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let onCombineRelatedEvent {
                            Button {
                                onCombineRelatedEvent(event)
                            } label: {
                                Label("Same Event", systemImage: "arrow.triangle.merge")
                            }
                        }
                    }
                    .help(
                        onCombineRelatedEvent == nil
                            ? "Open the overview of this earlier event"
                            : "Open the overview of this earlier event. Use the context menu if it reports this event."
                    )
                    .accessibilityHint("Opens this earlier event")
                    .accessibilityActions {
                        if let onCombineRelatedEvent {
                            Button("Same Event") { onCombineRelatedEvent(event) }
                        }
                    }

                    if event.eventID != relatedEvents.last?.eventID {
                        Divider().opacity(Self.dividerOpacity(for: contrast))
                    }
                }
            }
            .padding(AppSpacing.md)
            .overviewCardSurface(borderColor: currentBorderStrokeColor, contrast: contrast)
        }
    }

    // MARK: - Section 5: Evidence Sections (Timeline, Perspectives, Industry Impact, Angle)

    @ViewBuilder
    private var evidenceSections: some View {
        // Sections without enough data are absent
        if Self.hasEvidenceContent(
            timeline: overview.timeline,
            perspectives: overview.perspectives,
            industryImpact: overview.industryImpact,
            thematicAngle: overview.thematicAngle
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if !validTimeline.isEmpty {
                    timelineSection
                }

                if !validPerspectives.isEmpty {
                    perspectivesSection
                }

                if !validIndustryImpact.isEmpty {
                    industryImpactSection
                }

                // Thematic angle
                if Self.hasThematicAngleContent(overview.thematicAngle), let angle = overview.thematicAngle {
                    thematicAngleSection(angle)
                }
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Timeline")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sortedTimeline.enumerated()), id: \.element.id) { index, item in
                    timelineRow(item, isFirst: index == 0, isLast: index == sortedTimeline.count - 1)
                }
            }
            .padding(.vertical, AppSpacing.xxs)
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: OverviewTimelineItem, isFirst: Bool, isLast: Bool) -> some View {
        let citations = item.citationIDs.compactMap { overview.citations[$0] }
        let sources = citedSources(item.citationIDs)

        HStack(alignment: .top, spacing: AppSpacing.sm) {
            timelineRailNode(item: item, isFirst: isFirst, isLast: isLast)
                .accessibilityHidden(true)
            timelineRowContent(item, isLast: isLast)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.timelineItemAccessibilityLabel(item: item, citations: citations))
        .accessibilityActions { citationAccessibilityActions(sources) }
    }

    private func timelineRailNode(item: OverviewTimelineItem, isFirst: Bool, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(AppColor.timelineRail(for: contrast))
                    .frame(width: AppLayout.timelineRailStroke, height: AppSpacing.textStack)
            } else {
                Spacer()
                    .frame(height: AppSpacing.textStack)
            }

            timelineMarker(for: item)
                .frame(width: AppLayout.timelineDotSize, height: AppLayout.timelineDotSize)

            if !isLast {
                Rectangle()
                    .fill(AppColor.timelineRail(for: contrast))
                    .frame(width: AppLayout.timelineRailStroke)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: AppLayout.timelineRailWidth)
    }

    @ViewBuilder
    private func timelineMarker(for item: OverviewTimelineItem) -> some View {
        if item.isFuturePlan {
            DiamondShape()
                .fill(AppColor.accent)
        } else if item.eventDate == nil {
            Circle()
                .strokeBorder(AppColor.accent, lineWidth: AppLayout.timelineRailStroke)
                .background(Circle().fill(AppColor.background))
        } else {
            Circle()
                .fill(AppColor.accent)
        }
    }

    private func timelineRowContent(_ item: OverviewTimelineItem, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            timelineDateRow(item)
            timelineSummaryRow(item)
        }
        .padding(.bottom, isLast ? 0 : AppSpacing.md)
    }

    @ViewBuilder
    private func timelineDateRow(_ item: OverviewTimelineItem) -> some View {
        let hasDateText = !item.dateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasEventDate = item.eventDate != nil
        let hasPubDate = item.publicationDate != nil

        if hasDateText || hasEventDate || hasPubDate || item.isFuturePlan {
            HStack(spacing: AppSpacing.xs) {
                if hasEventDate && hasDateText {
                    Text(item.dateText)
                        .font(AppTypography.overviewFont(.annotation, scale: textScale))
                        .foregroundStyle(AppColor.accent)
                        .bold()
                } else if !hasEventDate && (hasDateText || hasPubDate) {
                    let displayDate =
                        hasDateText
                        ? item.dateText
                        : (item.publicationDate.map(formatTimelineDate) ?? "")
                    if !displayDate.isEmpty {
                        let text = displayDate.hasPrefix("Reported ") ? displayDate : "Reported \(displayDate)"
                        Text(text)
                            .font(AppTypography.overviewFont(.annotation, scale: textScale))
                            .foregroundStyle(AppColor.accent)
                            .bold()
                    }
                }

                if item.isFuturePlan {
                    TagView(
                        title: "Plan",
                        tint: AppColor.accent,
                        font: AppTypography.overviewFont(.micro, scale: textScale)
                    )
                    .accessibilityLabel("Planned event")
                }

                if let pubDate = item.publicationDate, hasEventDate {
                    Text("Reported \(formatTimelineDate(pubDate))")
                        .font(AppTypography.overviewFont(.annotation, scale: textScale))
                        .foregroundStyle(currentSecondaryTextColor)
                }
            }
        }
    }

    private func timelineSummaryRow(_ item: OverviewTimelineItem) -> some View {
        citedText(item.summary, citationIDs: item.citationIDs, font: bodyFont)
            .foregroundStyle(AppColor.primaryText)
    }

    private var perspectivesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Perspectives")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(validPerspectives) { perspective in
                    perspectiveRow(perspective)
                }
            }
            .padding(.vertical, AppSpacing.xxs)
        }
    }

    @ViewBuilder
    private func perspectiveRow(_ perspective: OverviewPerspective) -> some View {
        let source = Self.formatPerspectiveSource(
            wire: perspective.originalWireSource,
            publisher: perspective.sourcePublisher
        )
        let citations = perspective.citationIDs.compactMap { overview.citations[$0] }
        let sources = citedSources(perspective.citationIDs)

        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "person.crop.circle")
                    .font(AppTypography.overviewFont(.emphasis, scale: textScale))
                    .foregroundStyle(AppColor.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(perspective.participant)
                        .font(AppTypography.overviewFont(.emphasis, scale: textScale))
                        .foregroundStyle(AppColor.primaryText)
                        .textSelection(.enabled)

                    Text(perspective.position)
                        .font(bodyFont)
                        .lineSpacing(bodyLineSpacing)
                        .foregroundStyle(AppColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    let hasSource = source != nil && !source!.isEmpty
                    let hasCitations = !citations.isEmpty

                    if hasSource || hasCitations {
                        ReaderTagLayout(spacing: AppSpacing.eyebrowGap) {
                            if let source, !source.isEmpty {
                                Text(source)
                                    .font(AppTypography.overviewFont(.annotation, scale: textScale))
                                    .foregroundStyle(currentSecondaryTextColor)
                            }

                            ForEach(perspective.citationIDs, id: \.self) { id in
                                if let citation = overview.citations[id] {
                                    citationPill(citation)
                                }
                            }
                        }
                    }
                }
            }

            if perspective.id != validPerspectives.last?.id {
                Divider().opacity(Self.dividerOpacity(for: contrast))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.perspectiveAccessibilityLabel(
                participant: perspective.participant,
                position: perspective.position,
                source: source,
                citations: citations
            )
        )
        .accessibilityActions { citationAccessibilityActions(sources) }
    }

    private var industryImpactSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Industry Impact")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(validIndustryImpact) { item in
                    industryImpactRow(item)
                }
            }
            .padding(.vertical, AppSpacing.xxs)
        }
    }

    @ViewBuilder
    private func industryImpactRow(_ item: OverviewIndustryImpact) -> some View {
        let citations = item.citationIDs.compactMap { overview.citations[$0] }
        let sources = citedSources(item.citationIDs)

        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                TagView(
                    title: item.industry,
                    tint: AppColor.accent,
                    font: AppTypography.overviewFont(.micro, scale: textScale)
                )
                .accessibilityHidden(true)

                Text(item.implication)
                    .font(bodyFont)
                    .lineSpacing(bodyLineSpacing)
                    .foregroundStyle(AppColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !citations.isEmpty {
                    ReaderTagLayout(spacing: AppSpacing.eyebrowGap) {
                        ForEach(item.citationIDs, id: \.self) { id in
                            if let citation = overview.citations[id] {
                                citationPill(citation)
                            }
                        }
                    }
                }
            }

            if item.id != validIndustryImpact.last?.id {
                Divider().opacity(Self.dividerOpacity(for: contrast))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.industryImpactAccessibilityLabel(
                industry: item.industry,
                implication: item.implication,
                citations: citations
            )
        )
        .accessibilityActions { citationAccessibilityActions(sources) }
    }

    private func thematicAngleSection(_ angle: OverviewThematicAngle) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(angle.title)
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if Self.showsThematicAngleSummary(angle) {
                    Text(angle.summary)
                        .font(bodyFont)
                        .lineSpacing(bodyLineSpacing)
                        .foregroundStyle(AppColor.primaryText)
                        .textSelection(.enabled)
                }

                let validAngleFacts = Self.filterValidFacts(angle.facts)
                if !validAngleFacts.isEmpty {
                    thematicAngleFactsView(validAngleFacts)
                } else if !angle.citationIDs.isEmpty {
                    citedText(
                        "Sources", citationIDs: angle.citationIDs,
                        font: AppTypography.overviewFont(.caption, scale: textScale)
                    )
                    .foregroundStyle(currentSecondaryTextColor)
                }
            }
            .padding(.vertical, AppSpacing.xxs)
        }
    }

    private func thematicAngleFactsView(_ facts: [OverviewFact]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(facts) { fact in
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Circle()
                        .frame(width: AppSpacing.xxs, height: AppSpacing.xxs)
                        .foregroundStyle(AppColor.accent)
                        .padding(.top, AppLayout.bulletTopInset * textScale)
                        .accessibilityHidden(true)

                    factWithSuperscript(fact)
                }
            }
        }
    }
}

// MARK: - Timeline Diamond Shape

struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Overview Card Surface Modifier

private struct OverviewCardSurfaceModifier: ViewModifier {
    let borderColor: Color
    let contrast: ColorSchemeContrast

    func body(content: Content) -> some View {
        // Every card fills the reading column, so short cards line up with the rest.
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
    }
}

extension View {
    fileprivate func overviewCardSurface(borderColor: Color, contrast: ColorSchemeContrast) -> some View {
        modifier(OverviewCardSurfaceModifier(borderColor: borderColor, contrast: contrast))
    }
}
