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
        let covering = appSettings.muteRules.matchedSources(link: article.link)
        if let rule = covering.first {
            return ("Unmute \(rule)", { for source in covering { appSettings.unmuteSource(source) } })
        }
        guard let host = MuteRules.host(article.link) else { return nil }
        return ("Mute \(host)", { _ = appSettings.muteSource(host) })
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
                leadImage(for: phase)
            }
        } else {
            regularSurface()
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func leadImage(for phase: AsyncImagePhase) -> some View {
        switch phase {
        case .success(let image):
            leadSurface(image: image)
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

        if let muting = sourceMuting {
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
                Label("Share Story…", systemImage: "square.and.arrow.up")
            }
        }

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
        .animation(reduceMotion ? nil : AppMotion.state, value: isHovered || isSelected)
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
                    .foregroundColor(AppColor.secondaryText.opacity(0.85))
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

    /// Match the normal list or grid card geometry when an image cannot decode.
    private var failedLeadSurface: some View {
        regularSurface(editorialFallbackOnly: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AppLayout.leadStoryHeight, alignment: .top)
    }

    /// Only the publisher image extends into adjacent safe areas. The image is
    /// clipped to the detail-column frame before the macOS 26 background effect;
    /// content, caption, and controls are separate foreground layers.
    @available(macOS 26.0, *)
    private func leadSurface(image: Image?) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: AppLayout.leadStoryHeight)
                    .overlay {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.container))
                    .backgroundExtensionEffect()
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
        .animation(reduceMotion ? nil : AppMotion.state, value: isHovered || isSelected)
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

extension Notification.Name {
    /// Posted with the image URL as object and `["success": Bool]` when a reader image finishes decoding or fails;
    /// never on cancellation. Lets performance harnesses wait for what the reader actually rendered.
    static let readerImageFinished = Notification.Name("readerImageFinished")
}

// The default loader retains the protected network path; native harnesses can supply an offline image.
private struct ReaderImageLoaderKey: EnvironmentKey {
    static let defaultValue: @Sendable (URL) async throws -> CGImage = {
        try await SecureHTTPClient.shared.fetchReaderImage(from: $0)
    }
}

extension EnvironmentValues {
    var readerImageLoader: @Sendable (URL) async throws -> CGImage {
        get { self[ReaderImageLoaderKey.self] }
        set { self[ReaderImageLoaderKey.self] = newValue }
    }
}

/// Decoded images by source URL, so a card scrolled back into view shows its image at once instead of fetching and
/// decoding it again. NSCache evicts under memory pressure.
@MainActor private enum DecodedImageCache {
    static let images: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()
}

// Feed image URLs use the same bounded, validated network path as article content.
struct ArticleRemoteImage<Content: View>: View {
    let url: URL
    @ViewBuilder var content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase
    @State private var phaseURL: URL
    @Environment(\.readerImageLoader) private var loadImage

    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        _phase = State(
            initialValue: DecodedImageCache.images.object(forKey: url as NSURL).map { .success(Self.image($0)) }
                ?? .empty)
        _phaseURL = State(initialValue: url)
    }

    private static func image(_ image: CGImage) -> Image {
        Image(image, scale: 1, label: Text("Article image"))
    }

    var body: some View {
        content(phaseURL == url ? phase : .empty)
            .task(id: url) {
                if phaseURL == url, phase.image != nil {
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                    return
                }
                phaseURL = url
                if let cached = DecodedImageCache.images.object(forKey: url as NSURL) {
                    phase = .success(Self.image(cached))
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                    return
                }
                phase = .empty
                do {
                    let image = try await loadImage(ReaderImageCandidate.preferredRendition(of: url))
                    try Task.checkCancellation()
                    DecodedImageCache.images.setObject(
                        image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                    phase = .success(Self.image(image))
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": true])
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failure(error)
                    NotificationCenter.default.post(
                        name: .readerImageFinished, object: url, userInfo: ["success": false])
                }
            }
    }
}
