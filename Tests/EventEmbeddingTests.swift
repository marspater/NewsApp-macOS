// EventEmbeddingTests.swift
// Tests for on-device neural sentence embeddings (CoreML MiniLM), SQLite persistence,
// and hybrid anchor + embedding event matching (#127, #307).

import Accelerate
import Foundation
import SQLite3

extension NewsTests {
    static func testEventEmbeddingIntegration() async throws {
        print("  - Testing on-device sentence embeddings & hybrid matcher (#127, #307)...")

        try await testSentenceEmbedderInference()
        try await testArticleEmbeddingsDatabaseRoundtrip()
        try await testHybridEventMatcherSemanticRescueAndVeto()
    }

    // MARK: - SentenceEmbedder Inference & Normalization (#127)

    private static func testSentenceEmbedderInference() async throws {
        let embedder = SentenceEmbedder.shared
        guard await embedder.isAvailable else {
            print("    ⚠️ SentenceEmbedder model not available at default path; skipping live CoreML inference check.")
            return
        }

        // 1. Verify embedding dimension and unit length
        let textA = "Apple reports record quarterly revenue driven by iPhone sales and services growth."
        let textB = "Apple reports record revenue in Q3 driven by strong iPhone sales."
        let textC = "A powerful magnitude 6.2 earthquake struck eastern Turkey, damaging several buildings."

        guard let vecA = await embedder.embed(textA),
            let vecB = await embedder.embed(textB),
            let vecC = await embedder.embed(textC)
        else {
            assertTrue(false, "Failed to compute sentence embeddings")
            return
        }

        assertEqual(vecA.count, 384, "Embedding vector dimension must be 384")
        assertEqual(vecB.count, 384, "Embedding vector dimension must be 384")
        assertEqual(vecC.count, 384, "Embedding vector dimension must be 384")

        // 2. Verify L2 normalization
        var normSquaredA: Float = 0
        vDSP_svesq(vecA, 1, &normSquaredA, vDSP_Length(vecA.count))
        let normA = sqrt(normSquaredA)
        assertTrue(abs(normA - 1.0) < 1e-3, "Embedded vectors must be L2-normalized to unit sphere (got \(normA))")

        // 3. Verify semantic similarity: related financial reports vs unrelated earthquake report
        let simRelated = SentenceEmbedder.cosineSimilarity(vecA, vecB)
        let simUnrelated = SentenceEmbedder.cosineSimilarity(vecA, vecC)

        assertTrue(
            simRelated > 0.80,
            "Semantically equivalent financial reports should have high cosine similarity (got \(simRelated))"
        )
        assertTrue(
            simUnrelated < 0.20,
            "Semantically divergent earthquake report should have low cosine similarity (got \(simUnrelated))"
        )

        // 4. Batch embedding preserves order
        let batchVectors = await embedder.embedBatch([textA, textB, textC])
        assertEqual(batchVectors.count, 3, "Batch embed should return 3 vectors")
        assertTrue(
            abs(SentenceEmbedder.cosineSimilarity(batchVectors[0], vecA) - 1.0) < 1e-5,
            "Batch vector 0 matches single embed vector"
        )
        assertTrue(
            abs(SentenceEmbedder.cosineSimilarity(batchVectors[1], vecB) - 1.0) < 1e-5,
            "Batch vector 1 matches single embed vector"
        )
        assertTrue(
            abs(SentenceEmbedder.cosineSimilarity(batchVectors[2], vecC) - 1.0) < 1e-5,
            "Batch vector 2 matches single embed vector"
        )
    }

    // MARK: - SQLite v21 article_embeddings Roundtrip & Cascade (#127, #307)

    private static func testArticleEmbeddingsDatabaseRoundtrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test_embeddings.sqlite").path
        let db = DatabaseEngine(path: dbPath)
        try await db.open()

        let now = Date()

        // Insert prerequisite articles into articles table
        let art1 = FeedArticle(
            title: "Tech Earnings Surge",
            link: "https://example.com/art1",
            guid: "guid_1",
            description: "Quarterly profits rise",
            pubDate: now,
            source: "Financial News",
            fullContent: "Quarterly profits rise at unprecedented pace"
        )
        let art2 = FeedArticle(
            title: "Earthquake Reports",
            link: "https://example.com/art2",
            guid: "guid_2",
            description: "Tremors recorded",
            pubDate: now,
            source: "Global News",
            fullContent: "Tremors recorded in eastern province"
        )
        _ = try await db.upsertArticles([art1, art2])
        let article1ID = art1.id
        let article2ID = art2.id

        // Generate synthetic normalized 384-d vectors
        var dummyVec1 = [Float](repeating: 0.05, count: 384)
        var dummyVec2 = [Float](repeating: -0.05, count: 384)
        dummyVec1[0] = 0.5
        dummyVec2[0] = -0.5

        // Normalize dummy vectors
        var sumSq1: Float = 0
        vDSP_svesq(dummyVec1, 1, &sumSq1, 384)
        var norm1 = sqrt(sumSq1)
        vDSP_vsdiv(dummyVec1, 1, &norm1, &dummyVec1, 1, 384)

        var sumSq2: Float = 0
        vDSP_svesq(dummyVec2, 1, &sumSq2, 384)
        var norm2 = sqrt(sumSq2)
        vDSP_vsdiv(dummyVec2, 1, &norm2, &dummyVec2, 1, 384)

        let initialPayload = [
            article1ID: dummyVec1,
            article2ID: dummyVec2,
        ]

        // 1. Upsert embeddings
        try await db.upsertArticleEmbeddings(initialPayload, modelVersion: 1)

        // 2. Fetch embeddings and verify roundtrip precision
        let fetched = try await db.fetchArticleEmbeddings(articleIDs: [article1ID, article2ID], modelVersion: 1)
        assertEqual(fetched.count, 2, "Both embeddings must be retrieved")

        guard let retVec1 = fetched[article1ID], let retVec2 = fetched[article2ID] else {
            assertTrue(false, "Retrieved vectors must not be nil")
            return
        }

        assertEqual(retVec1.count, 384, "Retrieved vector 1 must be 384-dimensional")
        assertEqual(retVec2.count, 384, "Retrieved vector 2 must be 384-dimensional")

        let dot1 = SentenceEmbedder.cosineSimilarity(retVec1, dummyVec1)
        assertTrue(abs(dot1 - 1.0) < 1e-5, "Vector 1 roundtrip fidelity must be exact (got dot \(dot1))")

        let dot2 = SentenceEmbedder.cosineSimilarity(retVec2, dummyVec2)
        assertTrue(abs(dot2 - 1.0) < 1e-5, "Vector 2 roundtrip fidelity must be exact (got dot \(dot2))")

        // 3. Different model_version returns empty
        let fetchedOtherVersion = try await db.fetchArticleEmbeddings(articleIDs: [article1ID], modelVersion: 2)
        assertTrue(fetchedOtherVersion.isEmpty, "Querying mismatched model_version must return empty")

        // 4. Verify ON CONFLICT DO UPDATE
        var updatedVec1 = dummyVec1
        updatedVec1[1] = 0.8
        var sumSqUp: Float = 0
        vDSP_svesq(updatedVec1, 1, &sumSqUp, 384)
        var normUp = sqrt(sumSqUp)
        vDSP_vsdiv(updatedVec1, 1, &normUp, &updatedVec1, 1, 384)

        try await db.upsertArticleEmbeddings([article1ID: updatedVec1], modelVersion: 1)
        let reFetched = try await db.fetchArticleEmbeddings(articleIDs: [article1ID], modelVersion: 1)
        guard let reVec1 = reFetched[article1ID] else {
            assertTrue(false, "Re-fetched vector must not be nil")
            return
        }
        let reDot = SentenceEmbedder.cosineSimilarity(reVec1, updatedVec1)
        assertTrue(abs(reDot - 1.0) < 1e-5, "Updated vector roundtrip fidelity must be exact")
    }

    // MARK: - Hybrid EventMatcher Semantic Rescue and Veto (#307)

    private static func testHybridEventMatcherSemanticRescueAndVeto() async throws {
        let now = Date()

        func makeFeatures(
            anchors: Set<String>,
            keywords: Set<String>,
            places: Set<String> = [],
            periods: Set<String> = [],
            weekdays: Set<String> = [],
            numbers: Set<String> = [],
            hours: Double = 0
        ) -> EventFeatures {
            EventFeatures(
                language: "en",
                organizations: anchors,
                places: places,
                keywords: keywords,
                date: now.addingTimeInterval(hours * 3600),
                titleNumbers: numbers,
                periods: periods,
                weekdays: weekdays
            )
        }

        // Case 1: Semantic Rescue
        // Low keyword Jaccard overlap (different wording/paraphrase), but shares a specific named anchor
        // and has very high neural similarity (0.86 >= 0.82) with no factual conflict.
        let featA = makeFeatures(
            anchors: ["anthropic"],
            keywords: ["claude", "release", "benchmark", "reasoning", "coding"],
            hours: 1
        )
        let featB = makeFeatures(
            anchors: ["anthropic"],
            keywords: ["frontier", "model", "capabilities", "software", "development"],
            hours: 2
        )

        // Without embedding similarity, rule-based Jaccard overlap is too low to merge:
        let baselineAssessment = EventMatcher.assess(featA, featB, embeddingSimilarity: nil)
        assertFalse(baselineAssessment.isMatch, "Low lexical overlap alone fails to match under strict rules")

        // With high neural semantic similarity (0.86 >= 0.82) and shared specific anchor, semantic rescue activates:
        let rescuedAssessment = EventMatcher.assess(featA, featB, embeddingSimilarity: 0.86)
        assertTrue(
            rescuedAssessment.isMatch,
            "High neural similarity (0.86) rescues genuine paraphrase with shared specific anchor")
        assertEqual(rescuedAssessment.conflict, nil, "Rescued pair must have no factual conflict")

        // Case 2: Semantic Veto
        // Borderline rule overlap or single shared anchor, but low neural similarity (0.42 < 0.55 veto threshold).
        let featBorderlineA = makeFeatures(
            anchors: ["senate"],
            keywords: ["vote", "hearing", "committee", "bill", "passage"],
            hours: 1
        )
        let featBorderlineB = makeFeatures(
            anchors: ["senate"],
            keywords: ["vote", "nominee", "confirmation", "cabinet", "hearing"],
            hours: 2
        )

        let vetoedAssessment = EventMatcher.assess(featBorderlineA, featBorderlineB, embeddingSimilarity: 0.42)
        assertFalse(
            vetoedAssessment.isMatch, "Low neural similarity (< 0.55) vetoes false merge despite shared generic anchor")
        assertEqual(vetoedAssessment.conflict, .semanticDivergence, "Conflict must be recorded as semanticDivergence")

        // Case 3: Invariant - Hard Factual Conflict Cannot Be Rescued by High Similarity
        // Even if cosine similarity is 0.95, contradictory factual evidence (different fiscal quarter) MUST NOT match!
        let quarter3 = makeFeatures(
            anchors: ["apple"],
            keywords: ["revenue", "record", "iphone", "sale"],
            periods: ["q3"],
            hours: 1
        )
        let quarter4 = makeFeatures(
            anchors: ["apple"],
            keywords: ["revenue", "record", "iphone", "sale"],
            periods: ["q4"],
            hours: 2
        )

        let hardConflictAssessment = EventMatcher.assess(quarter3, quarter4, embeddingSimilarity: 0.95)
        assertFalse(
            hardConflictAssessment.isMatch, "Hard period conflict must never be overridden by high semantic similarity")
        assertEqual(hardConflictAssessment.conflict, .period, "Period conflict must remain intact")

        // Case 4: Invariant - Place Conflict Cannot Be Rescued
        let strikeKharkiv = makeFeatures(
            anchors: ["military"],
            keywords: ["missile", "strike", "infrastructure", "damage"],
            places: ["kharkiv"],
            hours: 1
        )
        let strikeOdesa = makeFeatures(
            anchors: ["military"],
            keywords: ["missile", "strike", "infrastructure", "damage"],
            places: ["odesa"],
            hours: 2
        )

        let placeConflictAssessment = EventMatcher.assess(strikeKharkiv, strikeOdesa, embeddingSimilarity: 0.93)
        assertFalse(
            placeConflictAssessment.isMatch, "Hard place conflict must never be overridden by high semantic similarity")
        assertEqual(placeConflictAssessment.conflict, .places, "Places conflict must remain intact")
    }
}
