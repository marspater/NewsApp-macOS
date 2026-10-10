// MainView.swift
// NewsApp Main Window Orchestrator & Split View Coordinator

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Navigation Notifications & Commands

extension Notification.Name {
    // Section Jump Commands
    static let jumpToTodayCommand = Notification.Name("jumpToTodayCommand")
    static let jumpToUnreadCommand = Notification.Name("jumpToUnreadCommand")
    static let jumpToSavedCommand = Notification.Name("jumpToSavedCommand")
    static let jumpToHistoryCommand = Notification.Name("jumpToHistoryCommand")
}

// MARK: - Main View

struct MainView: View {
    @State private var selectedTopic: String? = "Today"
    @State private var searchText: String = ""
    @State private var searchTokens: [ArchiveSearchToken] = []
    @State private var mastheadNotice: MastheadNotice?
    @State private var articlePath = NavigationPath()

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The tension series behind the sidebar reading; the sheet opens with it.
    @State private var tensionHistory: [TensionHistoryDay] = []
    @State private var showsTension = false
    @State private var isWindowDropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedTopic: $selectedTopic, mastheadNotice: $mastheadNotice,
                showsTensionReading: appSettings.tensionCollectionOptIn,
                tensionReading: TensionHistory.latestReading(in: tensionHistory),
                openTension: { showsTension = true }
            )
                .environmentObject(appSettings)
                .environmentObject(feedManager)
                .environmentObject(savedStories)
                .environmentObject(readManager)
        } detail: {
            NavigationStack(path: $articlePath) {
                ZStack {
                    AppColor.background

                    ArticleListView(
                        selectedTopic: $selectedTopic,
                        searchText: Binding(
                            get: { archiveQuery },
                            set: { searchText = $0 }
                        ),
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
                    ArticleDetailView(
                        article: wrap.article,
                        allArticles: wrap.contextArticles.isEmpty ? feedManager.articles : wrap.contextArticles,
                        path: $articlePath
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
            }
        }
        .alert(
            "Operation failed",
            isPresented: Binding(
                get: { articleStore.operationError != nil },
                set: { if !$0 { articleStore.operationError = nil } }
            )
        ) {
            Button("OK") { articleStore.operationError = nil }
        } message: {
            Text(articleStore.operationError ?? "Please try again.")
        }
        .navigationSplitViewStyle(.balanced)
        // A sheet, so the rest of the window waits until the reader closes it.
        .sheet(isPresented: $showsTension) {
            TensionIndexView(history: tensionHistory)
                .environmentObject(articleStore)
                .environmentObject(appSettings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewsTensionCommand)) { _ in
            showsTension = true
        }
        .task(id: tensionReloadKey) {
            guard appSettings.tensionCollectionOptIn, articleStore.isReady else {
                tensionHistory = []
                return
            }
            if let loaded = try? await TensionHistory.load(from: articleStore.database, now: Date()),
                !Task.isCancelled
            {
                tensionHistory = loaded
            }
        }
        // One archive search in the trailing toolbar, shared by list and reader.
        .searchable(text: $searchText, tokens: $searchTokens, placement: .toolbar, prompt: "Search archive") { token in
            Text(token.expression)
        }
        .searchSuggestions { searchOperatorSuggestions }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if feedManager.articles.isEmpty {
                feedManager.fetchFeeds()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isWindowDropTargeted) { providers in
            handleWindowOPMLDrop(providers: providers)
        }
        .onChange(of: mastheadNotice) { _, notice in
            guard let notice, let application = NSApp else { return }
            NSAccessibility.post(
                element: application, notification: .announcementRequested,
                userInfo: [
                    .announcement: notice.message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
        .task(id: mastheadNotice) {
            guard let current = mastheadNotice else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled && mastheadNotice == current { mastheadNotice = nil }
        }
        .onChange(of: selectedTopic) { _, _ in
            articlePath = NavigationPath()
        }
        .onChange(of: searchText) { _, updatedText in
            let promoted = ArchiveSearchToken.promoteCompleted(in: updatedText)
            if !promoted.tokens.isEmpty {
                for token in promoted.tokens where !searchTokens.contains(token) {
                    searchTokens.append(token)
                }
                searchText = promoted.text
            }
            if !articlePath.isEmpty { articlePath = NavigationPath() }
        }
        .onChange(of: searchTokens) { _, tokens in
            let kept = ArchiveSearchToken.latestPerField(tokens)
            if kept != tokens { searchTokens = kept }
            if !articlePath.isEmpty { articlePath = NavigationPath() }
        }
        // Notification Deep Link & Section Jump Routing
        .onReceive(NotificationCenter.default.publisher(for: .jumpToTodayCommand)) { _ in
            selectedTopic = "Today"
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToUnreadCommand)) { _ in
            selectedTopic = "Unread"
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToSavedCommand)) { _ in
            selectedTopic = "Saved Stories"
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToHistoryCommand)) { _ in
            selectedTopic = "History"
        }
        .task(id: articleStore.isReady ? articleStore.pendingNavigation?.token : nil) {
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
    }

    /// The sidebar reading is rescored when collection is turned on and after each refresh.
    private var tensionReloadKey: String {
        "\(appSettings.tensionCollectionOptIn):\(articleStore.isReady):\(feedManager.lastRefreshCompletedAt?.timeIntervalSince1970 ?? 0)"
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

    /// One suggestion row. The operator column is as wide as the longest operator, so every description starts at
    /// the same position.
    private func operatorSuggestion(_ option: (token: String, summary: String)) -> some View {
        HStack(spacing: AppSpacing.sm) {
            ZStack(alignment: .leading) {
                Text(Self.longestSearchOperator).hidden().accessibilityHidden(true)
                Text(option.token)
            }
            .font(.system(.body, design: .monospaced))
            Text(option.summary).foregroundStyle(AppColor.secondaryText)
        }
    }

    private static let longestSearchOperator =
        searchOperators.map(\.token).max { $0.count < $1.count } ?? ""

    // MARK: - Window-Level OPML Drop

    private func handleWindowOPMLDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { item, _ in
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
