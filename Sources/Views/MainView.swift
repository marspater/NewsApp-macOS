// MainView.swift
// NewsApp Main Window Orchestrator & Split View Coordinator

import SwiftUI
import AppKit
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
    @State private var articlePath = NavigationPath()
    
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isWindowDropTargeted = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedTopic: $selectedTopic)
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
                        searchText: $searchText,
                        articlePath: $articlePath,
                        columnVisibility: $columnVisibility
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
                    .environmentObject(appSettings)
                    .environmentObject(articleStore)
                    .environmentObject(feedManager)
                    .environmentObject(savedStories)
                    .environmentObject(readManager)
                    .environmentObject(themeManager)
                }
            }
        }
        .alert("Operation failed", isPresented: Binding(
            get: { articleStore.operationError != nil },
            set: { if !$0 { articleStore.operationError = nil } }
        )) {
            Button("OK") { articleStore.operationError = nil }
        } message: {
            Text(articleStore.operationError ?? "Please try again.")
        }
        .navigationSplitViewStyle(.balanced)
        // The system sidebar field: Liquid Glass on macOS 26, the standard search field on macOS 15.
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .searchSuggestions { searchOperatorSuggestions }
        .softScrollEdge()
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if feedManager.articles.isEmpty {
                feedManager.fetchFeeds()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isWindowDropTargeted) { providers in
            handleWindowOPMLDrop(providers: providers)
        }
        .onChange(of: selectedTopic) { _, _ in
            articlePath = NavigationPath()
        }
        .onChange(of: searchText) { _, _ in
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
    
    // MARK: - Search Operators

    private static let searchOperators: [(token: String, summary: String)] = [
        ("is:unread", "Unread stories"),
        ("is:read", "Stories you have read"),
        ("is:saved", "Saved stories"),
        ("source:", "Publisher, e.g. source:bbc"),
        ("category:", "Category, e.g. category:science")
    ]

    /// Filter operators, offered while the word being typed is empty or starts one; a choice completes onto the
    /// words already typed.
    @ViewBuilder
    private var searchOperatorSuggestions: some View {
        let word = searchText.last?.isWhitespace == false ? String(searchText.split(whereSeparator: \.isWhitespace).last ?? "") : ""
        let typed = String(searchText.dropLast(word.count))
        let lowered = word.lowercased()
        ForEach(Self.searchOperators.filter { lowered.isEmpty || ($0.token.hasPrefix(lowered) && $0.token != lowered) }, id: \.token) { option in
            HStack(spacing: AppSpacing.sm) {
                Text(option.token).font(.system(.body, design: .monospaced))
                Text(option.summary).foregroundStyle(AppColor.secondaryText)
            }
            .searchCompletion(typed + option.token)
        }
    }

    // MARK: - Window-Level OPML Drop
    
    private func handleWindowOPMLDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { item, _ in
                    guard let url = item else { return }
                    
                    if url.isFileURL && (url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml") {
                        Task { @MainActor in
                            await self.feedManager.importFeeds(fromFile: url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
