// EventEmbeddingTests.swift
// Tests for on-device neural sentence embeddings (CoreML MiniLM), SQLite persistence,
// and hybrid anchor + embedding event matching (#127, #307).

import Accelerate
import CoreML
import Foundation
import SQLite3

extension NewsTests {
    static func testEventEmbeddingIntegration() async throws {
        print("  - Testing on-device sentence embeddings & hybrid matcher (#127, #307)...")

        try testBertTokenizer()
        try await testSentenceEmbedderInference()
        try await testArticleEmbeddingsDatabaseRoundtrip()
        try await testArticleEmbeddingsForeignKeyCascade()
        try await testHybridEventMatcherSemanticRescueAndVeto()
        try await testEmbeddingAwareValidationOfAssignedMembers()
    }

    // MARK: - BertWordPieceTokenizer (#127)

    private static func testBertTokenizer() throws {
        let vocabURL =
            Bundle.main.url(forResource: "vocab", withExtension: "txt", subdirectory: "Models")
            ?? URL(fileURLWithPath: "Sources/Resources/Models/vocab.txt")
        let tokenizer = try BertWordPieceTokenizer(vocabURL: vocabURL)

        // 1. Punctuation handling, CLS/SEP tokens and padding
        let (ids, mask) = tokenizer.encode("Apple Inc., valued at $3T - up 5%.", maxSequenceLength: 32)
        assertEqual(ids.count, 32, "Padded tokens must reach maxSequenceLength")
        assertEqual(mask.count, 32, "Attention mask must reach maxSequenceLength")

        assertEqual(ids[0], 101, "First token must be [CLS]")

        let validCount = mask.filter { $0 == 1 }.count
        let padCount = mask.filter { $0 == 0 }.count
        assertTrue(validCount > 6, "Must tokenize words and punctuation into separate tokens")
        assertEqual(padCount, 32 - validCount, "Remaining tokens must be padded")
        assertEqual(ids[validCount - 1], 102, "Last valid token must be [SEP]")

        for i in validCount..<32 {
            assertEqual(ids[i], 0, "Padding token must be [PAD] (0)")
            assertEqual(mask[i], 0, "Padding mask must be 0")
        }

        // 2. Truncation bound
        let (shortIDs, shortMask) = tokenizer.encode(
            "Apple reports quarterly financial earnings and record revenues for institutional investors.",
            maxSequenceLength: 8
        )
        assertEqual(shortIDs.count, 8, "Truncated length must not exceed maxSequenceLength")
        assertEqual(shortIDs[0], 101, "Truncated sequence begins with [CLS]")
        assertEqual(shortIDs[7], 102, "Truncated sequence ends with [SEP]")
        assertEqual(shortMask, [Int32](repeating: 1, count: 8), "Truncated sequence has full attention mask")

        // 3. Uncased BERT strips accents: an accented name must tokenize like its ASCII form, never as [UNK] (100).
        let (accented, _) = tokenizer.encode("Erdoğan met Sánchez in Çanakkale", maxSequenceLength: 32)
        let (ascii, _) = tokenizer.encode("Erdogan met Sanchez in Canakkale", maxSequenceLength: 32)
        assertEqual(accented, ascii, "Accented names tokenize like their ASCII forms")
        assertFalse(accented.contains(100), "No accented name becomes an unknown token")

        // 4. Pair encoding for the pair model (#525): ids from script/training/train_pair_model.py's tokenizer port.
        let a = "Erdoğan meets Sánchez in Ankara"
        let b = "Turkey's president hosts Spain's prime minister"
        let pair = tokenizer.encodePair(a, b, maxSequenceLength: 24)
        assertEqual(
            pair.inputIDs,
            [
                101, 9413, 16168, 2319, 6010, 10568, 1999, 20312, 102, 4977, 1005, 1055, 2343, 6184, 3577, 1005, 1055,
                3539, 2704, 102, 0, 0, 0, 0,
            ], "Pair ids match the training tokenizer")
        assertEqual(pair.attentionMask, Array(repeating: 1, count: 20) + Array(repeating: 0, count: 4), "Pair mask")
        assertEqual(
            pair.tokenTypeIDs,
            Array(repeating: 0, count: 9) + Array(repeating: 1, count: 11) + Array(repeating: 0, count: 4),
            "Type ids: 0 through the first [SEP], then 1")
        let truncated = tokenizer.encodePair(a, b, maxSequenceLength: 12)
        assertEqual(
            truncated.inputIDs, [101, 9413, 16168, 2319, 6010, 10568, 102, 4977, 1005, 1055, 2343, 102],
            "Longest-first truncation, the second text on ties, as in training")
    }

    // MARK: - SentenceEmbedder Inference & Normalization (#127)

    private static func testSentenceEmbedderInference() async throws {
        let embedder = SentenceEmbedder.shared
        let isAvailable = await embedder.isAvailable
        assertTrue(
            isAvailable,
            "SentenceEmbedder CoreML model and vocab must be available and loadable in bundle or Sources/Resources/Models"
        )

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
        let batchVectors = await embedder.embedBatch([textA, textB, textC]).compactMap { $0 }
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

    // MARK: - SQLite Foreign-Key CASCADE Deletion (#127)

    private static func testArticleEmbeddingsForeignKeyCascade() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test_cascade.sqlite").path
        let db = DatabaseEngine(path: dbPath)
        try await db.open()

        let art = FeedArticle(
            title: "Cascade Test Story",
            link: "https://example.com/cascade",
            guid: "cascade_guid",
            description: "Testing cascade",
            pubDate: Date(),
            source: "Test Wire",
            fullContent: "Testing foreign key cascade deletion of embeddings"
        )
        _ = try await db.upsertArticles([art])
        let dummyVec = [Float](repeating: 0.1, count: 384)
        try await db.upsertArticleEmbeddings([art.id: dummyVec], modelVersion: 1)

        // Verify stored
        let fetchedBefore = try await db.fetchArticleEmbeddings(articleIDs: [art.id], modelVersion: 1)
        assertEqual(fetchedBefore.count, 1, "Embedding exists before article deletion")

        // Delete parent article directly from SQLite with foreign keys enabled
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK, "Open DB handle for direct delete")
        defer { sqlite3_close(handle) }
        assertEqual(
            sqlite3_exec(
                handle, "PRAGMA foreign_keys = ON; DELETE FROM articles WHERE id = '\(art.id)';", nil, nil, nil),
            SQLITE_OK,
            "Delete parent article with foreign keys ON"
        )

        // Verify cascade deletion
        let fetchedAfter = try await db.fetchArticleEmbeddings(articleIDs: [art.id], modelVersion: 1)
        assertTrue(fetchedAfter.isEmpty, "Embedding must be cascade deleted when parent article is removed")
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

        // With high neural semantic similarity (0.86 >= 0.70) and shared specific anchor, semantic rescue activates:
        let rescuedAssessment = EventMatcher.assess(featA, featB, embeddingSimilarity: 0.86)
        assertTrue(
            rescuedAssessment.isMatch,
            "High neural similarity (0.86) rescues genuine paraphrase with shared specific anchor")
        assertEqual(rescuedAssessment.conflict, nil, "Rescued pair must have no factual conflict")
        // The cutoff is 0.70, chosen on the tune split (#509): the first false pairs there appear at 0.65.
        assertTrue(
            EventMatcher.assess(featA, featB, embeddingSimilarity: 0.72).isMatch, "0.72 clears the rescue cutoff")
        let belowCutoff = EventMatcher.assess(featA, featB, embeddingSimilarity: 0.66)
        assertFalse(belowCutoff.isMatch, "0.66 stays below the rescue cutoff")
        assertEqual(belowCutoff.conflict, nil, "Below the cutoff is a non-match, not a veto")

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

    // MARK: - Embedding-Aware Member Validation (#307)

    private static func testEmbeddingAwareValidationOfAssignedMembers() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test_assigned.sqlite").path
        let db = DatabaseEngine(path: dbPath)
        try await db.open()

        let now = Date()
        let art1 = FeedArticle(
            title: "Apple introduces M4 MacBook Pro with breakthrough AI performance",
            link: "https://example.com/art1",
            guid: "art1",
            description: "Apple hardware launch Cupertino",
            pubDate: now,
            source: "Tech Wire",
            fullContent: "Apple hardware launch Cupertino"
        )
        let art2 = FeedArticle(
            title: "Magnitude 7.1 earthquake strikes eastern Turkey causing tremors",
            link: "https://example.com/art2",
            guid: "art2",
            description: "Earthquake disaster in Malatya Turkey",
            pubDate: now,
            source: "Global Wire",
            fullContent: "Earthquake disaster in Malatya Turkey"
        )
        _ = try await db.upsertArticles([art1, art2])

        // Put both into an event
        let event = try await db.createEvent(memberArticleIDs: [art1.id, art2.id], at: now)

        // Run EventClusterer with embedding computation.
        // Because art1 (Apple laptop) and art2 (Turkey earthquake) are semantically divergent (cosine < 0.20),
        // the embedding-aware check detaches art2 from the event!
        _ = try await EventClusterer.run(in: db, now: now)

        let eventAfter = try await db.eventMatchMembers(eventID: event.id)
        let memberIDs = eventAfter?.members.map(\.id) ?? []
        assertFalse(
            memberIDs.contains(art2.id) && memberIDs.contains(art1.id),
            "Semantically divergent member must not remain clustered together after embedding validation"
        )
    }

    // MARK: - Compute placement (#554)

    /// `--compute-plan` (#554): where Core ML runs each shipped model. `MLComputePlan` gives every operation's preferred
    /// device and estimated cost under `.all` and `.cpuAndNeuralEngine`, per function; the report sums the cost by device
    /// and names the operations that cannot run on the Neural Engine. Then each compute unit's load time and the latency
    /// of one text, one pair and a batch.
    /// `NEWS_EMBEDDING_MODEL_PATH` and `NEWS_PAIR_MODEL_PATH` measure candidate `.mlmodelc` folders instead.
    static func reportComputePlacement() async throws {
        let environment = ProcessInfo.processInfo.environment
        let minilm = URL(
            fileURLWithPath: environment["NEWS_EMBEDDING_MODEL_PATH"] ?? "Sources/Resources/Models/minilm.mlmodelc")
        let pairscorer = URL(
            fileURLWithPath: environment["NEWS_PAIR_MODEL_PATH"] ?? "Sources/Resources/Models/pairscorer.mlmodelc")
        struct Item: Decodable { let title: String, description: String? }
        struct Fixture: Decodable { let articles: [Item] }
        let texts = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/matcher-regressions-v1.json"))
        ).articles.map { EventFeatures.matchingText(title: $0.title, description: $0.description ?? "") }
        let tokenizer = try BertWordPieceTokenizer(vocabURL: URL(fileURLWithPath: "Sources/Resources/Models/vocab.txt"))
        let lengths = texts.map { text in tokenizer.encode(text).attentionMask.filter { $0 == 1 }.count }.sorted()
        var report: [String: Any] = [
            "texts": texts.count, "tokens_median": lengths[lengths.count / 2], "tokens_max": lengths.last ?? 0,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let units: [(String, MLComputeUnits)] = [
            ("all", .all), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuAndGPU", .cpuAndGPU),
            ("cpuOnly", .cpuOnly),
        ]
        for (name, url) in [("minilm", minilm), ("pairscorer", pairscorer)] {
            for (label, unit) in units.prefix(2) {
                report["\(name)_plan_\(label)"] = try await computePlans(url, unit)
            }
        }
        let batch = (0..<2_000).map { texts[$0 % texts.count] }
        func milliseconds(since start: TimeInterval) -> Double {
            ((ProcessInfo.processInfo.systemUptime - start) * 10_000).rounded() / 10
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        // The word-piece share of one text's embedding time, the same on every compute unit.
        report["tokenize_per_text_median_ms"] = median(
            texts.map { text in
                let start = ProcessInfo.processInfo.systemUptime
                _ = tokenizer.encode(text)
                return milliseconds(since: start)
            })
        for (label, unit) in units {
            var start = ProcessInfo.processInfo.systemUptime
            let embedder = SentenceEmbedder(modelURL: minilm, computeUnits: unit)
            let load = milliseconds(since: start)
            guard await embedder.isAvailable else { throw StoryCorpus.Failure.invalid("\(minilm.path) does not load") }
            start = ProcessInfo.processInfo.systemUptime
            _ = await embedder.embed(texts[0])
            let first = milliseconds(since: start)
            var single: [Double] = []
            for text in texts {
                start = ProcessInfo.processInfo.systemUptime
                _ = await embedder.embed(text)
                single.append(milliseconds(since: start))
            }
            start = ProcessInfo.processInfo.systemUptime
            _ = await embedder.embedBatch(texts)
            let corpusBatch = milliseconds(since: start)
            start = ProcessInfo.processInfo.systemUptime
            let vectors = await embedder.embedBatch(batch)
            let largeBatch = milliseconds(since: start)
            guard vectors.allSatisfy({ $0 != nil }) else { throw StoryCorpus.Failure.invalid("A text did not embed") }
            report["minilm_\(label)"] = [
                "load_ms": load, "first_prediction_ms": first, "per_text_median_ms": median(single),
                "batch_49_ms": corpusBatch, "batch_2000_ms": largeBatch,
            ]

            let configuration = MLModelConfiguration()
            configuration.computeUnits = unit
            start = ProcessInfo.processInfo.systemUptime
            let model = try MLModel(contentsOf: pairscorer, configuration: configuration)
            let pairLoad = milliseconds(since: start)
            let providers = try zip(texts, texts.dropFirst()).map { a, b in
                let encoded = tokenizer.encodePair(a, b, maxSequenceLength: PairScorer.maxSequenceLength)
                var inputs: [String: MLFeatureValue] = [:]
                for (name, values) in [
                    ("input_ids", encoded.inputIDs), ("attention_mask", encoded.attentionMask),
                    ("token_type_ids", encoded.tokenTypeIDs),
                ] {
                    let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
                    array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
                        _ = buffer.initialize(from: values)
                    }
                    inputs[name] = MLFeatureValue(multiArray: array)
                }
                return try MLDictionaryFeatureProvider(dictionary: inputs)
            }
            // Synchronous, as `PairScorer` calls it: in an async context `prediction(from:)` picks the async overload.
            func timed(_ providers: [MLFeatureProvider]) throws -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                if providers.count == 1 {
                    _ = try model.prediction(from: providers[0])
                } else {
                    _ = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
                }
                return milliseconds(since: start)
            }
            let pairFirst = try timed([providers[0]])
            let pairs = try providers.map { try timed([$0]) }
            report["pairscorer_\(label)"] = [
                "load_ms": pairLoad, "first_prediction_ms": pairFirst, "per_pair_median_ms": median(pairs),
                "batch_\(providers.count)_ms": try timed(providers),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("COMPUTE_PLACEMENT_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("COMPUTE_PLACEMENT_JSON_END")
    }

    /// Each function's `MLComputePlan` under `units`: the cost-weighted share of each preferred device, and per operator
    /// the count that cannot run on the Neural Engine and the count the plan sends elsewhere although it could.
    private static func computePlans(_ url: URL, _ units: MLComputeUnits) async throws -> [String: Any] {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let structure = try await MLComputePlan.load(contentsOf: url, configuration: configuration).modelStructure
        guard case .program(let program) = structure else {
            throw StoryCorpus.Failure.invalid("\(url.path) is not an ML program")
        }
        var plans: [String: Any] = [:]
        for name in program.functions.keys {
            // The plan places only the function the configuration names.
            if name != "main" { configuration.functionName = name }
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            guard case .program(let program) = plan.modelStructure, let function = program.functions[name] else {
                continue
            }
            plans[name] = computePlan(plan, function)
        }
        return plans
    }

    private static func computePlan(
        _ plan: MLComputePlan, _ function: MLModelStructure.Program.Function
    ) -> [String: Any] {
        var costByDevice: [String: Double] = [:]
        var operations = 0
        var notOnNeuralEngine: [String: Int] = [:]
        var placedElsewhere: [String: Int] = [:]
        func device(_ device: MLComputeDevice) -> String {
            switch device {
            case .cpu: "cpu"
            case .gpu: "gpu"
            case .neuralEngine: "neuralEngine"
            @unknown default: "other"
            }
        }
        func walk(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                operation.blocks.forEach(walk)
                guard let usage = plan.deviceUsage(for: operation) else { continue }
                operations += 1
                let preferred = device(usage.preferred)
                costByDevice[preferred, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
                if !usage.supported.contains(where: { device($0) == "neuralEngine" }) {
                    notOnNeuralEngine[operation.operatorName, default: 0] += 1
                } else if preferred != "neuralEngine" {
                    placedElsewhere[operation.operatorName, default: 0] += 1
                }
            }
        }
        walk(function.block)
        let total = costByDevice.values.reduce(0, +)
        return [
            "operations": operations,
            "cost_share": costByDevice.mapValues { total > 0 ? ($0 / total * 10_000).rounded() / 10_000 : 0 },
            "not_supported_on_neural_engine": notOnNeuralEngine,
            "supported_but_placed_elsewhere": placedElsewhere,
        ]
    }
}
