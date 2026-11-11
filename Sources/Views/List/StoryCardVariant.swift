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

/// The Today edition presentations of the one story card (docs/design/today.md, #938). A lane chooses the variant;
/// the card's surface, button, context menu and accessibility actions are shared. The Lead is the hero carousel.
enum StoryCardVariant: Sendable, Equatable {
    case developing
    case standard
    case feature
    case coverage
    case compact

    /// The card's width in a lane row; nil where the container decides (the Compact grid).
    var laneWidth: CGFloat? {
        switch self {
        case .feature: return AppLayout.featureCardWidth
        case .compact: return nil
        case .developing, .standard, .coverage: return AppLayout.laneCardWidth
        }
    }

    var headlineLines: Int { self == .feature || self == .compact ? 3 : 2 }
}

/// What a Today card shows beyond the story itself (#1174). Every field is optional: a card shows only what has a
/// real source, and nothing here is derived on the main actor while a card draws.
struct StoryCardMetadata: Equatable, Sendable {
    /// The latest report's time, for the Developing status pill ("Updated 14 min ago").
    var updatedAt: Date?
    var publisherCount: Int?
    /// Reports that joined the event since the reader last opened it.
    var newReportCount: Int?
    /// Days on which the event had a report; the progress strip shows with three or more.
    var reportDays: Int?
    /// Investigation, Explainer or Opinion, from the classification only, never from length.
    var contentType: String?
    var readingMinutes: Int?
    /// Reports that are not copies of another, wire copy counted once.
    var originalReports: Int?
    /// Publisher names for the monogram stack, in coverage order.
    var publishers: [String] = []
    /// One attributed differing account from a stored overview.
    var differingAccount: String?
    /// The lane showing the card, which VoiceOver names after the card's own description.
    var laneName: String?
    /// The event the card opens, if any. The card's action captures its entry, and regrouping can change the event
    /// behind the same representative, so the card's update decision must see it.
    var eventID: String?

    /// "3 publishers · 2 new reports", leaving out what is unknown or zero.
    var coverageLine: String? {
        var parts: [String] = []
        if let publisherCount, publisherCount > 0 {
            parts.append("\(publisherCount) \(publisherCount == 1 ? "publisher" : "publishers")")
        }
        if let newReportCount, newReportCount > 0 {
            parts.append("\(newReportCount) new \(newReportCount == 1 ? "report" : "reports")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var originalReportsText: String? {
        guard let originalReports, originalReports > 0 else { return nil }
        return "\(originalReports) original \(originalReports == 1 ? "report" : "reports")"
    }

    var readingTimeText: String? {
        guard let readingMinutes, readingMinutes > 0 else { return nil }
        return "\(readingMinutes) min read"
    }

    /// What VoiceOver adds for the variant, as sentences after the card's read state. The update is given as a
    /// clock time, which stays true while the card is on screen; the pill's relative time ages on its own.
    func accessibilityText(for variant: StoryCardVariant) -> String {
        let parts: [String?]
        switch variant {
        case .developing: parts = developingAccessibilityParts
        case .feature: parts = [contentType, readingTimeText]
        case .coverage: parts = coverageAccessibilityParts
        case .standard, .compact: parts = []
        }
        return (parts + [laneName.map { "In \($0)" }]).compactMap { $0 }.map { " \($0)." }.joined()
    }

    private var developingAccessibilityParts: [String?] {
        [
            updatedAt.map { "Updated \($0.formatted(date: .abbreviated, time: .shortened))" },
            coverageLine?.replacingOccurrences(of: " · ", with: ", "),
            reportDays.flatMap { $0 >= 3 ? "Reports on \($0) days" : nil },
        ]
    }

    private var coverageAccessibilityParts: [String?] {
        [
            StoryCardMetadata(publisherCount: publisherCount).coverageLine,
            publishers.isEmpty ? nil : "Including \(publishers.prefix(3).formatted(.list(type: .and)))",
            originalReportsText,
            differingAccount.map { "Accounts differ. \($0)" },
        ]
    }
}

// MARK: - From a lane assignment (#1174)

extension TodayStoryAssignment {
    /// The card a lane shows for this story. Coverage replaces the Standard card only past the grouping gate; In
    /// Motion and The Deep Read keep their own cards.
    var cardVariant: StoryCardVariant {
        switch lane {
        case .inMotion: return .developing
        case .theDeepRead: return .feature
        case .theLatest: return .compact
        case .theLead, .yourBeat, .outsideYourUsual: return isCoverageConfident ? .coverage : .standard
        }
    }

    /// The stored reading time in whole minutes, or nil when all the app holds is the feed's summary: the length of
    /// a summary is not a reading time.
    var storedReadingMinutes: Int? {
        let summaryWords = entry.visibleArticles.map { $0.description.split(whereSeparator: \.isWhitespace).count }
        let summaryMinutes = Double(summaryWords.max() ?? 0) / 200
        guard readingTimeMinutes >= 1, readingTimeMinutes > summaryMinutes + 0.01 else { return nil }
        return Int(readingTimeMinutes.rounded(.up))
    }
}

extension StoryCardMetadata {
    /// Everything a Today card shows, from values the assignment pass and the event load already hold: no query
    /// and no text work happens here. `differingAccount` comes from a stored overview, read with the edition.
    init(_ assignment: TodayStoryAssignment, differingAccount: String? = nil, calendar: Calendar = .current) {
        self.init()
        contentType = assignment.contentTypeLabel?.rawValue
        readingMinutes = assignment.storedReadingMinutes
        guard case .event(let summary, _, _) = assignment.entry, summary.isConfirmed else { return }
        updatedAt = summary.latestDate
        publisherCount = assignment.publisherCount
        newReportCount = summary.newReportCount
        reportDays = summary.reportDayCount(calendar: calendar)
        originalReports = assignment.originalReportCount
        publishers = summary.sources
        self.differingAccount = differingAccount
    }
}

extension StoryCardMetadata {
    /// One attributed differing account for the Coverage card: the positions two different publishers reported, in
    /// the overview's order. Nil unless two publishers are named, so the card never implies a difference from one.
    static func differingAccount(in perspectives: [OverviewPerspective]) -> String? {
        var seen = Set<String>()
        let attributed = perspectives.compactMap { perspective -> String? in
            let position = perspective.position.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let publisher = perspective.sourcePublisher, !publisher.isEmpty, !position.isEmpty,
                seen.insert(publisher.lowercased()).inserted
            else { return nil }
            return "\(publisher): \(position)" + (position.hasSuffix(".") ? "" : ".")
        }
        return attributed.count >= 2 ? attributed.prefix(2).joined(separator: " ") : nil
    }
}

// MARK: - Edition faces

extension ArticleCardView {
    @ViewBuilder
    func editionFace(_ variant: StoryCardVariant) -> some View {
        if variant == .compact {
            compactFace
        } else {
            VStack(alignment: .leading, spacing: 0) {
                editionImage(variant)
                editionText(variant)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Image

    /// The top image: 140 pt, or 3:2 on Feature.
    private func editionImage(_ variant: StoryCardVariant) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: variant == .feature ? AppLayout.featureImageHeight : AppLayout.editorialHeaderHeight)
            .overlay { editionPhoto(size: .card) }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    /// The story's photo filling its frame, or the editorial placeholder while it loads, fails or is missing.
    @ViewBuilder
    private func editionPhoto(size: DecodedImageCache.Size) -> some View {
        if let url = cardImageURL {
            ArticleRemoteImage(url: url, size: size) { phase in
                ZStack {
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill).scaleEffect(imageScale)
                    } else {
                        editorialPlaceholder
                    }
                }
                .animation(reduceMotion ? nil : AppMotion.state, value: phase.image != nil)
            }
        } else {
            editorialPlaceholder
        }
    }

    // MARK: Text

    private func editionText(_ variant: StoryCardVariant) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
            editionEyebrow(variant)
            // Room for the variant's full headline and two lines of dek, so the cards of a row end level.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
                    Text(verbatim: Array(repeating: "A", count: variant.headlineLines).joined(separator: "\n"))
                        .font(AppTypography.editionHeadline(feature: variant == .feature, isRead: false))
                    Text(verbatim: "A\nA").font(AppTypography.body)
                }
                .hidden()
                VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
                    editionHeadline(variant)
                    editionDek
                }
            }
            Spacer(minLength: AppSpacing.xxs)
            editionFooter(variant)
        }
        .padding(variant == .feature ? AppSpacing.md : AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Publisher, the saved glyph and, on a Developing card, its status pill at the trailing end, as the approved
    /// mock places it. Today cards show no unread dot: the headline's weight and color carry it.
    private func editionEyebrow(_ variant: StoryCardVariant) -> some View {
        HStack(spacing: AppSpacing.eyebrowGap) {
            EyebrowText(displaySource)
            Spacer(minLength: 0)
            if variant == .developing, let updatedAt = metadata.updatedAt {
                UpdatedPill(date: updatedAt)
            }
            if isSaved {
                Image(systemName: "bookmark.fill")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AppColor.accentText)
                    .accessibilityLabel("Saved")
            }
        }
    }

    private func editionHeadline(_ variant: StoryCardVariant) -> some View {
        Text(article.title)
            .font(AppTypography.editionHeadline(feature: variant == .feature, isRead: isRead))
            .foregroundStyle(isRead ? AppColor.secondaryText : AppColor.primaryText)
            .lineLimit(variant.headlineLines)
            .multilineTextAlignment(.leading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var editionDek: some View {
        let dek = CardText.cleaned(article.description)
        if !dek.isEmpty {
            Text(dek)
                .font(AppTypography.body)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private var editionDate: some View {
        CardDateText(article: article)
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.tertiaryText(for: contrast))
            .monospacedDigit()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
    }

    /// The line under the dek. Every part is absent without its data; a Developing or Coverage card with none
    /// falls back to the date, so no card ends on an empty line.
    @ViewBuilder
    private func editionFooter(_ variant: StoryCardVariant) -> some View {
        switch variant {
        case .developing: developingFooter
        case .feature: featureFooter
        case .coverage: coverageFooter
        case .standard, .compact: editionDate
        }
    }

    private var developingFooter: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let line = metadata.coverageLine { caption(line) } else { editionDate }
            if let days = metadata.reportDays, days >= 3 { ProgressStrip(days: days) }
        }
    }

    private var featureFooter: some View {
        HStack(spacing: AppSpacing.xs) {
            if let type = metadata.contentType { TagView(title: type) }
            if let time = metadata.readingTimeText { caption(time) }
            Spacer(minLength: AppSpacing.xs)
            editionDate
        }
    }

    private var coverageFooter: some View {
        let publishers = StoryCardMetadata(publisherCount: metadata.publisherCount).coverageLine
        let original = metadata.originalReportsText
        return VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
            coverageCounts(publishers: publishers, original: original)
            if let account = metadata.differingAccount {
                Divider()
                (Text("Accounts differ. ").font(AppTypography.caption.weight(.semibold))
                    + Text(account).font(AppTypography.caption))
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    /// The counts row. Without either count the date stands in for the counts alone: the monograms and the
    /// differing account render whenever their data exists.
    private func coverageCounts(publishers: String?, original: String?) -> some View {
        HStack(spacing: AppSpacing.eyebrowGap) {
            if publishers == nil, original == nil {
                editionDate
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .accessibilityHidden(true)
                if let publishers { caption(publishers) }
                if let original {
                    Text(original)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.originalReports)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if !metadata.publishers.isEmpty {
                PublisherMonograms(publishers: metadata.publishers, ring: AppColor.surface)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Compact

    /// The Latest's card: the photo fills the trailing side and dissolves toward the text, which may run over the
    /// dissolving edge. A story with no image has no photo and no fade.
    private var compactFace: some View {
        VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
            EyebrowText(displaySource)
            editionHeadline(.compact)
            Spacer(minLength: AppSpacing.xxs)
            HStack(spacing: AppSpacing.xs) {
                editionDate
                if isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AppColor.accentText)
                        .accessibilityLabel("Saved")
                }
            }
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: AppLayout.compactCardMinimumHeight, alignment: .leading)
        .modifier(LeadingShare(share: cardImageURL == nil ? 1 : AppLayout.compactTextShare))
        .background {
            if cardImageURL != nil {
                GeometryReader { card in
                    let width = card.size.width * AppLayout.compactPhotoShare
                    Color.clear
                        .overlay { editionPhoto(size: .card) }
                        .clipped()
                        // ponytail: a gradient of the card's own fill instead of a baked alpha fade and progressive
                        // blur per image; bake it if Z5 (#937) finds the grid can afford one more pass per photo.
                        .overlay(alignment: .leading) {
                            AppColor.compactPhotoFade.frame(width: width * AppLayout.compactPhotoFadeShare)
                        }
                        .frame(width: width)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

/// Gives its content the leading share of the offered width and keeps the full width itself.
private struct LeadingShare: ViewModifier {
    let share: CGFloat

    func body(content: Content) -> some View {
        ShareLayout(share: share) { content }
    }

    private struct ShareLayout: Layout {
        let share: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            guard let width = proposal.width, let child = subviews.first else {
                return subviews.first?.sizeThatFits(proposal) ?? .zero
            }
            let size = child.sizeThatFits(ProposedViewSize(width: width * share, height: proposal.height))
            return CGSize(width: width, height: size.height)
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            subviews.first?.place(
                at: bounds.origin, proposal: ProposedViewSize(width: bounds.width * share, height: bounds.height))
        }
    }
}

// MARK: - Parts

/// The Developing card's one status: "Updated 14 min ago", aging on its own each minute.
struct UpdatedPill: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text("Updated \(FeedArticle.relativeUpdateText(for: date, now: context.date, abbreviated: true))")
                .font(AppTypography.eyebrow)
                .monospacedDigit()
                .foregroundStyle(AppColor.leadText)
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, AppSpacing.xxs)
                .background(AppColor.statusPill, in: Capsule())
        }
    }
}

/// One ring per report day on a rail across the card, oldest first, the newest filled in the accent. At most seven
/// days: an older event shows its last week.
struct ProgressStrip: View {
    let days: Int

    var body: some View {
        let shown = min(days, 7)
        HStack(spacing: 0) {
            ForEach(0..<shown, id: \.self) { index in
                if index > 0 {
                    Rectangle().fill(AppColor.borderSubtle).frame(height: AppLayout.hairline * 2)
                }
                if index == shown - 1 {
                    Circle().fill(AppColor.accent)
                        .frame(width: AppLayout.progressDotSize, height: AppLayout.progressDotSize)
                } else {
                    Circle().strokeBorder(AppColor.tertiaryText, lineWidth: AppLayout.hoverStroke)
                        .frame(width: AppLayout.progressDotSize, height: AppLayout.progressDotSize)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Up to three overlapping publisher marks: the name's first letter on a stable color per publisher. The whole
/// stack is one element whose help text names the publishers.
struct PublisherMonograms: View {
    let publishers: [String]
    /// The surface behind the stack, drawn as each mark's ring so overlapping marks stay apart.
    let ring: Color
    /// A wash of the publisher's color with a darker letter, for a card's surface; solid marks sit on The Lead's
    /// image.
    var tinted = true

    var body: some View {
        HStack(spacing: -AppLayout.cardMonogramOverlap) {
            ForEach(Array(publishers.prefix(3).enumerated()), id: \.offset) { _, name in
                Circle()
                    .fill(ring)
                    .overlay { Circle().fill(AppColor.publisherMonogramFill(name, tinted: tinted)) }
                    .overlay {
                        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                            .font(AppTypography.monogram)
                            .textCase(.uppercase)
                            .foregroundStyle(
                                tinted ? AppColor.publisherMonogramText(name) : AppColor.leadText)
                    }
                    .overlay { Circle().strokeBorder(ring, lineWidth: AppLayout.cardMonogramStroke) }
                    .frame(width: AppLayout.cardMonogramSize, height: AppLayout.cardMonogramSize)
            }
        }
        .help(publishers.formatted(.list(type: .and)))
        .accessibilityHidden(true)
    }
}
