// ArticleCardView.swift
// NewsApp Article Grid Card View

import AppKit
import SwiftUI

struct ArticleCardView: View {
    let article: FeedArticle
    var isSelected: Bool = false
    var compact: Bool = false
    /// Other coverage of the same event; the card shows the first of their images when this article has none.
    var imageFallbacks: [FeedArticle] = []
    /// Opt-in to the macOS 26 image-backed lead treatment.
    var isLead = false
    let action: () -> Void

    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var isHovered = false

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

    private var cardLayout: AnyLayout {
        compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
    }

    private var appearance: (border: Color, width: CGFloat, shadow: Color, radius: CGFloat, y: CGFloat) {
        if isSelected {
            return (
                AppColor.accent, 1.5, AppShadow.cardFocusRingColor, AppShadow.cardFocusRingRadius,
                AppShadow.cardFocusRingY
            )
        }
        if isHovered {
            return (
                AppColor.accent.opacity(0.4), 1.0, AppShadow.cardHoverColor, AppShadow.cardHoverRadius,
                AppShadow.cardHoverY
            )
        }
        return (
            AppColor.border(for: contrast), 0.5, AppShadow.cardRestingColor, AppShadow.cardRestingRadius,
            AppShadow.cardRestingY
        )
    }

    var body: some View {
        Button(action: action) {
            cardFace
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: AppRadius.card))
        .contextMenu {
            storyContextMenu
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
    }

    @ViewBuilder
    private var cardFace: some View {
        if #available(macOS 26.0, *), isLead,
            let url = FeedArticle.bestCardImage(in: [article] + imageFallbacks)
        {
            ArticleRemoteImage(url: url) { phase in
                leadImage(for: phase, aspectRatio: DecodedImageCache.aspectRatio(for: url))
            }
        } else {
            regularSurface()
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
            failedLeadSurface
        @unknown default:
            failedLeadSurface
        }
    }

    @ViewBuilder
    private var storyContextMenu: some View {
        StoryContextMenuItems(article: article)
    }

    // MARK: - Card surfaces

    /// Reuse the phase-four card design, buttons, context menu and accessibility actions.
    private func regularSurface(editorialFallbackOnly: Bool = false) -> some View {
        cardLayout {
            cardImage(editorialFallbackOnly: editorialFallbackOnly)
            regularStoryText
        }
        .frame(height: compact ? 170 : nil)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card)
                .stroke(appearance.border, lineWidth: appearance.width)
        )
        .shadow(color: appearance.shadow, radius: appearance.radius, x: 0, y: appearance.y)
        .animation(reduceMotion ? nil : AppMotion.hover, value: isHovered)
        .animation(reduceMotion ? nil : AppMotion.state, value: isSelected)
        .opacity(isRead ? 0.90 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private func cardImage(editorialFallbackOnly: Bool) -> some View {
        // Header Image Container
        Group {
            if editorialFallbackOnly {
                editorialFallbackHeader
                    .frame(height: compact ? 170 : 54)
            } else {
                cardImageHeader
            }
        }
        .frame(width: compact ? 170 : nil)
        .accessibilityHidden(true)
    }

    private var regularStoryText: some View {
        VStack(alignment: .leading, spacing: AppSpacing.eyebrowGap) {
            // Eyebrow Row: Source + Badges
            regularEyebrow

            // Headline
            Text(article.title)
                .font(AppTypography.cardHeadline(compact ? .list : .grid))
                .foregroundColor(isRead ? AppColor.secondaryText : AppColor.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                // In the fixed-height list card the summary gives up lines before the headline does.
                .layoutPriority(1)

            // Description
            regularDescription

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

            if isSaved {
                Image(systemName: "bookmark.fill")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AppColor.accent)
            }

            if !isRead {
                Circle()
                    .fill(AppColor.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unread")
            }
        }
    }

    @ViewBuilder
    private var regularDescription: some View {
        if !article.description.isEmpty {
            let cleanDesc = ArticleContentRedactor.cleanText(article.description)
            if !cleanDesc.isEmpty {
                Text(cleanDesc)
                    .font(AppTypography.body)
                    .foregroundColor(AppColor.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var regularFooter: some View {
        HStack(spacing: AppSpacing.xs) {
            Text(article.cardDateText())
                .font(AppTypography.caption)
                .foregroundColor(AppColor.tertiaryText(for: contrast))

            Spacer()

            if article.aiSummary != nil {
                TagView.intelligence()
                    .help("AI summary available")
                    .accessibilityLabel("AI summary available")
            }
        }
    }

    /// Below this width-to-height ratio a lead image is framed whole rather than cropped to fill.
    static let wideLeadImageRatio: CGFloat = 1.25

    /// Square and portrait lead images (and wide ones only once their size is known) are framed whole.
    static func framesLeadImageWhole(aspectRatio: CGFloat?) -> Bool {
        aspectRatio.map { $0 < wideLeadImageRatio } ?? false
    }

    /// Match the normal list or grid card geometry when an image cannot decode.
    private var failedLeadSurface: some View {
        regularSurface(editorialFallbackOnly: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AppLayout.leadStoryHeight, alignment: .top)
    }

    /// Wide images fill the frame anchored to the top, where subjects usually sit above the caption scrim.
    /// Square and portrait images are shown whole over a blurred copy of themselves, so faces are never cropped.
    /// The image stays clipped to the card; the caption and controls are separate foreground layers.
    @available(macOS 26.0, *)
    private func leadSurface(image: Image?, aspectRatio: CGFloat? = nil) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: AppLayout.leadStoryHeight)
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
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.container))
                    .accessibilityHidden(true)
            } else {
                // Keep the loading surface dark so the image caption stays readable.
                AppColor.leadPlaceholder
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.container))
                    .accessibilityHidden(true)
            }

            leadCaption
                .padding(.bottom, AppSpacing.sm)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppLayout.leadStoryHeight)
        .containerShape(RoundedRectangle(cornerRadius: AppRadius.container))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.container)
                .stroke(appearance.border, lineWidth: appearance.width)
        }
        .shadow(color: appearance.shadow, radius: appearance.radius, x: 0, y: appearance.y)
        .animation(reduceMotion ? nil : AppMotion.hover, value: isHovered)
        .animation(reduceMotion ? nil : AppMotion.state, value: isSelected)
        .onHover { isHovered = $0 }
    }

    /// Dark image-caption backing remains legible at every glass transparency
    /// setting. Its lower corners follow the lead container's curvature.
    @available(macOS 26.0, *)
    private var leadCaption: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                EyebrowText(displaySource, color: AppColor.leadText)
                Spacer(minLength: AppSpacing.xs)
                if isSaved {
                    Label("Saved", systemImage: "bookmark.fill")
                        .font(AppTypography.caption)
                }
                if !isRead {
                    Label("Unread", systemImage: "circle.fill")
                        .font(AppTypography.caption)
                }
            }

            Text(article.title)
                .font(AppTypography.leadStoryHeadline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)

            let cleanDescription = ArticleContentRedactor.cleanText(article.description)
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
                Spacer(minLength: AppSpacing.xs)
                if article.aiSummary != nil {
                    TagView.intelligence()
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

    // MARK: - Subviews & Helpers

    @ViewBuilder
    private var cardImageHeader: some View {
        if let url = FeedArticle.bestCardImage(in: [article] + imageFallbacks) {
            ArticleRemoteImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    // The clear frame takes the column's size; a filled image wider than it must not push past it.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 170 : 140)
                        .overlay { image.resizable().aspectRatio(contentMode: .fill) }
                        .clipped()
                        .saturation(isRead ? 0.92 : 1.0)
                        .accessibilityHidden(true)
                default:
                    editorialFallbackHeader.frame(height: compact ? 170 : 140)
                }
            }
            .frame(height: compact ? 170 : 140)
        } else {
            editorialFallbackHeader
        }
    }

    private var editorialFallbackHeader: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [AppColor.surface, AppColor.elevatedSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Grid cards keep one header height with or without an image, so a row's cards line up.
            .frame(height: compact ? 170 : 140)
            .frame(maxWidth: .infinity)

            Image(systemName: "newspaper")
                .imageScale(.large)
                .foregroundStyle(AppColor.quaternaryLabel)
                .padding(AppSpacing.sm)
        }
    }

    private var displaySource: String { article.publisherName }

    private var accessibilityDescription: String {
        let readState = isRead ? "Read" : "Unread"
        let savedState = isSaved ? ", saved in your library" : ""
        let dateFormatted = article.publicationDateText
        return "\(article.title), from \(displaySource), published \(dateFormatted). \(readState)\(savedState)."
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

        if let url = URL(string: article.link) {
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

/// The feed layouts. Stored as the two existing preference keys so earlier List and Grid choices carry over.
enum StoryLayout: Int, CaseIterable {
    case compact, list, grid

    init(compact: Bool, grid: Bool) { self = compact ? .compact : grid ? .grid : .list }

    var title: String {
        switch self {
        case .compact: return "As Headlines"
        case .list: return "As List"
        case .grid: return "As Grid"
        }
    }

    /// A binding over the stored preferences, shared by the toolbar picker and the View menu.
    static func binding(compact: Binding<Bool>, grid: Binding<Bool>) -> Binding<StoryLayout> {
        Binding(
            get: { StoryLayout(compact: compact.wrappedValue, grid: grid.wrappedValue) },
            set: { layout in
                compact.wrappedValue = layout == .compact
                grid.wrappedValue = layout == .grid
            })
    }
}

/// A dense headline row (the Headlines layout): topic, headline and publisher on one line each. Clicking expands
/// the row in place to the summary, the publishers covering it and its actions, so a day's news can be read down
/// the page and checked off without opening every story.
struct CompactStoryRow: View {
    let article: FeedArticle
    /// Publishers covering the event, when this row stands for one.
    var publishers: [String] = []
    var isSelected = false
    @Binding var isExpanded: Bool
    let open: () -> Void

    @EnvironmentObject private var readManager: ReadManager
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast

    private var isRead: Bool { readManager.isRead(article.id) }

    private var kicker: String {
        let topic = article.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coverage = publishers.count > 1 ? "\(publishers.count) publishers" : ""
        return [topic, coverage].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var summary: String {
        ArticleContentRedactor.cleanText(article.aiSummary ?? article.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.state) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        if !kicker.isEmpty { EyebrowText(kicker, color: AppColor.accent) }
                        Text(article.title)
                            .font(AppTypography.headline)
                            .foregroundStyle(isRead ? AppColor.secondaryText : AppColor.primaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(isExpanded ? nil : 2)
                        Text("\(article.publisherName) · \(article.cardDateText())")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.tertiaryText(for: contrast))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Collapses the summary" : "Shows the summary and publishers")

                Button {
                    readManager.toggleRead(article.id)
                } label: {
                    Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(isRead ? AppColor.success : AppColor.tertiaryText(for: contrast))
                }
                .buttonStyle(.plain)
                .help(isRead ? "Mark as unread" : "Mark as read")
                .accessibilityLabel(isRead ? "Mark as Unread" : "Mark as Read")
            }

            if isExpanded {
                if !summary.isEmpty {
                    Text(summary)
                        .font(AppTypography.body)
                        .foregroundStyle(AppColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if publishers.count > 1 {
                    Text(publishers.joined(separator: " · "))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Button("Read Story", action: open)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open the story in the reader")
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .padding(.horizontal, AppSpacing.md)
        .background(
            isSelected || isExpanded ? AppColor.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.control)
        )
        .overlay(alignment: .bottom) {
            Divider().opacity(isExpanded ? 0 : 1)
        }
        // Expanding and collapsing content never draws over the neighbouring rows while they move.
        .clipped()
        .contextMenu {
            StoryContextMenuItems(article: article)
        }
    }
}
