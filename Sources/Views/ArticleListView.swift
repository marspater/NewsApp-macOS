// ArticleListView.swift
// NewsApp Article Grid List View & Navigation Coordinator

import SwiftUI
import AppKit

struct ArticleListView: View {
    @Binding var selectedTopic: String?
    @Binding var searchText: String
    @Binding var articlePath: NavigationPath
    @Binding var columnVisibility: NavigationSplitViewVisibility
    
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    
    @AppStorage("articleGridLayout") private var gridLayout = false
    @AppStorage("groupsEventCoverage") private var groupsEvents = true
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.effectiveContrast) private var contrast
    @State private var focusedArticleID: String? = nil
    @State private var isShortcutsHelpPresented: Bool = false
    
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
    /// Stories the reader's muting removes from this list, across every page.
    @State private var mutedCount = 0
    @State private var showsMuted = false
    @State private var confirmsUnmuteAll = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBriefing: Bool { selectedTopic == "Briefing" && !isSearching }

    /// Muting applies to the feed lists and search; Saved Stories and History list everything the reader kept or opened.
    private var listMuting: MuteRules {
        isSearching || (selectedTopic != "Saved Stories" && selectedTopic != "History") ? appSettings.muteRules : MuteRules()
    }

    private var queryIdentity: String {
        let muting = listMuting
        return "\(selectedTopic ?? "Today"):\(searchText):\(themeManager.autoHideRead):\(muting.sourceParameter)|\(muting.topicParameter):\(showsMuted)"
    }

    var filteredArticles: [FeedArticle] { buffer.displayed.articles }

    /// Saved Stories and History list exactly what the reader kept or opened.
    private var groupingMode: FeedGroupingMode {
        groupsEvents && !isBriefing && selectedTopic != "Saved Stories" && selectedTopic != "History" ? .events : .publications
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    listContent(proxy: proxy)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        headerBar
                        if buffer.pending != nil { updatesButton(proxy: proxy) }
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 24
                } action: { _, scrolled in
                    isScrolledAway = scrolled
                }
                .onHover { isPointerInList = $0 }
                .onChange(of: queuedUpdateCount, handleQueuedUpdatesChange)
                .softScrollEdge()
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
                       let art = filteredArticles.first(where: { $0.id == id }) {
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
                       let url = URL(string: art.link) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .task(id: "\(queryIdentity):\(articleStore.revision):\(articleStore.eventRevision):\(pageRequest)") {
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
                            muting: appSettings.muteRules)
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
                let fetched = try await fetchPage(after: isPaging ? cursor : nil, muting: showsMuted ? MuteRules() : muting)
                try Task.checkCancellation()
                if !isPaging {
                    var hidden = 0
                    if !muting.isEmpty { hidden = try await countMuted(muting) }
                    try Task.checkCancellation()
                    mutedCount = hidden
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
        if topic == "History" { read = true }
        else if topic == "Unread" || (themeManager.autoHideRead && topic != "Saved Stories") { read = false }
        else { read = nil }
        return (topic, read, topic == "Saved Stories" ? true : nil)
    }

    private func fetchPage(after pageCursor: ArticleQueryCursor?, muting: MuteRules) async throws -> [FeedArticle] {
        if isSearching {
            return try await articleStore.database.searchArticles(query: searchText, limit: 201, after: pageCursor, muting: muting)
        }
        let filters = listFilters
        return try await articleStore.database.fetchArticles(
            section: filters.topic, isRead: filters.read, isSaved: filters.saved,
            limit: 201, after: pageCursor, muting: muting)
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
            Label(showsMuted ? "Showing \(mutedCount) muted" : "\(mutedCount) hidden by muting",
                  systemImage: showsMuted ? "eye" : "eye.slash")
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(showsMuted ? "Muted stories are shown in this list" : "Stories hidden by your muted sources and topics")
        .accessibilityLabel(showsMuted ? "Showing \(mutedCount) muted stories" : "\(mutedCount) stories hidden by muting")
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
            Label(count > 0 ? "\(count) new \(count == 1 ? "story" : "stories")" : "Show updates", systemImage: "arrow.up")
                .font(AppTypography.label)
                .foregroundStyle(AppColor.accent)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(AppColor.accent.opacity(contrast == .increased ? 0.22 : 0.14))
                        .overlay(Capsule().stroke(AppColor.accent.opacity(contrast == .increased ? 0.60 : 0.0), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.capsule)
        .padding(.bottom, AppSpacing.xs)
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
        NSAccessibility.post(element: application, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    columnVisibility = (columnVisibility == .detailOnly ? .all : .detailOnly)
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (⌃⌘S)")
            .accessibilityLabel("Toggle Sidebar")
            
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(searchText.isEmpty ? (selectedTopic ?? "Today") : "Search")
                    .font(AppTypography.display)
                    .foregroundStyle(AppColor.primaryText)
                HStack(spacing: AppSpacing.xs) {
                    Text(isBriefing ? "Up to 10 unread stories · Last 24 hours" : "\(entries.count) stories · Your personal edition")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                    if mutedCount > 0 && !listMuting.isEmpty {
                        Text("·")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                            .accessibilityHidden(true)
                        mutingMenu
                    }
                }
            }
            
            Spacer()
            
            if isBriefing {
                Button("New Briefing", action: startNewBriefing)
                    .help("Select a new briefing from the latest unread stories")
            }

            Toggle(isOn: $groupsEvents) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14, weight: .medium))
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundColor(groupsEvents ? AppColor.accent : AppColor.secondaryText)
            .help(groupsEvents ? "Showing one card per event. Show individual publications (G)" : "Showing individual publications. Group coverage of the same event (G)")
            .disabled(isBriefing)
            .accessibilityLabel("Group Coverage by Event")
            .accessibilityValue(groupsEvents ? "On" : "Off")

            Picker("Article layout", selection: $gridLayout) {
                Image(systemName: "list.bullet").tag(false)
                    .accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true)
                    .accessibilityLabel("Grid")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(width: 80)
            .help("Choose list or grid layout")

            Button {
                isShortcutsHelpPresented.toggle()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShortcutsHelpPresented) {
                shortcutsHelpView
            }
            .help("Keyboard Shortcuts")
            .accessibilityLabel("Keyboard Shortcuts")
            
            Button {
                refreshFeeds()
            } label: {
                if feedManager.isAnyFeedLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppColor.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .disabled(feedManager.isAnyFeedLoading)
            .help("Refresh Feeds (R or ⌘R)")
            .accessibilityLabel("Refresh Feeds")
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.top, 24)
        .padding(.bottom, AppLayout.cardGap)
    }
    
    private func startNewBriefing() {
        briefing = nil
        pageRequest += 1
    }

    private var briefingCompletion: some View {
        VStack(spacing: AppSpacing.sm) {
            if let briefing {
                Text(briefing.isComplete(readManager.readArticles) ? "Briefing complete" : "\(briefing.readCount(readManager.readArticles)) of \(briefing.articles.count) stories read")
                    .font(AppTypography.headline)
                Text("Selection frozen at \(briefing.startedAt.formatted(date: .omitted, time: .shortened)). New stories stay in your regular feed.")
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
    
    private func articleGrid(proxy _: ScrollViewProxy) -> some View {
        Group {
            if gridLayout {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: AppLayout.cardGap)], spacing: AppLayout.cardGap) {
                    articleCards
                }
            } else {
                LazyVStack(spacing: AppSpacing.sm) {
                    articleCards
                }
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.bottom, AppSpacing.xl)
    }

    private var articleCards: some View {
        ForEach(entries) { entry in
            switch entry {
            case .article(let article):
                ArticleCardView(article: article, isSelected: article.id == focusedArticleID, compact: !gridLayout) {
                    openArticle(article)
                }
                .id(entry.id)
                .onAppear(perform: NewsSignposts.firstCardAppeared)
            case .event(let summary, let representative, _):
                EventCardView(
                    representative: representative,
                    summary: summary,
                    isSelected: representative.id == focusedArticleID,
                    compact: !gridLayout,
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
            } else if !isBriefing && (selectedTopic != "Saved Stories" && selectedTopic != "History") && !failedFeeds.isEmpty && filteredArticles.isEmpty {
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
                    Button(mutedCount == 1 ? "Show 1 Muted Story" : "Show \(mutedCount) Muted Stories") { showsMuted = true }
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
        case "Briefing": return "There are no unread, unmuted stories published in the last 24 hours. Your archive and normal feed remain available."
        case "Today": return "Subscribe to feeds or click refresh to load the latest stories."
        case "Unread": return "You've read all stories in your feeds. Check back later for updates."
        case "Saved Stories": return "Stories you bookmark will be kept here for easy reading."
        case "History": return "Articles you have opened will appear here."
        default: return "New articles matching \(selectedTopic ?? "this section") will appear here once your feeds refresh."
        }
    }
    
    // MARK: - Keyboard Handling
    
    private func handleKeyPress(press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard articlePath.isEmpty,
              press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        
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
                   let url = URL(string: art.link) {
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
              case .event(let summary, _, _) = entry else { return }
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
    
    private func refreshFeeds() {
        feedManager.fetchFeeds()
    }
    
    // MARK: - Shortcuts Help View
    
    private var shortcutsHelpView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(AppTypography.headline)
                .foregroundColor(AppColor.primaryText)
                .padding(.bottom, 2)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("NAVIGATION")
                    .font(AppTypography.metadata)
                    .foregroundColor(AppColor.tertiaryText)
                    .tracking(AppTypography.sourceEyebrowTracking)
                shortcutRow("J / ↓", "Next article")
                shortcutRow("K / ↑", "Previous article")
                shortcutRow("Space / ↵", "Open focused article")
                shortcutRow("Esc / ←", "Back to list")
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIONS")
                    .font(AppTypography.metadata)
                    .foregroundColor(AppColor.tertiaryText)
                    .tracking(AppTypography.sourceEyebrowTracking)
                shortcutRow("M", "Toggle read / unread")
                shortcutRow("S", "Bookmark story")
                shortcutRow("O", "Open in browser")
                shortcutRow("E", "Show or hide event sources")
                shortcutRow("G", "Group by event / publications")
                shortcutRow("U", "Show queued updates")
                shortcutRow("W", "Toggle Reader / Web view")
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("GLOBAL")
                    .font(AppTypography.metadata)
                    .foregroundColor(AppColor.tertiaryText)
                    .tracking(AppTypography.sourceEyebrowTracking)
                shortcutRow("R / ⌘R", "Refresh all feeds")
                shortcutRow("⌘1 - ⌘4", "Jump to section")
            }
        }
        .padding(14)
        .frame(width: 270)
    }
    
    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppColor.badgeBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
            Spacer()
            Text(desc)
                .font(AppTypography.caption)
                .foregroundColor(AppColor.secondaryText)
        }
    }
}
