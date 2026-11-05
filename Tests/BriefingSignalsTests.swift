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

import Foundation

/// Weak signals and forward watch (#851): the weak-signal gate, momentum, and the forward watch evaluation set.
/// Drives production types only (#804).
enum BriefingSignalsTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("❌ FAILURE [BriefingSignalsTests.swift:\(line)]: \(message)")
        }
    }

    static func run() async {
        print("=== Running Briefing signals (#851) tests ===")
        weakSignalGate()
        momentum()
        passageNovelty()
        momentumMACD()
        diversityMMR()
        forwardWatchEvaluation()
        forwardWatchCitations()
        forwardWatchMerge()
        if ProcessInfo.processInfo.environment["NEWS_EDITORIAL_EVALUATION"] == "1" {
            do { try await editorialEvaluation() }
            catch { check(false, "editorial evaluation failed: \(error)") }
        }
        print("Finished \(checks) Briefing signals checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }

    static let now = Date(timeIntervalSince1970: 1_793_188_800)

    static func entry(_ id: String, publishers: Int) -> FeedEntry {
        let article = FeedArticle(
            storedID: id, title: "Story \(id) headline here", link: "https://example.com/\(id)", guid: id,
            description: "", pubDate: now, source: "Outlet 0")
        guard publishers > 1 else { return .article(article) }
        let members = (0..<publishers).map {
            EventFeedMember(
                articleID: "\(id)-\($0)", source: "Outlet \($0)", title: article.title, date: now, joinedVersion: 1,
                isRead: false, isSaved: false)
        }
        return .event(
            EventFeedSummary(eventID: "e-\(id)", membershipVersion: 1, seenVersion: nil, members: members),
            representative: article, visibleMembers: [article])
    }

    static func weakSignalGate() {
        let uncited = OverviewIndustryImpact(industry: "Energy", implication: "Fuel prices may rise.")
        let cited = OverviewIndustryImpact(industry: "Shipping", implication: "Routes change.", citationIDs: ["c1"])
        check(BriefingWeakSignalsData.citedSector([uncited]) == nil, "an uncited industry impact never qualifies")
        check(BriefingWeakSignalsData.citedSector([uncited, cited]) == "Shipping", "the first cited sector qualifies")
        typealias Data = BriefingWeakSignalsData
        let low = entry("low", publishers: 2)
        check(
            Data.make(entries: [low], evidence: [low.id: Data.Evidence()], captions: [:]) == nil,
            "low coverage alone never qualifies")
        check(Data.make(entries: [low], evidence: [:], captions: [:]) == nil, "no evidence never qualifies")
        let reasons: [(Data.Evidence, String)] = [
            (Data.Evidence(isMajor: true), "Major rating"),
            (
                Data.Evidence(linkedThread: "Shipping corridor attacks widen to the gulf"),
                "Linked to shipping corridor attacks widen thread"
            ),
            (Data.Evidence(momentumRising: true), "Momentum rising"),
            (Data.Evidence(sector: "Energy"), "Industry impact: Energy"),
        ]
        for (evidence, pill) in reasons {
            let data = Data.make(entries: [low], evidence: [low.id: evidence], captions: [low.id: "2 publishers · 1 h"])
            check(data?.rows.map(\.reasons) == [[pill]], "\(pill) alone qualifies")
        }
        let wide = entry("wide", publishers: 3)
        check(
            Data.make(entries: [wide], evidence: [wide.id: Data.Evidence(isMajor: true)], captions: [:]) == nil,
            "three publishers is not low coverage")
        let many = (0..<7).map { entry("m\($0)", publishers: 1) }
        let all = Dictionary(uniqueKeysWithValues: many.map { ($0.id, Data.Evidence(isMajor: true)) })
        check(
            Data.make(entries: many, evidence: all, captions: [:])?.rows.count == many.count,
            "the data keeps every qualifying row")
    }

    static func momentum() {
        let hour: TimeInterval = 3600
        let rising = [now - hour, now - 2 * hour, now - 8 * hour]
        check(BriefingWeakSignalsData.isMomentumRising(rising, now: now), "two recent against one earlier rises")
        let flat = [now - hour, now - 8 * hour]
        check(!BriefingWeakSignalsData.isMomentumRising(flat, now: now), "equal windows do not rise")
        let falling = [now - hour, now - 7 * hour, now - 9 * hour]
        check(!BriefingWeakSignalsData.isMomentumRising(falling, now: now), "fewer recent reports do not rise")
        check(!BriefingWeakSignalsData.isMomentumRising([now - 20 * hour], now: now), "old reports do not rise")
    }

    struct Evaluation: Decodable {
        struct Item: Decodable {
            let sentence: String
            let expectedKind: String?
            let expectedDateText: String?
            enum CodingKeys: String, CodingKey {
                case sentence
                case expectedKind = "expected_kind"
                case expectedDateText = "expected_date_text"
            }
        }
        let items: [Item]
    }

    static func extract(_ sentence: String, publisher: String = "Harbor Times") -> [ForwardWatchItem] {
        let citation = OverviewCitation(
            id: "c1", articleID: "a1", passageID: "p1", passageFingerprint: "f1", quote: sentence,
            source: OverviewSourceMetadata(name: publisher, url: "https://example.com/a1", publishedAt: now))
        return ForwardWatchExtractor.extract(
            facts: [OverviewFact(id: "f1", text: sentence, citationIDs: ["c1"])], citations: ["c1": citation],
            publishedAt: now)
    }

    static func forwardWatchEvaluation() {
        let url = URL(fileURLWithPath: "Tests/Fixtures/forward-watch/forward-watch-eval-v1.json")
        guard let data = try? Data(contentsOf: url),
            let evaluation = try? JSONDecoder().decode(Evaluation.self, from: data)
        else {
            check(false, "evaluation set loads")
            return
        }
        check(evaluation.items.count >= 40, "at least 40 sentences")
        var positives = 0
        var recalled = 0
        var kindRight = 0
        var dateRight = 0
        var falsePositives = 0
        var badDates = 0
        var confusion: [String: Int] = [:]
        for item in evaluation.items {
            let found = extract(item.sentence).first
            confusion["\(item.expectedKind ?? "none") → \(found.map { "\($0.kind)" } ?? "none")", default: 0] += 1
            if let date = found?.dateText, !item.sentence.contains(date) { badDates += 1 }
            guard let expected = item.expectedKind else {
                if let found {
                    falsePositives += 1
                    print("   false positive: \(item.sentence) → \(found.kind)")
                }
                continue
            }
            positives += 1
            guard let found else {
                print("   missed: \(item.sentence)")
                continue
            }
            recalled += 1
            if "\(found.kind)" == expected {
                kindRight += 1
            } else {
                print("   wrong kind \(found.kind): \(item.sentence)")
            }
            if found.dateText == item.expectedDateText {
                dateRight += 1
            } else {
                print(
                    "   date text \(found.dateText ?? "nil"), expected \(item.expectedDateText ?? "nil"): \(item.sentence)"
                )
            }
        }
        let recall = Double(recalled) / Double(max(positives, 1))
        let accuracy = Double(kindRight) / Double(max(recalled, 1))
        print("   forward watch evaluation: \(evaluation.items.count) sentences, \(positives) positives")
        print(
            "   recall \(recalled)/\(positives), kind accuracy \(kindRight)/\(recalled), date text exact \(dateRight)/\(recalled), false positives \(falsePositives), dates not in sentence \(badDates)"
        )
        for (cell, count) in confusion.sorted(by: { $0.key < $1.key }) { print("   \(cell): \(count)") }
        check(falsePositives == 0, "no item for a sentence that states nothing ahead")
        check(dateRight == recalled, "date text exact \(dateRight)/\(recalled)")
        check(badDates == 0, "every date text is a substring of its sentence")
        check(recall >= 0.8, "recall \(recall) ≥ 0.8")
        check(accuracy >= 0.9, "kind accuracy \(accuracy) ≥ 0.9")
    }

    static func forwardWatchCitations() {
        let sentence = "The Security Council will meet on Tuesday to discuss the shipping corridor."
        check(
            ForwardWatchExtractor.extract(
                facts: [OverviewFact(id: "f", text: sentence, citationIDs: [])], citations: [:], publishedAt: now
            )
            .isEmpty, "an uncited fact yields nothing")
        let item = extract(sentence).first
        check(item?.citationID == "c1" && item?.publisher == "Harbor Times", "items carry their citation")
        let six = (0..<8).map { "Union delegation number \($0) will meet employers on Thursday for talks." }
        let citations = Dictionary(
            uniqueKeysWithValues: six.enumerated().map {
                (
                    "c\($0.offset)",
                    OverviewCitation(
                        id: "c\($0.offset)", articleID: "a", passageID: "p\($0.offset)", passageFingerprint: "f",
                        quote: $0.element)
                )
            })
        let facts = six.indices.map { OverviewFact(id: "f\($0)", text: "", citationIDs: ["c\($0)"]) }
        check(
            ForwardWatchExtractor.extract(facts: facts, citations: citations, publishedAt: now).count
                == ForwardWatchExtractor.maximumItems, "at most six items")
    }

    static func forwardWatchMerge() {
        let wire = "The Security Council will meet on Tuesday to discuss the shipping corridor."
        let twoCitations = ["c1": "Harbor Times", "c2": "Wire Service"].mapValues { _ in wire }
        let cited = Dictionary(
            uniqueKeysWithValues: [("c1", "Harbor Times"), ("c2", "Wire Service")].map { id, name in
                (
                    id,
                    OverviewCitation(
                        id: id, articleID: id, passageID: id, passageFingerprint: id, quote: twoCitations[id] ?? "",
                        source: OverviewSourceMetadata(name: name, publishedAt: now))
                )
            })
        let both = ForwardWatchExtractor.extract(
            facts: [OverviewFact(id: "f", text: wire, citationIDs: ["c1", "c2"])], citations: cited, publishedAt: now)
        let counted = BriefingForwardWatchData.make(both.map { BriefingForwardWatchData.Candidate(item: $0) })
        check(
            counted?.rows.count == 1 && counted?.rows.first?.publishers.count == 2,
            "one sentence from two citations counts both publishers")
        let opening = "The Federal Reserve's rate-setting committee will meet on "
        let split = BriefingForwardWatchData.make(
            (extract(opening + "5 November.") + extract(opening + "12 December.", publisher: "Wire Service"))
                .map { BriefingForwardWatchData.Candidate(item: $0, url: nil, entry: nil) })
        check(split?.rows.map(\.item.dateText) == ["on 5 November", "on 12 December"], "a shared opening never merges")
        check(ForwardWatchExtractor.key("A  b\nC") == ForwardWatchExtractor.key("a b c"), "whitespace and case fold")
        check(split?.hasRows(under: BriefingBoardFilter()) == true, "rows without a story pass the filter")
        let text = "The Security Council will meet on Tuesday to discuss the shipping corridor."
        let a = extract(text, publisher: "Harbor Times")
        let b = extract(text, publisher: "Wire Service")
        let conditional = extract("Port operators will close the terminal if attacks on vessels continue.")
        let data = BriefingForwardWatchData.make(
            (conditional + a + b).map { BriefingForwardWatchData.Candidate(item: $0) })
        check(data?.rows.count == 2, "same line from two publishers merges")
        check(data?.rows.first?.item.kind == .scheduled, "scheduled first")
        check(data?.rows.first?.caption == "Tuesday, as reported by 2 publishers", "merged caption")
        check(data?.rows.last?.caption == "Stated by Harbor Times, cited once", "single citation caption")
        check(BriefingForwardWatchData.make([]) == nil, "no item hides the module")
    }
    static func unitVector(_ index: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: SentenceEmbedder.vectorDimension)
        vector[index % vector.count] = 1
        return vector
    }

    static func passageNovelty() {
        let anchor = unitVector(0)
        let unrelated = unitVector(1)
        let repeated = PassageNoveltyScorer.score([
            PassageNoveltyInput(
                id: "repeated", weight: 1, embedding: anchor,
                lexicalCandidateVectors: [anchor], semanticFallbackVectors: [])
        ])
        check(repeated.disposition == .repetition, "high MaxSim with an FTS candidate is repetition")
        check(repeated.passages.first?.comparedCandidates == 1, "only the lexical candidate is compared")

        let newInformation = PassageNoveltyScorer.score([
            PassageNoveltyInput(
                id: "new", weight: 1, embedding: unrelated,
                lexicalCandidateVectors: [anchor], semanticFallbackVectors: [])
        ])
        check(
            newInformation.disposition == .potentiallyNew,
            "lexical overlap with low semantic similarity is potentially new")

        let noEvidence = PassageNoveltyScorer.score([
            PassageNoveltyInput(
                id: "unmatched", weight: 1, embedding: unrelated,
                lexicalCandidateVectors: [], semanticFallbackVectors: [])
        ])
        check(noEvidence.disposition == .unmatched, "no lexical or semantic evidence stays unmatched")
        check(noEvidence.score == nil, "unmatched evidence is not assigned a fake novelty score")

        let semanticRescue = PassageNoveltyScorer.score([
            PassageNoveltyInput(
                id: "synonym", weight: 1, embedding: anchor,
                lexicalCandidateVectors: [], semanticFallbackVectors: [anchor])
        ])
        check(semanticRescue.disposition == .repetition, "bounded semantic fallback catches a lexical miss")
        check(
            semanticRescue.passages.first?.comparedCandidates == 1,
            "semantic fallback is evaluated only when lexical retrieval is empty")

        let bounded = PassageNoveltyScorer.score([
            PassageNoveltyInput(
                id: "bounded", weight: 1, embedding: anchor,
                lexicalCandidateVectors: Array(repeating: anchor, count: 100),
                semanticFallbackVectors: Array(repeating: unrelated, count: 100))
        ])
        check(
            bounded.passages.first?.comparedCandidates == PassageNoveltyScorer.lexicalCandidateLimit,
            "lexical similarity work has a fixed candidate cap")
    }

    static func momentumMACD() {
        func report(_ id: String, _ publisher: String, minutesAgo: Double, wire: String? = nil) -> EventMomentumReport {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            return EventMomentumReport(
                id: id, publisher: publisher, independenceKey: wire,
                publishedAt: date, observedAt: now)
        }
        let burst = (0..<6).map {
            report("burst-\($0)", "Outlet \($0)", minutesAgo: Double($0 * 5))
        }
        let rising = EventMomentumMACD.assess(burst, now: now)
        check(rising.hasVolumeFloor, "a qualifying burst meets the independent-report volume floor")
        check(rising.isRising, "a concentrated independent reporting burst has positive MACD and histogram")
        check(rising.velocity > 0 && rising.momentum > 0 && rising.acceleration > 0, "MACD exposes velocity, momentum and acceleration")

        let single = EventMomentumMACD.assess([report("single", "One outlet", minutesAgo: 5)], now: now)
        check(!single.hasVolumeFloor && !single.isRising, "one article cannot create a breaking-news burst")

        let wireCopies = (0..<6).map {
            report("copy-\($0)", "Outlet \($0)", minutesAgo: Double($0 * 2), wire: "same-wire-story")
        }
        let deduplicated = EventMomentumMACD.assess(wireCopies, now: now)
        check(deduplicated.recentIndependentReports == 1, "wire copies count as one independent report")
        check(!deduplicated.hasVolumeFloor, "syndication cannot satisfy the volume floor")

        let backfill = EventMomentumReport(
            id: "backfill", publisher: "Archive Outlet", independenceKey: nil,
            publishedAt: now.addingTimeInterval(-48 * 3600), observedAt: now)
        let old = EventMomentumMACD.assess([backfill], now: now)
        check(old.recentIndependentReports == 0 && !old.hasVolumeFloor, "old backfills do not appear as a fresh burst")

        let delayedPoll = EventMomentumReport(
            id: "delayed", publisher: "Delayed Outlet", independenceKey: nil,
            publishedAt: now.addingTimeInterval(-30 * 60), observedAt: now)
        let delayed = EventMomentumMACD.assess([delayedPoll], now: now)
        check(delayed.recentIndependentReports == 1, "polling delay preserves the publisher's publication time")
    }

    static func diversityMMR() {
        let now = Date(timeIntervalSince1970: 1_793_188_800)
        let same = unitVector(0)
        let orthogonal = unitVector(1)
        let candidates = [
            EditorialMMRCandidate(id: "a", relevance: 1, embedding: same, timestamp: now),
            EditorialMMRCandidate(id: "b", relevance: 0.95, embedding: same, timestamp: now),
            EditorialMMRCandidate(id: "c", relevance: 0.8, embedding: orthogonal, timestamp: now),
        ]
        let selected = EditorialMMR.select(candidates, limit: 2, relevanceWeight: 0.5)
        check(selected.map(\.id) == ["a", "c"], "MMR avoids a near-duplicate when a relevant distinct story exists")

        let olderDuplicate = EditorialMMRCandidate(
            id: "old-b", relevance: 0.95, embedding: same, timestamp: now.addingTimeInterval(-24 * 3600))
        let decayed = EditorialMMR.temporalSimilarity(
            candidates[0], olderDuplicate, timeConstant: 12 * 3600)
        check(decayed < 0.14, "temporal redundancy decays continuously rather than at a hard cutoff")
        check(
            decayed < EditorialMMR.temporalSimilarity(candidates[0], candidates[1], timeConstant: 12 * 3600),
            "older coverage receives a smaller redundancy penalty")
        check(EditorialMMR.select(candidates, limit: 0).isEmpty, "zero selection limit returns no items")
        check(
            EditorialMMR.select(candidates, limit: 10).map(\.id)
                == EditorialMMR.select(candidates, limit: 10).map(\.id),
            "MMR is deterministic for identical inputs")
    }

    /// Opt-in, offline workload: a temporary 5,000-story SQLite archive, on-device embeddings, SQLite FTS5 + vDSP
    /// search, bounded passage MaxSim, MACD replay and MMR ranking. It never opens the user's library or makes a
    /// network request. The result is written only to NEWS_EDITORIAL_OUTPUT, supplied by the wrapper script.
    static func editorialEvaluation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("news-editorial-evaluation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = DatabaseEngine(path: root.appendingPathComponent("library.sqlite3").path)
        do {
            try await database.open()
            let now = Date()
            let topics = [
                "Grid battery storage projects connect renewable electricity to regional power networks.",
                "Semiconductor fabrication plants expand advanced chip production and wafer packaging capacity.",
                "Central bank policymakers review inflation, interest rates and household borrowing costs.",
                "European railway operators negotiate passenger schedules and infrastructure investment.",
                "Cargo shipping companies reroute vessels after security incidents in a maritime corridor.",
                "Public health researchers publish results from a clinical vaccine trial and safety review.",
                "Space agencies prepare a satellite launch and update the mission flight schedule.",
                "Cybersecurity teams investigate a software vulnerability affecting enterprise networks.",
                "Energy producers report changes in gas storage, electricity demand and export capacity.",
                "Court proceedings examine evidence, legal arguments and a scheduled judgment.",
                "Automakers announce electric vehicle production targets and battery supply agreements.",
                "Agricultural researchers measure drought conditions, crop yields and water availability.",
                "Telecommunications companies deploy fibre networks and upgrade mobile infrastructure.",
                "City councils debate public transport budgets, housing policy and local services.",
                "Technology companies release processor benchmarks and developer tooling updates.",
                "Environmental agencies monitor river levels, flood barriers and emergency response plans.",
                "Trade ministers negotiate customs rules, export controls and regional agreements.",
                "Hospitals publish capacity figures and updates to emergency care provision.",
                "Mining companies revise copper output forecasts and environmental permit applications.",
                "Universities announce astronomy observations and new scientific research findings.",
            ]
            let articles = (0..<5_000).map { index -> FeedArticle in
                let topic = topics[index / 250]
                return FeedArticle(
                    title: "Editorial benchmark report \(index)",
                    link: "https://editorial-evaluation.invalid/story/\(index)",
                    guid: "editorial-evaluation-\(index)",
                    description: "\(topic) Controlled offline fixture \(index).",
                    pubDate: now.addingTimeInterval(-Double(index % 86_400)),
                    source: "Publisher \(index % 20)")
            }

            let seedStart = ProcessInfo.processInfo.systemUptime
            try await database.upsertArticles(articles)
            let seedMilliseconds = (ProcessInfo.processInfo.systemUptime - seedStart) * 1000

            let embedder = SentenceEmbedder.shared
            guard await embedder.isAvailable else {
                throw NSError(
                    domain: "EditorialEvaluation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The bundled sentence embedding model is unavailable"])
            }
            let texts = articles.map { "\($0.title). \($0.description)" }
            let embeddingStart = ProcessInfo.processInfo.systemUptime
            let embedded = await embedder.embedBatch(texts)
            let embeddingMilliseconds = (ProcessInfo.processInfo.systemUptime - embeddingStart) * 1000
            var payload: [String: [Float]] = [:]
            payload.reserveCapacity(articles.count)
            for (article, vector) in zip(articles, embedded) {
                if let vector { payload[article.id] = vector }
            }
            guard payload.count == articles.count else {
                throw NSError(
                    domain: "EditorialEvaluation", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Only \(payload.count) of \(articles.count) articles were embedded"])
            }

            let persistenceStart = ProcessInfo.processInfo.systemUptime
            try await database.upsertArticleEmbeddings(payload, modelVersion: SentenceEmbedder.modelVersion)
            let persistenceMilliseconds = (ProcessInfo.processInfo.systemUptime - persistenceStart) * 1000
            let readStart = ProcessInfo.processInfo.systemUptime
            let stored = try await database.fetchArticleEmbeddings(
                articleIDs: articles.map(\.id), modelVersion: SentenceEmbedder.modelVersion)
            let vectorReadMilliseconds = (ProcessInfo.processInfo.systemUptime - readStart) * 1000
            guard stored.count == articles.count else {
                throw NSError(
                    domain: "EditorialEvaluation", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "SQLite returned \(stored.count) of \(articles.count) stored vectors"])
            }
            let vectors = articles.compactMap { stored[$0.id] }
            guard let queryVector = await embedder.embed(
                "grid scale battery storage renewable power generation and electricity networks")
            else {
                throw NSError(
                    domain: "EditorialEvaluation", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "The query embedding could not be generated"])
            }

            var semanticSearchSamples: [Double] = []
            var semanticSearchResultCount = 0
            for _ in 0..<7 {
                let start = ProcessInfo.processInfo.systemUptime
                let results = try await database.searchArticles(
                    query: "grid storage battery", limit: 100, queryEmbedding: queryVector)
                semanticSearchSamples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                semanticSearchResultCount = results.count
            }
            let lexicalStart = ProcessInfo.processInfo.systemUptime
            let lexicalRows = try await database.searchArticles(query: "\"grid\"", limit: 32)
            let lexicalSearchMilliseconds = (ProcessInfo.processInfo.systemUptime - lexicalStart) * 1000
            let lexicalVectors = lexicalRows.compactMap { stored[$0.id] }
            let fallbackVectors = Array(vectors.suffix(24))
            let noveltyInputs = (0..<1_000).map { index -> PassageNoveltyInput in
                let lexical = index.isMultiple(of: 3) ? [] : lexicalVectors
                return PassageNoveltyInput(
                    id: "bench-passage-\(index)", weight: 1,
                    embedding: vectors[(index * 7) % vectors.count],
                    lexicalCandidateVectors: lexical,
                    semanticFallbackVectors: fallbackVectors)
            }
            let noveltyStart = ProcessInfo.processInfo.systemUptime
            let novelty = PassageNoveltyScorer.score(noveltyInputs)
            let noveltyMilliseconds = (ProcessInfo.processInfo.systemUptime - noveltyStart) * 1000
            let noveltyComparisons = novelty.passages.reduce(0) { $0 + $1.comparedCandidates }
            let noveltyUnmatched = novelty.passages.filter { $0.disposition == .unmatched }.count

            let relevanceByTopic = (0..<20).map { 0.98 - Double($0) * 0.03 }
            let relevance = Dictionary(uniqueKeysWithValues: articles.enumerated().map { item in
                let topic = item.offset / 250
                let withinTopic = item.offset % 250
                return (item.element.id, max(0.05, relevanceByTopic[topic] - Double(withinTopic) * 0.00005))
            })
            let mmrCandidates = articles.enumerated().compactMap { item -> EditorialMMRCandidate? in
                let index = item.offset
                let article = item.element
                guard let vector = stored[article.id] else { return nil }
                return EditorialMMRCandidate(
                    id: article.id, relevance: relevance[article.id] ?? 0,
                    embedding: vector, timestamp: now.addingTimeInterval(-Double(index % 15) * 60))
            }
            let baseline = mmrCandidates.sorted {
                $0.relevance == $1.relevance ? $0.id < $1.id : $0.relevance > $1.relevance
            }.prefix(10)
            let mmrStart = ProcessInfo.processInfo.systemUptime
            let diversified = EditorialMMR.select(mmrCandidates, limit: 10)
            let mmrMilliseconds = (ProcessInfo.processInfo.systemUptime - mmrStart) * 1000

            func ndcg(_ ids: [String], cutoff: Int) -> Double {
                func dcg(_ ranked: [String]) -> Double {
                    ranked.prefix(cutoff).enumerated().reduce(0) { total, entry in
                        let gain = pow(2, relevance[entry.element] ?? 0) - 1
                        return total + gain / log2(Double(entry.offset + 2))
                    }
                }
                let actual = dcg(ids)
                let ideal = dcg(mmrCandidates.sorted {
                    $0.relevance == $1.relevance ? $0.id < $1.id : $0.relevance > $1.relevance
                }.map(\.id))
                return ideal > 0 ? actual / ideal : 0
            }
            func meanPairSimilarity(_ candidates: [EditorialMMRCandidate]) -> Double {
                guard candidates.count > 1 else { return 0 }
                var total = 0.0
                var pairs = 0
                for left in candidates.indices {
                    for right in candidates.indices where right > left {
                        guard let a = candidates[left].embedding, let b = candidates[right].embedding else { continue }
                        total += max(0, SentenceEmbedder.cosineSimilarity(a, b))
                        pairs += 1
                    }
                }
                return pairs > 0 ? total / Double(pairs) : 0
            }
            func topicCount(_ selected: [EditorialMMRCandidate]) -> Int {
                let indexes = Dictionary(uniqueKeysWithValues: articles.enumerated().map { item in (item.element.id, item.offset / 250) })
                return Set(selected.compactMap { indexes[$0.id] }).count
            }
            func publisherCount(_ selected: [EditorialMMRCandidate]) -> Int {
                let publishers = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0.publisherName) })
                return Set(selected.compactMap { publishers[$0.id] }).count
            }

            let baselineIDs = baseline.map(\.id)
            let mmrIDs = diversified.map(\.id)
            let burstReports = (0..<24).map { index in
                EventMomentumReport(
                    id: "burst-\(index)", publisher: "Publisher \(index)",
                    independenceKey: "independent-\(index)",
                    publishedAt: now.addingTimeInterval(-Double(index) * 60),
                    observedAt: now)
            }
            var momentumSamples: [Double] = []
            var momentumSignal: EventMomentumSignal?
            for _ in 0..<100 {
                let start = ProcessInfo.processInfo.systemUptime
                momentumSignal = EventMomentumMACD.assess(burstReports, now: now)
                momentumSamples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }

            let report: [String: Any] = [
                "schemaVersion": 1,
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "workload": "synthetic-offline-library",
                "libraryRows": articles.count,
                "publishers": 20,
                "embeddingModelVersion": SentenceEmbedder.modelVersion,
                "embeddingDimension": SentenceEmbedder.vectorDimension,
                "embeddedRows": payload.count,
                "storedRowsReadBack": stored.count,
                "seedSQLiteMilliseconds": seedMilliseconds,
                "coreMLEmbeddingMilliseconds": embeddingMilliseconds,
                "sqliteVectorPersistenceMilliseconds": persistenceMilliseconds,
                "sqliteVectorReadMilliseconds": vectorReadMilliseconds,
                "hybridSearchMedianMilliseconds": semanticSearchSamples.sorted()[semanticSearchSamples.count / 2],
                "hybridSearchResultCount": semanticSearchResultCount,
                "lexicalFTS5Milliseconds": lexicalSearchMilliseconds,
                "passageNoveltyWorkload": [
                    "passages": noveltyInputs.count,
                    "vDSPComparisons": noveltyComparisons,
                    "unmatched": noveltyUnmatched,
                    "elapsedMilliseconds": noveltyMilliseconds,
                    "meanNoveltyScore": novelty.score.map { $0 as Any } ?? NSNull(),
                ],
                "mmr": [
                    "candidates": mmrCandidates.count,
                    "selected": diversified.count,
                    "elapsedMilliseconds": mmrMilliseconds,
                    "baselineNDCGAt10": ndcg(baselineIDs, cutoff: 10),
                    "mmrNDCGAt10": ndcg(mmrIDs, cutoff: 10),
                    "baselineIntraListSimilarity": meanPairSimilarity(Array(baseline)),
                    "mmrIntraListSimilarity": meanPairSimilarity(diversified),
                    "baselineDistinctTopics": topicCount(Array(baseline)),
                    "mmrDistinctTopics": topicCount(diversified),
                    "baselineDistinctPublishers": publisherCount(Array(baseline)),
                    "mmrDistinctPublishers": publisherCount(diversified),
                ],
                "momentum": [
                    "replayedEvents": momentumSamples.count,
                    "reportsPerEvent": burstReports.count,
                    "medianMilliseconds": momentumSamples.sorted()[momentumSamples.count / 2],
                    "volumeFloorPassed": momentumSignal?.hasVolumeFloor ?? false,
                    "isRising": momentumSignal?.isRising ?? false,
                    "velocity": momentumSignal?.velocity ?? 0,
                    "macd": momentumSignal?.momentum ?? 0,
                    "histogram": momentumSignal?.acceleration ?? 0,
                ],
                "limitations": [
                    "Synthetic archive and embeddings; performance evidence only, not a publisher-quality holdout.",
                    "Passage benchmark exercises bounded vDSP MaxSim after the app's SQLite FTS5 retrieval; it does not create a production passage table or alter event clustering.",
                    "MMR NDCG uses synthetic topic relevance grades and must not be treated as user relevance.",
                    "The existing Briefing and notification consumers are not switched to MACD or MMR.",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let outputPath = ProcessInfo.processInfo.environment["NEWS_EDITORIAL_OUTPUT"] {
                let output = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
            } else {
                print("EDITORIAL_EVALUATION_JSON \(String(decoding: data, as: UTF8.self))")
            }
            print(
                "Editorial evaluation: \(articles.count) SQLite rows, \(payload.count) vectors, "
                    + "\(noveltyComparisons) MaxSim comparisons, MMR \(String(format: "%.2f", mmrMilliseconds)) ms")
            await database.close()
        } catch {
            await database.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }


}
