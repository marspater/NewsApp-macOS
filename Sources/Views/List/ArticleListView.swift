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

// ArticleListView.swift
// NewsApp Article Grid List View & Navigation Coordinator

import AppKit
import SwiftUI

/// A focused scene value is compared on every view update. Without `Equatable`, SwiftUI compares the closures'
/// heap contexts, which differ on every render; the App then re-renders the window, the list sets the value
/// again, and the main thread spins at a full core for as long as the window is key. Equality therefore reads
/// what the commands read: which actions exist, never the closures themselves.
struct ListCommandActions: Equatable {
    let canGroupStories: Bool
    /// The list in front, whose own layout View › as List and as Grid change.
    var layoutSection = "Today"
    let newBriefing: (() -> Void)?
    /// Leaves the Briefing for the destination shown before it (Navigate › Back).
    var back: (() -> Void)? = nil
    /// Where `back` leads; part of equality, so a new destination reaches the menu's copy of the action.
    var backDestination: String? = nil
    /// Presents the Customize Briefing sheet (View › Customize Briefing…).
    var customizeBriefing: (() -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canGroupStories == rhs.canGroupStories && lhs.layoutSection == rhs.layoutSection
            && (lhs.newBriefing == nil) == (rhs.newBriefing == nil)
            && (lhs.back == nil) == (rhs.back == nil) && lhs.backDestination == rhs.backDestination
            && (lhs.customizeBriefing == nil) == (rhs.customizeBriefing == nil)
    }
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
        return entries.first { $0.cardImageURL != nil }?.id
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
    @EnvironmentObject private var searchState: ArticleSearchState

    /// The single layout preference of earlier versions: the layout of a list the reader has not chosen one for.
    @AppStorage("articleGridLayout") private var defaultGridLayout = false
    @AppStorage(ListLayoutPreference.key) private var sectionLayouts = ""

    /// The list being shown, which keeps its own list or grid choice.
    private var layoutSection: String { selectedTopic ?? "Today" }

    private var gridLayout: Bool {
        ListLayoutPreference.isGrid(layoutSection, stored: sectionLayouts, fallback: defaultGridLayout)
    }

    private var gridLayoutChoice: Binding<Bool> {
        Binding(
            get: { gridLayout },
            set: { sectionLayouts = ListLayoutPreference.setting($0, for: layoutSection, in: sectionLayouts) })
    }
    @AppStorage("groupsEventCoverage") private var groupsEvents = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @FocusState private var listHasFocus: Bool
    @State private var focusedArticleID: String? = nil

    @State private var briefing: FiniteBriefing?
    /// Every Briefing module's data, read from the library once per edition.
    @State private var briefingData = BriefingBoardData()
    @State private var showsCustomizeBriefing = false
    /// The window's World Tension model, snapshotted into the Briefing modules' load context.
    @Environment(WorldTensionModel.self) private var tensionModel: WorldTensionModel?
    @AppStorage("briefingEditionHour") private var briefingEditionHour = FiniteBriefing.defaultEditionHour
    /// The stored edition, shared by every window: when it was selected and its story IDs in order.
    @AppStorage("briefingEditionSelectedAt") private var briefingEditionSelectedAt = 0.0
    @AppStorage("briefingEditionArticleIDs") private var briefingEditionArticleIDs = ""
    @AppStorage("readingInterestsResetAt") private var readingInterestsResetAt = 0.0
    @Environment(\.readerImageLoader) private var imageLoader
    /// Launch shows the cached snapshot once, in one transition (DESIGN.md 13, #602); later windows start settled.
    @MainActor static var hasSettledLaunch = false
    @State private var isSettled = ArticleListView.hasSettledLaunch

    private var initialPrefetchURLs: [URL] {
        if isTodayEdition, let todayEdition { return todayEdition.initialImageURLs }
        return CardImagePrefetch.initialURLs(entries)
    }

    /// Whether the first card with an image is the full-size lead story (macOS 26). Only Today shows it at full
    /// size: the Briefing picks its hero by publisher count, and the hero decodes its own image on demand.
    private var showsLeadImage: Bool {
        guard #available(macOS 26, *), !isBriefing else { return false }
        // The Lead's first slide is the first image the edition asks for.
        if isTodayEdition {
            return todayEdition.flatMap { edition in edition.lead.first.flatMap(edition.imageURL) } != nil
        }
        return LeadStoryPresentation.firstEligibleID(
            in: entries, selectedTopic: selectedTopic, isSearching: isSearching) != nil
    }

    private func prefetchAhead(of id: String) {
        groupedEntries.prefetchAhead(of: id, using: imageLoader)
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
    /// The reader has scrolled this list since it was loaded.
    @State private var hasScrolledList = false
    @State private var newDay = FeedUpdateBuffer.NewDayHandoff()
    /// The last launch's edition was tried for this list; it is tried once.
    @State private var hasTriedStoredEdition = false
    /// A fresh edition differs from the restored one on a page in use: the updates button offers it.
    @State private var todayAwaitsFreshEdition = false
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

    /// Today outside a search is the edition: The Lead, lanes and The Latest (docs/design/today.md).
    /// It needs stories grouped by event: with grouping off (G), Today lists every report on its own as before.
    private var isTodayEdition: Bool { groupsEvents && !isSearching && (selectedTopic ?? "Today") == "Today" }

    /// Muting applies to the feed lists and search; Saved Stories and History list everything the reader kept or opened.
    private var listMuting: MuteRules {
        isSearching || (selectedTopic != "Saved Stories" && selectedTopic != "History")
            ? appSettings.muteRules : MuteRules()
    }

    private var queryIdentity: String {
        let muting = listMuting
        let binderHash = currentSmartBinder?.hashValue ?? 0
        return
            "\(selectedTopic ?? "Today"):\(binderHash):\(searchText):\(themeManager.autoHideRead):\(muting.sourceParameter)|\(muting.topicParameter):\(showsMuted)"
    }

    var filteredArticles: [FeedArticle] { buffer.displayed.articles }

    /// Saved Stories and History list exactly what the reader kept or opened. Briefing is always one card per event,
    /// whatever the list preference says: its modules are built on events.
    private var groupingMode: FeedGroupingMode {
        if isBriefing { return .events }
        return groupsEvents && selectedTopic != "Saved Stories" && selectedTopic != "History"
            ? .events : .publications
    }

    /// The shown page grouped once per change of page or grouping; the body reads it several times (#778).
    @State private var groupedEntries = GroupedEntries()

    /// The Today page as laid out for the listed stories; nil until its first assignment has run.
    @State private var todayEdition: TodayEdition?
    /// Counts the updates the reader applied. An edition built for an older count is laid out afresh; within one
    /// count its stories stay in their lanes.
    @State private var todayGeneration = 0
    /// Each lane's last focused card, for the session.
    @State private var todayLaneMemory: [TodayLane: String] = [:]
    /// What the page's layout reports back and only key handling reads: kept in a reference so that a report does
    /// not evaluate the whole list again right after it is drawn (#937).
    @State private var todayLayout = TodayLayoutReport()
    /// The detail column's size, which sizes The Lead.
    @State private var columnSize = CGSize(
        width: AppLayout.mainWindowMinimumWidth, height: AppLayout.mainWindowMinimumHeight)
    @State private var todayPrefetch = TodayLanePrefetch()

    private var todayFocusMap: TodayFocusMap? {
        isTodayEdition ? todayEdition?.focusMap(latestColumns: gridLayout ? todayLayout.latestColumns : 1) : nil
    }

    private var entries: [FeedEntry] { groupedEntries.entries(of: buffer.displayed, mode: groupingMode) }

    /// Once stories are on screen they stay put: background collection, grouping and rating queue behind the
    /// updates button instead of reshuffling the list. A refresh the reader started is the exception while the list
    /// is showing: they asked for the new stories. So is Today showing only earlier days' stories, such as the cache
    /// at launch the next morning.
    private var isHoldingList: Bool {
        guard !appliesNextUpdate else { return false }
        if !articlePath.isEmpty { return true }
        // The new day's stories take the page once they are grouped, and only while the reader has not scrolled or
        // focused a card: before that the page would be one report a story, and after it the stories wait behind
        // the updates button like any other (#937).
        if !isSearching, (selectedTopic ?? "Today") == "Today",
            let holds = newDay.holds(
                showsOnlyEarlierDays: buffer.showsOnlyEarlierDays(), isGrouping: feedManager.isGroupingNewStories,
                isTouched: hasScrolledList || focusedArticleID != nil)
        {
            return holds
        }
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
        // The first query waits for the library to open (#937); until then the list is loading, not empty.
        if isLoadingPage || (!articleStore.isReady && !articleStore.startupFailed) {
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

    private var knowledgeExportActions: KnowledgeExportActions? {
        guard articlePath.isEmpty, isBriefing, let briefing, !briefing.articles.isEmpty else { return nil }
        return KnowledgeExportUI.actions(
            articles: briefing.articles,
            title: "Briefing · " + briefing.startedAt.formatted(date: .abbreviated, time: .omitted),
            store: articleStore, digest: true)
    }

    private var listCommandActions: ListCommandActions? {
        guard articlePath.isEmpty else { return nil }
        let backAction: (() -> Void)? = {
            if searchState.returnStory != nil {
                return { searchState.returnToStory(path: &articlePath) }
            } else if isBriefing {
                return { leaveBriefing() }
            } else {
                return nil
            }
        }()
        let backDest: String? = {
            if let returnStory = searchState.returnStory {
                return returnStory.article.title
            } else if isBriefing {
                return previousTopic
            } else {
                return nil
            }
        }()
        return ListCommandActions(
            canGroupStories: !isBriefing, layoutSection: layoutSection,
            newBriefing: isBriefing ? { startNewBriefing() } : nil,
            back: backAction, backDestination: backDest,
            customizeBriefing: isBriefing ? { showsCustomizeBriefing = true } : nil)
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
        .focusedSceneValue(\.knowledgeExport, knowledgeExportActions)
        .sheet(isPresented: $showsCustomizeBriefing) {
            BriefingCustomizeSheet().environmentObject(appSettings)
        }
        .navigationTitle(locationTitle)
        // The masthead shows the location, so the toolbar does not repeat it (DESIGN.md 5).
        .toolbar(removing: .title)
        .task(id: initialPrefetchURLs) {
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            await CardImagePrefetch.first(initialPrefetchURLs, leadAtFullSize: showsLeadImage, using: imageLoader)
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
        // The Today edition is assigned off the main actor; the one launch transition waits for it, at most a
        // second, so its cards arrive with the page instead of after it.
        if isTodayEdition, !entries.isEmpty {
            for _ in 0..<50 where todayEdition == nil {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        let urls = entries.prefix(12).compactMap(\.cardImageURL)
        let leadAtFullSize = showsLeadImage
        let loader = imageLoader
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await CardImagePrefetch.first(urls, leadAtFullSize: leadAtFullSize, using: loader) }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        guard !Task.isCancelled, !Self.hasSettledLaunch else { return }
        Self.hasSettledLaunch = true
        withAnimation(reduceMotion ? nil : AppMotion.navigation) { isSettled = true }
        // The launch refresh is automatic: a read-only library skips it rather than alerting on every launch.
        feedManager.fetchFeeds(scheduled: true)
        feedManager.clusterEventsInBackground()
    }

    @ViewBuilder
    private func scrollView(proxy: ScrollViewProxy) -> some View {
        attachNavigationCommands(
            to: ScrollView {
                masthead.id(Self.mastheadScrollID)
                listContent(proxy: proxy)
            }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                columnSize = $0
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, !hasScrolledList { hasScrolledList = true }
            }
            // The Today edition's rows pass under the floating sidebar, so the page must not cut them at the
            // column's edge.
            .scrollClipDisabled(isTodayEdition && Self.rowsPassUnderSidebar)
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
                // Opening a story, from any path, closes the preview.
                if !isClosed { StoryQuickLookCoordinator.shared.close() }
                guard isClosed, buffer.holdsSubscription else { return }
                showPendingUpdates()
                buffer.holdsSubscription = false
                appliesNextUpdate = true
                refreshReloads += 1
            }
            // A new section, search or filter can replace the previewed story, and Return would open another.
            .onChange(of: queryIdentity) { _, _ in
                StoryQuickLookCoordinator.shared.close()
            }
            // Grouping changes the entries too: the previewed report may no longer be one, and Return would open another.
            .onChange(of: groupsEvents) { _, _ in
                StoryQuickLookCoordinator.shared.close()
            }
            .onDisappear {
                StoryQuickLookCoordinator.shared.close()
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
            .onReceive(NotificationCenter.default.publisher(for: .quickLookCommand)) { _ in
                if articlePath.isEmpty { toggleQuickLook() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFocusedStoryCommand)) { _ in
                if articlePath.isEmpty { openFocusedArticle() }
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
        // While the library opens, a query would wait behind the store's first snapshot and then be cancelled by
        // the revision that snapshot publishes, twice over at launch (#937). The list waits for it and loads once.
        if !articleStore.isReady {
            await articleStore.waitForStartup()
            guard !Task.isCancelled else { return }
        }
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
                        options: ArticleFetchOptions(
                            publicationWindow: now.addingTimeInterval(-FiniteBriefing.duration)...now,
                            muting: appSettings.muteRules))
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
                // The edition's stories are frozen, but a photo the page lookup recorded after the selection belongs
                // on its card: without this a story from a feed without images stays bare for the whole edition (#1201).
                let frozen = briefing?.articles ?? []
                let photos =
                    (try? await articleStore.database.storyImages(
                        for: frozen.filter { $0.imageUrl == nil }.map(\.id))) ?? [:]
                let briefingArticles = frozen.map { story in
                    var story = story
                    if story.imageUrl == nil { story.imageUrl = photos[story.id] }
                    return story
                }
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
            groupedEntries.resetPrefetch()
            todayPrefetch.reset()
            todayEdition = nil
            todayAwaitsFreshEdition = false
            hasScrolledList = false
            newDay.reset()
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
            // One vector for the page and its counts: another window's search must not change what they count (#985).
            let queryVector =
                isSearching ? try await articleStore.database.searchQueryVector(for: searchText) : nil
            let fetched = try await fetchPage(
                after: isPaging ? cursor : nil, muting: showsMuted ? MuteRules() : muting, queryVector: queryVector)
            try Task.checkCancellation()
            NewsSignposts.launchMilestone("list_page_fetched")
            // Today's lanes need every listed story's language score; it is worked out while the counts and the
            // grouping below are read, not after them (#937).
            if isTodayEdition { NotificationService.shared.prepareImportance(of: Array(fetched.prefix(200))) }
            if !isPaging {
                var hidden = 0
                if !muting.isEmpty { hidden = try await countMuted(muting, queryVector: queryVector) }
                let totals = try await countListed(showsMuted ? MuteRules() : muting, queryVector: queryVector)
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
                newDay.noteRefreshedPage(
                    showsOnlyEarlierDays: buffer.showsOnlyEarlierDays(), isGrouping: feedManager.isGroupingNewStories)
                let holding = isHoldingList
                appliesNextUpdate = false
                let result = buffer.receive(snapshot, holding: holding, mode: groupingMode, hasMore: morePages)
                switch result {
                case .replaced:
                    newDay.reset()
                    // The list was replaced, not held: Today lays its edition out afresh for it.
                    todayGeneration += 1
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

    private var currentSmartBinder: SmartBinder? {
        guard let topic = selectedTopic else { return nil }
        return appSettings.smartBinder(forTag: topic)
    }

    private func fetchPage(after pageCursor: ArticleQueryCursor?, muting: MuteRules, queryVector: [Float]?) async throws
        -> [FeedArticle]
    {
        if isSearching {
            return try await articleStore.database.searchArticles(
                query: searchText, limit: 201, after: pageCursor, muting: muting, queryEmbedding: queryVector,
                vectorResolved: true)
        }
        let filters = listFilters
        if let binder = currentSmartBinder {
            return try await articleStore.database.fetchArticles(
                smartBinder: binder, isRead: filters.read, isSaved: filters.saved,
                limit: 201, options: ArticleFetchOptions(after: pageCursor, muting: muting))
        }
        return try await articleStore.database.fetchArticles(
            section: filters.topic, isRead: filters.read, isSaved: filters.saved,
            limit: 201, options: ArticleFetchOptions(after: pageCursor, muting: muting))
    }

    private func countMuted(_ muting: MuteRules, queryVector: [Float]?) async throws -> Int {
        if isSearching {
            return try await articleStore.database.mutedArticleCount(
                search: searchText, searchVector: queryVector, muting: muting)
        }
        let filters = listFilters
        if let binder = currentSmartBinder {
            return try await articleStore.database.mutedArticleCount(
                smartBinder: binder, isRead: filters.read, isSaved: filters.saved, muting: muting)
        }
        return try await articleStore.database.mutedArticleCount(
            section: filters.topic, isRead: filters.read, isSaved: filters.saved, muting: muting)
    }

    /// The masthead's totals: every story of the list, across all its pages, and the events grouping them (#782).
    private func countListed(_ muting: MuteRules, queryVector: [Float]?) async throws -> (stories: Int, events: Int) {
        if isSearching {
            return try await articleStore.database.listTotals(
                search: searchText, searchVector: queryVector, muting: muting)
        }
        let filters = listFilters
        if let binder = currentSmartBinder {
            return try await articleStore.database.listTotals(
                smartBinder: binder, isRead: filters.read, isSaved: filters.saved, muting: muting)
        }
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
        // A fresh edition waiting behind a restored one is an update too: the edition is laid out afresh.
        if buffer.pending == nil, todayAwaitsFreshEdition { todayGeneration += 1 }
        guard buffer.pending != nil || todayAwaitsFreshEdition else { return }
        todayAwaitsFreshEdition = false
        showPendingUpdates()
        if isTodayEdition {
            // The page returns to the masthead and each row to its leading edge; a card that keeps keyboard focus
            // is scrolled back into view once the new edition is installed (`reloadTodayEdition`).
            withAnimation(reduceMotion ? nil : AppMotion.hover) {
                proxy.scrollTo(Self.mastheadScrollID, anchor: .top)
            }
        } else if let first = entries.first {
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
        if isSearching { return "Search" }
        if let binder = currentSmartBinder { return binder.name }
        return selectedTopic ?? "Today"
    }

    static func headerMaxWidth(isBriefing: Bool, gridLayout: Bool) -> CGFloat? {
        if isBriefing {
            return AppLayout.briefingMaxWidth
        }
        return gridLayout ? .infinity : AppLayout.listMaxWidth
    }

    private var headerMaxWidth: CGFloat? {
        // The Today edition is full-bleed in both layouts, so its masthead starts at the page inset.
        isTodayEdition ? .infinity : Self.headerMaxWidth(isBriefing: isBriefing, gridLayout: gridLayout)
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
        .frame(
            maxWidth: headerMaxWidth,
            alignment: .leading
        )
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
        if let returnStory = searchState.returnStory {
            let storyTitle = returnStory.article.title
            ToolbarItem(placement: .navigation) {
                Button {
                    searchState.returnToStory(path: &articlePath)
                } label: {
                    Label("Back to Story", systemImage: "chevron.left")
                }
                .help("Back to \(storyTitle) (Esc)")
                .accessibilityLabel("Back to \(storyTitle)")
            }
        } else if isBriefing {
            ToolbarItem(placement: .navigation) {
                Button(action: leaveBriefing) {
                    Label("Back to \(previousTopic)", systemImage: "chevron.left")
                }
                .help("Back to \(previousTopic)")
            }
        }
        if articlePath.isEmpty, buffer.pending != nil || (isTodayEdition && todayAwaitsFreshEdition) {
            ToolbarItem(placement: .navigation) { updatesButton(proxy: proxy) }
        }
        // With the duplicate title removed nothing fills the toolbar, so macOS 26 and later would lay the list
        // controls out from the leading edge. A flexible spacer keeps them, and search, at the trailing edge.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !isBriefing {
                Toggle(isOn: $groupsEvents.animation(reduceMotion ? nil : AppMotion.state)) {
                    Label(
                        "Group Stories by Event",
                        systemImage: groupsEvents ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                }
                .toggleStyle(.button)
                .help(groupingHelp)
            }

            Picker("Story Layout", selection: gridLayoutChoice) {
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
            if let actions = knowledgeExportActions {
                ToolbarItem(placement: .primaryAction) { KnowledgeExportMenu(actions: actions) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCustomizeBriefing = true
                } label: {
                    Label("Customize Briefing", systemImage: "slider.horizontal.3")
                }
                .help("Choose and order the Briefing's modules")
            }
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
    private func articleGrid(proxy: ScrollViewProxy) -> some View {
        let listed = entries
        if isTodayEdition {
            todayPage(listed, proxy: proxy)
        } else if isBriefing {
            briefingPage(listed)
        } else {
            cardPage(listed)
        }
    }

    @ViewBuilder
    private func briefingPage(_ listed: [FeedEntry]) -> some View {
        BriefingView(
            entries: listed,
            briefing: briefing,
            data: briefingData,
            layout: appSettings.briefingLayout,
            readIDs: readManager.readArticles,
            savedIDs: briefingSavedIDs(listed),
            focusedID: listHasFocus ? focusedArticleID : nil,
            isMotionPaused: !articlePath.isEmpty || isSheetPresented || showsCustomizeBriefing,
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
            ),
            isWorldTensionEnabled: appSettings.isWorldTensionEnabled
        )
        // Every module's data from the library; nothing is generated at render time. Reloads when the stories,
        // their event membership or a stored overview change.
        .task(
            id: "\(listed.map(\.id)):\(groupsEvents):\(articleStore.eventRevision):\(articleStore.overviewRevision)"
        ) {
            let ranking = await BriefingRanking.load(entries: listed, database: articleStore.database)
            let context = BriefingLoadContext(
                entries: listed, heroIDs: Set(BriefingView.heroEntries(listed, ranking: ranking).map(\.id)),
                briefing: briefing, now: Date(), tension: tensionModel?.state ?? WorldTensionState(),
                readIDs: readManager.readArticles, previousEditionStartedAt: nil, ranking: ranking)
            let loaded = await BriefingBoardData.load(context, store: articleStore)
            if !Task.isCancelled { briefingData = loaded }
        }
        .allowsWindowActivationEvents(true)
    }

    @ViewBuilder
    private func cardPage(_ listed: [FeedEntry]) -> some View {
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

    /// The stories of one grid column: every `count`th story, starting at `column`.
    static func column(_ column: Int, of count: Int, in entries: [FeedEntry]) -> [FeedEntry] {
        guard count > 1 else { return entries }
        return stride(from: column, to: entries.count, by: count).map { entries[$0] }
    }

    /// What the grouping toggle does here. In Today it also switches between the edition and the plain list.
    private var groupingHelp: String {
        let isToday = !isSearching && (selectedTopic ?? "Today") == "Today"
        switch (groupsEvents, isToday) {
        case (true, true):
            return "Showing the Today edition: The Lead, lanes and one card per event. "
                + "Show every story on its own, without lanes (G)"
        case (false, true):
            return "Showing every story on its own. Group stories by event and show the Today edition (G)"
        case (true, false): return "Showing one card per event. Show every story on its own (G)"
        case (false, false): return "Showing every story on its own. Group stories of the same event (G)"
        }
    }

    /// macOS 26 and later float the sidebar over the content.
    static var rowsPassUnderSidebar: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static var mastheadScrollID: String { "list-masthead" }

    /// The Today edition of the listed stories. Its lanes are assigned off the main actor; until the first
    /// assignment is back the page below the masthead is empty, so no card ever changes lane in view.
    @ViewBuilder
    private func todayPage(_ listed: [FeedEntry], proxy: ScrollViewProxy) -> some View {
        // A stack rather than a group: the task below must run while the page is still empty.
        VStack(spacing: 0) {
            if let todayEdition {
                TodayEditionView(
                    edition: todayEdition,
                    focusedID: listHasFocus ? focusedArticleID : nil,
                    readIDs: readManager.readArticles,
                    columnSize: columnSize,
                    gridLayout: gridLayout,
                    isMotionPaused: !articlePath.isEmpty || isSheetPresented,
                    actions: TodayEditionActions(
                        open: { entry in open(entry) },
                        cardAppeared: { id in
                            NewsSignposts.firstCardAppeared(restored: todayEdition.isRestored)
                            todayPrefetch.cardAppeared(id, in: todayEdition, using: imageLoader)
                        },
                        latestColumnsChanged: { todayLayout.latestColumns = $0 },
                        laneMovedByReader: { todayLayout.hasMovedLane = true },
                        leadingCardChanged: { lane, id in todayLayout.laneLeading[lane] = id },
                        // The reader chose a slide: the page is in use. When a slide held keyboard focus,
                        // focus follows what shows.
                        leadSlideShown: { entry in
                            todayLayout.hasMovedLane = true
                            if todayEdition.lead.contains(where: { $0.id == focusedArticleID }) {
                                focusedArticleID = entry.id
                                todayLaneMemory[.theLead] = entry.id
                            }
                        }),
                    latestListCard: { entry in entryCard(entry) }
                )
            }
        }
        // Reloads when the listed stories, their event membership, a stored overview, the subscriptions or the applied
        // updates change.
        .task(
            id: "\(groupedEntries.revision):\(articleStore.eventRevision):\(articleStore.overviewRevision):"
                + "\(todayGeneration):\(queryIdentity):\(appSettings.feedURLs.hashValue)"
        ) {
            await reloadTodayEdition(listed, proxy: proxy)
        }
        .allowsWindowActivationEvents(true)
    }

    /// Shows the edition kept at the last launch, when it still describes these stories. False when the task was
    /// cancelled: the attempt is not counted, so the task that replaces it tries again.
    private func restoreStoredTodayEdition(_ listed: [FeedEntry], reader: TodayReader) async -> Bool {
        let result = await articleStore.restoredTodayEdition(
            entries: listed, reader: reader, generation: todayGeneration)
        guard !Task.isCancelled else { return false }
        hasTriedStoredEdition = true
        switch result {
        case .success(let restored):
            todayEdition = restored
            NewsSignposts.launchEvent("today_edition_restored", detail: "outcome=shown")
        case .failure(let rejection):
            NewsSignposts.launchEvent("today_edition_restored", detail: "outcome=\(rejection.rawValue)")
        case nil:
            NewsSignposts.launchEvent("today_edition_restored", detail: "outcome=none")
        }
        return true
    }

    /// Lays the listed stories out as the Today edition and moves keyboard focus with it.
    private func reloadTodayEdition(_ listed: [FeedEntry], proxy: ScrollViewProxy) async {
        let resetAt = readingInterestsResetAt > 0 ? Date(timeIntervalSince1970: readingInterestsResetAt) : nil
        let reader = TodayReader(
            failedImageURLs: DecodedImageCache.failedURLs, subscribedFeedURLs: Set(appSettings.feedURLs),
            starredFeedURLs: appSettings.starredFeedURLs, interestsResetAt: resetAt)
        // The first page of a launch is laid out at once from the edition kept at the last one, when it still
        // describes these stories; the fresh edition is worked out behind it (#937).
        if todayEdition == nil, !hasTriedStoredEdition, !listed.isEmpty {
            guard await restoreStoredTodayEdition(listed, reader: reader) else { return }
        }
        let previous = todayEdition
        let showsRestored = previous?.isRestored == true
        // Bursts of store revisions (clustering, overviews) would lay the page out once each; they are debounced
        // as in the list. The first edition loads at once, and so does the fresh one behind a restored edition.
        if previous != nil, !showsRestored {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
        // Stories stay in their lanes while the list is held; an applied update, a refresh the reader asked
        // for or another day's stories lay the edition out afresh. A restored edition is never the one kept.
        // While another day's page waits for its grouping, the edition on screen is not laid out again from the
        // earlier day's stories: the next edition is the new day's.
        let keeps =
            !showsRestored && (isHoldingList || newDay.isWaiting) && previous?.generation == todayGeneration
        NewsSignposts.launchMilestone("today_edition_requested")
        var edition = await articleStore.todayEdition(
            entries: listed, reader: reader, keeping: keeps ? previous : nil, generation: todayGeneration)
        guard !Task.isCancelled else { return }
        // A complete edition is kept for the next launch, unless its stories are still being grouped.
        if edition.isAssigned, !feedManager.holdsUngroupedStories {
            Task { await articleStore.storeTodayEdition(edition, reader: reader) }
        }
        if showsRestored, let previous, !settleFreshEdition(&edition, behind: previous) { return }
        await installTodayEdition(edition, replacing: previous, keeps: keeps, proxy: proxy)
    }

    /// Puts a laid-out edition on the page and moves keyboard focus with it.
    private func installTodayEdition(
        _ edition: TodayEdition, replacing previous: TodayEdition?, keeps: Bool, proxy: ScrollViewProxy
    ) async {
        // An edition laid out afresh is the one that was waiting, if any was.
        if !keeps { todayAwaitsFreshEdition = false }
        // A rebuilt edition has other cards at the same positions, so the lanes' image prefetch starts over.
        if !keeps { todayPrefetch.reset() }
        let isApplied = previous.map { $0.generation != edition.generation } ?? false
        let restored = restoreTodayFocus(in: edition, from: previous)
        todayEdition = edition
        NewsSignposts.launchMilestone("today_edition_installed")
        // Photos the top of the page still lacks are looked up first.
        feedManager.requestStoryImages(for: edition.imagelessShownIDs)
        // An applied update returns the page to the masthead; a card that kept focus is brought back into view.
        if isApplied, let restored {
            await Task.yield()
            let lane = edition.focusMap(latestColumns: todayLayout.latestColumns).lane(of: restored)
            withAnimation(reduceMotion ? nil : AppMotion.hover) {
                proxy.scrollTo(lane == .theLead ? TodayEditionView<EmptyView>.leadScrollID : restored)
            }
        }
    }

    /// The fresh edition is ready behind the restored one on screen. False when the page in use keeps its cards as
    /// an ordinary held edition and the fresh one is offered behind the updates button.
    private func settleFreshEdition(_ edition: inout TodayEdition, behind previous: TodayEdition) -> Bool {
        let awaitsNewDay = buffer.showsOnlyEarlierDays() && feedManager.isGroupingNewStories
        let outcome = TodayRestoreOutcome.decide(
            sameArrangement: edition.hasSameArrangement(as: previous),
            isTouched: hasScrolledList || focusedArticleID != nil || !articlePath.isEmpty
                || todayLayout.hasMovedLane || NSWorkspace.shared.isVoiceOverEnabled,
            awaitsNewDay: awaitsNewDay)
        NewsSignposts.launchEvent(
            "today_fresh_edition_ready",
            detail: "outcome=\(outcome.rawValue) scrolled=\(hasScrolledList) focused=\(focusedArticleID != nil) "
                + "reading=\(!articlePath.isEmpty) lane_moved=\(todayLayout.hasMovedLane) "
                + "voiceover=\(NSWorkspace.shared.isVoiceOverEnabled) new_day=\(awaitsNewDay)")
        switch outcome {
        case .held:
            var kept = previous
            kept.isRestored = false
            todayEdition = kept
            todayAwaitsFreshEdition = true
            return false
        case .confirmed:
            edition.generation = previous.generation
        case .swapped:
            break
        }
        return true
    }

    /// Focus follows its card, or the rules of today.md when the card or its lane is gone. The card that takes
    /// focus is also its lane's remembered card. Returns the focused card when the list has focus.
    private func restoreTodayFocus(in edition: TodayEdition, from previous: TodayEdition?) -> String? {
        guard let previous, let focused = focusedArticleID else { return nil }
        let map = edition.focusMap(latestColumns: todayLayout.latestColumns)
        let restored = map.restoredFocus(focused, from: previous.focusMap(latestColumns: todayLayout.latestColumns))
        focusedArticleID = restored
        guard let restored else { return nil }
        if let lane = map.lane(of: restored) { todayLaneMemory[lane] = restored }
        return listHasFocus ? restored : nil
    }

    private func open(_ entry: FeedEntry) {
        switch entry {
        case .article(let article): openArticle(article)
        case .event(let summary, let representative, _):
            openEvent(summary.eventID, article: representative, initialExperienceMode: .eventOverview)
        }
    }

    @ViewBuilder
    private func cardCollection(_ listed: [FeedEntry]) -> some View {
        if gridLayout {
            // Independent columns, not grid rows: showing an event's sources grows its own column and leaves the
            // cards beside it where they are (Mars, 11 November 2026). Stories still read across: story n sits in
            // column n mod the column count.
            let count = AppLayout.gridColumnCount(width: columnSize.width - AppLayout.pageInset * 2)
            HStack(alignment: .top, spacing: AppLayout.cardGap) {
                ForEach(0..<count, id: \.self) { column in
                    LazyVStack(spacing: AppLayout.cardGap) {
                        ForEach(Self.column(column, of: count, in: listed)) { entry in entryCard(entry) }
                    }
                    .frame(maxWidth: AppLayout.gridColumnMaximum, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity)
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
            .equatable()
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
                isExpanded: expandedEvents.contains(summary.eventID),
                setExpanded: { expanded in setExpanded(summary.eventID, expanded) },
                openRepresentative: {
                    openEvent(summary.eventID, article: representative, initialExperienceMode: .eventOverview)
                },
                openMember: { member, members in
                    openEvent(
                        summary.eventID, article: member, context: members,
                        initialExperienceMode: .sourcePublication)
                },
                separate: { member in separate(member, from: summary.eventID) },
                combine: { related in combine(related, into: summary.eventID) },
                store: articleStore
            )
            .equatable()
            .id(entry.id)
            .onAppear {
                NewsSignposts.firstCardAppeared()
                prefetchAhead(of: representative.id)
            }
        }
    }

    private func setExpanded(_ eventID: String, _ isExpanded: Bool) {
        if isExpanded { expandedEvents.insert(eventID) } else { expandedEvents.remove(eventID) }
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
        if let binder = currentSmartBinder { return binder.icon.isEmpty ? "folder" : binder.icon }
        switch selectedTopic {
        case "Briefing": return "text.book.closed"
        case "Today", "Unread": return "newspaper"
        case "Saved Stories": return "bookmark"
        case "History": return "clock"
        default: return "tray"
        }
    }

    private var emptyStateTitle: String {
        if let binder = currentSmartBinder { return "Nothing in \(binder.name)" }
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
        if let binder = currentSmartBinder {
            return "New stories matching “\(binder.name)” will appear here once your feeds refresh."
        }
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

        // An open preview takes Esc before Back or clearing the search.
        if press.key == .escape, StoryQuickLookCoordinator.shared.isOpen {
            StoryQuickLookCoordinator.shared.close()
            return .handled
        }
        if let map = todayFocusMap, searchState.returnStory == nil,
            let direction = Self.todayDirection(press.key)
        {
            focusToday(
                map.move(direction, from: focusedArticleID, memory: todayLaneMemory, visible: todayLayout.laneLeading),
                in: map, proxy: proxy)
            return .handled
        }
        if press.key == .escape || press.key == .leftArrow || press.characters == "b" || press.characters == "h" {
            if searchState.returnStory != nil {
                searchState.returnToStory(path: &articlePath)
                return .handled
            } else if isBriefing {
                leaveBriefing()
                return .handled
            } else if isSearching && press.key == .escape {
                searchState.clear()
                return .handled
            }
        }

        switch press.key {
        case .downArrow:
            navigateList(offset: 1, proxy: proxy)
            return .handled
        case .upArrow:
            navigateList(offset: -1, proxy: proxy)
            return .handled
        case .return:
            openFocusedArticle()
            return .handled
        case .space:
            toggleQuickLook()
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
            } else if press.characters == "g", !isBriefing {
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

    static func todayDirection(_ key: KeyEquivalent) -> TodayFocusMap.Direction? {
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        default: return nil
        }
    }

    /// Moves keyboard focus to a Today card, remembers it for its lane and scrolls the page only as far as showing
    /// it needs; the card's row scrolls itself.
    private func focusToday(_ id: String?, in map: TodayFocusMap, proxy: ScrollViewProxy) {
        guard let id else { return }
        focusedArticleID = id
        let lane = map.lane(of: id)
        if let lane { todayLaneMemory[lane] = id }
        withAnimation(reduceMotion ? nil : AppMotion.hover) {
            proxy.scrollTo(lane == .theLead ? TodayEditionView<EmptyView>.leadScrollID : id)
        }
        if StoryQuickLookCoordinator.shared.isOpen,
            let entry = entries.first(where: { $0.id == id })
        {
            StoryQuickLookCoordinator.shared.present(article: entry.representative, isDark: colorScheme == .dark)
        }
    }

    private func navigateList(offset: Int, proxy: ScrollViewProxy) {
        if let map = todayFocusMap {
            focusToday(map.step(offset, from: focusedArticleID), in: map, proxy: proxy)
            return
        }
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
        if StoryQuickLookCoordinator.shared.isOpen {
            StoryQuickLookCoordinator.shared.present(article: target.representative, isDark: colorScheme == .dark)
        }
    }

    /// The story Return and Space act on: the focused one, else the first the reader sees, which on the Today page
    /// is the ranked Lead and not the first listed story.
    private func keyboardEntry() -> FeedEntry? {
        let listed = entries
        if let focused = listed.first(where: { $0.id == focusedArticleID }) { return focused }
        if let first = todayFocusMap?.readingOrder.first { return listed.first { $0.id == first } }
        return listed.first
    }

    private func toggleQuickLook() {
        if StoryQuickLookCoordinator.shared.isOpen {
            StoryQuickLookCoordinator.shared.close()
        } else {
            guard let entry = keyboardEntry() else { return }
            focusedArticleID = entry.id
            StoryQuickLookCoordinator.shared.present(article: entry.representative, isDark: colorScheme == .dark)
        }
    }

    private func openFocusedArticle() {
        guard let entry = keyboardEntry() else { return }
        switch entry {
        case .article(let article): openArticle(article)
        case .event(let summary, let representative, _):
            openEvent(summary.eventID, article: representative, initialExperienceMode: .eventOverview)
        }
    }

    private func toggleFocusedEventSources() {
        // Only the list's own cards have coverage to expand: not a lane card, and not The Latest's Compact grid.
        if let map = todayFocusMap, gridLayout || map.lane(of: focusedArticleID) != .theLatest { return }
        guard let entry = entries.first(where: { $0.id == focusedArticleID }),
            case .event(let summary, _, _) = entry
        else { return }
        let expanded = !expandedEvents.contains(summary.eventID)
        withAnimation(reduceMotion ? nil : AppMotion.state) { setExpanded(summary.eventID, expanded) }
        if expanded {
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
        if initialExperienceMode?.marksOpenedStoryRead ?? true { readManager.markAsRead(article.id) }
        articlePath.append(
            FeedArticleWrap(
                article: article,
                contextArticles: context,
                initialExperienceMode: initialExperienceMode
            )
        )
    }

    /// Opening a publication from an event records the event version as seen; it marks only the
    /// opened article read, and opening the event overview marks nothing read.
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
        // The installed snapshot is no longer the earlier day the hold was waiting to replace.
        awaitsGroupedDay = false
        // The reader asked for the update: the Today edition is laid out afresh.
        todayGeneration += 1
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

/// Memoizes `FeedSnapshot.entries(_:)` and manages scroll-ahead image prefetching without invalidating `ArticleListView`
/// during scroll gestures (#778).
@MainActor
private final class GroupedEntries {
    private var snapshot: FeedSnapshot?
    private var mode: FeedGroupingMode?
    private var cached: [FeedEntry] = []
    /// Position of each entry in `cached`, by entry ID (the card's representative story).
    private var indexByID: [String: Int] = [:]
    private let imagePrefetch = CardImagePrefetch()
    /// Counts the times the grouped entries changed, for work keyed on them.
    private(set) var revision = 0

    func entries(of snapshot: FeedSnapshot, mode: FeedGroupingMode) -> [FeedEntry] {
        if snapshot != self.snapshot || mode != self.mode {
            revision += 1
            cached = snapshot.entries(mode)
            var map: [String: Int] = [:]
            map.reserveCapacity(cached.count)
            for (index, entry) in cached.enumerated() where map[entry.id] == nil {
                map[entry.id] = index
            }
            indexByID = map
            self.snapshot = snapshot
            self.mode = mode
        }
        return cached
    }

    func resetPrefetch() { imagePrefetch.reset() }

    func prefetchAhead(of id: String, using loader: @escaping @Sendable (URL, Int) async throws -> CGImage) {
        guard let index = indexByID[id] else { return }
        imagePrefetch.ahead(of: index, in: cached, using: loader)
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
                ("← → ↑ ↓", "In Today: move inside a lane and between lanes"),
                ("Space or ⌘Y", "Quick Look preview (⌘Y in the list)"),
                ("↵", "Open focused story"),
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
                ("⌥⌘R", "Check this story for new reports"),
                ("⇧⌘U", "Mark as read or unread (menu)"),
                ("⌘S", "Save or remove from Saved Stories (menu)"),
                ("⌘O", "Open in browser (menu)"),
                ("C", "Copy link"),
                ("⌘Y", "Highlight the selected passage (in the reader)"),
                ("⇧⌘Y", "Add a note to the selected passage"),
                ("⌥⌘I", "Show or hide highlights and notes"),
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
        .frame(width: AppLayout.keyboardShortcutsPopoverWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Latest's column count and the card at each lane row's leading edge, where an arrow key enters a lane the
/// reader has not focused. Not observed: nothing drawn depends on them.
@MainActor final class TodayLayoutReport {
    var latestColumns = 1
    var laneLeading: [TodayLane: String] = [:]
    /// The reader scrolled or paged a lane row sideways, or chose a Lead slide: the page is in use. A row's own
    /// layout reports are not that.
    var hasMovedLane = false
}

/// Decodes the next cards of a lane before they scroll into view (#591, #936): a card appearing asks for the
/// images of the cards after it in its own lane, each as its card shows it.
@MainActor final class TodayLanePrefetch {
    private var furthest: [TodayLane: Int] = [:]
    /// The newest task of each lane, which the next one waits for, and every task started, so a reset cancels the
    /// whole chain and not only its last link.
    private var tasks: [TodayLane: Task<Void, Never>] = [:]
    private var started: [Task<Void, Never>] = []

    func cardAppeared(
        _ id: String, in edition: TodayEdition, using loader: @escaping @Sendable (URL, Int) async throws -> CGImage
    ) {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        for lane in edition.lanes where lane.lane != .theLead {
            guard let index = lane.stories.firstIndex(where: { $0.id == id }) else { continue }
            let ahead = lane.lane == .theLatest ? 18 : 6
            let end = min(lane.stories.count, index + 1 + ahead)
            // Only once the card is past what an earlier card already asked for.
            guard end > (furthest[lane.lane] ?? 0) else { return }
            let start = max(index + 1, furthest[lane.lane] ?? 0)
            furthest[lane.lane] = end
            let urls = lane.stories[start..<end].compactMap { edition.imageURL(of: $0) }
            let previous = tasks[lane.lane]
            let task = Task {
                await previous?.value
                await DecodedImageCache.prefetch(urls, size: .card, using: loader)
            }
            tasks[lane.lane] = task
            started.append(task)
            return
        }
    }

    func reset() {
        furthest = [:]
        for task in started { task.cancel() }
        started = []
        tasks = [:]
    }
}
