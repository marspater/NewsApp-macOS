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
    
    @State private var focusedArticleID: String? = nil
    @State private var isShortcutsHelpPresented: Bool = false
    
    // MARK: - Filtered Articles
    
    var filteredArticles: [FeedArticle] {
        var result: [FeedArticle]
        let currentTopic = selectedTopic ?? "Today"
        if currentTopic == "Saved Stories" {
            result = savedStories.savedArticles
        } else if currentTopic == "Unread" {
            result = feedManager.articles.filter { !readManager.isRead($0.id) }
        } else if currentTopic == "History" {
            result = feedManager.articles.filter { readManager.isRead($0.id) }
        } else {
            result = feedManager.articles(for: currentTopic)
        }
        
        // Auto-Hide Read
        if themeManager.autoHideRead &&
            currentTopic != "Saved Stories" &&
            currentTopic != "Unread" &&
            currentTopic != "History" {
            result = result.filter { !readManager.isRead($0.id) }
        }
        
        // Structured Filter Query
        if !searchText.isEmpty {
            let query = ArticleFilterQuery.parse(searchText)
            result = result.filter { article in
                let isRead = readManager.isRead(article.id)
                let isSaved = savedStories.isSaved(article)
                return query.matches(article: article, isRead: isRead, isSaved: isSaved)
            }
        }
        
        return result
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            
            ScrollViewReader { proxy in
                ScrollView {
                    if filteredArticles.isEmpty {
                        emptyStateView
                    } else {
                        articleGrid(proxy: proxy)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress { press in
                    handleKeyPress(press: press, proxy: proxy)
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
            .highPriorityGesture(TapGesture().onEnded { _ in })
        }
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
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
            
            Text(selectedTopic ?? "Today")
                .font(AppTypography.title)
                .foregroundColor(AppColor.primaryText)
                .tracking(AppTypography.sectionHeaderTracking)
            
            Spacer()
            
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
    
    // MARK: - Article Grid
    
    private func articleGrid(proxy: ScrollViewProxy) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: AppLayout.cardGap)],
            spacing: AppLayout.cardGap
        ) {
            ForEach(filteredArticles) { article in
                ArticleCardView(
                    article: article,
                    isSelected: article.id == focusedArticleID
                ) {
                    focusedArticleID = article.id
                    readManager.markAsRead(article.id)
                    articlePath.append(FeedArticleWrap(article: article, contextArticles: filteredArticles))
                }
                .id(article.id)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.bottom, 30)
    }
    
    // MARK: - Empty States & Diagnostics
    
    private var emptyStateView: some View {
        VStack(spacing: AppSpacing.md) {
            let failedFeeds = feedManager.feedStatuses.filter {
                if case .failed = $0.value { return true }
                return false
            }
            
            if feedManager.isAnyFeedLoading {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.bottom, 4)
                Text("Refreshing news feeds...")
                    .font(AppTypography.body)
                    .foregroundColor(AppColor.secondaryText)
            } else if (selectedTopic != "Saved Stories" && selectedTopic != "History") && !failedFeeds.isEmpty && filteredArticles.isEmpty {
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
        case "Today", "Unread": return "newspaper"
        case "Saved Stories": return "bookmark"
        case "History": return "clock"
        default: return "tray"
        }
    }
    
    private var emptyStateTitle: String {
        switch selectedTopic {
        case "Today": return "No Articles Yet"
        case "Unread": return "All Caught Up"
        case "Saved Stories": return "No Saved Stories"
        case "History": return "No Reading History"
        default: return "Nothing in \(selectedTopic ?? "Section")"
        }
    }
    
    private var emptyStateText: String {
        switch selectedTopic {
        case "Today": return "Subscribe to feeds or click refresh to load the latest stories."
        case "Unread": return "You've read all stories in your feeds. Check back later for updates."
        case "Saved Stories": return "Stories you bookmark will be kept here for easy reading."
        case "History": return "Articles you have opened will appear here."
        default: return "New articles matching \(selectedTopic ?? "this section") will appear here once your feeds refresh."
        }
    }
    
    // MARK: - Keyboard Handling
    
    private func handleKeyPress(press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard articlePath.isEmpty else { return .ignored }
        
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
        guard !filteredArticles.isEmpty else { return }
        let currentIndex: Int
        if let currentID = focusedArticleID, let idx = filteredArticles.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        } else {
            currentIndex = offset > 0 ? -1 : filteredArticles.count
        }
        let targetIndex = max(0, min(filteredArticles.count - 1, currentIndex + offset))
        let targetArticle = filteredArticles[targetIndex]
        focusedArticleID = targetArticle.id
        withAnimation(AppMotion.quick) {
            proxy.scrollTo(targetArticle.id, anchor: .center)
        }
    }
    
    private func openFocusedArticle() {
        let articleToOpen: FeedArticle?
        if let id = focusedArticleID, let art = filteredArticles.first(where: { $0.id == id }) {
            articleToOpen = art
        } else {
            articleToOpen = filteredArticles.first
        }
        guard let article = articleToOpen else { return }
        focusedArticleID = article.id
        readManager.markAsRead(article.id)
        articlePath.append(FeedArticleWrap(article: article, contextArticles: filteredArticles))
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
                .cornerRadius(5)
            Spacer()
            Text(desc)
                .font(AppTypography.caption)
                .foregroundColor(AppColor.secondaryText)
        }
    }
}
