// MainView.swift
// NewsApp Main Window Orchestrator & Split View Coordinator

import AppKit
import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Navigation Notifications & Commands

extension Notification.Name {
    // Section Jump Commands
    static let jumpToTodayCommand = Notification.Name("jumpToTodayCommand")
    static let jumpToUnreadCommand = Notification.Name("jumpToUnreadCommand")
    static let jumpToSavedCommand = Notification.Name("jumpToSavedCommand")
    static let jumpToHistoryCommand = Notification.Name("jumpToHistoryCommand")
    static let jumpToBriefingCommand = Notification.Name("jumpToBriefingCommand")
}

// MARK: - Main View

struct MainView: View {
    @State private var selectedTopic: String? = "Today"
    @State private var searchText: String = ""
    @State private var searchTokens: [ArchiveSearchToken] = []
    @State private var searchPresented = false
    @State private var mastheadNotice: MastheadNotice?
    @State private var articlePath = NavigationPath()
    @State private var pendingFeedConfirmationURL: URL?

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The tension series behind the sidebar reading; the sheet opens with it.
    @State private var tensionHistory: [WorldTensionReading] = []
    @State private var showsTension = false
    @State private var tensionStatus = "Not assessed"
    /// The UTC day the reading belongs to; it advances at midnight UTC so the sidebar moves to the new day's reading.
    @State private var tensionDayStart = TensionMethodology.day(containing: Date()).start
    @State private var isWindowDropTargeted = false

    /// The Dock icon carries the unread count while the setting is on; clearing it removes the badge.
    private func updateDockBadge(_ unread: Int) {
        NSApp.dockTile.badgeLabel = appSettings.showsDockBadge && unread > 0 ? String(unread) : nil
    }

    var body: some View {
        splitView
            .alert(
                "Operation failed",
                isPresented: operationErrorBinding
            ) {
                Button("OK") { articleStore.operationError = nil }
            } message: {
                Text(articleStore.operationError ?? "Please try again.")
            }
            .navigationSplitViewStyle(.balanced)
            // A sheet, so the rest of the window waits until the reader closes it.
            .sheet(isPresented: $showsTension, content: tensionSheetContent)
            .onChange(of: articleStore.unreadCount, initial: true) { _, count in updateDockBadge(count) }
            .onChange(of: appSettings.showsDockBadge) { _, _ in updateDockBadge(articleStore.unreadCount) }
            .onReceive(NotificationCenter.default.publisher(for: .showNewsTensionCommand)) { _ in
                handleNewsTensionCommand()
            }
            .task(id: tensionReloadKey) {
                await reloadTension()
            }
            .task(id: tensionDayStart) {
                await scheduleTensionDayRollover()
            }
            // One archive search in the trailing toolbar, shared by list and reader.
            .modifier(
                ArchiveSearchToolbar(
                    searchText: $searchText,
                    searchTokens: $searchTokens,
                    searchPresented: $searchPresented,
                    archiveQuery: archiveQuery,
                    presentSearch: presentSearch,
                    suggestions: searchOperatorSuggestions
                )
            )
            .frame(minWidth: 900, minHeight: 600)
            .onAppear(perform: handleAppear)
            .onDrop(of: [.fileURL], isTargeted: $isWindowDropTargeted) { providers in
                handleWindowOPMLDrop(providers: providers)
            }
            .onChange(of: mastheadNotice, handleMastheadNoticeAnnouncement)
            .task(id: mastheadNotice) {
                await handleMastheadNoticeTimeout()
            }
            .onChange(of: selectedTopic) { _, _ in
                articlePath = NavigationPath()
            }
            .onChange(of: searchText, handleSearchTextChange)
            .onChange(of: searchTokens, handleSearchTokensChange)
            // Notification Deep Link & Section Jump Routing
            .onReceive(NotificationCenter.default.publisher(for: .jumpToTodayCommand)) { _ in
                showSection("Today")
            }
            .onReceive(NotificationCenter.default.publisher(for: .jumpToUnreadCommand)) { _ in
                showSection("Unread")
            }
            .onReceive(NotificationCenter.default.publisher(for: .jumpToSavedCommand)) { _ in
                showSection("Saved Stories")
            }
            .onReceive(NotificationCenter.default.publisher(for: .jumpToHistoryCommand)) { _ in
                showSection("History")
            }
            .onReceive(NotificationCenter.default.publisher(for: .jumpToBriefingCommand)) { _ in
                showSection("Briefing")
            }
            .task(id: pendingNavigationToken) {
                await handlePendingNavigation()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                handleSpotlightContinuation(activity)
            }
            .alert(
                "Subscribe to Feed?",
                isPresented: Binding(
                    get: { pendingFeedConfirmationURL != nil },
                    set: { if !$0 { pendingFeedConfirmationURL = nil } }
                ),
                presenting: pendingFeedConfirmationURL
            ) { targetURL in
                Button("Subscribe") {
                    confirmAddFeed(targetURL)
                    pendingFeedConfirmationURL = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingFeedConfirmationURL = nil
                }
            } message: { targetURL in
                Text(
                    "Would you like to subscribe to stories from \(targetURL.host ?? "this feed")?\n\n\(targetURL.absoluteString)"
                )
            }
    }

    /// A section request from the sidebar or ⌘1–⌘4: the section shows its list even when it is already selected
    /// and a story is open over it (#594).
    private func showSection(_ topic: String) {
        selectedTopic = topic
        ArticleDetailView.stepBack(&articlePath, toList: true)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        SidebarView(
            selectedTopic: Binding(get: { selectedTopic }, set: { showSection($0 ?? "Today") }),
            mastheadNotice: $mastheadNotice,
            showsTensionReading: appSettings.tensionCollectionOptIn,
            tensionReading: currentTensionReading,
            tensionStatus: tensionStatus,
            openTension: { showsTension = true }
        )
        .environmentObject(appSettings)
        .environmentObject(feedManager)
        .environmentObject(savedStories)
        .environmentObject(readManager)
    }

    @ViewBuilder
    private var detailView: some View {
        NavigationStack(path: $articlePath) {
            ZStack {
                AppColor.background

                ArticleListView(
                    selectedTopic: $selectedTopic,
                    searchText: searchBinding,
                    mastheadNotice: $mastheadNotice,
                    articlePath: $articlePath
                )
                .environmentObject(appSettings)
                .environmentObject(articleStore)
                .environmentObject(feedManager)
                .environmentObject(themeManager)
                .environmentObject(readManager)
                .environmentObject(savedStories)
            }
            .navigationDestination(for: FeedArticleWrap.self) { wrap in
                detailDestination(for: wrap)
            }
        }
    }

    @ViewBuilder
    private func detailDestination(for wrap: FeedArticleWrap) -> some View {
        ArticleDetailView(
            article: wrap.article,
            allArticles: wrap.contextArticles.isEmpty ? feedManager.articles : wrap.contextArticles,
            path: $articlePath,
            initialExperienceMode: wrap.initialExperienceMode
        )
        .navigationBarBackButtonHidden(true)
        // In full screen the toolbar steps aside for the story and returns on hover.
        .windowToolbarFullScreenVisibility(.onHover)
        .environmentObject(appSettings)
        .environmentObject(articleStore)
        .environmentObject(feedManager)
        .environmentObject(savedStories)
        .environmentObject(readManager)
        .environmentObject(themeManager)
    }

    @ViewBuilder
    private func tensionSheetContent() -> some View {
        TensionIndexView(history: tensionHistory, onUpdate: { tensionHistory = $0 })
            .environmentObject(articleStore)
            .environmentObject(appSettings)
    }

    // MARK: - Bindings & State Helpers

    private var currentTensionReading: WorldTensionReading? {
        appSettings.aiEnabled ? tensionHistory.last : nil
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { archiveQuery },
            set: { searchText = $0 }
        )
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { articleStore.operationError != nil },
            set: { if !$0 { articleStore.operationError = nil } }
        )
    }

    private var pendingNavigationToken: UUID? {
        articleStore.isReady ? articleStore.pendingNavigation?.token : nil
    }

    private func presentSearch() {
        searchPresented = true
    }

    // MARK: - Lifecycle & Navigation Handlers

    /// The launch refresh starts once the list has shown the cached snapshot (ArticleListView.settleLaunch, #602).
    private func handleAppear() {
        // A window Settings reopened missed the notification; the request is still pending.
        handleNewsTensionCommand()
    }

    private func handleNewsTensionCommand() {
        if NewsTensionRequest.take() { showsTension = true }
    }

    private func handleMastheadNoticeAnnouncement(_: MastheadNotice?, _ notice: MastheadNotice?) {
        guard let notice, let application = NSApp else { return }
        NSAccessibility.post(
            element: application, notification: .announcementRequested,
            userInfo: [
                .announcement: notice.message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    private func handleMastheadNoticeTimeout() async {
        guard let current = mastheadNotice else { return }
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled && mastheadNotice == current { mastheadNotice = nil }
    }

    private func handleSearchTextChange(_: String, _ updatedText: String) {
        let promoted = ArchiveSearchToken.promoteCompleted(in: updatedText)
        if !promoted.tokens.isEmpty {
            for token in promoted.tokens where !searchTokens.contains(token) {
                searchTokens.append(token)
            }
            searchText = promoted.text
        }
        if !articlePath.isEmpty { articlePath = NavigationPath() }
    }

    private func handleSearchTokensChange(_: [ArchiveSearchToken], _ tokens: [ArchiveSearchToken]) {
        let kept = ArchiveSearchToken.latestPerField(tokens)
        if kept != tokens { searchTokens = kept }
        if !articlePath.isEmpty { articlePath = NavigationPath() }
    }

    private func reloadTension() async {
        guard appSettings.tensionCollectionOptIn, appSettings.aiEnabled, articleStore.isReady else {
            tensionHistory = []
            if !appSettings.aiEnabled {
                tensionStatus = "AI is off"
            } else if !appSettings.tensionCollectionOptIn {
                tensionStatus = "Collection is off"
            } else {
                tensionStatus = "Collecting headlines"
            }
            return
        }
        tensionStatus = "Assessing headlines"
        do {
            let loaded = try await WorldTensionService.shared.assess(
                database: articleStore.database,
                now: Date(), aiEnabled: appSettings.aiEnabled, collectionEnabled: appSettings.tensionCollectionOptIn
            )
            try Task.checkCancellation()
            tensionHistory = loaded
            tensionStatus = "World Tension"
        } catch {
            guard !Task.isCancelled else { return }
            let accepted = try? await articleStore.database.worldTensionHistory()
            guard !Task.isCancelled, appSettings.aiEnabled, appSettings.tensionCollectionOptIn else { return }
            tensionHistory = accepted ?? []
            tensionStatus = "Assessment unavailable"
        }
    }

    private func scheduleTensionDayRollover() async {
        let nextDay = TensionMethodology.day(containing: Date()).end
        try? await Task.sleep(for: .seconds(max(1, nextDay.timeIntervalSinceNow + 1)))
        guard !Task.isCancelled else { return }
        tensionDayStart = TensionMethodology.day(containing: Date()).start
    }

    private func handlePendingNavigation() async {
        guard articleStore.isReady, let request = articleStore.pendingNavigation else { return }
        do {
            let article = try await articleStore.articleForNavigation(request)
            guard !Task.isCancelled, articleStore.pendingNavigation == request else { return }
            if let article {
                articlePath = NavigationPath()
                readManager.markAsRead(article.id)
                articlePath.append(FeedArticleWrap(article: article))
            } else {
                articleStore.operationError = "This story is no longer available in your archive."
            }
            articleStore.pendingNavigation = nil
        } catch {
            guard !Task.isCancelled else { return }
            articleStore.operationError = "The notification story could not be loaded. Please try again."
        }
    }

    private func handleIncomingURL(_ url: URL) {
        NSApp.activate()

        guard
            let destination = NewsURLParser.parse(
                url: url,
                allowInsecureHTTP: appSettings.allowInsecureHTTP
            )
        else {
            return
        }

        switch destination {
        case .story(let storyID):
            articleStore.pendingNavigation = .init(articleID: storyID, link: "")
        case .addFeed(let feedURL):
            if appSettings.hasFeed(feedURL.absoluteString) {
                articleStore.operationError = "You are already subscribed to this feed."
                return
            }
            pendingFeedConfirmationURL = feedURL
        }
    }

    private func handleSpotlightContinuation(_ activity: NSUserActivity) {
        guard
            let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        if let url = URL(string: "news://story/\(encoded)") {
            handleIncomingURL(url)
        } else {
            NSApp.activate()
            articleStore.pendingNavigation = .init(articleID: identifier, link: "")
        }
    }

    private func confirmAddFeed(_ url: URL) {
        let urlString = url.absoluteString
        if feedManager.addFeed(url: urlString) {
            mastheadNotice = MastheadNotice(message: "Subscribed to \(url.host ?? "feed")")
        } else {
            articleStore.operationError = "Feed not added. Check the URL or whether you already subscribe."
        }
    }

    /// The sidebar reading is rescored when collection is turned on, after each refresh and when a new UTC day begins.
    private var tensionReloadKey: String {
        "\(appSettings.tensionCollectionOptIn):\(appSettings.aiEnabled):\(articleStore.isReady):\(feedManager.lastRefreshCompletedAt?.timeIntervalSince1970 ?? 0):\(tensionDayStart.timeIntervalSince1970)"
    }

    // MARK: - Search Operators

    private var archiveQuery: String {
        ArchiveSearchToken.query(text: searchText, tokens: searchTokens)
    }

    private static let searchOperators: [(token: String, summary: String)] = [
        ("is:unread", "Unread stories"),
        ("is:read", "Stories you have read"),
        ("is:saved", "Saved stories"),
        ("source:", "Publisher, e.g. source:bbc"),
        ("category:", "Category, e.g. category:science"),
    ]

    /// Filter operators, offered while the word being typed is empty or starts one; a choice completes onto the
    /// words already typed.
    @ViewBuilder
    private var searchOperatorSuggestions: some View {
        if !searchText.isEmpty {
            let word =
                searchText.last?.isWhitespace == false
                ? String(searchText.split(whereSeparator: \.isWhitespace).last ?? "") : ""
            let typed = String(searchText.dropLast(word.count))
            let lowered = word.lowercased()
            ForEach(
                Self.searchOperators.filter { lowered.isEmpty || ($0.token.hasPrefix(lowered) && $0.token != lowered) },
                id: \.token
            ) { option in
                if let token = ArchiveSearchToken(completedExpression: option.token) {
                    operatorSuggestion(option)
                        .searchCompletion(token)
                } else {
                    // Source and category need values before becoming tokens.
                    operatorSuggestion(option)
                        .searchCompletion(typed + option.token)
                }
            }
            if let token = ArchiveSearchToken(completedExpression: word),
                lowered.hasPrefix("source:") || lowered.hasPrefix("category:")
            {
                Text("Filter: \(token.expression)")
                    .searchCompletion(token)
            }
        }
    }

    private func operatorIcon(for token: String) -> String {
        if token.hasPrefix("is:unread") { return "circle.circle" }
        if token.hasPrefix("is:read") { return "checkmark.circle" }
        if token.hasPrefix("is:saved") { return "bookmark" }
        if token.hasPrefix("source:") { return "newspaper" }
        if token.hasPrefix("category:") { return "tag" }
        return "magnifyingglass"
    }

    /// One suggestion row. The operator column is as wide as the longest operator, so every description starts at
    /// the same position.
    private func operatorSuggestion(_ option: (token: String, summary: String)) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: operatorIcon(for: option.token))
                .foregroundStyle(AppColor.accentText)
                .frame(width: 16)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                Text(Self.longestSearchOperator).hidden().accessibilityHidden(true)
                Text(option.token)
            }
            .font(AppTypography.caption.monospaced())
            Text(option.summary).foregroundStyle(AppColor.secondaryText)
        }
    }

    private static let longestSearchOperator =
        searchOperators.map(\.token).max { $0.count < $1.count } ?? ""

    // MARK: - Window-Level OPML Drop

    private func handleWindowOPMLDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { item, error in
                if let error {
                    Task { @MainActor in
                        articleStore.operationError =
                            "The dropped file could not be read: \(error.localizedDescription)"
                    }
                    return
                }
                guard let url = item else {
                    Task { @MainActor in articleStore.operationError = "The dropped file could not be read." }
                    return
                }

                if url.isFileURL
                    && (url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml")
                {
                    Task { @MainActor in
                        let count = await self.feedManager.importFeeds(fromFile: url)
                        if count > 0 {
                            mastheadNotice = MastheadNotice(
                                message: "Imported \(count) feed\(count == 1 ? "" : "s") from OPML")
                        } else if articleStore.operationError == nil {
                            mastheadNotice = MastheadNotice(message: "No new feeds imported")
                        }
                    }
                } else {
                    Task { @MainActor in
                        articleStore.operationError = "Only OPML or XML subscription files can be imported."
                    }
                }
            }
            return true
        }
        return false
    }
}

private struct ArchiveSearchToolbar<Suggestions: View>: ViewModifier {
    @Binding var searchText: String
    @Binding var searchTokens: [ArchiveSearchToken]
    @Binding var searchPresented: Bool
    let archiveQuery: String
    let presentSearch: () -> Void
    let suggestions: Suggestions
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $searchText, tokens: $searchTokens, isPresented: $searchPresented, placement: .toolbar,
                prompt: "Search archive"
            ) { token in
                Label(token.displayName, systemImage: token.systemImage)
            }
            .searchSuggestions { suggestions }
            .focusedSceneValue(\.archiveSearch, presentSearch)
            .background(
                CompactArchiveSearch(expanded: searchPresented || !archiveQuery.isEmpty, animates: !reduceMotion)
                    .frame(width: 0, height: 0)
            )
    }
}

/// SwiftUI owns search, tokens and focus; this narrow bridge only bounds the native toolbar item's resting width.
/// macOS exposes automatic space-based collapse, but no SwiftUI always-collapsed search behavior.
private struct CompactArchiveSearch: NSViewRepresentable {
    let expanded: Bool
    let animates: Bool
    func makeNSView(context _: Context) -> SearchSizer { SearchSizer() }
    func updateNSView(_ view: SearchSizer, context _: Context) {
        view.expanded = expanded
        view.animates = animates
        view.scheduleUpdate()
    }
    static func dismantleNSView(_ view: SearchSizer, coordinator _: ()) { view.width?.isActive = false }

    final class SearchSizer: NSView {
        var expanded = false
        var animates = true
        var width: NSLayoutConstraint?
        weak var field: NSSearchField?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }
        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        func apply() {
            guard let item = window?.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first else { return }
            item.preferredWidthForSearchField = AppLayout.archiveSearchWidth
            if field !== item.searchField {
                width?.isActive = false
                field = item.searchField
                width = item.searchField.widthAnchor.constraint(
                    lessThanOrEqualToConstant: AppLayout.archiveSearchCollapsedWidth)
                width?.priority = .init(999)
            }
            if window != nil, animates {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    width?.isActive = !expanded
                }
            } else {
                width?.isActive = !expanded
            }
        }
    }
}

private struct ArchiveSearchKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var archiveSearch: (() -> Void)? {
        get { self[ArchiveSearchKey.self] }
        set { self[ArchiveSearchKey.self] = newValue }
    }
}
