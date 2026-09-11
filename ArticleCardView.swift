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
            ZStack(alignment: .bottomLeading) {
                // Background Image or Flat Surface
                cardBackgroundLayer
                
                // Legibility Gradient
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                
                // Typography & Metadata Content
                VStack(alignment: .leading, spacing: 5) {
                    Text(displaySource.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(AppColor.accentPink)
                        .tracking(AppTypography.sourceEyebrowTracking)
                    
                    Text(article.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(radius: 2)
                    
                    if let ai = article.aiSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                            Text(ai)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(AppColor.accentGold)
                    }
                    
                    Text(article.description)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.72))
                        .lineLimit(2)
                }
                .padding(AppSpacing.md)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card)
                    .stroke(
                        isSelected
                            ? AppColor.accentPink
                            : (isHovered ? AppColor.accentPink.opacity(0.4) : Color.primary.opacity(0.08)),
                        lineWidth: isSelected ? 2.5 : (isHovered ? 1.5 : 0.5)
                    )
            )
            .shadow(
                color: isSelected
                    ? AppShadow.cardSelectedGlow
                    : (isHovered ? AppShadow.cardHoverColor : AppShadow.cardRestingColor),
                radius: isSelected
                    ? AppShadow.cardSelectedRadius
                    : (isHovered ? AppShadow.cardHoverRadius : AppShadow.cardRestingRadius),
                x: 0,
                y: isSelected
                    ? AppShadow.cardSelectedY
                    : (isHovered ? AppShadow.cardHoverY : AppShadow.cardRestingY)
            )
            .animation(reduceMotion ? nil : AppMotion.responsive, value: isHovered || isSelected)
            .opacity(isRead ? 0.45 : 1.0)
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
    private var cardBackgroundLayer: some View {
        if let imageUrl = article.imageUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 240)
                        .brightness(-0.04)
                        .contrast(1.05)
                        .saturation(1.08)
                        .clipped()
                default:
                    Rectangle()
                        .fill(AppColor.surfaceMid)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 240)
                }
            }
        } else {
            Rectangle()
                .fill(AppColor.surfaceMid)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 240)
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
