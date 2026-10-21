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
    let onSelectArticle: (FeedArticle) -> Void
    let onSelectCitation: (OverviewCitation, FeedArticle?) -> Void
    /// Earlier events of the same developing story; never merged into this one.
    let relatedEvents: [RelatedStoryEvent]
    let onSelectRelatedEvent: (RelatedStoryEvent) -> Void

    init(
        overview: EventOverviewDocument,
        memberArticles: [FeedArticle],
        textScale: CGFloat = 1.0,
        relatedEvents: [RelatedStoryEvent] = [],
        onSelectArticle: @escaping (FeedArticle) -> Void,
        onSelectCitation: @escaping (OverviewCitation, FeedArticle?) -> Void,
        onSelectRelatedEvent: @escaping (RelatedStoryEvent) -> Void = { _ in
            // Callers without navigation (harnesses, previews) pass no related events, so nothing calls this.
        }
    ) {
        self.overview = overview
        self.memberArticles = memberArticles
        self.textScale = textScale
        self.relatedEvents = relatedEvents
        self.onSelectArticle = onSelectArticle
        self.onSelectCitation = onSelectCitation
        self.onSelectRelatedEvent = onSelectRelatedEvent
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    /// Open by default: the list is the overview's only route to the original publications.
    @State private var isSourcesExpanded: Bool = true
    /// The lead image could not load, so its caption and credit are hidden with it.
    @State private var leadImageFailed = false
    @State private var activeCitationPreview: OverviewCitation? = nil

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
            !$0.dateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func filterValidPerspectives(_ perspectives: [OverviewPerspective]) -> [OverviewPerspective] {
        perspectives.filter {
            !$0.participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.position.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    static func hasCoverageSentimentContent(_ sentiment: OverviewCoverageSentiment?) -> Bool {
        guard let sentiment = sentiment else { return false }
        return !sentiment.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasEvidenceContent(
        timeline: [OverviewTimelineItem],
        perspectives: [OverviewPerspective],
        thematicAngle: OverviewThematicAngle?,
        coverageSentiment: OverviewCoverageSentiment?
    ) -> Bool {
        !filterValidTimeline(timeline).isEmpty || !filterValidPerspectives(perspectives).isEmpty
            || hasThematicAngleContent(thematicAngle) || hasCoverageSentimentContent(coverageSentiment)
    }

    private var validFacts: [OverviewFact] {
        Self.filterValidFacts(overview.facts)
    }

    private var validTimeline: [OverviewTimelineItem] {
        Self.filterValidTimeline(overview.timeline)
    }

    private var validPerspectives: [OverviewPerspective] {
        Self.filterValidPerspectives(overview.perspectives)
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

    private var formattedUpdateTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: overview.updatedAt, relativeTo: Date())
    }

    private func formatTimelineDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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
            HStack(spacing: AppSpacing.xs) {
                TagView(
                    title: "Event overview", tint: AppColor.accent,
                    font: AppTypography.overviewFont(.eyebrow, scale: textScale))

                if overview.kind == .fallbackExcerpts {
                    TagView(
                        title: "Publisher excerpts", tint: currentSecondaryTextColor,
                        font: AppTypography.overviewFont(.eyebrow, scale: textScale))
                }
            }
            .accessibilityElement(children: .combine)

            Text(overview.title)
                .font(AppTypography.overviewFont(.title, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .textSelection(.enabled)

            HStack(spacing: AppSpacing.eyebrowGap) {
                Text("Updated \(formattedUpdateTime)")
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .monospacedDigit()

                Text("·")
                    .foregroundStyle(currentTertiaryTextColor)
                    .accessibilityHidden(true)

                Text(articleCountText)
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .monospacedDigit()

                Text("·")
                    .foregroundStyle(currentTertiaryTextColor)
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
                    HStack(spacing: AppSpacing.eyebrowGap) {
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
                ArticleRemoteImage(url: url) { phase in
                    if let image = phase.image {
                        // Figures fill the measure and are never cropped (DESIGN.md 9).
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                    .strokeBorder(AppColor.borderSubtle, lineWidth: 0.5)
                            )
                    } else if phase.error != nil {
                        Color.clear
                            .frame(height: 0)
                            .onAppear { leadImageFailed = true }
                    } else {
                        Rectangle()
                            .fill(AppColor.surface)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .accessibilityHidden(true)
                .onChange(of: leadImage.url) { _, _ in leadImageFailed = false }
            }

            if !leadImageFailed, let caption = leadImage.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
                !caption.isEmpty
            {
                Text(caption)
                    .font(AppTypography.overviewFont(.annotation, scale: textScale))
                    .foregroundStyle(currentSecondaryTextColor)
                    .textSelection(.enabled)
            }

            if !leadImageFailed, let credit = leadImage.credit?.trimmingCharacters(in: .whitespacesAndNewlines),
                !credit.isEmpty
            {
                Text(credit)
                    .font(AppTypography.overviewFont(.caption, scale: textScale))
                    .foregroundStyle(currentTertiaryTextColor)
                    .textSelection(.enabled)
            }
        }
        // Ignore, not combine: the caption and credit are selectable (AppKit-backed) text, and the label already
        // carries both (DESIGN.md 16).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.leadImageAccessibilityLabel(leadImage))
    }

    // MARK: - Section 4: Key Facts

    private var keyFactsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Highlights")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundColor(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(validFacts) { fact in
                    HStack(alignment: .top, spacing: AppSpacing.xs) {
                        Circle()
                            .frame(width: AppSpacing.xxs, height: AppSpacing.xxs)
                            .foregroundColor(AppColor.accent)
                            .padding(.top, AppSpacing.eyebrowGap)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
                            Text(fact.text)
                                .font(AppTypography.overviewFont(.fact, scale: textScale))
                                .lineSpacing(AppSpacing.xxs * textScale)
                                .foregroundStyle(AppColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)

                            // Citation pills
                            citationPillsView(fact.citationIDs, spacing: AppSpacing.eyebrowGap)
                        }
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
        }
    }

    @ViewBuilder
    private func citationPillsView(_ citationIDs: [String], spacing: CGFloat = AppSpacing.xxs) -> some View {
        let validCitationIDs = citationIDs.filter { overview.citations[$0] != nil }
        if !validCitationIDs.isEmpty {
            HStack(spacing: spacing) {
                ForEach(validCitationIDs, id: \.self) { citID in
                    if let citation = overview.citations[citID] {
                        citationPill(citation)
                    }
                }
            }
        }
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
                ForEach(memberArticles) { article in
                    HStack(alignment: .center, spacing: AppSpacing.sm) {
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
                                .font(AppTypography.overviewFont(.caption, scale: textScale))
                                .foregroundStyle(currentTertiaryTextColor)
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
        .background(AppColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
        )
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
                                .font(AppTypography.overviewFont(.captionMedium, scale: textScale))
                                .foregroundStyle(currentTertiaryTextColor)
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
                    .help("Open the overview of this earlier event")
                    .accessibilityHint("Opens this earlier event")

                    if event.eventID != relatedEvents.last?.eventID {
                        Divider().opacity(Self.dividerOpacity(for: contrast))
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
        }
    }

    // MARK: - Section 5: Evidence Sections (Timeline, Perspectives, Angle)

    @ViewBuilder
    private var evidenceSections: some View {
        // Sections without enough data are absent
        if Self.hasEvidenceContent(
            timeline: overview.timeline,
            perspectives: overview.perspectives,
            thematicAngle: overview.thematicAngle,
            coverageSentiment: overview.coverageSentiment
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // Participant positions / perspectives, then how the event unfolded
                if !validPerspectives.isEmpty {
                    perspectivesSection
                }

                if !validTimeline.isEmpty {
                    timelineSection
                }

                // Thematic angle
                if Self.hasThematicAngleContent(overview.thematicAngle), let angle = overview.thematicAngle {
                    thematicAngleSection(angle)
                }

                // Coverage tone / sentiment (only when evaluation justifies it)
                if Self.hasCoverageSentimentContent(overview.coverageSentiment),
                    let sentiment = overview.coverageSentiment
                {
                    sentimentSection(sentiment)
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

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(validTimeline) { item in
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text(item.dateText)
                                .font(AppTypography.overviewFont(.annotation, scale: textScale))
                                .foregroundStyle(AppColor.accent)

                            if item.isFuturePlan {
                                TagView(
                                    title: "Plan",
                                    tint: AppColor.accent,
                                    font: AppTypography.overviewFont(.micro, scale: textScale)
                                )
                                .accessibilityLabel("Planned event")
                            }

                            if let pubDate = item.publicationDate, item.eventDate != nil {
                                Text("Reported \(formatTimelineDate(pubDate))")
                                    .font(AppTypography.overviewFont(.micro, scale: textScale))
                                    .foregroundStyle(currentTertiaryTextColor)
                            }
                        }
                        .frame(minWidth: 80, maxWidth: 110, alignment: .leading)

                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(item.summary)
                                .font(AppTypography.overviewFont(.body, scale: textScale))
                                .foregroundStyle(AppColor.primaryText)
                                .lineSpacing(AppSpacing.textStack * textScale)
                                .textSelection(.enabled)

                            citationPillsView(item.citationIDs)
                        }
                    }
                    .padding(.vertical, AppSpacing.xxs)

                    if item.id != validTimeline.last?.id {
                        Divider()
                            .opacity(Self.dividerOpacity(for: contrast))
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
        }
    }

    private var perspectivesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Perspectives")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(validPerspectives) { perspective in
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                            Text(perspective.participant)
                                .font(AppTypography.overviewFont(.emphasis, scale: textScale))
                                .foregroundStyle(AppColor.primaryText)
                                .textSelection(.enabled)

                            if let wire = perspective.originalWireSource, !wire.isEmpty {
                                Text("via \(wire) syndicate")
                                    .font(AppTypography.overviewFont(.captionMedium, scale: textScale))
                                    .foregroundStyle(currentTertiaryTextColor)
                            } else if let publisher = perspective.sourcePublisher, !publisher.isEmpty {
                                Text("via \(publisher)")
                                    .font(AppTypography.overviewFont(.captionMedium, scale: textScale))
                                    .foregroundStyle(currentTertiaryTextColor)
                            }
                        }

                        Text(perspective.position)
                            .font(AppTypography.overviewFont(.body, scale: textScale))
                            .foregroundStyle(currentSecondaryTextColor)
                            .lineSpacing(AppSpacing.textStack * textScale)
                            .textSelection(.enabled)

                        citationPillsView(perspective.citationIDs)
                            .padding(.top, AppSpacing.textStack)
                    }
                    .padding(.vertical, AppSpacing.xxs)

                    if perspective.id != validPerspectives.last?.id {
                        Divider()
                            .opacity(Self.dividerOpacity(for: contrast))
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
        }
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
                        .font(AppTypography.overviewFont(.body, scale: textScale))
                        .lineSpacing(AppSpacing.xxs * textScale)
                        .foregroundStyle(AppColor.primaryText)
                        .textSelection(.enabled)
                }

                let validAngleFacts = Self.filterValidFacts(angle.facts)
                if !validAngleFacts.isEmpty {
                    thematicAngleFactsView(validAngleFacts)
                } else if !angle.citationIDs.isEmpty {
                    citationPillsView(angle.citationIDs)
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
        }
    }

    private func thematicAngleFactsView(_ facts: [OverviewFact]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ForEach(facts) { fact in
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Circle()
                        .frame(width: AppSpacing.xxs, height: AppSpacing.xxs)
                        .foregroundStyle(AppColor.accent)
                        .padding(.top, AppSpacing.eyebrowGap)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(fact.text)
                            .font(AppTypography.overviewFont(.detail, scale: textScale))
                            .foregroundStyle(AppColor.primaryText)
                            .textSelection(.enabled)

                        citationPillsView(fact.citationIDs)
                    }
                }
            }
        }
        .padding(.top, AppSpacing.xxs)
    }

    private func sentimentSection(_ sentiment: OverviewCoverageSentiment) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Coverage tone")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundStyle(currentSecondaryTextColor)
                        .accessibilityHidden(true)
                    Text("\(sentiment.label) tone · automated estimate")
                        .font(AppTypography.overviewFont(.bodyMedium, scale: textScale))
                        .foregroundStyle(AppColor.primaryText)
                }

                if let rationale = sentiment.rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !rationale.isEmpty
                {
                    Text(rationale)
                        .font(AppTypography.overviewFont(.annotation, scale: textScale))
                        .foregroundStyle(currentSecondaryTextColor)
                        .lineSpacing(AppSpacing.textStack * textScale)
                        .textSelection(.enabled)
                }
            }
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(currentBorderStrokeColor, lineWidth: contrast == .increased ? 1.0 : 0.5)
            )
        }
    }
}
