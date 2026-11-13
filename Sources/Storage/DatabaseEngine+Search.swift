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

// Angelia · Mnemosyne (storage and search) owns this file. Register: docs/ANGELIA.md.

import Foundation

// MARK: - DatabaseEngine Hybrid Search (#708)

extension DatabaseEngine {
    /// Reciprocal Rank Fusion constant: a story at rank r in an arm scores 1 / (k + r) there.
    static let rrfK = 60
    /// Minimum cosine similarity for the semantic arm. On a 1,536-story library (3 Nov 2026) typos and nonsense peaked
    /// at 0.27–0.31 while topical matches ran 0.34–0.55, so 0.35 keeps a misspelled search empty, and its spelling
    /// suggestion offered, instead of listing unrelated stories.
    // ponytail: one library and eleven queries; re-measure on the library holdout when the embedder changes.
    static let semanticSimilarityThreshold = 0.35

    /// Free text fuses the FTS5 BM25 order with the cosine order of `article_embeddings` (RRF); a query of operators
    /// only lists by date. Both arms apply the same visibility, collection, operator and mute conditions.
    func searchArticles(
        query: String,
        limit: Int = 100,
        after: ArticleQueryCursor? = nil,
        muting: MuteRules = MuteRules(),
        queryEmbedding: [Float]? = nil,
        vectorResolved: Bool = false
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

        // The page's own vector ranks it; callers hand the same vector to the counts (`searchQueryVector`). A caller
        // that already asked for it (`vectorResolved`) keeps a nil answer, so a retry cannot rank what the counts did not.
        var vector = queryEmbedding
        if vector == nil, !vectorResolved { vector = try await searchQueryVector(for: trimmed) }
        let (sql, params) = hybridSearchQuery(
            parsed: parsed, muting: muting, after: after, limit: limit,
            embedding: Self.usableVector(vector, for: parsed))
        return try curateImages(
            in: executeQueryArticles(
                sql: sql, params: params, prepareErrorMessage: "Failed to prepare search query", orderIsDate: false))
    }

    /// The vector a free-text search ranks and counts with, or nil when it stays lexical: operators only, a quoted
    /// phrase (an entity tag, #930, asks for those exact words) or no embedder. The last text's vector is kept so
    /// paging does not embed it again; it is only a cache, so concurrent searches cannot change what a caller holds.
    /// A search passes its vector to `searchArticles`, `mutedArticleCount` and `listTotals`, so all three agree (#985).
    func searchQueryVector(for query: String) async throws -> [Float]? {
        let parsed = ArticleFilterQuery.parse(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parsed.terms.isEmpty, parsed.phraseTermIndices.isEmpty else { return nil }
        let text = parsed.terms.joined(separator: " ")
        if let searchEmbedding, searchEmbedding.text == text { return searchEmbedding.vector }
        guard await SentenceEmbedder.shared.isAvailable else { return nil }
        try Task.checkCancellation()
        let vector = await SentenceEmbedder.shared.embed(text)
        try Task.checkCancellation()
        searchEmbedding = vector.map { (text, $0) }
        return vector
    }

    /// The vector when it has the model's dimension and the search is not a quoted phrase.
    private static func usableVector(_ vector: [Float]?, for parsed: ArticleFilterQuery) -> [Float]? {
        guard parsed.phraseTermIndices.isEmpty, let vector, vector.count == SentenceEmbedder.vectorDimension
        else { return nil }
        return vector
    }

    /// The stories a search lists, as conditions on `a` for counts (#782): FTS5 matches, plus the semantic matches
    /// when the search has a query vector, under the operators.
    func searchConditions(_ parsed: ArticleFilterQuery, vector: [Float]? = nil) -> (
        sql: String, params: [QueryParameter]
    ) {
        let operators = operatorConditions(parsed)
        guard !parsed.terms.isEmpty else { return operators }
        var match =
            "a.id IN (SELECT f.article_id FROM article_fts_rows f JOIN articles_fts fts ON fts.rowid = f.fts_rowid WHERE articles_fts MATCH ?)"
        var params: [QueryParameter] = [("text", Self.ftsMatchExpression(parsed))]
        if let vector = Self.usableVector(vector, for: parsed) {
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
            // The stored source is the publisher shown on the card, worked out when the story is stored. A row stored
            // before its publisher was known still holds the feed's title, so the name is also worked out here
            // (#1311). The feed's own title ("World" for a section feed) is not stored and cannot be searched.
            sql += " AND (a.source LIKE ? OR news_publisher_name(a.canonical_url, a.source) LIKE ?)"
            params += [("text", "%\(sf)%"), ("text", "%\(sf)%")]
        }
        if let cf = parsed.categoryFilter {
            // Category tokens join words with hyphens (`category:health-&-wellness`). A reader category name also
            // matches the stored label shown under it, so the Health tag finds a story filed as "medical".
            sql += " AND (replace(coalesce(ae.category, a.category), ' ', '-') LIKE ?"
            params.append(("text", "%\(cf)%"))
            if NewsCategory.allCases.contains(where: { $0.rawValue.lowercased() == cf }) {
                sql += " OR news_category(coalesce(ae.category, a.category)) = ?"
                params.append(("text", cf))
            }
            sql += ")"
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
    /// The columns `parseArticleRow` reads; a search adds its order value (column 18), the snippet (19) and, for a ranked search, `created_at` (20).
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
        // The snippet is built for the page only, and only for lexical hits. `+rowid` keeps the page's rows out of the
        // FTS5 index lookup: a rowid constraint beside MATCH re-reads the whole doclist of a prefix term for every row
        // (16 ms for a 100-story page of a 10,000-story archive), while one MATCH scan filtered here takes about 1 ms.
        // It comes from the feed summary, else the body, whichever holds a match: a match in the headline is already
        // on the card, and one in the publisher or category name is no excerpt. Matches are wrapped in U+0002 and
        // U+0003 (`SearchExcerpt`), which publisher text cannot use as markup the way it could `<b>`.
        let sql = """
            WITH lexical AS (
                SELECT id, ROW_NUMBER() OVER (ORDER BY bm25, id) AS rank FROM (
                    SELECT a.id, fts.rank AS bm25 FROM article_fts_rows f
                    JOIN articles_fts fts ON fts.rowid = f.fts_rowid
                    JOIN articles a ON a.id = f.article_id \(Self.storyJoins)
                    WHERE articles_fts MATCH ? AND \(arm.sql)
                )
            ),
            \(semantic.sql),
            fused AS (
                SELECT id, SUM(1.0 / (\(Self.rrfK) + rank)) AS score, MAX(lexical) AS lexical FROM (
                    SELECT id, rank, 1 AS lexical FROM lexical UNION ALL SELECT id, rank, 0 FROM semantic
                ) GROUP BY id
            ),
            page AS MATERIALIZED (SELECT id, score, lexical FROM fused \(page) ORDER BY score DESC, id LIMIT ?),
            snippets AS MATERIALIZED (
                SELECT rowid AS fts_rowid,
                    snippet(articles_fts, 2, char(2), char(3), '…', 15) AS summary,
                    snippet(articles_fts, 3, char(2), char(3), '…', 15) AS body
                FROM articles_fts WHERE articles_fts MATCH ? AND +rowid IN (
                    SELECT f.fts_rowid FROM page JOIN article_fts_rows f ON f.article_id = page.id WHERE page.lexical
                )
            )
            SELECT \(Self.articleColumns), page.score,
                CASE WHEN instr(sn.summary, char(2)) > 0 THEN sn.summary WHEN instr(sn.body, char(2)) > 0 THEN sn.body END,
                a.created_at
            FROM page JOIN articles a ON a.id = page.id \(Self.storyJoins)
            LEFT JOIN article_fts_rows f ON page.lexical AND f.article_id = a.id
            LEFT JOIN snippets sn ON sn.fts_rowid = f.fts_rowid
            ORDER BY page.score DESC, a.id
            """
        return (sql, params)
    }

    /// The `semantic` CTE: every story at or above the similarity threshold, closest first; empty without a query
    /// vector, so the order is lexical alone. Uncapped, so the counts (`searchConditions`) and the pages cover the same
    /// stories. The similarities are materialized first: with the threshold and the window order on one expression,
    /// SQLite computed every cosine twice.
    private func semanticArm(embedding: [Float]?, conditions arm: (sql: String, params: [QueryParameter])) -> (
        sql: String, params: [QueryParameter]
    ) {
        guard let embedding else { return ("semantic AS (SELECT NULL AS id, NULL AS rank WHERE 0)", []) }
        let sql = """
            similarity AS MATERIALIZED (
                SELECT article_id, news_cosine(vector, ?) AS sim FROM article_embeddings WHERE model_version = ?
            ),
            semantic AS (
                SELECT id, ROW_NUMBER() OVER (ORDER BY sim DESC, id) AS rank FROM (
                    SELECT a.id, m.sim FROM similarity m JOIN articles a ON a.id = m.article_id \(Self.storyJoins)
                    WHERE m.sim >= ? AND \(arm.sql)
                )
            )
            """
        let params: [QueryParameter] = [
            ("blobFloats", embedding), ("int", SentenceEmbedder.modelVersion),
            ("double", Self.semanticSimilarityThreshold),
        ]
        return (sql, params + arm.params)
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
