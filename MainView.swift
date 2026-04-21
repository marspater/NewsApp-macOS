import SwiftUI
import AppKit

// MARK: - P3 Wide Gamut Color Palette

private let accentPink = Color(.displayP3, red: 1.0, green: 0.22, blue: 0.50, opacity: 1.0)
private let accentGold = Color(.displayP3, red: 1.0, green: 0.84, blue: 0.35, opacity: 1.0)
private let accentBlue = Color(.displayP3, red: 0.30, green: 0.55, blue: 1.0, opacity: 1.0)
private let surfaceDark = Color(.displayP3, red: 0.08, green: 0.08, blue: 0.10, opacity: 1.0)
private let surfaceMid = Color(.displayP3, red: 0.12, green: 0.13, blue: 0.15, opacity: 1.0)
private let textPrimary = Color(.displayP3, red: 0.95, green: 0.95, blue: 0.97, opacity: 1.0)
private let textSecondary = Color(.displayP3, red: 0.65, green: 0.65, blue: 0.70, opacity: 1.0)
private let textTertiary = Color(.displayP3, red: 0.45, green: 0.45, blue: 0.50, opacity: 1.0)

// MARK: - Navigation Wrapper

struct FeedArticleWrap: Identifiable, Hashable {
    let id = UUID()
    let article: FeedArticle
}

// MARK: - Main View

struct MainView: View {
    @State private var selectedTopic: String? = "Today"
    @EnvironmentObject private var feedManager: FeedManager
    @StateObject private var savedStories = SavedStoriesManager.shared
    @State private var searchText: String = ""
    @State private var isSubscribePopoverPresented = false
    @State private var newFeedURL: String = ""
    @State private var articlePath = NavigationPath()
    @State private var isRefreshing = false

    private var filteredArticles: [FeedArticle] {
        var result: [FeedArticle]
        if let topic = selectedTopic {
            if topic == "Saved Stories" {
                result = savedStories.savedArticles
            } else {
                result = feedManager.articles(for: topic)
            }
        } else {
            result = feedManager.articles
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.source.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
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
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
            .padding(.bottom, 6)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            NavigationLink(value: "Today") {
                Label("Today", systemImage: "newspaper.fill")
            }
            .listRowBackground(
                selectedTopic == "Today"
                    ? AnyView(accentPink.opacity(0.8).cornerRadius(8))
                    : AnyView(Color.clear)
            )

            Section("Library") {
                NavigationLink(value: "Saved Stories") {
                    Label {
                        HStack {
                            Text("Saved Stories")
                            if !savedStories.savedArticles.isEmpty {
                                Text("\(savedStories.savedArticles.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(textPrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(accentPink.opacity(0.6))
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "bookmark.fill")
                    }
                }
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
                        Button(role: .destructive) {
                            feedManager.removeSection(section)
                        } label: {
                            Label("Remove Section", systemImage: "minus.circle")
                        }
                    }
                }
            }

            Section("Suggested") {
                ForEach(suggestedTopics, id: \.0) { topic, icon in
                    if !feedManager.userSections.contains(topic) {
                        Button {
                            feedManager.addSection(topic)
                        } label: {
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isSubscribePopoverPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .popover(isPresented: $isSubscribePopoverPresented) {
                    subscribePopover
                }
            }
        }
    }

    private var subscribePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscribe to RSS Feed")
                .font(.headline)
            TextField("https://example.com/feed", text: $newFeedURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") {
                    isSubscribePopoverPresented = false
                }
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

                        if isRefreshing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .padding(.trailing, 4)
                        }

                        Button {
                            isRefreshing = true
                            feedManager.fetchFeeds()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                isRefreshing = false
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(textSecondary)
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 30)
                    .padding(.bottom, 16)

                    ScrollView {
                        if filteredArticles.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: selectedTopic == "Today" ? "newspaper" : (selectedTopic == "Saved Stories" ? "bookmark" : "tray"))
                                    .font(.system(size: 40))
                                    .foregroundColor(textTertiary)
                                Text(emptyStateText)
                                    .foregroundColor(textTertiary)
                                    .font(.system(size: 15))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else {
                            // In Saved Stories, show delete option
                            if selectedTopic == "Saved Stories" {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                                    ForEach(filteredArticles) { article in
                                        ArticleCardView(article: article) {
                                            articlePath.append(FeedArticleWrap(article: article))
                                        }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                savedStories.remove(article)
                                            } label: {
                                                Label("Remove from Saved", systemImage: "bookmark.slash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.bottom, 30)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                                    ForEach(filteredArticles) { article in
                                        ArticleCardView(article: article) {
                                            articlePath.append(FeedArticleWrap(article: article))
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.bottom, 30)
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: FeedArticleWrap.self) { wrap in
                ArticleDetailView(article: wrap.article, path: $articlePath)
                    .navigationBarBackButtonHidden(true)
                    .environmentObject(savedStories)
            }
        }
        .onAppear {
            if feedManager.articles.isEmpty {
                feedManager.fetchFeeds()
            }
        }
    }

    private var emptyStateText: String {
        switch selectedTopic {
        case "Today": return "No articles available"
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
}

// MARK: - Article Card

struct ArticleCardView: View {
    let article: FeedArticle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let imageUrl = article.imageUrl, let url = URL(string: imageUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 240)
                                .clipped()
                        default:
                            Rectangle().fill(surfaceMid)
                                .frame(height: 240)
                        }
                    }
                } else {
                    Rectangle().fill(surfaceMid)
                        .frame(height: 240)
                }

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.85)],
                    startPoint: .center, endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text((article.source.components(separatedBy: "\n").first ?? article.source).trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(accentPink)
                        .tracking(0.8)

                    Text(article.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(textPrimary)
                        .lineLimit(2)
                        .shadow(radius: 3)

                    if let ai = article.aiSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                            Text(ai)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(accentGold)
                    }

                    Text(article.description)
                        .font(.system(size: 12))
                        .foregroundColor(textPrimary.opacity(0.7))
                        .lineLimit(2)
                }
                .padding(16)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Article Detail View

struct ArticleDetailView: View {
    let article: FeedArticle
    @Binding var path: NavigationPath
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var savedStories: SavedStoriesManager

    private var currentArticle: FeedArticle {
        feedManager.articles.first { $0.id == article.id } ?? article
    }

    private var isSaved: Bool {
        savedStories.isSaved(currentArticle)
    }

    var body: some View {
        ZStack(alignment: .top) {
            surfaceDark.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Hero image
                    ZStack(alignment: .bottom) {
                        if let imageUrl = currentArticle.imageUrl, let url = URL(string: imageUrl) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(maxWidth: .infinity, maxHeight: 480)
                                        .clipped()
                                default:
                                    surfaceMid
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 480)
                                }
                            }
                        }

                        LinearGradient(
                            colors: [surfaceDark.opacity(0), surfaceDark.opacity(0.4), surfaceDark],
                            startPoint: .center, endPoint: .bottom
                        )
                        .frame(height: 200)
                    }

                    // Article body — selectable text
                    VStack(alignment: .leading, spacing: 20) {
                        // Title
                        Text(currentArticle.title)
                            .font(.system(size: 38, weight: .bold, design: .serif))
                            .foregroundColor(textPrimary)
                            .lineSpacing(4)
                            .textSelection(.enabled)

                        // Metadata
                        Text("\((currentArticle.source.components(separatedBy: "\n").first ?? currentArticle.source).trimmingCharacters(in: .whitespacesAndNewlines)) · \(currentArticle.pubDate.formatted(date: .long, time: .omitted))")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(textSecondary)
                            .textSelection(.enabled)

                        // AI Insight
                        if let ai = currentArticle.aiSummary {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(accentGold)
                                    .padding(.top, 3)
                                Text(ai)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(accentGold)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(accentGold.opacity(0.2), lineWidth: 0.5)
                                    )
                            )
                        }

                        // Full article content — selectable
                        if currentArticle.contentFetched {
                            if let content = currentArticle.fullContent, !content.isEmpty {
                                ForEach(contentParagraphs(content), id: \.self) { paragraph in
                                    Text(paragraph)
                                        .font(.system(size: 20, weight: .regular, design: .serif))
                                        .foregroundColor(textPrimary.opacity(0.87))
                                        .lineSpacing(10)
                                        .textSelection(.enabled)
                                }
                            } else {
                                Text(currentArticle.description)
                                    .font(.system(size: 20, weight: .regular, design: .serif))
                                    .foregroundColor(textPrimary.opacity(0.87))
                                    .lineSpacing(10)
                                    .textSelection(.enabled)
                            }
                        } else {
                            HStack {
                                Spacer()
                                VStack(spacing: 10) {
                                    ProgressView()
                                        .scaleEffect(1.2)
                                    Text("Loading full article...")
                                        .font(.system(size: 13))
                                        .foregroundColor(textTertiary)
                                }
                                .padding(.top, 40)
                                Spacer()
                            }
                        }

                        Spacer().frame(height: 80)
                    }
                    .padding(.horizontal, 70)
                    .padding(.top, -40)
                    .frame(maxWidth: 860, alignment: .leading)
                }
            }
            .ignoresSafeArea(edges: .top)

            // Floating toolbar — all icons same size and style
            HStack(spacing: 12) {
                toolbarButton(icon: "chevron.left") {
                    if !path.isEmpty { path.removeLast() }
                }

                Spacer()

                // Save to stories
                toolbarButton(icon: isSaved ? "bookmark.fill" : "bookmark") {
                    if isSaved {
                        savedStories.remove(currentArticle)
                    } else {
                        savedStories.save(currentArticle)
                    }
                }

                // Share
                toolbarButton(icon: "square.and.arrow.up") {
                    shareArticle()
                }

                // More options
                Menu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(currentArticle.link, forType: .string)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    Button {
                        if let url = URL(string: currentArticle.link) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(textPrimary)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
        }
        .toolbar(.hidden)
    }

    /// Consistent toolbar button — all same size/opacity
    private func toolbarButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(textPrimary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func shareArticle() {
        let items: [Any] = [
            currentArticle.title,
            URL(string: currentArticle.link) as Any
        ].compactMap { $0 }

        let picker = NSSharingServicePicker(items: items)
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    private func contentParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
