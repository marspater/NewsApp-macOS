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
import os

/// Pure Reciprocal Rank Fusion math, scoring boundaries, and deterministic tie-breaking (#708).
enum SearchRankingFusion {
    /// Standard RRF dampening constant k = 60.
    static let k: Double = 60.0

    /// Computes the reciprocal rank score component for a 1-based rank: 1.0 / (k + rank).
    static func rrfScore(rank: Int, k: Double = k) -> Double {
        guard rank >= 1 else { return 0.0 }
        return 1.0 / (k + Double(rank))
    }

    /// Single arm ranking result for an article candidate.
    struct RankedCandidate: Equatable, Sendable {
        let id: String
        let rank: Int
        let snippet: String?

        init(id: String, rank: Int, snippet: String? = nil) {
            self.id = id
            self.rank = rank
            self.snippet = snippet
        }
    }

    /// Fused search ranking outcome for an article candidate.
    struct FusedCandidate: Equatable, Sendable {
        let id: String
        let score: Double
        let snippet: String?

        init(id: String, score: Double, snippet: String? = nil) {
            self.id = id
            self.score = score
            self.snippet = snippet
        }
    }

    /// Fuses lexical and semantic rankings using Reciprocal Rank Fusion (k = 60).
    /// Pure function for mathematical verification and ranking stability tests.
    static func fuseRankings(
        lexical: [RankedCandidate],
        semantic: [RankedCandidate],
        k: Double = k
    ) -> [FusedCandidate] {
        var scores: [String: Double] = [:]
        var snippets: [String: String] = [:]

        for item in lexical {
            scores[item.id, default: 0.0] += rrfScore(rank: item.rank, k: k)
            if let snip = item.snippet {
                snippets[item.id] = snip
            }
        }

        for item in semantic {
            scores[item.id, default: 0.0] += rrfScore(rank: item.rank, k: k)
        }

        return scores.map { id, score in
            FusedCandidate(id: id, score: score, snippet: snippets[id])
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - DatabaseEngine Hybrid Search

extension DatabaseEngine {
    /// Minimum cosine similarity threshold for semantic search candidates (#708).
    /// Matches at or above this cutoff enter the semantic arm of Reciprocal Rank Fusion.
    static let semanticSimilarityThreshold: Double = 0.25

    /// Hybrid search combining SQLite FTS5 lexical ranking (BM25) with exact vector cosine similarity
    /// (`news_cosine(a, b)`) over `article_embeddings` using Reciprocal Rank Fusion (k = 60) (#708).
    func searchArticles(
        query: String,
        limit: Int = 100,
        after: ArticleQueryCursor? = nil,
        muting: MuteRules = MuteRules(),
        queryEmbedding: [Float]? = nil
    ) async throws -> [FeedArticle] {
        guard db != nil else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parsed = ArticleFilterQuery.parse(trimmed)

        // Pure operator queries (e.g. only `is:unread` or `category:...` without free text terms) stay purely lexical.
        if parsed.terms.isEmpty {
            let (sql, params) = buildPureOperatorSearchQuery(
                parsed: parsed, muting: muting, after: after, limit: limit)
            let results = try executeQueryArticles(
                sql: sql, params: params, prepareErrorMessage: "Failed to prepare operator search query")
            return try curateImages(in: results)
        }

        // Query embedding runs off @MainActor, cancellable if query text changes.
        var effectiveEmbedding = queryEmbedding
        if effectiveEmbedding == nil {
            let available = await SentenceEmbedder.shared.isAvailable
            if available {
                try Task.checkCancellation()
                let textToEmbed = parsed.terms.joined(separator: " ")
                effectiveEmbedding = await SentenceEmbedder.shared.embed(textToEmbed)
                try Task.checkCancellation()
            }
        }

        let (sql, params) = buildHybridSearchQuery(
            parsed: parsed,
            muting: muting,
            after: after,
            limit: limit,
            queryEmbedding: effectiveEmbedding
        )

        let results = try executeQueryArticles(
            sql: sql, params: params, prepareErrorMessage: "Failed to prepare hybrid search query")
        return try curateImages(in: results)
    }

    /// Common filters shared by lexical and semantic ranking arms: visibility, collection scope,
    /// filter tokens, and mute rules.
    func commonFilterConditions(
        parsed: ArticleFilterQuery,
        muting: MuteRules
    ) -> (sql: String, params: [QueryParameter]) {
        var sql = "NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)"
        var params: [QueryParameter] = []
        let scope = collectionScope()
        sql += scope.sql
        params += scope.params
        if let sf = parsed.sourceFilter {
            sql += " AND a.source LIKE ?"
            params.append(("text", "%\(sf)%"))
        }
        if let cf = parsed.categoryFilter {
            sql += " AND coalesce(ae.category, a.category) LIKE ?"
            params.append(("text", "%\(cf)%"))
        }
        if let rf = parsed.isReadFilter {
            sql += " AND s.is_read = ?"
            params.append(("int", rf ? 1 : 0))
        }
        if let sv = parsed.isSavedFilter {
            sql += " AND s.is_saved = ?"
            params.append(("int", sv ? 1 : 0))
        }
        if !muting.isEmpty {
            sql += " AND NOT " + DatabaseEngine.mutedArticle
            params += DatabaseEngine.mutingParameters(muting)
        }
        return (sql, params)
    }

    /// Builds the SQL query for hybrid search (lexical + semantic arms or lexical-only when embeddings are absent).
    private func buildHybridSearchQuery(
        parsed: ArticleFilterQuery,
        muting: MuteRules,
        after: ArticleQueryCursor?,
        limit: Int,
        queryEmbedding: [Float]?
    ) -> (sql: String, params: [QueryParameter]) {
        let hasSemantic = queryEmbedding != nil && queryEmbedding?.count == SentenceEmbedder.vectorDimension
        let (commonSQL, commonParams) = commonFilterConditions(parsed: parsed, muting: muting)
        let ftsMatch = parsed.terms.map { "\"\($0)\"*" }.joined(separator: " ")
        let candidateLimit = max(limit * 3, 250)

        var sql = "WITH lexical_arm AS (\n"
        sql += """
            SELECT id, ROW_NUMBER() OVER (ORDER BY rank, id ASC) AS rank
            FROM (
                SELECT f.article_id AS id, fts.rank
                FROM article_fts_rows f
                JOIN articles_fts fts ON fts.rowid = f.fts_rowid
                JOIN articles a ON a.id = f.article_id
                JOIN article_state s ON s.article_id = a.id
                LEFT JOIN article_enrichment ae ON ae.article_id = a.id
                WHERE articles_fts MATCH ? AND \(commonSQL)
                ORDER BY fts.rank, a.id ASC
                LIMIT \(candidateLimit)
            )
            """
        sql += "\n)"

        var params: [QueryParameter] = [("text", ftsMatch)]
        params.append(contentsOf: commonParams)

        if hasSemantic, let embedding = queryEmbedding {
            sql += ",\nsemantic_arm AS (\n"
            sql += """
                SELECT id, ROW_NUMBER() OVER (ORDER BY sim DESC, id ASC) AS rank
                FROM (
                    SELECT emb.article_id AS id, news_cosine(emb.vector, ?) AS sim
                    FROM article_embeddings emb
                    JOIN articles a ON a.id = emb.article_id
                    JOIN article_state s ON s.article_id = a.id
                    LEFT JOIN article_enrichment ae ON ae.article_id = a.id
                    WHERE emb.model_version = ? AND \(commonSQL)
                )
                WHERE sim >= ?
                ORDER BY sim DESC, id ASC
                LIMIT \(candidateLimit)
                """
            sql += "\n)"

            params.append(("blobFloats", embedding))
            params.append(("int", SentenceEmbedder.modelVersion))
            params.append(contentsOf: commonParams)
            params.append(("double", Self.semanticSimilarityThreshold))
        }

        sql += ",\nfused AS (\n"
        if hasSemantic {
            sql += """
                SELECT id,
                       SUM(1.0 / (\(SearchRankingFusion.k) + rank)) AS rrf_score,
                       MAX(is_lexical) AS is_lexical
                FROM (
                    SELECT id, rank, 1 AS is_lexical FROM lexical_arm
                    UNION ALL
                    SELECT id, rank, 0 AS is_lexical FROM semantic_arm
                )
                GROUP BY id
                """
        } else {
            sql += """
                SELECT id,
                       (1.0 / (\(SearchRankingFusion.k) + rank)) AS rrf_score,
                       1 AS is_lexical
                FROM lexical_arm
                """
        }
        sql += "\n)\n"

        sql += ",\ntop_candidates AS (\n"
        sql += "    SELECT id, rrf_score, is_lexical FROM fused\n"
        if let after {
            sql += "    WHERE (rrf_score < ? OR (rrf_score = ? AND id > ?))\n"
            params.append(("double", after.value))
            params.append(("double", after.value))
            params.append(("text", after.id))
        }
        sql += "    ORDER BY rrf_score DESC, id ASC\n"
        sql += "    LIMIT ?\n"
        sql += ")\n"
        params.append(("int", limit))

        sql += """
            SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
                   a.published_at, a.source, a.image_url, coalesce(ae.category, a.category),
                   ae.summary, ae.content_fetched,
                   s.is_read, s.is_saved,
                   ae.key_points, ae.entities, ae.sentiment, a.reader_document,
                   tc.rrf_score,
                   CASE WHEN fts.rowid IS NOT NULL THEN snippet(articles_fts, -1, '<b>', '</b>', '…', 15) ELSE NULL END AS snippet
            FROM top_candidates tc
            JOIN articles a ON a.id = tc.id
            JOIN article_state s ON s.article_id = a.id
            LEFT JOIN article_enrichment ae ON ae.article_id = a.id
            LEFT JOIN article_fts_rows f ON f.article_id = a.id AND tc.is_lexical = 1
            LEFT JOIN articles_fts fts ON fts.rowid = f.fts_rowid AND tc.is_lexical = 1 AND articles_fts MATCH ?
            ORDER BY tc.rrf_score DESC, a.id ASC
            """
        params.append(("text", ftsMatch))

        return (sql, params)
    }

    /// Pure operator search queries (without free text terms, e.g. `is:unread`, `category:...`) stay purely lexical
    /// and ordered by date (#708).
    private func buildPureOperatorSearchQuery(
        parsed: ArticleFilterQuery,
        muting: MuteRules,
        after: ArticleQueryCursor?,
        limit: Int
    ) -> (sql: String, params: [QueryParameter]) {
        var sql = """
            SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
                   a.published_at, a.source, a.image_url, coalesce(ae.category, a.category),
                   ae.summary, ae.content_fetched,
                   s.is_read, s.is_saved,
                   ae.key_points, ae.entities, ae.sentiment, a.reader_document,
                   \(Self.articleDateOrder)
            FROM articles a
            JOIN article_state s ON s.article_id = a.id
            LEFT JOIN article_enrichment ae ON ae.article_id = a.id
            """

        let (commonSQL, commonParams) = commonFilterConditions(parsed: parsed, muting: muting)
        sql += "\nWHERE " + commonSQL
        var params = commonParams

        if let after {
            sql += " AND (\(Self.articleDateOrder) < ? OR (\(Self.articleDateOrder) = ? AND a.id > ?))"
            params += [("double", after.value), ("double", after.value), ("text", after.id)]
        }
        sql += " ORDER BY \(Self.articleDateOrder) DESC, a.id ASC LIMIT ?"
        params.append(("int", limit))

        return (sql, params)
    }
}
