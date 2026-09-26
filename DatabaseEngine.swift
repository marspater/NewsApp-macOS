import Foundation
import SQLite3
import os

/// Actor-isolated SQLite persistence engine.
/// Manages connection lifecycle, WAL mode, schema versioning, FTS5 full-text indexing,
/// atomic batch transactions, and retention pruning.
actor DatabaseEngine {
    static let shared = DatabaseEngine()
    private let logger = Logger(subsystem: "com.marspater.news", category: "DatabaseEngine")
    private var db: OpaquePointer?
    private let dbPath: String
    
    // SQLITE_TRANSIENT destructor constant (-1 converted to unsafe pointer)
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    
    init(path: String? = nil) {
        if let customPath = path {
            self.dbPath = customPath
        } else {
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("com.marspater.news", isDirectory: true)
            if !fileManager.fileExists(atPath: appDir.path) {
                try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            }
            self.dbPath = appDir.appendingPathComponent("news.sqlite3").path
        }
    }
    
    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    // MARK: - Connection & Schema Setup
    
    func open() throws {
        guard db == nil else { return }
        
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard status == SQLITE_OK, let openDb = handle else {
            let errMsg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let handle = handle { sqlite3_close(handle) }
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to open database at \(dbPath): \(errMsg)"])
        }
        
        self.db = openDb
        
        // Optimize SQLite for high concurrency and safety
        try executeSimple("PRAGMA journal_mode = WAL;")
        try executeSimple("PRAGMA synchronous = NORMAL;")
        try executeSimple("PRAGMA foreign_keys = ON;")
        
        try migrateSchemaIfNeeded()
    }
    
    private func migrateSchemaIfNeeded() throws {
        let version = try getUserVersion()
        if version < 1 {
            let schema = """
            CREATE TABLE IF NOT EXISTS feeds (
                id TEXT PRIMARY KEY,
                url TEXT UNIQUE NOT NULL,
                title TEXT,
                created_at REAL NOT NULL,
                last_fetched_at REAL,
                etag TEXT,
                last_modified TEXT
            );

            CREATE TABLE IF NOT EXISTS articles (
                id TEXT PRIMARY KEY,
                guid TEXT,
                canonical_url TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                content TEXT,
                published_at REAL NOT NULL,
                source TEXT NOT NULL,
                image_url TEXT,
                category TEXT,
                feed_url TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS article_state (
                article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                is_read INTEGER NOT NULL DEFAULT 0,
                is_saved INTEGER NOT NULL DEFAULT 0,
                read_at REAL,
                saved_at REAL
            );

            CREATE TABLE IF NOT EXISTS article_enrichment (
                article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                summary TEXT,
                key_points TEXT,
                category TEXT,
                confidence REAL,
                sentiment REAL,
                entities TEXT,
                topics TEXT,
                content_fetched INTEGER NOT NULL DEFAULT 0,
                enriched_at REAL,
                model_identifier TEXT,
                analysis_version INTEGER DEFAULT 1
            );

            CREATE INDEX IF NOT EXISTS idx_articles_canonical_url ON articles(canonical_url);
            CREATE INDEX IF NOT EXISTS idx_articles_published_at ON articles(published_at DESC);
            CREATE INDEX IF NOT EXISTS idx_articles_source ON articles(source);
            CREATE INDEX IF NOT EXISTS idx_articles_category ON articles(category);
            CREATE INDEX IF NOT EXISTS idx_articles_feed_url ON articles(feed_url);

            CREATE INDEX IF NOT EXISTS idx_article_state_is_read ON article_state(is_read);
            CREATE INDEX IF NOT EXISTS idx_article_state_is_saved ON article_state(is_saved);

            CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
                article_id UNINDEXED,
                title,
                description,
                content,
                source,
                category,
                tokenize = 'porter unicode61'
            );

            CREATE TRIGGER IF NOT EXISTS trg_articles_ai AFTER INSERT ON articles BEGIN
                INSERT INTO articles_fts(article_id, title, description, content, source, category)
                VALUES (new.id, new.title, coalesce(new.description, ''), coalesce(new.content, ''), new.source, coalesce(new.category, ''));
            END;

            CREATE TRIGGER IF NOT EXISTS trg_articles_ad AFTER DELETE ON articles BEGIN
                DELETE FROM articles_fts WHERE article_id = old.id;
            END;

            CREATE TRIGGER IF NOT EXISTS trg_articles_au AFTER UPDATE ON articles BEGIN
                DELETE FROM articles_fts WHERE article_id = old.id;
                INSERT INTO articles_fts(article_id, title, description, content, source, category)
                VALUES (new.id, new.title, coalesce(new.description, ''), coalesce(new.content, ''), new.source, coalesce(new.category, ''));
            END;
            """
            try executeSimple(schema)

            // Safe column additions for existing installations
            let migrationCols = [
                "ALTER TABLE article_enrichment ADD COLUMN key_points TEXT;",
                "ALTER TABLE article_enrichment ADD COLUMN category TEXT;",
                "ALTER TABLE article_enrichment ADD COLUMN confidence REAL;",
                "ALTER TABLE article_enrichment ADD COLUMN model_identifier TEXT;",
                "ALTER TABLE article_enrichment ADD COLUMN analysis_version INTEGER DEFAULT 1;"
            ]
            for colSql in migrationCols {
                sqlite3_exec(db, colSql, nil, nil, nil)
            }

            try setUserVersion(1)
            logger.info("Database schema migrated to version 1")

        }
    }
    
    private func getUserVersion() throws -> Int {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
        }
        return 0
    }
    
    private func setUserVersion(_ version: Int) throws {
        try executeSimple("PRAGMA user_version = \(version);")
    }
    
    private func executeSimple(_ sql: String) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "SQL execution error: \(msg) in statement: \(sql)"])
        }
    }
    
    // MARK: - Transaction Control
    
    func beginTransaction() throws {
        try executeSimple("BEGIN IMMEDIATE TRANSACTION;")
    }
    
    func commitTransaction() throws {
        try executeSimple("COMMIT TRANSACTION;")
    }
    
    func rollbackTransaction() throws {
        try executeSimple("ROLLBACK TRANSACTION;")
    }
    
    // MARK: - Article Ingestion & Upsert
    
    func upsertArticles(_ articles: [FeedArticle], feedUrl: String? = nil) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !articles.isEmpty else { return }
        
        let signpostState = NewsSignposts.begin(NewsSignposts.database, name: "DatabaseBatchUpsert", metadata: "count=\(articles.count)")
        defer { NewsSignposts.end(NewsSignposts.database, name: "DatabaseBatchUpsert", state: signpostState) }

        try beginTransaction()
        defer {
            // Note: If an error is thrown, the caller can catch and rollback,
            // or the transaction will auto-rollback on error.
        }
        
        let articleSql = """
        INSERT INTO articles (
            id, guid, canonical_url, title, description, content,
            published_at, source, image_url, category, feed_url,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            description = excluded.description,
            content = coalesce(excluded.content, articles.content),
            image_url = coalesce(excluded.image_url, articles.image_url),
            category = coalesce(excluded.category, articles.category),
            updated_at = excluded.updated_at;
        """
        
        let stateSql = """
        INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
        VALUES (?, 0, 0, NULL, NULL)
        ON CONFLICT(article_id) DO NOTHING;
        """
        
        let enrichmentSql = """
        INSERT INTO article_enrichment (
            article_id, summary, sentiment, entities, topics, content_fetched, enriched_at
        ) VALUES (?, ?, NULL, NULL, NULL, ?, ?)
        ON CONFLICT(article_id) DO UPDATE SET
            summary = coalesce(excluded.summary, article_enrichment.summary),
            content_fetched = max(excluded.content_fetched, article_enrichment.content_fetched),
            enriched_at = coalesce(excluded.enriched_at, article_enrichment.enriched_at);
        """
        
        var artStmt: OpaquePointer?
        var stateStmt: OpaquePointer?
        var enrichStmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, articleSql, -1, &artStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, stateSql, -1, &stateStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, enrichmentSql, -1, &enrichStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(artStmt)
            sqlite3_finalize(stateStmt)
            sqlite3_finalize(enrichStmt)
            try rollbackTransaction()
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare batch upsert statements"])
        }
        
        defer {
            sqlite3_finalize(artStmt)
            sqlite3_finalize(stateStmt)
            sqlite3_finalize(enrichStmt)
        }
        
        let now = Date().timeIntervalSince1970
        
        for article in articles {
            let id = article.id
            let canonical = article.normalizedLink
            let pubDate = article.pubDate.timeIntervalSince1970
            
            // 1. Insert/Update Article
            sqlite3_reset(artStmt)
            sqlite3_bind_text(artStmt, 1, id, -1, Self.SQLITE_TRANSIENT)
            if let g = article.guid { sqlite3_bind_text(artStmt, 2, g, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(artStmt, 2) }
            sqlite3_bind_text(artStmt, 3, canonical, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(artStmt, 4, article.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(artStmt, 5, article.description, -1, Self.SQLITE_TRANSIENT)
            if let c = article.fullContent { sqlite3_bind_text(artStmt, 6, c, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(artStmt, 6) }
            sqlite3_bind_double(artStmt, 7, pubDate)
            sqlite3_bind_text(artStmt, 8, article.source, -1, Self.SQLITE_TRANSIENT)
            if let img = article.imageUrl { sqlite3_bind_text(artStmt, 9, img, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(artStmt, 9) }
            if let cat = article.category { sqlite3_bind_text(artStmt, 10, cat, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(artStmt, 10) }
            if let f = feedUrl { sqlite3_bind_text(artStmt, 11, f, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(artStmt, 11) }
            sqlite3_bind_double(artStmt, 12, now)
            sqlite3_bind_double(artStmt, 13, now)
            
            if sqlite3_step(artStmt) != SQLITE_DONE {
                try rollbackTransaction()
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to step article insert"])
            }
            
            // 2. Insert State (preserves existing read/saved state on conflict)
            sqlite3_reset(stateStmt)
            sqlite3_bind_text(stateStmt, 1, id, -1, Self.SQLITE_TRANSIENT)
            if sqlite3_step(stateStmt) != SQLITE_DONE {
                try rollbackTransaction()
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to step state insert"])
            }
            
            // 3. Insert Enrichment
            sqlite3_reset(enrichStmt)
            sqlite3_bind_text(enrichStmt, 1, id, -1, Self.SQLITE_TRANSIENT)
            if let s = article.aiSummary { sqlite3_bind_text(enrichStmt, 2, s, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(enrichStmt, 2) }
            sqlite3_bind_int(enrichStmt, 3, article.contentFetched ? 1 : 0)
            if article.aiSummary != nil || article.contentFetched {
                sqlite3_bind_double(enrichStmt, 4, now)
            } else {
                sqlite3_bind_null(enrichStmt, 4)
            }
            if sqlite3_step(enrichStmt) != SQLITE_DONE {
                try rollbackTransaction()
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to step enrichment insert"])
            }
        }
        
        try commitTransaction()
    }
    
    // MARK: - Article Queries
    
    func fetchArticles(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        limit: Int? = 500
    ) throws -> [FeedArticle] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        
        var query = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, a.category,
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        WHERE 1=1
        """

        
        var params: [(type: String, val: Any)] = []
        
        if let read = isRead {
            query += " AND s.is_read = ?"
            params.append(("int", read ? 1 : 0))
        }
        
        if let saved = isSaved {
            query += " AND s.is_saved = ?"
            params.append(("int", saved ? 1 : 0))
        }
        
        if let sec = section, sec != "Today" && sec != "Unread" && sec != "Saved Stories" && sec != "History" {
            query += " AND (a.category = ? OR a.title LIKE ? OR a.description LIKE ?)"
            params.append(("text", sec))
            params.append(("text", "%\(sec)%"))
            params.append(("text", "%\(sec)%"))
        }
        
        query += " ORDER BY a.published_at DESC"
        
        if let lim = limit {
            query += " LIMIT ?"
            params.append(("int", lim))
        }
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetch query: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        for (idx, p) in params.enumerated() {
            let col = Int32(idx + 1)
            if p.type == "int", let v = p.val as? Int {
                sqlite3_bind_int(stmt, col, Int32(v))
            } else if p.type == "text", let v = p.val as? String {
                sqlite3_bind_text(stmt, col, v, -1, Self.SQLITE_TRANSIENT)
            }
        }
        
        var results: [FeedArticle] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let article = parseArticleRow(stmt) {
                results.append(article)
            }
        }
        
        return results
    }
    
    // MARK: - Full Text Search (FTS5)
    
    func searchArticles(
        query: String,
        limit: Int = 100
    ) throws -> [FeedArticle] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        // Parse search operators (e.g., source:bbc, category:tech, is:read, is:unread, is:saved)
        var sourceFilter: String?
        var categoryFilter: String?
        var readFilter: Bool?
        var savedFilter: Bool?
        var cleanTerms: [String] = []
        
        let tokens = trimmed.components(separatedBy: .whitespaces)
        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("source:") {
                sourceFilter = String(token.dropFirst(7))
            } else if lower.hasPrefix("category:") {
                categoryFilter = String(token.dropFirst(9))
            } else if lower == "is:read" {
                readFilter = true
            } else if lower == "is:unread" {
                readFilter = false
            } else if lower == "is:saved" {
                savedFilter = true
            } else {
                cleanTerms.append(token)
            }
        }
        
        var sql = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, a.category,
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        """

        
        var params: [(type: String, val: Any)] = []
        
        let hasFTS = !cleanTerms.isEmpty
        if hasFTS {
            sql += " JOIN articles_fts fts ON fts.article_id = a.id WHERE articles_fts MATCH ?"
            // Sanitize FTS search term: wrap terms with quotes or escape special FTS characters
            let sanitizedFtsTerm = cleanTerms.map { term in
                let cleaned = term.replacingOccurrences(of: "\"", with: "")
                return "\"\(cleaned)*\""
            }.joined(separator: " ")
            params.append(("text", sanitizedFtsTerm))
        } else {
            sql += " WHERE 1=1"
        }
        
        if let sf = sourceFilter {
            sql += " AND a.source LIKE ?"
            params.append(("text", "%\(sf)%"))
        }
        if let cf = categoryFilter {
            sql += " AND a.category LIKE ?"
            params.append(("text", "%\(cf)%"))
        }
        if let rf = readFilter {
            sql += " AND s.is_read = ?"
            params.append(("int", rf ? 1 : 0))
        }
        if let sv = savedFilter {
            sql += " AND s.is_saved = ?"
            params.append(("int", sv ? 1 : 0))
        }
        
        if hasFTS {
            sql += " ORDER BY fts.rank LIMIT ?"
        } else {
            sql += " ORDER BY a.published_at DESC LIMIT ?"
        }
        params.append(("int", limit))
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare FTS search query: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        for (idx, p) in params.enumerated() {
            let col = Int32(idx + 1)
            if p.type == "int", let v = p.val as? Int {
                sqlite3_bind_int(stmt, col, Int32(v))
            } else if p.type == "text", let v = p.val as? String {
                sqlite3_bind_text(stmt, col, v, -1, Self.SQLITE_TRANSIENT)
            }
        }
        
        var results: [FeedArticle] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let article = parseArticleRow(stmt) {
                results.append(article)
            }
        }
        return results
    }
    
    // MARK: - State Mutations
    
    func markRead(articleId: String, isRead: Bool) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = """
        INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
        VALUES (?, ?, 0, ?, NULL)
        ON CONFLICT(article_id) DO UPDATE SET
            is_read = excluded.is_read,
            read_at = excluded.read_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare markRead statement"])
        }
        defer { sqlite3_finalize(stmt) }
        
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, isRead ? 1 : 0)
        if isRead {
            sqlite3_bind_double(stmt, 3, now)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute markRead"])
        }
    }
    
    func markReadBatch(articleIds: [String], isRead: Bool) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !articleIds.isEmpty else { return }

        let sql = """
        INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
        VALUES (?, ?, 0, ?, NULL)
        ON CONFLICT(article_id) DO UPDATE SET
            is_read = excluded.is_read,
            read_at = excluded.read_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare markReadBatch statement"])
        }
        defer { sqlite3_finalize(stmt) }

        try beginTransaction()
        var success = false
        defer { if !success { try? rollbackTransaction() } }
        let now = Date().timeIntervalSince1970
        let readInt: Int32 = isRead ? 1 : 0

        for articleId in articleIds {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, readInt)
            if isRead {
                sqlite3_bind_double(stmt, 3, now)
            } else {
                sqlite3_bind_null(stmt, 3)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute markReadBatch for id: \(articleId)"])
            }
        }
        try commitTransaction()
        success = true
    }

    func batchMarkSaved(_ articleIds: Set<String>) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !articleIds.isEmpty else { return }

        let sql = """
        INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
        VALUES (?, 0, 1, NULL, ?)
        ON CONFLICT(article_id) DO UPDATE SET
            is_saved = 1,
            saved_at = coalesce(article_state.saved_at, excluded.saved_at);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare batchMarkSaved statement"])
        }
        defer { sqlite3_finalize(stmt) }

        try beginTransaction()
        var success = false
        defer { if !success { try? rollbackTransaction() } }
        let now = Date().timeIntervalSince1970
        for articleId in articleIds {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute batchMarkSaved for \(articleId)"])
            }
        }
        try commitTransaction()
        success = true
    }
    
    func markAllRead(feedUrl: String? = nil) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let now = Date().timeIntervalSince1970
        var sql = "UPDATE article_state SET is_read = 1, read_at = ?"
        if let f = feedUrl {
            sql += " WHERE article_id IN (SELECT id FROM articles WHERE feed_url = ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, now)
                sqlite3_bind_text(stmt, 2, f, -1, Self.SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        } else {
            sql += ";"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, now)
                sqlite3_step(stmt)
            }
        }
    }
    
    func toggleSaved(articleId: String) throws -> Bool {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let current = try isSaved(articleId: articleId)
        let next = !current
        
        let sql = """
        INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
        VALUES (?, 0, ?, NULL, ?)
        ON CONFLICT(article_id) DO UPDATE SET
            is_saved = excluded.is_saved,
            saved_at = excluded.saved_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare toggleSaved statement"])
        }
        defer { sqlite3_finalize(stmt) }
        
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, next ? 1 : 0)
        if next {
            sqlite3_bind_double(stmt, 3, now)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute toggleSaved"])
        }
        return next
    }
    
    func isRead(articleId: String) throws -> Bool {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT is_read FROM article_state WHERE article_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) == 1
        }
        return false
    }
    
    func isSaved(articleId: String) throws -> Bool {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT is_saved FROM article_state WHERE article_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) == 1
        }
        return false
    }
    
    func getReadArticleIDs() throws -> Set<String> {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT article_id FROM article_state WHERE is_read = 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        
        var set = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                set.insert(String(cString: cStr))
            }
        }
        return set
    }
    
    func getSavedArticles() throws -> [FeedArticle] {
        return try fetchArticles(isSaved: true)
    }
    
    // MARK: - Enrichment Update
    
    func updateEnrichment(
        articleId: String,
        summary: String? = nil,
        category: String? = nil,
        sentiment: Double? = nil,
        entities: [String]? = nil,
        topics: [String]? = nil,
        content: String? = nil,
        image: String? = nil
    ) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        
        // 1. Update article table content, category & image if provided
        if content != nil || image != nil || category != nil {
            var updates: [String] = []
            var params: [(type: String, val: Any)] = []
            if let cat = category {
                updates.append("category = ?")
                params.append(("text", cat))
            }
            if let c = content {
                updates.append("content = ?")
                params.append(("text", c))
            }
            if let img = image {
                updates.append("image_url = coalesce(image_url, ?)")
                params.append(("text", img))
            }
            updates.append("updated_at = ?")
            params.append(("double", Date().timeIntervalSince1970))
            
            let artSql = "UPDATE articles SET \(updates.joined(separator: ", ")) WHERE id = ?;"
            var artStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, artSql, -1, &artStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(artStmt) }
                for (idx, p) in params.enumerated() {
                    let col = Int32(idx + 1)
                    if p.type == "text", let v = p.val as? String {
                        sqlite3_bind_text(artStmt, col, v, -1, Self.SQLITE_TRANSIENT)
                    } else if p.type == "double", let v = p.val as? Double {
                        sqlite3_bind_double(artStmt, col, v)
                    }
                }
                sqlite3_bind_text(artStmt, Int32(params.count + 1), articleId, -1, Self.SQLITE_TRANSIENT)
                sqlite3_step(artStmt)
            }
        }
        
        // 2. Update enrichment table
        let enrichSql = """
        INSERT INTO article_enrichment (
            article_id, summary, sentiment, entities, topics, content_fetched, enriched_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(article_id) DO UPDATE SET
            summary = coalesce(excluded.summary, article_enrichment.summary),
            sentiment = coalesce(excluded.sentiment, article_enrichment.sentiment),
            entities = coalesce(excluded.entities, article_enrichment.entities),
            topics = coalesce(excluded.topics, article_enrichment.topics),
            content_fetched = max(excluded.content_fetched, article_enrichment.content_fetched),
            enriched_at = excluded.enriched_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, enrichSql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        if let s = summary { sqlite3_bind_text(stmt, 2, s, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
        if let sent = sentiment { sqlite3_bind_double(stmt, 3, sent) } else { sqlite3_bind_null(stmt, 3) }
        if let ent = entities, let data = try? JSONEncoder().encode(ent), let str = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 4, str, -1, Self.SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 4) }
        if let top = topics, let data = try? JSONEncoder().encode(top), let str = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 5, str, -1, Self.SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_int(stmt, 6, content != nil ? 1 : 0)
        sqlite3_bind_double(stmt, 7, now)
        
        sqlite3_step(stmt)
    }

    /// Persists structured ArticleAnalysis into article_enrichment.
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        let sql = """
        INSERT INTO article_enrichment (
            article_id, summary, key_points, category, confidence, sentiment, entities, model_identifier, analysis_version, enriched_at, content_fetched
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(article_id) DO UPDATE SET
            summary = excluded.summary,
            key_points = excluded.key_points,
            category = coalesce(excluded.category, article_enrichment.category),
            confidence = coalesce(excluded.confidence, article_enrichment.confidence),
            sentiment = coalesce(excluded.sentiment, article_enrichment.sentiment),
            entities = excluded.entities,
            model_identifier = excluded.model_identifier,
            analysis_version = excluded.analysis_version,
            enriched_at = excluded.enriched_at,
            content_fetched = 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Prepare failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, analysis.summary, -1, Self.SQLITE_TRANSIENT)

        if let kpData = try? JSONEncoder().encode(analysis.keyPoints), let kpStr = String(data: kpData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 3, kpStr, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let cat = analysis.category {
            sqlite3_bind_text(stmt, 4, cat, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_bind_double(stmt, 5, 0.95)

        if let sent = analysis.sentiment?.score {
            sqlite3_bind_double(stmt, 6, sent)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        if let entData = try? JSONEncoder().encode(analysis.entities), let entStr = String(data: entData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 7, entStr, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        sqlite3_bind_text(stmt, 8, analysis.modelIdentifier, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 9, Int32(analysis.analysisVersion))
        sqlite3_bind_double(stmt, 10, now)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Step failed: \(msg)"])
        }
    }

    /// Fetches persisted ArticleAnalysis for an article (if previously analyzed).
    func fetchArticleAnalysis(for articleId: String) -> ArticleAnalysis? {
        guard let db = db else { return nil }
        let sql = """
        SELECT summary, key_points, category, sentiment, entities, model_identifier, analysis_version
        FROM article_enrichment
        WHERE article_id = ? AND summary IS NOT NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, articleId, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let summaryCStr = sqlite3_column_text(stmt, 0) else { return nil }
        let summary = String(cString: summaryCStr)

        var keyPoints: [String] = []
        if let kpCStr = sqlite3_column_text(stmt, 1) {
            let kpStr = String(cString: kpCStr)
            if let data = kpStr.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) {
                keyPoints = decoded
            }
        }

        let category: String? = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
        var sentiment: SentimentResult? = nil
        if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
            let score = sqlite3_column_double(stmt, 3)
            let label = score > 0.25 ? "Positive" : (score < -0.25 ? "Critical" : "Neutral")
            sentiment = SentimentResult(score: score, confidence: 0.9, label: label)
        }

        var entities: [EntityResult] = []
        if let entCStr = sqlite3_column_text(stmt, 4) {
            let entStr = String(cString: entCStr)
            if let data = entStr.data(using: .utf8), let decoded = try? JSONDecoder().decode([EntityResult].self, from: data) {
                entities = decoded
            }
        }

        let modelIdentifier = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? "apple.foundation-model"
        let version = Int(sqlite3_column_int(stmt, 6))

        return ArticleAnalysis(
            summary: summary,
            keyPoints: keyPoints,
            entities: entities,
            category: category,
            sentiment: sentiment,
            modelIdentifier: modelIdentifier,
            analysisVersion: max(1, version)
        )
    }

    // MARK: - Granular Cache Purging

    /// Clears all AI enrichment analysis data (summaries, key points, entities).
    /// Articles and subscriptions remain completely intact.
    func clearArticleEnrichment() throws {
        guard db != nil else { return }
        try executeSimple("DELETE FROM article_enrichment;")
        logger.info("Cleared all article enrichment data.")
    }

    /// Clears persisted article body text from local storage.
    /// Preserves subscriptions, saved stories, and read history markers.
    func clearArticleCache() throws {
        guard db != nil else { return }
        try executeSimple("""
        BEGIN TRANSACTION;
        UPDATE articles SET content = NULL WHERE id NOT IN (SELECT article_id FROM article_state WHERE is_saved = 1);
        DELETE FROM article_enrichment WHERE article_id NOT IN (SELECT article_id FROM article_state WHERE is_saved = 1);
        COMMIT;
        """)
        logger.info("Cleared non-saved article content cache.")
    }

    /// Completely purges all cached articles, state, and enrichment.
    /// Strictly preserves subscribed feed URLs and user settings.
    func clearAllDatabaseCache() throws {
        guard db != nil else { return }
        try executeSimple("""
        BEGIN TRANSACTION;
        DELETE FROM article_enrichment;
        DELETE FROM article_state WHERE is_saved = 0;
        DELETE FROM articles WHERE id NOT IN (SELECT article_id FROM article_state WHERE is_saved = 1);
        DELETE FROM articles_fts WHERE article_id NOT IN (SELECT article_id FROM article_state WHERE is_saved = 1);
        COMMIT;
        VACUUM;
        """)
        logger.info("Executed full database cache purge with VACUUM.")
    }
    
    // MARK: - Retention Policy & Pruning

    
    /// Prunes read articles older than `keepReadDays`.
    /// Never prunes unread articles or saved stories.
    @discardableResult
    func pruneOldArticles(keepReadDays: Int = 30) throws -> Int {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let cutoff = Date().timeIntervalSince1970 - Double(keepReadDays * 86400)
        
        let sql = """
        DELETE FROM articles
        WHERE id IN (
            SELECT a.id FROM articles a
            JOIN article_state s ON s.article_id = a.id
            WHERE s.is_read = 1
              AND s.is_saved = 0
              AND a.published_at < ?
        );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, cutoff)
        if sqlite3_step(stmt) == SQLITE_DONE {
            let changes = Int(sqlite3_changes(db))
            if changes > 0 {
                logger.info("Pruned \(changes) read articles older than \(keepReadDays) days")
            }
            return changes
        }
        return 0
    }
    
    // MARK: - Counts & Diagnostics
    
    func counts() throws -> (unread: Int, saved: Int, total: Int) {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        
        var total = 0
        var unread = 0
        var saved = 0
        
        var stmt: OpaquePointer?
        let sql = """
        SELECT
            count(a.id) as total_count,
            coalesce(sum(case when s.is_read = 0 then 1 else 0 end), 0) as unread_count,
            coalesce(sum(case when s.is_saved = 1 then 1 else 0 end), 0) as saved_count
        FROM articles a
        JOIN article_state s ON s.article_id = a.id;
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
                unread = Int(sqlite3_column_int(stmt, 1))
                saved = Int(sqlite3_column_int(stmt, 2))
            }
        }
        return (unread: unread, saved: saved, total: total)
    }
    
    // MARK: - Row Parser
    
    private func parseArticleRow(_ stmt: OpaquePointer?) -> FeedArticle? {
        guard let stmt = stmt else { return nil }
        
        guard let idStr = sqlite3_column_text(stmt, 0),
              let canonicalStr = sqlite3_column_text(stmt, 2),
              let titleStr = sqlite3_column_text(stmt, 3),
              let sourceStr = sqlite3_column_text(stmt, 7) else {
            return nil
        }
        
        let _ = String(cString: idStr)
        let guid: String? = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }
        let canonical = String(cString: canonicalStr)
        let title = String(cString: titleStr)
        let description = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
        let content: String? = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
        let pubDateTimestamp = sqlite3_column_double(stmt, 6)
        let source = String(cString: sourceStr)
        let imageUrl: String? = sqlite3_column_text(stmt, 8).flatMap { String(cString: $0) }
        let category: String? = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) }
        let aiSummary: String? = sqlite3_column_text(stmt, 10).flatMap { String(cString: $0) }
        let contentFetched = sqlite3_column_int(stmt, 11) == 1

        var keyPoints: [String]?
        if let kpCStr = sqlite3_column_text(stmt, 14) {
            let kpStr = String(cString: kpCStr)
            if let data = kpStr.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) {
                keyPoints = decoded
            }
        }

        var entities: [EntityResult]?
        if let entCStr = sqlite3_column_text(stmt, 15) {
            let entStr = String(cString: entCStr)
            if let data = entStr.data(using: .utf8), let decoded = try? JSONDecoder().decode([EntityResult].self, from: data) {
                entities = decoded
            }
        }

        var sentimentScore: Double?
        var sentimentLabel: String?
        if sqlite3_column_type(stmt, 16) != SQLITE_NULL {
            let score = sqlite3_column_double(stmt, 16)
            sentimentScore = score
            sentimentLabel = score > 0.25 ? "Positive" : (score < -0.25 ? "Critical" : "Neutral")
        }
        
        return FeedArticle(
            title: title,
            link: canonical,
            guid: guid,
            description: description,
            pubDate: Date(timeIntervalSince1970: pubDateTimestamp),
            source: source,
            imageUrl: imageUrl,
            aiSummary: aiSummary,
            fullContent: content,
            category: category,
            contentFetched: contentFetched,
            keyPoints: keyPoints,
            entities: entities,
            sentimentScore: sentimentScore,
            sentimentLabel: sentimentLabel
        )
    }

}
