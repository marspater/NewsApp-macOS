// ArticleDetailView.swift
// NewsApp Article Detail Reading Experience & Floating Glass Controls

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

@MainActor
final class TrackpadSwipeCoordinator: ObservableObject {
    nonisolated(unsafe) private var monitor: Any? = nil
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?
    var isEnabled: Bool = false
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isEnabled else { return event }
            guard event.hasPreciseScrollingDeltas else { return event }

            if event.phase == .began {
                self.accX = 0
                self.accY = 0
            } else if event.phase == .changed {
                self.accX += event.scrollingDeltaX
                self.accY += event.scrollingDeltaY

                let dir = TrackpadSwipeEvaluator.evaluate(deltaX: self.accX, deltaY: self.accY, threshold: 60)
                if dir == .previous {
                    self.accX = 0
                    self.accY = 0
                    self.onSwipeRight?()
                } else if dir == .next {
                    self.accX = 0
                    self.accY = 0
                    self.onSwipeLeft?()
                }
            } else if event.phase == .ended || event.phase == .cancelled {
                self.accX = 0
                self.accY = 0
            }
            return event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewMode: DetailViewMode = .reader
    @State private var isWebLoading: Bool = false
    @State private var webCanGoBack: Bool = false
    @State private var webCanGoForward: Bool = false
    @State private var webAction: WebNavigationAction? = nil

    @State private var analysis: ArticleAnalysis? = nil
    @State private var isAnalyzing: Bool = false
    @State private var analysisError: String? = nil
    @State private var analysisTask: Task<Void, Never>? = nil
    @State private var extractionTask: Task<Void, Never>? = nil
    @State private var contentState: ArticleContentState = .loading

    // Toolbar & Scroll interaction states
    @State private var readingProgress: CGFloat = 0.0
    @State private var isToolbarCompacted: Bool = false
    @State private var isToolbarHovered: Bool = false
    @State private var articleScrollPositions: [String: CGFloat] = [:]
    @StateObject private var swipeCoordinator = TrackpadSwipeCoordinator()

    init(article: FeedArticle, allArticles: [FeedArticle] = [], path: Binding<NavigationPath>) {
        self._activeArticle = State(initialValue: article)
        self.allArticles = allArticles
        self._path = path
    }

    private var currentArticle: FeedArticle {
        articleStore.articles.first { $0.id == activeArticle.id }
            ?? feedManager.articles.first { $0.id == activeArticle.id }
            ?? allArticles.first { $0.id == activeArticle.id }
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
        ZStack(alignment: .top) {
            AppColor.background.ignoresSafeArea()

            // Content Layer
            if viewMode == .reader {
                readerView
            } else {
                webViewContainer
            }

            // Navigation / Controls Layer: Floating Liquid Glass Toolbar
            topGlassToolbar
                .zIndex(100)
        }
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
            cancelTasks()
            readingProgress = 0.0
            isToolbarCompacted = false
            await ensureContentExtracted()
            await startArticleAnalysis()
        }
        .onAppear {
            configureSwipeCoordinator()
        }
        .onChange(of: viewMode) { _, newMode in
            swipeCoordinator.isEnabled = (newMode == .reader && !reduceMotion)
        }
        .onDisappear {
            swipeCoordinator.stop()
            cancelTasks()
        }
    }

    private func configureSwipeCoordinator() {
        swipeCoordinator.onSwipeRight = { [self] in
            // Standard macOS swipe-back: return to article list
            if !path.isEmpty {
                withAnimation(reduceMotion ? .none : .spring(response: 0.35, dampingFraction: 0.85)) {
                    path.removeLast()
                }
            }
        }
        // Swiping horizontally left in reader mode is deactivated to prevent accidental article jumps.
        // Article pagination remains fully accessible via keyboard (J/K, ↓/↑) and toolbar chevrons.
        swipeCoordinator.onSwipeLeft = nil
        swipeCoordinator.isEnabled = (viewMode == .reader && !reduceMotion)
        swipeCoordinator.start()
    }

    // MARK: - Reader View

    private var readerView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 1. Hero Image Layer with smooth atmospheric blend into background
                heroImageHeader

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

                        Text(currentArticle.pubDate.formatted(date: .abbreviated, time: .omitted))
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
                        .font(AppTypography.titleFont(for: themeManager.articleTheme))
                        .foregroundColor(AppColor.primaryText)
                        .lineSpacing(3)

                    // On-device AI Analysis Section
                    aiAnalysisSection

                    // Article Content Section with explicit state handling
                    switch contentState {
                    case .loading:
                        loadingStateView
                    case .ready:
                        articleContentParagraphs
                    case .fallback(let reason):
                        fallbackStateView(reason: reason)
                    }

                    // Terminal Affordance: "Read original article on <source>"
                    terminalAffordance

                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 40)
                .padding(.top, currentArticle.imageUrl != nil ? 18 : (AppLayout.toolbarHeight + 68))
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, newOffset in
            let shouldCompact = newOffset > 150
            if shouldCompact != isToolbarCompacted {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isToolbarCompacted = shouldCompact
                }
            }
            articleScrollPositions[activeArticle.id] = newOffset
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            let scrollable = geo.contentSize.height - geo.containerSize.height
            return scrollable > 20 ? min(max(0, geo.contentOffset.y / scrollable), 1.0) : 0.0
        } action: { _, newProgress in
            readingProgress = newProgress
        }
    }

    @ViewBuilder
    private var heroImageHeader: some View {
        if let imageUrl = currentArticle.imageUrl, let url = URL(string: imageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: 330)
                        .clipped()
                        .overlay(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .clear, location: 0.45),
                                    .init(color: AppColor.background.opacity(0.35), location: 0.70),
                                    .init(color: AppColor.background.opacity(0.85), location: 0.90),
                                    .init(color: AppColor.background, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                default:
                    EmptyView()
                }
            }
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
                    Task { await ensureContentExtracted() }
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

            Text("FEED SUMMARY PREVIEW")
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
        let paragraphs = ArticleContentRedactor.redactAndSplit(currentArticle.description)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme))
                    .foregroundColor(AppColor.primaryText.opacity(0.9))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var articleContentParagraphs: some View {
        let paragraphs = displayParagraphs
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                Text(paragraph)
                    .font(index == 0 ? AppTypography.leadFont(for: themeManager.articleTheme) : AppTypography.bodyFont(for: themeManager.articleTheme))
                    .foregroundColor(AppColor.primaryText.opacity(index == 0 ? 0.95 : 0.88))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                    .textSelection(.enabled)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
            Spacer().frame(height: AppLayout.toolbarHeight + 20)

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
                    isLoading: $isWebLoading,
                    canGoBack: $webCanGoBack,
                    canGoForward: $webCanGoForward,
                    action: $webAction
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

    // MARK: - Single Unified Liquid Glass Toolbar

    private var topGlassToolbar: some View {
        HStack(spacing: 12) {
            // 1. Back Button
            Button {
                if !path.isEmpty { path.removeLast() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                    Text("Back")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(AppColor.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back to articles (Esc, Delete, or ←)")
            .accessibilityLabel("Back to articles")

            // 2. Web Mode Browser History Back / Forward
            if viewMode == .web {
                HStack(spacing: 4) {
                    Button {
                        webAction = .goBack
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(webCanGoBack ? AppColor.primaryText : AppColor.tertiaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!webCanGoBack)
                    .help("Browser History Back")

                    Button {
                        webAction = .goForward
                    } label: {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(webCanGoForward ? AppColor.primaryText : AppColor.tertiaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!webCanGoForward)
                    .help("Browser History Forward")
                }
            }

            Divider()
                .frame(height: 16)
                .opacity(0.3)

            // 3. Article Paging (in reader mode)
            if !allArticles.isEmpty {
                HStack(spacing: 2) {
                    Button {
                        prevArticle()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(hasPrevArticle ? AppColor.primaryText : AppColor.tertiaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(!hasPrevArticle)
                    .help("Previous Article (K or ↑)")

                    Button {
                        nextArticle()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(hasNextArticle ? AppColor.primaryText : AppColor.tertiaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(!hasNextArticle)
                    .help("Next Article (J or ↓)")
                }

                Divider()
                    .frame(height: 16)
                    .opacity(0.3)
            }

            // 4. View Mode Segmented Switcher
            Picker("", selection: $viewMode) {
                Label("Reader", systemImage: "doc.plaintext").tag(DetailViewMode.reader)
                Label("Web", systemImage: "safari").tag(DetailViewMode.web)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .focusable(false)
            .help("Toggle Reader / Web view (W)")

            Divider()
                .frame(height: 16)
                .opacity(0.3)

            // 5. Actions: Bookmark, Share, Menu
            HStack(spacing: 6) {
                Button {
                    toggleSave()
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSaved ? AppColor.accent : AppColor.primaryText)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .help("Save Story (S)")

                if let url = URL(string: currentArticle.link) {
                    ShareLink(item: url, subject: Text(currentArticle.title)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColor.primaryText)
                            .frame(width: 26, height: 24)
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
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frostedPill(elevation: .control)
        .overlay(alignment: .bottom) {
            if readingProgress > 0.01 {
                GeometryReader { proxy in
                    Capsule()
                        .fill(AppColor.accent)
                        .frame(width: max(8, proxy.size.width * readingProgress), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
        .opacity(isToolbarCompacted && !isToolbarHovered ? 0.92 : 1.0)
        .onHover { isToolbarHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isToolbarCompacted)
        .animation(.easeInOut(duration: 0.15), value: isToolbarHovered)
        .padding(.top, 56)
    }

    // MARK: - Navigation & Actions

    private func nextArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx + 1 < allArticles.count else { return }
        cancelTasks()
        let next = allArticles[idx + 1]
        activeArticle = next
        readManager.markAsRead(next.id)
    }

    private func prevArticle() {
        guard !allArticles.isEmpty,
              let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
              idx > 0 else { return }
        cancelTasks()
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
        case .escape, .leftArrow, .delete:
            if !path.isEmpty { path.removeLast() }
            return .handled
        case .downArrow:
            nextArticle()
            return .handled
        case .upArrow:
            prevArticle()
            return .handled
        default:
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
        if firstLine.count > 24 {
            return String(firstLine.prefix(24)) + "…"
        }
        return firstLine
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
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.container))
        } else if let analysis = analysis {
            VStack(alignment: .leading, spacing: 14) {
                // Section Header: Restrained Summary
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(AppColor.intelligence)
                    Text("Summary")
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

                // Entity tags, sentiment badge, category pill
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let sentiment = analysis.sentiment {
                            HStack(spacing: 4) {
                                Image(systemName: sentiment.score >= 0.1 ? "hand.thumbsup.fill" : (sentiment.score <= -0.1 ? "hand.thumbsdown.fill" : "minus.circle.fill"))
                                    .font(.system(size: 10))
                                Text(sentiment.label)
                                    .font(.caption2.bold())
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(AppColor.surface))
                            .foregroundColor(AppColor.secondaryText)
                        }

                        if let cat = displayCategory {
                            Text(cat)
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(AppColor.accent.opacity(0.12)))
                                .foregroundColor(AppColor.accent)
                        }

                        ForEach(analysis.entities.prefix(4), id: \.name) { entity in
                            let name = entity.name.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !name.isEmpty {
                                Text(name)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(AppColor.surface))
                                    .foregroundColor(AppColor.secondaryText)
                            }
                        }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(AppColor.intelligence)
                    Text("Summary")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColor.primaryText)
                }

                Text(ai)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(AppColor.primaryText.opacity(0.92))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
            }
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: AppRadius.container))
        }
    }

    // MARK: - Independent Extraction & Analysis

    private func ensureContentExtracted() async {
        if let existing = currentArticle.fullContent, !existing.isEmpty {
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

        contentState = .loading

        extractionTask = Task { @MainActor in
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(
                from: link,
                allowHTTP: allowInsecure
            )
            guard !Task.isCancelled else { return }

            switch outcome {
            case .success(let content, let imageUrl):
                await articleStore.updateEnrichment(
                    id: targetId,
                    content: content,
                    image: imageUrl
                )
                var updated = self.activeArticle
                updated.fullContent = content
                updated.contentFetched = true
                if let img = imageUrl, updated.imageUrl == nil {
                    updated.imageUrl = img
                }
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
        await extractionTask?.value
    }

    private func startArticleAnalysis() async {
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

        analysisTask = Task { @MainActor in
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

    private func cancelTasks() {
        extractionTask?.cancel()
        extractionTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }
}
