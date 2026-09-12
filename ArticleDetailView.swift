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
        feedManager.articles.first { $0.id == activeArticle.id } ?? activeArticle
    }
    
    private var isSaved: Bool {
        savedStories.isSaved(currentArticle)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            AppColor.surfaceDark.ignoresSafeArea()
            
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
                        .foregroundColor(AppColor.textPrimary)
                    
                    Text("\(displaySource) · \(currentArticle.pubDate.formatted(date: .long, time: .omitted))")
                        .font(.system(
                            size: 15,
                            weight: .semibold,
                            design: themeManager.articleTheme == .alto ? .monospaced : .default
                        ))
                        .foregroundColor(AppColor.accentPink)
                        .tracking(AppTypography.sectionHeaderTracking)
                        .textCase(.uppercase)
                    
                    aiAnalysisSection
                    
                    if currentArticle.contentFetched {
                        articleContentParagraphs
                    } else {
                        contentLoadingSkeleton
                    }
                    
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 70)
                .padding(.top, -40)
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .highPriorityGesture(TapGesture().onEnded { _ in })
    }
    
    private var heroImageHeader: some View {
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
                        AppColor.surfaceMid.frame(maxWidth: .infinity).frame(height: 480)
                    }
                }
            }
            LinearGradient(
                colors: [AppColor.surfaceDark.opacity(0), AppColor.surfaceDark.opacity(0.4), AppColor.surfaceDark],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 200)
        }
    }
    
    @ViewBuilder
    private var articleContentParagraphs: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let content = currentArticle.fullContent, !content.isEmpty {
                ForEach(contentParagraphs(content), id: \.self) { paragraph in
                    Text(paragraph)
                        .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                        .foregroundColor(AppColor.textPrimary.opacity(0.88))
                        .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                }
            } else {
                Text(currentArticle.description)
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                    .foregroundColor(AppColor.textPrimary.opacity(0.88))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                
                Button {
                    viewMode = .web
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "safari")
                        Text("Open Web View (W)")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(AppColor.accentPink))
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
                    .fill(AppColor.textTertiary.opacity(0.2))
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
            }
            .phaseAnimator([0.5, 1.0]) { content, phase in
                content.opacity(phase)
            }
            
            Text("AI is extracting full content...")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(AppColor.accentGold.opacity(0.85))
                .padding(.top, 10)
            
            Button {
                viewMode = .web
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Switch to Web View (W)")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColor.accentBlue)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.top, 20)
    }
    
    // MARK: - Web View Container
    
    private var webViewContainer: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 84)
            
            if isWebLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppColor.accentPink)
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
                        .font(.system(size: 14, weight: .medium))
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
            toolbarGlassButton(icon: "chevron.left", help: "Back to list (Esc or ←)") {
                if !path.isEmpty { path.removeLast() }
            }
            
            Spacer()
            
            if !allArticles.isEmpty {
                toolbarGlassButton(icon: "arrow.up", help: "Previous Article (K or ↑)") {
                    prevArticle()
                }
                toolbarGlassButton(icon: "arrow.down", help: "Next Article (J or ↓)") {
                    nextArticle()
                }
            }
            
            Picker("", selection: $viewMode) {
                Label("Reader", systemImage: "doc.plaintext").tag(DetailViewMode.reader)
                Label("Web", systemImage: "safari").tag(DetailViewMode.web)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("Toggle Reader / Web view (W)")
            
            toolbarGlassButton(
                icon: isSaved ? "bookmark.fill" : "bookmark",
                help: "Save Story (S)"
            ) {
                toggleSave()
            }
            
            if let url = URL(string: currentArticle.link) {
                ShareLink(
                    item: url,
                    subject: Text(currentArticle.title),
                    message: Text(currentArticle.title)
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AppColor.textPrimary)
                        .frame(width: 38, height: 38)
                        .liquidGlass(in: Circle(), interactive: true)
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, 40)
        .padding(.bottom, AppSpacing.sm)
        .inGlassContainer()
    }
    
    private func toolbarGlassButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(AppColor.textPrimary)
                .frame(width: 38, height: 38)
                .liquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
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
                    .foregroundColor(AppColor.accentGold)
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.bubble))
        } else if let analysis = analysis {
            VStack(alignment: .leading, spacing: 14) {
                // 1-Paragraph Summary
                HStack(alignment: .top, spacing: AppSpacing.xs) {
                    Image(systemName: "sparkles")
                        .foregroundColor(AppColor.accentGold)
                        .padding(.top, 3)
                    Text(analysis.summary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColor.accentGold)
                }

                // 3 to 5 Bullet Key Points
                if !analysis.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.clipboard")
                                .foregroundColor(AppColor.accentGold)
                            Text("Key Takeaways")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(AppColor.textPrimary)
                        }
                        .padding(.top, 4)

                        ForEach(analysis.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColor.accentGold)
                                    .padding(.top, 3)
                                Text(point)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColor.textPrimary.opacity(0.9))
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
                        .background(Capsule().fill(AppColor.accentPink.opacity(0.2)))
                        .foregroundColor(AppColor.accentPink)
                    }

                    ForEach(analysis.entities.prefix(4), id: \.name) { entity in
                        Text(entity.name)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppColor.surfaceMid))
                            .foregroundColor(AppColor.textSecondary)
                    }

                    if let cat = analysis.category ?? currentArticle.category {
                        Text(cat)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppColor.accentBlue.opacity(0.2)))
                            .foregroundColor(AppColor.accentBlue)
                    }
                }
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.bubble))
        } else if let error = analysisError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("AI analysis unavailable: \(error)")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.textSecondary)
                Spacer()
                Button("Try Again") {
                    Task { await startArticleAnalysis() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.bubble))
        } else if let ai = currentArticle.aiSummary {
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundColor(AppColor.accentGold)
                Text(ai)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColor.accentGold)
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.bubble))
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
