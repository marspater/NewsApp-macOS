// MainView.swift
// NewsApp Main Window Orchestrator & Split View Coordinator

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Navigation Wrappers & Commands

struct FeedArticleWrap: Identifiable, Hashable {
    let id = UUID()
    let article: FeedArticle
}

extension Notification.Name {
    static let detailNextArticle = Notification.Name("detailNextArticle")
    static let detailPrevArticle = Notification.Name("detailPrevArticle")
    static let detailToggleRead = Notification.Name("detailToggleRead")
    static let detailToggleSave = Notification.Name("detailToggleSave")
    static let detailOpenInBrowser = Notification.Name("detailOpenInBrowser")
    static let detailToggleViewMode = Notification.Name("detailToggleViewMode")
    
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
    @StateObject private var savedStories = SavedStoriesManager.shared
    
    @State private var isWindowDropTargeted = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selectedTopic: $selectedTopic, searchText: $searchText)
                .environmentObject(appSettings)
                .environmentObject(feedManager)
                .environmentObject(savedStories)
                .environmentObject(readManager)
        } detail: {
            NavigationStack(path: $articlePath) {
                ZStack {
                    AppColor.surfaceDark.ignoresSafeArea()
                    
                    ArticleListView(
                        selectedTopic: $selectedTopic,
                        searchText: $searchText,
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
                        allArticles: feedManager.articles,
                        path: $articlePath
                    )
                    .navigationBarBackButtonHidden(true)
                    .environmentObject(feedManager)
                    .environmentObject(savedStories)
                    .environmentObject(readManager)
                    .environmentObject(themeManager)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .backgroundExtensionEffect()
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if feedManager.articles.isEmpty {
                feedManager.fetchFeeds()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isWindowDropTargeted) { providers in
            handleWindowOPMLDrop(providers: providers)
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
        .onReceive(NotificationCenter.default.publisher(for: .openArticleFromNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let articleLink = userInfo["articleLink"] as? String else { return }
            
            if let article = feedManager.articles.first(where: { $0.link == articleLink }) {
                selectedTopic = "Today"
                articlePath = NavigationPath()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    readManager.markAsRead(article.id)
                    articlePath.append(FeedArticleWrap(article: article))
                }
            }
        }
    }
    
    // MARK: - Window-Level OPML Drop
    
    private func handleWindowOPMLDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { item, _ in
                    guard let url = item else { return }
                    
                    if url.isFileURL && (url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml") {
                        if let fileData = try? Data(contentsOf: url) {
                            Task { @MainActor in
                                self.feedManager.importFeeds(from: fileData)
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
