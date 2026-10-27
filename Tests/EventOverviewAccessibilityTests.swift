// EventOverviewAccessibilityTests.swift
// Dedicated accessibility regression test suite for Event Overview reader mode (Issue #155)

import AppKit
import Foundation
import SwiftUI

// Defined in NewsApp.swift, which this standalone runner does not compile; the reader's command modifier uses them.
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
        testInlineCitationLinks()
        testSparseSectionsFiltering()
        testVoiceOverLabelsAndSemantics()
        testIncreaseContrastScalers()
        testReduceMotionPolicy()
        testTextScalingAndLayoutMetrics()
        testEpicT1IndustryImpact()
        testEpicT2TimelineSpineAndSorting()
        testEpicT3HighlightSeparationAndHierarchy()
        testEpicT4DistinctPerspectivesDesign()

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

        // 6. Each superscript opens its own source's citation, numbered as under Sources
        let citations = Dictionary(
            uniqueKeysWithValues: [citationByURL, citationByID, citationByTitle, citationUnresolvable].map {
                ($0.id, $0)
            })
        let cited = EventOverviewReaderView.citedSources(
            ["cit_2", "cit_1", "cit_3", "cit_5", "missing"], citations: citations, memberArticles: articles)
        assertEqual(cited.map(\.index), [1, 2], "Sources are numbered once each, in source order")
        assertEqual(cited.map(\.citation.id), ["cit_1", "cit_2"], "Source 2 opens its own citation, not the first one")
    }

    // MARK: - 2. Sparse Sections Filtering
    static func testInlineCitationLinks() {
        print("  - Testing inline citation superscripts: one text per fact, each number a news-citation link...")
        let attributed = EventOverviewReaderView.citedAttributedString(
            "Talks resumed on Monday.", sources: [2, 3], scale: 1)
        assertEqual(String(attributed.characters), "Talks resumed on Monday. [2] [3]", "Numbers follow the sentence")
        let links = attributed.runs.compactMap(\.link).map(\.absoluteString)
        assertEqual(links, ["news-citation://2", "news-citation://3"], "Each number links to its own source index")
        assertTrue(
            attributed.runs.first { $0.link != nil }?.baselineOffset == AppTypography.superscriptOffset,
            "Citation numbers are raised by the superscript token")
        assertTrue(
            attributed.runs.first.map { $0.link == nil && $0.baselineOffset == nil } ?? false,
            "The sentence itself carries no link or offset")
        assertEqual(
            String(EventOverviewReaderView.citedAttributedString("No sources.", sources: [], scale: 1).characters),
            "No sources.", "A fact without citations stays plain")
    }

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
        assertTrue(
            EventOverviewReaderView.showsThematicAngleSummary(validAngle),
            "An angle without fact bullets shows its summary")
        let bulletedAngle = OverviewThematicAngle(
            id: "a4", title: "By the Numbers", summary: "Ten ships sailed. Two returned.", citationIDs: [],
            facts: [
                OverviewFact(id: "n1", text: "Ten ships sailed.", citationIDs: []),
                OverviewFact(id: "n2", text: "Two returned.", citationIDs: []),
            ])
        assertFalse(
            EventOverviewReaderView.showsThematicAngleSummary(bulletedAngle),
            "The summary repeats the bullets, so an angle with facts shows only the cited bullets")

        // Coverage Sentiment
        // Evidence section compound check
        assertFalse(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [],
                perspectives: [],
                thematicAngle: nil
            ),
            "Evidence container is absent when all 3 sub-sections are empty"
        )

        assertTrue(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [validTimelineItem],
                perspectives: [],
                thematicAngle: nil
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

    // MARK: - 7. Epic T1: Industry Impact
    static func testEpicT1IndustryImpact() {
        print("  - Testing Epic T1: Industry Impact...")

        // 1. Fixed list of 12 standard industries
        assertEqual(
            OverviewIndustryImpactExtractor.StandardIndustry.allCases.count, 12,
            "StandardIndustry must have exactly 12 documented industries"
        )
        let expectedIndustries = Set([
            "Energy", "Financial Services", "Healthcare", "Technology",
            "Transportation", "Agriculture", "Manufacturing", "Retail & E-commerce",
            "Media & Entertainment", "Telecommunications", "Real Estate", "Defense & Aerospace",
        ])
        let actualIndustries = Set(OverviewIndustryImpactExtractor.StandardIndustry.allCases.map(\.rawValue))
        assertEqual(actualIndustries, expectedIndustries, "Documented industries match Epic T specification")

        // 2. Sparse filtering: filterValidIndustryImpact
        let blankImpact = [
            OverviewIndustryImpact(id: "i1", industry: "  ", implication: "Valid implication", citationIDs: []),
            OverviewIndustryImpact(id: "i2", industry: "Technology", implication: "", citationIDs: []),
            OverviewIndustryImpact(id: "i3", industry: "", implication: "", citationIDs: []),
        ]
        assertEqual(
            EventOverviewReaderView.filterValidIndustryImpact(blankImpact).count, 0,
            "Blank or incomplete industry impact items are pruned"
        )
        let validItem = OverviewIndustryImpact(
            id: "i4", industry: "Transportation",
            implication: "Automakers halted production at two plants.", citationIDs: ["c1"]
        )
        assertEqual(
            EventOverviewReaderView.filterValidIndustryImpact([validItem]).count, 1,
            "Valid industry impact item is retained"
        )

        // 3. Container presence with industry impact
        assertTrue(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [],
                perspectives: [],
                industryImpact: [validItem],
                thematicAngle: nil
            ),
            "Evidence container is present when industry impact has valid data"
        )

        // 4. Extraction: sports fixture produces no industry impact
        let sportsArticle = FeedArticle(
            storedID: "sports_1",
            title: "Championship Match Ends in Victory",
            link: "https://example.com/sports",
            guid: "sports_guid",
            description:
                "The home team celebrated after winning the final match 3-1 before cheering fans in the stadium.",
            pubDate: Date(),
            source: "SportsWire"
        )
        let sportsPassage = EvidencePassage(
            id: "pass_sports",
            articleID: "sports_1",
            text: "The home team celebrated after winning the final match 3-1 before cheering fans in the stadium."
        )
        let sportsCitation = OverviewCitation(
            id: "cite_sports",
            articleID: "sports_1",
            passageID: "pass_sports",
            passageFingerprint: sportsPassage.fingerprint,
            quote: "The home team celebrated after winning the final match 3-1 before cheering fans in the stadium.",
            source: nil
        )
        let sportsExtracted = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [sportsPassage],
            articles: [sportsArticle],
            existingCitations: ["cite_sports": sportsCitation]
        )
        assertEqual(sportsExtracted.items.count, 0, "Non-business text (sports) produces no industry impact")

        // 5. Stated impact shows named industry + implication + citation
        let autoSentence =
            "Automakers announced major production halts and layoffs across three assembly plants due to parts shortages."
        let autoArticle = FeedArticle(
            storedID: "auto_1",
            title: "Automakers Announce Factory Shutdowns",
            link: "https://example.com/auto",
            guid: "auto_guid",
            description: autoSentence,
            pubDate: Date(),
            source: "Reuters"
        )
        let autoPassage = EvidencePassage(
            id: "pass_auto",
            articleID: "auto_1",
            text: autoSentence
        )
        let autoCitation = OverviewCitation(
            id: "cite_auto",
            articleID: "auto_1",
            passageID: "pass_auto",
            passageFingerprint: autoPassage.fingerprint,
            quote: autoSentence,
            source: OverviewSourceMetadata(
                title: "Auto News", name: "Reuters", url: "https://example.com/auto", publishedAt: Date())
        )
        let autoExtracted = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [autoPassage],
            articles: [autoArticle],
            existingCitations: ["cite_auto": autoCitation]
        )
        assertEqual(autoExtracted.items.count, 1, "Extracts stated industry impact from grounded passage")
        assertEqual(autoExtracted.items.first?.industry, "Transportation", "Maps automakers to Transportation industry")

        // 6. VoiceOver accessibility label
        let impactVO = EventOverviewReaderView.industryImpactAccessibilityLabel(
            industry: "Transportation",
            implication: "Automakers announced production halts.",
            citations: [autoCitation]
        )
        assertEqual(
            impactVO, "Transportation: Automakers announced production halts. Source: Reuters",
            "VoiceOver combines industry, implication, and source cleanly"
        )
    }

    // MARK: - 8. Epic T2: Timeline Spine and Sorting
    static func testEpicT2TimelineSpineAndSorting() {
        print("  - Testing Epic T2: Timeline Spine and Sorting...")

        let pastDate1 = Date(timeIntervalSince1970: 1000)
        let pastDate2 = Date(timeIntervalSince1970: 2000)
        let pubDateOnly = Date(timeIntervalSince1970: 1500)
        let futureDate = Date(timeIntervalSince1970: 500)  // earlier timestamp, but planned event

        let item1 = OverviewTimelineItem(
            id: "t1", dateText: "Oct 1", summary: "Initial event", isFuturePlan: false, eventDate: pastDate1)
        let item2 = OverviewTimelineItem(
            id: "t2", dateText: "Oct 5", summary: "Followup event", isFuturePlan: false, eventDate: pastDate2)
        let item3 = OverviewTimelineItem(
            id: "t3", dateText: "Oct 3", summary: "Reported discovery", isFuturePlan: false,
            publicationDate: pubDateOnly)
        let item4 = OverviewTimelineItem(
            id: "t4", dateText: "Next Week", summary: "Scheduled vote", isFuturePlan: true, eventDate: futureDate)

        let sorted = EventOverviewReaderView.sortTimelineItems([item4, item2, item1, item3])
        assertEqual(
            sorted.map { $0.id }, ["t1", "t3", "t2", "t4"], "Chronological sort with planned items ordered last")

        // Pruning empty summary
        let emptySummary = OverviewTimelineItem(id: "t5", dateText: "Oct 2", summary: "  ", isFuturePlan: false)
        assertEqual(
            EventOverviewReaderView.filterValidTimeline([emptySummary]).count, 0, "Item with empty summary is pruned")

        // VoiceOver labels
        let cit = OverviewCitation(
            id: "c_t", articleID: "a1", passageID: "p1", passageFingerprint: "fp", quote: "quote",
            source: OverviewSourceMetadata(title: nil, name: "AP", url: nil, publishedAt: nil))
        let voPast = EventOverviewReaderView.timelineItemAccessibilityLabel(item: item1, citations: [cit])
        assertEqual(voPast, "Oct 1. Initial event. Source: AP", "VoiceOver past event reads date, summary, source")

        let voPubOnly = EventOverviewReaderView.timelineItemAccessibilityLabel(item: item3, citations: [cit])
        assertEqual(
            voPubOnly, "Reported Oct 3. Reported discovery. Source: AP",
            "VoiceOver publication-only reads Reported prefix")

        let voPlan = EventOverviewReaderView.timelineItemAccessibilityLabel(item: item4, citations: [cit])
        assertEqual(
            voPlan, "Next Week. Planned. Scheduled vote. Source: AP",
            "VoiceOver planned item includes Planned announcement")
    }

    // MARK: - 9. Epic T3: Highlight Separation and Hierarchy
    static func testEpicT3HighlightSeparationAndHierarchy() {
        print("  - Testing Epic T3: Highlight Separation and Hierarchy...")

        // Spacing ratio: inter-gap (16pt) >= 2 * intra-gap (4pt)
        assertTrue(AppSpacing.md >= 2 * AppSpacing.xxs, "Highlight inter-gap is at least 2x intra-gap")

        // Unknown publisher fallback
        let citNoSource = OverviewCitation(
            id: "c_none", articleID: "a1", passageID: "p1", passageFingerprint: "fp", quote: "quote", source: nil)
        let voNoPub = EventOverviewReaderView.highlightAccessibilityLabel(
            takeaway: "Clean energy funding approved", publisher: nil, citations: [citNoSource])
        assertEqual(voNoPub, "Clean energy funding approved", "Unknown publisher omits attribution in VoiceOver")

        let voWithPub = EventOverviewReaderView.highlightAccessibilityLabel(
            takeaway: "Clean energy funding approved", publisher: "Financial Times", citations: [])
        assertEqual(
            voWithPub, "Clean energy funding approved. Source: Financial Times",
            "Known publisher includes source attribution")
    }

    // MARK: - 10. Epic T4: Distinct Perspectives Design
    static func testEpicT4DistinctPerspectivesDesign() {
        print("  - Testing Epic T4: Distinct Perspectives Design...")

        // filterValidPerspectives requires BOTH participant AND position non-empty
        let pEmptyParticipant = OverviewPerspective(id: "p1", participant: "  ", position: "Supports treaty")
        let pEmptyPosition = OverviewPerspective(id: "p2", participant: "EU Envoy", position: "")
        let pValid = OverviewPerspective(
            id: "p3", participant: "EU Envoy", position: "Supports binding commitments", sourcePublisher: "Bloomberg")

        let filtered = EventOverviewReaderView.filterValidPerspectives([pEmptyParticipant, pEmptyPosition, pValid])
        assertEqual(filtered.count, 1, "Only perspectives with both non-empty participant and position are kept")
        assertEqual(filtered.first?.id, "p3", "Keeps valid perspective")

        // Section absent when 0 remain
        assertFalse(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [],
                perspectives: [pEmptyParticipant],
                industryImpact: [],
                thematicAngle: nil
            ),
            "Section is absent when perspectives has no valid items"
        )

        // 1-perspective fixture has no false balance (retains exactly 1, does not synthesize counter)
        assertEqual(
            EventOverviewReaderView.filterValidPerspectives([pValid]).count, 1,
            "Single perspective is preserved without false balance")

        // VoiceOver label reads participant, position, source in order
        let voPersp = EventOverviewReaderView.perspectiveAccessibilityLabel(
            participant: "EU Envoy",
            position: "Supports binding commitments",
            source: "via Bloomberg"
        )
        assertEqual(
            voPersp, "EU Envoy. Supports binding commitments. via Bloomberg",
            "VoiceOver reads participant, position, and source in sequence")
    }
}
