// ArticleDetailView.swift
// NewsApp Article Detail Reading Experience & Native Toolbar

import SwiftUI
import AppKit

enum DetailViewMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case web = "Web"
    var id: String { rawValue }
}

enum ArticleContentState: Equatable {
    case loading
    case ready
    case fallback(reason: String)
}

struct ArticleDetailView: View {
    @State private var activeArticle: FeedArticle
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
    @State private var webLoadError: String?
    @State private var webAction: WebNavigationAction? = nil

    @State private var analysis: ArticleAnalysis? = nil
    @State private var isAnalyzing: Bool = false
    @State private var analysisError: String? = nil
    @State private var summaryExpanded = false
    @State private var reloadGeneration = 0
    @State private var readerTextScale: CGFloat = 1
    @State private var contentState: ArticleContentState = .loading

    @FocusState private var isViewFocused: Bool

    init(article: FeedArticle, allArticles: [FeedArticle] = [], path: Binding<NavigationPath>) {
        self._activeArticle = State(initialValue: article)
        self.allArticles = allArticles
        self._path = path
    }

    private var currentArticle: FeedArticle {
        articleStore.articles.first { $0.id == activeArticle.id }
            ?? articleStore.savedArticles.first { $0.id == activeArticle.id }
            ?? activeArticle
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
        Group {
            // Content Layer
            if viewMode == .reader {
                readerView.id(activeArticle.id)
            } else {
                webViewContainer
            }

        }
        .background(AppColor.background)
        .softScrollEdge()
        .toolbar { readerToolbar }
        .toolbarBackground(.visible, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($isViewFocused)
        .onKeyPress { press in
            handleKeyPress(press: press)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextArticleCommand)) { _ in nextArticle() }
        .onReceive(NotificationCenter.default.publisher(for: .prevArticleCommand)) { _ in prevArticle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleReadCommand)) { _ in
            readManager.toggleRead(currentArticle.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSaveCommand)) { _ in
            toggleSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInBrowserCommand)) { _ in
            openInBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleViewModeCommand)) { _ in
            viewMode = (viewMode == .reader) ? .web : .reader
        }
        .task(id: "\(activeArticle.id):\(reloadGeneration)") {
            await ensureContentExtracted(forceRefresh: reloadGeneration > 0)
        }
        .task(id: summaryExpanded ? activeArticle.id : nil) {
            guard summaryExpanded else { return }
            await startArticleAnalysis()
        }
        .onAppear { isViewFocused = true }
    }

    // MARK: - Reader View

    private var readerView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 2. Editorial Content Hierarchy: Eyebrow -> Title -> AI Summary -> Body -> Terminal Affordance
                VStack(alignment: .leading, spacing: 18) {
                    // Eyebrow: Source, Date, Reading Time
                    HStack(spacing: 6) {
                        Text(displaySource.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.1)
                            .foregroundColor(AppColor.accent)

                        Text("·")
                            .foregroundColor(AppColor.tertiaryText)

                        Text(currentArticle.publicationDateText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColor.secondaryText)

                        Text("·")
                            .foregroundColor(AppColor.tertiaryText)

                        Text(readingTimeEstimate)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColor.secondaryText)
                    }

                    // Headline
                    Text(currentArticle.title)
                        .font(AppTypography.titleFont(for: themeManager.articleTheme, scale: readerTextScale))
                        .foregroundColor(AppColor.primaryText)
                        .lineSpacing(3)

                    // On-device AI Analysis Section
                    heroImageHeader

                    if appSettings.aiEnabled || currentArticle.aiSummary != nil {
                        DisclosureGroup("On-device summary", isExpanded: $summaryExpanded) {
                            aiAnalysisSection.padding(.top, AppSpacing.sm)
                        }
                        .font(AppTypography.bodySmall)
                        .foregroundStyle(AppColor.secondaryText)
                        .disabled(contentState == .loading)
                    }

                    Divider()

                    // Article Content Section with explicit state handling
                    switch contentState {
                    case .loading:
                        loadingStateView
                        articleDescriptionParagraphs
                    case .ready:
                        articleContentParagraphs
                    case .fallback(let reason):
                        fallbackStateView(reason: reason)
                    }

                    // Terminal Affordance: "Read original article on <source>"
                    terminalAffordance


                }
                .padding(.horizontal, AppLayout.pageInset)
                .padding(.vertical, AppSpacing.xl)
                .frame(maxWidth: 700 * min(readerTextScale, 1.3), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .softScrollEdge()

    }

    @ViewBuilder
    private var heroImageHeader: some View {
        if let imageUrl = currentArticle.readerDocument?.selectedImage(fallback: currentArticle.imageUrl) ?? (currentArticle.readerDocument == nil ? currentArticle.imageUrl : nil), let url = URL(string: imageUrl),
           currentArticle.readerDocument?.blocks.contains(where: { $0.kind == .figure && $0.imageURL == imageUrl }) != true {
            let candidate = currentArticle.readerDocument?.images?.first { $0.url == imageUrl }
            ReaderFigureView(block: ReaderBlock(kind: .figure, text: candidate?.caption ?? "",
                imageURL: imageUrl, imageAlt: candidate?.alt, imageCredit: candidate?.credit,
                imageWidth: candidate?.width, imageHeight: candidate?.height), url: url, textScale: readerTextScale)
        }
    }

    private var displayParagraphs: [String] {
        if let content = currentArticle.fullContent, !content.isEmpty {
            return ArticleContentRedactor.redactAndSplit(content)
        }
        return ArticleContentRedactor.redactAndSplit(currentArticle.description)
    }

    private var readingTimeEstimate: String {
        let text = currentArticle.fullContent ?? currentArticle.description
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let minutes = max(1, Int(ceil(Double(words) / 200.0)))
        return "\(minutes) min read"
    }

    private var loadingStateView: some View {
        HStack(spacing: AppSpacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading full article…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppSpacing.lg)
    }

    private func fallbackStateView(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColor.secondaryText)
                Text("Full article unavailable in reader")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColor.primaryText)
                Spacer()
                Button {
                    reloadGeneration += 1
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewMode = .web
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                        Text("Open Web View (W)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(AppColor.secondaryText)

            Divider().opacity(0.15)

            Text(currentArticle.fullContent == nil ? "FEED SUMMARY PREVIEW" : "PREVIOUSLY SAVED TEXT")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundColor(AppColor.tertiaryText)

            articleDescriptionParagraphs
        }
        .padding(16)
        .background(AppColor.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColor.borderSubtle, lineWidth: 1))
    }

    @ViewBuilder
    private var articleDescriptionParagraphs: some View {
        let paragraphs = displayParagraphs
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
                    .foregroundColor(AppColor.primaryText.opacity(0.9))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                    .textSelection(.enabled)
            }
        }
    }

    private var articleContentParagraphs: some View {
        let storedBlocks = currentArticle.readerDocument?.blocks ?? []
        let blocks = storedBlocks.isEmpty ? displayParagraphs.map {
            ReaderBlock(kind: .paragraph, text: $0)
        } : storedBlocks
        return VStack(alignment: .leading, spacing: AppSpacing.lg * readerTextScale) {
            // Positions are stable within the immutable, article-keyed reader document.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                readerBlock(block, isLead: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func readerBlock(_ block: ReaderBlock, isLead: Bool) -> some View {
        switch block.kind {
        case .figure:
            if let imageURL = block.imageURL, let url = URL(string: imageURL) {
                ReaderFigureView(block: block, url: url, textScale: readerTextScale)
            }
        case .heading, .subheading:
            Text(readerText(block))
                .font(.system(size: (block.kind == .heading ? 22 : 15) * readerTextScale, weight: block.kind == .heading ? .bold : .semibold))
                .foregroundStyle(AppColor.primaryText)
                .padding(.top, AppSpacing.md)
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
        case .quote:
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Rectangle().fill(AppColor.accent.opacity(0.5)).frame(width: 3)
                Text(readerText(block))
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale).italic())
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, AppSpacing.xs)
        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Text(block.ordinal.map { "\($0)." } ?? "•")
                    .foregroundStyle(AppColor.secondaryText)
                Text(readerText(block)).textSelection(.enabled)
            }
            .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
            .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
        case .code:
            Text(readerText(block))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.control))
        case .paragraph:
            Text(readerText(block))
                .font(isLead ? AppTypography.leadFont(for: themeManager.articleTheme, scale: readerTextScale) : AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
                .foregroundStyle(AppColor.primaryText)
                .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func summaryTag(_ text: String, emphasized: Bool = false) -> some View {
        Text(text)
            .font(AppTypography.label)
            .foregroundStyle(emphasized ? AppColor.accent : AppColor.secondaryText)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 6)
            .background(emphasized ? AppColor.accent.opacity(0.10) : AppColor.badgeBackground,
                        in: RoundedRectangle(cornerRadius: AppRadius.control))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var terminalAffordance: some View {
        VStack(spacing: AppSpacing.md) {
            Divider()
                .opacity(0.15)
                .padding(.vertical, AppSpacing.sm)

            HStack(spacing: AppSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Read original article on \(displaySource)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColor.primaryText)
                    if let host = URL(string: currentArticle.link)?.host {
                        Text(host)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColor.secondaryText)
                    }
                }

                Spacer()

                Button {
                    viewMode = .web
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                        Text("Open Web View (W)")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColor.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppColor.surface.opacity(0.85))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Open Web View (W)")

                if URL(string: currentArticle.link) != nil {
                    Button {
                        openInBrowser()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right")
                            Text("External")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppColor.surface.opacity(0.6))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Open in default web browser (O)")
                }
            }
        }
        .padding(.top, AppSpacing.sm)
    }

    // MARK: - Web View Container

    private var webViewContainer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Protected preview · Scripts disabled")
                Spacer()
                Button("Open interactive page in browser") { openInBrowser() }
            }
            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            .padding(AppSpacing.sm)
            if let webLoadError {
                HStack {
                    Label(webLoadError, systemImage: "exclamationmark.triangle")
                    Button("Reload") { webAction = .reload }
                }
                .font(AppTypography.bodySmall)
                .padding(AppSpacing.sm)
            }
            if isWebLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppColor.accent)
                    .frame(height: 2)
            } else {
                Divider().opacity(0.15)
            }

            if let url = URL(string: currentArticle.link) {
                ArticleWebView(
                    url: url,
                    allowHTTP: appSettings.allowInsecureHTTP,
                    isLoading: $isWebLoading,
                    canGoBack: $webCanGoBack,
                    canGoForward: $webCanGoForward,
                    action: $webAction,
                    loadError: $webLoadError
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: AppSpacing.sm) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(AppColor.secondaryText)
                    Text("Invalid article URL")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColor.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Native Reader Toolbar

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                if !path.isEmpty { path.removeLast() }
            } label: {
                Label("Back to articles", systemImage: "chevron.left")
            }
            .help("Back to articles (Esc)")

            Button(action: prevArticle) {
                Label("Previous article", systemImage: "chevron.up")
            }
            .disabled(!hasPrevArticle)
            .help("Previous article (K)")

            Button(action: nextArticle) {
                Label("Next article", systemImage: "chevron.down")
            }
            .disabled(!hasNextArticle)
            .help("Next article (J)")
        }
        ToolbarItemGroup(placement: .principal) {
            Toggle(isOn: Binding(get: { viewMode == .reader }, set: { if $0 { viewMode = .reader } })) {
                Label("Reader", systemImage: "doc.richtext")
            }
            .toggleStyle(.button)
            .help("Read extracted article (W)")
            Toggle(isOn: Binding(get: { viewMode == .web }, set: { if $0 { viewMode = .web } })) {
                Label("Web", systemImage: "globe")
            }
            .toggleStyle(.button)
            .help("View publisher website (W)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if viewMode == .web {
                Button { webAction = .goBack } label: {
                    Label("Browser back", systemImage: "arrow.left")
                }
                .disabled(!webCanGoBack)
                Button { webAction = .goForward } label: {
                    Label("Browser forward", systemImage: "arrow.right")
                }
                .disabled(!webCanGoForward)
            }
            Button(action: toggleSave) {
                Label(isSaved ? "Remove from Saved Stories" : "Save Story",
                      systemImage: isSaved ? "bookmark.fill" : "bookmark")
            }
            .help(isSaved ? "Remove from Saved Stories (S)" : "Save Story (S)")

            if let url = URL(string: currentArticle.link) {
                ShareLink(item: url, subject: Text(currentArticle.title)) {
                    Label("Share story", systemImage: "square.and.arrow.up")
                }
            }
            Menu {
                Picker("Text size", selection: $readerTextScale) {
                    Text("Standard").tag(CGFloat(1))
                    Text("Large").tag(CGFloat(1.25))
                    Text("Extra large").tag(CGFloat(1.5))
                }
                Picker("Reading style", selection: $themeManager.articleTheme) {
                    ForEach(ArticleThemeType.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                Divider()
                Button("Reload reader content", systemImage: "arrow.clockwise") {
                    summaryExpanded = false
                    analysis = nil
                    reloadGeneration += 1
                }
                .disabled(contentState == .loading)
                Button("Copy link", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentArticle.link, forType: .string)
                }
                Button("Open in browser", systemImage: "safari", action: openInBrowser)
            } label: {
                Label("Reading options", systemImage: "textformat.size")
            }
            .help("Reading style and article actions")
        }
    }

    // MARK: - Navigation & Actions

    private func nextArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx + 1 < allArticles.count else { return }
        resetReaderState()
        let next = allArticles[idx + 1]
        activeArticle = next
        readManager.markAsRead(next.id)
    }

    private func prevArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx > 0 else { return }
        resetReaderState()
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
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        if press.key == .escape {
            if !path.isEmpty { path.removeLast() }
            return .handled
        }
        if press.characters == "b" || press.characters == "h" {
            if !path.isEmpty { path.removeLast() }
            return .handled
        } else if press.characters == "j" {
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

    private var displaySource: String {
        (currentArticle.source.components(separatedBy: "\n").first ?? currentArticle.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayCategory: String? {
        let raw = analysis?.category ?? currentArticle.category
        guard let raw = raw, !raw.isEmpty else { return nil }
        let firstLine = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return nil }
        if let matched = NewsCategory.match(from: firstLine) {
            return matched.rawValue
        }
        return nil
    }

    // MARK: - AI Analysis UI (Restrained & Semantic)

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
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        } else if let analysis = analysis {
            VStack(alignment: .leading, spacing: 14) {
                // Section Header: Restrained Summary
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(AppColor.intelligence)
                    Text(analysis.modelIdentifier == "apple.natural-language.fallback" ? "Extractive summary" : "AI-generated summary")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColor.primaryText)
                }

                Text(analysis.summary)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(AppColor.primaryText.opacity(0.92))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))

                // Key Takeaways
                if !analysis.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key Takeaways")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppColor.secondaryText)
                            .padding(.top, 2)

                        ForEach(analysis.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(AppColor.intelligence.opacity(0.8))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                                Text(point)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColor.primaryText.opacity(0.88))
                            }
                        }
                    }
                }

                ReaderTagLayout(spacing: AppSpacing.xs) {
                    if let category = displayCategory {
                        summaryTag(category, emphasized: true)
                    }
                    ForEach(EntityResult.readerTags(from: analysis.entities).prefix(6), id: \.name) { entity in
                        summaryTag(entity.name)
                    }
                }
                if let sentiment = analysis.sentiment {
                    Label("\(sentiment.label) language · automated estimate", systemImage: "text.magnifyingglass")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
            .padding(14)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        } else if let error = analysisError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(AppColor.warning)
                Text("AI analysis unavailable: \(error)")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.secondaryText)
                Spacer()
                Button("Close summary") {
                    summaryExpanded = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        } else if let ai = currentArticle.aiSummary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(AppColor.intelligence)
                    Text("AI-generated summary")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColor.primaryText)
                }

                Text(ai)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(AppColor.primaryText.opacity(0.92))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
            }
            .padding(14)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    // MARK: - Independent Extraction & Analysis

    private func ensureContentExtracted(forceRefresh: Bool = false) async {
        if !forceRefresh, currentArticle.readerDocument.map({ (1...ReaderDocument.currentVersion).contains($0.version) }) == true,
           let existing = currentArticle.fullContent, !ArticleContentRedactor.redactAndSplit(existing).isEmpty {
            contentState = .ready
            return
        }

        let link = currentArticle.link
        guard !link.isEmpty, let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else {
            contentState = .fallback(reason: "Invalid article URL")
            return
        }
        let allowInsecure = appSettings.allowInsecureHTTP
        let targetId = currentArticle.id

        guard !Task.isCancelled else { return }
        contentState = .loading

        do {
            let extraction = await ContentExtractionPipeline.shared.extractArticleWithIdentity(
                from: link,
                allowHTTP: allowInsecure
            )
            guard !Task.isCancelled, activeArticle.id == targetId else { return }

            switch extraction.outcome {
            case .success(let content, let imageUrl, let extractedDocument):
                var document = extractedDocument
                if let extractedDocument {
                    document = extractedDocument.curated(feedImage: currentArticle.imageUrl, title: currentArticle.title)
                    do {
                        let repeated = try await articleStore.database.repeatedImageURLs(source: currentArticle.source)
                        try Task.checkCancellation()
                        guard activeArticle.id == targetId else { return }
                        document = document?.curated(feedImage: nil, title: currentArticle.title, excluding: repeated)
                    } catch is CancellationError { return }
                    catch { /* Recurrence is optional; protected images still use local filters. */ }
                }
                await articleStore.updateEnrichment(
                    id: targetId,
                    content: content,
                    image: imageUrl,
                    readerDocument: document,
                    identityEvidence: extraction.evidence
                )
                guard !Task.isCancelled, activeArticle.id == targetId else { return }
                var updated = self.activeArticle
                updated.fullContent = content
                updated.readerDocument = document
                updated.contentFetched = true
                updated.imageUrl = document?.selectedImage(fallback: imageUrl) ?? (document == nil ? imageUrl : nil)
                self.activeArticle = updated
                self.contentState = .ready
            case .qualityValidationFailed(let reason):
                self.contentState = .fallback(reason: "Article quality check not met: \(reason)")
            case .httpError(let status):
                self.contentState = .fallback(reason: "Publisher returned HTTP \(status)")
            case .securityBlocked(let reason):
                self.contentState = .fallback(reason: "Security policy: \(reason)")
            case .emptyContent:
                self.contentState = .fallback(reason: "Publisher returned empty content")
            case .contentParsingFailed(let reason):
                self.contentState = .fallback(reason: "Could not extract article body: \(reason)")
            case .networkError(let reason):
                self.contentState = .fallback(reason: "Network error: \(reason)")
            }
        }
    }

    private func startArticleAnalysis() async {
        guard !Task.isCancelled else { return }
        let targetID = activeArticle.id
        analysisError = nil
        isAnalyzing = false

        // Preserve persisted model identity and analysis version.
        if let cached = await articleStore.fetchArticleAnalysis(for: activeArticle.id), cached.analysisVersion >= 2 {
            guard !Task.isCancelled, activeArticle.id == targetID else { return }
            self.analysis = cached
            return
        }

        // Analysis runs only after the summary is explicitly opened.
        guard !Task.isCancelled, activeArticle.id == targetID, appSettings.aiEnabled else { return }

        isAnalyzing = true
        let targetArticle = currentArticle

        do {
            try Task.checkCancellation()

            var contentToAnalyze = targetArticle.fullContent ?? ""
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
            guard !Task.isCancelled, activeArticle.id == targetArticle.id else { return }
            self.analysis = result
            self.isAnalyzing = false
        } catch is CancellationError {
            // The replacement article owns the current UI state.
        } catch {
            if !Task.isCancelled, activeArticle.id == targetID {
                self.analysisError = error.localizedDescription
                self.isAnalyzing = false
            }
        }
    }

    private func resetReaderState() {
        summaryExpanded = false
        analysis = nil
        analysisError = nil
        isAnalyzing = false
        contentState = .loading
        reloadGeneration = 0
        webLoadError = nil
        webAction = nil
        webCanGoBack = false
        webCanGoForward = false
    }
}

/// Tags keep their natural width and wrap instead of disappearing in a horizontal scroller.
private struct ReaderTagLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, item) in layout.items.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.minX, y: bounds.minY + item.minY),
                                 proposal: ProposedViewSize(item.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let width = width.isFinite ? max(1, width) : 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var items: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), items)
    }
}


/// Whole-image fit plus a fixed ratio keeps known media stable before loading.
struct ReaderFigureView: View {
    let block: ReaderBlock
    let url: URL
    var textScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ArticleRemoteImage(url: url) { phase in
                ZStack {
                    AppColor.surface
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                            .accessibilityLabel(block.imageAlt ?? "Article image")
                    case .failure:
                        Label("Image unavailable", systemImage: "photo").foregroundStyle(AppColor.secondaryText)
                    case .empty:
                        ProgressView().accessibilityLabel("Loading article image")
                    @unknown default: EmptyView()
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            }
            if !block.text.isEmpty {
                Text(block.text).font(.system(size: 11 * textScale)).foregroundStyle(AppColor.secondaryText).textSelection(.enabled)
            }
            if let credit = block.imageCredit, !credit.isEmpty {
                Text(credit).font(.system(size: 11 * textScale)).foregroundStyle(AppColor.secondaryText).textSelection(.enabled)
                    .accessibilityLabel("Image credit: " + credit)
            }
            Text("Image source: " + (url.host ?? "Publisher"))
                .font(.system(size: 11 * textScale)).foregroundStyle(AppColor.secondaryText).textSelection(.enabled)
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = block.imageWidth, let height = block.imageHeight, width > 0, height > 0 else { return 1.5 }
        return min(3, max(0.4, CGFloat(width) / CGFloat(height)))
    }
}

func readerText(_ block: ReaderBlock) -> AttributedString {
    guard let runs = block.inlineRuns, runs.map(\.text).joined() == block.text else { return AttributedString(block.text) }
    var text = AttributedString()
    for run in runs {
        var part = AttributedString(run.text)
        if run.strong { part.inlinePresentationIntent = .stronglyEmphasized }
        if run.emphasis { part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.emphasized) }
        if run.code { part.inlinePresentationIntent = (part.inlinePresentationIntent ?? []).union(.code) }
        if let link = ContentExtractionPipeline.readerImageURL(run.link, baseURL: nil) { part.link = URL(string: link) }
        text.append(part)
    }
    return text
}
