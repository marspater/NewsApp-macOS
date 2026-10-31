// ArticleListView.swift
// NewsApp Article Grid List View & Navigation Coordinator

import AppKit
import SwiftUI

struct ListCommandActions {
    let canGroupStories: Bool
    let newBriefing: (() -> Void)?
    /// Leaves the Briefing for the destination shown before it (Navigate › Back).
    var back: (() -> Void)? = nil
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
    /// Where the Briefing's Back returns: the destination shown before it, Today if none (#780).
    var previousTopic = "Today"
    /// A sheet covers the window, so the Briefing carousel holds still.
    var isSheetPresented = false

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
    @FocusState private var listHasFocus: Bool
    @State private var focusedArticleID: String? = nil

    @State private var briefing: FiniteBriefing?
    /// The Briefing's cited facts and hero images, read from the library once per edition.
    @State private var briefingDetails = BriefingStoryDetails()
    @AppStorage("briefingEditionHour") private var briefingEditionHour = FiniteBriefing.defaultEditionHour
    /// The stored edition, shared by every window: when it was selected and its story IDs in order.
    @AppStorage("briefingEditionSelectedAt") private var briefingEditionSelectedAt = 0.0
    @AppStorage("briefingEditionArticleIDs") private var briefingEditionArticleIDs = ""
    @AppStorage("readingInterestsResetAt") private var readingInterestsResetAt = 0.0
    @State private var imagePrefetchStart = 0
    @Environment(\.readerImageLoader) private var imageLoader
    /// Launch shows the cached snapshot once, in one transition (DESIGN.md 13, #602); later windows start settled.
    @MainActor static var hasSettledLaunch = false
    @State private var isSettled = ArticleListView.hasSettledLaunch

    private var imagePrefetchURLs: [URL] {
        buffer.displayed.articles.dropFirst(imagePrefetchStart).prefix(30).compactMap {
            $0.imageUrl.flatMap(URL.init(string:))
        }
    }

    static func prefetchStart(visibleIndex: Int, currentStart: Int) -> Int {
        if visibleIndex < currentStart || visibleIndex >= currentStart + 18 { return max(0, visibleIndex - 6) }
        return currentStart
    }

    private func prefetchAhead(of id: String) {
        guard let index = buffer.displayed.articles.firstIndex(where: { $0.id == id }) else { return }
        imagePrefetchStart = Self.prefetchStart(visibleIndex: index, currentStart: imagePrefetchStart)
    }
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
    /// Set by the reader's own regrouping actions, which apply at once.
    @State private var appliesNextUpdate = false
    /// Reloads the list once a refresh the reader asked for has finished.
    @State private var refreshReloads = 0
    /// A refresh the reader started: its results replace the list as they arrive instead of queueing behind
    /// the updates button.
    @State private var isReaderRefreshing = false
    /// Stories the reader's muting removes from this list, across every page.
    @State private var mutedCount = 0
    /// Stories of this list across all its pages and the events grouping them; nil until a new list has loaded.
    @State private var listTotals: (stories: Int, events: Int)?
    @State private var searchSuggestion: String?
    @State private var showsMuted = false
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
            "\(selectedTopic ?? "Today"):\(searchText):\(themeManager.autoHideRead):\(muting.sourceParameter)|\(muting.topicParameter):\(showsMuted)"
    }

    var filteredArticles: [FeedArticle] { buffer.displayed.articles }

    /// Saved Stories and History list exactly what the reader kept or opened.
    private var groupingMode: FeedGroupingMode {
        groupsEvents && selectedTopic != "Saved Stories" && selectedTopic != "History"
            ? .events : .publications
    }

    /// The shown page grouped once per change of page or grouping; the body reads it several times (#778).
    @State private var groupedEntries = GroupedEntries()

    private var entries: [FeedEntry] { groupedEntries.entries(of: buffer.displayed, mode: groupingMode) }

    /// Once stories are on screen they stay put: background collection, grouping and rating queue behind the
    /// updates button instead of reshuffling the list. A refresh the reader started is the exception while the list
    /// is showing: they asked for the new stories. So is Today showing only earlier days' stories, such as the cache
    /// at launch the next morning.
    private var isHoldingList: Bool {
        guard !appliesNextUpdate else { return false }
        if !articlePath.isEmpty { return true }
        if !isSearching, (selectedTopic ?? "Today") == "Today", buffer.showsOnlyEarlierDays() { return false }
        return !isReaderRefreshing
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
        if !filteredArticles.isEmpty {
            articleGrid(proxy: proxy)
                .opacity(isSettled ? 1 : 0)
            if hasMoreResults {
                Button("Load More Stories") { pageRequest += 1 }
                    .disabled(isLoadingPage)
                    .padding(.bottom, AppSpacing.lg)
            }
            if queryError != nil {
                queryFailureView
                    .padding(.top, AppSpacing.xl)
            }
        }
    }

    /// Loading, failure, no results and empty sections, centered in the visible list area under the masthead.
    @ViewBuilder
    private var emptyListContent: some View {
        if isLoadingPage {
            ProgressView("Loading stories…")
        } else if queryError != nil {
            queryFailureView
        } else if isSearching {
            VStack(spacing: AppSpacing.md) {
                ContentUnavailableView.search(text: searchText)
                if let searchSuggestion {
                    Button("Search for “\(searchSuggestion)”") { searchText = searchSuggestion }
                }
                if mutedCount > 0 && !showsMuted && !listMuting.isEmpty {
                    Button(mutedCount == 1 ? "Show 1 Muted Story" : "Show \(mutedCount) Muted Stories") {
                        showsMuted = true
                    }
                }
            }
        } else {
            emptyStateView
        }
    }

    private var queryFailureView: some View {
        VStack(spacing: AppSpacing.md) {
            ContentUnavailableView {
                Label(
                    filteredArticles.isEmpty ? "Couldn’t Load Stories" : "Couldn’t Load More Stories",
                    systemImage: "exclamationmark.triangle")
            } description: {
                Text("The archive could not be loaded. Please try again.")
            } actions: {
                Button("Retry") { pageRequest += 1 }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedStory: FeedArticle? {
        guard articlePath.isEmpty, let focusedArticleID else { return nil }
        return filteredArticles.first { $0.id == focusedArticleID }
    }

    private var listCommandActions: ListCommandActions? {
        guard articlePath.isEmpty else { return nil }
        return ListCommandActions(
            canGroupStories: true, newBriefing: isBriefing ? { startNewBriefing() } : nil,
            back: isBriefing ? { leaveBriefing() } : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                scrollView(proxy: proxy)
                    .toolbar { listToolbar(proxy: proxy) }
            }
        }
        .focusedSceneValue(\.selectedStory, selectedStory)
        .focusedSceneValue(\.listActions, listCommandActions)
        .navigationTitle(locationTitle)
        // The masthead shows the location, so the toolbar does not repeat it (DESIGN.md 5).
        .toolbar(removing: .title)
        .task(id: imagePrefetchURLs) {
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            await DecodedImageCache.prefetch(imagePrefetchURLs, using: imageLoader)
        }
        .task(id: taskQueryReloadKey) {
            await performQueryReload()
            await settleLaunch()
        }
    }

    /// Once the cached snapshot is loaded, waits (at most a second) for the first page's card images, shows the cards
    /// in one transition, and only then starts the launch refresh and the catch-up clustering with its image lookup.
    private func settleLaunch() async {
        guard !Self.hasSettledLaunch, articleStore.isReady, !isLoadingPage else { return }
        let urls = entries.prefix(12).compactMap {
            FeedArticle.bestCardImage(in: [$0.representative] + $0.visibleArticles)
        }
        let loader = imageLoader
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await DecodedImageCache.prefetch(urls, using: loader) }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        guard !Task.isCancelled, !Self.hasSettledLaunch else { return }
        Self.hasSettledLaunch = true
        withAnimation(reduceMotion ? nil : AppMotion.navigation) { isSettled = true }
        feedManager.fetchFeeds()
        feedManager.clusterEventsInBackground()
    }

    @ViewBuilder
    private func scrollView(proxy: ScrollViewProxy) -> some View {
        attachNavigationCommands(
            to: ScrollView {
                masthead
                listContent(proxy: proxy)
            }
            // An empty list keeps its masthead at the top and centers its state in the visible area.
            .overlay { emptyListOverlay }
            .onChange(of: queuedUpdateCount, handleQueuedUpdatesChange)
            // Another window stored a new briefing (New Briefing, or the next day's): show the same one here.
            .onChange(of: briefingEditionSelectedAt) { _, stored in
                guard let shown = briefing, shown.startedAt.timeIntervalSince1970 != stored else { return }
                briefing = nil
                if isBriefing { pageRequest += 1 }
            }
            // Subscribing asks for those stories, as Refresh does: the refresh the subscription starts shows them
            // instead of parking them behind the updates button, where the list looked unchanged (#782).
            .onChange(of: appSettings.feedURLs) { previous, current in
                if FeedUpdateBuffer.subscriptionAdded(from: previous, to: current) { refreshFeeds(subscription: true) }
            }
            // A subscription's stories held while an article was open appear when the reader closes.
            .onChange(of: articlePath.isEmpty) { _, isClosed in
                guard isClosed, buffer.holdsSubscription else { return }
                showPendingUpdates()
                buffer.holdsSubscription = false
                appliesNextUpdate = true
                refreshReloads += 1
            }
            .focusable()
            .focused($listHasFocus)
            .defaultFocus($listHasFocus, true)
            .onAppear { listHasFocus = true }
            .focusEffectDisabled()
            .onKeyPress { press in
                handleKeyPress(press: press, proxy: proxy)
            },
            proxy: proxy
        )
    }

    @ViewBuilder
    private func attachNavigationCommands<Content: View>(to content: Content, proxy: ScrollViewProxy) -> some View {
        content
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
                handleToggleRead()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markAllReadCommand)) { _ in
                handleMarkAllAsRead()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSaveCommand)) { _ in
                handleToggleSave()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInBrowserCommand)) { _ in
                handleOpenInBrowser()
            }
    }

    @ViewBuilder
    private var emptyListOverlay: some View {
        if filteredArticles.isEmpty {
            emptyListContent
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppLayout.pageInset)
        }
    }

    private func handleToggleRead() {
        if articlePath.isEmpty, let id = focusedArticleID {
            readManager.toggleRead(id)
        }
    }

    /// Story › Mark All as Read: every story loaded in the current list, not stories still to page in.
    private func handleMarkAllAsRead() {
        guard articlePath.isEmpty else { return }
        let unread = filteredArticles.map(\.id).filter { !readManager.isRead($0) }
        guard !unread.isEmpty else { return }
        readManager.markAsRead(ids: unread)
        mastheadNotice = MastheadNotice(
            message: unread.count == 1 ? "1 story marked as read" : "\(unread.count) stories marked as read")
    }

    private func handleToggleSave() {
        guard articlePath.isEmpty, let id = focusedArticleID,
            let art = filteredArticles.first(where: { $0.id == id })
        else { return }
        if savedStories.isSaved(art) {
            savedStories.remove(art)
        } else {
            savedStories.save(art)
        }
    }

    private func handleOpenInBrowser() {
        guard articlePath.isEmpty, let id = focusedArticleID,
            let art = filteredArticles.first(where: { $0.id == id }),
            let url = WebLink.url(art.link)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private var taskQueryReloadKey: String {
        "\(queryIdentity):\(articleStore.revision):\(articleStore.eventRevision):\(pageRequest):\(refreshReloads)"
    }

    private func performQueryReload() async {
        let identity = queryIdentity
        let runID = UUID()
        if isBriefing {
            // Bursts of store revisions rebuilt the board once each; they are debounced as in the list. A new or
            // rolled-over edition (no briefing yet) loads at once.
            if briefing != nil, loadedQuery == identity, !buffer.displayed.articles.isEmpty {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            queryRunID = runID
            queryError = nil
            isLoadingPage = true
            defer { if queryRunID == runID { isLoadingPage = false } }
            do {
                let now = Date()
                if let current = briefing,
                    !FiniteBriefing.isCurrent(selectedAt: current.startedAt, now: now, hour: briefingEditionHour)
                {
                    briefing = nil
                }
                if briefing == nil, let stored = try await storedBriefingEdition(now: now) {
                    briefing = stored
                }
                if briefing == nil {
                    let candidates = try await articleStore.database.fetchArticles(
                        isRead: false, limit: FiniteBriefing.candidateLimit,
                        publicationWindow: now.addingTimeInterval(-FiniteBriefing.duration)...now,
                        muting: appSettings.muteRules)
                    try Task.checkCancellation()
                    let priorities = try await articleStore.database.briefingPriorities(
                        articleIDs: candidates.map(\.id))
                    try Task.checkCancellation()
                    let resetDate =
                        readingInterestsResetAt > 0
                        ? Date(timeIntervalSince1970: readingInterestsResetAt)
                        : nil
                    let interests = try await articleStore.database.briefingInterests(
                        now: now, resetAt: resetDate)
                    try Task.checkCancellation()
                    let edition = FiniteBriefing(
                        candidates: candidates, readIDs: readManager.readArticles, now: now, priorities: priorities,
                        interests: interests)
                    // Selection awaited the database, so another window may have stored an edition meanwhile. This
                    // check and the write run on the main actor without a suspension, so the first stored edition
                    // wins and later windows adopt it.
                    if !briefingEditionArticleIDs.isEmpty,
                        FiniteBriefing.isCurrent(
                            selectedAt: Date(timeIntervalSince1970: briefingEditionSelectedAt), now: now,
                            hour: briefingEditionHour)
                    {
                        briefing = try await storedBriefingEdition(now: now) ?? edition
                    } else {
                        briefing = edition
                        briefingEditionSelectedAt = edition.startedAt.timeIntervalSince1970
                        briefingEditionArticleIDs = edition.articles.map(\.id).joined(separator: "\n")
                    }
                }
                let briefingArticles = briefing?.articles ?? []
                let events = (try? await articleStore.eventFeedSummaries(for: briefingArticles.map(\.id))) ?? []
                try Task.checkCancellation()
                let snapshot = FeedSnapshot(articles: briefingArticles, events: events)
                if buffer.displayed != snapshot { buffer.replace(with: snapshot) }
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
        // The debounce comes before any state changes, so a burst of revisions that keeps restarting it leaves the
        // list alone instead of re-rendering it for each one (#778).
        if FeedUpdateBuffer.debouncesReload(
            isPaging: isPaging, isNewQuery: isNewQuery, hasStories: !buffer.displayed.articles.isEmpty)
        {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
        queryRunID = runID
        loadedPageRequest = pageRequest
        if isNewQuery {
            buffer = FeedUpdateBuffer()
            imagePrefetchStart = 0
            cursor = nil
            hasMoreResults = false
            expandedEvents = []
            listTotals = nil
            loadedQuery = identity
        }
        queryError = nil
        isLoadingPage = true
        defer { if queryRunID == runID { isLoadingPage = false } }
        do {
            let muting = listMuting
            let fetched = try await fetchPage(
                after: isPaging ? cursor : nil, muting: showsMuted ? MuteRules() : muting)
            try Task.checkCancellation()
            if !isPaging {
                var hidden = 0
                if !muting.isEmpty { hidden = try await countMuted(muting) }
                let totals = try await countListed(showsMuted ? MuteRules() : muting)
                // A search that finds nothing offers the closest spelling that does; a failure means no suggestion.
                var suggestion: String?
                if isSearching && fetched.isEmpty {
                    suggestion = try? await articleStore.database.searchSuggestion(
                        query: searchText, muting: showsMuted ? MuteRules() : muting)
                }
                try Task.checkCancellation()
                mutedCount = hidden
                listTotals = totals
                searchSuggestion = suggestion
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
                let result = buffer.receive(snapshot, holding: holding, mode: groupingMode, hasMore: morePages)
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
            guard queryRunID == runID else { return }
            queryError = "Could not load stories. Please try again."
            // The masthead must not keep totals from before a reload that failed.
            if !isPaging { listTotals = nil }
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

    private func fetchPage(after pageCursor: ArticleQueryCursor?, muting: MuteRules) async throws -> [FeedArticle] {
        if isSearching {
            return try await articleStore.database.searchArticles(
                query: searchText, limit: 201, after: pageCursor, muting: muting)
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

    /// The masthead's totals: every story of the list, across all its pages, and the events grouping them (#782).
    private func countListed(_ muting: MuteRules) async throws -> (stories: Int, events: Int) {
        if isSearching {
            return try await articleStore.database.listTotals(search: searchText, muting: muting)
        }
        let filters = listFilters
        return try await articleStore.database.listTotals(
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
    }

    // MARK: - Queued Updates

    private func updatesButton(proxy: ScrollViewProxy) -> some View {
        let count = buffer.newEntryCount(groupingMode)
        return Button {
            applyPendingUpdates(proxy: proxy)
        } label: {
            Label(
                count > 0 ? "Show \(count) New \(count == 1 ? "Story" : "Stories")" : "Show Updates",
                systemImage: "arrow.up"
            )
            .font(AppTypography.label)
            .monospacedDigit()
            .labelStyle(.titleAndIcon)
        }
        .help("Stories that arrived in the background (U)")
        .accessibilityHint("Moves to the top of the updated list")
    }

    private func applyPendingUpdates(proxy: ScrollViewProxy) {
        guard buffer.pending != nil else { return }
        showPendingUpdates()
        if let first = entries.first {
            withAnimation(reduceMotion ? nil : AppMotion.hover) {
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
            // One line when it fits; at narrow widths the inline actions move to a second line instead of
            // squeezing every part into its own wrapped column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.xs) {
                    statusText
                    statusExtras(startsLine: false)
                }
                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    statusText
                    HStack(spacing: AppSpacing.xs) { statusExtras(startsLine: true) }
                }
            }
        }
        // Aligned with the content column: the centred list and Briefing measure, or the full-width grid.
        .frame(maxWidth: gridLayout && !isBriefing ? .infinity : AppLayout.listMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppLayout.cardGap)
        .confirmationDialog("Unmute every source and topic?", isPresented: $confirmsUnmuteAll) {
            Button("Unmute All", role: .destructive) { appSettings.clearMuting() }
        } message: {
            Text("Muted stories return to every list.")
        }
    }

    private var statusText: some View {
        Text(listSubtitle)
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
            .monospacedDigit()
    }

    private var statusSeparator: some View {
        Text("·")
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
            .accessibilityHidden(true)
    }

    /// The masthead notice and inline actions. `startsLine` drops the separator before the first one.
    @ViewBuilder
    private func statusExtras(startsLine: Bool) -> some View {
        if let mastheadNotice {
            if !startsLine { statusSeparator }
            Text(mastheadNotice.message)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
        }
        if mutedCount > 0 && !listMuting.isEmpty {
            if !startsLine || mastheadNotice != nil { statusSeparator }
            mutingMenu
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func listToolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        // The reader's Back, in the same place (DESIGN.md 5, #780).
        if isBriefing {
            ToolbarItem(placement: .navigation) {
                Button(action: leaveBriefing) {
                    Label("Back to \(previousTopic)", systemImage: "chevron.left")
                }
                .help("Back to \(previousTopic)")
            }
        }
        if articlePath.isEmpty, buffer.pending != nil {
            ToolbarItem(placement: .navigation) { updatesButton(proxy: proxy) }
        }
        // With the duplicate title removed nothing fills the toolbar, so macOS 26 and later would lay the list
        // controls out from the leading edge. A flexible spacer keeps them, and search, at the trailing edge.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $groupsEvents.animation(reduceMotion ? nil : AppMotion.state)) {
                Label(
                    "Group Stories by Event",
                    systemImage: groupsEvents ? "square.stack.3d.up.fill" : "square.stack.3d.up")
            }
            .toggleStyle(.button)
            .help(
                groupsEvents
                    ? "Showing one card per event. Show every story on its own (G)"
                    : "Showing every story on its own. Group stories of the same event (G)"
            )

            Picker("Story Layout", selection: $gridLayout) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Grid", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
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
            ToolbarItem(placement: .primaryAction) {
                Button(action: startNewBriefing) {
                    Label("New Briefing", systemImage: "text.book.closed")
                }
                .help("Select a new briefing now from the latest unread stories")
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
            .help(feedManager.isAnyFeedLoading ? "Refreshing feeds…" : "Check feeds for new stories (R or ⌘R)")
            .accessibilityLabel("Refresh Feeds")
            .accessibilityValue(feedManager.isAnyFeedLoading ? "Refreshing" : "")
        }
    }

    /// The list's story count and how many events group them, across every page rather than the loaded one (#782);
    /// "unread" when the list shows unread stories only. Then when feeds last refreshed.
    private var listSubtitle: String {
        if isBriefing {
            let edition = (briefing?.startedAt ?? Date()).formatted(.dateTime.weekday(.wide).month(.wide).day())
            return "\(edition) briefing · Selected by coverage and your interests"
        }
        var parts: [String] = []
        if !isSearching && (selectedTopic ?? "Today") == "Today" {
            parts.append(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
        }
        if let listTotals {
            let showsUnreadOnly =
                isSearching ? ArticleFilterQuery.parse(searchText).isReadFilter == false : listFilters.read == false
            let unread = showsUnreadOnly ? "unread " : ""
            parts.append(
                "\(listTotals.stories.formatted()) \(unread)\(listTotals.stories == 1 ? "story" : "stories")")
            if groupingMode == .events && listTotals.events > 0 {
                parts.append(
                    "\(listTotals.events.formatted()) grouped \(listTotals.events == 1 ? "event" : "events")")
            }
        }
        if !isSearching, let refreshed = feedManager.lastRefreshCompletedAt {
            parts.append("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func startNewBriefing() {
        briefing = nil
        briefingEditionArticleIDs = ""
        pageRequest += 1
    }

    /// Today's stored edition, when one was selected since the edition hour; stories since removed are skipped.
    private func storedBriefingEdition(now: Date) async throws -> FiniteBriefing? {
        let selectedAt = Date(timeIntervalSince1970: briefingEditionSelectedAt)
        let ids = briefingEditionArticleIDs.split(separator: "\n").map(String.init)
        guard !ids.isEmpty, FiniteBriefing.isCurrent(selectedAt: selectedAt, now: now, hour: briefingEditionHour)
        else { return nil }
        var articles: [FeedArticle] = []
        for id in ids.prefix(FiniteBriefing.maximumStories) {
            if let article = try await articleStore.database.fetchArticles(limit: 1, id: id).first {
                articles.append(article)
            }
            try Task.checkCancellation()
        }
        return articles.isEmpty ? nil : FiniteBriefing(startedAt: selectedAt, articles: articles)
    }

    private func leaveBriefing() {
        selectedTopic = previousTopic
    }

    /// The Briefing's saved stories, as a plain set for the board.
    private func briefingSavedIDs(_ entries: [FeedEntry]) -> Set<String> {
        Set(entries.map(\.representative).filter { savedStories.isSaved($0) }.map(\.id))
    }

    private func toggleSaved(_ article: FeedArticle) {
        if savedStories.isSaved(article) { savedStories.remove(article) } else { savedStories.save(article) }
    }

    // MARK: - Article Grid

    /// The lead is an inset card like the others and shares the list measure (DESIGN.md 3.4, 12).
    /// Both collections retain their original ordering and existing lazy rendering.
    @ViewBuilder
    private func articleGrid(proxy _: ScrollViewProxy) -> some View {
        let listed = entries
        if isBriefing {
            BriefingView(
                entries: listed,
                briefing: briefing,
                details: briefingDetails,
                readIDs: readManager.readArticles,
                savedIDs: briefingSavedIDs(listed),
                focusedID: listHasFocus ? focusedArticleID : nil,
                isMotionPaused: !articlePath.isEmpty || isSheetPresented,
                nextEdition: FiniteBriefing.nextEditionStart(now: Date(), hour: briefingEditionHour),
                actions: BriefingActions(
                    onOpenArticle: { article in openArticle(article) },
                    onOpenEvent: { event in
                        if let entry = listed.first(where: {
                            if case .event(let s, _, _) = $0 { return s.eventID == event.eventID }
                            return false
                        }) {
                            openEvent(
                                event.eventID,
                                article: entry.representative,
                                initialExperienceMode: .eventOverview
                            )
                        }
                    },
                    onStartNewBriefing: { startNewBriefing() },
                    onBackToToday: { selectedTopic = "Today" },
                    onToggleRead: { readManager.toggleRead($0.id) },
                    onToggleSave: { toggleSaved($0) }
                )
            )
            // Stored overview highlights and each hero event's best image; nothing is generated here. Reloads when
            // the stories, their event membership or a stored overview change.
            .task(id: "\(listed.map(\.id)):\(articleStore.eventRevision):\(articleStore.overviewRevision)") {
                let loaded = await BriefingStoryDetails.load(
                    for: listed, heroIDs: Set(BriefingView.heroEntries(listed).map(\.id)), store: articleStore)
                if !Task.isCancelled { briefingDetails = loaded }
            }
            .allowsWindowActivationEvents(true)
        } else {
            let leadID: String? = {
                if #available(macOS 26, *) {
                    return LeadStoryPresentation.firstEligibleID(
                        in: listed, selectedTopic: selectedTopic, isSearching: isSearching
                    )
                }
                return nil
            }()

            VStack(spacing: AppLayout.cardGap) {
                if let leadID, let leadIndex = listed.firstIndex(where: { $0.id == leadID }) {
                    if leadIndex > 0 {
                        cardCollection(Array(listed[..<leadIndex]))
                    }
                    entryCard(listed[leadIndex], isLead: true)
                        .frame(maxWidth: AppLayout.listMaxWidth)
                        .frame(maxWidth: .infinity)
                    if leadIndex + 1 < listed.count {
                        cardCollection(Array(listed[(leadIndex + 1)...]))
                    }
                } else {
                    cardCollection(listed)
                }
            }
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.bottom, AppSpacing.xl)
            // The click that brings an inactive window forward also opens the card under it (#594).
            .allowsWindowActivationEvents(true)
        }
    }

    @ViewBuilder
    private func cardCollection(_ listed: [FeedEntry]) -> some View {
        if gridLayout {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(
                            minimum: AppLayout.gridColumnMinimum,
                            maximum: AppLayout.gridColumnMaximum), spacing: AppLayout.cardGap, alignment: .top)
                ],
                spacing: AppLayout.cardGap
            ) {
                ForEach(listed) { entry in entryCard(entry) }
            }
        } else {
            LazyVStack(spacing: AppLayout.cardGap) {
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
                article: article, isSelected: listHasFocus && article.id == focusedArticleID,
                compact: !gridLayout, isLead: isLead, reservesCoverageRow: gridLayout && !isLead,
                action: { openArticle(article) }, footer: EmptyView()
            )
            .id(entry.id)
            .onAppear {
                NewsSignposts.firstCardAppeared()
                prefetchAhead(of: article.id)
            }
        case .event(let summary, let representative, let visibleMembers):
            EventCardView(
                representative: representative,
                summary: summary,
                visibleMembers: visibleMembers,
                isSelected: listHasFocus && representative.id == focusedArticleID,
                compact: !gridLayout,
                isLead: isLead,
                isExpanded: expansionBinding(summary.eventID),
                openRepresentative: {
                    openEvent(summary.eventID, article: representative, initialExperienceMode: .eventOverview)
                },
                openMember: { member, members in
                    openEvent(
                        summary.eventID, article: member, context: members,
                        initialExperienceMode: .sourcePublication)
                },
                separate: { member in separate(member, from: summary.eventID) },
                combine: { related in combine(related, into: summary.eventID) }
            )
            .id(entry.id)
            .onAppear {
                NewsSignposts.firstCardAppeared()
                prefetchAhead(of: representative.id)
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

    /// A consistent system treatment for empty lists and exhausted feeds (DESIGN.md §8.4).
    private var emptyStateView: some View {
        let failedFeeds = feedManager.feedStatuses.keys.sorted().filter { url in
            if case .some(.failed) = feedManager.feedStatuses[url] { return true }
            return false
        }
        return VStack(spacing: AppSpacing.md) {
            if !isBriefing && feedManager.isAnyFeedLoading && !isSearching && selectedTopic != "Saved Stories"
                && selectedTopic != "History"
            {
                ProgressView("Refreshing news feeds…")
                    .controlSize(.regular)
            } else if !isBriefing && selectedTopic != "Saved Stories" && selectedTopic != "History"
                && !failedFeeds.isEmpty
            {
                ContentUnavailableView {
                    Label(
                        failedFeeds.count == 1
                            ? "1 Feed Couldn’t Refresh" : "\(failedFeeds.count) Feeds Couldn’t Refresh",
                        systemImage: "exclamationmark.triangle")
                } description: {
                    Text(
                        "No stories are available from these feeds. Each feed’s status is in Settings → Subscriptions.")
                } actions: {
                    Button("Retry Feeds") { refreshFeeds() }
                }
            } else {
                ContentUnavailableView {
                    Label(emptyStateTitle, systemImage: emptyStateIcon)
                } description: {
                    Text(emptyStateText)
                } actions: {
                    if mutedCount > 0 && !showsMuted && !listMuting.isEmpty {
                        Button(mutedCount == 1 ? "Show 1 Muted Story" : "Show \(mutedCount) Muted Stories") {
                            showsMuted = true
                        }
                    }
                    if selectedTopic == "Today" || selectedTopic == "Unread" {
                        Button("Refresh Feeds") { refreshFeeds() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        case "Today": return "No Stories Yet"
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
        case "Today": return "Subscribe to feeds or refresh to load the latest stories."
        case "Unread": return "You’ve read every story in your feeds."
        case "Saved Stories": return "Stories you save are kept here."
        case "History": return "Stories you have opened will appear here."
        default:
            return "New stories matching \(selectedTopic ?? "this section") will appear here once your feeds refresh."
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
                groupsEvents.toggle()
                return .handled
            } else if press.characters == "u" {
                applyPendingUpdates(proxy: proxy)
                return .handled
            } else if press.characters == "o" {
                if let id = focusedArticleID, let art = filteredArticles.first(where: { $0.id == id }),
                    let url = WebLink.url(art.link)
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
        withAnimation(reduceMotion ? nil : AppMotion.hover) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    private func openFocusedArticle() {
        let listed = entries
        guard let entry = listed.first(where: { $0.id == focusedArticleID }) ?? listed.first else { return }
        switch entry {
        case .article(let article): openArticle(article)
        case .event(let summary, let representative, _):
            openEvent(summary.eventID, article: representative, initialExperienceMode: .eventOverview)
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

    private func openArticle(
        _ article: FeedArticle,
        context: [FeedArticle]? = nil,
        initialExperienceMode: ReaderExperienceMode? = nil
    ) {
        let context = context ?? filteredArticles
        focusedArticleID = article.id
        readManager.markAsRead(article.id)
        articlePath.append(
            FeedArticleWrap(
                article: article,
                contextArticles: context,
                initialExperienceMode: initialExperienceMode
            )
        )
    }

    /// Opening a publication from an event records the event version as seen; it marks only the
    /// opened article read.
    private func openEvent(
        _ eventID: String,
        article: FeedArticle,
        context: [FeedArticle]? = nil,
        initialExperienceMode: ReaderExperienceMode? = nil
    ) {
        Task { await articleStore.markEventSeen(eventID) }
        openArticle(article, context: context, initialExperienceMode: initialExperienceMode)
    }

    private func separate(_ article: FeedArticle, from eventID: String) {
        correctEvent { await articleStore.separateArticle(article.id, fromEvent: eventID) }
    }

    private func combine(_ related: RelatedStoryEvent, into eventID: String) {
        correctEvent { await articleStore.includeEvent(related.eventID, inEvent: eventID) }
    }

    /// A reader's correction shows at once; the next clustering pass applies it to the rest of the feed.
    private func correctEvent(_ change: @escaping () async -> Bool) {
        Task {
            appliesNextUpdate = true
            if await change() {
                feedManager.clusterEventsInBackground()
            } else {
                appliesNextUpdate = false
            }
        }
    }

    /// The reader asked for these stories, so they are shown when the refresh ends instead of waiting behind
    /// the update button.
    private func showPendingUpdates() {
        guard buffer.pending != nil else { return }
        withAnimation(reduceMotion ? nil : AppMotion.state) {
            buffer.applyPending()
        }
        cursor = buffer.displayed.articles.last.map(ArticleQueryCursor.init)
        hasMoreResults = pendingHasMore
    }

    /// Refresh means "show me what's new": queued updates appear at once, and results arriving during the refresh
    /// (collection, event grouping, rating) replace the list instead of waiting behind the updates button.
    private func refreshFeeds(subscription: Bool = false) {
        Task {
            if articlePath.isEmpty { showPendingUpdates() }
            isReaderRefreshing = true
            defer { isReaderRefreshing = false }
            await feedManager.fetchFeedsAsync()
            // An open article keeps the list still; its updates wait as usual, a subscription's until it closes.
            guard articlePath.isEmpty else {
                if subscription { buffer.holdsSubscription = true }
                return
            }
            appliesNextUpdate = true
            refreshReloads += 1
        }
    }
}

/// Memoizes `FeedSnapshot.entries(_:)`. An unchanged snapshot compares in constant time, since its arrays share
/// storage with the cached one; regrouping a 200-story page on every read showed in scrolling (#778).
@MainActor
private final class GroupedEntries {
    private var snapshot: FeedSnapshot?
    private var mode: FeedGroupingMode?
    private var cached: [FeedEntry] = []

    func entries(of snapshot: FeedSnapshot, mode: FeedGroupingMode) -> [FeedEntry] {
        if snapshot != self.snapshot || mode != self.mode {
            cached = snapshot.entries(mode)
            self.snapshot = snapshot
            self.mode = mode
        }
        return cached
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
                ("Esc, ← or B", "Back to list"),
            ]
        ),
        (
            "Story",
            [
                ("M", "Mark as read or unread"),
                ("S", "Save or remove from Saved Stories"),
                ("O", "Open in browser"),
                ("E", "Show or hide event coverage"),
                ("W", "Next reading mode: Overview, Story, Web"),
                ("⇧⌘R", "Switch between Story and Web"),
                ("⇧⌘U", "Mark as read or unread (menu)"),
                ("⌘S", "Save or remove from Saved Stories (menu)"),
                ("⌘O", "Open in browser (menu)"),
                ("C", "Copy link"),
                ("⌘[ / ⌘]", "Web back and forward"),
                ("⌘+ / ⌘− / ⌘0", "Bigger text, smaller text, actual size"),
            ]
        ),
        (
            "List",
            [
                ("G", "Group stories by event"),
                ("U", "Show new stories that arrived in the background"),
                ("R or ⌘R", "Check feeds for new stories"),
                ("⌥⌘U", "Mark all loaded stories as read"),
                ("⌘J / ⌘K", "Next and previous story (menu)"),
                ("⌘1 – ⌘4", "Today, Unread, Saved Stories, History"),
                ("⌘F", "Search the archive"),
                ("⇧⌘T", "World Tension"),
            ]
        ),
        (
            "Subscriptions",
            [
                ("⇧⌘I", "Import subscriptions (OPML)"),
                ("⇧⌘E", "Export subscriptions (OPML)"),
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
