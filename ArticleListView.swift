// ArticleListView.swift
// NewsApp Article Grid List View & Navigation Coordinator

import SwiftUI
import AppKit

struct ArticleListView: View {
    @Binding var selectedTopic: String?
    @Binding var searchText: String
    @Binding var articlePath: NavigationPath
    
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    
    @State private var focusedArticleID: String? = nil
    @State private var isRefreshing: Bool = false
    @State private var isShortcutsHelpPresented: Bool = false
    
    // MARK: - Filtered Articles
    
    var filteredArticles: [FeedArticle] {
        var result: [FeedArticle]
        if let topic = selectedTopic {
            if topic == "Saved Stories" {
                result = savedStories.savedArticles
            } else if topic == "Unread" {
                result = feedManager.articles.filter { !readManager.isRead($0.id) }
            } else if topic == "History" {
                result = feedManager.articles.filter { readManager.isRead($0.id) }
            } else {
                result = feedManager.articles(for: topic)
            }
        } else {
            result = feedManager.articles
        }
        
        // Auto-Hide Read
        if themeManager.autoHideRead &&
            selectedTopic != "Saved Stories" &&
            selectedTopic != "Unread" &&
            selectedTopic != "History" {
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
            .onTapGesture {} // Prevents click-through window drag
        }
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack {
            Text(selectedTopic?.uppercased() ?? "TODAY")
                .font(.system(size: 22, weight: .bold, design: .default))
                .foregroundColor(AppColor.textPrimary)
                .tracking(AppTypography.sectionHeaderTracking)
            
            Spacer()
            
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 4)
            }
            
            Button {
                isShortcutsHelpPresented.toggle()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColor.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShortcutsHelpPresented) {
                shortcutsHelpView
            }
            .help("Keyboard Shortcuts")
            
            Button {
                refreshFeeds()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppColor.textSecondary)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh Feeds (R or ⌘R)")
        }
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, AppSpacing.md)
    }
    
    // MARK: - Article Grid
    
    private func articleGrid(proxy: ScrollViewProxy) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: AppSpacing.md)],
            spacing: AppSpacing.md
        ) {
            ForEach(filteredArticles) { article in
                ArticleCardView(
                    article: article,
                    isSelected: article.id == focusedArticleID
                ) {
                    focusedArticleID = article.id
                    readManager.markAsRead(article.id)
                    articlePath.append(FeedArticleWrap(article: article))
                }
                .id(article.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98)),
                    removal: .opacity
                ))
            }
        }
        .animation(AppMotion.responsive, value: filteredArticles)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, 30)
    }
    
    // MARK: - Empty States & Diagnostics
    
    private var emptyStateView: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 44))
                .foregroundColor(AppColor.textTertiary)
            
            Text(emptyStateText)
                .foregroundColor(AppColor.textTertiary)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
            
            let failedFeeds = feedManager.feedStatuses.filter {
                if case .failed = $0.value { return true }
                return false
            }
            
            if feedManager.isAnyFeedLoading {
                HStack(spacing: AppSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Updating news feeds...")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(AppColor.accentPink.opacity(0.85))
                }
                .padding(.top, AppSpacing.sm)
            } else if !failedFeeds.isEmpty {
                VStack(spacing: AppSpacing.xs) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AppColor.errorRed)
                        Text("Some feeds failed to load:")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColor.errorRed)
                    }
                    
                    ForEach(Array(failedFeeds.keys.prefix(3)), id: \.self) { failedUrl in
                        if case .failed(let err) = feedManager.feedStatuses[failedUrl] {
                            Text("\(failedUrl): \(err.localizedDescription)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Button("Retry Feeds") {
                        refreshFeeds()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColor.accentPink)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.bubble)
                        .fill(Color.primary.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.bubble)
                                .stroke(AppColor.errorRed.opacity(0.2), lineWidth: 1)
                        )
                )
                .frame(maxWidth: 380)
                .padding(.top, AppSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
    
    private var emptyStateIcon: String {
        switch selectedTopic {
        case "Today", "Unread": return "newspaper"
        case "Saved Stories": return "bookmark"
        default: return "tray"
        }
    }
    
    private var emptyStateText: String {
        switch selectedTopic {
        case "Today": return "No articles available"
        case "Unread": return "You're all caught up! No unread articles."
        case "Saved Stories": return "No saved stories yet.\nSave articles using the bookmark icon."
        case "History": return "No reading history"
        default: return "No articles in \"\(selectedTopic ?? "")\"\nArticles are auto-categorized.\nTry adding more RSS feeds."
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
        articlePath.append(FeedArticleWrap(article: article))
    }
    
    private func refreshFeeds() {
        isRefreshing = true
        feedManager.fetchFeeds()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.isRefreshing = false
        }
    }
    
    // MARK: - Shortcuts Help View
    
    private var shortcutsHelpView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 2)
            
            Group {
                shortcutRow("J / ↓", "Next article")
                shortcutRow("K / ↑", "Previous article")
                shortcutRow("Space / ↵", "Open focused article")
                shortcutRow("M", "Toggle read / unread")
                shortcutRow("S", "Bookmark story")
                shortcutRow("O", "Open in browser")
                shortcutRow("R / ⌘R", "Refresh feeds")
                shortcutRow("W / ⇧⌘W", "Toggle Reader / Web view")
                shortcutRow("Esc / ←", "Back to list (in detail)")
                shortcutRow("⌘1 - ⌘4", "Jump to Section")
            }
        }
        .padding(14)
        .frame(width: 260)
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
                .font(.system(size: 11))
                .foregroundColor(AppColor.textSecondary)
        }
    }
}
