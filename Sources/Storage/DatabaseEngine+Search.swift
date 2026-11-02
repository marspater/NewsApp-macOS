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

// MARK: - DatabaseEngine Hybrid Search (#708)

extension DatabaseEngine {
    /// Reciprocal Rank Fusion constant: a story at rank r in an arm scores 1 / (k + r) there.
    static let rrfK = 60
    /// Minimum cosine similarity for the semantic arm.
    // ponytail: uncalibrated against a real library; measure precision on the holdout before tuning.
    static let semanticSimilarityThreshold = 0.25

    /// Free text fuses the FTS5 BM25 order with the cosine order of `article_embeddings` (RRF); a query of operators
    /// only lists by date. Both arms apply the same visibility, collection, operator and mute conditions.
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
        guard !parsed.terms.isEmpty else {
            let (sql, params) = operatorSearchQuery(parsed: parsed, muting: muting, after: after, limit: limit)
            return try curateImages(
                in: executeQueryArticles(
                    sql: sql, params: params, prepareErrorMessage: "Failed to prepare operator search query"))
        }

        // Pages and counts of one search reuse its vector instead of embedding the text again.
        let text = parsed.terms.joined(separator: " ")
        if let queryEmbedding {
            searchEmbedding = (text, queryEmbedding)
        } else if searchEmbedding?.text != text, await SentenceEmbedder.shared.isAvailable {
            try Task.checkCancellation()
            let vector = await SentenceEmbedder.shared.embed(text)
            try Task.checkCancellation()
            searchEmbedding = vector.map { (text, $0) }
        }
        let (sql, params) = hybridSearchQuery(
            parsed: parsed, muting: muting, after: after, limit: limit, embedding: searchVector(for: parsed))
        return try curateImages(
            in: executeQueryArticles(sql: sql, params: params, prepareErrorMessage: "Failed to prepare search query"))
    }

    /// The stored query vector for this search's text, when it has the model's dimension.
    private func searchVector(for parsed: ArticleFilterQuery) -> [Float]? {
        guard let searchEmbedding, searchEmbedding.text == parsed.terms.joined(separator: " "),
            searchEmbedding.vector.count == SentenceEmbedder.vectorDimension
        else { return nil }
        return searchEmbedding.vector
    }

    /// The stories a search lists, as conditions on `a` for counts (#782): FTS5 matches, plus the semantic matches
    /// when the search has a query vector, under the operators.
    func searchConditions(_ parsed: ArticleFilterQuery) -> (sql: String, params: [QueryParameter]) {
        let operators = operatorConditions(parsed)
        guard !parsed.terms.isEmpty else { return operators }
        var match =
            "a.id IN (SELECT f.article_id FROM article_fts_rows f JOIN articles_fts fts ON fts.rowid = f.fts_rowid WHERE articles_fts MATCH ?)"
        var params: [QueryParameter] = [("text", Self.ftsMatchExpression(parsed))]
        if let vector = searchVector(for: parsed) {
            match +=
                " OR a.id IN (SELECT article_id FROM article_embeddings WHERE model_version = ? AND news_cosine(vector, ?) >= ?)"
            params += [
                ("int", SentenceEmbedder.modelVersion), ("blobFloats", vector),
                ("double", Self.semanticSimilarityThreshold),
            ]
        }
        return (" AND (\(match))" + operators.sql, params + operators.params)
    }

    /// FTS5 MATCH text. Every term is quoted so typed text cannot inject syntax; only unquoted words match as prefixes.
    static func ftsMatchExpression(_ parsed: ArticleFilterQuery) -> String {
        parsed.terms.enumerated().map { index, term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
                + (parsed.phraseTermIndices.contains(index) ? "" : "*")
        }
        .joined(separator: " ")
    }

    /// Collection scope and the source, category, read and saved operators, shared by every search query.
    func operatorConditions(_ parsed: ArticleFilterQuery) -> (sql: String, params: [QueryParameter]) {
        let scope = collectionScope()
        var sql = scope.sql
        var params = scope.params
        if let sf = parsed.sourceFilter {
            sql += " AND a.source LIKE ?"
            params.append(("text", "%\(sf)%"))
        }
        if let cf = parsed.categoryFilter {
            // Category tokens join words with hyphens (`category:health-&-wellness`).
            sql += " AND replace(coalesce(ae.category, a.category), ' ', '-') LIKE ?"
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
        return (sql, params)
    }

    /// Visibility, collection scope, operators and muting for one search arm, over `a`, `s` and `ae`.
    private func armConditions(_ parsed: ArticleFilterQuery, muting: MuteRules) -> (
        sql: String, params: [QueryParameter]
    ) {
        let operators = operatorConditions(parsed)
        var sql = Self.visibleArticle + operators.sql
        var params = operators.params
        if !muting.isEmpty {
            sql += " AND NOT " + Self.mutedArticle
            params += Self.mutingParameters(muting)
        }
        return (sql, params)
    }

    private static let storyJoins =
        "JOIN article_state s ON s.article_id = a.id LEFT JOIN article_enrichment ae ON ae.article_id = a.id"
    /// The columns `parseArticleRow` reads; a search adds its order value (column 18) and the snippet (19).
    private static let articleColumns = """
        a.id, a.guid, a.canonical_url, a.title, a.description, a.content, a.published_at, a.source, a.image_url,
        coalesce(ae.category, a.category), ae.summary, ae.content_fetched, s.is_read, s.is_saved, ae.key_points,
        ae.entities, ae.sentiment, a.reader_document
        """

    private func hybridSearchQuery(
        parsed: ArticleFilterQuery, muting: MuteRules, after: ArticleQueryCursor?, limit: Int, embedding: [Float]?
    ) -> (sql: String, params: [QueryParameter]) {
        let arm = armConditions(parsed, muting: muting)
        let match = Self.ftsMatchExpression(parsed)
        var params: [QueryParameter] = [("text", match)] + arm.params
        let semantic = semanticArm(embedding: embedding, conditions: arm)
        params += semantic.params
        var page = ""
        if let after {
            page = "WHERE score < ? OR (score = ? AND id > ?)"
            params += [("double", after.value), ("double", after.value), ("text", after.id)]
        }
        params += [("int", limit), ("text", match)]
        // The snippet is built for the page only, and only for lexical hits.
        let sql = """
            WITH lexical AS (
                SELECT id, ROW_NUMBER() OVER (ORDER BY bm25, id) AS rank FROM (
                    SELECT a.id, fts.rank AS bm25 FROM article_fts_rows f
                    JOIN articles_fts fts ON fts.rowid = f.fts_rowid
                    JOIN articles a ON a.id = f.article_id \(Self.storyJoins)
                    WHERE articles_fts MATCH ? AND \(arm.sql)
                )
            ),
            semantic AS (\(semantic.sql)),
            fused AS (
                SELECT id, SUM(1.0 / (\(Self.rrfK) + rank)) AS score, MAX(lexical) AS lexical FROM (
                    SELECT id, rank, 1 AS lexical FROM lexical UNION ALL SELECT id, rank, 0 FROM semantic
                ) GROUP BY id
            ),
            page AS (SELECT id, score, lexical FROM fused \(page) ORDER BY score DESC, id LIMIT ?)
            SELECT \(Self.articleColumns), page.score,
                CASE WHEN page.lexical THEN snippet(articles_fts, -1, '<b>', '</b>', '…', 15) END
            FROM page JOIN articles a ON a.id = page.id \(Self.storyJoins)
            LEFT JOIN article_fts_rows f ON page.lexical AND f.article_id = a.id
            LEFT JOIN articles_fts fts ON page.lexical AND fts.rowid = f.fts_rowid AND articles_fts MATCH ?
            ORDER BY page.score DESC, a.id
            """
        return (sql, params)
    }

    /// Every story at or above the similarity threshold, closest first; empty without a query vector, so the order is
    /// lexical alone. Uncapped, so the counts (`searchConditions`) and the pages cover the same stories.
    private func semanticArm(embedding: [Float]?, conditions arm: (sql: String, params: [QueryParameter])) -> (
        sql: String, params: [QueryParameter]
    ) {
        guard let embedding else { return ("SELECT NULL AS id, NULL AS rank WHERE 0", []) }
        let sql = """
            SELECT id, ROW_NUMBER() OVER (ORDER BY sim DESC, id) AS rank FROM (
                SELECT a.id, news_cosine(e.vector, ?) AS sim FROM article_embeddings e
                JOIN articles a ON a.id = e.article_id \(Self.storyJoins)
                WHERE e.model_version = ? AND \(arm.sql)
            ) WHERE sim >= ?
            """
        let params: [QueryParameter] = [("blobFloats", embedding), ("int", SentenceEmbedder.modelVersion)] + arm.params
        return (sql, params + [("double", Self.semanticSimilarityThreshold)])
    }

    private func operatorSearchQuery(
        parsed: ArticleFilterQuery, muting: MuteRules, after: ArticleQueryCursor?, limit: Int
    )
        -> (sql: String, params: [QueryParameter])
    {
        let arm = armConditions(parsed, muting: muting)
        var sql = """
            SELECT \(Self.articleColumns), \(Self.articleDateOrder)
            FROM articles a \(Self.storyJoins) WHERE \(arm.sql)
            """
        var params = arm.params
        if let after {
            sql += " AND (\(Self.articleDateOrder) < ? OR (\(Self.articleDateOrder) = ? AND a.id > ?))"
            params += [("double", after.value), ("double", after.value), ("text", after.id)]
        }
        sql += " ORDER BY \(Self.articleDateOrder) DESC, a.id LIMIT ?"
        params.append(("int", limit))
        return (sql, params)
    }
}
