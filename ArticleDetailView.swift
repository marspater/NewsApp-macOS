// ArticleDetailView.swift
// NewsApp Article Detail Reading Experience & Floating Glass Controls

import SwiftUI
import AppKit

enum DetailViewMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case web = "Web"
    var id: String { rawValue }
}

struct ArticleDetailView: View {
    @State var activeArticle: FeedArticle
    let allArticles: [FeedArticle]
    @Binding var path: NavigationPath
    
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var themeManager: ThemeManager
    
    @State private var viewMode: DetailViewMode = .reader
    @State private var isWebLoading: Bool = false
    @State private var webCanGoBack: Bool = false
    @State private var webCanGoForward: Bool = false
    @State private var analysis: ArticleAnalysis? = nil
    @State private var isAnalyzing: Bool = false
    @State private var analysisError: String? = nil
    @State private var analysisTask: Task<Void, Never>? = nil
    
    init(article: FeedArticle, allArticles: [FeedArticle] = [], path: Binding<NavigationPath>) {
        self._activeArticle = State(initialValue: article)
        self.allArticles = allArticles
        self._path = path
    }
    
    private var currentArticle: FeedArticle {
        allArticles.first { $0.id == activeArticle.id } ?? activeArticle
    }
    
    private var isSaved: Bool {
        savedStories.isSaved(currentArticle)
    }
    
    private var currentArticleIndex: Int? {
        allArticles.firstIndex(where: { $0.id == activeArticle.id })
    }
    
    private var hasPrevArticle: Bool {
        guard let idx = currentArticleIndex else { return false }
        return idx > 0
    }
    
    private var hasNextArticle: Bool {
        guard let idx = currentArticleIndex else { return false }
        return idx + 1 < allArticles.count
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            AppColor.background.ignoresSafeArea()
            
            // Content Layer: Flat, clear, readable reading experience
            if viewMode == .reader {
                readerView
            } else {
                webViewContainer
            }
            
            // Navigation / Controls Layer: Floating Liquid Glass controls
            topGlassToolbar
        }
        .focusable()
        .onKeyPress { press in
            handleKeyPress(press: press)
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailNextArticle)) { _ in nextArticle() }
        .onReceive(NotificationCenter.default.publisher(for: .detailPrevArticle)) { _ in prevArticle() }
        .onReceive(NotificationCenter.default.publisher(for: .detailToggleRead)) { _ in
            readManager.toggleRead(currentArticle.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailToggleSave)) { _ in
            toggleSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailOpenInBrowser)) { _ in
            openInBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(for: .detailToggleViewMode)) { _ in
            viewMode = (viewMode == .reader ? .web : .reader)
        }
        .task(id: activeArticle.id) {
            await startArticleAnalysis()
        }
        .onDisappear {
            cancelAnalysis()
        }
    }
    
    // MARK: - Reader View
    
    private var readerView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero Image Layer
                heroImageHeader
                
                // Article Typography & Content
                VStack(alignment: .leading, spacing: 20) {
                    Text(currentArticle.title)
                        .font(AppTypography.titleFont(for: themeManager.articleTheme))
                        .foregroundColor(AppColor.primaryText)
                    
                    Text("\(displaySource) · \(currentArticle.pubDate.formatted(date: .long, time: .omitted))")
                        .font(.system(
                            size: 13,
                            weight: .medium,
                            design: themeManager.articleTheme == .alto ? .monospaced : .default
                        ))
                        .foregroundColor(AppColor.secondaryText)
                        .tracking(AppTypography.sourceEyebrowTracking)
                    
                    aiAnalysisSection
                    
                    if currentArticle.contentFetched {
                        articleContentParagraphs
                    } else {
                        contentLoadingSkeleton
                    }
                    
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 48)
                .padding(.top, 24)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onTapGesture {}
    }
    
    @ViewBuilder
    private var heroImageHeader: some View {
        if let imageUrl = currentArticle.imageUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipped()
                        .overlay(
                            LinearGradient(
                                colors: [Color.clear, AppColor.background.opacity(0.85), AppColor.background],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                        )
                default:
                    EmptyView()
                }
            }
        }
    }
    
    @ViewBuilder
    private var articleContentParagraphs: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let content = currentArticle.fullContent, !content.isEmpty {
                ForEach(contentParagraphs(content), id: \.self) { paragraph in
                    Text(paragraph)
                        .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                        .foregroundColor(AppColor.primaryText.opacity(0.88))
                        .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                }
            } else {
                Text(currentArticle.description)
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                    .foregroundColor(AppColor.primaryText.opacity(0.88))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                
                Button {
                    viewMode = .web
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "safari")
                        Text("Open Web View (W)")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.primaryText)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 8)
                    .glassPill(interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpacing.sm)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    
    private var contentLoadingSkeleton: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)
            ForEach(0..<3) { _ in
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(AppColor.tertiaryText.opacity(0.2))
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
            }
            .phaseAnimator([0.5, 1.0]) { content, phase in
                content.opacity(phase)
            }
            
            Text("AI is extracting full content...")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(AppColor.intelligence.opacity(0.85))
                .padding(.top, 10)
            
            Button {
                viewMode = .web
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Switch to Web View (W)")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColor.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.top, 20)
    }
    
    // MARK: - Web View Container
    
    private var webViewContainer: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: AppLayout.toolbarHeight + 16)
            
            if isWebLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppColor.accent)
                    .frame(height: 2)
            } else {
                Divider().opacity(0.2)
            }
            
            if let url = URL(string: currentArticle.link) {
                ArticleWebView(
                    url: url,
                    isLoading: $isWebLoading,
                    canGoBack: $webCanGoBack,
                    canGoForward: $webCanGoForward
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: AppSpacing.sm) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(AppColor.textSecondary)
                    Text("Invalid article URL")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColor.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Top Floating Glass Toolbar
    
    private var topGlassToolbar: some View {
        HStack(spacing: AppSpacing.sm) {
            // 1. Navigation Group: Back Button
            Button {
                if !path.isEmpty { path.removeLast() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Done")
                        .font(AppTypography.label)
                }
                .foregroundColor(AppColor.primaryText)
                .padding(.horizontal, 10)
                .frame(height: AppLayout.controlHeight + 4)
                .glassPill(interactive: true)
            }
            .buttonStyle(.plain)
            .help("Back to list (Esc or ←)")
            
            Spacer()
            
            // 2. Center Group: Paging & Mode Switcher
            HStack(spacing: 8) {
                if !allArticles.isEmpty {
                    HStack(spacing: 0) {
                        Button {
                            prevArticle()
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(hasPrevArticle ? AppColor.primaryText : AppColor.tertiaryText)
                                .frame(width: 28, height: AppLayout.controlHeight + 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasPrevArticle)
                        .help("Previous Article (K or ↑)")
                        
                        Divider().frame(height: 14)
                        
                        Button {
                            nextArticle()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(hasNextArticle ? AppColor.primaryText : AppColor.tertiaryText)
                                .frame(width: 28, height: AppLayout.controlHeight + 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasNextArticle)
                        .help("Next Article (J or ↓)")
                    }
                    .glassPill(interactive: true)
                }
                
                Picker("", selection: $viewMode) {
                    Label("Reader", systemImage: "doc.plaintext").tag(DetailViewMode.reader)
                    Label("Web", systemImage: "safari").tag(DetailViewMode.web)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .help("Toggle Reader / Web view (W)")
            }
            
            Spacer()
            
            // 3. Action Group: Bookmark, Share, Menu
            HStack(spacing: 2) {
                Button {
                    toggleSave()
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSaved ? AppColor.accent : AppColor.primaryText)
                        .frame(width: 32, height: AppLayout.controlHeight + 4)
                }
                .buttonStyle(.plain)
                .help("Save Story (S)")
                
                if let url = URL(string: currentArticle.link) {
                    ShareLink(item: url, subject: Text(currentArticle.title)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColor.primaryText)
                            .frame(width: 32, height: AppLayout.controlHeight + 4)
                    }
                    .buttonStyle(.plain)
                    .help("Share Story")
                }
                
                Menu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(currentArticle.link, forType: .string)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    
                    Button {
                        openInBrowser()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColor.primaryText)
                        .frame(width: 32, height: AppLayout.controlHeight + 4)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .glassPill(interactive: true)
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .inGlassContainer()
    }
    
    // MARK: - Navigation & Actions
    
    private func nextArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx + 1 < allArticles.count else { return }
        cancelAnalysis()
        let next = allArticles[idx + 1]
        activeArticle = next
        readManager.markAsRead(next.id)
    }
    
    private func prevArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx > 0 else { return }
        cancelAnalysis()
        let prev = allArticles[idx - 1]
        activeArticle = prev
        readManager.markAsRead(prev.id)
    }
    
    private func toggleSave() {
        if isSaved {
            savedStories.remove(currentArticle)
        } else {
            savedStories.save(currentArticle)
        }
    }
    
    private func openInBrowser() {
        if let url = URL(string: currentArticle.link) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
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
                toggleSave()
                return .handled
            } else if press.characters == "o" {
                openInBrowser()
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
    
    private var displaySource: String {
        (currentArticle.source.components(separatedBy: "\n").first ?? currentArticle.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func contentParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - AI Analysis & Key Points UI

    @ViewBuilder
    private var aiAnalysisSection: some View {
        if isAnalyzing {
            HStack(spacing: AppSpacing.xs) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                Text("Analyzing article with on-device AI...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.intelligence)
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.container))
        } else if let analysis = analysis {
            VStack(alignment: .leading, spacing: 14) {
                // 1-Paragraph Summary
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Image(systemName: "sparkles")
                        .foregroundColor(AppColor.intelligence)
                        .padding(.top, 3)
                    Text(analysis.summary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColor.primaryText)
                }

                // 3 to 5 Bullet Key Points
                if !analysis.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.clipboard")
                                .foregroundColor(AppColor.intelligence)
                            Text("Key Takeaways")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(AppColor.primaryText)
                        }
                        .padding(.top, 4)

                        ForEach(analysis.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColor.intelligence)
                                    .padding(.top, 3)
                                Text(point)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColor.primaryText.opacity(0.9))
                            }
                        }
                    }
                }

                // Entity tags, sentiment badge, category pill
                HStack(spacing: 8) {
                    if let sentiment = analysis.sentiment {
                        HStack(spacing: 4) {
                            Image(systemName: sentiment.score >= 0.1 ? "hand.thumbsup.fill" : (sentiment.score <= -0.1 ? "hand.thumbsdown.fill" : "minus.circle.fill"))
                                .font(.system(size: 10))
                            Text(sentiment.label)
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppColor.surface))
                        .foregroundColor(AppColor.secondaryText)
                    }

                    ForEach(analysis.entities.prefix(4), id: \.name) { entity in
                        Text(entity.name)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppColor.surface))
                            .foregroundColor(AppColor.secondaryText)
                    }

                    if let cat = analysis.category ?? currentArticle.category {
                        Text(cat)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppColor.accent.opacity(0.12)))
                            .foregroundColor(AppColor.accent)
                    }
                }
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.container))
        } else if let error = analysisError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(AppColor.warning)
                Text("AI analysis unavailable: \(error)")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.secondaryText)
                Spacer()
                Button("Try Again") {
                    Task { await startArticleAnalysis() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.container))
        } else if let ai = currentArticle.aiSummary {
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundColor(AppColor.intelligence)
                Text(ai)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColor.primaryText)
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.container))
        }
    }

    // MARK: - On-Demand Interactive Analysis Lifecycle

    private func startArticleAnalysis() async {
        cancelAnalysis()
        analysisError = nil

        // 1. Check if article already has analysis loaded
        if let keyPoints = currentArticle.keyPoints, !keyPoints.isEmpty,
           let summary = currentArticle.aiSummary {
            self.analysis = ArticleAnalysis(
                summary: summary,
                keyPoints: keyPoints,
                entities: currentArticle.entities ?? [],
                category: currentArticle.category,
                sentiment: currentArticle.sentimentLabel.map {
                    SentimentResult(score: currentArticle.sentimentScore ?? 0.0, confidence: 0.9, label: $0)
                },
                modelIdentifier: "cached",
                analysisVersion: 1
            )
            return
        }

        // 2. Check persistent database for existing analysis
        if let cached = await articleStore.fetchArticleAnalysis(for: activeArticle.id) {
            self.analysis = cached
            return
        }

        // 3. Lazy interactive analysis if enabled
        guard appSettings.aiEnabled else { return }

        isAnalyzing = true
        let targetArticle = currentArticle
        let allowInsecure = appSettings.allowInsecureHTTP

        analysisTask = Task { @MainActor in
            do {
                try Task.checkCancellation()

                // Extract web content if needed
                var contentToAnalyze = targetArticle.fullContent ?? ""
                if contentToAnalyze.isEmpty {
                    let extracted = await ContentExtractionPipeline.shared.extractArticle(
                        from: targetArticle.link,
                        allowHTTP: allowInsecure
                    )
                    try Task.checkCancellation()
                    if let content = extracted.content, !content.isEmpty {
                        contentToAnalyze = content
                        await articleStore.updateEnrichment(
                            id: targetArticle.id,
                            content: content,
                            image: extracted.imageUrl
                        )
                    }
                }

                if contentToAnalyze.isEmpty {
                    contentToAnalyze = targetArticle.description
                }

                try Task.checkCancellation()

                let result = try await ArticleAnalyzer.shared.analyze(
                    title: targetArticle.title,
                    content: contentToAnalyze,
                    category: targetArticle.category
                )

                try Task.checkCancellation()

                await articleStore.saveArticleAnalysis(result, for: targetArticle.id)
                self.analysis = result
                self.isAnalyzing = false
            } catch is CancellationError {
                self.isAnalyzing = false
            } catch {
                if !Task.isCancelled {
                    self.analysisError = error.localizedDescription
                    self.isAnalyzing = false
                }
            }
        }
        await analysisTask?.value
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }
}
