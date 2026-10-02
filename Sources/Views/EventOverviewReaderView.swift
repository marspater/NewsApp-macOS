// EventOverviewReaderView.swift
// NewsApp Event Overview Reader Mode & Source Navigation

import SwiftUI
import AppKit

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
    let onSelectArticle: (FeedArticle) -> Void
    let onSelectCitation: (OverviewCitation, FeedArticle?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSourcesExpanded: Bool = false
    @State private var activeCitationPreview: OverviewCitation? = nil

    private var uniquePublishers: [String] {
        var set = Set<String>()
        var list: [String] = []
        for article in memberArticles {
            let src = article.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !src.isEmpty && !set.contains(src) {
                set.insert(src)
                list.append(src)
            }
        }
        if list.isEmpty {
            for citation in overview.citations.values {
                if let name = citation.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !set.contains(name) {
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

    private var borderStrokeColor: Color {
        contrast == .increased ? AppColor.primaryText.opacity(0.3) : AppColor.borderSubtle
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
                VStack(alignment: .leading, spacing: 24) {
                    // 1. Header: Eyebrow, Title, Update Time, Article & Publisher Counts
                    headerSection

                    // 2. Short introduction: one or two paragraphs
                    if !overview.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        introductionSection
                    }

                    // 3. Fitting main image with caption and source
                    if let leadImage = overview.leadImage, !leadImage.url.isEmpty {
                        leadImageSection(leadImage)
                    }

                    // 4. Three to five key facts with links
                    if !overview.facts.isEmpty {
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
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .background(AppColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Event overview: \(overview.title)")
    }

    // MARK: - Section 1: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("EVENT OVERVIEW")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(AppColor.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppColor.accent.opacity(0.12))
                    .clipShape(Capsule())

                if overview.kind == .fallbackExcerpts {
                    Text("VERIFIED EXCERPTS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(AppColor.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppColor.badgeBackground)
                        .clipShape(Capsule())
                }
            }

            Text(overview.title)
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundColor(AppColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHeading(.h1)

            HStack(spacing: 6) {
                Text("Updated \(formattedUpdateTime)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)

                Text("·")
                    .foregroundColor(AppColor.tertiaryText)

                Text(articleCountText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)

                Text("·")
                    .foregroundColor(AppColor.tertiaryText)

                Text(publisherCountText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Section 2: Introduction

    private var introductionSection: some View {
        let paragraphs = overview.summary
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                Text(para)
                    .font(.system(size: 16, weight: .regular))
                    .lineSpacing(6)
                    .foregroundColor(AppColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Section 3: Lead Image

    @ViewBuilder
    private func leadImageSection(_ leadImage: OverviewLeadImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = URL(string: leadImage.url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxHeight: 380)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else if phase.error != nil {
                        // Image failed to load: gracefully omit visual box
                        EmptyView()
                    } else {
                        Rectangle()
                            .fill(AppColor.surface)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(ProgressView().scaleEffect(0.8))
                    }
                }
            }

            if let caption = leadImage.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }

            if let credit = leadImage.credit, !credit.isEmpty {
                Text(credit)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(AppColor.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(leadImage.caption ?? "Event lead image")
    }

    // MARK: - Section 4: Key Facts

    private var keyFactsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Key facts")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColor.primaryText)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(overview.facts) { fact in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(AppColor.accent)
                            .padding(.top, 7)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(fact.text)
                                .font(.system(size: 15, weight: .regular))
                                .lineSpacing(4)
                                .foregroundColor(AppColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            // Citation pills
                            if !fact.citationIDs.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(fact.citationIDs, id: \.self) { citID in
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
            .padding(16)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderStrokeColor, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func citationPill(_ citation: OverviewCitation) -> some View {
        let matchingArticle = memberArticles.first { $0.id == citation.articleID }
        let label = citation.sourceName ?? matchingArticle?.source ?? "Source"

        Button {
            onSelectCitation(citation, matchingArticle)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(AppColor.accent.opacity(0.12))
            .foregroundColor(AppColor.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open in Source publication: \"\(citation.quote)\"")
        .accessibilityLabel("Citation from \(label): \(citation.quote). Double tap to open source article.")
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSourcesExpanded = val
                        }
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(memberArticles) { article in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(article.source)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(AppColor.accent)

                            Text(article.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColor.primaryText)
                                .lineLimit(1)

                            Text(article.publicationDateText)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(AppColor.tertiaryText)
                        }

                        Spacer()

                        Button("Read") {
                            onSelectArticle(article)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Read this article in Source publication mode")

                        if let url = URL(string: article.link) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(AppColor.secondaryText)
                            .help("Open original web publication")
                        }
                    }
                    .padding(.vertical, 4)

                    if article.id != memberArticles.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "newspaper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColor.accent)

                Text("Sources (\(memberArticles.count))")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppColor.primaryText)
            }
        }
        .padding(14)
        .background(AppColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderStrokeColor, lineWidth: 1)
        )
    }

    // MARK: - Section 6: Evidence Sections (Timeline, Perspectives, Angle)

    @ViewBuilder
    private var evidenceSections: some View {
        // Sections without enough data are absent
        if !overview.timeline.isEmpty || !overview.perspectives.isEmpty || overview.thematicAngle != nil {
            VStack(alignment: .leading, spacing: 22) {
                // Timeline
                if !overview.timeline.isEmpty {
                    timelineSection
                }

                // Participant positions / perspectives
                if !overview.perspectives.isEmpty {
                    perspectivesSection
                }

                // Thematic angle
                if let angle = overview.thematicAngle {
                    thematicAngleSection(angle)
                }
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColor.primaryText)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(overview.timeline) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.dateText)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(AppColor.accent)

                            if item.isFuturePlan {
                                Text("Plan")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }

                            if let pubDate = item.publicationDate, item.eventDate != nil {
                                Text("Reported \(formatTimelineDate(pubDate))")
                                    .font(.system(size: 10))
                                    .foregroundColor(AppColor.tertiaryText)
                            }
                        }
                        .frame(minWidth: 90, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.summary)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(AppColor.primaryText)
                                .lineSpacing(3)

                            if !item.citationIDs.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(item.citationIDs, id: \.self) { citID in
                                        if let citation = overview.citations[citID] {
                                            citationPill(citation)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if item.id != overview.timeline.last?.id {
                        Divider()
                    }
                }
            }
            .padding(16)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderStrokeColor, lineWidth: 1)
            )
        }
    }

    private var perspectivesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Perspectives")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColor.primaryText)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(overview.perspectives) { perspective in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(perspective.participant)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(AppColor.primaryText)

                        Text(perspective.position)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(AppColor.secondaryText)
                            .lineSpacing(3)

                        if !perspective.citationIDs.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(perspective.citationIDs, id: \.self) { citID in
                                    if let citation = overview.citations[citID] {
                                        citationPill(citation)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)

                    if perspective.id != overview.perspectives.last?.id {
                        Divider()
                    }
                }
            }
            .padding(16)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderStrokeColor, lineWidth: 1)
            )
        }
    }

    private func thematicAngleSection(_ angle: OverviewThematicAngle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(angle.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColor.primaryText)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: 8) {
                Text(angle.summary)
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(4)
                    .foregroundColor(AppColor.primaryText)

                if !angle.citationIDs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(angle.citationIDs, id: \.self) { citID in
                            if let citation = overview.citations[citID] {
                                citationPill(citation)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(AppColor.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderStrokeColor, lineWidth: 1)
            )
        }
    }

    // MARK: - Section 7: Original Publications

    private var originalPublicationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original publications")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppColor.primaryText)
                .accessibilityHeading(.h2)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(memberArticles) { article in
                    if let url = URL(string: article.link) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColor.accent)

                                Text(article.source)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(AppColor.primaryText)

                                Text("—")
                                    .foregroundColor(AppColor.tertiaryText)

                                Text(article.title)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(AppColor.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open original article on \(article.source)")
                        .accessibilityLabel("Open original publication: \(article.title) by \(article.source)")
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}
