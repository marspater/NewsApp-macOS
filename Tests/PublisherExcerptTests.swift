// PublisherExcerptTests.swift
// Dedicated regression harness for publisher-excerpt overviews (ADR: Release simplification)

import AppKit
import Foundation
import SwiftUI

@main
@MainActor
struct PublisherExcerptTests {
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
        print("=== Running Publisher Excerpt Regression Tests ===")

        testCurrentAnalysisVersionBumped()
        testExactExcerptCitationCorrespondence()
        testAttributionControls()
        await testEmptySummaryRenderingAndStorage()
        testCachedProseInvalidation()
        testPublisherExcerptsDisplayTag()
        await testAIDisabledBehavior()
        await testCancellationAndSupersession()
        testRetainedDeterministicSections()

        print("Finished \(testsRun) publisher excerpt checks with \(failures) failures.")
        if failures > 0 {
            exit(1)
        } else {
            print("✅ ALL PUBLISHER EXCERPT CHECKS PASSED")
        }
    }

    // MARK: - 1. Version Bump
    static func testCurrentAnalysisVersionBumped() {
        print("  - Testing current analysis version is at least 11...")
        assertTrue(
            EventOverviewDocument.currentAnalysisVersion >= 11,
            "EventOverviewDocument.currentAnalysisVersion must be at least 11 to invalidate overviews cached before"
                + " publisher excerpts")
    }

    // MARK: - 2. Exact Excerpt / Citation Correspondence
    static func testExactExcerptCitationCorrespondence() {
        print("  - Testing exact excerpt and citation correspondence...")

        let sentence1 =
            "The international conference concluded on Sunday with delegates approving the renewable energy treaty."
        let sentence2 =
            "Treasury officials confirmed the economic transition fund will disburse initial grants starting next month."
        let sentence3 =
            "Independent energy analysts reported renewable investments doubled across the participating nations."

        let article1 = FeedArticle(
            storedID: "art_reuters_1",
            title: "Renewable Energy Treaty Approved by 190 Nations",
            link: "https://reuters.com/world/renewable-treaty-190",
            guid: "guid_reuters_1",
            description: sentence1,
            pubDate: Date(timeIntervalSince1970: 1_729_000_000),
            source: "Reuters"
        )
        let article2 = FeedArticle(
            storedID: "art_ap_2",
            title: "Economic Transition Grants Slated for Early Release",
            link: "https://apnews.com/article/energy-grants-fund-2",
            guid: "guid_ap_2",
            description: sentence2,
            pubDate: Date(timeIntervalSince1970: 1_729_000_100),
            source: "Associated Press"
        )
        let article3 = FeedArticle(
            storedID: "art_bbc_3",
            title: "Analysts Note Doubling of Clean Investments",
            link: "https://bbc.com/news/clean-investments-3",
            guid: "guid_bbc_3",
            description: sentence3,
            pubDate: Date(timeIntervalSince1970: 1_729_000_200),
            source: "BBC News"
        )

        let passage1 = EvidencePassage(id: "pass_1", articleID: "art_reuters_1", text: sentence1)
        let passage2 = EvidencePassage(id: "pass_2", articleID: "art_ap_2", text: sentence2)
        let passage3 = EvidencePassage(id: "pass_3", articleID: "art_bbc_3", text: sentence3)

        let passages = [passage1, passage2, passage3]
        let articles = [article1, article2, article3]

        let facts = PassageFactExtractor.deterministicExtract(passages: passages)
        assertEqual(facts.count, 3, "Extracted 3 passage-anchored facts")

        let overview = OverviewComposer.composeOverview(
            eventID: "event_treaty_100",
            eventTitle: "Renewable Energy Treaty Historic Agreement",
            verifiedFacts: facts,
            passages: passages,
            articles: articles,
            membershipVersion: 1
        )

        // Title should be a stored publisher headline
        assertEqual(overview.title, article1.title, "Overview title uses stored publisher headline")

        // Excerpt kind must be fallbackExcerpts
        assertEqual(overview.kind, .fallbackExcerpts, "Overview kind must be .fallbackExcerpts")

        // Check each fact correspondence
        for fact in overview.facts {
            assertTrue(!fact.citationIDs.isEmpty, "Fact \(fact.id) must have at least one citation")
            for citID in fact.citationIDs {
                guard let citation = overview.citations[citID] else {
                    assertTrue(false, "Citation \(citID) must exist in overview.citations")
                    continue
                }
                // Verbatim containment: fact text must match quotation from passage
                assertEqual(citation.quote, fact.text, "Fact text matches citation quote verbatim")
                let sourceArt = articles.first(where: { $0.id == citation.articleID })
                assertTrue(sourceArt != nil, "Citation articleID points to valid member article")
                assertEqual(citation.sourceTitle, sourceArt?.title, "Citation has correct source title")
                assertEqual(citation.sourceName, sourceArt?.source, "Citation has correct source name")
                assertEqual(citation.sourceURL, sourceArt?.link, "Citation has correct source URL")
            }
        }
    }

    // MARK: - 3. Attribution Controls
    static func testAttributionControls() {
        print("  - Testing attribution controls and source matching...")

        let article = FeedArticle(
            storedID: "art_bloomberg_1",
            title: "Global Supply Chains Stabilize After Port Agreement",
            link: "https://bloomberg.com/news/supply-chains-1",
            guid: "guid_bbg_1",
            description: "Port operators and maritime unions reached an accord on work hours.",
            pubDate: Date(timeIntervalSince1970: 1_729_000_500),
            source: "Bloomberg"
        )
        let citation = OverviewCitation(
            id: "cite_port_1",
            articleID: "art_bloomberg_1",
            passageID: "pass_port_1",
            passageFingerprint: "fp_port_1",
            quote: "Port operators and maritime unions reached an accord on work hours.",
            source: OverviewSourceMetadata(
                title: article.title,
                name: article.source,
                url: article.link,
                publishedAt: article.pubDate
            )
        )

        let matched = EventOverviewReaderView.matchingArticle(for: citation, in: [article])
        assertEqual(matched?.id, "art_bloomberg_1", "Direct matching article found")
        assertEqual(matched?.source, "Bloomberg", "Matched article source name is accurate")
    }

    // MARK: - 4. Empty Summary Rendering & Storage
    static func testEmptySummaryRenderingAndStorage() async {
        print("  - Testing empty summary rendering and JSON round-trip...")

        let sentence = "Negotiators presented the updated draft text early Monday morning."
        let article = FeedArticle(
            storedID: "art_1",
            title: "Negotiators Present Draft Text",
            link: "https://example.com/draft",
            guid: "guid_1",
            description: sentence,
            // Whole seconds round-trip exactly through SQLite's Unix timestamp representation.
            pubDate: Date(timeIntervalSince1970: 1_729_000_000),
            source: "Example Wire"
        )
        let passage = EvidencePassage(id: "p1", articleID: "art_1", text: sentence)
        let facts = PassageFactExtractor.deterministicExtract(passages: [passage])

        let overview = OverviewComposer.composeOverview(
            eventID: "event_1",
            eventTitle: "Draft Text Update",
            verifiedFacts: facts,
            passages: [passage],
            articles: [article],
            membershipVersion: 1
        )

        // Summary must be empty string
        assertEqual(overview.summary, "", "Overview summary must be strictly empty")
        assertFalse(
            EventOverviewReaderView.hasSummaryContent(overview.summary),
            "Reader view hasSummaryContent must evaluate to false for empty summary"
        )

        // JSON encoding and decoding must preserve empty summary and all fields
        do {
            let data = try JSONEncoder().encode(overview)
            let decoded = try JSONDecoder().decode(EventOverviewDocument.self, from: data)
            assertEqual(decoded.id, overview.id, "Round-trip preserves document ID")
            assertEqual(decoded.summary, "", "Round-trip preserves empty summary")
            assertEqual(decoded.kind, .fallbackExcerpts, "Round-trip preserves excerpt provenance kind")
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            _ = try await db.upsertArticles([article])
            assertTrue(try await db.recordEventOverview(overview), "SQLite accepts an empty summary")
            let stored = try await db.fetchEventOverview(eventID: overview.eventID)
            assertEqual(stored?.summary, "", "SQLite preserves the empty summary")
            assertEqual(stored?.facts, overview.facts, "SQLite preserves excerpt text")
            assertEqual(stored?.citations, overview.citations, "SQLite preserves source citations")
            await db.close()
            assertEqual(
                decoded.analysisVersion, EventOverviewDocument.currentAnalysisVersion,
                "Round-trip preserves analysis version")
        } catch {
            assertTrue(false, "Failed to round-trip overview document through JSON: \(error)")
        }
    }

    // MARK: - 5. Cached Prose Invalidation
    static func testCachedProseInvalidation() {
        print("  - Testing cached prose invalidation...")

        let content = OverviewContent(
            title: "Old Generated Title",
            summary: "This was a model-written summary from a previous analysis version.",
            facts: [],
            citations: []
        )
        let oldDoc = EventOverviewDocument(
            id: "old_doc_1",
            eventID: "evt_1",
            version: OverviewVersionContext(
                membershipVersion: 1,
                inputTextHash: "hash_1",
                schemaVersion: EventOverviewDocument.currentSchemaVersion,
                analysisVersion: 7  // old version
            ),
            content: content,
            provenance: OverviewProvenance(memberArticleIDs: ["art_1"], kind: .synthesized)
        )

        assertTrue(
            oldDoc.isStale(currentMembershipVersion: 1, currentInputTextHash: "hash_1"),
            "Document with analysisVersion 7 must be stale when currentAnalysisVersion is 11"
        )

        let currentDoc = EventOverviewDocument(
            id: "new_doc_1",
            eventID: "evt_1",
            version: OverviewVersionContext(
                membershipVersion: 1,
                inputTextHash: "hash_1",
                schemaVersion: EventOverviewDocument.currentSchemaVersion,
                analysisVersion: EventOverviewDocument.currentAnalysisVersion
            ),
            content: OverviewContent(title: "Publisher Title", summary: "", facts: [], citations: []),
            provenance: OverviewProvenance(memberArticleIDs: ["art_1"], kind: .fallbackExcerpts)
        )

        assertFalse(
            currentDoc.isStale(currentMembershipVersion: 1, currentInputTextHash: "hash_1"),
            "Document with analysisVersion 9 must not be stale"
        )
    }

    // MARK: - 6. Publisher Excerpts Display Tag
    static func testPublisherExcerptsDisplayTag() {
        print("  - Testing Publisher excerpts display tag...")

        let doc = EventOverviewDocument(
            id: "excerpt_doc",
            eventID: "evt_excerpt",
            version: OverviewVersionContext(
                membershipVersion: 1,
                inputTextHash: "h1",
                analysisVersion: 8
            ),
            content: OverviewContent(title: "Title", summary: "", facts: [], citations: []),
            provenance: OverviewProvenance(memberArticleIDs: ["a1"], kind: .fallbackExcerpts)
        )

        assertEqual(doc.kind, .fallbackExcerpts, "Overview kind is fallbackExcerpts")
    }

    // MARK: - 7. AI-Disabled Behavior
    static func testAIDisabledBehavior() async {
        print("  - Testing AI-disabled requests produce deterministic excerpts without being marked provisional...")

        let sentence1 = "The central bank held the benchmark interest rate steady at five percent on Wednesday."
        let sentence2 = "Monetary policy committee members voted unanimously to maintain current borrowing costs."
        let article1 = FeedArticle(
            storedID: "art_cb_1",
            title: "Central Bank Holds Benchmark Rate Steady",
            link: "https://ft.com/central-bank-rates",
            guid: "guid_cb_1",
            description: sentence1,
            pubDate: Date(),
            source: "Financial Times",
            fullContent: sentence1
        )
        let article2 = FeedArticle(
            storedID: "art_cb_2",
            title: "Interest Rates Remain at 5% Following Monetary Decision",
            link: "https://wsj.com/central-bank-decision",
            guid: "guid_cb_2",
            description: sentence2,
            pubDate: Date(),
            source: "The Wall Street Journal",
            fullContent: sentence2
        )
        let articles = [article1, article2]

        let db = DatabaseEngine(path: ":memory:")
        do {
            try await db.open()
            _ = try await db.upsertArticles(articles)
        } catch {
            assertTrue(false, "Failed to initialize and open in-memory database: \(error)")
            return
        }
        let store = ArticleStore(database: db)
        let queue = EnrichmentQueue(store: store)

        // The coordinator never calls a model: publisher excerpts are its only overview.
        let coordinator = OverviewGenerationCoordinator(
            store: store,
            queue: queue,
            allowsEnergy: { true },
            extractText: nil
        )

        let result = await coordinator.requestOverview(
            eventID: "evt_rate_decision",
            eventTitle: article1.title,
            membershipVersion: 1,
            articles: articles,
            priority: .onDemand,
            store: store
        )

        guard let overview = result else {
            assertTrue(false, "Coordinator must return a non-nil overview when AI is disabled")
            return
        }

        assertEqual(overview.kind, .fallbackExcerpts, "Overview kind must be fallbackExcerpts")
        assertEqual(
            overview.analysisVersion, EventOverviewDocument.currentAnalysisVersion,
            "AI-disabled overview must have currentAnalysisVersion (8), not provisional (0)"
        )
        assertEqual(overview.summary, "", "AI-disabled overview has empty summary")
        assertFalse(
            overview.isStale(currentMembershipVersion: 1, currentInputTextHash: overview.inputTextHash),
            "AI-disabled overview must not be immediately stale"
        )
    }

    // MARK: - 8. Cancellation and Supersession
    static func testCancellationAndSupersession() async {
        print("  - Testing coordinator cancellation and supersession...")

        let coordinator = OverviewGenerationCoordinator(
            store: nil,
            extractText: nil
        )

        // Cancelled parent task
        let cancelledTask = Task { () -> EventOverviewDocument? in
            Task.cancelVisitor()
            return await coordinator.requestOverview(
                eventID: "evt_cancel_1",
                eventTitle: "Cancelled Event",
                membershipVersion: 1,
                articles: [],
                priority: .onDemand
            )
        }
        let cancelledResult = await cancelledTask.value
        assertEqual(cancelledResult, nil, "Cancelled task returns nil")
    }

    // MARK: - 9. Retained Deterministic Sections
    static func testRetainedDeterministicSections() {
        print("  - Testing retained deterministic timeline, perspectives, and thematic sections...")

        let sentence1 = "On October 12, the council convened in Geneva to negotiate the transit agreement."
        let sentence2 = "Transport Minister Schmidt told reporters that passenger services will resume on Friday."
        let sentence3 = "Regional rail operators said the agreement resolves infrastructure maintenance disputes."

        let article1 = FeedArticle(
            storedID: "art_rail_1",
            title: "Council Convenes in Geneva Over Transit Agreement",
            link: "https://example.com/rail-1",
            guid: "guid_rail_1",
            description: sentence1,
            pubDate: Date(timeIntervalSince1970: 1_729_000_000),
            source: "Swiss Info"
        )
        let article2 = FeedArticle(
            storedID: "art_rail_2",
            title: "Passenger Rail Services Set to Resume Friday",
            link: "https://example.com/rail-2",
            guid: "guid_rail_2",
            description: sentence2,
            pubDate: Date(timeIntervalSince1970: 1_729_000_100),
            source: "Deutsche Welle"
        )
        let article3 = FeedArticle(
            storedID: "art_rail_3",
            title: "Maintenance Dispute Resolved by Geneva Accord",
            link: "https://example.com/rail-3",
            guid: "guid_rail_3",
            description: sentence3,
            pubDate: Date(timeIntervalSince1970: 1_729_000_200),
            source: "Railway Gazette"
        )

        let passage1 = EvidencePassage(id: "p_rail_1", articleID: "art_rail_1", text: sentence1)
        let passage2 = EvidencePassage(id: "p_rail_2", articleID: "art_rail_2", text: sentence2)
        let passage3 = EvidencePassage(id: "p_rail_3", articleID: "art_rail_3", text: sentence3)

        let passages = [passage1, passage2, passage3]
        let articles = [article1, article2, article3]
        let facts = PassageFactExtractor.deterministicExtract(passages: passages)

        let overview = OverviewComposer.composeOverview(
            eventID: "evt_rail",
            eventTitle: "Geneva Rail Agreement",
            verifiedFacts: facts,
            passages: passages,
            articles: articles,
            membershipVersion: 1
        )

        assertEqual(overview.summary, "", "Summary remains empty")
        assertEqual(overview.kind, .fallbackExcerpts, "Overview kind is fallbackExcerpts")

        // Check timeline retention
        if !overview.timeline.isEmpty {
            for item in overview.timeline {
                assertTrue(!item.dateText.isEmpty, "Timeline item has dateText")
                assertTrue(!item.summary.isEmpty, "Timeline item has summary")
            }
        }

        // Check perspectives retention
        if !overview.perspectives.isEmpty {
            for persp in overview.perspectives {
                assertTrue(!persp.participant.isEmpty, "Perspective has participant")
                assertTrue(!persp.position.isEmpty, "Perspective has position")
            }
        }
    }
}

extension Task where Success == Never, Failure == Never {
    fileprivate static func cancelVisitor() {
        withUnsafeCurrentTask { $0?.cancel() }
    }
}
