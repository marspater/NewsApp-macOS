// ArticleCardView.swift
// NewsApp Article Grid Card View

import SwiftUI
import AppKit

struct ArticleCardView: View {
    let article: FeedArticle
    var isSelected: Bool = false
    let action: () -> Void
    
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    
    private var isRead: Bool {
        readManager.isRead(article.id)
    }
    
    private var isSaved: Bool {
        savedStories.isSaved(article)
    }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Header Image Container
                cardImageHeader
                
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
                        .font(AppTypography.headline)
                        .foregroundColor(isRead ? AppColor.secondaryText : AppColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    // Description
                    if !article.description.isEmpty {
                        Text(article.description)
                            .font(AppTypography.bodySmall)
                            .foregroundColor(AppColor.secondaryText.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer(minLength: 4)
                    
                    // Footer Row: Timestamp & Optional AI Badge
                    HStack(spacing: 8) {
                        Text(article.pubDate.formatted(date: .abbreviated, time: .omitted))
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
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card)
                    .stroke(
                        isSelected
                            ? AppColor.accent
                            : (isHovered ? AppColor.accent.opacity(0.4) : AppColor.borderSubtle),
                        lineWidth: isSelected ? 1.5 : (isHovered ? 1.0 : 0.5)
                    )
            )
            .shadow(
                color: isSelected
                    ? AppShadow.cardFocusRingColor
                    : (isHovered ? AppShadow.cardHoverColor : AppShadow.cardRestingColor),
                radius: isSelected
                    ? AppShadow.cardFocusRingRadius
                    : (isHovered ? AppShadow.cardHoverRadius : AppShadow.cardRestingRadius),
                x: 0,
                y: isSelected
                    ? AppShadow.cardFocusRingY
                    : (isHovered ? AppShadow.cardHoverY : AppShadow.cardRestingY)
            )
            .animation(reduceMotion ? nil : AppMotion.state, value: isHovered || isSelected)
            .opacity(isRead ? 0.90 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
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
    }
    
    // MARK: - Subviews & Helpers
    
    @ViewBuilder
    private var cardImageHeader: some View {
        if let imageUrl = article.imageUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .saturation(isRead ? 0.92 : 1.0)
                default:
                    editorialFallbackHeader
                }
            }
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
            .frame(height: 54)
            .frame(maxWidth: .infinity)
            
            Image(systemName: "newspaper")
                .font(.system(size: 18))
                .foregroundColor(AppColor.tertiaryText.opacity(0.35))
                .padding(10)
        }
    }
    
    private var displaySource: String {
        (article.source.components(separatedBy: "\n").first ?? article.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var accessibilityDescription: String {
        let readState = isRead ? "Read" : "Unread"
        let savedState = isSaved ? ", saved in your library" : ""
        let dateFormatted = article.pubDate.formatted(date: .abbreviated, time: .omitted)
        return "\(article.title), from \(displaySource), published \(dateFormatted). \(readState)\(savedState)."
    }
}
