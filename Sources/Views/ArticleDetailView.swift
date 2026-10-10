// ArticleDetailView.swift
// NewsApp Article Detail Reading Experience & Native Toolbar

import AppKit
import SwiftUI

enum DetailViewMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case web = "Web"
    var id: String { rawValue }
}

/// The reader's toolbar modes: the event overview (events only), the extracted story, or the publisher's page.
enum ReaderMode: Hashable {
    case overview
    case story
    case web

    static let webShortcut: KeyEquivalent = "r"
    static let webShortcutModifiers: EventModifiers = [.command, .shift]
    var toggledPublicationMode: ReaderMode { self == .web ? .story : .web }

    /// W steps through the modes the toolbar offers, in its order: Overview (events only), Story, Web.
    func next(hasOverview: Bool) -> ReaderMode {
        switch self {
        case .overview: return .story
        case .story: return .web
        case .web: return hasOverview ? .overview : .story
        }
    }
}

/// Window-scoped bindings and actions let menu commands operate on the same reader as its toolbar.
struct ReaderCommandActions {
    let mode: Binding<ReaderMode>
    let textScale: Binding<CGFloat>
    let showReadingOptions: () -> Void
    let hasOverview: Bool
    let back: () -> Void
    let reload: (() -> Void)?
    let copyLink: () -> Void
    let webBack: (() -> Void)?
    let webForward: (() -> Void)?
}

private struct ReaderCommandActionsKey: FocusedValueKey { typealias Value = ReaderCommandActions }
private struct SelectedStoryKey: FocusedValueKey { typealias Value = FeedArticle }

extension FocusedValues {
    var readerActions: ReaderCommandActions? {
        get { self[ReaderCommandActionsKey.self] }
        set { self[ReaderCommandActionsKey.self] = newValue }
    }
    var selectedStory: FeedArticle? {
        get { self[SelectedStoryKey.self] }
        set { self[SelectedStoryKey.self] = newValue }
    }
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
    @Environment(\.effectiveContrast) private var contrast
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    @State private var viewMode: DetailViewMode = .reader
    @State private var isWebLoading: Bool = false
    @State private var webCanGoBack: Bool = false
    @State private var webCanGoForward: Bool = false
    @State private var webLoadError: String?
    @State private var webAction: WebNavigationAction? = nil

    @State private var publisherRevisions: [PublisherContentRevision] = []
    @State private var publisherUpdatesExpanded = false
    @State private var analysis: ArticleAnalysis? = nil
    @State private var isAnalyzing: Bool = false
    @State private var analysisError: String? = nil
    @State private var summaryExpanded = false
    @State private var reloadGeneration = 0
    @State private var showsReadingOptions = false
    @State private var textScaleOverride: CGFloat?
    @Namespace private var storyParagraphs

    private var readerTextScale: CGFloat {
        textScaleOverride ?? themeManager.readerTextScale
    }
    private var readerTextScaleBinding: Binding<CGFloat> {
        Binding(
            get: { readerTextScale },
            set: {
                themeManager.readerTextScale = $0
                textScaleOverride = nil
            }
        )
    }
    @State private var contentState: ArticleContentState = .loading

    @State private var experienceMode: ReaderExperienceMode = .sourcePublication
    @State private var currentOverview: EventOverviewDocument? = nil
    @State private var highlightedPassage: String? = nil
    @State private var eventMemberArticles: [FeedArticle] = []
    @State private var isOverviewLoading: Bool = false
    /// Identifies this reader to the overview coordinator, so closing it never clears another reader's event.
    @State private var overviewOwner = UUID()

    @FocusState private var isViewFocused: Bool
    @FocusState private var readingOptionsFocused: Bool

    init(
        article: FeedArticle,
        allArticles: [FeedArticle] = [],
        path: Binding<NavigationPath>,
        overview: EventOverviewDocument? = nil,
        initialExperienceMode: ReaderExperienceMode? = nil
    ) {
        self._activeArticle = State(initialValue: article)
        self.allArticles = allArticles
        self._path = path
        self._currentOverview = State(initialValue: overview)
        self._textScaleOverride = State(
            initialValue: SystemSettingsOverrides.from().textScale.map(ReaderTextSize.normalized))
        if let mode = initialExperienceMode {
            self._experienceMode = State(initialValue: mode)
        } else if overview != nil {
            self._experienceMode = State(initialValue: .eventOverview)
        } else {
            self._experienceMode = State(initialValue: .sourcePublication)
        }
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

    private var readerCommandActions: ReaderCommandActions {
        ReaderCommandActions(
            mode: readerModeBinding, textScale: readerTextScaleBinding,
            showReadingOptions: { showsReadingOptions = true }, hasOverview: currentOverview != nil,
            back: { if !path.isEmpty { path.removeLast() } },
            reload: contentState == .loading ? nil : { reloadReaderContent() },
            copyLink: copyStoryLink,
            webBack: readerModeBinding.wrappedValue == .web && webCanGoBack ? { webAction = .goBack } : nil,
            webForward: readerModeBinding.wrappedValue == .web && webCanGoForward ? { webAction = .goForward } : nil
        )
    }

    var body: some View {
        contentLayer
            .background(AppColor.background)
            .navigationTitle(displaySource)
            .toolbar(removing: .title)
            .toolbar { readerToolbar }
            .focusedSceneValue(\.selectedStory, currentArticle)
            .focusedSceneValue(\.readerActions, readerCommandActions)
            .focusable()
            .focusEffectDisabled()
            .focused($isViewFocused)
            .onKeyPress { press in
                handleKeyPress(press: press)
            }
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                }
            }
            .modifier(
                ArticleNavigationCommands(
                    onNextArticle: nextArticle,
                    onPrevArticle: prevArticle,
                    onToggleRead: { readManager.toggleRead(currentArticle.id) },
                    onToggleSave: toggleSave,
                    onOpenInBrowser: openInBrowser
                )
            )
            // Publisher-input changes invalidate the stored overview; request it again from current inputs.
            .task(id: "\(activeArticle.id):\(currentArticle.publisherInputHash)") {
                await loadEventOverviewForActiveArticle()
            }
            .task(id: activeArticleContentTaskID) {
                await refreshActiveArticleFromStore()
                await ensureContentExtracted(forceRefresh: reloadGeneration > 0)
            }
            .task(id: summaryExpanded ? "\(activeArticle.id):\(currentArticle.publisherInputHash)" : nil) {
                guard summaryExpanded else { return }
                await startArticleAnalysis()
            }
            .task(id: "\(activeArticle.id):\(articleStore.revision)") {
                let id = activeArticle.id
                let revisions = try? await articleStore.database.publisherContentRevisions(for: id)
                guard !Task.isCancelled, activeArticle.id == id else { return }
                publisherRevisions = revisions ?? []
            }
            .onChange(of: activeArticle.id) { _, _ in
                publisherUpdatesExpanded = false
            }
            .onChange(of: currentArticle.publisherInputHash) { _, _ in
                analysis = nil
                analysisError = nil
                isAnalyzing = false
                // Keep the overview mode so the regenerated overview returns by itself.
                currentOverview = nil
            }
            .onAppear { isViewFocused = true }
            .onDisappear {
                let owner = overviewOwner
                Task {
                    await OverviewGenerationCoordinator.shared.clearVisibleEvent(owner: owner)
                }
            }
    }

    private var contentLayer: some View {
        Group {
            // Content Layer: descendants enable focus effects for their own interactive controls
            if experienceMode == .eventOverview, let overview = currentOverview {
                EventOverviewReaderView(
                    overview: overview,
                    memberArticles: eventMemberArticles.isEmpty ? [currentArticle] : eventMemberArticles,
                    textScale: readerTextScale,
                    onSelectArticle: { article in
                        activeArticle = article
                        highlightedPassage = nil
                        experienceMode = .sourcePublication
                    },
                    onSelectCitation: { citation, article in
                        if let article = article {
                            activeArticle = article
                        }
                        highlightedPassage = citation.quote
                        experienceMode = .sourcePublication
                    }
                )
                .id(overview.id)
                .focusEffectDisabled(false)
            } else if viewMode == .reader {
                readerView
                    .id(activeArticle.id)
                    .focusEffectDisabled(false)
            } else {
                webViewContainer
                    .focusEffectDisabled(false)
            }
        }
    }

    private var activeArticleContentTaskID: String {
        "\(activeArticle.id):\(reloadGeneration)"
    }

    // MARK: - Reader View

    private var readerView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 2. Editorial Content Hierarchy: Eyebrow -> Title -> AI Summary -> Body -> Terminal Affordance
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    // Highlighted passage cited in Event Overview
                    if let passage = highlightedPassage {
                        NoticeView(tint: AppColor.accent) {
                            HStack(alignment: .top, spacing: AppSpacing.xs) {
                                HStack(alignment: .top, spacing: AppSpacing.xs) {
                                    Image(systemName: "quote.bubble.fill")
                                        .font(AppTypography.body)
                                        .foregroundColor(AppColor.accent)
                                        .padding(.top, AppSpacing.textStack)
                                        .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                        Text("Cited in Event Overview")
                                            .font(AppTypography.eyebrow)
                                            .foregroundColor(AppColor.accent)

                                        Text("“\(passage)”")
                                            .font(AppTypography.readerCitation)
                                            .foregroundColor(AppColor.primaryText)
                                            .lineSpacing(AppSpacing.textStack)
                                            .textSelection(.enabled)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Cited passage in event overview: \(passage)")

                                Spacer()

                                Button {
                                    if reduceMotion {
                                        highlightedPassage = nil
                                    } else {
                                        withAnimation(Self.readerAnimation(reduceMotion: reduceMotion)) {
                                            highlightedPassage = nil
                                        }
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(AppTypography.body)
                                        .foregroundColor(AppColor.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .buttonBorderShape(.circle)
                                .help("Dismiss citation highlight")
                                .accessibilityLabel("Dismiss citation highlight")
                            }
                        }
                    }

                    // Eyebrow: Source, Date, Reading Time
                    HStack(spacing: AppSpacing.eyebrowGap) {
                        EyebrowText(displaySource, color: AppColor.accent)

                        Text("·")
                            .foregroundColor(tertiaryText)

                        Text(currentArticle.publicationDateText)
                            .font(AppTypography.label)
                            .foregroundColor(AppColor.secondaryText)

                        Text("·")
                            .foregroundColor(tertiaryText)

                        Text(readingTimeEstimate)
                            .font(AppTypography.label)
                            .foregroundColor(AppColor.secondaryText)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Self.sourceLineAccessibilityLabel(
                            source: displaySource,
                            publicationDateText: currentArticle.publicationDateText,
                            readingTimeEstimate: readingTimeEstimate
                        ))

                    // Headline
                    Text(currentArticle.title)
                        .font(AppTypography.titleFont(for: themeManager.articleTheme, scale: readerTextScale))
                        .foregroundColor(AppColor.primaryText)
                        .lineSpacing(3)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHeading(.h1)
                        .textSelection(.enabled)

                    publisherUpdates

                    // On-device AI Analysis Section
                    heroImageHeader

                    if appSettings.aiEnabled || currentArticle.aiSummary != nil {
                        DisclosureGroup("On-device summary", isExpanded: summaryExpandedBinding) {
                            aiAnalysisSection.padding(.top, AppSpacing.sm)
                        }
                        .font(AppTypography.body)
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
                .modifier(ReadingColumn(textScale: readerTextScale))
            }
        }
    }

    @ViewBuilder
    private var publisherUpdates: some View {
        let updates = publisherRevisions.filter { $0.kind == .publisherUpdate }
        if let latest = updates.first {
            DisclosureGroup(
                "Publisher updated · \(latest.observedAt.formatted(date: .abbreviated, time: .shortened))",
                isExpanded: $publisherUpdatesExpanded
            ) {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Changes observed on this Mac. An update is not a verified correction.")
                    ForEach(updates) { revision in
                        Text(
                            "Version \(revision.version) · \(revision.changeDescription) · \(revision.observedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                    }
                }
                .font(AppTypography.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, AppSpacing.sm)
            }
            .font(AppTypography.caption)
            .foregroundStyle(AppColor.secondaryText)
        }
    }

    @ViewBuilder
    private var heroImageHeader: some View {
        if let imageUrl = currentArticle.readerDocument?.selectedImage(fallback: currentArticle.imageUrl)
            ?? (currentArticle.readerDocument == nil ? currentArticle.imageUrl : nil), let url = URL(string: imageUrl),
            currentArticle.readerDocument?.blocks.contains(where: { $0.kind == .figure && $0.imageURL == imageUrl })
                != true
        {
            let candidate = currentArticle.readerDocument?.images?.first { $0.url == imageUrl }
            ReaderFigureView(
                block: ReaderBlock(
                    kind: .figure, text: candidate?.caption ?? "",
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
            Text("Loading full story…")
                .font(AppTypography.label)
                .foregroundColor(AppColor.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading full story")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppSpacing.lg)
    }

    private func fallbackStateView(reason: String) -> some View {
        NoticeView {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppTypography.sectionTitle)
                        .foregroundColor(AppColor.secondaryText)
                        .accessibilityHidden(true)
                    Text("Full story unavailable in reader")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColor.primaryText)
                    Spacer()
                    Button {
                        reloadGeneration += 1
                    } label: {
                        HStack(spacing: AppSpacing.xxs) {
                            Image(systemName: "arrow.clockwise")
                                .accessibilityHidden(true)
                            Text("Retry")
                        }
                        .font(AppTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        viewMode = .web
                    } label: {
                        Label("Open Web View", systemImage: "globe")
                            .font(AppTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open Web View (W)")
                }

                Text(reason)
                    .font(AppTypography.callout)
                    .foregroundColor(AppColor.secondaryText)

                Divider().opacity(Self.dividerOpacity(for: contrast))

                Text(currentArticle.fullContent == nil ? "Feed summary preview" : "Previously saved text")
                    .font(AppTypography.eyebrow)
                    .tracking(AppTypography.eyebrowTracking)
                    .textCase(.uppercase)
                    .foregroundColor(tertiaryText)

                articleDescriptionParagraphs
            }
        }
    }

    @ViewBuilder
    private var articleDescriptionParagraphs: some View {
        let paragraphs = displayParagraphs
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
                    .foregroundColor(readableText(0.9))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                    .textSelection(.enabled)
                    .accessibilityLinkedGroup(id: currentArticle.id, in: storyParagraphs)
            }
        }
    }

    private var articleContentParagraphs: some View {
        let storedBlocks = currentArticle.readerDocument?.blocks ?? []
        // Documents stored before a boilerplate or image rule existed are cleaned here too.
        var blocks =
            storedBlocks.isEmpty
            ? displayParagraphs.map {
                ReaderBlock(kind: .paragraph, text: $0)
            }
            : storedBlocks.filter { block in
                block.kind == .figure
                    ? ReaderImageCandidate.usable(
                        url: block.imageURL ?? "", width: block.imageWidth, height: block.imageHeight)
                    : !ArticleContentRedactor.isBoilerplateLine(block.text)
            }
        // The page's own headline repeats the title above it.
        if let first = blocks.firstIndex(where: { $0.kind != .figure }),
            EventFeedSummary.titleKey(blocks[first].text) == EventFeedSummary.titleKey(currentArticle.title)
        {
            blocks.remove(at: first)
        }
        let leadIndex = blocks.firstIndex { $0.kind == .paragraph }
        return VStack(alignment: .leading, spacing: AppSpacing.lg * readerTextScale) {
            // Positions are stable within the immutable, article-keyed reader document.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                readerBlock(block, isLead: index == leadIndex)
                    .accessibilityLinkedGroup(id: currentArticle.id, in: storyParagraphs)
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
                .font(
                    .system(
                        size: (block.kind == .heading ? 22 : 15) * readerTextScale,
                        weight: block.kind == .heading ? .bold : .semibold)
                )
                .foregroundStyle(AppColor.primaryText)
                .padding(.top, AppSpacing.md)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(block.kind == .heading ? .h2 : .h3)
                .textSelection(.enabled)
        case .quote:
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Rectangle()
                    .fill(AppColor.accent.opacity(Self.quoteBarOpacity(for: contrast)))
                    .frame(width: 3)
                    .accessibilityHidden(true)
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
            .accessibilityElement(children: .combine)
        case .code:
            Text(readerText(block))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.control))
        case .paragraph:
            Text(readerText(block))
                .font(
                    isLead
                        ? AppTypography.leadFont(for: themeManager.articleTheme, scale: readerTextScale)
                        : AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale)
                )
                .foregroundStyle(AppColor.primaryText)
                .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func summaryTag(_ text: String, emphasized: Bool = false) -> some View {
        TagView(title: text, tint: emphasized ? AppColor.accent : AppColor.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var terminalAffordance: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Divider()
                .opacity(Self.dividerOpacity(for: contrast))
                .padding(.vertical, AppSpacing.sm)
            Text("Read the original story on \(displaySource)")
                .font(AppTypography.body)
                .foregroundStyle(AppColor.secondaryText)
            HStack(spacing: AppSpacing.sm) {
                Button("Open Web View", systemImage: "globe") { readerModeBinding.wrappedValue = .web }
                    .help("Open Web View (W)")
                if URL(string: currentArticle.link) != nil {
                    Button("Open in Browser", systemImage: "safari", action: openInBrowser)
                        .help("Open in default browser (O or ⌘O)")
                }
            }
            .buttonStyle(.bordered)
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
                .font(AppTypography.body)
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
                        .imageScale(.large)
                        .foregroundColor(AppColor.secondaryText)
                    Text("Invalid story link")
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
                Label("Back to Stories", systemImage: "chevron.left")
            }
            .help("Back to stories (Esc)")

            Button(action: prevArticle) {
                Label("Previous Story", systemImage: "chevron.up")
            }
            .disabled(!hasPrevArticle)
            .help("Previous story (K)")

            Button(action: nextArticle) {
                Label("Next Story", systemImage: "chevron.down")
            }
            .disabled(!hasNextArticle)
            .help("Next story (J)")
        }
        ToolbarItemGroup(placement: .principal) {
            // One mode control; in the toolbar it takes the system Liquid Glass on macOS 26 and later.
            Picker("Reading mode", selection: readerModeBinding) {
                if currentOverview != nil {
                    Text("Overview").tag(ReaderMode.overview)
                }
                Text("Story").tag(ReaderMode.story)
                Text("Web").tag(ReaderMode.web)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(
                currentOverview != nil
                    ? "Show the event overview, the publisher's story or its page (W)"
                    : "Show the publisher's story or its page (W)"
            )
            .accessibilityLabel("Reading mode")

            if isOverviewLoading && currentOverview == nil {
                ToolbarLoadingBubble()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if readerModeBinding.wrappedValue == .web {
                Button {
                    webAction = .goBack
                } label: {
                    Label("Web Back", systemImage: "arrow.left")
                }
                .disabled(!webCanGoBack)
                .help("Web Back")
                Button {
                    webAction = .goForward
                } label: {
                    Label("Web Forward", systemImage: "arrow.right")
                }
                .disabled(!webCanGoForward)
                .help("Web Forward")
            }
            Button(action: toggleSave) {
                Label(
                    isSaved ? "Remove from Saved Stories" : "Save Story",
                    systemImage: isSaved ? "bookmark.fill" : "bookmark")
            }
            .help(isSaved ? "Remove from Saved Stories (S)" : "Save Story (S)")

            if let url = URL(string: currentArticle.link) {
                ShareLink(item: url, subject: Text(currentArticle.title)) {
                    Label("Share Story", systemImage: "square.and.arrow.up")
                }
                .help("Share Story")
                .accessibilityLabel("Share Story")
            }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsReadingOptions.toggle()
            } label: {
                Label("Reading Options", systemImage: "textformat.size")
            }
            .help("Reading options")
            .popover(isPresented: $showsReadingOptions) { readingOptions }
        }
    }

    /// Labels in one trailing-aligned column and controls in the next, as in macOS settings forms.
    private var readingOptions: some View {
        Form {
            LabeledContent("Text Size") {
                HStack(spacing: AppSpacing.xs) {
                    Button {
                        readerTextScaleBinding.wrappedValue = ReaderTextSize.adjusted(readerTextScale, by: -1)
                    } label: {
                        Label("Make Text Smaller", systemImage: "textformat.size.smaller")
                    }
                    .disabled(readerTextScale <= ReaderTextSize.minimum)
                    .help("Make text smaller (⌘−)")
                    Button {
                        readerTextScaleBinding.wrappedValue = ReaderTextSize.adjusted(readerTextScale, by: 1)
                    } label: {
                        Label("Make Text Bigger", systemImage: "textformat.size.larger")
                    }
                    .disabled(readerTextScale >= ReaderTextSize.maximum)
                    .help("Make text bigger (⌘+)")
                    Text(readerTextScale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityLabel("Text size")
                        .accessibilityValue(Text(readerTextScale, format: .percent.precision(.fractionLength(0))))
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
            }
            Picker("Reading Style", selection: $themeManager.articleTheme) {
                ForEach(ArticleThemeType.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.columns)
        .fixedSize()
        .padding(AppSpacing.md)
        .focusable()
        .focusEffectDisabled()
        .focused($readingOptionsFocused)
        .onAppear { readingOptionsFocused = true }
        .onKeyPress(.escape) {
            showsReadingOptions = false
            return .handled
        }
    }

    /// The toolbar's single mode choice, mapped onto the overview and reader/web state it replaces.
    private var readerModeBinding: Binding<ReaderMode> {
        Binding(
            get: {
                if experienceMode == .eventOverview && currentOverview != nil { return .overview }
                return viewMode == .web ? .web : .story
            },
            set: { mode in
                switch mode {
                case .overview:
                    experienceMode = .eventOverview
                case .story:
                    experienceMode = .sourcePublication
                    viewMode = .reader
                case .web:
                    experienceMode = .sourcePublication
                    viewMode = .web
                }
            }
        )
    }

    // MARK: - Navigation & Actions

    private func nextArticle() {
        guard !allArticles.isEmpty,
            let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
            idx + 1 < allArticles.count
        else { return }
        resetReaderState()
        let next = allArticles[idx + 1]
        activeArticle = next
        readManager.markAsRead(next.id)
    }

    private func prevArticle() {
        guard !allArticles.isEmpty,
            let idx = allArticles.firstIndex(where: { $0.id == activeArticle.id }),
            idx > 0
        else { return }
        resetReaderState()
        let prev = allArticles[idx - 1]
        activeArticle = prev
        readManager.markAsRead(prev.id)
    }

    private func reloadReaderContent() {
        summaryExpanded = false
        analysis = nil
        reloadGeneration += 1
    }

    private func copyStoryLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentArticle.link, forType: .string)
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

    static func shouldPassThroughToSystem(modifiers: EventModifiers) -> Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        guard !Self.shouldPassThroughToSystem(modifiers: press.modifiers) else { return .ignored }
        if press.key == .escape {
            if showsReadingOptions {
                showsReadingOptions = false
                return .handled
            }
            if !path.isEmpty { path.removeLast() }
            return .handled
        }
        if press.key == .leftArrow || press.characters == "b" || press.characters == "h" {
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
            readerModeBinding.wrappedValue = readerModeBinding.wrappedValue.next(hasOverview: currentOverview != nil)
            return .handled
        }
        return .ignored
    }

    private var summaryExpandedBinding: Binding<Bool> {
        Binding(
            get: { summaryExpanded },
            set: { val in
                if reduceMotion {
                    summaryExpanded = val
                } else {
                    withAnimation(Self.readerAnimation(reduceMotion: reduceMotion)) {
                        summaryExpanded = val
                    }
                }
            }
        )
    }

    static func readerAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    static func sourceLineAccessibilityLabel(source: String, publicationDateText: String, readingTimeEstimate: String)
        -> String
    {
        "\(source), \(publicationDateText), \(readingTimeEstimate)"
    }

    static func dividerOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.60 : 0.15
    }

    static func quoteBarOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 1.0 : 0.5
    }

    static func capsuleBorderOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.35 : 0.08
    }

    private var tertiaryText: Color {
        AppColor.tertiaryText(for: contrast)
    }

    /// Increase Contrast restores full-strength text that is otherwise slightly softened.
    private func readableText(_ opacity: Double) -> Color {
        contrast == .increased ? AppColor.primaryText : AppColor.primaryText.opacity(opacity)
    }

    private func borderColor(_ standard: Color) -> Color {
        contrast == .increased ? AppColor.primaryText.opacity(0.3) : standard
    }

    private var displaySource: String { currentArticle.publisherName }

    private var displayCategory: String? {
        let raw = analysis?.category ?? currentArticle.category
        guard let raw = raw, !raw.isEmpty else { return nil }
        let firstLine =
            raw.components(separatedBy: .newlines)
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
                Text("Analyzing the story on device…")
                    .font(AppTypography.label)
                    .foregroundColor(AppColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Analyzing story with on-device AI")
            .padding(AppSpacing.sm)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        } else if let analysis = analysis {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                // Section Header: Restrained Summary
                IntelligenceLabel(
                    analysis.modelIdentifier == "apple.natural-language.fallback"
                        ? "Extractive summary" : "AI-generated summary"
                )

                Text(analysis.summary)
                    .font(AppTypography.body)
                    .foregroundColor(readableText(0.92))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                    .textSelection(.enabled)

                // Key Takeaways
                if !analysis.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Key Takeaways")
                            .font(AppTypography.label)
                            .foregroundColor(AppColor.secondaryText)
                            .padding(.top, AppSpacing.textStack)

                        ForEach(analysis.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: AppSpacing.xs) {
                                Circle()
                                    .fill(AppColor.intelligence.opacity(0.8))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, AppSpacing.eyebrowGap)
                                    .accessibilityHidden(true)
                                Text(point)
                                    .font(AppTypography.body)
                                    .foregroundColor(readableText(0.88))
                                    .textSelection(.enabled)
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
            .padding(AppSpacing.sm)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        } else if let error = analysisError {
            NoticeView(tint: AppColor.warning) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(AppColor.warning)
                    Text("AI analysis unavailable: \(error)")
                        .font(AppTypography.callout)
                        .foregroundColor(AppColor.secondaryText)
                    Spacer()
                    Button("Close Summary") {
                        if reduceMotion {
                            summaryExpanded = false
                        } else {
                            withAnimation(Self.readerAnimation(reduceMotion: reduceMotion)) {
                                summaryExpanded = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else if let ai = currentArticle.aiSummary {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                IntelligenceLabel("AI-generated summary")

                Text(ai)
                    .font(AppTypography.body)
                    .foregroundColor(readableText(0.92))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme))
                    .textSelection(.enabled)
            }
            .padding(AppSpacing.sm)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    // MARK: - Independent Extraction & Analysis

    /// Lists and briefings may hold an older snapshot. Guarded writes compare against stored publisher
    /// inputs, so the reader starts from them.
    private func refreshActiveArticleFromStore() async {
        let id = activeArticle.id
        guard let stored = try? await articleStore.database.fetchArticles(limit: 1, id: id).first,
            !Task.isCancelled, activeArticle.id == id, stored.id == id,
            stored.publisherInputHash != activeArticle.publisherInputHash
        else { return }
        activeArticle = stored
    }

    private func ensureContentExtracted(forceRefresh: Bool = false) async {
        // A stored document stands in for extraction only with publisher text; feed media alone does not.
        if !forceRefresh,
            currentArticle.readerDocument.map({
                (1...ReaderDocument.currentVersion).contains($0.version) && $0.hasPublisherText
            }) == true,
            let existing = currentArticle.fullContent, !ArticleContentRedactor.redactAndSplit(existing).isEmpty
        {
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
        let expectedInputHash = currentArticle.publisherInputHash

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
                    document = extractedDocument.curated(
                        feedImage: currentArticle.imageUrl, title: currentArticle.title)
                    do {
                        let repeated = try await articleStore.database.repeatedImageURLs(source: currentArticle.source)
                        try Task.checkCancellation()
                        guard activeArticle.id == targetId else { return }
                        document = document?.curated(feedImage: nil, title: currentArticle.title, excluding: repeated)
                    } catch is CancellationError { return } catch {
                        // Recurrence is optional; protected images still use local filters.
                    }
                }
                let saved = await articleStore.updateEnrichment(
                    id: targetId,
                    content: content,
                    image: imageUrl,
                    readerDocument: document,
                    identityEvidence: extraction.evidence,
                    expectedInputHash: expectedInputHash
                )
                guard !Task.isCancelled, activeArticle.id == targetId else { return }
                guard saved else {
                    contentState = .fallback(reason: "Publisher content changed while loading. Reload to try again.")
                    return
                }
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
        let targetArticle = currentArticle
        analysisError = nil
        isAnalyzing = false

        // Preserve persisted model identity and analysis version.
        if let cached = await articleStore.fetchArticleAnalysis(for: activeArticle.id), cached.analysisVersion >= 3 {
            guard !Task.isCancelled, activeArticle.id == targetID,
                currentArticle.publisherInputHash == targetArticle.publisherInputHash
            else { return }
            self.analysis = cached
            return
        }

        // Analysis runs only after the summary is explicitly opened.
        guard !Task.isCancelled, activeArticle.id == targetID, appSettings.aiEnabled else { return }

        isAnalyzing = true

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

            let saved = await articleStore.saveArticleAnalysis(
                result, for: targetArticle.id, expectedInputHash: targetArticle.publisherInputHash)
            guard !Task.isCancelled, activeArticle.id == targetArticle.id else { return }
            guard saved, currentArticle.publisherInputHash == targetArticle.publisherInputHash else {
                isAnalyzing = false
                analysisError = "Publisher content changed during analysis. Open the summary again to retry."
                return
            }
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

    private func setOverviewLoading(_ loading: Bool) {
        if reduceMotion {
            isOverviewLoading = loading
        } else {
            withAnimation(Self.readerAnimation(reduceMotion: reduceMotion)) {
                isOverviewLoading = loading
            }
        }
    }

    private func loadEventOverviewForActiveArticle() async {
        let articleID = activeArticle.id
        let inputHash = currentArticle.publisherInputHash
        guard !Task.isCancelled else { return }
        let summaries = (try? await articleStore.eventFeedSummaries(for: [articleID])) ?? []
        guard !Task.isCancelled, activeArticle.id == articleID,
            currentArticle.publisherInputHash == inputHash
        else { return }
        guard let summary = summaries.first, summary.isConfirmed, summary.sources.count >= 2 else {
            setOverviewLoading(false)
            currentOverview = nil
            eventMemberArticles = []
            experienceMode = .sourcePublication
            await OverviewGenerationCoordinator.shared.clearVisibleEvent(owner: overviewOwner)
            return
        }

        let eventID = summary.eventID
        let membershipVersion = summary.membershipVersion

        if let existing = currentOverview,
            existing.eventID == eventID,
            !existing.isStale(currentMembershipVersion: membershipVersion)
        {
            setOverviewLoading(false)
            let members = (try? await articleStore.eventMemberArticles(eventID: eventID)) ?? []
            guard !Task.isCancelled, activeArticle.id == articleID,
                currentArticle.publisherInputHash == inputHash
            else { return }
            eventMemberArticles = members.isEmpty ? [activeArticle] : members
            return
        }

        let members = (try? await articleStore.eventMemberArticles(eventID: eventID)) ?? []
        guard !Task.isCancelled, activeArticle.id == articleID,
            currentArticle.publisherInputHash == inputHash
        else { return }
        let resolvedMembers = members.isEmpty ? [activeArticle] : members
        let eventTitle = resolvedMembers.first?.title ?? summary.members.first?.title ?? activeArticle.title

        // Never show another event's overview while this one loads. The reader returns to the overview by
        // itself only if it was already showing one (J/K across events); otherwise it stays on the article.
        let returnToOverview = experienceMode == .eventOverview
        if currentOverview?.eventID != eventID {
            currentOverview = nil
            experienceMode = .sourcePublication
        }
        setOverviewLoading(true)

        let doc = await OverviewGenerationCoordinator.shared.setVisibleEvent(
            eventID: eventID,
            eventTitle: eventTitle,
            membershipVersion: membershipVersion,
            articles: resolvedMembers,
            store: articleStore,
            owner: overviewOwner,
            readerArticleID: articleID
        )

        guard !Task.isCancelled, activeArticle.id == articleID,
            currentArticle.publisherInputHash == inputHash
        else { return }

        setOverviewLoading(false)
        if let doc = doc {
            currentOverview = doc
            eventMemberArticles = resolvedMembers
            if returnToOverview && viewMode == .reader {
                experienceMode = .eventOverview
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
        highlightedPassage = nil
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
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.minX, y: bounds.minY + item.minY),
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

    static func effectiveImageAlt(for block: ReaderBlock) -> String {
        if let alt = block.imageAlt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            return alt
        }
        return "Article image"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ArticleRemoteImage(url: url) { phase in
                ZStack {
                    AppColor.surface
                        .accessibilityHidden(true)
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                            .accessibilityLabel(Self.effectiveImageAlt(for: block))
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
                Text(block.text).font(AppTypography.readerCaptionFont(scale: textScale)).foregroundStyle(
                    AppColor.secondaryText
                )
                .textSelection(.enabled)
            }
            if let credit = block.imageCredit, !credit.isEmpty {
                Text(credit).font(AppTypography.readerCaptionFont(scale: textScale)).foregroundStyle(
                    AppColor.secondaryText
                ).textSelection(
                    .enabled
                )
                .accessibilityLabel("Image credit: " + credit)
            }
            Text("Image source: " + (url.host ?? "Publisher"))
                .font(AppTypography.readerCaptionFont(scale: textScale)).foregroundStyle(AppColor.secondaryText)
                .textSelection(.enabled)
        }
    }

    private var aspectRatio: CGFloat {
        guard let width = block.imageWidth, let height = block.imageHeight, width > 0, height > 0 else { return 1.5 }
        return min(3, max(0.4, CGFloat(width) / CGFloat(height)))
    }
}

private struct ArticleNavigationCommands: ViewModifier {
    let onNextArticle: () -> Void
    let onPrevArticle: () -> Void
    let onToggleRead: () -> Void
    let onToggleSave: () -> Void
    let onOpenInBrowser: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .nextArticleCommand)) { _ in onNextArticle() }
            .onReceive(NotificationCenter.default.publisher(for: .prevArticleCommand)) { _ in onPrevArticle() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadCommand)) { _ in onToggleRead() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSaveCommand)) { _ in onToggleSave() }
            .onReceive(NotificationCenter.default.publisher(for: .openInBrowserCommand)) { _ in onOpenInBrowser() }
    }
}

func readerText(_ block: ReaderBlock) -> AttributedString {
    guard let runs = block.inlineRuns, runs.map(\.text).joined() == block.text else {
        return AttributedString(block.text)
    }
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

/// An isolated, fixed-height loading indicator bubble in the reader toolbar.
private struct ToolbarLoadingBubble: View {
    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.xs) {
            ProgressView()
                .controlSize(.small)
            Text("Loading event overview…")
                .font(AppTypography.caption)
                .foregroundColor(AppColor.secondaryText)
        }
        .frame(height: 24)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xxs)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.95)),
                removal: .opacity
            )
            .animation(.easeInOut(duration: 0.25))
        )
        .help("Generating evidence-backed event overview…")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading event overview")
    }
}
