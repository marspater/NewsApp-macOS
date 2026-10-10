// EventOverviewAccessibilityTests.swift
// Dedicated accessibility regression test suite for Event Overview reader mode (Issue #155)

import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let nextArticleCommand = Notification.Name("nextArticleCommand")
    static let prevArticleCommand = Notification.Name("prevArticleCommand")
    static let toggleReadCommand = Notification.Name("toggleReadCommand")
    static let toggleSaveCommand = Notification.Name("toggleSaveCommand")
    static let openInBrowserCommand = Notification.Name("openInBrowserCommand")
}

@main
@MainActor
struct EventOverviewAccessibilityTests {
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
        print("=== Running Event Overview Accessibility Tests (Issue #155) ===")

        testCitationSourceResolution()
        testSparseSectionsFiltering()
        testVoiceOverLabelsAndSemantics()
        testIncreaseContrastScalers()
        testReduceMotionPolicy()
        testTextScalingAndLayoutMetrics()

        print("Finished \(testsRun) event overview accessibility checks with \(failures) failures.")
        if failures > 0 {
            exit(1)
        } else {
            print("✅ ALL EVENT OVERVIEW ACCESSIBILITY CHECKS PASSED")
        }
    }

    // MARK: - 1. Citation Source Resolution
    static func testCitationSourceResolution() {
        print("  - Testing Citation Source Resolution (opening correct source)...")

        let article1 = FeedArticle(
            storedID: "art_101",
            title: "Global Climate Summit Reaches Historic Treaty",
            link: "https://example.com/climate-summit",
            guid: "guid_101",
            description: "Delegates from 190 nations agreed on carbon reduction targets.",
            pubDate: Date(),
            source: "Reuters"
        )

        let article2 = FeedArticle(
            storedID: "art_102",
            title: "Nations Pledge Stricter Methane Caps at Summit",
            link: "https://example.com/methane-pledge",
            guid: "guid_102",
            description: "Methane reduction will be expedited over five years.",
            pubDate: Date(),
            source: "Associated Press"
        )

        let articles = [article1, article2]

        // 1. Exact match by articleID
        let citationByID = OverviewCitation(
            id: "cit_1",
            articleID: "art_101",
            passageID: "pass_1",
            passageFingerprint: "fp1",
            quote: "Delegates agreed on carbon targets.",
            source: OverviewSourceMetadata(
                title: "Global Climate Summit Reaches Historic Treaty", name: "Reuters",
                url: "https://example.com/climate-summit", publishedAt: nil)
        )
        let resolvedByID = EventOverviewReaderView.matchingArticle(for: citationByID, in: articles)
        assertEqual(resolvedByID?.id, "art_101", "Matches article directly by articleID")
        assertEqual(resolvedByID?.source, "Reuters", "Resolved article has matching source")

        // 2. Match by sourceURL when articleID is unknown or different
        let citationByURL = OverviewCitation(
            id: "cit_2",
            articleID: "unknown_id",
            passageID: "pass_2",
            passageFingerprint: "fp2",
            quote: "Methane reduction will be expedited.",
            source: OverviewSourceMetadata(
                title: nil, name: nil, url: "https://example.com/methane-pledge", publishedAt: nil)
        )
        let resolvedByURL = EventOverviewReaderView.matchingArticle(for: citationByURL, in: articles)
        assertEqual(resolvedByURL?.id, "art_102", "Matches article by sourceURL fallback")

        // 3. Match by sourceTitle when articleID is unknown
        let citationByTitle = OverviewCitation(
            id: "cit_3",
            articleID: "different_id",
            passageID: "pass_3",
            passageFingerprint: "fp3",
            quote: "Historic treaty signed.",
            source: OverviewSourceMetadata(
                title: "Global Climate Summit Reaches Historic Treaty", name: nil, url: nil, publishedAt: nil)
        )
        let resolvedByTitle = EventOverviewReaderView.matchingArticle(for: citationByTitle, in: articles)
        assertEqual(resolvedByTitle?.id, "art_101", "Matches article by sourceTitle fallback")

        // 4. Match by sourceName (case-insensitive)
        let citationByName = OverviewCitation(
            id: "cit_4",
            articleID: "mismatched",
            passageID: "pass_4",
            passageFingerprint: "fp4",
            quote: "Methane caps agreed.",
            source: OverviewSourceMetadata(title: nil, name: "associated press", url: nil, publishedAt: nil)
        )
        let resolvedByName = EventOverviewReaderView.matchingArticle(for: citationByName, in: articles)
        assertEqual(resolvedByName?.id, "art_102", "Matches article by case-insensitive sourceName")

        // 5. Unresolvable citation returns nil safely
        let citationUnresolvable = OverviewCitation(
            id: "cit_5",
            articleID: "ghost",
            passageID: "pass_5",
            passageFingerprint: "fp5",
            quote: "Uncited quote.",
            source: OverviewSourceMetadata(
                title: "Unknown", name: "Bloomberg", url: "https://bloomberg.com/other", publishedAt: nil)
        )
        let resolvedGhost = EventOverviewReaderView.matchingArticle(for: citationUnresolvable, in: articles)
        assertTrue(resolvedGhost == nil, "Returns nil when citation has no matching member article")
    }

    // MARK: - 2. Sparse Sections Filtering
    static func testSparseSectionsFiltering() {
        print("  - Testing Sparse Sections Filtering (empty sections stay hidden)...")

        // Summary
        assertFalse(EventOverviewReaderView.hasSummaryContent(""), "Empty summary is considered absent")
        assertFalse(EventOverviewReaderView.hasSummaryContent("   \n\t  "), "Whitespace summary is considered absent")
        assertTrue(
            EventOverviewReaderView.hasSummaryContent("A concise introductory paragraph."),
            "Non-empty summary is present")

        // Lead Image
        assertFalse(EventOverviewReaderView.hasLeadImageContent(nil), "Nil lead image is absent")
        assertFalse(
            EventOverviewReaderView.hasLeadImageContent(OverviewLeadImage(url: "", caption: nil, credit: nil)),
            "Empty lead image URL is absent")
        assertFalse(
            EventOverviewReaderView.hasLeadImageContent(OverviewLeadImage(url: "   ", caption: "Caption", credit: nil)),
            "Whitespace URL is absent")
        assertTrue(
            EventOverviewReaderView.hasLeadImageContent(
                OverviewLeadImage(url: "https://example.com/lead.jpg", caption: "Summit", credit: "Reuters")),
            "Valid image URL is present")

        // Key Facts
        let emptyFacts: [OverviewFact] = []
        assertEqual(
            EventOverviewReaderView.filterValidFacts(emptyFacts).count, 0, "Empty facts array yields 0 valid facts")
        let blankFacts = [
            OverviewFact(id: "f1", text: "  ", citationIDs: []),
            OverviewFact(id: "f2", text: "\n", citationIDs: []),
        ]
        assertEqual(EventOverviewReaderView.filterValidFacts(blankFacts).count, 0, "Whitespace facts are pruned")
        let mixedFacts = [
            OverviewFact(id: "f1", text: "Verified carbon reduction goal.", citationIDs: ["c1"]),
            OverviewFact(id: "f2", text: "", citationIDs: []),
        ]
        assertEqual(EventOverviewReaderView.filterValidFacts(mixedFacts).count, 1, "Only non-empty facts are retained")

        // Timeline
        let emptyTimeline: [OverviewTimelineItem] = []
        assertEqual(
            EventOverviewReaderView.filterValidTimeline(emptyTimeline).count, 0, "Empty timeline yields 0 valid items")
        let blankTimeline = [
            OverviewTimelineItem(id: "t1", dateText: " ", summary: "", isFuturePlan: false)
        ]
        assertEqual(
            EventOverviewReaderView.filterValidTimeline(blankTimeline).count, 0, "Blank timeline item is pruned")
        let validTimelineItem = OverviewTimelineItem(
            id: "t2", dateText: "Oct 2", summary: "Treaty signed", isFuturePlan: false)
        assertEqual(
            EventOverviewReaderView.filterValidTimeline([validTimelineItem]).count, 1, "Valid timeline item is retained"
        )

        // Perspectives
        let emptyPerspectives: [OverviewPerspective] = []
        assertEqual(
            EventOverviewReaderView.filterValidPerspectives(emptyPerspectives).count, 0,
            "Empty perspectives yields 0 valid items")
        let blankPerspective = OverviewPerspective(id: "p1", participant: "  ", position: "")
        assertEqual(
            EventOverviewReaderView.filterValidPerspectives([blankPerspective]).count, 0, "Blank perspective is pruned")
        let validPerspective = OverviewPerspective(
            id: "p2", participant: "EU Envoy", position: "Supports binding commitments")
        assertEqual(
            EventOverviewReaderView.filterValidPerspectives([validPerspective]).count, 1,
            "Valid perspective is retained")

        // Thematic Angle
        assertFalse(EventOverviewReaderView.hasThematicAngleContent(nil), "Nil thematic angle is absent")
        let emptyAngle = OverviewThematicAngle(id: "a1", title: "", summary: "", citationIDs: [], facts: [])
        assertFalse(EventOverviewReaderView.hasThematicAngleContent(emptyAngle), "Empty thematic angle is absent")
        let whitespaceAngle = OverviewThematicAngle(id: "a2", title: "  ", summary: "\n", citationIDs: [], facts: [])
        assertFalse(
            EventOverviewReaderView.hasThematicAngleContent(whitespaceAngle), "Whitespace thematic angle is absent")
        let validAngle = OverviewThematicAngle(
            id: "a3", title: "Economic Impact", summary: "Renewable investment expected to double.", citationIDs: [],
            facts: [])
        assertTrue(EventOverviewReaderView.hasThematicAngleContent(validAngle), "Valid thematic angle is present")

        // Coverage Sentiment
        assertFalse(EventOverviewReaderView.hasCoverageSentimentContent(nil), "Nil coverage sentiment is absent")
        let blankSentiment = OverviewCoverageSentiment(score: 0.1, label: "  ", confidence: 0.8, rationale: nil)
        assertFalse(
            EventOverviewReaderView.hasCoverageSentimentContent(blankSentiment), "Blank sentiment label is absent")
        let validSentiment = OverviewCoverageSentiment(
            score: 0.3, label: "Cautious", confidence: 0.85, rationale: "Measured optimism.")
        assertTrue(
            EventOverviewReaderView.hasCoverageSentimentContent(validSentiment), "Valid coverage sentiment is present")

        // Evidence section compound check
        assertFalse(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [],
                perspectives: [],
                thematicAngle: nil,
                coverageSentiment: nil
            ),
            "Evidence container is absent when all 4 sub-sections are empty"
        )

        assertTrue(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [validTimelineItem],
                perspectives: [],
                thematicAngle: nil,
                coverageSentiment: nil
            ),
            "Evidence container is present when timeline has data"
        )
    }

    // MARK: - 3. VoiceOver Labels and Semantics
    static func testVoiceOverLabelsAndSemantics() {
        print("  - Testing VoiceOver Labels and Accessibility Semantics...")

        // Header metadata line
        let metaLabel = EventOverviewReaderView.headerMetadataAccessibilityLabel(
            formattedUpdateTime: "2 hours ago",
            articleCountText: "3 articles",
            publisherCountText: "2 publishers"
        )
        assertEqual(
            metaLabel, "Updated 2 hours ago, 3 articles, 2 publishers",
            "Header metadata label combines elements cleanly without dot artifacts")

        // Lead image label
        let leadImageWithCaptionAndCredit = OverviewLeadImage(
            url: "https://example.com/photo.jpg",
            caption: "Summit floor in Geneva",
            credit: "Associated Press"
        )
        let leadLabel1 = EventOverviewReaderView.leadImageAccessibilityLabel(leadImageWithCaptionAndCredit)
        assertEqual(
            leadLabel1, "Summit floor in Geneva. Credit: Associated Press",
            "Lead image combines caption and credit cleanly")

        let leadImageNoCaption = OverviewLeadImage(
            url: "https://example.com/photo.jpg", caption: nil, credit: "Reuters")
        let leadLabel2 = EventOverviewReaderView.leadImageAccessibilityLabel(leadImageNoCaption)
        assertEqual(
            leadLabel2, "Event lead image. Credit: Reuters", "Lead image falls back to generic caption with credit")

        // Citation pill label
        let citLabel = EventOverviewReaderView.citationAccessibilityLabel(
            sourceName: "Reuters", quote: "Targets were agreed unanimously.")
        assertEqual(
            citLabel, "Citation from Reuters: Targets were agreed unanimously.", "Citation pill label is descriptive")

        // Source article action labels
        let readLabel = EventOverviewReaderView.readArticleAccessibilityLabel(title: "Summit Treaty", source: "Reuters")
        assertEqual(
            readLabel, "Read Summit Treaty from Reuters in Source publication mode",
            "Read button has distinct context for VoiceOver rotor")

        let openWebLabel = EventOverviewReaderView.openWebArticleAccessibilityLabel(
            title: "Summit Treaty", source: "Reuters")
        assertEqual(
            openWebLabel, "Open original publication: Summit Treaty on Reuters", "Web button has distinct context")
    }

    // MARK: - 4. Increase Contrast Scalers
    static func testIncreaseContrastScalers() {
        print("  - Testing Increase Contrast Scalers...")

        // Divider opacity
        assertEqual(
            EventOverviewReaderView.dividerOpacity(for: .standard), 0.20, "Standard divider opacity is subtle (0.20)")
        assertEqual(
            EventOverviewReaderView.dividerOpacity(for: .increased), 0.60,
            "Increased contrast divider opacity is strong (0.60)")

        // Pill border opacity
        assertEqual(
            EventOverviewReaderView.pillBorderOpacity(for: .standard), 0.0,
            "Standard citation pill has no border stroke")
        assertEqual(
            EventOverviewReaderView.pillBorderOpacity(for: .increased), 0.60,
            "Increased contrast citation pill has visible stroke (0.60)")

        // Pill background opacity
        assertEqual(
            EventOverviewReaderView.pillBackgroundOpacity(for: .standard), 0.12,
            "Standard pill background opacity is 0.12")
        assertEqual(
            EventOverviewReaderView.pillBackgroundOpacity(for: .increased), 0.22,
            "Increased contrast pill background opacity is 0.22")
    }

    // MARK: - 5. Reduce Motion Policy
    static func testReduceMotionPolicy() {
        print("  - Testing Reduce Motion Policy...")

        let animated = EventOverviewReaderView.readerAnimation(reduceMotion: false)
        assertTrue(animated != nil, "Animation is provided when reduceMotion is false")

        let suppressed = EventOverviewReaderView.readerAnimation(reduceMotion: true)
        assertTrue(suppressed == nil, "Animation is nil when reduceMotion is true")
    }

    // MARK: - 6. Text Scaling and Layout Metrics
    static func testTextScalingAndLayoutMetrics() {
        print("  - Testing Text Scaling and Layout Metrics...")

        // Max reading width adapts to text scale up to 1.3
        let widthNormal = EventOverviewReaderView.readingColumnMaxWidth(for: 1.0)
        assertEqual(widthNormal, 720.0, "Normal reading width is 720.0")

        let widthScaled = EventOverviewReaderView.readingColumnMaxWidth(for: 1.2)
        assertEqual(widthScaled, 720.0 * 1.2, "Scaled reading width expands with text scale")

        let widthCapped = EventOverviewReaderView.readingColumnMaxWidth(for: 1.8)
        assertEqual(widthCapped, 720.0 * 1.3, "Scaled reading width caps at 1.3x to prevent excessive column width")

        // Padding matches design system pageInset (24.0) to prevent overflow on narrow 380px windows
        assertEqual(
            EventOverviewReaderView.horizontalPageInset, 24.0,
            "Horizontal page inset matches AppLayout.pageInset (24.0)")
    }
}
