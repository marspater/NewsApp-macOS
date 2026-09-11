import SwiftUI
import AppKit

// MARK: - Standard Semantic Colors for Light/Dark Mode
private let accentPink = Color(.displayP3, red: 1.0, green: 0.22, blue: 0.50, opacity: 1.0)
private let accentGold = Color(.displayP3, red: 1.0, green: 0.84, blue: 0.35, opacity: 1.0)
private let accentBlue = Color(.displayP3, red: 0.30, green: 0.55, blue: 1.0, opacity: 1.0)

private let surfaceDark = Color(NSColor.windowBackgroundColor)
private let surfaceMid = Color(NSColor.controlBackgroundColor)
private let textPrimary = Color.primary
private let textSecondary = Color.secondary
private let textTertiary = Color.secondary.opacity(0.7)

// MARK: - Navigation Wrapper
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
}

// MARK: - Main View
struct MainView: View {
    @State private var selectedTopic: String? = "Today"
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var readManager: ReadManager
    @StateObject private var savedStories = SavedStoriesManager.shared
    
    @State private var searchText: String = ""
    @State private var isSubscribePopoverPresented = false
    @State private var newFeedURL: String = ""
    @State private var articlePath = NavigationPath()
    @State private var isRefreshing = false
    @State private var focusedArticleID: String? = nil
    @State private var isShortcutsHelpPresented = false

    private var filteredArticles: [FeedArticle] {
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
        
        if !searchText.isEmpty {
            let lowerSearch = searchText.lowercased()
            if lowerSearch.contains("source:") || lowerSearch.contains("category:") || lowerSearch.contains("is:") {
                var sourceOp: String?
                var catOp: String?
                var isReadOp: Bool?
                var isSavedOp: Bool?
                var terms: [String] = []
                for token in searchText.components(separatedBy: .whitespaces) {
                    let l = token.lowercased()
                    if l.hasPrefix("source:") { sourceOp = String(token.dropFirst(7)).lowercased() }
                    else if l.hasPrefix("category:") { catOp = String(token.dropFirst(9)).lowercased() }
                    else if l == "is:read" { isReadOp = true }
                    else if l == "is:unread" { isReadOp = false }
                    else if l == "is:saved" { isSavedOp = true }
                    else if !token.isEmpty { terms.append(l) }
                }
                result = result.filter { article in
                    if let s = sourceOp, !article.source.lowercased().contains(s) { return false }
                    if let c = catOp, !(article.category?.lowercased().contains(c) ?? false) { return false }
                    if let r = isReadOp, readManager.isRead(article.id) != r { return false }
                    if let sv = isSavedOp, savedStories.isSaved(article) != sv { return false }
                    if !terms.isEmpty {
                        let text = "\(article.title) \(article.description) \(article.category ?? "")".lowercased()
                        return terms.allSatisfy { text.contains($0) }
                    }
                    return true
                }
            } else {
                result = result.filter {
                    $0.title.localizedCaseInsensitiveContains(searchText) ||
                    $0.description.localizedCaseInsensitiveContains(searchText) ||
                    $0.source.localizedCaseInsensitiveContains(searchText) ||
                    ($0.category?.localizedCaseInsensitiveContains(searchText) ?? false)
                }
            }
        }
        return result
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - Sidebar
    private var sidebar: some View {
        List(selection: $selectedTopic) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(textTertiary)
                    .font(.system(size: 13))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.bottom, 6)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section("Inbox") {
                NavigationLink(value: "Today") {
                    HStack {
                        Label("Today", systemImage: "newspaper.fill")
                        Spacer()
                        if feedManager.isAnyFeedLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                    }
                }
                .listRowBackground(
                    selectedTopic == "Today" ? AnyView(accentPink.opacity(0.8).cornerRadius(8)) : AnyView(Color.clear)
                )
                
                NavigationLink(value: "Unread") {
                    Label("Unread", systemImage: "circle.circle.fill")
                }
                .badge(feedManager.articles.filter { !readManager.isRead($0.id) }.count)
                .listRowBackground(
                    selectedTopic == "Unread" ? AnyView(accentPink.opacity(0.8).cornerRadius(8)) : AnyView(Color.clear)
                )
            }

            Section("Library") {
                NavigationLink(value: "Saved Stories") {
                    Label("Saved Stories", systemImage: "bookmark.fill")
                }
                .badge(savedStories.savedArticles.isEmpty ? 0 : savedStories.savedArticles.count)
                NavigationLink(value: "History") {
                    Label("History", systemImage: "clock.fill")
                }
            }

            Section("Sections") {
                ForEach(feedManager.userSections, id: \.self) { section in
                    NavigationLink(value: section) {
                        Label(section, systemImage: iconForSection(section))
                    }
                    .contextMenu {
                        Button(role: .destructive) { feedManager.removeSection(section) } label: { Label("Remove Section", systemImage: "minus.circle") }
                    }
                }
            }

            Section("Suggested") {
                ForEach(suggestedTopics, id: \.0) { topic, icon in
                    if !feedManager.userSections.contains(topic) {
                        Button { feedManager.addSection(topic) } label: {
                            HStack {
                                Label(topic, systemImage: icon)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundColor(textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.visible)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isSubscribePopoverPresented = true } label: { Image(systemName: "plus") }
                .popover(isPresented: $isSubscribePopoverPresented) { subscribePopover }
            }
        }
    }

    private var subscribePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscribe to RSS Feed").font(.headline)
            TextField("https://example.com/feed", text: $newFeedURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { isSubscribePopoverPresented = false }
                Button("Add") {
                    if !newFeedURL.isEmpty {
                        feedManager.addFeed(url: newFeedURL)
                        newFeedURL = ""
                        isSubscribePopoverPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentPink)
            }
        }
        .padding()
    }

    // MARK: - Detail Content
    private var detailContent: some View {
        NavigationStack(path: $articlePath) {
            ZStack {
                surfaceDark.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(selectedTopic?.uppercased() ?? "TODAY")
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .foregroundColor(textPrimary)
                            .tracking(1.2)
                        Spacer()

                        if isRefreshing { ProgressView().scaleEffect(0.7).padding(.trailing, 4) }

                        Button {
                            isShortcutsHelpPresented.toggle()
                        } label: {
                            Image(systemName: "keyboard")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(textSecondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isShortcutsHelpPresented) { shortcutsHelpView }
                        .help("Keyboard Shortcuts")

                        Button {
                            isRefreshing = true
                            feedManager.fetchFeeds()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { isRefreshing = false }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(textSecondary)
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Feeds (R or ⌘R)")
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 30)
                    .padding(.bottom, 16)

                    ScrollViewReader { proxy in
                        ScrollView {
                            if filteredArticles.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: selectedTopic == "Today" || selectedTopic == "Unread" ? "newspaper" : (selectedTopic == "Saved Stories" ? "bookmark" : "tray"))
                                        .font(.system(size: 44))
                                        .foregroundColor(textTertiary)
                                    
                                    Text(emptyStateText)
                                        .foregroundColor(textTertiary)
                                        .font(.system(size: 15))
                                        .multilineTextAlignment(.center)
                                    
                                    // Diagnostics for errors or loading state
                                    let failedFeeds = feedManager.feedStatuses.filter {
                                        if case .failed = $0.value { return true }
                                        return false
                                    }
                                    
                                    if feedManager.isAnyFeedLoading {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text("Updating news feeds...")
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundColor(accentPink.opacity(0.8))
                                        }
                                        .padding(.top, 12)
                                    } else if !failedFeeds.isEmpty {
                                        VStack(spacing: 8) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundColor(.red)
                                                Text("Some feeds failed to load:")
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundColor(.red)
                                            }
                                            ForEach(Array(failedFeeds.keys.prefix(3)), id: \.self) { failedUrl in
                                                if case .failed(let err) = feedManager.feedStatuses[failedUrl] {
                                                    Text("\(failedUrl): \(err.localizedDescription)")
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundColor(textSecondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Button("Retry Feeds") {
                                                feedManager.fetchFeeds()
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(accentPink)
                                            .controlSize(.small)
                                            .padding(.top, 4)
                                        }
                                        .padding(14)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.02)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.2), lineWidth: 1)))
                                        .frame(maxWidth: 380)
                                        .padding(.top, 12)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                            } else {
                                if selectedTopic == "Saved Stories" {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                                        ForEach(filteredArticles) { article in
                                            ArticleCardView(article: article, isSelected: article.id == focusedArticleID) {
                                                focusedArticleID = article.id
                                                readManager.markAsRead(article.id)
                                                articlePath.append(FeedArticleWrap(article: article))
                                            }
                                            .id(article.id)
                                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)), removal: .opacity))
                                            .contextMenu {
                                                Button(role: .destructive) { savedStories.remove(article) } label: { Label("Remove from Saved", systemImage: "bookmark.slash") }
                                            }
                                        }
                                    }
                                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: filteredArticles)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 30)
                                } else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                                        ForEach(filteredArticles) { article in
                                            ArticleCardView(article: article, isSelected: article.id == focusedArticleID) {
                                                focusedArticleID = article.id
                                                readManager.markAsRead(article.id)
                                                articlePath.append(FeedArticleWrap(article: article))
                                            }
                                            .id(article.id)
                                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)), removal: .opacity))
                                            .contextMenu {
                                                Button { readManager.toggleRead(article.id) } label: { Label(readManager.isRead(article.id) ? "Mark as Unread" : "Mark as Read", systemImage: readManager.isRead(article.id) ? "circle" : "checkmark.circle.fill") }
                                            }
                                        }
                                    }
                                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: filteredArticles)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 30)
                                }
                            }
                        }
                        .focusable()
                        .onKeyPress { press in
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
                                    if let id = focusedArticleID {
                                        readManager.toggleRead(id)
                                    }
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
                                    feedManager.fetchFeeds()
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
                        .onReceive(NotificationCenter.default.publisher(for: .nextArticleCommand)) { _ in
                            if articlePath.isEmpty {
                                navigateList(offset: 1, proxy: proxy)
                            } else {
                                NotificationCenter.default.post(name: .detailNextArticle, object: nil)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .prevArticleCommand)) { _ in
                            if articlePath.isEmpty {
                                navigateList(offset: -1, proxy: proxy)
                            } else {
                                NotificationCenter.default.post(name: .detailPrevArticle, object: nil)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .refreshFeedsCommand)) { _ in
                            feedManager.fetchFeeds()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .toggleReadCommand)) { _ in
                            if articlePath.isEmpty {
                                if let id = focusedArticleID { readManager.toggleRead(id) }
                            } else {
                                NotificationCenter.default.post(name: .detailToggleRead, object: nil)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .toggleSaveCommand)) { _ in
                            if articlePath.isEmpty {
                                if let id = focusedArticleID, let art = filteredArticles.first(where: { $0.id == id }) {
                                    if savedStories.isSaved(art) { savedStories.remove(art) } else { savedStories.save(art) }
                                }
                            } else {
                                NotificationCenter.default.post(name: .detailToggleSave, object: nil)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .openInBrowserCommand)) { _ in
                            if articlePath.isEmpty {
                                if let id = focusedArticleID, let art = filteredArticles.first(where: { $0.id == id }),
                                   let url = URL(string: art.link) {
                                    NSWorkspace.shared.open(url)
                                }
                            } else {
                                NotificationCenter.default.post(name: .detailOpenInBrowser, object: nil)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .toggleViewModeCommand)) { _ in
                            if !articlePath.isEmpty {
                                NotificationCenter.default.post(name: .detailToggleViewMode, object: nil)
                            }
                        }
                    }
                    .onTapGesture {} // Prevents clicks from passing through to the window and triggering the title bar bug
                }
            }
            .navigationDestination(for: FeedArticleWrap.self) { wrap in
                ArticleDetailView(article: wrap.article, allArticles: filteredArticles, path: $articlePath)
                    .navigationBarBackButtonHidden(true)
                    .environmentObject(savedStories)
            }
        }
        .onAppear {
            if feedManager.articles.isEmpty { feedManager.fetchFeeds() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openArticleFromNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let articleLink = userInfo["articleLink"] as? String else { return }
            
            // Find the article matching this link
            if let article = feedManager.articles.first(where: { $0.link == articleLink }) {
                // Switch to Today view and navigate
                selectedTopic = "Today"
                // Clear existing path and navigate to the article
                articlePath = NavigationPath()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    readManager.markAsRead(article.id)
                    articlePath.append(FeedArticleWrap(article: article))
                }
            }
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

    // MARK: - Helpers
    private let suggestedTopics: [(String, String)] = [
        ("Entertainment", "tv"), ("Science", "atom"),
        ("U.S. Politics", "building.columns"), ("Tech", "cpu"),
        ("Business", "briefcase"), ("Health & Wellness", "leaf"),
        ("Fashion", "tshirt"), ("Travel", "airplane"),
        ("Sports", "sportscourt"), ("World", "globe.americas")
    ]

    private func iconForSection(_ section: String) -> String {
        let map: [String: String] = [
            "Entertainment": "tv", "Politics": "building.columns",
            "Business": "briefcase", "Tech": "cpu",
            "Food": "fork.knife", "Health & Wellness": "leaf",
            "Lifestyle": "chair.lounge", "Science": "atom",
            "U.S. Politics": "building.columns", "Fashion": "tshirt",
            "Travel": "airplane", "Sports": "sportscourt",
            "World": "globe.americas"
        ]
        return map[section] ?? "doc.text"
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
        withAnimation(.easeInOut(duration: 0.15)) {
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
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(5)
            Spacer()
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
        }
    }
}

// MARK: - Article Card
struct ArticleCardView: View {
    let article: FeedArticle
    var isSelected: Bool = false
    let action: () -> Void
    @EnvironmentObject private var readManager: ReadManager
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let imageUrl = article.imageUrl, let url = URL(string: imageUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 240)
                                .brightness(-0.05)
                                .contrast(1.05)
                                .saturation(1.1)
                                .clipped()
                                .overlay(Color.black.opacity(0.1))
                        default:
                            Rectangle().fill(surfaceMid).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 240)
                        }
                    }
                } else {
                    Rectangle().fill(surfaceMid).frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: 240)
                }

                LinearGradient(colors: [Color.clear, Color.black.opacity(0.85)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 5) {
                    Text((article.source.components(separatedBy: "\n").first ?? article.source).trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(accentPink)
                        .tracking(0.8)

                    Text(article.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(radius: 3)

                    if let ai = article.aiSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.system(size: 9))
                            Text(ai).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        }
                        .foregroundColor(accentGold)
                    }

                    Text(article.description)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.7))
                        .lineLimit(2)
                }
                .padding(16)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? accentPink : (isHovered ? accentPink.opacity(0.4) : Color.primary.opacity(0.1)), lineWidth: isSelected ? 2.5 : (isHovered ? 2 : 0.5))
            )
            .shadow(color: isSelected ? accentPink.opacity(0.35) : Color.black.opacity(isHovered ? 0.4 : 0.2), radius: isSelected ? 14 : (isHovered ? 12 : 8), x: 0, y: isSelected ? 6 : (isHovered ? 8 : 4))
            .scaleEffect(isSelected ? 1.03 : (isHovered ? 1.02 : 1.0))
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered || isSelected)
            .opacity(readManager.isRead(article.id) ? 0.45 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Article Detail View
enum DetailViewMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case web = "Web"
    var id: String { rawValue }
}

struct ArticleDetailView: View {
    @State var activeArticle: FeedArticle
    let allArticles: [FeedArticle]
    @Binding var path: NavigationPath
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var viewMode: DetailViewMode = .reader
    @State private var isWebLoading: Bool = false
    @State private var webCanGoBack: Bool = false
    @State private var webCanGoForward: Bool = false

    init(article: FeedArticle, allArticles: [FeedArticle] = [], path: Binding<NavigationPath>) {
        self._activeArticle = State(initialValue: article)
        self.allArticles = allArticles
        self._path = path
    }

    private var currentArticle: FeedArticle {
        feedManager.articles.first { $0.id == activeArticle.id } ?? activeArticle
    }

    private var isSaved: Bool {
        savedStories.isSaved(currentArticle)
    }

    private func nextArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx + 1 < allArticles.count else { return }
        let next = allArticles[idx + 1]
        activeArticle = next
        readManager.markAsRead(next.id)
    }

    private func prevArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx > 0 else { return }
        let prev = allArticles[idx - 1]
        activeArticle = prev
        readManager.markAsRead(prev.id)
    }
    
    // Ghost Themes Design Maps
    private var titleFontDef: Font {
        switch themeManager.articleTheme {
        case .casper: return .system(size: 44, weight: .bold, design: .serif)
        case .edition: return .system(size: 40, weight: .heavy, design: .default)
        case .alto: return .system(size: 36, weight: .medium, design: .monospaced)
        }
    }
    
    private var bodyFontDef: Font {
        switch themeManager.articleTheme {
        case .casper: return .system(size: 21, weight: .regular, design: .serif)
        case .edition: return .system(size: 18, weight: .regular, design: .default)
        case .alto: return .system(size: 17, weight: .regular, design: .monospaced)
        }
    }
    
    private var bodyLineSpacing: CGFloat {
        switch themeManager.articleTheme {
        case .casper: return 12
        case .edition: return 8
        case .alto: return 14
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            surfaceDark.ignoresSafeArea()

            if viewMode == .reader {
                readerView
            } else {
                webViewContainer
            }

            topToolbar
        }
        .focusable()
        .onKeyPress { press in
            switch press.key {
            case .escape, .leftArrow:
                if !path.isEmpty { path.removeLast() }
                return .handled
            case .downArrow:
                nextArticle()
                return .handled
            case .upArrow:
                prevArticle()
                return .handled
            default:
                if press.characters == "j" {
                    nextArticle()
                    return .handled
                } else if press.characters == "k" {
                    prevArticle()
                    return .handled
                } else if press.characters == "m" {
                    readManager.toggleRead(currentArticle.id)
                    return .handled
                } else if press.characters == "s" {
                    if isSaved { savedStories.remove(currentArticle) } else { savedStories.save(currentArticle) }
                    return .handled
                } else if press.characters == "o" {
                    if let url = URL(string: currentArticle.link) { NSWorkspace.shared.open(url) }
                    return .handled
                } else if press.characters == "c" {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentArticle.link, forType: .string)
                    return .handled
                } else if press.characters == "w" {
                    viewMode = (viewMode == .reader ? .web : .reader)
                    return .handled
                }
                return .ignored
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailNextArticle)) { _ in nextArticle() }
        .onReceive(NotificationCenter.default.publisher(for: .detailPrevArticle)) { _ in prevArticle() }
        .onReceive(NotificationCenter.default.publisher(for: .detailToggleRead)) { _ in readManager.toggleRead(currentArticle.id) }
        .onReceive(NotificationCenter.default.publisher(for: .detailToggleSave)) { _ in
            if isSaved { savedStories.remove(currentArticle) } else { savedStories.save(currentArticle) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailOpenInBrowser)) { _ in
            if let url = URL(string: currentArticle.link) { NSWorkspace.shared.open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailToggleViewMode)) { _ in
            viewMode = (viewMode == .reader ? .web : .reader)
        }
    }

    private var readerView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    if let imageUrl = currentArticle.imageUrl, let url = URL(string: imageUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill).frame(maxWidth: .infinity, maxHeight: 480).clipped()
                            default:
                                surfaceMid.frame(maxWidth: .infinity).frame(height: 480)
                            }
                        }
                    }
                    LinearGradient(colors: [surfaceDark.opacity(0), surfaceDark.opacity(0.4), surfaceDark], startPoint: .center, endPoint: .bottom).frame(height: 200)
                }

                VStack(alignment: .leading, spacing: 20) {
                    Text(currentArticle.title)
                        .font(titleFontDef)
                        .foregroundColor(textPrimary)

                    Text("\((currentArticle.source.components(separatedBy: "\n").first ?? currentArticle.source).trimmingCharacters(in: .whitespacesAndNewlines)) · \(currentArticle.pubDate.formatted(date: .long, time: .omitted))")
                        .font(.system(size: 15, weight: .semibold, design: themeManager.articleTheme == .alto ? .monospaced : .default))
                        .foregroundColor(accentPink)
                        .tracking(1.2)
                        .textCase(.uppercase)

                    if let ai = currentArticle.aiSummary {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkles").foregroundColor(accentGold).padding(.top, 3)
                            Text(ai).font(.system(size: 14, weight: .medium)).foregroundColor(accentGold)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).overlay(RoundedRectangle(cornerRadius: 12).stroke(accentGold.opacity(0.2), lineWidth: 0.5)))
                    }

                    if currentArticle.contentFetched {
                        VStack(alignment: .leading, spacing: 20) {
                            if let content = currentArticle.fullContent, !content.isEmpty {
                                ForEach(contentParagraphs(content), id: \.self) { paragraph in
                                    Text(paragraph)
                                        .font(bodyFontDef)
                                        .foregroundColor(textPrimary.opacity(0.87))
                                        .lineSpacing(bodyLineSpacing)
                                }
                            } else {
                                Text(currentArticle.description)
                                    .font(bodyFontDef)
                                    .foregroundColor(textPrimary.opacity(0.87))
                                    .lineSpacing(bodyLineSpacing)

                                Button(action: { viewMode = .web }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "safari")
                                        Text("Open Web View (W)")
                                    }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(accentPink))
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 12)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        VStack(spacing: 20) {
                            Spacer().frame(height: 40)
                            ForEach(0..<3) { _ in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(textTertiary.opacity(0.2))
                                    .frame(height: 20)
                                    .frame(maxWidth: .infinity)
                            }
                            .phaseAnimator([0.5, 1.0]) { content, phase in
                                content.opacity(phase)
                            }
                            
                            Text("AI is extracting full content...")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(accentGold.opacity(0.8))
                                .padding(.top, 10)

                            Button(action: { viewMode = .web }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                    Text("Switch to Web View (W)")
                                }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(accentBlue)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                        }
                        .padding(.top, 20)
                    }
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 70)
                .padding(.top, -40)
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onTapGesture {} // Prevents clicks from passing through to the window and triggering the title bar bug
    }

    private var webViewContainer: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 84)

            if isWebLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(accentPink)
                    .frame(height: 2)
            } else {
                Divider()
                    .opacity(0.2)
            }

            if let url = URL(string: currentArticle.link) {
                ArticleWebView(url: url, isLoading: $isWebLoading, canGoBack: $webCanGoBack, canGoForward: $webCanGoForward)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Invalid article URL")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topToolbar: some View {
        HStack(spacing: 12) {
            toolbarButton(icon: "chevron.left") { if !path.isEmpty { path.removeLast() } }
                .help("Back to list (Esc or ←)")
            Spacer()

            if !allArticles.isEmpty {
                toolbarButton(icon: "arrow.up") { prevArticle() }
                    .help("Previous Article (K or ↑)")
                toolbarButton(icon: "arrow.down") { nextArticle() }
                    .help("Next Article (J or ↓)")
            }

            Picker("", selection: $viewMode) {
                Label("Reader", systemImage: "doc.plaintext").tag(DetailViewMode.reader)
                Label("Web", systemImage: "safari").tag(DetailViewMode.web)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("Toggle Reader / Web view (W)")

            toolbarButton(icon: isSaved ? "bookmark.fill" : "bookmark") {
                if isSaved { savedStories.remove(currentArticle) } else { savedStories.save(currentArticle) }
            }
            .help("Save Story (S)")
        
            if let url = URL(string: currentArticle.link) {
                ShareLink(item: url, subject: Text(currentArticle.title), message: Text(currentArticle.title)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(textPrimary)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Menu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentArticle.link, forType: .string)
                } label: { Label("Copy Link", systemImage: "link") }
                Button {
                    if let url = URL(string: currentArticle.link) { NSWorkspace.shared.open(url) }
                } label: { Label("Open in Browser", systemImage: "safari") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundColor(textPrimary).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .background(
            viewMode == .web
                ? AnyView(Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .top))
                : AnyView(Color.clear)
        )
    }

    private func toolbarButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundColor(textPrimary).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func contentParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
