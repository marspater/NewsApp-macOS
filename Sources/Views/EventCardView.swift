// EventCardView.swift
// NewsApp Event Card & Source List

import AppKit
import SwiftUI

/// One card for a confirmed event: the representative story as an ordinary card, with the event's coverage row
/// and, on request, every member story on the same card surface. Publisher text is never replaced.
struct EventCardView: View {
    let representative: FeedArticle
    let summary: EventFeedSummary
    /// Members listed on this page, used for the card image when the representative has none.
    var visibleMembers: [FeedArticle] = []
    var isSelected = false
    var compact = false
    var isLead = false
    var isExpanded = false
    /// Expands or collapses the coverage; the list keeps which events are open.
    let setExpanded: (Bool) -> Void
    let openRepresentative: () -> Void
    let openMember: (FeedArticle, [FeedArticle]) -> Void
    let separate: (FeedArticle) -> Void
    /// "Same Event as…": the reader says a related event reports this one (#524).
    let combine: (RelatedStoryEvent) -> Void

    @EnvironmentObject private var articleStore: ArticleStore
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var members: [FeedArticle] = []
    /// Loaded with the members, so the submenu is ready before a context menu opens on a row.
    @State private var relatedEvents: [RelatedStoryEvent] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var loadAttempt = 0

    var body: some View {
        ArticleCardView(
            article: representative, isSelected: isSelected, compact: compact,
            imageFallbacks: (needsHiddenMemberImage ? members : visibleMembers).filter { $0.id != representative.id },
            isLead: isLead, action: openRepresentative, footer: coverage
        )
        .task(id: "\(summary.eventID):\(summary.membershipVersion):\(isExpanded):\(loadAttempt)") {
            // Collapsed cards use the visible page's image candidates and fetch full coverage only on demand, or when
            // none of them has an image and the event has members hidden from lists (World Tension panel feeds, #595).
            guard isExpanded || needsHiddenMemberImage else { return }
            do {
                let loaded = try await articleStore.storyMemberArticles(eventID: summary.eventID)
                try Task.checkCancellation()
                members = loaded
                hasLoaded = true
                loadFailed = false
                guard isExpanded else { return }
                // Optional: a failed or slow lookup only leaves the submenu out.
                let related = (try? await articleStore.relatedStoryEvents(eventID: summary.eventID)) ?? []
                if !Task.isCancelled { relatedEvents = related }
            } catch {
                if !Task.isCancelled { loadFailed = true }
            }
        }
    }

    private var needsHiddenMemberImage: Bool {
        summary.members.count > visibleMembers.count
            && FeedArticle.bestCardImage(in: [representative] + visibleMembers) == nil
    }

    // MARK: - Coverage

    /// The coverage row and, when expanded, the source list, on the card's own surface.
    @ViewBuilder
    private var coverage: some View {
        Divider()
        coverageToggle
        if isExpanded {
            Divider()
            sourceList
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    private var coverageToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : AppMotion.state) { setExpanded(!isExpanded) }
            if !isExpanded {
                let eventID = summary.eventID
                Task { await articleStore.markEventSeen(eventID) }
            }
        } label: {
            CoverageRowLabel(
                coverageText: summary.coverageText, latestDate: summary.latestDate,
                hasUpdate: summary.hasSubstantiveUpdate, isExpanded: isExpanded, isGrid: !compact && !isLead
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the sources covering this story (E)" : "Show every source covering this story (E)")
        .accessibilityLabel(coverageDescription)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Lists every source covering this story")
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

    /// Loading, failure with Retry, no sources, or the member rows (DESIGN.md 8.3 and 8.4).
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loadFailed {
                HStack(spacing: AppSpacing.xs) {
                    Text("Sources couldn’t be loaded.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                    Spacer(minLength: AppSpacing.xs)
                    Button("Retry") {
                        loadFailed = false
                        loadAttempt += 1
                    }
                    .controlSize(.small)
                }
                .padding(AppSpacing.sm)
            } else if !hasLoaded {
                // The AppKit-backed spinner is hidden; a plain container carries the label (DESIGN.md 16).
                HStack {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                .padding(AppSpacing.sm)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading sources")
            } else if members.isEmpty {
                Text("No sources")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(AppSpacing.sm)
            }
            ForEach(members) { member in
                EventSourceRow(
                    article: member,
                    canSeparate: members.count > 1,
                    relatedEvents: relatedEvents,
                    open: { openMember(member, members) },
                    separate: { separate(member) },
                    combine: combine
                )
                if member.id != members.last?.id {
                    Divider().padding(.leading, AppSpacing.sm)
                }
            }
        }
        .padding(.vertical, AppSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources covering this story")
    }
}

/// One member story. Read, save and separation act on this article only, so they stay
/// independent of how the event is grouped later. "Same Event as…" acts on the whole event.
private struct EventSourceRow: View {
    let article: FeedArticle
    let canSeparate: Bool
    let relatedEvents: [RelatedStoryEvent]

    /// "Same Event as…" offers the first few earlier events only; a long story would make the menu unwieldy.
    private var mergeTargets: ArraySlice<RelatedStoryEvent> { relatedEvents.prefix(EventStoryRelation.linkLimit) }
    let open: () -> Void
    let separate: () -> Void
    let combine: (RelatedStoryEvent) -> Void

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
                        .foregroundStyle(AppColor.accentText)
                }
                CardDateText(article: article)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tertiaryText(for: contrast))
                    .monospacedDigit()
                if !isRead {
                    UnreadDot()
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: AppRadius.card))
        .contextMenu {
            StoryContextMenuItems(article: article) {
                if canSeparate || !relatedEvents.isEmpty {
                    Divider()
                }
                if canSeparate {
                    Button {
                        separate()
                    } label: {
                        Label("Not the Same Event", systemImage: "rectangle.split.2x1")
                    }
                }
                if !relatedEvents.isEmpty {
                    Menu {
                        ForEach(mergeTargets, id: \.eventID) { event in
                            Button(event.title) { combine(event) }
                        }
                    } label: {
                        Label("Same Event as…", systemImage: "arrow.triangle.merge")
                    }
                }
            }
        }
        .help(
            canSeparate || !relatedEvents.isEmpty
                ? "Open this story. Use the context menu if it reports a different event or an earlier one."
                : "Open this story"
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
            ForEach(mergeTargets, id: \.eventID) { event in
                Button("Same Event as \(event.title)") { combine(event) }
            }
        }
    }

    private func toggleSaved() {
        if isSaved { savedStories.remove(article) } else { savedStories.save(article) }
    }
}

/// An event card redraws only when its story, members, selection or expansion changed (#839). The closures are
/// left out of the comparison: they capture the same event and representative the card shows.
extension EventCardView: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.representative == rhs.representative && lhs.summary == rhs.summary
            && lhs.visibleMembers == rhs.visibleMembers && lhs.isSelected == rhs.isSelected
            && lhs.compact == rhs.compact && lhs.isLead == rhs.isLead && lhs.isExpanded == rhs.isExpanded
    }
}
