// ArticleListView.swift
// NewsApp Article Grid List View & Navigation Coordinator

import AppKit
import SwiftUI

struct ListCommandActions {
    let canGroupStories: Bool
    let newBriefing: (() -> Void)?
}

private struct ListCommandActionsKey: FocusedValueKey { typealias Value = ListCommandActions }

extension FocusedValues {
    var listActions: ListCommandActions? {
        get { self[ListCommandActionsKey.self] }
        set { self[ListCommandActionsKey.self] = newValue }
    }
}

/// Presentation-only choice: never sort, filter or change the feed's ordered entries.
/// An event may borrow the image of one of its currently visible publications.
enum LeadStoryPresentation {
    static func firstEligibleID(in entries: [FeedEntry], selectedTopic: String?, isSearching: Bool) -> String? {
        let location = selectedTopic ?? "Today"
        guard !isSearching, location == "Today" || location == "Briefing" else { return nil }
        for entry in entries {
            let articles = [entry.representative] + entry.visibleArticles.filter { $0.id != entry.representative.id }
            if FeedArticle.bestCardImage(in: articles) != nil { return entry.id }
        }
        return nil
    }
}

/// A transient masthead status line. Each notice is distinct, so a repeated message restarts its
/// lifetime and announcement.
struct MastheadNotice: Equatable {
    let message: String
    let id = UUID()
}

struct ArticleListView: View {
    @Binding var selectedTopic: String?
    @Binding var searchText: String
    @Binding var mastheadNotice: MastheadNotice?
    @Binding var articlePath: NavigationPath

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager

    @AppStorage("articleGridLayout") private var gridLayout = false
    @AppStorage("groupsEventCoverage") private var groupsEvents = true
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var focusedArticleID: String? = nil

    @State private var briefing: FiniteBriefing?
    @State private var buffer = FeedUpdateBuffer()
    @State private var pageRequest = 0
    @State private var loadedPageRequest = 0
    @State private var cursor: ArticleQueryCursor?
    @State private var loadedQuery: String?
    @State private var queryRunID = UUID()
    @State private var isLoadingPage = false
    @State private var hasMoreResults = false
    @State private var pendingHasMore = false
    @State private var queryError: String?
    @State private var expandedEvents: Set<String> = []
    @State private var isScrolledAway = false
    @State private var isPointerInList = false
    /// Set by the reader's own regrouping actions, which apply at once.
    @State private var appliesNextUpdate = false
    /// Reloads the list once a refresh the reader asked for has finished.
    @State private var refreshReloads = 0
    /// Stories the reader's muting removes from this list, across every page.
    @State private var mutedCount = 0
    @State private var showsMuted = false
    /// Stories this list hides until more publishers cover them (`StoryVisibilityPolicy`).
    @State private var waitingCount = 0
    @State private var showsWaiting = false
    @State private var confirmsUnmuteAll = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBriefing: Bool { selectedTopic == "Briefing" && !isSearching }

    /// Muting applies to the feed lists and search; Saved Stories and History list everything the reader kept or opened.
    private var listMuting: MuteRules {
        isSearching || (selectedTopic != "Saved Stories" && selectedTopic != "History")
            ? appSettings.muteRules : MuteRules()
    }

    private var queryIdentity: String {
        let muting = listMuting
        return
            "\(selectedTopic ?? "Today"):\(searchText):\(themeManager.autoHideRead):\(muting.sourceParameter)|\(muting.topicParameter):\(showsMuted):\(showsWaiting)"
    }

    var filteredArticles: [FeedArticle] { buffer.displayed.articles }

    /// Saved Stories and History list exactly what the reader kept or opened.
    private var groupingMode: FeedGroupingMode {
        groupsEvents && !isBriefing && selectedTopic != "Saved Stories" && selectedTopic != "History"
            ? .events : .publications
    }

    private var entries: [FeedEntry] { buffer.displayed.entries(groupingMode) }

    /// The reader is looking at the list or an article from it, so cards must not move underneath.
    private var isHoldingList: Bool {
        !appliesNextUpdate && (!articlePath.isEmpty || isScrolledAway || isPointerInList || focusedArticleID != nil)
    }

    private var queuedUpdateCount: Int {
        buffer.newEntryCount(groupingMode)
    }

    private func handleQueuedUpdatesChange(previous: Int, count: Int) {
        if count > previous {
            announceUpdates(count)
        }
    }

    @ViewBuilder
    private func listContent(proxy: ScrollViewProxy) -> some View {
        if filteredArticles.isEmpty && isLoadingPage {
            ProgressView("Loading articles…").padding(AppSpacing.xl)
        } else if filteredArticles.isEmpty && queryError != nil {
            ContentUnavailableView("Couldn’t Load Articles", systemImage: "exclamationmark.triangle")
        } else if filteredArticles.isEmpty && isSearching && mutedCount == 0 {
            ContentUnavailableView.search(text: searchText)
                .padding(.top, 80)
        } else if filteredArticles.isEmpty {
            emptyStateView
        } else {
            articleGrid(proxy: proxy)
            if isBriefing { briefingCompletion }
            if hasMoreResults {
                Button("Load more articles") { pageRequest += 1 }
                    .disabled(isLoadingPage)
                    .padding(.bottom, AppSpacing.lg)
            }
        }
        if let queryError {
            VStack(spacing: AppSpacing.sm) {
                Text(queryError).foregroundStyle(AppColor.secondaryText)
                Button("Retry") { pageRequest += 1 }
            }.padding()
        }
    }

    private var selectedStory: FeedArticle? {
        guard articlePath.isEmpty, let focusedArticleID else { return nil }
        return filteredArticles.first { $0.id == focusedArticleID }
    }

    private var listCommandActions: ListCommandActions? {
        guard articlePath.isEmpty else { return nil }
        return ListCommandActions(canGroupStories: !isBriefing, newBriefing: isBriefing ? { startNewBriefing() } : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    masthead
                    listContent(proxy: proxy)
                }
                // Queued updates float over the list (DESIGN.md 8.4); the list keeps its place underneath.
                .overlay(alignment: .top) {
                    if buffer.pending != nil { updatesButton(proxy: proxy) }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 24
                } action: { _, scrolled in
                    isScrolledAway = scrolled
                }
                .onHover { isPointerInList = $0 }
                .onChange(of: queuedUpdateCount, handleQueuedUpdatesChange)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress { press in
                    handleKeyPress(press: press, proxy: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: .showFeedUpdatesCommand)) { _ in
                    if articlePath.isEmpty { applyPendingUpdates(proxy: proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .nextArticleCommand)) { _ in
                    if articlePath.isEmpty { navigateList(offset: 1, proxy: proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .prevArticleCommand)) { _ in
                    if articlePath.isEmpty { navigateList(offset: -1, proxy: proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .refreshFeedsCommand)) { _ in
                    refreshFeeds()
                }
                .onReceive(NotificationCenter.default.publisher(for: .toggleReadCommand)) { _ in
                    if articlePath.isEmpty, let id = focusedArticleID {
                        readManager.toggleRead(id)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .toggleSaveCommand)) { _ in
                    if articlePath.isEmpty, let id = focusedArticleID,
                        let art = filteredArticles.first(where: { $0.id == id })
                    {
                        if savedStories.isSaved(art) {
                            savedStories.remove(art)
                        } else {
                            savedStories.save(art)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openInBrowserCommand)) { _ in
                    if articlePath.isEmpty, let id = focusedArticleID,
                        let art = filteredArticles.first(where: { $0.id == id }),
                        let url = URL(string: art.link)
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .focusedSceneValue(\.selectedStory, selectedStory)
        .focusedSceneValue(\.listActions, listCommandActions)
        .navigationTitle(locationTitle)
        // The masthead shows the location, so the toolbar does not repeat it (DESIGN.md 5).
        .toolbar(removing: .title)
        .toolbar { listToolbar }
        .task(
            id:
                "\(queryIdentity):\(articleStore.revision):\(articleStore.eventRevision):\(pageRequest):\(refreshReloads)"
        ) {
            let identity = queryIdentity
            let runID = UUID()
            queryRunID = runID
            if isBriefing {
                queryError = nil
                isLoadingPage = true
                defer { if queryRunID == runID { isLoadingPage = false } }
                do {
                    if briefing == nil {
                        let now = Date()
                        let candidates = try await articleStore.database.fetchArticles(
                            isRead: false, limit: FiniteBriefing.candidateLimit,
                            publicationWindow: now.addingTimeInterval(-FiniteBriefing.duration)...now,
                            muting: appSettings.muteRules, hidingWaitingStories: true)
                        try Task.checkCancellation()
                        briefing = FiniteBriefing(candidates: candidates, readIDs: readManager.readArticles, now: now)
                    }
                    buffer.replace(with: FeedSnapshot(articles: briefing?.articles ?? []))
                    hasMoreResults = false
                    mutedCount = 0
                    loadedQuery = identity
                } catch is CancellationError {
                    // A newer selection owns the results.
                } catch {
                    if queryRunID == runID { queryError = "Could not load the briefing. Please try again." }
                }
                return
            }
            let isNewQuery = loadedQuery != identity
            let isPaging = !isNewQuery && pageRequest != loadedPageRequest && cursor != nil
            loadedPageRequest = pageRequest
            if isNewQuery {
                buffer = FeedUpdateBuffer()
                cursor = nil
                hasMoreResults = false
                expandedEvents = []
                loadedQuery = identity
            }
            queryError = nil
            isLoadingPage = true
            defer { if queryRunID == runID { isLoadingPage = false } }
            do {
                if !isPaging { try await Task.sleep(for: .milliseconds(180)) }
                let muting = listMuting
                let fetched = try await fetchPage(
                    after: isPaging ? cursor : nil, muting: showsMuted ? MuteRules() : muting)
                try Task.checkCancellation()
                if !isPaging {
                    var hidden = 0
                    if !muting.isEmpty { hidden = try await countMuted(muting) }
                    let waiting = hidesWaitingStories || showsWaiting ? try await countWaiting(muting: muting) : 0
                    try Task.checkCancellation()
                    mutedCount = hidden
                    waitingCount = waiting
                }
                let page = Array(fetched.prefix(200))
                let listed = isPaging ? buffer.displayed.articles + page : page
                let events = try await articleStore.eventFeedSummaries(for: listed.map(\.id))
                try Task.checkCancellation()
                let morePages = fetched.count > 200
                if isPaging {
                    buffer.append(page, events: events)
                    cursor = buffer.displayed.articles.last.map(ArticleQueryCursor.init)
                    hasMoreResults = morePages
                } else if isNewQuery {
                    buffer.replace(with: FeedSnapshot(articles: page, events: events))
                    cursor = page.last.map(ArticleQueryCursor.init)
                    hasMoreResults = morePages
                } else {
                    let snapshot = FeedSnapshot(articles: page, events: events)
                    let holding = isHoldingList
                    appliesNextUpdate = false
                    let result = withAnimation(reduceMotion ? nil : AppMotion.state) {
                        buffer.receive(snapshot, holding: holding, mode: groupingMode, hasMore: morePages)
                    }
                    switch result {
                    case .replaced:
                        cursor = page.last.map(ArticleQueryCursor.init)
                        hasMoreResults = morePages
                    case .refreshedInPlace:
                        break
                    case .waiting:
                        pendingHasMore = morePages
                    }
                }
            } catch is CancellationError {
                // A newer query owns the results.
            } catch {
                if queryRunID == runID { queryError = "Could not load articles. Please try again." }
            }
        }
    }

    private var listFilters: (topic: String, read: Bool?, saved: Bool?) {
        let topic = selectedTopic ?? "Today"
        let read: Bool?
        if topic == "History" {
            read = true
        } else if topic == "Unread" || (themeManager.autoHideRead && topic != "Saved Stories") {
            read = false
        } else {
            read = nil
        }
        return (topic, read, topic == "Saved Stories" ? true : nil)
    }

    /// Main lists hide stories that wait for more coverage; search, Saved Stories and History list everything.
    private var listsWaitingStories: Bool {
        !isSearching && selectedTopic != "Saved Stories" && selectedTopic != "History"
    }

    private var hidesWaitingStories: Bool { listsWaitingStories && !showsWaiting }

    private func fetchPage(after pageCursor: ArticleQueryCursor?, muting: MuteRules) async throws -> [FeedArticle] {
        if isSearching {
            return try await articleStore.database.searchArticles(
                query: searchText, limit: 201, after: pageCursor, muting: muting)
        }
        let filters = listFilters
        return try await articleStore.database.fetchArticles(
            section: filters.topic, isRead: filters.read, isSaved: filters.saved,
            limit: 201, after: pageCursor, muting: muting, hidingWaitingStories: hidesWaitingStories)
    }

    private func countWaiting(muting: MuteRules) async throws -> Int {
        guard listsWaitingStories else { return 0 }
        let filters = listFilters
        return try await articleStore.database.waitingStoryCount(
            section: filters.topic, isRead: filters.read, isSaved: filters.saved, muting: muting)
    }

    private func countMuted(_ muting: MuteRules) async throws -> Int {
        if isSearching {
            return try await articleStore.database.mutedArticleCount(search: searchText, muting: muting)
        }
        let filters = listFilters
        return try await articleStore.database.mutedArticleCount(
            section: filters.topic, isRead: filters.read, isSaved: filters.saved, muting: muting)
    }

    // MARK: - Muting

    private var mutingMenu: some View {
        Menu {
            Button(showsMuted ? "Hide Muted Stories" : "Show Muted Stories") { showsMuted.toggle() }
            SettingsLink { Text("Muting Settings…") }
            Divider()
            Button("Unmute All…", role: .destructive) { confirmsUnmuteAll = true }
        } label: {
            Label(
                showsMuted ? "Showing \(mutedCount) muted" : "\(mutedCount) hidden by muting",
                systemImage: showsMuted ? "eye" : "eye.slash"
            )
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(showsMuted ? "Muted stories are shown in this list" : "Stories hidden by your muted sources and topics")
        .accessibilityLabel(
            showsMuted ? "Showing \(mutedCount) muted stories" : "\(mutedCount) stories hidden by muting"
        )
        .confirmationDialog("Unmute every source and topic?", isPresented: $confirmsUnmuteAll) {
            Button("Unmute All", role: .destructive) { appSettings.clearMuting() }
        } message: {
            Text("Muted stories return to every list.")
        }
    }

    // MARK: - Queued Updates

    private func updatesButton(proxy: ScrollViewProxy) -> some View {
        let count = buffer.newEntryCount(groupingMode)
        return Button {
            applyPendingUpdates(proxy: proxy)
        } label: {
            Label(
                count > 0 ? "\(count) new \(count == 1 ? "story" : "stories")" : "Show updates", systemImage: "arrow.up"
            )
            .font(AppTypography.label)
        }
        .nativeGlassButtonStyle()
        .buttonBorderShape(.capsule)
        .opacity(appearsActive ? 1 : 0.5)
        .padding(.top, AppSpacing.xs)
        .help("Show the latest stories (U). The list keeps its place until you do.")
        .accessibilityHint("Moves to the top of the updated list")
    }

    private func applyPendingUpdates(proxy: ScrollViewProxy) {
        guard buffer.pending != nil else { return }
        withAnimation(reduceMotion ? nil : AppMotion.state) {
            buffer.applyPending()
        }
        cursor = buffer.displayed.articles.last.map(ArticleQueryCursor.init)
        hasMoreResults = pendingHasMore
        if let first = entries.first {
            withAnimation(reduceMotion ? nil : AppMotion.quick) {
                proxy.scrollTo(first.id, anchor: .top)
            }
        }
    }

    private func announceUpdates(_ count: Int) {
        guard let application = NSApp else { return }
        let message = count == 1 ? "1 new story available" : "\(count) new stories available"
        NSAccessibility.post(
            element: application, notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    // MARK: - Masthead

    private var locationTitle: String {
        isSearching ? "Search" : (selectedTopic ?? "Today")
    }

    /// The location title and one status line, scrolling with the list under the toolbar (DESIGN.md 8.1).
    private var masthead: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(locationTitle)
                .font(AppTypography.masthead)
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            HStack(spacing: AppSpacing.xs) {
                Text(listSubtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .monospacedDigit()
                if let mastheadNotice {
                    Text("·")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityHidden(true)
                    Text(mastheadNotice.message)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                if waitingCount > 0 && !isBriefing {
                    Text("·")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityHidden(true)
                    Button(showsWaiting ? "Hide \(waitingCount) waiting" : "\(waitingCount) waiting for more sources") {
                        showsWaiting.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .help(
                        showsWaiting
                            ? "Hide minor stories until more publishers cover them"
                            : "Minor stories appear once \(StoryVisibilityPolicy.minorStorySources + 1) publishers cover them; unread ones expire after a day"
                    )
                }
                if mutedCount > 0 && !listMuting.isEmpty {
                    Text("·")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityHidden(true)
                    mutingMenu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppLayout.cardGap)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $groupsEvents.animation(reduceMotion ? nil : AppMotion.state)) {
                Label(
                    "Group Stories by Event",
                    systemImage: groupsEvents ? "square.stack.3d.up.fill" : "square.stack.3d.up")
            }
            .toggleStyle(.button)
            .help(
                groupsEvents
                    ? "Showing one card per event. Show individual publications (G)"
                    : "Showing individual publications. Group coverage of the same event (G)"
            )
            .disabled(isBriefing)
            .accessibilityLabel("Group Coverage by Event")

            Picker("Article layout", selection: $gridLayout) {
                Image(systemName: "list.bullet").tag(false)
                    .accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true)
                    .accessibilityLabel("Grid")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Choose list or grid layout")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Xcode 26.3 (CodeQL tracing) cannot resolve this newer SwiftUI modifier.
        #if compiler(>=6.4)
            if #available(macOS 26.1, *) {
                refreshToolbarItem.visibilityPriority(.high)
            } else {
                refreshToolbarItem
            }
        #else
            refreshToolbarItem
        #endif
        if isBriefing {
            if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItem(placement: .primaryAction) {
                Button("New Briefing", action: startNewBriefing)
                    .help("Select a new briefing from the latest unread stories")
            }
        }
    }

    // Repeated refreshes join the running request, so keep the control enabled and its size stable.
    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                refreshFeeds()
            } label: {
                Label("Refresh Feeds", systemImage: "arrow.clockwise")
                    .symbolEffect(
                        .rotate, options: .repeat(.continuous), isActive: feedManager.isAnyFeedLoading && !reduceMotion)
            }
            .help(feedManager.isAnyFeedLoading ? "Refreshing feeds…" : "Refresh Feeds (R or ⌘R)")
            .accessibilityLabel("Refresh Feeds")
            .accessibilityValue(feedManager.isAnyFeedLoading ? "Refreshing" : "")
        }
    }

    /// Story count, how many cards group an event's coverage, and when feeds last refreshed.
    private var listSubtitle: String {
        if isBriefing { return "Up to 10 unread stories · Last 24 hours" }
        var parts = ["\(entries.count) \(entries.count == 1 ? "story" : "stories")"]
        if !isSearching && (selectedTopic ?? "Today") == "Today" {
            parts.insert(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()), at: 0)
        }
        let events = entries.filter { if case .event = $0 { return true } else { return false } }.count
        if events > 0 { parts.append("\(events) grouped \(events == 1 ? "event" : "events")") }
        if !isSearching, let refreshed = feedManager.lastRefreshCompletedAt {
            parts.append("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func startNewBriefing() {
        briefing = nil
        pageRequest += 1
    }

    private var briefingCompletion: some View {
        VStack(spacing: AppSpacing.sm) {
            if let briefing {
                Text(
                    briefing.isComplete(readManager.readArticles)
                        ? "Briefing complete"
                        : "\(briefing.readCount(readManager.readArticles)) of \(briefing.articles.count) stories read"
                )
                .font(AppTypography.headline)
                Text(
                    "Selection frozen at \(briefing.startedAt.formatted(date: .omitted, time: .shortened)). New stories stay in your regular feed."
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                Button("Back to Today") { selectedTopic = "Today" }
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Article Grid

    /// The lead takes the full detail-column width, including the edge by the sidebar.
    /// Both collections retain their original ordering and existing lazy rendering.
    private func articleGrid(proxy _: ScrollViewProxy) -> some View {
        let listed = entries
        let leadID: String? = {
            if #available(macOS 26, *) {
                return LeadStoryPresentation.firstEligibleID(
                    in: listed, selectedTopic: selectedTopic, isSearching: isSearching
                )
            }
            return nil
        }()

        return VStack(spacing: AppLayout.cardGap) {
            if let leadID, let leadIndex = listed.firstIndex(where: { $0.id == leadID }) {
                if leadIndex > 0 {
                    cardCollection(Array(listed[..<leadIndex]))
                        .padding(.horizontal, AppLayout.pageInset)
                }
                entryCard(listed[leadIndex], isLead: true)
                    .frame(maxWidth: .infinity)
                if leadIndex + 1 < listed.count {
                    cardCollection(Array(listed[(leadIndex + 1)...]))
                        .padding(.horizontal, AppLayout.pageInset)
                }
            } else {
                cardCollection(listed)
                    .padding(.horizontal, AppLayout.pageInset)
            }
        }
        .padding(.bottom, AppSpacing.xl)
    }

    @ViewBuilder
    private func cardCollection(_ listed: [FeedEntry]) -> some View {
        if gridLayout {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(
                            minimum: AppLayout.gridColumnMinimum,
                            maximum: AppLayout.gridColumnMaximum), spacing: AppLayout.cardGap)
                ],
                spacing: AppLayout.cardGap
            ) {
                ForEach(listed) { entry in entryCard(entry) }
            }
        } else {
            LazyVStack(spacing: AppSpacing.sm) {
                ForEach(listed) { entry in entryCard(entry) }
            }
            .frame(maxWidth: AppLayout.listMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func entryCard(_ entry: FeedEntry, isLead: Bool = false) -> some View {
        switch entry {
        case .article(let article):
            ArticleCardView(
                article: article, isSelected: article.id == focusedArticleID,
                compact: !gridLayout, isLead: isLead
            ) {
                openArticle(article)
            }
            .id(entry.id)
            .onAppear(perform: NewsSignposts.firstCardAppeared)
        case .event(let summary, let representative, let visibleMembers):
            EventCardView(
                representative: representative,
                summary: summary,
                visibleMembers: visibleMembers,
                isSelected: representative.id == focusedArticleID,
                compact: !gridLayout,
                isLead: isLead,
                isExpanded: expansionBinding(summary.eventID),
                openRepresentative: { openEvent(summary.eventID, article: representative) },
                openMember: { member, members in
                    openEvent(summary.eventID, article: member, context: members)
                },
                separate: { member in separate(member, from: summary.eventID) }
            )
            .id(entry.id)
            .onAppear(perform: NewsSignposts.firstCardAppeared)
        }
    }

    private func expansionBinding(_ eventID: String) -> Binding<Bool> {
        Binding(
            get: { expandedEvents.contains(eventID) },
            set: { isExpanded in
                if isExpanded { expandedEvents.insert(eventID) } else { expandedEvents.remove(eventID) }
            }
        )
    }

    // MARK: - Empty States & Diagnostics

    private var emptyStateView: some View {
        VStack(spacing: AppSpacing.md) {
            let failedFeeds = feedManager.feedStatuses.filter {
                if case .failed = $0.value { return true }
                return false
            }

            if !isBriefing && feedManager.isAnyFeedLoading {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.bottom, 4)
                Text("Refreshing news feeds...")
                    .font(AppTypography.body)
                    .foregroundColor(AppColor.secondaryText)
            } else if !isBriefing && (selectedTopic != "Saved Stories" && selectedTopic != "History")
                && !failedFeeds.isEmpty && filteredArticles.isEmpty
            {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(AppColor.warning)

                    Text("\(failedFeeds.count) feeds couldn't be refreshed")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColor.primaryText)

                    VStack(spacing: 4) {
                        ForEach(Array(failedFeeds.keys.prefix(4)), id: \.self) { urlString in
                            let host = URL(string: urlString)?.host ?? urlString
                            Text(host)
                                .font(AppTypography.bodySmall)
                                .foregroundColor(AppColor.secondaryText)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Retry Feeds") {
                            refreshFeeds()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColor.accent)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)

                    DisclosureGroup("Technical Details") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(failedFeeds.keys), id: \.self) { urlString in
                                if case .failed(let err) = feedManager.feedStatuses[urlString] {
                                    Text("\(urlString): \(err.localizedDescription)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(AppColor.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.tertiaryText)
                    .frame(maxWidth: 360)
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.container)
                        .fill(AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.container)
                                .stroke(AppColor.borderSubtle, lineWidth: 1)
                        )
                )
                .frame(maxWidth: 420)
            } else {
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 36))
                    .foregroundColor(AppColor.tertiaryText)

                Text(emptyStateTitle)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColor.primaryText)

                Text(emptyStateText)
                    .font(AppTypography.bodySmall)
                    .foregroundColor(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                if mutedCount > 0 && !showsMuted && !listMuting.isEmpty {
                    Button(mutedCount == 1 ? "Show 1 Muted Story" : "Show \(mutedCount) Muted Stories") {
                        showsMuted = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if selectedTopic == "Today" || selectedTopic == "Unread" {
                    Button("Refresh Feeds") {
                        refreshFeeds()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var emptyStateIcon: String {
        switch selectedTopic {
        case "Briefing": return "text.book.closed"
        case "Today", "Unread": return "newspaper"
        case "Saved Stories": return "bookmark"
        case "History": return "clock"
        default: return "tray"
        }
    }

    private var emptyStateTitle: String {
        switch selectedTopic {
        case "Briefing": return "No Stories for This Briefing"
        case "Today": return "No Articles Yet"
        case "Unread": return "All Caught Up"
        case "Saved Stories": return "No Saved Stories"
        case "History": return "No Reading History"
        default: return "Nothing in \(selectedTopic ?? "Section")"
        }
    }

    private var emptyStateText: String {
        switch selectedTopic {
        case "Briefing":
            return
                "There are no unread, unmuted stories published in the last 24 hours. Your archive and normal feed remain available."
        case "Today": return "Subscribe to feeds or click refresh to load the latest stories."
        case "Unread": return "You've read all stories in your feeds. Check back later for updates."
        case "Saved Stories": return "Stories you bookmark will be kept here for easy reading."
        case "History": return "Articles you have opened will appear here."
        default:
            return "New articles matching \(selectedTopic ?? "this section") will appear here once your feeds refresh."
        }
    }

    // MARK: - Keyboard Handling

    private func handleKeyPress(press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard articlePath.isEmpty,
            press.modifiers.intersection([.command, .control, .option]).isEmpty
        else { return .ignored }

        switch press.key {
        case .downArrow:
            navigateList(offset: 1, proxy: proxy)
            return .handled
        case .upArrow:
            navigateList(offset: -1, proxy: proxy)
            return .handled
        case .return, .space:
            openFocusedArticle()
            return .handled
        default:
            if press.characters == "j" {
                navigateList(offset: 1, proxy: proxy)
                return .handled
            } else if press.characters == "k" {
                navigateList(offset: -1, proxy: proxy)
                return .handled
            } else if press.characters == "m" {
                if let id = focusedArticleID { readManager.toggleRead(id) }
                return .handled
            } else if press.characters == "s" {
                if let id = focusedArticleID, let art = filteredArticles.first(where: { $0.id == id }) {
                    if savedStories.isSaved(art) {
                        savedStories.remove(art)
                    } else {
                        savedStories.save(art)
                    }
                }
                return .handled
            } else if press.characters == "r" {
                refreshFeeds()
                return .handled
            } else if press.characters == "e" {
                toggleFocusedEventSources()
                return .handled
            } else if press.characters == "g" {
                guard !isBriefing else { return .ignored }
                groupsEvents.toggle()
                return .handled
            } else if press.characters == "u" {
                applyPendingUpdates(proxy: proxy)
                return .handled
            } else if press.characters == "o" {
                if let id = focusedArticleID, let art = filteredArticles.first(where: { $0.id == id }),
                    let url = URL(string: art.link)
                {
                    NSWorkspace.shared.open(url)
                }
                return .handled
            }
            return .ignored
        }
    }

    private func navigateList(offset: Int, proxy: ScrollViewProxy) {
        let listed = entries
        guard !listed.isEmpty else { return }
        let currentIndex: Int
        if let currentID = focusedArticleID, let idx = listed.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        } else {
            currentIndex = offset > 0 ? -1 : listed.count
        }
        let targetIndex = max(0, min(listed.count - 1, currentIndex + offset))
        let target = listed[targetIndex]
        focusedArticleID = target.id
        withAnimation(reduceMotion ? nil : AppMotion.quick) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    private func openFocusedArticle() {
        let listed = entries
        guard let entry = listed.first(where: { $0.id == focusedArticleID }) ?? listed.first else { return }
        switch entry {
        case .article(let article): openArticle(article)
        case .event(let summary, let representative, _): openEvent(summary.eventID, article: representative)
        }
    }

    private func toggleFocusedEventSources() {
        guard let entry = entries.first(where: { $0.id == focusedArticleID }),
            case .event(let summary, _, _) = entry
        else { return }
        let binding = expansionBinding(summary.eventID)
        withAnimation(reduceMotion ? nil : AppMotion.state) { binding.wrappedValue.toggle() }
        if binding.wrappedValue {
            let eventID = summary.eventID
            Task { await articleStore.markEventSeen(eventID) }
        }
    }

    private func openArticle(_ article: FeedArticle, context: [FeedArticle]? = nil) {
        let context = context ?? filteredArticles
        focusedArticleID = article.id
        readManager.markAsRead(article.id)
        articlePath.append(FeedArticleWrap(article: article, contextArticles: context))
    }

    /// Opening a publication from an event records the event version as seen; it marks only the
    /// opened article read.
    private func openEvent(_ eventID: String, article: FeedArticle, context: [FeedArticle]? = nil) {
        Task { await articleStore.markEventSeen(eventID) }
        openArticle(article, context: context)
    }

    private func separate(_ article: FeedArticle, from eventID: String) {
        Task {
            appliesNextUpdate = true
            if await articleStore.separateArticle(article.id, fromEvent: eventID) {
                feedManager.clusterEventsInBackground()
            } else {
                appliesNextUpdate = false
            }
        }
    }

    /// The reader asked for these stories, so they are shown when the refresh ends instead of waiting behind
    /// the update button.
    private func refreshFeeds() {
        Task {
            await feedManager.fetchFeedsAsync()
            // An open article keeps the list still; its updates wait as usual.
            guard articlePath.isEmpty else { return }
            appliesNextUpdate = true
            refreshReloads += 1
        }
    }
}

// MARK: - Keyboard Shortcuts Window

/// Help → Keyboard Shortcuts. Lists the single-key shortcuts that menus cannot show.
struct KeyboardShortcutsView: View {
    private static let sections: [(title: String, rows: [(keys: String, action: String)])] = [
        (
            "Navigation",
            [
                ("J or ↓", "Next story"),
                ("K or ↑", "Previous story"),
                ("Space or ↵", "Open focused story"),
                ("Esc or ←", "Back to list"),
            ]
        ),
        (
            "Story",
            [
                ("M", "Mark as read or unread"),
                ("S", "Save or remove from Saved Stories"),
                ("O", "Open in browser"),
                ("E", "Show or hide event coverage"),
                ("W or ⇧⌘R", "Switch between Story and Web"),
            ]
        ),
        (
            "List",
            [
                ("G", "Group coverage by event"),
                ("U", "Show queued updates"),
                ("R or ⌘R", "Refresh feeds"),
                ("⌘1 – ⌘4", "Today, Unread, Saved Stories, History"),
            ]
        ),
    ]

    var body: some View {
        Form {
            ForEach(Self.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.keys) { row in
                        LabeledContent(row.action) {
                            Text(row.keys)
                                .monospaced()
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
