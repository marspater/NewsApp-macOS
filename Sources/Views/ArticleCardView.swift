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
                cardFace
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
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(appearance.border, lineWidth: appearance.width)
        )
        .shadow(color: appearance.shadow, radius: appearance.radius, x: 0, y: appearance.y)
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

            // Headline
            Text(article.title)
                .font(AppTypography.cardHeadline(compact ? .list : .grid))
                .foregroundStyle(isRead ? AppColor.secondaryText : AppColor.primaryText)
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
            stateGlyphs
        }
    }

    /// Saved glyph and unread dot, in this order, at the trailing end of the eyebrow line.
    @ViewBuilder
    private var stateGlyphs: some View {
        if isSaved {
            Image(systemName: "bookmark.fill")
                .font(AppTypography.eyebrow)
                .foregroundStyle(AppColor.accent)
                .accessibilityLabel("Saved")
        }
        if !isRead {
            UnreadDot()
        }
    }

    @ViewBuilder
    private var regularDescription: some View {
        if !article.description.isEmpty {
            let cleanDesc = ArticleContentRedactor.cleanText(article.description)
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
                stateGlyphs
            }

            Text(article.title)
                .font(AppTypography.leadStoryHeadline)
                .foregroundStyle(isRead ? AppColor.leadSecondaryText : AppColor.leadText)
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
                    .monospacedDigit()
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

    // MARK: - Helpers

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
