// ArticleCardView.swift
// NewsApp Story Card View

import AppKit
import SwiftUI

struct ArticleCardView<Footer: View>: View {
    let article: FeedArticle
    var isSelected: Bool = false
    var compact: Bool = false
    /// Other coverage of the same event; the card shows the best of their images when this article has none.
    var imageFallbacks: [FeedArticle] = []
    /// Opt-in to the macOS 26 image-backed lead treatment.
    var isLead = false
    /// A grid card without coverage keeps the coverage row's height inside its button, so it ends level with the
    /// event cards of its row and the whole card still opens the story (#779).
    var reservesCoverageRow = false
    let action: () -> Void
    /// Rows that share the card surface below the story, such as an event's coverage; `EmptyView()` for none.
    let footer: Footer

    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var isHovered = false

    private var cardImageURL: URL? {
        FeedArticle.bestCardImage(in: [article] + imageFallbacks)
    }

    private var isRead: Bool {
        readManager.isRead(article.id)
    }

    private var isSaved: Bool {
        savedStories.isSaved(article)
    }

    /// The muting action for this story's publisher host: unmute the rules covering it, or mute the host.
    private var sourceMuting: (title: String, apply: () -> Void)? {
        appSettings.sourceMuting(for: article.link)
    }

    /// The image-backed lead needs macOS 26 and an image to show.
    private var showsLeadImage: Bool {
        if #available(macOS 26.0, *), isLead, cardImageURL != nil { return true }
        return false
    }

    private var radius: CGFloat {
        showsLeadImage ? AppRadius.container : AppRadius.card
    }

    private var cardLayout: AnyLayout {
        compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
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
            AppColor.border(for: contrast), AppLayout.hairline, AppShadow.cardRestingColor, AppShadow.cardRestingRadius,
            AppShadow.cardRestingY
        )
    }

    /// One surface for the story and its footer: the card fill, radius, stroke, shadow and hover.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                VStack(spacing: 0) {
                    cardFace
                    if reservesCoverageRow { CoverageRowSpace() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .buttonBorderShape(.roundedRectangle(radius: radius))
            .contextMenu {
                StoryContextMenuItems(article: article)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityAction(named: isRead ? "Mark as Unread" : "Mark as Read") {
                readManager.toggleRead(article.id)
            }
            .accessibilityAction(named: isSaved ? "Remove from Saved" : "Save Story") {
                if isSaved {
                    savedStories.remove(article)
                } else {
                    savedStories.save(article)
                }
            }
            .accessibilityActions {
                if let muting = sourceMuting {
                    Button(muting.title, action: muting.apply)
                }
            }

            footer
        }
        // A card is as tall as its own content: in a grid row it never stretches to a taller neighbour, such as an
        // event card showing its sources (#779).
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // The shadow is cast by the filled card shape rather than the composited card, whose shadow needed an
        // offscreen pass per card on every scrolled frame (#778). The card is opaque, so it looks the same.
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AppColor.surface)
                .shadow(color: appearance.shadow, radius: appearance.radius, x: 0, y: appearance.y)
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(appearance.border, lineWidth: appearance.width)
        )
        .animation(reduceMotion ? nil : AppMotion.hover, value: isHovered)
        .animation(reduceMotion ? nil : AppMotion.state, value: isSelected)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var cardFace: some View {
        if #available(macOS 26.0, *), isLead, let url = cardImageURL {
            ArticleRemoteImage(url: url) { phase in
                leadImage(for: phase, aspectRatio: DecodedImageCache.aspectRatio(for: url))
            }
        } else {
            cardLayout {
                cardImage
                regularStoryText
            }
            .frame(height: compact ? AppLayout.listCardHeight : nil)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func leadImage(for phase: AsyncImagePhase, aspectRatio: CGFloat?) -> some View {
        switch phase {
        case .success(let image):
            leadSurface(image: image, aspectRatio: aspectRatio)
        case .empty:
            leadSurface(image: nil)
        case .failure:
            leadSurface(image: nil, failed: true)
        @unknown default:
            leadSurface(image: nil, failed: true)
        }
    }

    // MARK: - Regular card

    private var cardHeaderHeight: CGFloat {
        compact ? AppLayout.listCardHeight : AppLayout.editorialHeaderHeight
    }

    /// The header image, or the editorial placeholder while it loads, fails or is missing. Grid cards keep one
    /// header height with or without an image, so a row's cards line up.
    private var cardImage: some View {
        Group {
            if let url = cardImageURL {
                ArticleRemoteImage(url: url) { phase in
                    if case .success(let image) = phase {
                        // The clear frame takes the column's size; a filled image wider than it must not push past it.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: cardHeaderHeight)
                            .overlay { image.resizable().aspectRatio(contentMode: .fill) }
                            .clipped()
                            // Clipping hides the overflow but does not stop it taking clicks meant for the card above.
                            .contentShape(Rectangle())
                    } else {
                        editorialPlaceholder
                    }
                }
            } else {
                editorialPlaceholder
            }
        }
        .frame(width: compact ? AppLayout.listCardImageWidth : nil, height: cardHeaderHeight)
        .accessibilityHidden(true)
    }

    private var regularStoryText: some View {
        VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
            // Eyebrow Row: Source + Badges
            regularEyebrow

            if compact {
                headline
                regularDescription
            } else {
                // A grid card keeps room for two lines of headline and two of summary, so the collapsed cards of a
                // row end level however long their text is; the text itself stays together at the top (#779).
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
                        Text(verbatim: "A\nA").font(AppTypography.cardHeadline(.grid))
                        Text(verbatim: "A\nA").font(AppTypography.body)
                    }
                    .hidden()
                    VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
                        headline
                        regularDescription
                    }
                }
            }

            Spacer(minLength: AppSpacing.xxs)

            // Footer Row: Timestamp & Optional AI Badge
            regularFooter
        }
        .padding(.horizontal, compact ? AppSpacing.lg : AppSpacing.sm)
        .padding(.vertical, compact ? AppSpacing.md : AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regularEyebrow: some View {
        HStack(spacing: AppSpacing.eyebrowGap) {
            EyebrowText(displaySource)
            Spacer()
            stateGlyphs()
        }
    }

    /// Saved glyph and unread dot, in this order, at the trailing end of the eyebrow line. The lead caption passes
    /// its light text color, since the darkened light-appearance accent is too dim on the dark scrim.
    @ViewBuilder
    private func stateGlyphs(saved: Color = AppColor.accentText) -> some View {
        if isSaved {
            Image(systemName: "bookmark.fill")
                .font(AppTypography.eyebrow)
                .foregroundStyle(saved)
                .accessibilityLabel("Saved")
        }
        if !isRead {
            UnreadDot()
        }
    }

    private var headline: some View {
        Text(article.title)
            .font(AppTypography.cardHeadline(compact ? .list : .grid))
            .foregroundStyle(isRead ? AppColor.secondaryText : AppColor.primaryText)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            // In the fixed-height list card the summary gives up lines before the headline does.
            .layoutPriority(1)
    }

    @ViewBuilder
    private var regularDescription: some View {
        if !article.description.isEmpty {
            let cleanDesc = CardText.cleaned(article.description)
            if !cleanDesc.isEmpty {
                Text(cleanDesc)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var regularFooter: some View {
        HStack(spacing: AppSpacing.xs) {
            Text(article.cardDateText())
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.tertiaryText(for: contrast))
                .monospacedDigit()

            Spacer()

            if article.aiSummary != nil {
                TagView.intelligence()
                    .help("AI summary available")
                    .accessibilityLabel("AI summary available")
            } else if !compact {
                // A grid card keeps the tag's height without it, so it ends level with a card that has one.
                TagView.intelligence().hidden()
            }
        }
    }

    /// A story without a usable image: a flat elevated surface and the newspaper glyph. It fills whatever frame
    /// its caller gives it, from a grid header to the whole lead.
    private var editorialPlaceholder: some View {
        AppColor.elevatedSurface
            .overlay(alignment: .topLeading) {
                Image(systemName: "newspaper")
                    .imageScale(.large)
                    .foregroundStyle(AppColor.quaternaryLabel)
                    .padding(AppSpacing.sm)
            }
    }

    // MARK: - Lead card

    /// Below this width-to-height ratio a lead image is framed whole rather than cropped to fill.
    static var wideLeadImageRatio: CGFloat { 1.25 }

    /// Square and portrait lead images (and wide ones only once their size is known) are framed whole.
    static func framesLeadImageWhole(aspectRatio: CGFloat?) -> Bool {
        aspectRatio.map { $0 < wideLeadImageRatio } ?? false
    }

    /// Wide images fill the frame anchored to the top, where subjects usually sit above the caption scrim.
    /// Square and portrait images are shown whole over a blurred copy of themselves, so faces are never cropped.
    /// A failed image leaves the editorial placeholder at full height; the card clips everything to one radius.
    @available(macOS 26.0, *)
    private func leadSurface(image: Image?, aspectRatio: CGFloat? = nil, failed: Bool = false) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Color.clear
                        .overlay(alignment: .top) {
                            if Self.framesLeadImageWhole(aspectRatio: aspectRatio) {
                                ZStack(alignment: .top) {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                        .blur(radius: AppLayout.leadBackdropBlur)
                                        .overlay(AppColor.leadBackdropDim)
                                    image.resizable().aspectRatio(contentMode: .fit)
                                }
                            } else {
                                image.resizable().aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                        }
                        .clipped()
                        .contentShape(Rectangle())
                } else if failed {
                    editorialPlaceholder
                } else {
                    // Keep the loading surface dark so the image caption stays readable.
                    AppColor.leadPlaceholder
                }
            }
            .accessibilityHidden(true)

            leadCaption
                .padding(.bottom, AppSpacing.sm)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppLayout.leadStoryHeight)
    }

    /// Dark image-caption backing remains legible at every glass transparency
    /// setting. Its lower corners follow the lead container's curvature.
    @available(macOS 26.0, *)
    private var leadCaption: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                EyebrowText(displaySource, color: AppColor.leadText)
                Spacer(minLength: AppSpacing.xs)
                stateGlyphs(saved: AppColor.leadText)
            }

            Text(article.title)
                .font(AppTypography.leadStoryHeadline)
                .foregroundStyle(isRead ? AppColor.leadSecondaryText : AppColor.leadText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)

            let cleanDescription = CardText.cleaned(article.description)
            if !cleanDescription.isEmpty {
                Text(cleanDescription)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColor.leadSecondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: AppSpacing.sm) {
                Text(article.cardDateText())
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.leadSecondaryText)
                    .monospacedDigit()
                Spacer(minLength: AppSpacing.xs)
                if article.aiSummary != nil {
                    TagView.intelligence(foreground: AppColor.leadText)
                        .help("AI summary available")
                        .accessibilityLabel("AI summary available")
                }
            }
        }
        .foregroundStyle(AppColor.leadText)
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ConcentricRectangle(
                uniformTopCorners: .fixed(AppRadius.control),
                uniformBottomCorners: .concentric(minimum: .fixed(AppRadius.card))
            )
            .fill(AppColor.leadScrim)
        }
        .padding(.horizontal, AppSpacing.sm)
    }

    // MARK: - Helpers

    private var displaySource: String { article.publisherName }

    private var accessibilityDescription: String {
        let readState = isRead ? "Read" : "Unread"
        let savedState = isSaved ? ", saved in your library" : ""
        let dateFormatted = article.publicationDateText
        return "\(article.title), from \(displaySource), published \(dateFormatted). \(readState)\(savedState)."
    }
}

/// The coverage row: symbol, coverage, last update, "Updated" tag and chevron. In a grid it keeps one line, an
/// abbreviated update and the tag's height with or without the tag, so every collapsed event card of a grid row is as
/// tall as the others (#779); list and lead cards keep the full text.
struct CoverageRowLabel: View {
    let coverageText: String
    let latestDate: Date?
    let hasUpdate: Bool
    let isExpanded: Bool
    let isGrid: Bool

    @Environment(\.effectiveContrast) private var contrast

    var body: some View {
        ZStack(alignment: .leading) {
            if isGrid { TagView(title: "Updated", tint: AppColor.accent).hidden() }
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "square.stack.3d.up")
                    .font(AppTypography.label)
                Text(coverageText)
                    .font(AppTypography.label)
                    .layoutPriority(1)
                if let latestDate {
                    Text(
                        "· updated \(latestDate, format: .relative(presentation: .named, unitsStyle: isGrid ? .abbreviated : .wide))"
                    )
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tertiaryText(for: contrast))
                    .monospacedDigit()
                }
                if hasUpdate {
                    TagView(title: "Updated", tint: AppColor.accent)
                }
                Spacer(minLength: AppSpacing.xs)
                Image(systemName: "chevron.down")
                    .font(AppTypography.eyebrow)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .lineLimit(isGrid ? 1 : nil)
        }
        .foregroundStyle(AppColor.secondaryText)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
    }
}

/// The room a grid story card without coverage keeps below its story: a hidden coverage row, so the collapsed cards
/// of a row end level whether or not they are events (#779).
struct CoverageRowSpace: View {
    var body: some View {
        Divider().hidden()
        CoverageRowLabel(coverageText: " ", latestDate: nil, hasUpdate: false, isExpanded: false, isGrid: true)
            .hidden()
            .accessibilityHidden(true)
    }
}

/// Feed summaries cleaned for cards, by raw text: card bodies run on every update while scrolling, the cleaning
/// regular expressions once per summary (#778).
@MainActor
private enum CardText {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2000
        return cache
    }()

    static func cleaned(_ raw: String) -> String {
        if let cached = cache.object(forKey: raw as NSString) { return cached as String }
        let cleaned = ArticleContentRedactor.cleanText(raw)
        cache.setObject(cleaned as NSString, forKey: raw as NSString)
        return cleaned
    }
}

/// The shared context menu items for a story per DESIGN.md §14.
struct StoryContextMenuItems<TrailingContent: View>: View {
    let article: FeedArticle
    @ViewBuilder let trailingContent: TrailingContent

    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var appSettings: AppSettings

    private var isRead: Bool { readManager.isRead(article.id) }
    private var isSaved: Bool { savedStories.isSaved(article) }

    init(article: FeedArticle, @ViewBuilder trailingContent: () -> TrailingContent) {
        self.article = article
        self.trailingContent = trailingContent()
    }

    var body: some View {
        Button {
            readManager.toggleRead(article.id)
        } label: {
            Label(
                isRead ? "Mark as Unread" : "Mark as Read",
                systemImage: isRead ? "circle" : "checkmark.circle.fill"
            )
        }

        Button {
            if isSaved {
                savedStories.remove(article)
            } else {
                savedStories.save(article)
            }
        } label: {
            Label(
                isSaved ? "Remove from Saved" : "Save Story",
                systemImage: isSaved ? "bookmark.slash" : "bookmark"
            )
        }

        if let muting = appSettings.sourceMuting(for: article.link) {
            Button(action: muting.apply) {
                Label(muting.title, systemImage: "speaker.slash")
            }
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(article.link, forType: .string)
        } label: {
            Label("Copy Link", systemImage: "link")
        }

        if let url = WebLink.url(article.link) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }

            ShareLink(item: url, subject: Text(article.title), message: Text(article.title)) {
                Label("Share Story", systemImage: "square.and.arrow.up")
            }
        }

        trailingContent
    }
}

extension StoryContextMenuItems where TrailingContent == EmptyView {
    init(article: FeedArticle) {
        self.init(article: article, trailingContent: { EmptyView() })
    }
}
