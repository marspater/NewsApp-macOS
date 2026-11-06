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
import SQLite3

struct EditorialPassage: Sendable {
    let eventID: String
    let passage: EvidencePassage
    let publishedAt: Date
    let observedAt: Date
    let source: OverviewSourceMetadata?

    init(
        eventID: String, passage: EvidencePassage, publishedAt: Date, observedAt: Date,
        source: OverviewSourceMetadata? = nil
    ) {
        self.eventID = eventID
        self.passage = passage
        self.publishedAt = publishedAt
        self.observedAt = observedAt
        self.source = source
    }
}

struct EditorialNoveltyStamp: Sendable, Equatable {
    let inputHash: String
    let membershipHash: String
    let analysisVersion: Int
}

struct EditorialNoveltyPolicy: Sendable {
    let repeatSimilarity: Double
    let strongLexicalOverlap: Double
    let maxPassages: Int
    let maxCandidates: Int
    let maxCacheEntries: Int

    init(
        repeatSimilarity: Double, strongLexicalOverlap: Double, maxPassages: Int = 256,
        maxCandidates: Int = 32, maxCacheEntries: Int = 512
    ) {
        precondition((-1...1).contains(repeatSimilarity) && (0...1).contains(strongLexicalOverlap))
        precondition((1...1024).contains(maxPassages) && (1...64).contains(maxCandidates))
        precondition((1...4096).contains(maxCacheEntries))
        self.repeatSimilarity = repeatSimilarity
        self.strongLexicalOverlap = strongLexicalOverlap
        self.maxPassages = maxPassages
        self.maxCandidates = maxCandidates
        self.maxCacheEntries = maxCacheEntries
    }
}

struct EditorialNoveltySelection: Sendable {
    let sentence: String
    let citation: OverviewCitation
    let stamp: EditorialNoveltyStamp
    let semanticDistance: Double
}

enum EditorialNoveltyResult: Sendable {
    case lowPrioritySemanticFallback
    case deferred
    case repetition
    case noAnchoredSentence
    case novel(EditorialNoveltySelection)
}

struct EditorialNoveltyStats: Sendable {
    let cacheHits: Int
    let cacheMisses: Int
    let entries: Int
}

/// An isolated experiment: extracts cited source sentences without asserting their truth.
actor EditorialNovelty {
    typealias EmbeddingProvider = @Sendable ([String]) async -> [[Float]?]
    private let policy: EditorialNoveltyPolicy
    private let modelVersion: String
    private let embeddingProvider: EmbeddingProvider
    private let allowsEnergy: @Sendable () -> Bool
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private var generation: UInt64 = 0
    private var cacheHits = 0
    private var cacheMisses = 0
    private var analyzing = false

    init(
        policy: EditorialNoveltyPolicy, modelVersion: String,
        embeddingProvider: @escaping EmbeddingProvider,
        allowsEnergy: @escaping @Sendable () -> Bool = { IntelligencePolicy.allowsEnergy() }
    ) {
        self.policy = policy
        self.modelVersion = modelVersion
        self.embeddingProvider = embeddingProvider
        self.allowsEnergy = allowsEnergy
    }

    func stats() -> EditorialNoveltyStats {
        .init(cacheHits: cacheHits, cacheMisses: cacheMisses, entries: cache.count)
    }

    func clearCache() {
        generation &+= 1
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func analyze(
        candidate: EditorialPassage, baseline: [EditorialPassage], coreEntities: [String],
        stamp: EditorialNoveltyStamp
    ) async throws -> EditorialNoveltyResult {
        try Task.checkCancellation()
        guard !analyzing else { return .deferred }
        analyzing = true
        defer { analyzing = false }
        guard candidate.passage.text.utf8.count <= 65_536, baseline.count <= 4096,
            candidate.publishedAt <= candidate.observedAt,
            coreEntities.count <= 64, coreEntities.allSatisfy({ $0.utf8.count <= 1024 })
        else { return .deferred }
        let eligible = historicalBaseline(baseline, candidate: candidate)
        let index = try EditorialPassageIndex(passages: Array(eligible))
        let matches = try index.matches(candidate.passage.text, limit: policy.maxCandidates)
        guard !matches.isEmpty else { return .lowPrioritySemanticFallback }
        let sentences = PassageFactExtractor.segmentedSentences(in: candidate.passage.text)
            .map { String(candidate.passage.text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.hasAnchor($0, entities: coreEntities) }
            .prefix(policy.maxCandidates)
        guard !sentences.isEmpty else { return .noAnchoredSentence }
        let texts = Array(sentences) + matches.map { $0.passage.text }
        guard allowsEnergy() else { return .deferred }
        let capturedGeneration = generation
        guard let vectors = try await embeddings(texts, generation: capturedGeneration) else {
            return .deferred
        }
        try Task.checkCancellation()
        guard generation == capturedGeneration, allowsEnergy() else { return .deferred }
        guard
            let (sentence, distance) = selectSentence(
                Array(sentences), matches: matches, vectors: vectors)
        else {
            return .repetition
        }
        return selection(candidate: candidate, sentence: sentence, distance: distance, stamp: stamp)
    }

    /// Preserve the source passage and its citation when returning a selected sentence.
    private func selection(
        candidate: EditorialPassage, sentence: String, distance: Double, stamp: EditorialNoveltyStamp
    ) -> EditorialNoveltyResult {
        let passage = candidate.passage
        var source = candidate.source ?? OverviewSourceMetadata()
        if source.publishedAt == nil { source.publishedAt = candidate.publishedAt }
        let citation = OverviewCitation(
            id: ArticleIdentity.sha256Hex(passage.id + "\n" + sentence), articleID: passage.articleID,
            passageID: passage.id, passageFingerprint: passage.fingerprint, quote: sentence,
            source: source
        )
        return .novel(
            .init(sentence: sentence, citation: citation, stamp: stamp, semanticDistance: distance))
    }

    /// Keep only bounded, already observed evidence from this event, newest publication first.
    private func historicalBaseline(_ baseline: [EditorialPassage], candidate: EditorialPassage)
        -> [EditorialPassage]
    {
        Array(
            baseline.filter {
                $0.eventID == candidate.eventID && $0.passage.articleID != candidate.passage.articleID
                    && $0.passage.id != candidate.passage.id && $0.publishedAt <= candidate.publishedAt
                    && $0.publishedAt <= $0.observedAt
                    && $0.observedAt <= candidate.observedAt && $0.passage.text.utf8.count <= 65_536
            }.sorted {
                if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
                return $0.passage.id < $1.passage.id
            }.prefix(policy.maxPassages))
    }

    /// Choose the most distant anchored sentence that does not satisfy the repetition rule.
    private func selectSentence(
        _ sentences: [String], matches: [EditorialPassage], vectors: [[Float]]
    ) -> (String, Double)? {
        let baselineVectors = Array(vectors.dropFirst(sentences.count))
        var best: (String, Double)?
        for (offset, sentence) in sentences.enumerated() {
            let similarities = baselineVectors.map {
                SentenceEmbedder.cosineSimilarity(vectors[offset], $0)
            }
            let maximum = similarities.max() ?? 1
            let repeated = zip(matches, similarities).contains {
                $0.1 >= policy.repeatSimilarity
                    && Self.lexicalOverlap(sentence, $0.0.passage.text) >= policy.strongLexicalOverlap
            }
            if repeated { continue }
            let distance = 1 - min(1, max(-1, maximum))
            if best == nil || distance > best!.1 { best = (sentence, distance) }
        }
        return best
    }

    private func embeddings(_ texts: [String], generation captured: UInt64) async throws -> [[Float]]? {
        let keys = texts.map {
            ArticleIdentity.sha256Hex("editorial-normalized-v1\n" + modelVersion + "\n" + $0)
        }
        var seen = Set<String>()
        let missing = texts.indices.filter { cache[keys[$0]] == nil && seen.insert(keys[$0]).inserted }
        // Hits count requested positions already cached; misses count unique uncached text keys.
        cacheMisses += missing.count
        cacheHits += keys.filter { cache[$0] != nil }.count
        var resolved = cache
        if !missing.isEmpty {
            try Task.checkCancellation()
            guard allowsEnergy() else { return nil }
            let values = await embeddingProvider(missing.map { texts[$0] })
            try Task.checkCancellation()
            guard generation == captured, allowsEnergy(), values.count == missing.count else {
                return nil
            }
            for (index, value) in zip(missing, values) {
                guard let value, value.count == 384, value.allSatisfy(\.isFinite) else { return nil }
                let norm = sqrt(value.reduce(0.0) { $0 + Double($1) * Double($1) })
                guard norm.isFinite, norm > 0 else { return nil }
                let normalized = value.map { Float(Double($0) / norm) }
                resolved[keys[index]] = normalized
                if cache[keys[index]] == nil { cacheOrder.append(keys[index]) }
                cache[keys[index]] = normalized
                while cacheOrder.count > policy.maxCacheEntries {
                    cache.removeValue(forKey: cacheOrder.removeFirst())
                }
            }
        }
        return keys.compactMap { resolved[$0] }.count == keys.count
            ? keys.compactMap { resolved[$0] } : nil
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func hasAnchor(_ sentence: String, entities: [String]) -> Bool {
        let sentenceWords = words(sentence)
        return entities.contains { entity in
            let anchor = words(entity)
            guard !anchor.isEmpty, anchor.count <= sentenceWords.count else { return false }
            return (0...(sentenceWords.count - anchor.count)).contains {
                Array(sentenceWords[$0..<($0 + anchor.count)]) == anchor
            }
        }
    }

    private static func lexicalOverlap(_ sentence: String, _ passage: String) -> Double {
        let sentenceWords = Set(words(sentence))
        guard !sentenceWords.isEmpty else { return 0 }
        return Double(sentenceWords.intersection(Set(words(passage))).count)
            / Double(sentenceWords.count)
    }
}

/// The SQLite connection never leaves the owning analysis actor's synchronous scope.
private final class EditorialPassageIndex {
    private var database: OpaquePointer?
    private let passages: [EditorialPassage]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(passages: [EditorialPassage]) throws {
        self.passages = passages
        guard sqlite3_open(":memory:", &database) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw IndexError.sqlite
        }
        do {
            guard
                sqlite3_exec(
                    database, "CREATE VIRTUAL TABLE passages USING fts5(text, tokenize='porter unicode61')",
                    nil, nil,
                    nil) == SQLITE_OK
            else {
                throw IndexError.sqlite
            }
            for (offset, passage) in passages.enumerated() {
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        database, "INSERT INTO passages(rowid,text) VALUES(?,?)", -1, &statement, nil)
                        == SQLITE_OK
                else { throw IndexError.sqlite }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, Int64(offset + 1))
                sqlite3_bind_text(statement, 2, passage.passage.text, -1, Self.transient)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.sqlite }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func matches(_ text: String, limit: Int) throws -> [EditorialPassage] {
        let terms = Array(
            Set(
                text.lowercased().components(separatedBy: .alphanumerics.inverted)
                    .filter { !$0.isEmpty }.prefix(64))
        ).sorted()
        guard !terms.isEmpty else { return [] }
        let query = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(
            separator: " OR ")
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT rowid FROM passages WHERE passages MATCH ? ORDER BY bm25(passages),rowid LIMIT ?",
                -1,
                &statement, nil) == SQLITE_OK
        else { throw IndexError.sqlite }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, query, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var result: [EditorialPassage] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw IndexError.sqlite }
            result.append(passages[Int(sqlite3_column_int64(statement, 0)) - 1])
        }
        return result
    }

    private enum IndexError: Error { case sqlite }
}
