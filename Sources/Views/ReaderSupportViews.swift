// ReaderSupportViews.swift
// Reader modes, commands and small views shared by ArticleDetailView.

import AppKit
import SwiftUI

enum DetailViewMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case web = "Web"
    var id: String { rawValue }
}

/// The reader's toolbar modes: the event overview (events only), the extracted story, or the publisher's page.
enum ReaderMode: Hashable {
    case overview
    case story
    case web

    static let webShortcut: KeyEquivalent = "r"
    static let webShortcutModifiers: EventModifiers = [.command, .shift]
    var toggledPublicationMode: ReaderMode { self == .web ? .story : .web }

    /// W steps through the modes the toolbar offers, in its order: Overview (events only), Story, Web.
    func next(hasOverview: Bool) -> ReaderMode {
        switch self {
        case .overview: return .story
        case .story: return .web
        case .web: return hasOverview ? .overview : .story
        }
    }
}

/// Window-scoped bindings and actions let menu commands operate on the same reader as its toolbar.
struct ReaderCommandActions {
    let mode: Binding<ReaderMode>
    let textScale: Binding<CGFloat>
    let showReadingOptions: () -> Void
    let hasOverview: Bool
    let back: () -> Void
    let reload: (() -> Void)?
    let copyLink: () -> Void
    let webBack: (() -> Void)?
    let webForward: (() -> Void)?
}

struct ReaderCommandActionsKey: FocusedValueKey { typealias Value = ReaderCommandActions }
struct SelectedStoryKey: FocusedValueKey { typealias Value = FeedArticle }

extension FocusedValues {
    var readerActions: ReaderCommandActions? {
        get { self[ReaderCommandActionsKey.self] }
        set { self[ReaderCommandActionsKey.self] = newValue }
    }
    var selectedStory: FeedArticle? {
        get { self[SelectedStoryKey.self] }
        set { self[SelectedStoryKey.self] = newValue }
    }
}

enum ArticleContentState: Equatable {
    case loading
    case ready
    case fallback(reason: String)
    /// The publisher shows the story only to subscribers (or refuses the reader outright); the feed teaser is shown
    /// as a preview with ways to read it on the publisher's site.
    case publisherOnly(subscriber: Bool)
}

/// Tags keep their natural width and wrap instead of disappearing in a horizontal scroller.
struct ReaderTagLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, item) in layout.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.minX, y: bounds.minY + item.minY),
                proposal: ProposedViewSize(item.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let width = width.isFinite ? max(1, width) : 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var items: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), items)
    }
}

/// Whole-image fit plus a fixed ratio keeps known media stable before loading.
struct ReaderFigureView: View {
    let block: ReaderBlock
    let url: URL
    var textScale: CGFloat = 1
    @Environment(\.effectiveContrast) private var contrast

    static func effectiveImageAlt(for block: ReaderBlock) -> String {
        if let alt = block.imageAlt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            return alt
        }
        return "Article image"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ArticleRemoteImage(url: url) { phase in
                ZStack {
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                            .accessibilityLabel(Self.effectiveImageAlt(for: block))
                    case .failure:
                        AppColor.surface
                            .aspectRatio(aspectRatio, contentMode: .fit)
                            .overlay {
                                Label("Image unavailable", systemImage: "photo").foregroundStyle(AppColor.secondaryText)
                            }
                    case .empty:
                        // A label set on the AppKit-backed spinner itself made accessibility label resolution loop
                        // between SwiftUI and AppKit until the stack overflowed (VoiceOver or automation reading a
                        // story whose image was still loading). The plain placeholder carries the label instead.
                        AppColor.surface
                            .aspectRatio(aspectRatio, contentMode: .fit)
                            .overlay {
                                ProgressView().accessibilityHidden(true)
                            }
                            .accessibilityElement()
                            .accessibilityLabel("Loading story image")
                    @unknown default: EmptyView()
                    }
                }
                .frame(
                    maxWidth: DecodedImageCache.images.object(forKey: url as NSURL).map { CGFloat($0.width) }
                        ?? .infinity
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .strokeBorder(AppColor.borderSubtle, lineWidth: 0.5)
                )
            }
            if !block.text.isEmpty && block.text.lowercased() != "article image" {
                Text(block.text).font(AppTypography.readerCaptionFont(scale: textScale)).foregroundStyle(
                    AppColor.secondaryText(for: contrast)
                )
                .textSelection(.enabled)
            }
            if let credit = block.imageCredit, !credit.isEmpty {
                // Selectable text is backed by an AppKit view; a label set directly on it made accessibility label
                // resolution loop until the stack overflowed. A plain container carries the spoken label instead.
                HStack(spacing: 0) {
                    Text(credit).font(AppTypography.readerCaptionFont(scale: textScale)).foregroundStyle(
                        AppColor.tertiaryText(for: contrast)
                    ).textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Image credit: " + credit)
            }
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = block.imageWidth, let height = block.imageHeight, width > 0, height > 0 else { return 1.5 }
        return min(3, max(0.4, CGFloat(width) / CGFloat(height)))
    }
}

struct ArticleNavigationCommands: ViewModifier {
    let onNextArticle: () -> Void
    let onPrevArticle: () -> Void
    let onToggleRead: () -> Void
    let onToggleSave: () -> Void
    let onOpenInBrowser: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .nextArticleCommand)) { _ in onNextArticle() }
            .onReceive(NotificationCenter.default.publisher(for: .prevArticleCommand)) { _ in onPrevArticle() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadCommand)) { _ in onToggleRead() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSaveCommand)) { _ in onToggleSave() }
            .onReceive(NotificationCenter.default.publisher(for: .openInBrowserCommand)) { _ in onOpenInBrowser() }
    }
}

func readerText(_ block: ReaderBlock) -> AttributedString {
    guard let runs = block.inlineRuns, runs.map(\.text).joined() == block.text else {
        return AttributedString(block.text)
    }
    var text = AttributedString()
    for run in runs {
        var part = AttributedString(run.text)
        if run.strong { part.inlinePresentationIntent = .stronglyEmphasized }
        if run.emphasis { part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.emphasized) }
        if run.code { part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.code) }
        if let link = ContentExtractionPipeline.readerImageURL(run.link, baseURL: nil) { part.link = URL(string: link) }
        text.append(part)
    }
    return text
}

/// An isolated, fixed-height loading indicator bubble in the reader toolbar.
struct ToolbarLoadingBubble: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            // AppKit-backed views stay out of combined or relabelled accessibility elements (see ReaderFigureView).
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Loading event overview…")
                .font(AppTypography.caption)
                .foregroundColor(AppColor.secondaryText)
                .accessibilityLabel("Loading event overview")
        }
        .frame(height: 24)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xxs)
        .transition(.opacity.animation(reduceMotion ? nil : AppMotion.state))
        .help("Generating evidence-backed event overview…")
    }
}
