// ArticleCardView.swift
// NewsApp Article Grid Card View

import SwiftUI
import AppKit

struct ArticleCardView: View {
    let article: FeedArticle
    var isSelected: Bool = false
    var compact: Bool = false
    /// Other coverage of the same event; the card shows the first of their images when this article has none.
    var imageFallbacks: [FeedArticle] = []
    let action: () -> Void
    
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.effectiveReduceMotion) private var reduceMotion
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
        compact ? AnyLayout(HStackLayout(alignment: .center, spacing: 0))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
    }

    private var appearance: (border: Color, width: CGFloat, shadow: Color, radius: CGFloat, y: CGFloat) {
        if isSelected {
            return (AppColor.accent, 1.5, AppShadow.cardFocusRingColor, AppShadow.cardFocusRingRadius, AppShadow.cardFocusRingY)
        }
        if isHovered {
            return (AppColor.accent.opacity(0.4), 1.0, AppShadow.cardHoverColor, AppShadow.cardHoverRadius, AppShadow.cardHoverY)
        }
        return (AppColor.borderSubtle, 0.5, AppShadow.cardRestingColor, AppShadow.cardRestingRadius, AppShadow.cardRestingY)
    }

    var body: some View {
        Button(action: action) {
            cardLayout {
                // Header Image Container
                cardImageHeader
                    .frame(width: compact ? 170 : nil)
                    .accessibilityHidden(true)
                
                // Content Body Container
                VStack(alignment: .leading, spacing: 6) {
                    // Eyebrow Row: Source + Badges
                    HStack(spacing: 6) {
                        Text(displaySource.uppercased())
                            .font(AppTypography.metadata)
                            .foregroundColor(AppColor.secondaryText)
                            .tracking(AppTypography.sourceEyebrowTracking)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        if isSaved {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 10))
                                .foregroundColor(AppColor.accent)
                        }
                        
                        if !isRead {
                            Circle()
                                .fill(AppColor.accent)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel("Unread")
                        }
                    }
                    
                    // Headline
                    Text(article.title)
                        .font(compact ? .system(size: 20, weight: .semibold, design: .serif) : AppTypography.headline)
                        .foregroundColor(isRead ? AppColor.secondaryText : AppColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        // In the fixed-height list card the summary gives up lines before the headline does.
                        .layoutPriority(1)
                    
                    // Description
                    if !article.description.isEmpty {
                        let cleanDesc = ArticleContentRedactor.cleanText(article.description)
                        if !cleanDesc.isEmpty {
                            Text(cleanDesc)
                                .font(AppTypography.bodySmall)
                                .foregroundColor(AppColor.secondaryText.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    
                    Spacer(minLength: 4)
                    
                    // Footer Row: Timestamp & Optional AI Badge
                    HStack(spacing: 8) {
                        Text(article.publicationDateText)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColor.tertiaryText)
                        
                        Spacer()
                        
                        if article.aiSummary != nil {
                            HStack(spacing: 3) {
                                Text("✦")
                                    .font(.system(size: 8))
                                Text("AI")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundColor(AppColor.intelligence)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(AppColor.intelligence.opacity(0.12)))
                            .help("AI summary available")
                            .accessibilityLabel("AI summary available")
                        }
                    }
                }
                .padding(.horizontal, compact ? AppSpacing.lg : AppSpacing.sm)
                .padding(.vertical, compact ? AppSpacing.md : AppSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: AppRadius.card))
        .contextMenu {
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
                    Label("Share Story...", systemImage: "square.and.arrow.up")
                }
            }
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
    
    // MARK: - Subviews & Helpers
    
    private static func cardImageURL(_ article: FeedArticle) -> URL? {
        guard let imageUrl = article.readerDocument?.selectedImage(fallback: article.imageUrl) ?? (article.readerDocument == nil ? article.imageUrl : nil),
              ReaderImageCandidate.usable(url: imageUrl) else { return nil }
        return URL(string: imageUrl)
    }

    @ViewBuilder
    private var cardImageHeader: some View {
        if let url = ([article] + imageFallbacks).lazy.compactMap(Self.cardImageURL).first {
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
            .frame(height: compact ? 170 : 54)
            .frame(maxWidth: .infinity)
            
            Image(systemName: "newspaper")
                .font(.system(size: 18))
                .foregroundColor(AppColor.tertiaryText.opacity(0.35))
                .padding(10)
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
    @Environment(\.readerImageLoader) private var loadImage

    init(url: URL, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        _phase = State(initialValue: DecodedImageCache.images.object(forKey: url as NSURL).map { .success(Self.image($0)) } ?? .empty)
    }

    private static func image(_ image: CGImage) -> Image {
        Image(image, scale: 1, label: Text("Article image"))
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                if let cached = DecodedImageCache.images.object(forKey: url as NSURL) {
                    phase = .success(Self.image(cached))
                    NotificationCenter.default.post(name: .readerImageFinished, object: url, userInfo: ["success": true])
                    return
                }
                phase = .empty
                do {
                    let image = try await loadImage(ReaderImageCandidate.preferredRendition(of: url))
                    try Task.checkCancellation()
                    DecodedImageCache.images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                    phase = .success(Self.image(image))
                    NotificationCenter.default.post(name: .readerImageFinished, object: url, userInfo: ["success": true])
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failure(error)
                    NotificationCenter.default.post(name: .readerImageFinished, object: url, userInfo: ["success": false])
                }
            }
    }
}
