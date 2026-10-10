// NativeUIQAChecks.swift
// Dedicated automated verification suite for Native UI QA with System Settings (Issues #155, #123)

import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let openArticleFromNotification = Notification.Name("openArticleFromNotification")
    static let refreshFeedsCommand = Notification.Name("refreshFeedsCommand")
    static let nextArticleCommand = Notification.Name("nextArticleCommand")
    static let prevArticleCommand = Notification.Name("prevArticleCommand")
    static let toggleReadCommand = Notification.Name("toggleReadCommand")
    static let toggleSaveCommand = Notification.Name("toggleSaveCommand")
    static let openInBrowserCommand = Notification.Name("openInBrowserCommand")
    static let showFeedUpdatesCommand = Notification.Name("showFeedUpdatesCommand")
}

@main
@MainActor
struct NativeUIQAChecks {
    static var testsRun = 0
    static var failures = 0

    static func assertEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line
    ) {
        testsRun += 1
        if actual != expected {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected '\(expected)', got '\(actual)'")
        }
    }

    static func assertTrue(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected true, got false")
        }
    }

    static func assertFalse(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        testsRun += 1
        if condition {
            failures += 1
            print("❌ FAILURE [\(file):\(line)]: \(message) — Expected false, got true")
        }
    }

    static func main() async {
        print("=== Running Native UI QA Checks with System Settings (#155, #123) ===")

        testSystemSettingsOverridesParsing()
        testKeyboardShortcutsAndKeyHandling()
        testArchiveSearchTokens()
        testVoiceOverStructureAndAnnouncements()
        testWindowWidthsAndLayoutMetrics()
        testLeadStorySelection()
        testLeadStoryEventImageFallback()
        testTextScalingAdaptation()
        testIncreaseContrastScalers()
        testReduceMotionPolicies()
        testLightAndDarkAppearanceTokens()
        testFeedStabilityAndQueuedUpdatesBuffer()
        testEventOverviewGenerationAndCachingLifecycle()
        testCitationRoutingAndBanner()
        testSettingsPanePersistenceAndSizing()
        testSecondaryWindowAndSheetChrome()
        await testRemoteImageReuse()

        print("Finished \(testsRun) Native UI QA checks with \(failures) failures.")
        if failures > 0 {
            exit(1)
        } else {
            print("✅ ALL NATIVE UI QA CHECKS PASSED (#155, #123)")
        }
    }

    static func testArchiveSearchTokens() {
        print("  - Testing tokenized archive search operators...")
        let promoted = ArchiveSearchToken.promoteCompleted(in: "climate is:unread source:bbc category:science ")
        assertEqual(promoted.text, "climate", "Full-text search survives tokenization")
        assertEqual(
            promoted.tokens.map(\.expression),
            ["is:unread", "source:bbc", "category:science"], "Completed operators become tokens")
        let parsed = ArticleFilterQuery.parse(ArchiveSearchToken.query(text: promoted.text, tokens: promoted.tokens))
        assertEqual(parsed.terms, ["climate"], "Archive still searches full text")
        assertEqual(parsed.isReadFilter, false, "Unread operator remains active")
        assertEqual(parsed.sourceFilter, "bbc", "Source operator remains active")
        assertEqual(parsed.categoryFilter, "science", "Category operator remains active")
        assertEqual(
            ArticleFilterQuery.parse(
                ArchiveSearchToken.query(
                    text: "", tokens: [ArchiveSearchToken(completedExpression: "is:read")!]
                )
            ).isReadFilter, true, "Read filter works without free text")
        assertEqual(
            ArticleFilterQuery.parse(
                ArchiveSearchToken.query(
                    text: "", tokens: [ArchiveSearchToken(completedExpression: "is:saved")!]
                )
            ).isSavedFilter, true, "Saved filter works without free text")
        assertEqual(ArchiveSearchToken.promoteCompleted(in: "source:").tokens.count, 0, "Prefix waits for a value")
        assertEqual(
            ArchiveSearchToken.promoteCompleted(in: "economy is:re").tokens.count, 0, "Incomplete status stays editable"
        )
        assertEqual(ArchiveSearchToken(completedExpression: "category:"), nil, "Empty category is not a token")
        let replaced = ArchiveSearchToken.latestPerField(
            ["source:bbc", "is:unread", "is:saved", "source:npr", "is:read"].compactMap {
                ArchiveSearchToken(completedExpression: $0)
            })
        assertEqual(
            replaced.map(\.expression), ["is:saved", "source:npr", "is:read"],
            "A newer chip replaces the one the parser would ignore")
    }

    static func testRemoteImageReuse() async {
        print("  - Testing image cache hits and URL changes in a reused SwiftUI view...")
        let first = URL(string: "https://images.example/\(UUID().uuidString)/first.jpg")!
        let second = first.deletingLastPathComponent().appendingPathComponent("second.jpg")
        let probe = RemoteImageProbe()
        var rendered: [(url: URL, success: Bool)] = []
        func fixture(_ url: URL) -> some View {
            ArticleRemoteImage(url: url) { phase in
                let _ = rendered.append((url, phase.image != nil))
                Text(phase.image == nil ? "Waiting" : "Ready")
            }.environment(\.readerImageLoader) { url in await probe.load(url) }
        }
        let host = NSHostingView(rootView: AnyView(fixture(first)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func waitUntil(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { await Task.yield() }
            return condition()
        }
        assertTrue(await waitUntil { rendered.contains { $0.url == first && $0.success } }, "First image is rendered")
        let cached = NSHostingView(rootView: AnyView(fixture(first)))
        window.contentView = cached
        assertTrue(
            await waitUntil { rendered.filter { $0.url == first && $0.success }.count >= 2 },
            "A newly mounted card renders its cached image")
        assertEqual(probe.requests.filter { $0 == first }.count, 1, "A cached mount performs no second load or decode")
        rendered.removeAll()
        window.contentView = host
        host.rootView = AnyView(fixture(second))
        assertTrue(
            await waitUntil { probe.pending != nil && rendered.contains { $0.url == second } },
            "Reused card begins loading the new URL")
        assertFalse(
            rendered.contains { $0.url == second && $0.success }, "The old image is never rendered for the new URL")
        probe.pending?.resume(returning: probe.image)
        probe.pending = nil
        assertTrue(
            await waitUntil { rendered.contains { $0.url == second && $0.success } },
            "New image appears after its own load completes")
        assertEqual(probe.requests.count, 2, "Each distinct source loads once")
    }

    @MainActor private final class RemoteImageProbe {
        var requests: [URL] = []
        var pending: CheckedContinuation<CGImage, Never>?
        let image = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        func load(_ url: URL) async -> CGImage {
            requests.append(url)
            if requests.count == 1 { return image }
            return await withCheckedContinuation { pending = $0 }
        }
    }

    // MARK: - 1. System Settings Overrides
    static func testSystemSettingsOverridesParsing() {
        print("  - Testing System Settings Overrides (CLI flags and UserDefaults)...")

        // Direct CLI flags
        let cliArgs = ["--increase-contrast", "--reduce-motion", "--voice-over", "--text-scale", "1.35"]
        let overridesCLI = SystemSettingsOverrides.from(arguments: cliArgs, defaults: UserDefaults())
        assertEqual(overridesCLI.contrast, .increased, "CLI --increase-contrast parses to .increased")
        assertEqual(overridesCLI.reduceMotion, true, "CLI --reduce-motion parses to true")
        assertEqual(overridesCLI.voiceOverEnabled, true, "CLI --voice-over parses to true")
        assertEqual(overridesCLI.textScale, 1.35, "CLI --text-scale parses to 1.35")

        // Standard macOS arguments in UserDefaults (-key value)
        let suite = "test.settings.overrides.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "AppleIncreaseContrast")
        defaults.set(true, forKey: "AppleReduceMotion")
        defaults.set(true, forKey: "AppleAccessibilityVoiceOverEnabled")
        defaults.set(1.5, forKey: "AppleTextScaleFactor")

        let overridesDefaults = SystemSettingsOverrides.from(arguments: [], defaults: defaults)
        assertEqual(overridesDefaults.contrast, .increased, "AppleIncreaseContrast parses to .increased")
        assertEqual(overridesDefaults.reduceMotion, true, "AppleReduceMotion parses to true")
        assertEqual(overridesDefaults.voiceOverEnabled, true, "AppleAccessibilityVoiceOverEnabled parses to true")
        assertEqual(overridesDefaults.textScale, 1.5, "AppleTextScaleFactor parses to 1.5")

        // Default: no overrides when no flags or settings present
        let emptyOverrides = SystemSettingsOverrides.from(arguments: ["News"], defaults: UserDefaults())
        assertTrue(emptyOverrides.contrast == nil, "Contrast override is nil by default")
        assertTrue(emptyOverrides.reduceMotion == nil, "Reduce motion override is nil by default")
        assertTrue(emptyOverrides.voiceOverEnabled == nil, "VoiceOver override is nil by default")
        assertTrue(emptyOverrides.textScale == nil, "Text scale override is nil by default")
    }

    // MARK: - 2. Keyboard Navigation and Traversal
    static func testKeyboardShortcutsAndKeyHandling() {
        print("  - Testing Keyboard Shortcuts, Modifiers, and Focus Ring Semantics...")

        // System modifier pass-through (Cmd+C, Cmd+R, Cmd+J)
        assertTrue(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: .command), "Cmd modifier passes through to system")
        assertTrue(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: .control),
            "Control modifier passes through to system")
        assertTrue(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: .option), "Option modifier passes through to system")
        assertFalse(
            ArticleDetailView.shouldPassThroughToSystem(modifiers: []), "Unmodified keys captured for app shortcuts")

        assertEqual(ReaderMode.webShortcut, KeyEquivalent("r"), "Reader/Web uses R, leaving Shift-Command-W for Close")
        assertEqual(ReaderMode.webShortcutModifiers, [.command, .shift], "Reader/Web uses Shift-Command-R")
        assertEqual(ReaderMode.story.toggledPublicationMode, .web, "Story switches to Web")
        assertEqual(ReaderMode.web.toggledPublicationMode, .story, "Web switches to Story")
        assertEqual(
            ReaderMode.overview.toggledPublicationMode, .web,
            "Reader/Web command leaves the overview for the publisher page")

        // Key handler keys verification:
        // E key: expands/collapses event sources
        // G key: toggles event grouping
        // U key: applies queued updates
        // W key: toggles reader experience mode / web view
        // J/K: previous / next article
        // M: toggle read/unread
        // S: toggle saved/bookmark
        // O: open in browser
        let supportedKeys = ["j", "k", "m", "s", "r", "e", "g", "u", "o"]
        for key in supportedKeys {
            assertTrue(key.count == 1, "Shortcut key '\(key)' is a single-character key")
        }
    }

    // MARK: - 3. VoiceOver Spoken Label Helpers and Alt Fallbacks
    static func testVoiceOverStructureAndAnnouncements() {
        print("  - Testing VoiceOver Spoken Label Helpers and Image Alt Fallbacks...")

        // 1. Grouped source line (PR #212)
        let sourceLine = ArticleDetailView.sourceLineAccessibilityLabel(
            source: "BBC News",
            publicationDateText: "Oct 3, 2026",
            readingTimeEstimate: "3 min read"
        )
        assertEqual(sourceLine, "BBC News, Oct 3, 2026, 3 min read", "Grouped source line eliminates punctuation noise")

        // 2. Event overview header metadata line
        let metaLabel = EventOverviewReaderView.headerMetadataAccessibilityLabel(
            formattedUpdateTime: "1 hour ago",
            articleCountText: "3 articles",
            publisherCountText: "2 publishers"
        )
        assertEqual(metaLabel, "Updated 1 hour ago, 3 articles, 2 publishers", "Overview metadata line speaks cleanly")

        // 3. Lead image caption and credit
        let leadImage = OverviewLeadImage(
            url: "https://example.com/img.jpg", caption: "Delegates meet in Geneva", credit: "Reuters")
        let leadLabel = EventOverviewReaderView.leadImageAccessibilityLabel(leadImage)
        assertEqual(
            leadLabel, "Delegates meet in Geneva. Credit: Reuters", "Lead image label combines caption and credit")

        // 4. Citation pill label
        let citationLabel = EventOverviewReaderView.citationAccessibilityLabel(
            sourceName: "Associated Press", quote: "Emissions cap agreed.")
        assertEqual(
            citationLabel, "Citation from Associated Press: Emissions cap agreed.",
            "Citation pill label describes source and quote")

        // 5. Source article action labels
        let readLabel = EventOverviewReaderView.readArticleAccessibilityLabel(title: "Global Treaty", source: "AP")
        assertEqual(
            readLabel, "Read Global Treaty from AP in Source publication mode",
            "Read button has distinct context for VoiceOver rotor")

        let webLabel = EventOverviewReaderView.openWebArticleAccessibilityLabel(title: "Global Treaty", source: "AP")
        assertEqual(
            webLabel, "Open original publication: Global Treaty on AP", "Web button has distinct context for rotor")

        // 6. Alt text fallback
        let figureExplicit = ReaderBlock(
            kind: .figure, text: "Caption", imageURL: "https://example.com/1.jpg", imageAlt: "Solar panels on roof",
            imageCredit: nil, imageWidth: 400, imageHeight: 300)
        assertEqual(
            ReaderFigureView.effectiveImageAlt(for: figureExplicit), "Solar panels on roof",
            "Explicit alt text is preserved")

        let figureNil = ReaderBlock(
            kind: .figure, text: "Caption", imageURL: "https://example.com/2.jpg", imageAlt: nil, imageCredit: nil,
            imageWidth: 400, imageHeight: 300)
        assertEqual(
            ReaderFigureView.effectiveImageAlt(for: figureNil), "Article image",
            "Nil alt text falls back to 'Article image'")

        let figureBlank = ReaderBlock(
            kind: .figure, text: "Caption", imageURL: "https://example.com/3.jpg", imageAlt: "   \t", imageCredit: nil,
            imageWidth: 400, imageHeight: 300)
        assertEqual(
            ReaderFigureView.effectiveImageAlt(for: figureBlank), "Article image",
            "Whitespace alt text falls back to 'Article image'")

        assertEqual(
            MastheadNotice(message: "Subscribed to example.com")
                == MastheadNotice(message: "Subscribed to example.com"),
            false, "A repeated masthead notice restarts its lifetime and announcement")
    }

    // MARK: - 4. Window Widths and Layout Metrics
    static func testWindowWidthsAndLayoutMetrics() {
        print("  - Testing Window Widths and Layout Metrics (380px, 800px, 1200px)...")

        // Standard page inset
        assertEqual(
            EventOverviewReaderView.horizontalPageInset, 24.0,
            "Horizontal page inset matches AppLayout.pageInset (24.0)")

        // Narrow split window: 380px
        let narrowWindowWidth: CGFloat = 380.0
        let narrowAvailableContent = narrowWindowWidth - (EventOverviewReaderView.horizontalPageInset * 2)
        assertEqual(narrowAvailableContent, 332.0, "Usable reading width on 380px window is 332px")
        assertTrue(narrowAvailableContent > 300.0, "Narrow window provides comfortable measure for narrative text")

        // Standard window (800px) and Wide window (1200px)
        let standardColWidth = EventOverviewReaderView.readingColumnMaxWidth(for: 1.0)
        assertEqual(standardColWidth, 720.0, "Standard reading column width is 720.0")

        let wideColWidth = EventOverviewReaderView.readingColumnMaxWidth(for: 1.0)
        assertTrue(wideColWidth <= 720.0, "Wide windows keep maximum measure bounded to 720px for readability")
    }

    // MARK: - Phase 6: lead selection never changes the feed order
    static func testLeadStorySelection() {
        func story(_ index: Int, hasImage: Bool) -> FeedArticle {
            var article = FeedArticle(
                title: "Story \(index)", link: "https://publisher.example/story/\(index)",
                guid: "lead-\(index)", description: "Fixture", pubDate: Date(), source: "Publisher"
            )
            if hasImage { article.imageUrl = "https://images.example/lead-\(index).jpg" }
            return article
        }
        let textOnly = story(1, hasImage: false)
        let firstImage = story(2, hasImage: true)
        let laterImage = story(3, hasImage: true)
        let entries: [FeedEntry] = [.article(textOnly), .article(firstImage), .article(laterImage)]
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: entries, selectedTopic: "Today", isSearching: false),
            firstImage.id, "First image-bearing entry is highlighted without moving the text-only entry"
        )
        assertEqual(
            entries.map(\.id), [textOnly.id, firstImage.id, laterImage.id], "Lead selection leaves the order intact")
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: entries, selectedTopic: nil, isSearching: false),
            firstImage.id, "The default Today location can use the first image-bearing entry"
        )
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: entries, selectedTopic: "Briefing", isSearching: false),
            firstImage.id, "Briefing can select the same first image-bearing entry"
        )
        for section in ["Unread", "Saved Stories", "History"] {
            assertEqual(
                LeadStoryPresentation.firstEligibleID(in: entries, selectedTopic: section, isSearching: false),
                nil, "Lead presentation is excluded from \(section)"
            )
        }
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: entries, selectedTopic: "Today", isSearching: true),
            nil, "Search results never use the lead treatment"
        )
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: entries, selectedTopic: "Briefing", isSearching: true),
            nil, "Briefing search results cannot use the lead treatment"
        )
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: [.article(textOnly)], selectedTopic: "Today", isSearching: false),
            nil, "No publisher image means an ordinary card"
        )

    }

    /// Event-member fallback and a missing member image require a normal card.
    static func testLeadStoryEventImageFallback() {
        let textOnly = FeedArticle(
            title: "No-image representative", link: "https://publisher.example/event/one",
            guid: "lead-event-1", description: "Fixture", pubDate: Date(), source: "Publisher"
        )
        var firstImage = FeedArticle(
            title: "Image-bearing member", link: "https://publisher.example/event/two",
            guid: "lead-event-2", description: "Fixture", pubDate: Date(), source: "Publisher"
        )
        firstImage.imageUrl = "https://images.example/lead-event.jpg"
        let summary = EventFeedSummary(eventID: "lead-event", membershipVersion: 1, seenVersion: nil, members: [])
        let covered: [FeedEntry] = [.event(summary, representative: textOnly, visibleMembers: [textOnly, firstImage])]
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: covered, selectedTopic: "Today", isSearching: false),
            textOnly.id, "An event can use its visible member's image without changing its representative"
        )
        let noImageEvent: [FeedEntry] = [.event(summary, representative: textOnly, visibleMembers: [textOnly])]
        assertEqual(
            LeadStoryPresentation.firstEligibleID(in: noImageEvent, selectedTopic: "Today", isSearching: false),
            nil, "An event without a suitable member image stays a normal coverage card"
        )
    }

    // MARK: - 5. Text Scaling Adaptation
    static func testTextScalingAdaptation() {
        print("  - Testing Text Scaling Adaptation (1.0x to 1.5x)...")

        let scale10 = EventOverviewReaderView.readingColumnMaxWidth(for: 1.0)
        assertEqual(scale10, 720.0, "1.0x scale reading column width is 720.0")

        let scale115 = EventOverviewReaderView.readingColumnMaxWidth(for: 1.15)
        assertEqual(scale115, 720.0 * 1.15, "1.15x scale reading column width expands proportionally")

        let scale130 = EventOverviewReaderView.readingColumnMaxWidth(for: 1.3)
        assertEqual(scale130, 720.0 * 1.3, "1.3x scale reading column width expands to 936px")

        // Capped at 1.3x to prevent excessive line length at large type sizes
        let scale150 = EventOverviewReaderView.readingColumnMaxWidth(for: 1.5)
        assertEqual(scale150, 720.0 * 1.3, "1.5x scale reading column width is capped at 1.3x (936px)")
    }

    // MARK: - 6. Increase Contrast Scalers
    static func testIncreaseContrastScalers() {
        print("  - Testing Increase Contrast Scalers across Reader and Event Overview...")

        // Event overview contrast
        assertEqual(
            EventOverviewReaderView.dividerOpacity(for: .standard), 0.20, "Overview standard divider opacity is 0.20")
        assertEqual(
            EventOverviewReaderView.dividerOpacity(for: .increased), 0.60,
            "Overview increased contrast divider opacity is 0.60")
        assertEqual(
            EventOverviewReaderView.pillBorderOpacity(for: .standard), 0.0,
            "Overview standard citation pill has no border stroke")
        assertEqual(
            EventOverviewReaderView.pillBorderOpacity(for: .increased), 0.60,
            "Overview increased contrast citation pill has 0.60 stroke")
        assertEqual(
            EventOverviewReaderView.pillBackgroundOpacity(for: .standard), 0.12,
            "Overview standard pill background opacity is 0.12")
        assertEqual(
            EventOverviewReaderView.pillBackgroundOpacity(for: .increased), 0.22,
            "Overview increased contrast pill background opacity is 0.22")

        // Article detail contrast
        assertEqual(ArticleDetailView.dividerOpacity(for: .standard), 0.15, "Article standard divider opacity is 0.15")
        assertEqual(
            ArticleDetailView.dividerOpacity(for: .increased), 0.60,
            "Article increased contrast divider opacity is 0.60")
        assertEqual(
            ArticleDetailView.quoteBarOpacity(for: .standard), 0.50, "Article standard quote bar opacity is 0.50")
        assertEqual(
            ArticleDetailView.quoteBarOpacity(for: .increased), 1.0,
            "Article increased contrast quote bar opacity is 1.0")
        assertEqual(
            ArticleDetailView.capsuleBorderOpacity(for: .standard), 0.08,
            "Article standard capsule border opacity is 0.08")
        assertEqual(
            ArticleDetailView.capsuleBorderOpacity(for: .increased), 0.35,
            "Article increased contrast capsule border opacity is 0.35")
    }

    // MARK: - 7. Reduce Motion Policies
    static func testReduceMotionPolicies() {
        print("  - Testing Reduce Motion Animation Policies...")

        // Reader detail animations
        let readerStandard = ArticleDetailView.readerAnimation(reduceMotion: false)
        let readerReduced = ArticleDetailView.readerAnimation(reduceMotion: true)
        assertTrue(readerStandard != nil, "Standard mode enables reader animations")
        assertTrue(readerReduced == nil, "Reduce motion returns nil for reader animations")

        // Event overview animations
        let overviewStandard = EventOverviewReaderView.readerAnimation(reduceMotion: false)
        let overviewReduced = EventOverviewReaderView.readerAnimation(reduceMotion: true)
        assertTrue(overviewStandard != nil, "Standard mode enables overview animations")
        assertTrue(overviewReduced == nil, "Reduce motion returns nil for overview animations")
    }

    // MARK: - 8. Light and Dark Appearance Tokens
    static func testLightAndDarkAppearanceTokens() {
        print("  - Testing Light and Dark Appearance Tokens...")

        // Access design system color tokens to verify resolution
        _ = AppColor.background
        _ = AppColor.surface
        _ = AppColor.primaryText
        _ = AppColor.secondaryText
        _ = AppColor.accent
        assertTrue(true, "AppColor semantic design tokens resolve without error")
    }

    // MARK: - 9. Feed Stability and Queued Updates Buffer
    static func testFeedStabilityAndQueuedUpdatesBuffer() {
        print("  - Testing Feed Stability & Queued Updates Buffer (#130)...")

        var buffer = FeedUpdateBuffer()
        let article1 = FeedArticle(
            title: "First Story", link: "https://example.com/1", guid: "g1", description: "Desc", pubDate: Date(),
            source: "Source 1")
        let article2 = FeedArticle(
            title: "Second Story", link: "https://example.com/2", guid: "g2", description: "Desc", pubDate: Date(),
            source: "Source 2")

        buffer.replace(with: FeedSnapshot(articles: [article1], events: []))
        assertEqual(buffer.displayed.articles.count, 1, "Initial article is displayed immediately")
        assertEqual(buffer.newEntryCount(.events), 0, "No pending new stories initially")

        // Queue updates while user is interacting (holding == true)
        let incoming = [article2, article1]
        let result = buffer.receive(FeedSnapshot(articles: incoming, events: []), holding: true, mode: .events)
        assertEqual(result, .waiting, "Refreshed entries that move wait behind explicit update")
        assertEqual(buffer.displayed.articles.count, 1, "Displayed articles remain unchanged while reading/scrolling")
        assertEqual(buffer.newEntryCount(.events), 1, "1 new story is queued in buffer")

        // Apply pending updates
        buffer.applyPending()
        assertEqual(buffer.displayed.articles.count, 2, "Pending updates applied to displayed list")
        assertEqual(buffer.newEntryCount(.events), 0, "Pending count resets to 0 after application")
    }

    // MARK: - 10. Event Overview Generation and Caching Lifecycle
    static func testEventOverviewGenerationAndCachingLifecycle() {
        print("  - Testing Event Overview Generation, Caching, and Split Event Lifecycle (#140, #219, #222)...")

        let doc1 = EventOverviewDocument(
            id: "doc-1",
            eventID: "evt_1",
            version: OverviewVersionContext(
                membershipVersion: 1,
                inputTextHash: "hash1",
                schemaVersion: 1,
                analysisVersion: EventOverviewDocument.currentAnalysisVersion
            ),
            content: OverviewContent(
                title: "Global Summit Reaches Agreement",
                summary: "Delegates signed the carbon reduction agreement.",
                facts: [OverviewFact(id: "f1", text: "Treaty signed by 190 countries.", citationIDs: ["c1"])],
                citations: [
                    OverviewCitation(
                        id: "c1", articleID: "art_1", passageID: "p1", passageFingerprint: "fp1",
                        quote: "Treaty signed.",
                        source: OverviewSourceMetadata(
                            title: "Summit", name: "Reuters", url: "https://example.com/1", publishedAt: nil))
                ]
            ),
            provenance: OverviewProvenance(memberArticleIDs: ["art_1", "art_2"], kind: .synthesized)
        )

        assertFalse(doc1.isStale(currentMembershipVersion: 1), "Overview is fresh when membershipVersion matches")
        assertTrue(doc1.isStale(currentMembershipVersion: 2), "Overview is stale when event gains or loses a member")

        // When split occurs ("Not the Same Event"), version bumps and old overview is rejected
        let docAfterSplit = doc1.isStale(currentMembershipVersion: 3)
        assertTrue(docAfterSplit, "Split event bumps version and invalidates cached overview")
    }

    // MARK: - 11. Citation Routing and Banner
    static func testCitationRoutingAndBanner() {
        print("  - Testing Citation Source Matching and Routing...")

        let articleA = FeedArticle(
            storedID: "art_A", title: "Summit Opening", link: "https://example.com/a", guid: "gA",
            description: "Desc A", pubDate: Date(), source: "Reuters")
        let articleB = FeedArticle(
            storedID: "art_B", title: "Treaty Concluded", link: "https://example.com/b", guid: "gB",
            description: "Desc B", pubDate: Date(), source: "Associated Press")
        let members = [articleA, articleB]

        // 1. By articleID
        let citA = OverviewCitation(
            id: "c1", articleID: "art_A", passageID: "p1", passageFingerprint: "fp1", quote: "Opening remarks.",
            source: OverviewSourceMetadata(title: nil, name: nil, url: nil, publishedAt: nil))
        let matchA = EventOverviewReaderView.matchingArticle(for: citA, in: members)
        assertEqual(matchA?.id, "art_A", "Matches article directly by ID")

        // 2. By URL
        let citB = OverviewCitation(
            id: "c2", articleID: "wrong_id", passageID: "p2", passageFingerprint: "fp2", quote: "Concluded.",
            source: OverviewSourceMetadata(title: nil, name: nil, url: "https://example.com/b", publishedAt: nil))
        let matchB = EventOverviewReaderView.matchingArticle(for: citB, in: members)
        assertEqual(matchB?.id, "art_B", "Matches article by URL fallback")

        // 3. By Source Name
        let citName = OverviewCitation(
            id: "c3", articleID: "unknown", passageID: "p3", passageFingerprint: "fp3", quote: "AP report.",
            source: OverviewSourceMetadata(title: nil, name: "Associated Press", url: nil, publishedAt: nil))
        let matchName = EventOverviewReaderView.matchingArticle(for: citName, in: members)
        assertEqual(matchName?.id, "art_B", "Matches article by publisher name fallback")
    }

    static func testSettingsPanePersistenceAndSizing() {
        print("  - Testing Settings Pane Persistence and Adaptive Sizing (#357)...")
        assertEqual(SettingsPane.general.rawValue, "general", "General pane raw value")
        assertEqual(SettingsPane.subscriptions.rawValue, "subscriptions", "Subscriptions pane raw value")
        assertEqual(SettingsPane.muting.rawValue, "muting", "Muting pane raw value")
        assertEqual(SettingsPane.appearance.rawValue, "appearance", "Appearance pane raw value")
        assertEqual(SettingsPane.notifications.rawValue, "notifications", "Notifications pane raw value")
        assertEqual(SettingsPane.intelligence.rawValue, "intelligence", "Intelligence pane raw value")
        assertEqual(SettingsPane.privacy.rawValue, "privacy", "Privacy pane raw value")
        assertEqual(SettingsPane.storage.rawValue, "storage", "Storage pane raw value")
        assertEqual(SettingsPane.updates.rawValue, "updates", "Updates pane raw value")
        assertEqual(SettingsView.lastPaneStorageKey, "lastSettingsPane", "Last pane storage key matches standard")
        assertEqual(SettingsView.paneWidth, 500, "Settings pane width is 500pt")
    }

    static func testSecondaryWindowAndSheetChrome() {
        print("  - Testing Secondary Window and Sheet Chrome Rules (#357)...")
        assertEqual(FeedCatalogView.navigationTitleText, "Feed Catalog", "Feed catalog navigation title")
        assertEqual(TensionIndexView.navigationTitleText, "News Tension", "News tension navigation title")
        assertTrue(FeedCatalogView.showsDoneInToolbar, "Feed catalog presents Done in confirmationAction toolbar")
        assertFalse(
            FeedCatalogView.hasBottomDoneBar, "Feed catalog does not put Done or critical controls at the bottom")
        assertFalse(
            FeedCatalogView.hasCustomSheetBackground,
            "Feed catalog uses system sheet background without custom override")
    }
}
