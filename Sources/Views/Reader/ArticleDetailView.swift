// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// ArticleDetailView.swift
// NewsApp Article Detail Reading Experience & Native Toolbar

import AppKit
import SwiftUI

struct ArticleDetailView: View {
    @State private var activeArticle: FeedArticle
    let allArticles: [FeedArticle]
    @Binding var path: NavigationPath

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var articleStore: ArticleStore
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var readManager: ReadManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var feedManager: FeedManager
    @Environment(\.articleSearchState) private var searchState: ArticleSearchState?
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
    @State private var showsAnnotationsInspector = false
    @State private var articleNotes: [UserNote] = []
    @State private var noteDraft: NoteDraft?
    @State private var showsChanges = false
    @State private var changesSinceVersion: Int?
    /// The diff overlay with the `changesTaskID` it was worked out for; it is used only while that still holds.
    @State private var changeOverlay = (key: "", overlay: SentenceDiff.Overlay())
    @State private var revealedBlock: Int?
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
    /// Identifies the latest overview load so an older one cannot overwrite its result.
    @State private var overviewLoadSerial = 0
    @State private var currentOverview: EventOverviewDocument?
    @State private var overviewLoadedInputHash: String?
    @State private var highlightedPassage: String? = nil
    @State private var eventMemberArticles: [FeedArticle] = []
    /// Earlier events of the overview's developing story, keyed by the event they were found for.
    @State private var relatedStories: (eventID: String, events: [RelatedStoryEvent])?
    /// An article opened from "Earlier in This Story": its event opens on the overview, even if an interrupted load
    /// already reset the mode.
    @State private var overviewRequestedArticleID: String?
    @State private var isOverviewLoading: Bool = false
    /// The overview's Check for Updates status line (#992); nil until the person checks this story.
    @State private var storyUpdateStatus: String?
    @State private var isCheckingForUpdates = false
    /// The running Check for Updates; cleared when the reader closes, so a result after that changes nothing.
    @State private var storyUpdateCheck: UUID?
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
        self._overviewLoadedInputHash = State(initialValue: overview != nil ? article.publisherInputHash : nil)
        self._textScaleOverride = State(
            initialValue: SystemSettingsOverrides.from().textScale.map(ReaderTextSize.normalized))
        if let mode = initialExperienceMode {
            self._experienceMode = State(initialValue: mode)
            if mode == .eventOverview {
                self._overviewRequestedArticleID = State(initialValue: article.id)
            }
        } else if overview != nil {
            self._experienceMode = State(initialValue: .eventOverview)
            self._overviewRequestedArticleID = State(initialValue: article.id)
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

    private var knowledgeExportActions: KnowledgeExportActions {
        KnowledgeExportUI.actions(articles: [currentArticle], title: currentArticle.title, store: articleStore)
    }

    private var readerCommandActions: ReaderCommandActions {
        ReaderCommandActions(
            mode: readerModeBinding, textScale: readerTextScaleBinding,
            showReadingOptions: { showsReadingOptions = true }, hasOverview: currentOverview != nil,
            back: { Self.stepBack(&path) },
            reload: contentState == .loading ? nil : { reloadReaderContent() },
            copyLink: copyStoryLink,
            webBack: readerModeBinding.wrappedValue == .web && webCanGoBack ? { webAction = .goBack } : nil,
            webForward: readerModeBinding.wrappedValue == .web && webCanGoForward ? { webAction = .goForward } : nil,
            checkForUpdates: canCheckForUpdates ? { checkForUpdates() } : nil
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
            .focusedSceneValue(\.knowledgeExport, knowledgeExportActions)
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
            .modifier(
                ReaderAnnotationCommands(
                    onHighlight: highlightSelection, onAddNote: beginNote,
                    onToggleInspector: { showsAnnotationsInspector.toggle() })
            )
            .diagnosticInspector(isPresented: $showsAnnotationsInspector) { annotationsInspector }
            .task(id: changesTaskID) { await updateChangeOverlay() }
            .task(id: "\(activeArticle.id):\(articleStore.userNotesRevision)") {
                let id = activeArticle.id
                let notes = await articleStore.notes(for: id)
                guard !Task.isCancelled, activeArticle.id == id else { return }
                articleNotes = notes
            }
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
            // Publisher updates are recorded only when the story's publisher input changes; other stories'
            // writes leave them as they are (#778).
            .task(id: "\(activeArticle.id):\(currentArticle.publisherInputHash)") {
                let id = activeArticle.id
                let revisions = try? await articleStore.database.publisherContentRevisions(for: id)
                guard !Task.isCancelled, activeArticle.id == id else { return }
                publisherRevisions = revisions ?? []
            }
            .onChange(of: activeArticle.id) { _, _ in
                publisherUpdatesExpanded = false
                storyUpdateStatus = nil
                articleNotes = []
                noteDraft = nil
                showsChanges = false
                changesSinceVersion = nil
                changeOverlay = ("", SentenceDiff.Overlay())
            }
            .onChange(of: currentArticle.publisherInputHash) { _, _ in
                analysis = nil
                analysisError = nil
                isAnalyzing = false
                currentOverview = nil
                overviewLoadedInputHash = nil
            }
            .onAppear { isViewFocused = true }
            .onDisappear {
                storyUpdateCheck = nil
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
                    theme: themeManager.articleTheme,
                    updateStatus: storyUpdateStatus,
                    relatedEvents: Self.relatedEventsToShow(relatedStories, overviewEventID: overview.eventID),
                    onSelectArticle: { article in
                        selectSourceArticle(article)
                        highlightedPassage = nil
                        experienceMode = .sourcePublication
                    },
                    onSelectCitation: { citation, article in
                        if let article = article {
                            selectSourceArticle(article)
                        }
                        // After the reset, which clears the passage.
                        highlightedPassage = citation.quote
                        experienceMode = .sourcePublication
                    },
                    onSelectRelatedEvent: { related in
                        Task {
                            // Opening an event from here counts as seeing it, as it does from the feed.
                            if await openStory(id: related.articleID) {
                                await articleStore.markEventSeen(related.eventID)
                            }
                        }
                    },
                    onCombineRelatedEvent: { related in
                        Task {
                            guard await articleStore.includeEvent(related.eventID, inEvent: overview.eventID) else {
                                return
                            }
                            guard !Task.isCancelled else { return }
                            relatedStories = nil
                            await loadEventOverviewForActiveArticle()
                        }
                    },
                    entitySource: articleStore.entitySource,
                    onOpenEntityStory: { id in Task { _ = await openStory(id: id) } }
                )
                .id(overview.id)
                .focusEffectDisabled(false)
            } else if overviewRequestedArticleID == activeArticle.id && isOverviewLoading {
                VStack(spacing: AppSpacing.md) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading event overview…")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The rendered block the cited passage matches, once the story is ready.
    private var highlightedBlockIndex: Int? {
        guard case .ready = contentState, let passage = highlightedPassage else { return nil }
        return ReaderPassageMatcher.index(of: passage, in: renderedBlocks)
    }

    private static func readerBlockID(_ index: Int) -> String { "reader-block-\(index)" }

    private var readerView: some View {
        ScrollViewReader { proxy in
            readerScrollView
                .onChange(of: highlightedBlockIndex, initial: true) { _, index in
                    guard let index else { return }
                    if reduceMotion {
                        proxy.scrollTo(Self.readerBlockID(index), anchor: .center)
                    } else {
                        withAnimation(AppMotion.navigation) {
                            proxy.scrollTo(Self.readerBlockID(index), anchor: .center)
                        }
                    }
                }
                // Show in Story from the Annotations inspector.
                .onChange(of: revealedBlock) { _, index in
                    guard let index else { return }
                    revealedBlock = nil
                    withAnimation(reduceMotion ? nil : AppMotion.navigation) {
                        proxy.scrollTo(Self.readerBlockID(index), anchor: .center)
                    }
                }
        }
    }

    private var readerScrollView: some View {
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
                                        .foregroundStyle(AppColor.accentText)
                                        .padding(.top, AppSpacing.textStack)
                                        .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                        Text("Cited in Event Overview")
                                            .font(AppTypography.eyebrow)
                                            .foregroundStyle(AppColor.accentText)

                                        Text("“\(passage)”")
                                            .font(AppTypography.readerCitation)
                                            .foregroundStyle(AppColor.primaryText)
                                            .lineSpacing(AppSpacing.textStack)
                                            .textSelection(.enabled)
                                    }
                                }
                                // Ignore, not combine: the passage is selectable text (DESIGN.md 16).
                                .accessibilityElement(children: .ignore)
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
                                        .foregroundStyle(AppColor.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .buttonBorderShape(.circle)
                                .help("Dismiss citation highlight")
                                .accessibilityLabel("Dismiss citation highlight")
                            }
                        }
                    }

                    // Eyebrow: Source, Date, Reading Time, and the revision pill of an updated story
                    HStack(spacing: AppSpacing.eyebrowGap) {
                        HStack(spacing: AppSpacing.eyebrowGap) {
                            EyebrowText(displaySource)

                            Text("·")
                                .foregroundStyle(secondaryText)

                            Text(currentArticle.publicationDateText)
                                .font(AppTypography.label)
                                .foregroundStyle(AppColor.secondaryText)
                                .monospacedDigit()

                            if let readingTimeEstimate {
                                Text("·")
                                    .foregroundStyle(secondaryText)

                                Text(readingTimeEstimate)
                                    .font(AppTypography.label)
                                    .foregroundStyle(AppColor.secondaryText)
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Self.sourceLineAccessibilityLabel(
                                source: displaySource,
                                publicationDateText: currentArticle.publicationDateText,
                                readingTimeEstimate: readingTimeEstimate ?? ""
                            ))

                        revisionPill
                    }

                    // Headline
                    Text(currentArticle.title)
                        .font(AppTypography.titleFont(for: themeManager.articleTheme, scale: readerTextScale))
                        .foregroundStyle(AppColor.primaryText)
                        .lineSpacing(AppSpacing.xxs * readerTextScale)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHeading(.h1)
                        .textSelection(.enabled)

                    standfirst

                    publisherUpdates

                    // On-device AI Analysis Section
                    heroImageHeader

                    if appSettings.aiEnabled || currentArticle.aiSummary != nil {
                        DisclosureGroup(isExpanded: summaryExpandedBinding) {
                            aiAnalysisSection.padding(.top, AppSpacing.sm)
                        } label: {
                            IntelligenceLabel(Self.summaryLabel(modelIdentifier: analysis?.modelIdentifier))
                                .font(AppTypography.headline)
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
                    case .publisherOnly(let subscriber):
                        publisherOnlyView(subscriber: subscriber)
                    }

                    // Once the story is there: the people, organizations and places it names, each opening a dossier
                    // (W2 #716), then the terminal affordance, "Read original article on <source>". One child, not two:
                    // this column is at the ten children a ViewBuilder takes on the Xcode 26 SDK that CI builds with.
                    if case .ready = contentState {
                        EntityChipRow(
                            articleIDs: [currentArticle.id], source: articleStore.entitySource,
                            onSelectStory: { id in Task { _ = await openStory(id: id) } })
                        terminalAffordance
                    }

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

    /// The reader's lead figure: the image the story card shows (#925), unless a figure opens the body or the body
    /// already shows the same image.
    nonisolated static func leadImage(for article: FeedArticle, blocks: [ReaderBlock]) -> String? {
        guard !blocks.prefix(2).contains(where: { $0.kind == .figure }),
            let image = article.readerDocument?.selectedImage(fallback: article.imageUrl) ?? article.imageUrl,
            !blocks.contains(where: { $0.kind == .figure && $0.imageURL == image })
        else { return nil }
        return image
    }

    @ViewBuilder
    private var heroImageHeader: some View {
        // Decided on the blocks the reader shows, so a dropped early figure does not hide the lead.
        let blocks = renderedBlocks
        if let imageUrl = Self.leadImage(for: currentArticle, blocks: blocks), let url = URL(string: imageUrl) {
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

    /// Counted from the rendered story once it is there; a feed teaser would understate it.
    private var readingTimeEstimate: String? {
        let text: String
        if currentArticle.readerDocument != nil {
            text = renderedBlocks.map(\.text).joined(separator: " ")
        } else if case .ready = contentState, let content = currentArticle.fullContent {
            text = content
        } else {
            return nil
        }
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let minutes = max(1, Int(ceil(Double(words) / 200.0)))
        return "\(minutes) min read"
    }

    private var loadingStateView: some View {
        HStack(spacing: AppSpacing.sm) {
            // AppKit-backed views stay out of combined or relabelled accessibility elements (see ReaderFigureView).
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Loading full story…")
                .font(AppTypography.label)
                .foregroundStyle(AppColor.secondaryText)
                .accessibilityLabel("Loading full story")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppSpacing.lg)
    }

    private func fallbackStateView(reason: String) -> some View {
        NoticeView {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityHidden(true)
                    Text("Full story unavailable in reader")
                        .font(AppTypography.headline)
                        .foregroundStyle(AppColor.primaryText)
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
                    .help("Open web view (W)")
                }

                Text(reason)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)

                Divider().opacity(Self.dividerOpacity(for: contrast))

                EyebrowText(
                    currentArticle.fullContent == nil ? "Feed summary preview" : "Previously saved text",
                    color: secondaryText)

                articleDescriptionParagraphs
            }
        }
    }

    /// The teaser reads as the story's lead, followed by a quiet note and the ways to read it with the reader's access.
    private func publisherOnlyView(subscriber: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            articleDescriptionParagraphs
            NoticeView {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Label(
                        subscriber ? "Subscriber-only story" : "Read on the publisher's site",
                        systemImage: subscriber ? "lock" : "globe"
                    )
                    .font(AppTypography.headline)
                    .foregroundStyle(AppColor.primaryText)
                    Text(
                        subscriber
                            ? "\(displaySource) shows the full story to subscribers. Sign in through the web view to read it."
                            : "\(displaySource) does not let the reader fetch this story. Open it in the web view to read it."
                    )
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: AppSpacing.sm) {
                        Button {
                            viewMode = .web
                        } label: {
                            Label("Open Web View", systemImage: "globe")
                        }
                        .help("Open web view (W)")
                        Button {
                            openInBrowser()
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(AppTypography.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The feed's standfirst under the headline, unless the story's opening paragraph already says it.
    private var standfirstText: String? {
        let dek = ArticleContentRedactor.cleanText(currentArticle.description)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = renderedBlocks.first { $0.kind == .paragraph }?.text ?? ""
        let key = { (text: String) in String(EventFeedSummary.titleKey(text).prefix(60)) }
        // The page's own standfirst, when extracted, is shown in the body instead.
        let pageHasStandfirst = currentArticle.readerDocument?.blocks.contains { $0.kind == .standfirst } == true
        guard contentState == .ready, !pageHasStandfirst, (20...400).contains(dek.count),
            !key(opening).hasPrefix(key(dek)),
            !key(dek).hasPrefix(key(opening))
        else { return nil }
        return dek
    }

    @ViewBuilder
    private var standfirst: some View {
        if let dek = standfirstText {
            Text(dek)
                .font(AppTypography.leadFont(for: themeManager.articleTheme, scale: readerTextScale))
                .foregroundStyle(AppColor.secondaryText)
                .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var articleDescriptionParagraphs: some View {
        let paragraphs = displayParagraphs
        VStack(alignment: .leading, spacing: AppSpacing.lg * readerTextScale) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
                    .foregroundStyle(AppColor.primaryText)
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                    .textSelection(.enabled)
                    .accessibilityLinkedGroup(id: currentArticle.id, in: storyParagraphs)
            }
        }
    }

    /// The blocks the reader renders: stored blocks cleaned by today's rules, or feed paragraphs, minus a repeated headline.
    private var renderedBlocks: [ReaderBlock] {
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
                    : block.kind == .divider || !ArticleContentRedactor.isBoilerplateLine(block.text)
            }
        // The page's own headline repeats the title above it.
        func normalizedHeadline(_ text: String) -> String {
            var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for sep in [" - ", " | ", " – ", " — "] {
                if let r = s.range(of: sep, options: .backwards) {
                    s = String(s[..<r.lowerBound])
                }
            }
            return EventFeedSummary.titleKey(s)
        }
        let articleKey = normalizedHeadline(currentArticle.title)
        if let first = blocks.firstIndex(where: { $0.kind != .figure && $0.kind != .divider }) {
            let blockKey = normalizedHeadline(blocks[first].text)
            if blockKey == articleKey || (!articleKey.isEmpty && blockKey.hasPrefix(articleKey))
                || (!blockKey.isEmpty && articleKey.hasPrefix(blockKey))
            {
                blocks.remove(at: first)
            }
        }
        return blocks
    }

    private var articleContentParagraphs: some View {
        let blocks = renderedBlocks
        let overlay = readerOverlay(for: blocks)
        // A shown feed standfirst or a page standfirst already leads the story in the lead size.
        let leadIndex =
            standfirstText == nil && !blocks.contains { $0.kind == .standfirst }
            ? blocks.firstIndex { $0.kind == .paragraph } : nil
        return VStack(alignment: .leading, spacing: 0) {
            // Positions are stable within the immutable, article-keyed reader document.
            let highlighted = highlightedBlockIndex
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if index == 0 { retractedLines(overlay.changes.retracted[-1]) }
                readerBlock(block, index: index, isLead: index == leadIndex, overlay: overlay)
                    .padding(.horizontal, index == highlighted ? AppSpacing.xs : 0)
                    .padding(.vertical, index == highlighted ? AppSpacing.xxs : 0)
                    .background(
                        index == highlighted ? AppColor.passageHighlight : .clear,
                        in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    )
                    .id(Self.readerBlockID(index))
                    .padding(
                        .bottom,
                        Self.blockSpacing(
                            after: block.kind, before: index + 1 < blocks.count ? blocks[index + 1].kind : nil,
                            scale: readerTextScale)
                    )
                    .accessibilityLinkedGroup(id: currentArticle.id, in: storyParagraphs)
                retractedLines(overlay.changes.retracted[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Story links open in the browser, never inside the reader column.
        .environment(
            \.openURL,
            OpenURLAction { url in
                // A link of any other scheme in an article is not opened at all (#799).
                guard let url = WebLink.url(url.absoluteString) else { return .discarded }
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    /// Legacy documents stored relative links; the story URL resolves them.
    private func readerLinkedText(_ block: ReaderBlock, index: Int, overlay: ReaderOverlay) -> AttributedString {
        overlay.styled(readerText(block, baseURL: URL(string: currentArticle.link)), at: index)
    }

    /// One rendered block of the story: figures, headings, dividers and paragraphs here, the other kinds below.
    @ViewBuilder
    private func readerBlock(_ block: ReaderBlock, index: Int, isLead: Bool, overlay: ReaderOverlay) -> some View {
        switch block.kind {
        case .figure:
            if let imageURL = block.imageURL, let url = URL(string: imageURL) {
                ReaderFigureView(block: block, url: url, textScale: readerTextScale)
            }
        case .heading, .subheading:
            Text(readerLinkedText(block, index: index, overlay: overlay))
                .font(
                    AppTypography.readerHeadingFont(
                        level: block.kind == .heading ? 2 : 3, theme: themeManager.articleTheme, scale: readerTextScale)
                )
                .foregroundStyle(AppColor.primaryText)
                .lineSpacing(AppSpacing.xxs * readerTextScale)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(block.kind == .heading ? .h2 : .h3)
                .textSelection(.enabled)
                .readerLookUp(
                    text: block.text,
                    lineSpacing: AppSpacing.xxs * readerTextScale,
                    font: ReaderDictionaryLookup.headingFont(
                        level: block.kind == .heading ? 2 : 3, theme: themeManager.articleTheme, scale: readerTextScale)
                )
        case .divider:
            Divider()
                .opacity(Self.dividerOpacity(for: contrast))
                .frame(maxWidth: AppLayout.readerSectionRuleWidth)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm * readerTextScale)
                .accessibilityHidden(true)
        case .paragraph:
            Text(readerLinkedText(block, index: index, overlay: overlay))
                .font(
                    isLead
                        ? AppTypography.leadFont(for: themeManager.articleTheme, scale: readerTextScale)
                        : AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale)
                )
                .foregroundStyle(AppColor.primaryText)
                .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .readerLookUp(
                    text: block.text,
                    lineSpacing: AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale,
                    font: isLead
                        ? ReaderDictionaryLookup.leadFont(for: themeManager.articleTheme, scale: readerTextScale)
                        : ReaderDictionaryLookup.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
        default:
            readerWrappedBlock(block, index: index, overlay: overlay)
        }
    }

    /// Quotes, list items, code and standfirsts: the block kinds whose layout wraps the text.
    @ViewBuilder
    private func readerWrappedBlock(_ block: ReaderBlock, index: Int, overlay: ReaderOverlay) -> some View {
        switch block.kind {
        case .quote:
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Rectangle()
                    .fill(AppColor.accent.opacity(Self.quoteBarOpacity(for: contrast)))
                    .frame(width: AppLayout.quoteBarWidth)
                    .accessibilityHidden(true)
                Text(readerLinkedText(block, index: index, overlay: overlay))
                    .font(AppTypography.readerQuoteFont(for: themeManager.articleTheme, scale: readerTextScale))
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                    .textSelection(.enabled)
                    .readerLookUp(
                        text: block.text,
                        lineSpacing: AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale,
                        font: ReaderDictionaryLookup.bodyFont(
                            for: themeManager.articleTheme, scale: readerTextScale, italic: true))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, AppSpacing.xxs * readerTextScale)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Text(block.ordinal.map { "\($0)." } ?? "•")
                    .foregroundStyle(AppColor.secondaryText)
                    // A bullet is decoration; an ordinal is read before the item.
                    .accessibilityHidden(block.ordinal == nil)
                // Not combined: the item is selectable text and may carry links (DESIGN.md 16).
                Text(readerLinkedText(block, index: index, overlay: overlay))
                    .textSelection(.enabled)
                    .readerLookUp(
                        text: block.text,
                        lineSpacing: AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale,
                        font: ReaderDictionaryLookup.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
            }
            .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
            .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
            .padding(.leading, CGFloat(block.level ?? 0) * AppSpacing.lg * readerTextScale)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(readerLinkedText(block, index: index, overlay: overlay))
                    .font(AppTypography.readerCodeFont(for: themeManager.articleTheme, scale: readerTextScale))
                    .textSelection(.enabled)
                    .readerLookUp(
                        text: block.text,
                        lineSpacing: AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale,
                        font: ReaderDictionaryLookup.codeFont(for: themeManager.articleTheme, scale: readerTextScale)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(AppSpacing.md * readerTextScale)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        case .standfirst:
            Text(readerLinkedText(block, index: index, overlay: overlay))
                .font(AppTypography.leadFont(for: themeManager.articleTheme, scale: readerTextScale))
                .foregroundStyle(AppColor.secondaryText)
                .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .readerLookUp(
                    text: block.text,
                    lineSpacing: AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale,
                    font: ReaderDictionaryLookup.leadFont(for: themeManager.articleTheme, scale: readerTextScale))
        default:
            readerBoxedBlock(block, index: index, overlay: overlay)
        }
    }

    /// Pull quotes, tables and embeds: the block kinds that are boxed or set apart from the text.
    @ViewBuilder
    private func readerBoxedBlock(_ block: ReaderBlock, index: Int, overlay: ReaderOverlay) -> some View {
        switch block.kind {
        case .pullQuote:
            VStack(alignment: .leading, spacing: AppSpacing.sm * readerTextScale) {
                Divider().opacity(Self.dividerOpacity(for: contrast))
                Text(readerLinkedText(block, index: index, overlay: overlay))
                    .font(AppTypography.leadFont(for: themeManager.articleTheme, scale: readerTextScale).italic())
                    .foregroundStyle(AppColor.primaryText)
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .readerLookUp(
                        text: block.text,
                        lineSpacing: AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale,
                        font: ReaderDictionaryLookup.leadFont(
                            for: themeManager.articleTheme, scale: readerTextScale, italic: true))
                Divider().opacity(Self.dividerOpacity(for: contrast))
            }
        case .table:
            ReaderTableView(
                block: block,
                font: AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale * 0.9))
        case .embed:
            NoticeView {
                HStack(spacing: AppSpacing.sm) {
                    Label(
                        Self.embedTitle(for: block),
                        systemImage: Self.isTableNotice(block) ? "tablecells" : "text.bubble"
                    )
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)
                    Spacer()
                    Button("Open Web View", systemImage: "globe") { viewMode = .web }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open web view (W)")
                }
            }
        default:
            EmptyView()
        }
    }

    private func summaryTag(_ text: String, isCategory: Bool = false) -> some View {
        Button {
            openSearchForTag(text, isCategory: isCategory)
        } label: {
            TagView(title: text, tint: isCategory ? AppColor.accent : AppColor.secondaryLabel)
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Search for \(text)")
        .accessibilityHint(
            isCategory ? "Opens archive search for this category" : "Opens archive search for this topic"
        )
        .contextMenu {
            Button {
                openSearchForTag(text, isCategory: isCategory)
            } label: {
                Label("Search for “\(text)”", systemImage: "magnifyingglass")
            }
        }
        .help("Search for “\(text)”")
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openSearchForTag(_ text: String, isCategory: Bool) {
        let wrap = FeedArticleWrap(
            article: currentArticle,
            contextArticles: allArticles,
            initialExperienceMode: experienceMode
        )
        searchState?.openTag(tag: text, isCategory: isCategory, from: wrap, path: &path)
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
                    .help("Open web view (W)")
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
                Button("Open in Browser") { openInBrowser() }
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
                    .frame(height: AppLayout.progressBarHeight)
            } else {
                Divider()
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
                        .foregroundStyle(AppColor.secondaryText)
                    Text("Invalid story link")
                        .font(AppTypography.headline)
                        .foregroundStyle(AppColor.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Highlights and Notes (V1 #711)

    private static let annotatableKinds: Set<ReaderBlock.Kind> = [
        .paragraph, .standfirst, .quote, .pullQuote, .listItem, .heading, .subheading,
    ]

    /// The text of each rendered block a highlight can sit in, empty for the others, so indices match the blocks.
    private func anchorTexts(_ blocks: [ReaderBlock]) -> [String] {
        blocks.map { Self.annotatableKinds.contains($0.kind) ? $0.text : "" }
    }

    /// The highlights (and, with the diff shown, the changes) to paint over the rendered blocks.
    private func readerOverlay(for blocks: [ReaderBlock]) -> ReaderOverlay {
        ReaderOverlay(
            notes: articleNotes, paragraphs: anchorTexts(blocks),
            changes: showsChanges && changeOverlay.key == changesTaskID ? changeOverlay.overlay : .init())
    }

    // MARK: - Story Evolution (V2 #712)

    private var isStoryReady: Bool {
        if case .ready = contentState { return true }
        return false
    }

    /// Publisher updates the story can be compared with, newest first.
    private var comparableUpdates: [PublisherContentRevision] {
        PublisherContentRevision.comparable(
            publisherRevisions,
            current: PublisherContentRevision.text(
                description: currentArticle.description, content: currentArticle.fullContent))
    }

    /// The update the story is compared with: the story as it was before it, the newest unless the reader chose.
    private var changesBase: PublisherContentRevision? {
        let updates = comparableUpdates
        return updates.first { $0.version == changesSinceVersion } ?? updates.first
    }

    private var changesTaskID: String {
        // The blocks' text is part of the key only while the diff shows: it decides where the changes sit.
        let blocks = showsChanges ? renderedBlocks.map(\.text).hashValue : 0
        return
            "\(showsChanges && isStoryReady):\(changesBase?.version ?? 0):\(currentArticle.publisherInputHash):\(blocks)"
    }

    /// Works out the diff overlay off the main actor and keeps it with the comparison it belongs to.
    private func updateChangeOverlay() async {
        guard showsChanges, isStoryReady, let before = changesBase?.previousText else {
            changeOverlay = ("", SentenceDiff.Overlay())
            return
        }
        let key = changesTaskID
        let after = PublisherContentRevision.text(
            description: currentArticle.description, content: currentArticle.fullContent)
        let blocks = anchorTexts(renderedBlocks)
        let work = Task.detached(priority: .userInitiated) {
            SentenceDiff.overlay(before: before, after: after, blocks: blocks)
        }
        let overlay = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        changeOverlay = (key, overlay)
    }

    /// "Updated (N revisions)" beside the date: toggles the sentence diff; with several updates the menu picks the
    /// story it is compared with. Added sentences are tinted and removed ones listed struck through, in place.
    @ViewBuilder
    private var revisionPill: some View {
        let updates = comparableUpdates
        if isStoryReady, !updates.isEmpty {
            let count = updates.count
            Text("·")
                .foregroundStyle(secondaryText)
                .accessibilityHidden(true)
            Menu {
                ForEach(updates) { update in
                    Button {
                        changesSinceVersion = update.version
                        showsChanges = true
                    } label: {
                        Text(
                            "Compare with the story before \(update.observedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                    }
                }
                if showsChanges {
                    Divider()
                    Button("Hide Changes") { showsChanges = false }
                }
            } label: {
                TagView(
                    title: count == 1 ? "Updated (1 revision)" : "Updated (\(count) revisions)",
                    systemImage: "clock.arrow.circlepath",
                    tint: showsChanges ? AppColor.accent : AppColor.secondaryText, font: AppTypography.label)
            } primaryAction: {
                showsChanges.toggle()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help(showsChanges ? "Hide what the publisher changed" : "Show what the publisher changed")
            .accessibilityValue(showsChanges ? "Showing changes" : "Changes hidden")
            .accessibilityHint("Shows added sentences marked and removed sentences struck through")
        }
    }

    /// Sentences a publisher update removed, struck through after the block that held the sentence before them.
    @ViewBuilder
    private func retractedLines(_ sentences: [String]?) -> some View {
        ForEach(Array((sentences ?? []).enumerated()), id: \.offset) { _, sentence in
            Text(sentence)
                .font(AppTypography.bodyFont(for: themeManager.articleTheme, scale: readerTextScale))
                .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                .strikethrough()
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, AppSpacing.xs)
                .accessibilityLabel("Removed by the publisher: \(sentence)")
        }
    }

    /// One note for each passage of the reader's selection that is not highlighted yet; nil, with a beep, when
    /// nothing in the story's text is selected.
    private func notesForSelection() -> [UserNote]? {
        let texts = anchorTexts(renderedBlocks)
        let taken = articleNotes.compactMap { NoteAnchor.resolve($0, in: texts) }.map {
            (index: $0.index, range: $0.range)
        }
        guard readerModeBinding.wrappedValue == .story, case .ready = contentState,
            let selection = ReaderSelection.current(),
            let places = NoteAnchor.place(selection: selection, in: texts, taken: taken)
        else {
            NSSound.beep()
            return nil
        }
        return places.compactMap { place in
            let range = place.start..<place.start + place.quote.count
            guard !taken.contains(where: { $0.index == place.index && $0.range == range }) else { return nil }
            return NoteAnchor.note(
                articleID: activeArticle.id, paragraphs: texts, index: place.index, start: place.start,
                quote: place.quote)
        }
    }

    /// Shows new notes at once, so a second command sees them; the store reloads them when the save lands, and they
    /// disappear again if it failed.
    private func add(_ notes: [UserNote]) {
        articleNotes += notes
        Task { await articleStore.saveNotes(notes) }
    }

    /// Highlights the selected passages, or beeps when there is nothing new to highlight.
    private func highlightSelection() {
        guard let notes = notesForSelection() else { return }
        if notes.isEmpty { NSSound.beep() } else { add(notes) }
    }

    /// Opens the note composer for the selected passages.
    private func beginNote() {
        guard let notes = notesForSelection() else { return }
        // A passage that is highlighted already takes its note in the inspector.
        if notes.isEmpty { showsAnnotationsInspector = true } else { noteDraft = NoteDraft(notes: notes) }
    }

    /// Saves the note the composer collected; false, with the composer left open and its text kept, when the library
    /// refused it.
    private func saveNote(_ draft: NoteDraft, body: String) async -> Bool {
        var notes = draft.notes
        notes[0].noteBody = body
        articleNotes += notes
        let saved = await articleStore.saveNotes(notes)
        if saved { showsAnnotationsInspector = true }
        return saved
    }

    private var annotationsInspector: some View {
        let texts = anchorTexts(renderedBlocks)
        let ready: Bool = {
            if case .ready = contentState { return true }
            return false
        }()
        return AnnotationsInspectorView(
            notes: articleNotes,
            lostIDs: ready ? Set(articleNotes.filter { NoteAnchor.resolve($0, in: texts) == nil }.map(\.id)) : [],
            onReveal: { note in revealedBlock = NoteAnchor.resolve(note, in: texts)?.index },
            onSave: { note in await articleStore.saveNotes([note]) },
            onDelete: { id in Task { await articleStore.deleteNote(id: id) } }
        )
        .inspectorColumnWidth(
            min: AppLayout.inspectorMinimumWidth, ideal: AppLayout.inspectorIdealWidth,
            max: AppLayout.inspectorMaximumWidth)
    }

    // MARK: - Native Reader Toolbar

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Self.stepBack(&path)
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
        if readerModeBinding.wrappedValue == .story {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: highlightSelection) {
                    Label("Highlight", systemImage: "highlighter")
                }
                .help("Highlight the selected passage (⌘Y)")
                Button(action: beginNote) {
                    Label("Add Note", systemImage: "note.text.badge.plus")
                }
                .help("Add a private note to the selected passage (⇧⌘Y)")
                .popover(item: $noteDraft) { draft in
                    NoteComposerView(quote: draft.quote) { await saveNote(draft, body: $0) }
                }
                Button {
                    showsAnnotationsInspector.toggle()
                } label: {
                    Label("Annotations", systemImage: "sidebar.trailing")
                }
                .help("Show or hide highlights and notes (⌥⌘I)")
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
                .help("Go back")
                Button {
                    webAction = .goForward
                } label: {
                    Label("Web Forward", systemImage: "arrow.right")
                }
                .disabled(!webCanGoForward)
                .help("Go forward")
            }
            if readerModeBinding.wrappedValue == .overview {
                Button(action: checkForUpdates) {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(!canCheckForUpdates)
                .help("Check feeds for new reports in this story (⌥⌘R)")
            }
            Button(action: toggleSave) {
                Label(
                    isSaved ? "Remove from Saved Stories" : "Save Story",
                    systemImage: isSaved ? "bookmark.fill" : "bookmark")
            }
            .help(isSaved ? "Remove from saved stories (S)" : "Save story (S)")

            KnowledgeExportMenu(actions: knowledgeExportActions)

            if let url = URL(string: currentArticle.link) {
                ShareLink(item: url, subject: Text(currentArticle.title)) {
                    Label("Share Story", systemImage: "square.and.arrow.up")
                }
                .help("Share story")
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
            Picker("Reading Style", selection: themeManager.binding(\.articleTheme)) {
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
        if let url = WebLink.url(currentArticle.link) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Esc, B, ← and Back to Stories step back one reader; a sidebar section click or ⌘1–⌘4 returns to the list
    /// even when that section is already selected (#594).
    static func stepBack(_ path: inout NavigationPath, toList: Bool = false) {
        if toList {
            path = NavigationPath()
        } else if !path.isEmpty {
            path.removeLast()
        }
    }

    /// The summary panel's one generated-content label (DESIGN.md 9, #597): extractive when sentences were selected
    /// from the story, generated when the on-device model wrote it or has yet to.
    static func summaryLabel(modelIdentifier: String?) -> String {
        modelIdentifier == "apple.natural-language.fallback" ? "Extractive summary" : "Generated summary"
    }

    static func shouldPassThroughToSystem(modifiers: EventModifiers) -> Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// Whether keyboard focus is currently in an active text input field or note editor (#1206).
    static func isTextInputActive(
        firstResponder: Any? = NSApp.keyWindow?.firstResponder,
        isNoteDraftActive: Bool = false
    ) -> Bool {
        if isNoteDraftActive { return true }
        guard let firstResponder else { return false }
        if let text = firstResponder as? NSText, text.isEditable {
            return true
        }
        if let textField = firstResponder as? NSTextField, textField.isEditable {
            return true
        }
        return false
    }

    private func handleKeyPress(press: KeyPress) -> KeyPress.Result {
        guard !Self.shouldPassThroughToSystem(modifiers: press.modifiers) else { return .ignored }
        let textInputFocused = Self.isTextInputActive(isNoteDraftActive: noteDraft != nil)
        if press.key == .escape {
            if showsReadingOptions {
                showsReadingOptions = false
                return .handled
            }
            if textInputFocused { return .ignored }
            Self.stepBack(&path)
            return .handled
        }
        // When typing inside a note or text input, single-letter shortcuts must not hijack key events (#1206).
        if textInputFocused { return .ignored }

        if press.key == .leftArrow || press.characters == "b" || press.characters == "h" {
            Self.stepBack(&path)
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

    /// Earlier events only for the overview they were found for; none while a lookup is pending or after it failed.
    static func relatedEventsToShow(
        _ stored: (eventID: String, events: [RelatedStoryEvent])?, overviewEventID: String
    ) -> [RelatedStoryEvent] {
        guard let stored, stored.eventID == overviewEventID else { return [] }
        return stored.events.filter { $0.eventID != overviewEventID }
    }

    /// The reader lands on the overview when it was already showing one, or when the article was opened from
    /// "Earlier in This Story", even if an interrupted load reset the mode meanwhile.
    static func opensOnOverview(showingOverview: Bool, requestedArticleID: String?, articleID: String) -> Bool {
        showingOverview || requestedArticleID == articleID
    }

    static func readerAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : AppMotion.navigation
    }

    static func sourceLineAccessibilityLabel(source: String, publicationDateText: String, readingTimeEstimate: String)
        -> String
    {
        "\(source), \(publicationDateText), \(readingTimeEstimate)"
    }

    /// What an embed placeholder stands for: a post from its host, or content the reader cannot lay out.
    static func embedTitle(for block: ReaderBlock) -> String {
        if isTableNotice(block) { return "Large table on the publisher’s page" }
        if block.text == "Social post" { return "Embedded post" }
        if block.text == "Embedded media" { return "Embedded media" }
        return "Embedded content from \(block.text)"
    }

    private static func isTableNotice(_ block: ReaderBlock) -> Bool {
        block.imageURL == nil && block.text == "Table"
    }

    /// Section rules are quiet; Increase Contrast shows the full separator, as plain dividers do.
    static func dividerOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 1.0 : 0.15
    }

    /// Space below a reader block, scaled with the text. List items stay together; a heading sits close to the text
    /// it introduces and apart from what precedes it.
    static func blockSpacing(after block: ReaderBlock.Kind, before next: ReaderBlock.Kind?, scale: CGFloat) -> CGFloat {
        let isHeading = { (kind: ReaderBlock.Kind?) in kind == .heading || kind == .subheading }
        let points: CGFloat
        if isHeading(block) {
            points = AppSpacing.xs
        } else if isHeading(next) {
            points = AppSpacing.xl
        } else if block == .listItem && next == .listItem {
            points = AppSpacing.xs
        } else {
            points = AppSpacing.lg
        }
        return points * scale
    }

    static func quoteBarOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 1.0 : 0.5
    }

    static func capsuleBorderOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.35 : 0.08
    }

    private var secondaryText: Color {
        AppColor.secondaryText(for: contrast)
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
                    .accessibilityHidden(true)
                Text("Analyzing the story on device…")
                    .font(AppTypography.label)
                    .foregroundStyle(AppColor.secondaryText)
                    .accessibilityLabel("Analyzing story with on-device AI")
            }
            .modifier(ContentPanel())
        } else if let analysis = analysis {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(analysis.summary)
                    .font(AppTypography.overviewFont(.body, scale: readerTextScale))
                    .foregroundStyle(AppColor.primaryText)
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                    .textSelection(.enabled)

                if !analysis.keyPoints.isEmpty {
                    Divider().padding(.vertical, AppSpacing.xs)
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Key points")
                            .font(AppTypography.label)
                            .foregroundStyle(AppColor.secondaryText)
                            .padding(.top, AppSpacing.textStack)

                        ForEach(analysis.keyPoints, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                                Text("•")
                                    .foregroundStyle(AppColor.secondaryText)
                                    .accessibilityHidden(true)
                                Text(point)
                                    .font(AppTypography.overviewFont(.body, scale: readerTextScale))
                                    .foregroundStyle(AppColor.primaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                ReaderTagLayout(spacing: AppSpacing.xs) {
                    if let category = displayCategory {
                        summaryTag(category, isCategory: true)
                    }
                    let tags = EntityResult.readerTags(
                        from: analysis.entities, title: currentArticle.title,
                        description: currentArticle.description, text: currentArticle.fullContent ?? "")
                    ForEach(tags.prefix(6), id: \.name) { entity in
                        summaryTag(entity.name, isCategory: false)
                    }
                }
            }
            .modifier(ContentPanel())
        } else if analysisError != nil {
            NoticeView(tint: AppColor.warning) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppColor.warning)
                    Text("The summary could not be generated for this story.")
                        .font(AppTypography.callout)
                        .foregroundStyle(AppColor.secondaryText)
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
                Text(ai)
                    .font(AppTypography.overviewFont(.body, scale: readerTextScale))
                    .foregroundStyle(AppColor.primaryText)
                    .lineSpacing(AppTypography.bodyLineSpacing(for: themeManager.articleTheme) * readerTextScale)
                    .textSelection(.enabled)
            }
            .padding(AppSpacing.md)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(AppColor.border(for: contrast), lineWidth: AppLayout.hairline)
            )
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
                $0.version == ReaderDocument.currentVersion && $0.hasPublisherText && $0.hasCompleteArticleBody
            }) == true,
            let existing = currentArticle.fullContent, !ArticleContentRedactor.redactAndSplit(existing).isEmpty
        {
            contentState = .ready
            return
        }

        let link = currentArticle.link
        guard !link.isEmpty, let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else {
            contentState = .fallback(reason: "Invalid story link")
            return
        }
        let allowInsecure = appSettings.allowInsecureHTTP
        let targetId = currentArticle.id
        let expectedInputHash = currentArticle.publisherInputHash
        // A clear of derived data while the page loads refuses the body write (#982).
        let analysisGeneration = await articleStore.database.analysisGeneration

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
                    expectedInputHash: expectedInputHash,
                    expectedGeneration: analysisGeneration
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
            case .subscriberOnly:
                self.contentState = .publisherOnly(subscriber: true)
            case .httpError(403):
                // Bot checks and regional blocks: the publisher's own page still opens in the web view.
                self.contentState = .publisherOnly(subscriber: false)
            case .qualityValidationFailed(let reason):
                self.contentState = .fallback(reason: "Story quality check not met: \(reason)")
            case .httpError(let status):
                self.contentState = .fallback(reason: "Publisher returned HTTP \(status)")
            case .securityBlocked(let reason):
                self.contentState = .fallback(reason: "Security policy: \(reason)")
            case .emptyContent:
                self.contentState = .fallback(reason: "Publisher returned empty content")
            case .contentParsingFailed(let reason):
                self.contentState = .fallback(reason: "Could not extract story body: \(reason)")
            case .networkError(let reason):
                self.contentState = .fallback(reason: "Network error: \(reason)")
            }
            // After the state: a busy database must not delay the message, and the story may change during the write.
            if let barrier = ReaderBarrier(extraction.outcome) {
                await articleStore.recordReaderBarrier(barrier, articleID: targetId)
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
        // The analysis is saved only if nothing cleared derived data in the meantime (#844).
        let analysisGeneration = await articleStore.database.analysisGeneration

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
                result, for: targetArticle.id, expectedInputHash: targetArticle.publisherInputHash,
                expectedGeneration: analysisGeneration)
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
        guard isOverviewLoading != loading else { return }
        isOverviewLoading = loading
    }

    private var canCheckForUpdates: Bool {
        readerModeBinding.wrappedValue == .overview && currentOverview != nil && !isCheckingForUpdates
    }

    /// Refreshes the subscriptions, or waits for the refresh already running, and says in the overview header whether
    /// reports joined this story (#992). The line appears on the click and then changes in place (DESIGN.md 13).
    private func checkForUpdates() {
        guard canCheckForUpdates, let eventID = currentOverview?.eventID else { return }
        let articleID = activeArticle.id
        let check = UUID()
        storyUpdateCheck = check
        isCheckingForUpdates = true
        storyUpdateStatus = FeedManager.StoryUpdateResult.checkingText
        Task {
            let result = await feedManager.checkForUpdates(storyOf: articleID)
            // Regeneration can clear the overview while this event is still open. Resolve membership independently,
            // retrying if navigation changes the article during the database read.
            var activeEventID: String?
            while storyUpdateCheck == check {
                let activeID = activeArticle.id
                let resolvedEventID = try? await articleStore.database.eventID(forArticle: activeID)
                guard activeArticle.id == activeID else { continue }
                activeEventID = resolvedEventID
                break
            }
            isCheckingForUpdates = false
            // Another report of the same event may be open now; only a closed reader or another event drops it.
            guard storyUpdateCheck == check, activeEventID == eventID else {
                // A dropped result leaves no "Checking your feeds…" line behind.
                if storyUpdateStatus == FeedManager.StoryUpdateResult.checkingText { storyUpdateStatus = nil }
                return
            }
            storyUpdateCheck = nil
            storyUpdateStatus = result.statusText
            AccessibilityNotification.Announcement(result.statusText).post()
            // New members make the overview stale; it regenerates from the current reports.
            await loadEventOverviewForActiveArticle()
        }
    }

    private func loadEventOverviewForActiveArticle() async {
        let articleID = activeArticle.id
        let inputHash = currentArticle.publisherInputHash
        // A newer load (membership changed during Check for Updates) supersedes this one; only the latest may write state.
        overviewLoadSerial += 1
        let serial = overviewLoadSerial
        guard !Task.isCancelled else { return }
        let summaries = (try? await articleStore.eventFeedSummaries(for: [articleID])) ?? []
        guard !Task.isCancelled, activeArticle.id == articleID, overviewLoadSerial == serial,
            currentArticle.publisherInputHash == inputHash
        else { return }
        guard let summary = summaries.first, summary.isConfirmed, summary.sources.count >= 2 else {
            setOverviewLoading(false)
            currentOverview = nil
            overviewLoadedInputHash = nil
            eventMemberArticles = []
            relatedStories = nil
            experienceMode = .sourcePublication
            overviewRequestedArticleID = nil
            await OverviewGenerationCoordinator.shared.clearVisibleEvent(owner: overviewOwner)
            return
        }

        let eventID = summary.eventID
        let membershipVersion = summary.eventVersion

        if let existing = currentOverview,
            existing.eventID == eventID,
            overviewLoadedInputHash == inputHash,
            !existing.isStale(currentMembershipVersion: membershipVersion)
        {
            setOverviewLoading(false)
            let members = (try? await articleStore.eventMemberArticles(eventID: eventID)) ?? []
            guard !Task.isCancelled, activeArticle.id == articleID,
                currentArticle.publisherInputHash == inputHash
            else { return }
            eventMemberArticles = members.isEmpty ? [activeArticle] : members
            await loadRelatedStories(eventID: eventID, articleID: articleID)
            return
        }

        let members = (try? await articleStore.eventMemberArticles(eventID: eventID)) ?? []
        guard !Task.isCancelled, activeArticle.id == articleID, overviewLoadSerial == serial,
            currentArticle.publisherInputHash == inputHash
        else { return }
        let resolvedMembers = members.isEmpty ? [activeArticle] : members
        let eventTitle = resolvedMembers.first?.title ?? summary.members.first?.title ?? activeArticle.title

        // Never show another event's overview while this one loads. The reader returns to the overview by
        // itself only if it was already showing one (J/K across events); otherwise it stays on the article.
        let returnToOverview = Self.opensOnOverview(
            showingOverview: experienceMode == .eventOverview, requestedArticleID: overviewRequestedArticleID,
            articleID: articleID)
        if currentOverview?.eventID != eventID {
            currentOverview = nil
            overviewLoadedInputHash = nil
            if !returnToOverview {
                experienceMode = .sourcePublication
            }
        }
        // A mode the person picks while the overview generates (Story during a Check for Updates) is kept.
        let modeAtLoad = experienceMode
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

        guard !Task.isCancelled, activeArticle.id == articleID, overviewLoadSerial == serial,
            currentArticle.publisherInputHash == inputHash
        else { return }

        setOverviewLoading(false)
        if let doc = doc {
            currentOverview = doc
            overviewLoadedInputHash = inputHash
            eventMemberArticles = resolvedMembers
            if returnToOverview && viewMode == .reader && experienceMode == modeAtLoad {
                experienceMode = .eventOverview
                overviewRequestedArticleID = nil
            }
            await loadRelatedStories(eventID: eventID, articleID: articleID)
        } else {
            currentOverview = nil
            overviewLoadedInputHash = nil
            if experienceMode == .eventOverview {
                experienceMode = .sourcePublication
            }
            overviewRequestedArticleID = nil
        }
    }

    /// Optional navigation after the overview shows: a failure or slow lookup only leaves the section out.
    private func loadRelatedStories(eventID: String, articleID: String) async {
        guard relatedStories?.eventID != eventID else { return }
        let related = (try? await articleStore.relatedStoryEvents(eventID: eventID)) ?? []
        guard !Task.isCancelled, activeArticle.id == articleID else { return }
        relatedStories = (eventID, related)
    }

    /// Opens another source story with fresh reader state; the current story keeps its loaded content,
    /// because an unchanged content task would not run again after the reset.
    private func selectSourceArticle(_ article: FeedArticle) {
        guard article.id != activeArticle.id else { return }
        resetReaderState()
        activeArticle = article
    }

    /// Opens another story by id with fresh reader state, as moving to the next story does; a story that belongs to an
    /// event opens on its overview. False, with a notice, when the story is gone or the library cannot be read.
    @discardableResult
    private func openStory(id: String) async -> Bool {
        do {
            guard let article = try await articleStore.database.fetchArticles(limit: 1, id: id).first else {
                articleStore.operationError = "This story is no longer available in your archive."
                return false
            }
            guard !Task.isCancelled else { return false }
            // The open story: an unchanged id would not restart the content and overview tasks after a reset, and
            // would leave the reader loading. From the overview it opens that story's own view.
            guard article.id != activeArticle.id else {
                if experienceMode == .eventOverview { experienceMode = .sourcePublication }
                return true
            }
            resetReaderState()
            currentOverview = nil
            eventMemberArticles = []
            overviewRequestedArticleID = article.id
            activeArticle = article
            return true
        } catch {
            articleStore.operationError = "This story could not be opened. Please try again."
            return false
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

/// Menu commands for the open story; the names live in NewsApp, so this stays beside the reader.
struct ArticleNavigationCommands: ViewModifier {
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

// #1328 diagnostic only, never merged: NEWS_DIAG_NO_INSPECTOR removes the annotations inspector's split column.
extension View {
    @ViewBuilder
    func diagnosticInspector<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: () -> Content
    ) -> some View {
        if ProcessInfo.processInfo.environment["NEWS_DIAG_NO_INSPECTOR"] != nil {
            self
        } else {
            inspector(isPresented: isPresented, content: content)
        }
    }
}
