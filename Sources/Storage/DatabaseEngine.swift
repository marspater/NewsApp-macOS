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
    
    // sqliteTransient destructor constant (-1 converted to unsafe pointer)
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    
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
        
        do {
            // Optimize SQLite for high concurrency and safety
            try executeSimple("PRAGMA journal_mode = WAL;")
            try executeSimple("PRAGMA synchronous = NORMAL;")
            try executeSimple("PRAGMA foreign_keys = ON;")

            try migrateSchemaIfNeeded()
        } catch {
            sqlite3_close(openDb)
            self.db = nil
            throw error
        }

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

            try setUserVersion(1)
            logger.info("Database schema migrated to version 1")

        }
        if version < 2 {
            try beginTransaction()
            do {
                try executeSimple("ALTER TABLE articles ADD COLUMN reader_document TEXT;")
                try setUserVersion(2)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 3 {
            try beginTransaction()
            do {
                try executeSimple("""
                CREATE TABLE article_feeds (
                    article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                    feed_url TEXT NOT NULL,
                    PRIMARY KEY (article_id, feed_url)
                );
                CREATE INDEX idx_article_feeds_url ON article_feeds(feed_url, article_id);
                INSERT INTO article_feeds SELECT id, feed_url FROM articles WHERE feed_url IS NOT NULL;
                """)
                try setUserVersion(3)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 4 {
            try beginTransaction()
            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "PRAGMA table_info(article_enrichment);", -1, &statement, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot inspect enrichment schema"])
                }
                var columns = Set<String>()
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
                    status = sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
                guard status == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read enrichment schema"])
                }
                for (name, definition) in [
                    ("key_points", "TEXT"), ("category", "TEXT"), ("confidence", "REAL"),
                    ("model_identifier", "TEXT"), ("analysis_version", "INTEGER DEFAULT 1")
                ] where !columns.contains(name) {
                    try executeSimple("ALTER TABLE article_enrichment ADD COLUMN \(name) \(definition);")
                }
                try setUserVersion(4)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 5 {
            try beginTransaction()
            do {
                try executeSimple("""
                CREATE TABLE article_aliases (
                    kind TEXT NOT NULL CHECK(kind IN ('id', 'url')),
                    value TEXT NOT NULL,
                    article_id TEXT REFERENCES articles(id) ON DELETE CASCADE,
                    PRIMARY KEY(kind, value)
                );
                CREATE INDEX idx_article_aliases_article ON article_aliases(article_id);
                """)
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT id, canonical_url FROM articles;", -1, &statement, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare alias migration"])
                }
                defer { sqlite3_finalize(statement) }
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    let id = String(cString: sqlite3_column_text(statement, 0))
                    let url = String(cString: sqlite3_column_text(statement, 1))
                    try recordAlias(kind: "id", value: id, articleID: id)
                    if Self.isDocumentURL(url) {
                        try recordAlias(kind: "url", value: url, articleID: id)
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read alias migration rows"])
                }
                try setUserVersion(5)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 6 {
            try beginTransaction()
            do {
                // Multiple-feed histories do not record which feed supplied each GUID.
                // Seed only a current GUID that still matches its original key and
                // has one feed; URL aliases preserve less certain histories.
                var statement: OpaquePointer?
                let sql = """
                SELECT a.id, a.guid, min(af.feed_url)
                FROM articles a JOIN article_feeds af ON af.article_id = a.id
                WHERE a.guid IS NOT NULL
                GROUP BY a.id HAVING count(*) = 1;
                """
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare scoped GUID migration"])
                }
                defer { sqlite3_finalize(statement) }
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    let id = String(cString: sqlite3_column_text(statement, 0))
                    let guid = String(cString: sqlite3_column_text(statement, 1))
                    let feed = String(cString: sqlite3_column_text(statement, 2))
                    if id == ArticleIdentity.computeId(guid: guid, link: ""),
                       let scoped = ArticleIdentity.scopedGUID(guid, feedURL: feed) {
                        try recordAlias(kind: "id", value: scoped, articleID: id)
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read scoped GUID migration rows"])
                }
                try setUserVersion(6)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 7 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple("""
                ALTER TABLE article_aliases RENAME TO article_aliases_v6;
                CREATE TABLE article_aliases (
                    kind TEXT NOT NULL CHECK(kind IN ('id', 'url', 'content')),
                    value TEXT NOT NULL,
                    article_id TEXT REFERENCES articles(id) ON DELETE CASCADE,
                    PRIMARY KEY(kind, value)
                );
                INSERT INTO article_aliases SELECT kind, value, article_id FROM article_aliases_v6;
                DROP TABLE article_aliases_v6;
                CREATE INDEX idx_article_aliases_article ON article_aliases(article_id);
                """)
                // Index historical evidence without merging or rewriting any row.
                var statement: OpaquePointer?
                let sql = "SELECT id, canonical_url, title, description, content, published_at, source FROM articles;"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher text migration"])
                }
                defer { sqlite3_finalize(statement) }
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    func text(_ column: Int32) -> String {
                        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                    }
                    let article = FeedArticle(title: text(2), link: text(1), guid: nil,
                        description: text(3), pubDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                        source: text(6), fullContent: text(4))
                    for fingerprint in ArticleIdentity.publisherTextFingerprints(article) {
                        try recordAlias(kind: "content", value: fingerprint, articleID: text(0))
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read publisher text migration"])
                }
                try Task.checkCancellation()
                try setUserVersion(7)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 8 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple("""
                CREATE TABLE IF NOT EXISTS event_overviews (
                    id TEXT PRIMARY KEY,
                    event_id TEXT NOT NULL UNIQUE,
                    membership_version INTEGER NOT NULL,
                    input_text_hash TEXT NOT NULL,
                    schema_version INTEGER NOT NULL,
                    analysis_version INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    facts_json TEXT NOT NULL,
                    lead_image_json TEXT,
                    member_article_ids_json TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_event_overviews_event_id ON event_overviews(event_id);

                CREATE TABLE IF NOT EXISTS event_overview_citations (
                    id TEXT PRIMARY KEY,
                    overview_id TEXT NOT NULL REFERENCES event_overviews(id) ON DELETE CASCADE,
                    article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE RESTRICT,
                    passage_id TEXT NOT NULL,
                    passage_fingerprint TEXT NOT NULL,
                    quote TEXT NOT NULL,
                    source_title TEXT,
                    source_name TEXT,
                    source_url TEXT,
                    published_at REAL
                );
                CREATE INDEX IF NOT EXISTS idx_event_overview_citations_overview_id ON event_overview_citations(overview_id);
                CREATE INDEX IF NOT EXISTS idx_event_overview_citations_article_id ON event_overview_citations(article_id);
                """)
                try setUserVersion(8)
                try commitTransaction()
                logger.info("Database schema migrated to version 8 (event overviews and citations)")
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 9 {
            try beginTransaction()
            do {
                try executeSimple("""
                CREATE TABLE article_reconciliations (
                    duplicate_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    survivor_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                    canonical_url TEXT NOT NULL, fingerprint TEXT NOT NULL
                );
                CREATE INDEX idx_article_reconciliation_survivor ON article_reconciliations(survivor_id);
                CREATE INDEX idx_article_reconciliation_evidence ON article_reconciliations(canonical_url, fingerprint);
                CREATE TABLE article_reconciliation_history (
                    article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    is_read INTEGER NOT NULL, is_saved INTEGER NOT NULL,
                    read_at REAL, saved_at REAL
                );
                """)
                try reconcileHistoricalArticles()
                try Task.checkCancellation()
                try setUserVersion(9)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }
    
    private func executeBound(_ sql: String, _ values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare reconciliation statement"])
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot execute reconciliation statement"])
        }
    }

    private func reconcileHistoricalArticles() throws {
        var statement: OpaquePointer?
        let sql = """
        SELECT id, canonical_url, title, description, content, published_at, source
        FROM articles JOIN article_state ON article_state.article_id = articles.id
        ORDER BY canonical_url, reader_document IS NOT NULL DESC,
            length(content) DESC, created_at, id;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare historical reconciliation"])
        }
        defer { sqlite3_finalize(statement) }
        var currentURL = ""
        var survivors = [String: String]()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let id = text(0), url = text(1)
            if url != currentURL { survivors.removeAll(keepingCapacity: true); currentURL = url }
            if Self.isDocumentURL(url) {
                let body = text(4)
                let article = FeedArticle(title: text(2), link: url, guid: nil,
                    description: text(3),
                    pubDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    source: text(6), fullContent: body.isEmpty ? nil : body)
                if let fingerprint = Self.historicalFingerprint(article) {
                    if let survivor = survivors[fingerprint] {
                        try reconcileHistoricalArticle(id, into: survivor, url: url, fingerprint: fingerprint)
                    } else if survivors.count < 1000 {
                        // ponytail: bounded candidates per exact URL; oversized ambiguous
                        // groups remain separate until corpus evidence justifies more work.
                        survivors[fingerprint] = id
                    }
                }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read historical articles"])
        }
    }

    private func reconcileHistoricalArticle(_ duplicate: String, into survivor: String, url: String, fingerprint: String) throws {
        try executeBound("INSERT OR IGNORE INTO article_reconciliation_history SELECT * FROM article_state WHERE article_id IN (?, ?);", [duplicate, survivor])
        try executeBound("""
        UPDATE article_state SET (is_read, is_saved, read_at, saved_at) =
            (SELECT max(is_read), max(is_saved), max(read_at), max(saved_at)
             FROM article_state WHERE article_id IN (?, ?)) WHERE article_id = ?;
        """, [duplicate, survivor, survivor])
        try executeBound("INSERT OR IGNORE INTO article_feeds SELECT ?, feed_url FROM article_feeds WHERE article_id = ?;", [survivor, duplicate])
        try executeBound("INSERT INTO article_reconciliations VALUES (?, ?, ?, ?);", [duplicate, survivor, url, fingerprint])
        try executeBound("UPDATE article_aliases SET article_id = ? WHERE article_id = ?;", [survivor, duplicate])
        try executeBound("""
        INSERT INTO article_aliases(kind, value, article_id) VALUES ('id', ?, ?)
        ON CONFLICT(kind, value) DO UPDATE SET article_id = excluded.article_id;
        """, [duplicate, survivor])
        // Keep URL/content ambiguity tombstones: reconciliation does not infer
        // ownership of conflicting or previously removed alias targets.
    }

    private static func historicalFingerprint(_ article: FeedArticle) -> String? {
        // A present body must qualify itself; its teaser cannot override different prose.
        let body = article.fullContent ?? ""
        let evidence = FeedArticle(title: article.title, link: article.link, guid: nil,
            description: body.isEmpty ? article.description : "", pubDate: article.pubDate,
            source: article.source, fullContent: body.isEmpty ? nil : body)
        return ArticleIdentity.publisherTextFingerprints(evidence).first
    }

    private func historicalTarget(_ article: FeedArticle) throws -> String? {
        guard let fingerprint = Self.historicalFingerprint(article) else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT DISTINCT survivor_id FROM article_reconciliations WHERE canonical_url = ? AND fingerprint = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare historical identity lookup"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, article.normalizedLink, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, fingerprint, -1, Self.sqliteTransient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read historical identity"])
        }
        let target = String(cString: sqlite3_column_text(statement, 0))
        let next = sqlite3_step(statement)
        guard next == SQLITE_ROW || next == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(next), userInfo: [NSLocalizedDescriptionKey: "Cannot finish historical identity lookup"])
        }
        return next == SQLITE_DONE ? target : nil
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
    
    // Root URLs are not document identifiers: feeds can link every item to a homepage.
    private static func isDocumentURL(_ value: String) -> Bool {
        let components = URLComponents(string: value)
        return components?.host?.isEmpty == false
            && components?.user == nil && components?.password == nil
            && ["http", "https"].contains(components?.scheme?.lowercased() ?? "")
            && (!(components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
                || !(components?.query ?? "").isEmpty)
    }

    /// A NULL target permanently records ambiguity instead of choosing a document.
    private func recordAlias(kind: String, value: String, articleID: String) throws {
        let sql = """
        INSERT INTO article_aliases(kind, value, article_id) VALUES (?, ?, ?)
        ON CONFLICT(kind, value) DO UPDATE SET article_id =
            CASE WHEN article_aliases.article_id = excluded.article_id
                 THEN article_aliases.article_id ELSE NULL END;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare article alias"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 3, articleID, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot persist article alias"])
        }
    }

    private func aliasTarget(kind: String, value: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT article_id FROM article_aliases WHERE kind = ? AND value = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare alias lookup"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, Self.sqliteTransient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        case SQLITE_DONE:
            return nil
        default:
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot read article alias"])
        }
    }

    func resolvedArticleID(_ id: String) throws -> String {
        try aliasTarget(kind: "id", value: id) ?? id
    }

    /// Keep observed identities across serial URL/GUID changes without rewriting keys.
    func resolvedArticleID(for article: FeedArticle, feedURL: String? = nil) throws -> String {
        let scoped = ArticleIdentity.scopedGUID(article.guid, feedURL: feedURL ?? article.identityFeedURL)
        let lookupID = article.storedID ?? scoped ?? article.id
        let idTarget = try aliasTarget(kind: "id", value: lookupID)
        let urlTarget = Self.isDocumentURL(article.normalizedLink)
            ? try aliasTarget(kind: "url", value: article.normalizedLink) : nil
        if let idTarget, let urlTarget, idTarget != urlTarget {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Conflicting article identity signals"])
        }
        if let target = idTarget ?? urlTarget { return target }
        if let target = try publisherTextTarget(article) { return target }
        if let target = try historicalTarget(article) { return target }
        // Direct legacy callers may still supply an unscoped model. Keep that key
        // only if unused; a GUID already owned by another feed needs its scoped key.
        if let scoped, article.storedID == nil,
           try aliasTarget(kind: "id", value: article.id) != nil { return scoped }
        return article.id
    }

    /// Validated evidence extends one existing document; it never merges stored rows.
    func recordDocumentIdentity(_ evidence: DocumentIdentityEvidence, articleID: String) throws {
        let id = try resolvedArticleID(articleID)
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }
        guard try aliasTarget(kind: "url", value: evidence.requestedURL) == id else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Document evidence does not belong to the requested article"])
        }
        for url in evidence.urls {
            try Task.checkCancellation()
            if Self.isDocumentURL(url) { try recordAlias(kind: "url", value: url, articleID: id) }
        }
        try commitTransaction()
    }

    private func publisherTextTarget(_ article: FeedArticle) throws -> String? {
        let fingerprints = ArticleIdentity.publisherTextFingerprints(article)
        guard !fingerprints.isEmpty else { return nil }
        let placeholders = fingerprints.map { _ in "?" }.joined(separator: ",")
        var statement: OpaquePointer?
        let sql = "SELECT article_id FROM article_aliases WHERE kind = 'content' AND value IN (\(placeholders));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher text lookup"])
        }
        defer { sqlite3_finalize(statement) }
        for (index, fingerprint) in fingerprints.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), fingerprint, -1, Self.sqliteTransient)
        }
        var targets = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { return nil }
            targets.insert(String(cString: value))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot read publisher text lookup"])
        }
        return targets.count == 1 ? targets.first : nil
    }

    /// `validators` are written in the same transaction as the articles, so a feed is only ever
    /// answered "not modified" for content that was durably ingested.
    @discardableResult
    func upsertArticles(_ articles: [FeedArticle], feedUrl: String? = nil, validators: FeedValidators? = nil) throws -> Set<String> {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !articles.isEmpty else { return [] }
        
        let signpostState = NewsSignposts.begin(NewsSignposts.database, name: "DatabaseBatchUpsert", metadata: "count=\(articles.count)")
        defer { NewsSignposts.end(NewsSignposts.database, name: "DatabaseBatchUpsert", state: signpostState) }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }
        
        let articleSql = """
        INSERT INTO articles (
            id, guid, canonical_url, title, description, content,
            published_at, source, image_url, category, feed_url,
            created_at, updated_at, reader_document
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            guid = coalesce(excluded.guid, articles.guid),
            canonical_url = CASE WHEN ?
                THEN excluded.canonical_url ELSE articles.canonical_url END,
            published_at = CASE WHEN excluded.published_at = ? THEN articles.published_at ELSE excluded.published_at END,
            title = excluded.title,
            source = excluded.source,
            description = excluded.description,
            content = CASE WHEN articles.reader_document IS NOT NULL AND excluded.reader_document IS NULL
                THEN articles.content ELSE coalesce(excluded.content, articles.content) END,
            reader_document = coalesce(excluded.reader_document, articles.reader_document),
            image_url = coalesce(excluded.image_url, articles.image_url),
            category = coalesce(excluded.category, articles.category),
            feed_url = coalesce(articles.feed_url, excluded.feed_url),
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
        var feedStmt: OpaquePointer?
        
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
        
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO article_feeds(article_id, feed_url) VALUES (?, ?);", -1, &feedStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed association"])
        }
        defer { sqlite3_finalize(feedStmt) }
        var existenceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM articles WHERE id = ?;", -1, &existenceStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare article existence query"])
        }
        defer { sqlite3_finalize(existenceStmt) }
        var insertedIDs = Set<String>()
        let now = Date().timeIntervalSince1970

        for article in articles {
            try Task.checkCancellation()
            let identityFeedURL = feedUrl ?? article.identityFeedURL
            let id = try resolvedArticleID(for: article, feedURL: identityFeedURL)
            let url = URL(string: article.normalizedLink)
            let validLink = url?.host?.isEmpty == false && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
            let canonical = article.normalizedLink
            let pubDate = article.pubDate.timeIntervalSince1970

            sqlite3_reset(existenceStmt)
            sqlite3_bind_text(existenceStmt, 1, id, -1, Self.sqliteTransient)
            let existenceStatus = sqlite3_step(existenceStmt)
            guard existenceStatus == SQLITE_ROW || existenceStatus == SQLITE_DONE else {
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to check stored article identity"])
            }
            if existenceStatus == SQLITE_DONE { insertedIDs.insert(id) }

            // 1. Insert/Update Article
            sqlite3_reset(artStmt)
            sqlite3_bind_text(artStmt, 1, id, -1, Self.sqliteTransient)
            if let g = article.guid { sqlite3_bind_text(artStmt, 2, g, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 2) }
            sqlite3_bind_text(artStmt, 3, canonical, -1, Self.sqliteTransient)
            sqlite3_bind_text(artStmt, 4, article.title, -1, Self.sqliteTransient)
            sqlite3_bind_text(artStmt, 5, article.description, -1, Self.sqliteTransient)
            if let c = article.fullContent { sqlite3_bind_text(artStmt, 6, c, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 6) }
            sqlite3_bind_double(artStmt, 7, pubDate)
            sqlite3_bind_text(artStmt, 8, article.source, -1, Self.sqliteTransient)
            if let img = article.imageUrl { sqlite3_bind_text(artStmt, 9, img, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 9) }
            if let cat = article.category { sqlite3_bind_text(artStmt, 10, cat, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 10) }
            if let f = identityFeedURL { sqlite3_bind_text(artStmt, 11, f, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 11) }
            sqlite3_bind_double(artStmt, 12, now)
            sqlite3_bind_double(artStmt, 13, now)
            if let document = article.readerDocument {
                let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
                sqlite3_bind_text(artStmt, 14, encoded, -1, Self.sqliteTransient)
            } else { sqlite3_bind_null(artStmt, 14) }

            sqlite3_bind_int(artStmt, 15, validLink ? 1 : 0)
            sqlite3_bind_double(artStmt, 16, DateParser.unknownDate.timeIntervalSince1970)

            if sqlite3_step(artStmt) != SQLITE_DONE {
                try rollbackTransaction()
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to step article insert"])
            }

            try recordAlias(kind: "id", value: id, articleID: id)
            if let scoped = ArticleIdentity.scopedGUID(article.guid, feedURL: identityFeedURL) {
                try recordAlias(kind: "id", value: scoped, articleID: id)
            } else {
                try recordAlias(kind: "id", value: article.id, articleID: id)
            }
            if Self.isDocumentURL(canonical) {
                try recordAlias(kind: "url", value: canonical, articleID: id)
            }

            for fingerprint in ArticleIdentity.publisherTextFingerprints(article) {
                try recordAlias(kind: "content", value: fingerprint, articleID: id)
            }

            if let feedUrl = identityFeedURL {
                sqlite3_reset(feedStmt)
                sqlite3_bind_text(feedStmt, 1, id, -1, Self.sqliteTransient)
                sqlite3_bind_text(feedStmt, 2, feedUrl, -1, Self.sqliteTransient)
                guard sqlite3_step(feedStmt) == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed association"])
                }
            }

            // 2. Insert State (preserves existing read/saved state on conflict)
            sqlite3_reset(stateStmt)
            sqlite3_bind_text(stateStmt, 1, id, -1, Self.sqliteTransient)
            if sqlite3_step(stateStmt) != SQLITE_DONE {
                try rollbackTransaction()
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to step state insert"])
            }

            // 3. Insert Enrichment
            sqlite3_reset(enrichStmt)
            sqlite3_bind_text(enrichStmt, 1, id, -1, Self.sqliteTransient)
            if let s = article.aiSummary { sqlite3_bind_text(enrichStmt, 2, s, -1, Self.sqliteTransient) } else { sqlite3_bind_null(enrichStmt, 2) }
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
        
        if let feedUrl, let validators {
            try recordFeedValidators(validators, for: feedUrl, at: now)
        }
        try Task.checkCancellation()
        try commitTransaction()
        return insertedIDs
    }

    // MARK: - Feed Fetch State

    /// Stored conditional-request validators keyed by subscription URL.
    func feedValidators() throws -> [String: FeedValidators] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT url, etag, last_modified FROM feeds WHERE etag IS NOT NULL OR last_modified IS NOT NULL;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed validator query"])
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        var result: [String: FeedValidators] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let url = text(0) { result[url] = FeedValidators(etag: text(1), lastModified: text(2)) }
        }
        return result
    }

    /// Writes (or clears, when empty) a feed's validators; the caller owns the transaction.
    private func recordFeedValidators(_ validators: FeedValidators, for feedURL: String, at now: Double) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = """
        INSERT INTO feeds (id, url, created_at, last_fetched_at, etag, last_modified) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET last_fetched_at = excluded.last_fetched_at, etag = excluded.etag, last_modified = excluded.last_modified;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed validator write"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, feedURL, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        for (index, value) in [(5, validators.etag), (6, validators.lastModified)] {
            if let value { sqlite3_bind_text(statement, Int32(index), value, -1, Self.sqliteTransient) } else { sqlite3_bind_null(statement, Int32(index)) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed validators"])
        }
    }
    
    // Unknown publisher dates retain their identity sentinel; ingestion time orders them.
    private static let articleDateOrder = "CASE WHEN a.published_at = \(DateParser.unknownDate.timeIntervalSince1970) THEN a.created_at ELSE a.published_at END"

    private static let savedDocumentIDs = "SELECT article_id FROM article_state WHERE is_saved = 1 UNION SELECT r.duplicate_id FROM article_reconciliations r JOIN article_state s ON s.article_id = r.survivor_id WHERE s.is_saved = 1"
    private static let visibleArticle = "NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)"

    // MARK: - Article Queries
    
    func fetchArticles(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        limit: Int? = 500,
        after: ArticleQueryCursor? = nil,
        id: String? = nil,
        canonicalURL: String? = nil,
        includingOriginals: Bool = false
    ) throws -> [FeedArticle] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        
        var query = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, a.category,
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment, a.reader_document, \(Self.articleDateOrder)
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        WHERE 1=1
        """

        
        if !includingOriginals { query += " AND " + Self.visibleArticle }
        var params: [(type: String, val: Any)] = []
        
        if let id {
            query += " AND a.id = ?"
            params.append(("text", includingOriginals ? id : try resolvedArticleID(id)))
        }
        if let canonicalURL {
            if let target = try aliasTarget(kind: "url", value: canonicalURL) {
                query += " AND a.id = ?"
                params.append(("text", target))
            } else {
                query += """
                 AND a.canonical_url = ?
                 AND (SELECT count(*) FROM articles WHERE canonical_url = ?) = 1
                 AND NOT EXISTS (SELECT 1 FROM article_aliases WHERE kind = 'url' AND value = ? AND article_id IS NULL)
                """
                params.append(("text", canonicalURL))
                params.append(("text", canonicalURL))
                params.append(("text", canonicalURL))
            }
        }
        if let read = isRead {
            query += " AND s.is_read = ?"
            params.append(("int", read ? 1 : 0))
        }
        
        if let saved = isSaved {
            query += " AND s.is_saved = ?"
            params.append(("int", saved ? 1 : 0))
        }
        
        if let sec = section, !["Today", "Unread", "Saved Stories", "History"].contains(sec) {
            let terms = ArticleSection.keywords[sec] ?? [sec.lowercased()]
            query += " AND (" + terms.map { _ in "instr(lower(a.title || ' ' || coalesce(a.description, '') || ' ' || coalesce(a.category, '')), ?) > 0" }.joined(separator: " OR ") + ")"
            params += terms.map { ("text", $0) }
        }
        if let after {
            query += " AND (\(Self.articleDateOrder) < ? OR (\(Self.articleDateOrder) = ? AND a.id > ?))"
            params += [("double", after.value), ("double", after.value), ("text", after.id)]
        }

        query += " ORDER BY \(Self.articleDateOrder) DESC, a.id"
        
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
            } else if p.type == "double", let v = p.val as? Double {
                sqlite3_bind_double(stmt, col, v)
            } else if p.type == "text", let v = p.val as? String {
                sqlite3_bind_text(stmt, col, v, -1, Self.sqliteTransient)
            }
        }
        
        var results: [FeedArticle] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            if var article = parseArticleRow(stmt) {
                article.queryOrderValue = sqlite3_column_double(stmt, 18)
                results.append(article)
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        
        return results
    }
    
    // MARK: - Full Text Search (FTS5)
    
    func searchArticles(
        query: String,
        limit: Int = 100,
        after: ArticleQueryCursor? = nil
    ) throws -> [FeedArticle] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let parsed = ArticleFilterQuery.parse(trimmed)
        let sourceFilter = parsed.sourceFilter
        let categoryFilter = parsed.categoryFilter
        let readFilter = parsed.isReadFilter
        let savedFilter = parsed.isSavedFilter
        let cleanTerms = parsed.terms

        var sql = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, a.category,
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment, a.reader_document
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        """

        
        sql = sql.replacingOccurrences(of: "a.reader_document\n", with: "a.reader_document, " + (cleanTerms.isEmpty ? Self.articleDateOrder : "fts.rank") + "\n")
        var params: [(type: String, val: Any)] = []
        
        let hasFTS = !cleanTerms.isEmpty
        if hasFTS {
            sql += " JOIN articles_fts fts ON fts.article_id = a.id WHERE articles_fts MATCH ?"
            // Sanitize FTS search term: wrap terms with quotes or escape special FTS characters
            let sanitizedFtsTerm = cleanTerms.map { term in
                let cleaned = term.replacingOccurrences(of: "\"", with: "")
                return "\"\(cleaned)\"*"
            }.joined(separator: " ")
            params.append(("text", sanitizedFtsTerm))
        } else {
            sql += " WHERE 1=1"
        }
        
        sql += " AND " + Self.visibleArticle

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
        
        if let after {
            if hasFTS {
                sql += " AND (fts.rank > ? OR (fts.rank = ? AND a.id > ?))"
            } else {
                sql += " AND (\(Self.articleDateOrder) < ? OR (\(Self.articleDateOrder) = ? AND a.id > ?))"
            }
            params += [("double", after.value), ("double", after.value), ("text", after.id)]
        }
        if hasFTS {
            sql += " ORDER BY fts.rank, a.id LIMIT ?"
        } else {
            sql += " ORDER BY \(Self.articleDateOrder) DESC, a.id LIMIT ?"
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
            } else if p.type == "double", let v = p.val as? Double {
                sqlite3_bind_double(stmt, col, v)
            } else if p.type == "text", let v = p.val as? String {
                sqlite3_bind_text(stmt, col, v, -1, Self.sqliteTransient)
            }
        }
        
        var results: [FeedArticle] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            if var article = parseArticleRow(stmt) {
                article.queryOrderValue = sqlite3_column_double(stmt, 18)
                results.append(article)
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return results
    }
    
    // MARK: - State Mutations
    
    func markRead(articleId: String, isRead: Bool) throws {
        let articleId = try resolvedArticleID(articleId)
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
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
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

        let now = Date().timeIntervalSince1970
        let readInt: Int32 = isRead ? 1 : 0

        try beginTransaction()
        do {
            for articleId in articleIds {
                let articleId = try resolvedArticleID(articleId)
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
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
        } catch {
            try? rollbackTransaction()
            throw error
        }
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

        let now = Date().timeIntervalSince1970
        try beginTransaction()
        do {
            for articleId in articleIds {
                let articleId = try resolvedArticleID(articleId)
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
                sqlite3_bind_double(stmt, 2, now)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute batchMarkSaved for \(articleId)"])
                }
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }
    
    func markAllRead(feedUrl: String? = nil) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "UPDATE article_state SET is_read = 1, read_at = ?" +
            (feedUrl == nil ? ";" : " WHERE article_id IN (SELECT article_id FROM article_feeds WHERE feed_url = ?);")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        if let feedUrl { sqlite3_bind_text(stmt, 2, feedUrl, -1, Self.sqliteTransient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
    
    func toggleSaved(articleId: String) throws -> Bool {
        let next = try !isSaved(articleId: articleId)
        try setSaved(articleId: articleId, isSaved: next)
        return next
    }

    func setSaved(articleId: String, isSaved: Bool) throws {
        let articleId = try resolvedArticleID(articleId)
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
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
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 2, isSaved ? 1 : 0)
        if isSaved {
            sqlite3_bind_double(stmt, 3, now)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute toggleSaved"])
        }
    }
    
    func isRead(articleId: String) throws -> Bool {
        let articleId = try resolvedArticleID(articleId)
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT is_read FROM article_state WHERE article_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) == 1
        }
        return false
    }
    
    func isSaved(articleId: String) throws -> Bool {
        let articleId = try resolvedArticleID(articleId)
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT is_saved FROM article_state WHERE article_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) == 1
        }
        return false
    }
    
    func getReadArticleIDs() throws -> Set<String> {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT article_id FROM article_state s WHERE is_read = 1 AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = s.article_id);"
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
    
    private static func sentimentLabel(for score: Double) -> String {
        if score > 0.25 { return "Positive" }
        if score < -0.25 { return "Critical" }
        return "Neutral"
    }

    // MARK: - Enrichment Update
    
    struct EnrichmentUpdate: Sendable {
        var summary: String? = nil
        var category: String? = nil
        var sentiment: Double? = nil
        var entities: [String]? = nil
        var topics: [String]? = nil
        var content: String? = nil
        var image: String? = nil
        var readerDocument: ReaderDocument? = nil
    }

    func updateEnrichment(articleId: String, update: EnrichmentUpdate) throws {
        let articleId = try resolvedArticleID(articleId)
        let summary = update.summary
        let category = update.category
        let sentiment = update.sentiment
        let entities = update.entities
        let topics = update.topics
        let content = update.content
        let image = update.image
        let readerDocument = update.readerDocument
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

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
                if let readerDocument {
                    updates.append("reader_document = ?")
                    params.append(("text", String(decoding: try JSONEncoder().encode(readerDocument), as: UTF8.self)))
                } else {
                    updates.append("reader_document = NULL")
                }
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
                        sqlite3_bind_text(artStmt, col, v, -1, Self.sqliteTransient)
                    } else if p.type == "double", let v = p.val as? Double {
                        sqlite3_bind_double(artStmt, col, v)
                    }
                }
                sqlite3_bind_text(artStmt, Int32(params.count + 1), articleId, -1, Self.sqliteTransient)
                guard sqlite3_step(artStmt) == SQLITE_DONE else {
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot update publisher content"])
                }
            } else {
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher content update"])
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
        guard sqlite3_prepare_v2(db, enrichSql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare enrichment update"])
        }
        defer { sqlite3_finalize(stmt) }
        
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        if let s = summary { sqlite3_bind_text(stmt, 2, s, -1, Self.sqliteTransient) } else { sqlite3_bind_null(stmt, 2) }
        if let sent = sentiment { sqlite3_bind_double(stmt, 3, sent) } else { sqlite3_bind_null(stmt, 3) }
        if let ent = entities, let data = try? JSONEncoder().encode(ent), let str = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 4, str, -1, Self.sqliteTransient)
        } else { sqlite3_bind_null(stmt, 4) }
        if let top = topics, let data = try? JSONEncoder().encode(top), let str = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 5, str, -1, Self.sqliteTransient)
        } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_int(stmt, 6, content != nil ? 1 : 0)
        sqlite3_bind_double(stmt, 7, now)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot update enrichment"])
        }
        if content != nil, let article = try fetchArticles(id: articleId).first {
            for fingerprint in ArticleIdentity.publisherTextFingerprints(article) {
                try recordAlias(kind: "content", value: fingerprint, articleID: articleId)
            }
        }
        try commitTransaction()
    }

    /// Persists structured ArticleAnalysis into article_enrichment.
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String) throws {
        let articleId = try resolvedArticleID(articleId)
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
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, analysis.summary, -1, Self.sqliteTransient)

        if let kpData = try? JSONEncoder().encode(analysis.keyPoints), let kpStr = String(data: kpData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 3, kpStr, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let cat = analysis.category {
            sqlite3_bind_text(stmt, 4, cat, -1, Self.sqliteTransient)
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
            sqlite3_bind_text(stmt, 7, entStr, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        sqlite3_bind_text(stmt, 8, analysis.modelIdentifier, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 9, Int32(analysis.analysisVersion))
        sqlite3_bind_double(stmt, 10, now)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Step failed: \(msg)"])
        }
    }

    /// Fetches persisted ArticleAnalysis for an article (if previously analyzed).
    func fetchArticleAnalysis(for articleId: String) -> ArticleAnalysis? {
        guard let db = db, let articleId = try? resolvedArticleID(articleId) else { return nil }
        let sql = """
        SELECT summary, key_points, category, sentiment, entities, model_identifier, analysis_version
        FROM article_enrichment
        WHERE article_id = ? AND summary IS NOT NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
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
            let label = Self.sentimentLabel(for: score)
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
        try beginTransaction()
        do {
            try executeSimple("UPDATE articles SET content = NULL, reader_document = NULL WHERE id NOT IN (\(Self.savedDocumentIDs));")
            try executeSimple("DELETE FROM article_enrichment WHERE article_id NOT IN (\(Self.savedDocumentIDs));")
            // Feed-provided bodies return only from an unconditional refresh.
            try executeSimple("UPDATE feeds SET etag = NULL, last_modified = NULL;")
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    /// Clears replaceable data; article headers, read history and saved bodies are user data.
    func clearAllDatabaseCache() throws {
        try beginTransaction()
        do {
            try executeSimple("DELETE FROM article_enrichment;")
            try executeSimple("UPDATE articles SET content = NULL, reader_document = NULL WHERE id NOT IN (\(Self.savedDocumentIDs));")
            try executeSimple("UPDATE feeds SET etag = NULL, last_modified = NULL;")
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    // MARK: - Retention Policy & Pruning

    
    /// Prunes read articles older than `keepReadDays`.
    /// Never prunes unread articles or saved stories.
    @discardableResult
    func pruneOldArticles(keepReadDays: Int = 30) throws -> Int {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let cutoff = Date().timeIntervalSince1970 - Double(keepReadDays * 86400)
        
        let expired = """
        SELECT a.id FROM articles a JOIN article_state s ON s.article_id = a.id
        WHERE s.is_read = 1 AND s.is_saved = 0 AND \(Self.articleDateOrder) < ?
            AND \(Self.visibleArticle)
            AND NOT EXISTS (SELECT 1 FROM event_overview_citations c
                WHERE c.article_id = a.id OR c.article_id IN (
                    SELECT duplicate_id FROM article_reconciliations WHERE survivor_id = a.id))
        """
        let sql = """
        DELETE FROM articles WHERE id IN (
            \(expired)
            UNION SELECT r.duplicate_id FROM article_reconciliations r
                WHERE r.survivor_id IN (\(expired))
        );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_bind_double(stmt, 2, cutoff)
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
        JOIN article_state s ON s.article_id = a.id
        WHERE \(Self.visibleArticle);
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
        
        let storedID = String(cString: idStr)
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
            sentimentLabel = Self.sentimentLabel(for: score)
        }
        
        return FeedArticle(
            storedID: storedID,
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
            sentimentLabel: sentimentLabel,
            readerDocument: sqlite3_column_text(stmt, 17).flatMap {
                try? JSONDecoder().decode(ReaderDocument.self, from: Data(String(cString: $0).utf8))
            }
        )
    }

    // MARK: - Event Overviews

    @discardableResult
    func recordEventOverview(_ overview: EventOverviewDocument) throws -> Bool {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

        // Check if an existing overview exists for this event
        var checkStmt: OpaquePointer?
        let checkSql = "SELECT id, membership_version FROM event_overviews WHERE event_id = ?;"
        guard sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare check statement for event overview"])
        }
        defer { sqlite3_finalize(checkStmt) }

        sqlite3_bind_text(checkStmt, 1, overview.eventID, -1, Self.sqliteTransient)
        var existingOverviewID: String?
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingVersion = Int(sqlite3_column_int(checkStmt, 1))
            // An older result never overwrites a newer version
            if existingVersion > overview.membershipVersion {
                return false
            }
            if let idText = sqlite3_column_text(checkStmt, 0) {
                existingOverviewID = String(cString: idText)
            }
        }

        // If an existing overview exists with older/same version, remove it first
        if let oldID = existingOverviewID {
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM event_overviews WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, oldID, -1, Self.sqliteTransient)
                _ = sqlite3_step(delStmt)
                sqlite3_finalize(delStmt)
            }
        }

        let encoder = JSONEncoder()
        let factsJSON = String(decoding: try encoder.encode(overview.facts), as: UTF8.self)
        let memberArticleIDsJSON = String(decoding: try encoder.encode(overview.memberArticleIDs), as: UTF8.self)
        var leadImageJSON: String?
        if let leadImage = overview.leadImage {
            leadImageJSON = String(decoding: try encoder.encode(leadImage), as: UTF8.self)
        }

        let insertOverviewSql = """
        INSERT INTO event_overviews (
            id, event_id, membership_version, input_text_hash,
            schema_version, analysis_version, title, summary,
            facts_json, lead_image_json, member_article_ids_json,
            kind, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var overviewStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertOverviewSql, -1, &overviewStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare insert statement for event overview"])
        }
        defer { sqlite3_finalize(overviewStmt) }

        sqlite3_bind_text(overviewStmt, 1, overview.id, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 2, overview.eventID, -1, Self.sqliteTransient)
        sqlite3_bind_int(overviewStmt, 3, Int32(overview.membershipVersion))
        sqlite3_bind_text(overviewStmt, 4, overview.inputTextHash, -1, Self.sqliteTransient)
        sqlite3_bind_int(overviewStmt, 5, Int32(overview.schemaVersion))
        sqlite3_bind_int(overviewStmt, 6, Int32(overview.analysisVersion))
        sqlite3_bind_text(overviewStmt, 7, overview.title, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 8, overview.summary, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 9, factsJSON, -1, Self.sqliteTransient)
        if let lij = leadImageJSON {
            sqlite3_bind_text(overviewStmt, 10, lij, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(overviewStmt, 10)
        }
        sqlite3_bind_text(overviewStmt, 11, memberArticleIDsJSON, -1, Self.sqliteTransient)
        sqlite3_bind_text(overviewStmt, 12, overview.kind.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_double(overviewStmt, 13, overview.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(overviewStmt, 14, overview.updatedAt.timeIntervalSince1970)

        guard sqlite3_step(overviewStmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert event overview: \(errMsg)"])
        }

        let insertCitationSql = """
        INSERT INTO event_overview_citations (
            id, overview_id, article_id, passage_id, passage_fingerprint,
            quote, source_title, source_name, source_url, published_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var citationStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertCitationSql, -1, &citationStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare citation statement"])
        }
        defer { sqlite3_finalize(citationStmt) }

        for citation in overview.citations.values {
            sqlite3_reset(citationStmt)
            sqlite3_bind_text(citationStmt, 1, citation.id, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 2, overview.id, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 3, citation.articleID, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 4, citation.passageID, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 5, citation.passageFingerprint, -1, Self.sqliteTransient)
            sqlite3_bind_text(citationStmt, 6, citation.quote, -1, Self.sqliteTransient)
            if let st = citation.sourceTitle { sqlite3_bind_text(citationStmt, 7, st, -1, Self.sqliteTransient) } else { sqlite3_bind_null(citationStmt, 7) }
            if let sn = citation.sourceName { sqlite3_bind_text(citationStmt, 8, sn, -1, Self.sqliteTransient) } else { sqlite3_bind_null(citationStmt, 8) }
            if let su = citation.sourceURL { sqlite3_bind_text(citationStmt, 9, su, -1, Self.sqliteTransient) } else { sqlite3_bind_null(citationStmt, 9) }
            if let pa = citation.publishedAt { sqlite3_bind_double(citationStmt, 10, pa.timeIntervalSince1970) } else { sqlite3_bind_null(citationStmt, 10) }

            guard sqlite3_step(citationStmt) == SQLITE_DONE else {
                let errMsg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to insert event overview citation: \(errMsg)"])
            }
        }

        try commitTransaction()
        return true
    }

    func fetchEventOverview(eventID: String) throws -> EventOverviewDocument? {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        let overviewSql = """
        SELECT id, event_id, membership_version, input_text_hash,
               schema_version, analysis_version, title, summary,
               facts_json, lead_image_json, member_article_ids_json,
               kind, created_at, updated_at
        FROM event_overviews
        WHERE event_id = ?;
        """
        var overviewStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, overviewSql, -1, &overviewStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetch overview statement"])
        }
        defer { sqlite3_finalize(overviewStmt) }

        sqlite3_bind_text(overviewStmt, 1, eventID, -1, Self.sqliteTransient)
        guard sqlite3_step(overviewStmt) == SQLITE_ROW else {
            return nil
        }

        let id = String(cString: sqlite3_column_text(overviewStmt, 0))
        let fetchedEventID = String(cString: sqlite3_column_text(overviewStmt, 1))
        let membershipVersion = Int(sqlite3_column_int(overviewStmt, 2))
        let inputTextHash = String(cString: sqlite3_column_text(overviewStmt, 3))
        let schemaVersion = Int(sqlite3_column_int(overviewStmt, 4))
        let analysisVersion = Int(sqlite3_column_int(overviewStmt, 5))
        let title = String(cString: sqlite3_column_text(overviewStmt, 6))
        let summary = String(cString: sqlite3_column_text(overviewStmt, 7))
        let factsJSON = String(cString: sqlite3_column_text(overviewStmt, 8))
        let leadImageJSON = sqlite3_column_text(overviewStmt, 9).map { String(cString: $0) }
        let memberArticleIDsJSON = String(cString: sqlite3_column_text(overviewStmt, 10))
        let kindString = String(cString: sqlite3_column_text(overviewStmt, 11))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(overviewStmt, 12))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(overviewStmt, 13))

        let decoder = JSONDecoder()
        let facts = (try? decoder.decode([OverviewFact].self, from: Data(factsJSON.utf8))) ?? []
        let memberArticleIDs = (try? decoder.decode([String].self, from: Data(memberArticleIDsJSON.utf8))) ?? []
        var leadImage: OverviewLeadImage?
        if let lij = leadImageJSON, let data = lij.data(using: .utf8) {
            leadImage = try? decoder.decode(OverviewLeadImage.self, from: data)
        }
        let kind = OverviewKind(rawValue: kindString) ?? .synthesized

        // Fetch citations
        let citationSql = """
        SELECT id, article_id, passage_id, passage_fingerprint,
               quote, source_title, source_name, source_url, published_at
        FROM event_overview_citations
        WHERE overview_id = ?;
        """
        var citationStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, citationSql, -1, &citationStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetch citations statement"])
        }
        defer { sqlite3_finalize(citationStmt) }

        sqlite3_bind_text(citationStmt, 1, id, -1, Self.sqliteTransient)
        var citations: [OverviewCitation] = []
        while sqlite3_step(citationStmt) == SQLITE_ROW {
            let citID = String(cString: sqlite3_column_text(citationStmt, 0))
            let articleID = String(cString: sqlite3_column_text(citationStmt, 1))
            let passageID = String(cString: sqlite3_column_text(citationStmt, 2))
            let passageFingerprint = String(cString: sqlite3_column_text(citationStmt, 3))
            let quote = String(cString: sqlite3_column_text(citationStmt, 4))
            let sourceTitle = sqlite3_column_text(citationStmt, 5).map { String(cString: $0) }
            let sourceName = sqlite3_column_text(citationStmt, 6).map { String(cString: $0) }
            let sourceURL = sqlite3_column_text(citationStmt, 7).map { String(cString: $0) }
            var publishedAt: Date?
            if sqlite3_column_type(citationStmt, 8) != SQLITE_NULL {
                publishedAt = Date(timeIntervalSince1970: sqlite3_column_double(citationStmt, 8))
            }
            citations.append(OverviewCitation(
                id: citID,
                articleID: articleID,
                passageID: passageID,
                passageFingerprint: passageFingerprint,
                quote: quote,
                source: OverviewSourceMetadata(
                    title: sourceTitle,
                    name: sourceName,
                    url: sourceURL,
                    publishedAt: publishedAt
                )
            ))
        }

        return EventOverviewDocument(
            id: id,
            eventID: fetchedEventID,
            version: OverviewVersionContext(
                membershipVersion: membershipVersion,
                inputTextHash: inputTextHash,
                schemaVersion: schemaVersion,
                analysisVersion: analysisVersion
            ),
            content: OverviewContent(
                title: title,
                summary: summary,
                facts: facts,
                citations: citations,
                leadImage: leadImage
            ),
            provenance: OverviewProvenance(
                memberArticleIDs: memberArticleIDs,
                kind: kind,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )
    }

    @discardableResult
    func deleteEventOverview(eventID: String) throws -> Bool {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

        var stmt: OpaquePointer?
        let sql = "DELETE FROM event_overviews WHERE event_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare delete event overview statement"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, eventID, -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete event overview: \(errMsg)"])
        }
        let changes = sqlite3_changes(db)
        try commitTransaction()
        return changes > 0
    }

    func clearEventOverviews() throws {
        guard db != nil else { return }
        try executeSimple("DELETE FROM event_overviews;")
        logger.info("Cleared all event overviews and citations.")
    }

}
