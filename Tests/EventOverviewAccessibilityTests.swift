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
        await testEpicTRobustnessConcurrencyAndErrorHandling()
        testIndustryImpactSectorCoverage()
        testIndustryImpactSelectionAndCitations()
        testIndustryImpactEligibilityBoundaries()
        testIndustryImpactCitationValidation()
        testEvidenceSectionsCompatibility()
        testOverviewDeduplicationBoundaries()
        testComposerPreservesIndustryImpactWithTimeline()
        await testModelCompositionDeduplicatesEvidenceSections()
        testTimelineOrderingTiesAndMissingDates()
        testEvidenceAttributionFallbacks()

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

        // 6. Substring false positive prevention (e.g. soil matching oil, in order to matching order)
        let soilSentence =
            "The researchers collected soil samples in the forest in order to verify local geology without disruption."
        let soilArticle = FeedArticle(
            storedID: "soil_1", title: "Forest Soil Survey", link: "https://example.com/soil",
            guid: "soil_guid", description: soilSentence, pubDate: Date(), source: "Science Daily")
        let soilPassage = EvidencePassage(id: "pass_soil", articleID: "soil_1", text: soilSentence)
        let soilCitation = OverviewCitation(
            id: "cite_soil", articleID: "soil_1", passageID: "pass_soil",
            passageFingerprint: soilPassage.fingerprint, quote: soilSentence,
            source: OverviewSourceMetadata(title: "Science", name: "Science Daily", url: nil, publishedAt: nil))
        let soilExtracted = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [soilPassage],
            articles: [soilArticle],
            existingCitations: ["cite_soil": soilCitation]
        )
        assertEqual(
            soilExtracted.items.count, 0, "Substring false positives (soil, in order to) produce no industry impact")

        // 7. Sports fixture rejection even with business implication cues
        let sportsBizSentence =
            "The football championship match tickets were cancelled and player wages cut after stadium disruptions."
        let sportsBizArticle = FeedArticle(
            storedID: "sports_biz_1", title: "Championship Tournament Disruption", link: "https://example.com/sb",
            guid: "sb_guid", description: sportsBizSentence, pubDate: Date(), source: "SportsDaily")
        let sportsBizPassage = EvidencePassage(id: "pass_sb", articleID: "sports_biz_1", text: sportsBizSentence)
        let sportsBizCitation = OverviewCitation(
            id: "cite_sb", articleID: "sports_biz_1", passageID: "pass_sb",
            passageFingerprint: sportsBizPassage.fingerprint, quote: sportsBizSentence,
            source: OverviewSourceMetadata(title: "Sports", name: "SportsDaily", url: nil, publishedAt: nil))
        let sportsBizExtracted = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [sportsBizPassage],
            articles: [sportsBizArticle],
            existingCitations: ["cite_sb": sportsBizCitation]
        )
        assertEqual(
            sportsBizExtracted.items.count, 0, "Sports fixture with implication cues produces no industry impact")

        // 8. Deduplication against highlights and intro
        let duplicateImpact = OverviewIndustryImpact(
            id: "imp_auto", industry: "Transportation",
            implication:
                "Automakers announced major production halts and layoffs across three assembly plants due to parts shortages.",
            citationIDs: ["cite_auto"])
        let deduped = OverviewComposer.deduplicateIndustryImpact(
            [duplicateImpact],
            against: [
                "Automakers announced major production halts and layoffs across three assembly plants due to parts shortages."
            ])
        assertEqual(deduped.count, 0, "Industry impact duplicating highlight statement is filtered out")

        // 9. VoiceOver accessibility label
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

        let itemBothDates = OverviewTimelineItem(
            id: "t1_reported", dateText: "Oct 1", summary: "Initial event", isFuturePlan: false, eventDate: pastDate1,
            publicationDate: pubDateOnly)
        let reportedText = pubDateOnly.formatted(date: .abbreviated, time: .omitted)
        assertEqual(
            EventOverviewReaderView.timelineItemAccessibilityLabel(item: itemBothDates, citations: [cit]),
            "Oct 1. Reported \(reportedText). Initial event. Source: AP",
            "VoiceOver dated event also reads the Reported publication date shown in the row")

        let voPubOnly = EventOverviewReaderView.timelineItemAccessibilityLabel(item: item3, citations: [cit])
        assertEqual(
            voPubOnly, "Reported Oct 3. Reported discovery. Source: AP",
            "VoiceOver publication-only reads Reported prefix")

        let voPlan = EventOverviewReaderView.timelineItemAccessibilityLabel(item: item4, citations: [cit])
        assertEqual(
            voPlan, "Next Week. Planned. Scheduled vote. Source: AP",
            "VoiceOver planned item includes Planned announcement")

        // Item with empty dateText but publicationDate gets formatted Reported prefix
        let itemPubDateOnlyNoText = OverviewTimelineItem(
            id: "t_pub_only", dateText: "", summary: "Regulatory filing published", isFuturePlan: false,
            publicationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let voPubFallback = EventOverviewReaderView.timelineItemAccessibilityLabel(
            item: itemPubDateOnlyNoText, citations: [cit])
        assertTrue(
            voPubFallback.hasPrefix("Reported "),
            "VoiceOver timeline item with empty dateText uses publicationDate with Reported prefix"
        )

        // Item with dateText already prefixed does not duplicate prefix
        let itemAlreadyReported = OverviewTimelineItem(
            id: "t_already_rep", dateText: "Reported Nov 15", summary: "Filing announced", isFuturePlan: false)
        let voAlreadyRep = EventOverviewReaderView.timelineItemAccessibilityLabel(
            item: itemAlreadyReported, citations: [cit])
        assertFalse(
            voAlreadyRep.contains("Reported Reported"),
            "VoiceOver timeline item does not duplicate Reported prefix"
        )
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

        // Attribution formatting
        assertEqual(
            EventOverviewReaderView.formatPerspectiveSource(wire: nil, publisher: "Reuters"),
            "via Reuters",
            "Publisher formatted as via [publisher]"
        )
        assertEqual(
            EventOverviewReaderView.formatPerspectiveSource(wire: nil, publisher: "via Reuters"),
            "via Reuters",
            "Does not duplicate via prefix on publisher"
        )
        assertEqual(
            EventOverviewReaderView.formatPerspectiveSource(wire: "AP", publisher: "Local Paper"),
            "via AP syndicate",
            "Wire source formatted as via [wire] syndicate"
        )

        // Deduplication against highlights
        let dupPersp = OverviewPerspective(
            id: "p_dup", participant: "CEO", position: "Clean energy funding approved", sourcePublisher: "FT")
        let dedupedP = OverviewComposer.deduplicatePerspectives(
            [dupPersp], against: ["Clean energy funding approved"])
        assertEqual(dedupedP.count, 0, "Perspective duplicating highlight statement is filtered out")

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

    // MARK: - 11. Epic T: Strict Concurrency, Error Handling & Memory Safety
    static func testEpicTRobustnessConcurrencyAndErrorHandling() async {
        print("  - Testing Epic T: Strict Concurrency, Error Handling & Memory Safety...")

        // 1. Resiliency to duplicate article IDs (must not trap with uniqueKeysWithValues duplicate key error)
        let artDuplicate1 = FeedArticle(
            storedID: "art_dup", title: "Steel manufacturers face raw material shortages and shutdown",
            link: "https://example.com/art1", guid: "g1", description: "First copy",
            pubDate: Date(), source: "Reuters Top News"
        )
        let artDuplicate2 = FeedArticle(
            storedID: "art_dup", title: "Steel manufacturers face raw material shortages and shutdown",
            link: "https://example.com/art1_alt", guid: "g2", description: "Second copy with duplicate ID",
            pubDate: Date(), source: "Reuters Top News"
        )
        let passDuplicate = EvidencePassage(
            id: "pass_dup_1", articleID: "art_dup",
            text:
                "Steel manufacturers face severe raw material shortages and announced immediate shutdown of three factories."
        )

        let extractedFromDuplicates = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [passDuplicate],
            articles: [artDuplicate1, artDuplicate2],
            existingCitations: [:]
        )
        assertTrue(
            extractedFromDuplicates.items.count > 0,
            "extractIndustryImpact safely handles duplicate article IDs without fatalError"
        )

        // 2. Fallback citation metadata generation when existingCitations is empty
        if let firstItem = extractedFromDuplicates.items.first,
            let firstCite = extractedFromDuplicates.citations.first
        {
            assertEqual(firstItem.industry, "Manufacturing", "Identifies manufacturing industry impact")
            assertEqual(firstCite.sourceName, "Reuters Top News", "Populates source metadata from article")
            assertEqual(
                firstCite.sourceTitle, "Steel manufacturers face raw material shortages and shutdown", "Populates title"
            )

            // 3. validateIndustryImpact with duplicate passages and duplicate articles
            let isValid = OverviewIndustryImpactExtractor.validateIndustryImpact(
                firstItem,
                against: [firstCite.id: firstCite],
                passages: [passDuplicate, passDuplicate],
                articles: [artDuplicate1, artDuplicate2]
            )
            assertTrue(isValid, "validateIndustryImpact safely validates with duplicate passage/article IDs")
        } else {
            assertTrue(false, "Expected extracted industry impact item")
        }

        // 4. Citation resolution by publisherName when source string differs
        let guardianArticle = FeedArticle(
            storedID: "guardian_1", title: "Tech giants face antitrust mandates",
            link: "https://www.theguardian.com/technology/2026/oct/27/story", guid: "g_guid", description: "",
            pubDate: Date(), source: "Technology - Latest"
        )
        // FeedCatalog resolves theguardian.com to "The Guardian", while article.source is "Technology - Latest"
        assertEqual(guardianArticle.publisherName, "The Guardian", "FeedCatalog resolves Guardian domain")
        let guardianCitation = OverviewCitation(
            id: "cite_guardian", articleID: "guardian_unknown_id", passageID: "p1",
            passageFingerprint: "fp", quote: "quote",
            source: OverviewSourceMetadata(title: "Tech giants", name: "The Guardian", url: nil, publishedAt: nil)
        )
        let resolvedMatch = EventOverviewReaderView.matchingArticle(for: guardianCitation, in: [guardianArticle])
        assertEqual(
            resolvedMatch?.id, guardianArticle.id,
            "matchingArticle matches citation sourceName against article.publisherName"
        )

        // 5. Nonisolated helper invocation from detached task across actor boundaries
        let detachedResult = await Task.detached { () -> Bool in
            let sorted = EventOverviewReaderView.sortTimelineItems([])
            let impactFiltered = EventOverviewReaderView.filterValidIndustryImpact([])
            let hasContent = EventOverviewReaderView.hasEvidenceContent(
                timeline: sorted,
                perspectives: [],
                industryImpact: impactFiltered,
                thematicAngle: nil
            )
            return !hasContent
        }.value
        assertTrue(detachedResult, "Pure static helpers are nonisolated and callable from background tasks")

        // 6. Concurrency stress test: parallel extraction across tasks
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<10 {
                let sentence = "Energy companies reported soaring power grid costs and pipeline disruption #\(i)."
                let pass = EvidencePassage(id: "p_conc_\(i)", articleID: "a_conc_\(i)", text: sentence)
                let art = FeedArticle(
                    storedID: "a_conc_\(i)", title: "Energy grid costs",
                    link: "https://example.com/energy/\(i)", guid: "e_\(i)", description: "",
                    pubDate: Date(), source: "Energy Weekly"
                )
                group.addTask {
                    let ext = OverviewIndustryImpactExtractor.extractIndustryImpact(
                        passages: [pass],
                        articles: [art],
                        existingCitations: [:]
                    )
                    return ext.items.count <= 1
                }
            }
            for await success in group {
                assertTrue(success, "Concurrent industry impact extraction executed safely")
            }
        }

        // 7. Deduplication edge cases (empty strings, whitespace-only, disjoint texts)
        let emptyPerspective = OverviewPerspective(
            id: "p_empty", participant: "Speaker", position: "   ", sourcePublisher: "Source")
        let dedupedEmpty = OverviewComposer.deduplicatePerspectives([emptyPerspective], against: ["Valid highlight"])
        assertEqual(dedupedEmpty.count, 1, "Empty position is handled without crash")

        let dedupedNoExclusion = OverviewComposer.deduplicateIndustryImpact(
            extractedFromDuplicates.items, against: [])
        assertEqual(
            dedupedNoExclusion.count, extractedFromDuplicates.items.count,
            "Empty exclusion array retains all impact items"
        )

        // 8. Hyphenated cue matching: e-commerce in Retail & E-commerce sector
        let ecommerceArticle = FeedArticle(
            storedID: "art_ecom", title: "Retailers see massive delivery demand surge",
            link: "https://example.com/retail", guid: "g_ecom", description: "",
            pubDate: Date(), source: "Retail News"
        )
        let ecommercePassage = EvidencePassage(
            id: "pass_ecom", articleID: "art_ecom",
            text:
                "Major retailers reported a historic surge in e-commerce orders and widespread delivery shortages across the nation."
        )
        let ecommerceExtracted = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [ecommercePassage],
            articles: [ecommerceArticle],
            existingCitations: [:]
        )
        assertTrue(
            ecommerceExtracted.items.contains(where: { $0.industry == "Retail & E-commerce" }),
            "extractIndustryImpact correctly identifies hyphenated cue 'e-commerce' as Retail & E-commerce"
        )

        // 9. sourceIndex empty and whitespace string safety
        let emptyNameCitation = OverviewCitation(
            id: "cite_empty", articleID: "art_unknown", passageID: "p_unk",
            passageFingerprint: "fp", quote: "quote",
            source: OverviewSourceMetadata(title: nil, name: "   ", url: nil, publishedAt: nil)
        )
        let emptyIndexMatch = EventOverviewReaderView.sourceIndex(for: emptyNameCitation, in: [ecommerceArticle])
        assertEqual(emptyIndexMatch, nil, "sourceIndex returns nil for whitespace-only citation source name")

        // 10. Background concurrency for accessibility label functions
        let bgLabelsSuccess = await Task.detached { () -> Bool in
            let item = OverviewTimelineItem(
                id: "t_bg", dateText: "", summary: "Background timeline event", isFuturePlan: false,
                publicationDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let tlLabel = EventOverviewReaderView.timelineItemAccessibilityLabel(item: item)
            let pLabel = EventOverviewReaderView.perspectiveAccessibilityLabel(
                participant: "Analyst", position: "Cautious outlook", source: "Bloomberg"
            )
            let iLabel = EventOverviewReaderView.industryImpactAccessibilityLabel(
                industry: "Energy", implication: "Costs soar", citations: []
            )
            let attr = EventOverviewReaderView.citedAttributedString("Summary fact", sources: [1, 2], scale: 1.0)
            return !tlLabel.isEmpty && !pLabel.isEmpty && !iLabel.isEmpty && !attr.characters.isEmpty
        }.value
        assertTrue(bgLabelsSuccess, "Accessibility and attribution functions are thread-safe and nonisolated")

        // 11. OverviewEvidenceSections serialization & backwards compatibility
        let testImpact = OverviewIndustryImpact(
            id: "imp_test", industry: "Energy", implication: "Fuel costs escalated by 20%",
            citationIDs: ["c1"]
        )
        let sectionsWithImpact = OverviewEvidenceSections(industryImpact: [testImpact])
        assertFalse(sectionsWithImpact.isEmpty, "Evidence sections with industry impact is not empty")

        do {
            let encoded = try JSONEncoder().encode(sectionsWithImpact)
            let decoded = try JSONDecoder().decode(OverviewEvidenceSections.self, from: encoded)
            assertEqual(decoded.industryImpact.count, 1, "Decoded industry impact count matches")
            assertEqual(decoded.industryImpact.first?.industry, "Energy", "Decoded industry matches")
            assertEqual(
                decoded.industryImpact.first?.implication, "Fuel costs escalated by 20%", "Decoded implication matches")

            // Backwards compatibility: decode JSON without industryImpact field
            let legacyJSON = "{}".data(using: .utf8)!
            let decodedLegacy = try JSONDecoder().decode(OverviewEvidenceSections.self, from: legacyJSON)
            assertTrue(decodedLegacy.industryImpact.isEmpty, "Legacy JSON decodes with empty industry impact")
            assertTrue(decodedLegacy.isEmpty, "Legacy empty JSON decodes as empty evidence sections")
        } catch {
            assertTrue(false, "OverviewEvidenceSections JSON serialization threw: \(error)")
        }
    }
}

extension EventOverviewAccessibilityTests {
    // MARK: - Industry impact regression fixtures

    private static func impactFixture(
        _ text: String, id: String = "impact-regression", title: String = "Business update"
    ) -> (article: FeedArticle, passage: EvidencePassage) {
        let article = FeedArticle(
            storedID: id, title: title, link: "https://example.com/\(id)", guid: id,
            description: text, pubDate: Date(timeIntervalSince1970: 1_793_088_000), source: "Fixture News")
        return (article, EvidencePassage(id: "passage-\(id)", articleID: id, text: text))
    }

    private static func impactCitation(
        _ passage: EvidencePassage, id: String = "impact-citation", fingerprint: String? = nil,
        articleID: String? = nil, quote: String? = nil, source: OverviewSourceMetadata? = nil
    ) -> OverviewCitation {
        OverviewCitation(
            id: id, articleID: articleID ?? passage.articleID, passageID: passage.id,
            passageFingerprint: fingerprint ?? passage.fingerprint, quote: quote ?? passage.text, source: source)
    }

    static func testIndustryImpactSectorCoverage() {
        print("  - Testing industry sector recognition and sentence-level citation grounding...")
        let cases: [(industry: String, sentence: String)] = [
            ("Energy", "Energy companies halted pipeline operations after widespread equipment failures yesterday."),
            ("Financial Services", "Banks reduced lending fees after regulators approved the revised rules."),
            ("Healthcare", "Hospitals halted operations after workers began a nationwide labor strike yesterday."),
            (
                "Technology",
                "Chipmakers halted production following severe component supply shortages across the region."
            ),
            ("Transportation", "Airlines cancelled flights after crews began a nationwide strike yesterday."),
            ("Agriculture", "Farmers reported falling crop prices after the recent harvest ended."),
            ("Manufacturing", "Steel manufacturers halted production after workers began a nationwide strike."),
            ("Retail & E-commerce", "E-commerce orders increased after shoppers returned during the annual sale."),
            ("Media & Entertainment", "Streaming studios halted production after writers began a nationwide strike."),
            (
                "Telecommunications",
                "Broadband providers reported outages after widespread equipment failures last night."
            ),
            ("Real Estate", "Construction companies halted operations after workers began a nationwide strike."),
            ("Defense & Aerospace", "Aerospace companies halted production after workers began a nationwide strike."),
        ]
        for (index, entry) in cases.enumerated() {
            let fixture = impactFixture(entry.sentence, id: "sector-\(index)")
            let result = OverviewIndustryImpactExtractor.extractIndustryImpact(
                passages: [fixture.passage], articles: [fixture.article], existingCitations: [:])
            assertEqual(
                result.items.map(\.industry), [entry.industry], "Recognizes \(entry.industry) from its own cues")
            assertEqual(result.items.map(\.implication), [entry.sentence], "Preserves the publisher's exact sentence")
            assertEqual(result.citations.count, 1, "Each sector has one supporting citation")
            guard let item = result.items.first, let citation = result.citations.first else { continue }
            assertEqual(item.citationIDs, [citation.id], "Impact points to the returned citation")
            assertEqual(citation.quote, entry.sentence, "Citation quotes only the extracted sentence")
            assertEqual(citation.articleID, fixture.article.id, "Citation retains the stored article identity")
            assertEqual(citation.passageID, fixture.passage.id, "Citation retains the stored passage identity")
            assertEqual(citation.passageFingerprint, fixture.passage.fingerprint, "Citation binds to the passage text")
            assertTrue(
                OverviewIndustryImpactExtractor.validateIndustryImpact(
                    item, against: [citation.id: citation], passages: [fixture.passage], articles: [fixture.article]),
                "Extracted \(entry.industry) implication passes claim verification")
        }
    }

    static func testIndustryImpactSelectionAndCitations() {
        print("  - Testing industry limits, missing articles, and source metadata...")
        let sentences = [
            "Energy companies halted pipeline operations after widespread equipment failures yesterday.",
            "Oil refineries reported higher costs after a prolonged equipment outage yesterday.",
            "Banks reduced lending fees after regulators approved the revised rules.",
            "Hospitals halted operations after workers began a nationwide labor strike yesterday.",
            "Chipmakers halted production following severe component supply shortages across the region.",
            "Airlines cancelled flights after crews began a nationwide strike yesterday.",
        ]
        let fixtures = sentences.enumerated().map { impactFixture($0.element, id: "selection-\($0.offset)") }
        let orphan = impactFixture(sentences[0], id: "orphan")
        let result = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [orphan.passage] + fixtures.map(\.passage), articles: fixtures.map(\.article),
            existingCitations: [:])
        assertEqual(
            result.items.map(\.industry), ["Energy", "Financial Services", "Healthcare", "Technology"],
            "Skips missing articles, retains the first implication per industry, and caps results at four")
        assertEqual(
            result.items.map(\.implication), [sentences[0], sentences[2], sentences[3], sentences[4]],
            "Selection preserves passage order without replacing an earlier sector's sentence")
        assertEqual(result.citations.count, 4, "Skipped candidates produce no unused citations")
        assertEqual(Set(result.items.map(\.id)).count, 4, "Selected impact identifiers are unique")
        assertEqual(Set(result.citations.map(\.id)).count, 4, "Selected citation identifiers are unique")

        let combined = impactFixture(sentences.joined(separator: " "), id: "combined")
        let withinPassage = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [combined.passage], articles: [combined.article], existingCitations: [:])
        assertEqual(
            withinPassage.items.map(\.implication), result.items.map(\.implication),
            "Limit also applies within a passage")
        assertEqual(
            withinPassage.citations.map(\.quote), result.items.map(\.implication),
            "Each quote excludes neighboring sentences")

        let metadata = OverviewSourceMetadata(
            title: "Original publisher headline", name: "Original Wire", url: "https://example.com/original",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let existing = impactCitation(combined.passage, id: "existing-source", source: metadata)
        let withSource = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [combined.passage], articles: [combined.article], existingCitations: [existing.id: existing])
        assertEqual(
            withSource.items, withinPassage.items, "Metadata does not alter selected implications or identifiers")
        assertEqual(
            withSource.citations.map(\.source), [OverviewSourceMetadata?](repeating: metadata, count: 4),
            "Reuses the existing passage source")
        assertEqual(
            withinPassage.citations.first?.sourceTitle, combined.article.title,
            "Missing metadata falls back to article title")
        assertEqual(
            withinPassage.citations.first?.publishedAt, combined.article.pubDate, "Fallback preserves publication date")

        let repeated = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: fixtures.map(\.passage), articles: fixtures.map(\.article), existingCitations: [:])
        assertEqual(repeated.items, result.items, "Repeated extraction produces identical items")
        assertEqual(repeated.citations, result.citations, "Repeated extraction produces identical citations")
    }

    static func testIndustryImpactEligibilityBoundaries() {
        print("  - Testing industry eligibility, exclusions, and sentence length boundaries...")
        let rejected = [
            "Energy prices are expected to rise after the recent pipeline disruption.",
            "Analysts predict that energy costs will double after the supply disruption.",
            "Investors should buy shares in energy companies after the supply disruption.",
            "Banks received a strong buy recommendation after reporting higher lending fees.",
            "Energy researchers gathered samples in order to understand the unusual findings.",
            "Energy researchers gathered samples in order that colleagues could examine them.",
            "Energy researchers gathered samples in order for colleagues to examine them.",
            "Energy researchers presented their latest findings at the annual conference yesterday.",
            "Local residents reported higher costs after the recent public celebration ended.",
            "Soil samples revealed higher costs for the research team during testing.",
            "Airlines cancelled flights after the championship tournament ended at the stadium.",
            "A missile strike hit the main hospital in the city, killing twelve people overnight.",
            "The military operation used precision weapons against targets near the border on Tuesday.",
            "A court order froze the bank accounts of the suspects pending trial next month.",
        ]
        for sentence in rejected {
            let fixture = impactFixture(sentence)
            let result = OverviewIndustryImpactExtractor.extractIndustryImpact(
                passages: [fixture.passage], articles: [fixture.article], existingCitations: [:])
            assertTrue(result.items.isEmpty, "Rejects ineligible sentence: \(sentence)")
            assertTrue(result.citations.isEmpty, "Rejected sentence creates no citation")
        }

        let sentence = "Energy costs increased across all regional markets today."
        let fixture = impactFixture(sentence)
        let mixed = impactFixture("\(rejected[0]) \(sentence)", id: "forecast-then-stated")
        let mixedResult = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [mixed.passage], articles: [mixed.article], existingCitations: [:])
        assertEqual(
            mixedResult.items.map(\.implication), [sentence],
            "Rejecting a forecast does not prevent a later stated implication for the same industry")
        assertEqual(mixedResult.citations.map(\.quote), [sentence], "Only the accepted sentence receives a citation")
        for exclusion in [
            " \n\(sentence.uppercased())\t ", "Energy costs increased across all regional markets yesterday.",
        ] {
            let excluded = OverviewIndustryImpactExtractor.extractIndustryImpact(
                passages: [fixture.passage], articles: [fixture.article], existingCitations: [:],
                excludeSentences: [exclusion])
            assertTrue(excluded.items.isEmpty, "Excludes normalized or near-duplicate highlights")
            assertTrue(excluded.citations.isEmpty, "Excluded highlights create no citation")
        }
        let retained = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [fixture.passage], articles: [fixture.article], existingCitations: [:],
            excludeSentences: ["  \n ", "The council approved a new bridge yesterday."])
        assertEqual(
            retained.items.map(\.implication), [sentence], "Blank and unrelated highlights do not suppress impact")

        let sportsTitle = impactFixture(sentence, title: "World Cup championship report")
        let sportsResult = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [sportsTitle.passage], articles: [sportsTitle.article], existingCitations: [:])
        assertTrue(
            sportsResult.items.isEmpty, "Sports in the article title excludes an otherwise eligible business sentence")

        let orderFixture = impactFixture("Banks received large orders from clients after the review.")
        let orderResult = OverviewIndustryImpactExtractor.extractIndustryImpact(
            passages: [orderFixture.passage], articles: [orderFixture.article], existingCitations: [:])
        assertEqual(
            orderResult.items.map(\.industry), ["Financial Services"], "Genuine orders remain a demand implication")

        // Synthetic padding isolates the word-count boundary from sector and implication matching.
        for count in [7, 8, 60, 61] {
            let padding = Array(repeating: "regional", count: count - 5).joined(separator: " ")
            let boundary = impactFixture("Energy costs increased across \(padding) markets.")
            let result = OverviewIndustryImpactExtractor.extractIndustryImpact(
                passages: [boundary.passage], articles: [boundary.article], existingCitations: [:])
            let expected = (8...60).contains(count) ? 1 : 0
            assertEqual(result.items.count, expected, "Sentence length \(count) respects inclusive 8–60 word bounds")
            assertEqual(result.citations.count, expected, "Sentence length rejection leaves no citation")
        }
    }

    static func testIndustryImpactCitationValidation() {
        print("  - Testing industry impact validation fails closed on broken evidence...")
        let sentence = "Energy companies halted pipeline operations after costs rose by 20 percent."
        let fixture = impactFixture(sentence)
        let citation = impactCitation(fixture.passage)
        func impact(
            industry: String = "Energy", implication: String? = nil, ids: [String] = ["impact-citation"]
        ) -> OverviewIndustryImpact {
            OverviewIndustryImpact(
                id: "validation-impact", industry: industry, implication: implication ?? sentence, citationIDs: ids)
        }
        func validates(
            _ item: OverviewIndustryImpact, citationMap: [String: OverviewCitation]? = nil,
            passages: [EvidencePassage]? = nil
        ) -> Bool {
            OverviewIndustryImpactExtractor.validateIndustryImpact(
                item, against: citationMap ?? [citation.id: citation], passages: passages ?? [fixture.passage],
                articles: [fixture.article])
        }
        assertTrue(validates(impact()), "Control: grounded industry implication validates")
        assertFalse(validates(impact(ids: [])), "An implication requires at least one citation")
        assertFalse(validates(impact(implication: " \n\t ")), "Whitespace implication is invalid")
        assertFalse(validates(impact(industry: "Unknown Sector")), "Undocumented industry is invalid")
        assertFalse(validates(impact(), citationMap: [:]), "Missing citation is invalid")
        assertFalse(validates(impact(), passages: []), "Missing passage is invalid")
        assertFalse(
            validates(impact(ids: [citation.id, "missing"])), "Every citation must resolve, even after a valid one")
        assertFalse(
            validates(impact(implication: sentence.replacingOccurrences(of: "20", with: "90"))),
            "A grounded quote cannot support an altered numeric claim")
        assertFalse(
            validates(
                impact(
                    implication: "Energy companies did not halt pipeline operations after costs rose by 20 percent.")),
            "A grounded quote cannot support inverted negation")

        let brokenCitations = [
            impactCitation(fixture.passage, fingerprint: "stale-fingerprint"),
            impactCitation(fixture.passage, articleID: "different-article"),
            impactCitation(fixture.passage, quote: "The source never reported this sentence."),
        ]
        for broken in brokenCitations {
            assertFalse(
                validates(impact(), citationMap: [broken.id: broken]),
                "Rejects stale fingerprints, mismatched articles, and ungrounded quotes")
        }
    }

    static func testEvidenceSectionsCompatibility() {
        print("  - Testing legacy evidence decoding and complete document round trips...")
        let legacyJSON = """
            {
                "introduction": [{"id":"intro","text":"A cited introduction.","citationIDs":["c"]}],
                "timeline": [{"id":"past","dateText":"Oct 1","summary":"Talks opened.",
                              "citationIDs":["c"],"isFuturePlan":false}],
                "perspectives": [{"id":"speaker","participant":"Council","position":"Supported the plan.",
                                  "citationIDs":["c"],"sourcePublisher":"Fixture News"}],
                "thematicAngle": {"id":"angle","title":"Costs","summary":"Costs rose.","citationIDs":["c"],"facts":[]},
                "coverageSentiment": {"score":0.25,"label":"Measured","confidence":0.8,"rationale":"Source wording"}
            }
            """
        do {
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let legacy = try decoder.decode(OverviewEvidenceSections.self, from: Data(legacyJSON.utf8))
            assertTrue(
                legacy.industryImpact.isEmpty, "Legacy populated sections default missing industry impact to empty")
            assertEqual(legacy.introduction?.map(\.id), ["intro"], "Legacy introduction survives the new decoder")
            assertEqual(legacy.timeline.map(\.id), ["past"], "Legacy timeline survives the new decoder")
            assertEqual(legacy.perspectives.map(\.id), ["speaker"], "Legacy perspectives survive the new decoder")
            assertEqual(legacy.thematicAngle?.title, "Costs", "Legacy thematic angle survives the new decoder")
            assertEqual(legacy.coverageSentiment?.score, 0.25, "Legacy coverage sentiment survives the new decoder")
            assertFalse(legacy.isEmpty, "Populated legacy sections are still present")
            assertEqual(
                try decoder.decode(OverviewEvidenceSections.self, from: encoder.encode(legacy)), legacy,
                "Every legacy field survives re-encoding")

            let nullJSON = """
                {"introduction":null,"timeline":null,"perspectives":null,"industryImpact":null,
                 "thematicAngle":null,"coverageSentiment":null}
                """
            let nullSections = try decoder.decode(OverviewEvidenceSections.self, from: Data(nullJSON.utf8))
            assertEqual(
                nullSections, OverviewEvidenceSections(), "Explicit null sections use the absent-section defaults")
            let emptyObject = try JSONSerialization.jsonObject(with: encoder.encode(nullSections)) as? [String: Any]
            assertEqual(emptyObject?.count, 0, "Empty optional sections are omitted from the encoded object")

            let fixture = impactFixture("Energy costs increased across all regional markets today.")
            let citation = impactCitation(fixture.passage)
            let impact = OverviewIndustryImpact(
                id: "round-trip-impact", industry: "Energy", implication: fixture.passage.text,
                citationIDs: [citation.id])
            let sections = OverviewEvidenceSections(
                timeline: legacy.timeline, perspectives: legacy.perspectives, thematicAngle: legacy.thematicAngle,
                coverageSentiment: legacy.coverageSentiment, introduction: legacy.introduction,
                industryImpact: [impact])
            let document = EventOverviewDocument(
                id: "round-trip-document", eventID: "round-trip-event",
                version: OverviewVersionContext(membershipVersion: 7, inputTextHash: "stable-input"),
                content: OverviewContent(
                    title: "Energy update", summary: "", citations: [citation], evidenceSections: sections),
                provenance: OverviewProvenance(
                    memberArticleIDs: [fixture.article.id], kind: .fallbackExcerpts,
                    createdAt: fixture.article.pubDate, updatedAt: fixture.article.pubDate))
            let decoded = try decoder.decode(EventOverviewDocument.self, from: encoder.encode(document))
            assertEqual(decoded, document, "Complete overview round trip preserves new and existing fields")
            assertEqual(decoded.industryImpact, [impact], "Document exposes the stored industry impact")
            assertEqual(decoded.citations[citation.id], citation, "Document preserves industry citation provenance")
            assertFalse(
                OverviewEvidenceSections(industryImpact: [impact]).isEmpty,
                "Industry impact alone keeps sections present")

            // Optional fields tolerate absence, but malformed present values must not silently disappear.
            for malformed in [
                #"{"industryImpact":{}}"#,
                #"{"industryImpact":[{"id":"bad","industry":"Energy","implication":"Costs rose."}]}"#,
                #"{"timeline":"invalid"}"#,
                #"{"perspectives":17}"#,
            ] {
                do {
                    _ = try decoder.decode(OverviewEvidenceSections.self, from: Data(malformed.utf8))
                    assertTrue(false, "Malformed evidence must throw: \(malformed)")
                } catch is DecodingError {
                    assertTrue(true, "Malformed evidence is rejected by the decoder")
                }
            }
        } catch {
            assertTrue(false, "Evidence compatibility fixture failed: \(error)")
        }
    }

    static func testOverviewDeduplicationBoundaries() {
        print("  - Testing inclusive deduplication thresholds and preservation of distinct viewpoints...")
        let excluded = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        // All tokens are distinct: the union is ten, making the threshold exact and independent of token ordering.
        let cases: [(text: String, keepPerspective: Bool, keepImpact: Bool)] = [
            (" \n\(excluded.uppercased())\t ", false, false),
            ("alpha bravo charlie delta echo foxtrot golf", false, false),  // 7/10: perspective boundary
            ("alpha bravo charlie delta echo foxtrot", true, false),  // 6/10: impact boundary
            ("alpha bravo charlie delta echo", true, true),
            ("kilo lima mike november oscar", true, true),
        ]
        for entry in cases {
            let perspective = OverviewPerspective(
                id: "threshold-view", participant: "Council", position: entry.text, citationIDs: ["c"],
                sourcePublisher: "Fixture News", originalWireSource: "AP")
            let impact = OverviewIndustryImpact(
                id: "threshold-impact", industry: "Energy", implication: entry.text, citationIDs: ["c"])
            assertEqual(
                OverviewComposer.deduplicatePerspectives([perspective], against: [excluded]),
                entry.keepPerspective ? [perspective] : [], "Perspective uses an inclusive 0.7 overlap threshold")
            assertEqual(
                OverviewComposer.deduplicateIndustryImpact([impact], against: [excluded]),
                entry.keepImpact ? [impact] : [], "Impact uses an inclusive 0.6 overlap threshold")
        }
        let first = OverviewPerspective(
            id: "first", participant: "Workers", position: "Workers supported revised pay rules.")
        let duplicate = OverviewPerspective(id: "duplicate", participant: "Council", position: excluded)
        let last = OverviewPerspective(
            id: "last", participant: "Residents", position: "Residents requested improved bus access.")
        assertEqual(
            OverviewComposer.deduplicatePerspectives([first, duplicate, last], against: [excluded, "  "]),
            [first, last], "Filtering preserves source-coverage order and every retained perspective's fields")
        let blank = OverviewIndustryImpact(id: "blank", industry: "Energy", implication: " \n\t ")
        assertTrue(
            OverviewComposer.deduplicateIndustryImpact([blank], against: []).isEmpty,
            "Empty implications are removed even without exclusions")
    }

    static func testComposerPreservesIndustryImpactWithTimeline() {
        print("  - Testing industry impact survives timeline attachment without repeating highlights...")
        let timelineSentences = [
            "The council approved the river bridge proposal on October 1, 2026.",
            "The council opened the river bridge to residents on October 3, 2026.",
        ]
        let impactSentence = "Energy costs increased across all regional markets today."
        let fixtures = (timelineSentences + [impactSentence]).enumerated().map {
            impactFixture($0.element, id: "composition-\($0.offset)")
        }
        let facts = fixtures.prefix(2).map {
            PassageAnchoredFact(
                id: "fact-\($0.article.id)", statement: $0.passage.text, passageID: $0.passage.id,
                quote: $0.passage.text, articleID: $0.article.id)
        }
        let document = OverviewComposer.composeOverview(
            eventID: "impact-timeline", eventTitle: "Bridge update", verifiedFacts: facts,
            passages: fixtures.map(\.passage), articles: fixtures.map(\.article), membershipVersion: 7)
        assertEqual(document.timeline.count, 2, "Control: both dated facts produce the attached timeline")
        assertEqual(
            document.industryImpact.map(\.implication), [impactSentence], "Attaching a timeline preserves impact")
        assertEqual(document.membershipVersion, 7, "Composition retains event membership binding")
        assertEqual(document.memberArticleIDs, fixtures.map { $0.article.id }, "Composition retains original members")
        for item in document.industryImpact {
            assertTrue(
                OverviewIndustryImpactExtractor.validateIndustryImpact(
                    item, against: document.citations, passages: fixtures.map(\.passage),
                    articles: fixtures.map(\.article)),
                "Composed industry citations remain resolvable and grounded after attachment")
        }

        let highlightedImpact = PassageAnchoredFact(
            id: "highlighted-impact", statement: impactSentence, passageID: fixtures[2].passage.id,
            quote: impactSentence, articleID: fixtures[2].article.id)
        let deduplicated = OverviewComposer.composeOverview(
            eventID: "impact-highlight", eventTitle: "Energy update", verifiedFacts: [highlightedImpact],
            passages: [fixtures[2].passage], articles: [fixtures[2].article])
        assertEqual(
            deduplicated.facts.map(\.text), [impactSentence], "Control: industry sentence is selected as a highlight")
        assertTrue(deduplicated.industryImpact.isEmpty, "Highlight sentence is not repeated as industry impact")
    }

    static func testModelCompositionDeduplicatesEvidenceSections() async {
        print("  - Testing model composition deduplicates introduction and facts while preserving other evidence...")
        let energy = "Energy costs increased across all regional markets today."
        let banking = "Regional banks reduced lending fees after the review."
        let healthcare = "Hospital workers resumed operations after the pay agreement."
        let technology = "Chipmakers halted production following severe component supply shortages."
        let agriculture = "Farmers reported falling crop prices after the harvest."
        let transportation = "Shipping companies cancelled deliveries after ports halted operations."
        let viewpoint = "Port workers supported revised staffing rules."
        let datedEvent = "The review opened on October 1, 2026."
        let first = impactFixture([energy, banking, healthcare].joined(separator: " "), id: "model-first")
        let second = impactFixture(
            [technology, agriculture, transportation, viewpoint, datedEvent].joined(separator: " "), id: "model-second")
        let firstCitation = impactCitation(first.passage, id: "first-impact-citation")
        let citation = impactCitation(second.passage)
        let keptImpact = OverviewIndustryImpact(
            id: "kept-impact", industry: "Transportation", implication: transportation, citationIDs: [citation.id])
        let keptPerspective = OverviewPerspective(
            id: "kept-view", participant: "Port workers", position: viewpoint,
            citationIDs: [citation.id], sourcePublisher: "Fixture News")
        let timeline = [
            OverviewTimelineItem(
                id: "model-timeline", dateText: "Oct 1, 2026", summary: datedEvent, citationIDs: [citation.id])
        ]
        let sections = OverviewEvidenceSections(
            timeline: timeline,
            perspectives: [
                OverviewPerspective(
                    id: "intro-view", participant: "Council", position: energy, citationIDs: [firstCitation.id]),
                OverviewPerspective(
                    id: "fact-view", participant: "Banks", position: banking, citationIDs: [firstCitation.id]),
                keptPerspective,
            ],
            industryImpact: [
                OverviewIndustryImpact(
                    id: "intro-impact", industry: "Energy", implication: energy, citationIDs: [firstCitation.id]),
                OverviewIndustryImpact(
                    id: "fact-impact", industry: "Financial Services", implication: banking,
                    citationIDs: [firstCitation.id]),
                keptImpact,
            ])
        let fallback = EventOverviewDocument(
            id: "model-fallback", eventID: "model-event",
            version: OverviewVersionContext(membershipVersion: 3, inputTextHash: "model-input"),
            content: OverviewContent(
                title: "Business update", summary: "", citations: [firstCitation, citation], evidenceSections: sections),
            provenance: OverviewProvenance(
                memberArticleIDs: [first.article.id, second.article.id], kind: .fallbackExcerpts))
        let answer = """
            INTRO|P1|\(energy)
            INTRO|P2|\(technology)
            FACT|P1|\(banking)
            FACT|P1|\(healthcare)
            FACT|P2|\(agriculture)
            """
        let model = NewsTextModel { prompt, _ in
            prompt.contains("Return plain text only:") ? answer : "YES"
        }
        do {
            let generated = try await OverviewComposer.composeWithModel(
                fallback: fallback, passages: [first.passage, second.passage],
                articles: [first.article, second.article], model: model)
            assertEqual(generated.kind, .synthesized, "Control: deterministic stub produces an accepted model draft")
            assertEqual(generated.summary, "\(energy) \(technology)", "Draft has the expected introduction")
            assertEqual(
                generated.facts.map(\.text), [banking, healthcare, agriculture], "Draft has the expected facts")
            assertEqual(generated.industryImpact, [keptImpact], "Intro and fact duplicates are removed from impact")
            assertEqual(
                generated.perspectives, [keptPerspective], "Intro and fact duplicates are removed from perspectives")
            assertEqual(generated.timeline, timeline, "Other evidence sections survive model replacement")
            assertEqual(
                generated.citations[citation.id], citation, "Retained impact and perspective keep their citation")
            assertEqual(generated.version, fallback.version, "Model replacement preserves input and version binding")
            assertEqual(
                generated.memberArticleIDs, fallback.memberArticleIDs, "Model replacement preserves original members")
            assertEqual(fallback.industryImpact.count, 3, "Composition does not mutate the fallback document")
        } catch {
            assertTrue(false, "Stubbed model composition failed: \(error)")
        }
    }

    static func testTimelineOrderingTiesAndMissingDates() {
        print("  - Testing stable timeline ordering, date precedence, and undated labels...")
        let early = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        let event = OverviewTimelineItem(
            id: "event", dateText: "Oct 1", summary: "Event occurred.", eventDate: early, publicationDate: later)
        let sameEvent = OverviewTimelineItem(
            id: "event-tie", dateText: "Oct 1", summary: "Additional event.", eventDate: early)
        let reported = OverviewTimelineItem(
            id: "reported", dateText: "Oct 1", summary: "Report published.", publicationDate: early)
        let publicationTie = OverviewTimelineItem(
            id: "reported-tie", dateText: "Oct 1", summary: "Second report published.", publicationDate: early)
        let undated = OverviewTimelineItem(id: "undated", dateText: "", summary: "  Undated update. \n")
        let undatedTie = OverviewTimelineItem(id: "undated-tie", dateText: "", summary: "Another update.")
        let plan = OverviewTimelineItem(
            id: "plan", dateText: "Oct 1", summary: "Vote scheduled.", isFuturePlan: true, eventDate: early)
        let laterPlan = OverviewTimelineItem(
            id: "later-plan", dateText: "Oct 2", summary: "Hearing scheduled.", isFuturePlan: true, eventDate: later)
        let undatedPlan = OverviewTimelineItem(
            id: "undated-plan", dateText: "", summary: "Review scheduled.", isFuturePlan: true)
        let input = [undated, undatedPlan, reported, laterPlan, event, publicationTie, plan, sameEvent, undatedTie]
        let sorted = EventOverviewReaderView.sortTimelineItems(input)
        assertEqual(
            sorted.map(\.id),
            [
                "event", "event-tie", "reported", "reported-tie", "undated", "undated-tie", "plan", "later-plan",
                "undated-plan",
            ],
            "Event date wins over publication date; dated rows precede undated rows and ties retain source order")
        assertEqual(
            EventOverviewReaderView.sortTimelineItems(sorted), sorted, "Sorting an ordered timeline is idempotent")
        assertEqual(input.first?.id, "undated", "Sorting leaves the source timeline untouched")
        assertEqual(
            EventOverviewReaderView.timelineItemAccessibilityLabel(item: undated), "Undated update",
            "Missing dates omit the date line and do not announce Reported")
        assertEqual(
            EventOverviewReaderView.timelineItemAccessibilityLabel(item: undatedPlan), "Planned. Review scheduled",
            "Undated plans still announce Planned without a fabricated date")
        let blank = OverviewTimelineItem(id: "blank", dateText: "Oct 1", summary: " \n\t ")
        assertEqual(
            EventOverviewReaderView.filterValidTimeline([undated, blank]), [undated],
            "An undated summary is retained while a dated blank summary is removed")
    }

    static func testEvidenceAttributionFallbacks() {
        print("  - Testing evidence attribution fallbacks and punctuation...")
        let fixture = impactFixture("Energy costs increased across all regional markets today.")
        let source = OverviewSourceMetadata(name: "Fixture News")
        let citation = impactCitation(fixture.passage, source: source)
        let unknownCitation = impactCitation(fixture.passage, id: "unknown-source")
        let secondCitation = impactCitation(
            fixture.passage, id: "second-source", source: OverviewSourceMetadata(name: "Second Wire"))
        assertEqual(
            EventOverviewReaderView.highlightAccessibilityLabel(
                takeaway: "  Costs rose. \n", publisher: nil, citations: [unknownCitation, citation, secondCitation]),
            "Costs rose. Source: Fixture News, Second Wire", "Unknown highlight publisher falls back to cited sources")
        assertEqual(
            EventOverviewReaderView.highlightAccessibilityLabel(
                takeaway: "Costs rose.", publisher: "Named Publisher", citations: [citation]),
            "Costs rose. Source: Named Publisher", "Explicit publisher takes precedence over citation attribution")
        assertEqual(
            EventOverviewReaderView.perspectiveAccessibilityLabel(
                participant: "  Council \n", position: "  Supported the plan. \n", source: nil, citations: [citation]),
            "Council. Supported the plan. Source: Fixture News",
            "Perspective trims text and falls back to citation source")
        assertEqual(
            EventOverviewReaderView.industryImpactAccessibilityLabel(
                industry: "Energy", implication: "  Costs rose. \n", citations: [unknownCitation]),
            "Energy: Costs rose.", "Unknown sources do not create empty source announcements")
        assertEqual(
            EventOverviewReaderView.industryImpactAccessibilityLabel(
                industry: "Energy", implication: "Costs rose.", citations: [citation, secondCitation]),
            "Energy: Costs rose. Source: Fixture News, Second Wire", "Multiple sources use one sentence separator")
        assertEqual(
            EventOverviewReaderView.formatPerspectiveSource(wire: " \n ", publisher: "  Local News \n"),
            "via Local News", "Blank wire falls back to a trimmed publisher")
        assertEqual(
            EventOverviewReaderView.formatPerspectiveSource(wire: " via AP ", publisher: "Local News"),
            "via AP syndicate", "Wire takes precedence and does not duplicate the via prefix")
        assertEqual(
            EventOverviewReaderView.formatPerspectiveSource(wire: " \n", publisher: " \t"), nil,
            "Absent attribution does not generate a placeholder")

        let incomplete = [
            OverviewIndustryImpact(id: "blank-sector", industry: " \n", implication: "Costs rose."),
            OverviewIndustryImpact(id: "blank-text", industry: "Energy", implication: " \t"),
        ]
        assertFalse(
            EventOverviewReaderView.hasEvidenceContent(
                timeline: [], perspectives: [], industryImpact: incomplete, thematicAngle: nil),
            "Incomplete impact entries do not make an empty evidence section visible")
        let valid = OverviewIndustryImpact(id: "visible", industry: "Energy", implication: fixture.passage.text)
        assertEqual(
            EventOverviewReaderView.filterValidIndustryImpact([incomplete[0], valid, incomplete[1]]), [valid],
            "Filtering incomplete impact entries preserves valid data")
    }
}
