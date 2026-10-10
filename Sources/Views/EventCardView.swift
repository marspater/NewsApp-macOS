// EventCardView.swift
// NewsApp Event Card & Source List

import AppKit
import SwiftUI

/// One card for a confirmed event: the representative publication as an ordinary card, followed by
/// the event's coverage and, on request, every member publication. Publisher text is never replaced.
struct EventCardView: View {
    let representative: FeedArticle
    let summary: EventFeedSummary
    /// Members listed on this page, used for the card image when the representative has none.
    var visibleMembers: [FeedArticle] = []
    var isSelected = false
    var compact = false
    var isLead = false
    @Binding var isExpanded: Bool
    let openRepresentative: () -> Void
    let openMember: (FeedArticle, [FeedArticle]) -> Void
    let separate: (FeedArticle) -> Void

    @EnvironmentObject private var articleStore: ArticleStore
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var members: [FeedArticle] = []
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ArticleCardView(
                article: representative, isSelected: isSelected, compact: compact,
                imageFallbacks: (members.isEmpty ? visibleMembers : members).filter { $0.id != representative.id },
                isLead: isLead, action: openRepresentative)
            coverageToggle
            if isExpanded {
                sourceList
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .task(id: "\(summary.eventID):\(summary.membershipVersion):\(isExpanded)") {
            do {
                let loaded = try await articleStore.eventMemberArticles(eventID: summary.eventID)
                try Task.checkCancellation()
                members = loaded
                loadFailed = false
            } catch {
                if !Task.isCancelled { loadFailed = true }
            }
        }
    }

    // MARK: - Coverage

    private var coverageToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : AppMotion.state) { isExpanded.toggle() }
            if isExpanded {
                let eventID = summary.eventID
                Task { await articleStore.markEventSeen(eventID) }
            }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "square.stack.3d.up")
                    .font(AppTypography.label)
                Text(summary.coverageText)
                    .font(AppTypography.label)
                if let latest = summary.latestDate {
                    Text("· updated \(latest, format: .relative(presentation: .named))")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.tertiaryText(for: contrast))
                }
                if summary.hasSubstantiveUpdate {
                    TagView(title: "Updated", tint: AppColor.accent)
                }
                Spacer(minLength: AppSpacing.xs)
                Image(systemName: "chevron.down")
                    .font(AppTypography.eyebrow)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(AppColor.secondaryText)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(RoundedRectangle(cornerRadius: AppRadius.control).fill(AppColor.badgeBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: AppRadius.control))
        .help(isExpanded ? "Hide the sources covering this event (E)" : "Show every source covering this event (E)")
        .accessibilityLabel(coverageDescription)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Lists every publication covering this event")
    }

    private var coverageDescription: String {
        var parts = ["Event: \(summary.coverageText)"]
        if let latest = summary.latestDate {
            parts.append("updated \(latest.formatted(.relative(presentation: .named)))")
        }
        if summary.hasSubstantiveUpdate { parts.append("new reporting since you last opened it") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Source List

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loadFailed {
                Text("Sources could not be loaded. Collapse and expand to try again.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(AppSpacing.sm)
            } else if members.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(AppSpacing.sm)
                    .accessibilityLabel("Loading sources")
            }
            ForEach(members) { member in
                EventSourceRow(
                    article: member,
                    canSeparate: members.count > 1,
                    open: { openMember(member, members) },
                    separate: { separate(member) }
                )
                if member.id != members.last?.id {
                    Divider().padding(.leading, AppSpacing.sm)
                }
            }
        }
        .padding(.vertical, AppSpacing.xxs)
        .background(RoundedRectangle(cornerRadius: AppRadius.card).fill(AppColor.surface))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColor.border(for: contrast), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources covering this event")
    }
}

/// One member publication. Read, save and separation act on this article only, so they stay
/// independent of how the event is grouped later.
private struct EventSourceRow: View {
    let article: FeedArticle
    let canSeparate: Bool
    let open: () -> Void
    let separate: () -> Void

    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.effectiveContrast) private var contrast

    private var isRead: Bool { readManager.isRead(article.id) }
    private var isSaved: Bool { savedStories.isSaved(article) }
    private var source: String { article.publisherName }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Circle()
                    .fill(isRead ? Color.clear : AppColor.unreadDot)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    EyebrowText(source)
                    Text(article.title)
                        .font(AppTypography.body)
                        .foregroundStyle(isRead ? AppColor.secondaryText : AppColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: AppSpacing.xs)
                if isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(AppColor.accent)
                }
                Text(article.cardDateText())
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tertiaryText(for: contrast))
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: AppRadius.card))
        .contextMenu {
            StoryContextMenuItems(article: article) {
                if canSeparate {
                    Divider()
                    Button {
                        separate()
                    } label: {
                        Label("Not the Same Event", systemImage: "rectangle.split.2x1")
                    }
                }
            }
        }
        .help(
            canSeparate
                ? "Open this publication. Use the context menu if it reports a different event."
                : "Open this publication"
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(article.title), from \(source), published \(article.publicationDateText). \(isRead ? "Read" : "Unread")\(isSaved ? ", saved in your library" : "")."
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button(isRead ? "Mark as Unread" : "Mark as Read") { readManager.toggleRead(article.id) }
            Button(isSaved ? "Remove from Saved" : "Save Story") { toggleSaved() }
            if let muting = appSettings.sourceMuting(for: article.link) {
                Button(muting.title, action: muting.apply)
            }
            if canSeparate {
                Button("Not the Same Event") { separate() }
            }
        }
    }

    private func toggleSaved() {
        if isSaved { savedStories.remove(article) } else { savedStories.save(article) }
    }
}
