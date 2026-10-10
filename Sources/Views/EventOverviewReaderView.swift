// EventOverviewReaderView.swift
// NewsApp Event Overview Reader Mode & Source Navigation

import AppKit
import SwiftUI

/// Native SwiftUI reader view for multi-source event overviews.
/// Implements the 7 editorial sections in order:
/// 1. Title, update time, article count and publisher count
/// 2. Short introduction (1–2 paragraphs)
/// 3. Fitting main image with caption and attribution
/// 4. Key verified facts with passage-anchored citation links
/// 5. Compact expandable source list
/// 6. Evidence sections: timeline, participant perspectives, thematic angle
/// 7. Links to original publications
/// Sections without enough data are absent.
struct EventOverviewReaderView: View {
    let overview: EventOverviewDocument
    let memberArticles: [FeedArticle]
    let textScale: CGFloat
    let onSelectArticle: (FeedArticle) -> Void
    let onSelectCitation: (OverviewCitation, FeedArticle?) -> Void

    init(
        overview: EventOverviewDocument,
        memberArticles: [FeedArticle],
        textScale: CGFloat = 1.0,
        onSelectArticle: @escaping (FeedArticle) -> Void,
        onSelectCitation: @escaping (OverviewCitation, FeedArticle?) -> Void
    ) {
        self.overview = overview
        self.memberArticles = memberArticles
        self.textScale = textScale
        self.onSelectArticle = onSelectArticle
        self.onSelectCitation = onSelectCitation
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    @State private var isSourcesExpanded: Bool = false
    @State private var activeCitationPreview: OverviewCitation? = nil

    // MARK: - Layout Metrics & Bounds
    static let horizontalPageInset: CGFloat = 24.0

    static func readingColumnMaxWidth(for scale: CGFloat) -> CGFloat {
        720.0 * min(scale, 1.3)
    }

    // MARK: - Contrast & Color Scalers
    static func borderStrokeColor(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? AppColor.primaryText.opacity(0.50) : AppColor.borderSubtle
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
        contrast == .increased ? AppColor.secondaryText : AppColor.tertiaryText
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
        reduceMotion ? nil : .easeInOut(duration: 0.2)
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
        return count == 1 ? "1 article" : "\(count) articles"
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

                    // 5. Compact expandable source list
                    if !memberArticles.isEmpty {
                        compactSourcesSection
                    }

                    // 6. With evidence: timeline, participant positions, thematic angle
                    evidenceSections

                    // 7. Links to original publications
                    if !memberArticles.isEmpty {
                        originalPublicationsSection
                    }
                }
                .padding(.horizontal, Self.horizontalPageInset)
                .padding(.vertical, AppSpacing.lg)
                .frame(maxWidth: Self.readingColumnMaxWidth(for: textScale), alignment: .leading)
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
                        title: "Verified excerpts", tint: currentSecondaryTextColor,
                        font: AppTypography.overviewFont(.eyebrow, scale: textScale))
                }
            }
            .accessibilityElement(children: .combine)

            Text(overview.title)
                .font(AppTypography.overviewFont(.title, scale: textScale))
                .foregroundColor(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .textSelection(.enabled)

            HStack(spacing: AppSpacing.eyebrowGap) {
                Text("Updated \(formattedUpdateTime)")
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundColor(currentSecondaryTextColor)

                Text("·")
                    .foregroundColor(currentTertiaryTextColor)
                    .accessibilityHidden(true)

                Text(articleCountText)
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundColor(currentSecondaryTextColor)

                Text("·")
                    .foregroundColor(currentTertiaryTextColor)
                    .accessibilityHidden(true)

                Text(publisherCountText)
                    .font(AppTypography.overviewFont(.metadata, scale: textScale))
                    .foregroundColor(currentSecondaryTextColor)
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
                        .foregroundColor(AppColor.primaryText)
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
                        .foregroundColor(AppColor.primaryText)
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
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxHeight: 380)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    } else if phase.error != nil {
                        EmptyView()
                    } else {
                        Rectangle()
                            .fill(AppColor.surface)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                            .overlay(ProgressView().scaleEffect(0.8))
                    }
                }
                .accessibilityHidden(true)
            }

            if let caption = leadImage.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
                Text(caption)
                    .font(AppTypography.overviewFont(.annotation, scale: textScale))
                    .foregroundColor(currentSecondaryTextColor)
                    .textSelection(.enabled)
            }

            if let credit = leadImage.credit?.trimmingCharacters(in: .whitespacesAndNewlines), !credit.isEmpty {
                Text(credit)
                    .font(AppTypography.overviewFont(.caption, scale: textScale))
                    .foregroundColor(currentTertiaryTextColor)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.leadImageAccessibilityLabel(leadImage))
    }

    // MARK: - Section 4: Key Facts

    private var keyFactsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Key facts")
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
                                .foregroundColor(AppColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)

                            // Citation pills
                            let validCitationIDs = fact.citationIDs.filter { overview.citations[$0] != nil }
                            if !validCitationIDs.isEmpty {
                                HStack(spacing: AppSpacing.eyebrowGap) {
                                    ForEach(validCitationIDs, id: \.self) { citID in
                                        if let citation = overview.citations[citID] {
                                            citationPill(citation)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .stroke(currentBorderStrokeColor, lineWidth: 1)
            )
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
        .help("Open in Source publication: “\(citation.quote)”")
        .accessibilityLabel(Self.citationAccessibilityLabel(sourceName: label, quote: citation.quote))
        .accessibilityHint("Opens source publication at cited passage")
    }

    // MARK: - Section 5: Compact Expandable Source List

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
                                .foregroundColor(AppColor.primaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)

                            Text(article.publicationDateText)
                                .font(AppTypography.overviewFont(.caption, scale: textScale))
                                .foregroundColor(currentTertiaryTextColor)
                        }

                        Spacer(minLength: 8)

                        Button("Read") {
                            onSelectArticle(article)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Read this article in Source publication mode")
                        .accessibilityLabel(
                            Self.readArticleAccessibilityLabel(title: article.title, source: article.publisherName))

                        if let url = URL(string: article.link) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .imageScale(.small)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(currentSecondaryTextColor)
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
                    .foregroundColor(AppColor.accent)
                    .accessibilityHidden(true)

                Text("Sources (\(memberArticles.count))")
                    .font(AppTypography.overviewFont(.subheading, scale: textScale))
                    .foregroundColor(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
            }
        }
        .padding(AppSpacing.sm)
        .background(AppColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(currentBorderStrokeColor, lineWidth: 1)
        )
    }

    // MARK: - Section 6: Evidence Sections (Timeline, Perspectives, Angle)

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
                // Timeline
                if !validTimeline.isEmpty {
                    timelineSection
                }

                // Participant positions / perspectives
                if !validPerspectives.isEmpty {
                    perspectivesSection
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
                .foregroundColor(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(validTimeline) { item in
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                            Text(item.dateText)
                                .font(AppTypography.overviewFont(.annotation, scale: textScale))
                                .foregroundColor(AppColor.accent)

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
                                    .foregroundColor(currentTertiaryTextColor)
                            }
                        }
                        .frame(minWidth: 80, maxWidth: 110, alignment: .leading)

                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(item.summary)
                                .font(AppTypography.overviewFont(.body, scale: textScale))
                                .foregroundColor(AppColor.primaryText)
                                .lineSpacing(AppSpacing.textStack * textScale)
                                .textSelection(.enabled)

                            let validCitationIDs = item.citationIDs.filter { overview.citations[$0] != nil }
                            if !validCitationIDs.isEmpty {
                                HStack(spacing: AppSpacing.xxs) {
                                    ForEach(validCitationIDs, id: \.self) { citID in
                                        if let citation = overview.citations[citID] {
                                            citationPill(citation)
                                        }
                                    }
                                }
                            }
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
                    .stroke(currentBorderStrokeColor, lineWidth: 1)
            )
        }
    }

    private var perspectivesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Perspectives")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundColor(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(validPerspectives) { perspective in
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                            Text(perspective.participant)
                                .font(AppTypography.overviewFont(.emphasis, scale: textScale))
                                .foregroundColor(AppColor.primaryText)
                                .textSelection(.enabled)

                            if let wire = perspective.originalWireSource, !wire.isEmpty {
                                Text("via \(wire) syndicate")
                                    .font(AppTypography.overviewFont(.captionMedium, scale: textScale))
                                    .foregroundColor(currentTertiaryTextColor)
                            } else if let publisher = perspective.sourcePublisher, !publisher.isEmpty {
                                Text("via \(publisher)")
                                    .font(AppTypography.overviewFont(.captionMedium, scale: textScale))
                                    .foregroundColor(currentTertiaryTextColor)
                            }
                        }

                        Text(perspective.position)
                            .font(AppTypography.overviewFont(.body, scale: textScale))
                            .foregroundColor(currentSecondaryTextColor)
                            .lineSpacing(AppSpacing.textStack * textScale)
                            .textSelection(.enabled)

                        let validCitationIDs = perspective.citationIDs.filter { overview.citations[$0] != nil }
                        if !validCitationIDs.isEmpty {
                            HStack(spacing: AppSpacing.xxs) {
                                ForEach(validCitationIDs, id: \.self) { citID in
                                    if let citation = overview.citations[citID] {
                                        citationPill(citation)
                                    }
                                }
                            }
                            .padding(.top, AppSpacing.textStack)
                        }
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
                    .stroke(currentBorderStrokeColor, lineWidth: 1)
            )
        }
    }

    private func thematicAngleSection(_ angle: OverviewThematicAngle) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(angle.title)
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundColor(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if !angle.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(angle.summary)
                        .font(AppTypography.overviewFont(.body, scale: textScale))
                        .lineSpacing(AppSpacing.xxs * textScale)
                        .foregroundColor(AppColor.primaryText)
                        .textSelection(.enabled)
                }

                let validAngleFacts = Self.filterValidFacts(angle.facts)
                if !validAngleFacts.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(validAngleFacts) { fact in
                            HStack(alignment: .top, spacing: AppSpacing.xs) {
                                Circle()
                                    .frame(width: AppSpacing.xxs, height: AppSpacing.xxs)
                                    .foregroundColor(AppColor.accent)
                                    .padding(.top, AppSpacing.eyebrowGap)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text(fact.text)
                                        .font(AppTypography.overviewFont(.detail, scale: textScale))
                                        .foregroundColor(AppColor.primaryText)
                                        .textSelection(.enabled)

                                    let validCitationIDs = fact.citationIDs.filter { overview.citations[$0] != nil }
                                    if !validCitationIDs.isEmpty {
                                        HStack(spacing: AppSpacing.xxs) {
                                            ForEach(validCitationIDs, id: \.self) { citID in
                                                if let citation = overview.citations[citID] {
                                                    citationPill(citation)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, AppSpacing.xxs)
                } else if !angle.citationIDs.isEmpty {
                    let validCitationIDs = angle.citationIDs.filter { overview.citations[$0] != nil }
                    if !validCitationIDs.isEmpty {
                        HStack(spacing: AppSpacing.xxs) {
                            ForEach(validCitationIDs, id: \.self) { citID in
                                if let citation = overview.citations[citID] {
                                    citationPill(citation)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .stroke(currentBorderStrokeColor, lineWidth: 1)
            )
        }
    }

    private func sentimentSection(_ sentiment: OverviewCoverageSentiment) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Coverage tone")
                .font(AppTypography.overviewFont(.section, scale: textScale))
                .foregroundColor(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundColor(currentSecondaryTextColor)
                        .accessibilityHidden(true)
                    Text("\(sentiment.label) tone · automated estimate")
                        .font(AppTypography.overviewFont(.bodyMedium, scale: textScale))
                        .foregroundColor(AppColor.primaryText)
                }

                if let rationale = sentiment.rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !rationale.isEmpty
                {
                    Text(rationale)
                        .font(AppTypography.overviewFont(.annotation, scale: textScale))
                        .foregroundColor(currentSecondaryTextColor)
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
                    .stroke(currentBorderStrokeColor, lineWidth: 1)
            )
        }
    }

    // MARK: - Section 7: Original Publications

    private var originalPublicationsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Original publications")
                .font(AppTypography.overviewFont(.subheading, scale: textScale))
                .foregroundColor(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(memberArticles) { article in
                    if let url = URL(string: article.link) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: "arrow.up.forward.square")
                                    .imageScale(.small)
                                    .foregroundColor(AppColor.accent)
                                    .accessibilityHidden(true)

                                Text(article.publisherName)
                                    .font(AppTypography.overviewFont(.emphasis, scale: textScale))
                                    .foregroundColor(AppColor.primaryText)

                                Text("—")
                                    .foregroundColor(currentTertiaryTextColor)
                                    .accessibilityHidden(true)

                                Text(article.title)
                                    .font(AppTypography.overviewFont(.detail, scale: textScale))
                                    .foregroundColor(currentSecondaryTextColor)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, AppSpacing.xxs)
                            .padding(.horizontal, AppSpacing.eyebrowGap)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open original article on \(article.publisherName)")
                        .accessibilityLabel(
                            Self.openWebArticleAccessibilityLabel(title: article.title, source: article.publisherName))
                    }
                }
            }
        }
        .padding(.top, AppSpacing.xs)
    }
}
