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
            try registerFunctions()

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
        if version < 10 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Libraries reconstructed at an older version may already carry the columns.
                let columns = try columnNames(of: "feeds")
                for (name, definition) in [("consecutive_failures", "INTEGER NOT NULL DEFAULT 0"), ("next_attempt_at", "REAL")]
                where !columns.contains(name) {
                    try executeSimple("ALTER TABLE feeds ADD COLUMN \(name) \(definition);")
                }
                try setUserVersion(10)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 11 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                let columns = try columnNames(of: "feeds")
                for (name, definition) in [("latest_item_at", "REAL"), ("item_count", "INTEGER NOT NULL DEFAULT 0"), ("full_text_items", "INTEGER NOT NULL DEFAULT 0")]
                where !columns.contains(name) {
                    try executeSimple("ALTER TABLE feeds ADD COLUMN \(name) \(definition);")
                }
                try setUserVersion(11)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 12 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple("""
                DROP TRIGGER IF EXISTS trg_articles_au;
                CREATE TRIGGER trg_articles_au AFTER UPDATE ON articles
                WHEN old.title IS NOT new.title OR old.description IS NOT new.description
                    OR old.content IS NOT new.content OR old.source IS NOT new.source
                    OR old.category IS NOT new.category
                BEGIN
                    DELETE FROM articles_fts WHERE article_id = old.id;
                    INSERT INTO articles_fts(article_id, title, description, content, source, category)
                    VALUES (new.id, new.title, coalesce(new.description, ''), coalesce(new.content, ''), new.source, coalesce(new.category, ''));
                END;
                """)
                try setUserVersion(12)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 13 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // An article belongs to at most one event. A merged event keeps its row as a forward
                // to the survivor so links to the old ID still resolve.
                try executeSimple("""
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    membership_version INTEGER NOT NULL DEFAULT 1,
                    merged_into TEXT REFERENCES events(id) ON DELETE SET NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_events_merged_into ON events(merged_into);
                CREATE TABLE IF NOT EXISTS event_members (
                    article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
                    joined_version INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_event_members_event ON event_members(event_id);
                """)
                try Task.checkCancellation()
                try setUserVersion(13)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 14 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Matching progress, the user's "different events" decisions and the event version a
                // reader has seen. A changed title or description makes the article pending again.
                try executeSimple("""
                CREATE TABLE IF NOT EXISTS event_match_state (
                    article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    matcher_version INTEGER NOT NULL,
                    processed_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS event_exclusions (
                    article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                    other_article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (article_id, other_article_id),
                    CHECK (article_id < other_article_id)
                );
                CREATE INDEX IF NOT EXISTS idx_event_exclusions_other ON event_exclusions(other_article_id);
                CREATE TABLE IF NOT EXISTS event_state (
                    event_id TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
                    seen_version INTEGER NOT NULL,
                    seen_at REAL NOT NULL
                );
                DROP TRIGGER IF EXISTS trg_articles_event_rematch;
                CREATE TRIGGER trg_articles_event_rematch AFTER UPDATE OF title, description ON articles
                WHEN old.title IS NOT new.title OR old.description IS NOT new.description
                BEGIN
                    DELETE FROM event_match_state WHERE article_id = old.id;
                END;
                """)
                try Task.checkCancellation()
                try setUserVersion(14)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 15 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // A durable integer key avoids reading the FTS content blob just to join article IDs.
                // Do not use articles.rowid: VACUUM may change a hidden rowid on a TEXT-keyed table.
                try executeSimple("""
                DROP TRIGGER IF EXISTS trg_articles_ai;
                DROP TRIGGER IF EXISTS trg_articles_ad;
                DROP TRIGGER IF EXISTS trg_articles_au;
                DROP TABLE IF EXISTS articles_fts;
                DROP TABLE IF EXISTS article_fts_rows;
                CREATE TABLE article_fts_rows (
                    fts_rowid INTEGER PRIMARY KEY,
                    article_id TEXT NOT NULL UNIQUE REFERENCES articles(id) ON DELETE CASCADE
                );
                CREATE VIRTUAL TABLE articles_fts USING fts5(
                    article_id UNINDEXED, title, description, content, source, category,
                    tokenize = 'porter unicode61'
                );
                INSERT INTO article_fts_rows(article_id) SELECT id FROM articles ORDER BY id;
                INSERT INTO articles_fts(rowid, article_id, title, description, content, source, category)
                SELECT f.fts_rowid, a.id, a.title, coalesce(a.description, ''), coalesce(a.content, ''),
                       a.source, coalesce(a.category, '')
                FROM articles a JOIN article_fts_rows f ON f.article_id = a.id;
                CREATE TRIGGER trg_articles_ai AFTER INSERT ON articles BEGIN
                    INSERT INTO article_fts_rows(article_id) VALUES (new.id);
                    INSERT INTO articles_fts(rowid, article_id, title, description, content, source, category)
                    VALUES ((SELECT fts_rowid FROM article_fts_rows WHERE article_id = new.id), new.id,
                            new.title, coalesce(new.description, ''), coalesce(new.content, ''),
                            new.source, coalesce(new.category, ''));
                END;
                CREATE TRIGGER trg_articles_ad BEFORE DELETE ON articles BEGIN
                    DELETE FROM articles_fts WHERE rowid = (SELECT fts_rowid FROM article_fts_rows WHERE article_id = old.id);
                    DELETE FROM article_fts_rows WHERE article_id = old.id;
                END;
                CREATE TRIGGER trg_articles_au AFTER UPDATE ON articles
                WHEN old.title IS NOT new.title OR old.description IS NOT new.description
                  OR old.content IS NOT new.content OR old.source IS NOT new.source
                  OR old.category IS NOT new.category
                BEGIN
                    DELETE FROM articles_fts WHERE rowid = (SELECT fts_rowid FROM article_fts_rows WHERE article_id = old.id);
                    INSERT INTO articles_fts(rowid, article_id, title, description, content, source, category)
                    VALUES ((SELECT fts_rowid FROM article_fts_rows WHERE article_id = new.id), new.id,
                            new.title, coalesce(new.description, ''), coalesce(new.content, ''),
                            new.source, coalesce(new.category, ''));
                END;
                """)
                try Task.checkCancellation()
                try setUserVersion(15)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 16 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                let columns = try columnNames(of: "article_enrichment")
                for (name, definition) in [("input_content_version", "INTEGER"), ("input_text_hash", "TEXT")]
                where !columns.contains(name) {
                    try executeSimple("ALTER TABLE article_enrichment ADD COLUMN \(name) \(definition);")
                }
                try executeSimple("""
                CREATE TABLE IF NOT EXISTS publisher_content_revisions (
                    article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL,
                    observed_at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    changed_fields INTEGER NOT NULL,
                    input_text_hash TEXT NOT NULL,
                    PRIMARY KEY (article_id, version)
                );
                INSERT OR IGNORE INTO publisher_content_revisions
                SELECT id, 1, \(Date().timeIntervalSince1970), 'snapshot', 0,
                       news_publisher_input(title, coalesce(description, ''), content) FROM articles;
                -- Legacy generated results have no input provenance; keep publisher bodies and user state.
                UPDATE article_enrichment SET summary = NULL, key_points = NULL, sentiment = NULL,
                    entities = NULL, topics = NULL, category = NULL, confidence = NULL,
                    model_identifier = NULL, analysis_version = NULL, input_content_version = NULL, input_text_hash = NULL;
                DROP TRIGGER IF EXISTS trg_publisher_content_insert;
                CREATE TRIGGER trg_publisher_content_insert AFTER INSERT ON articles
                BEGIN
                    INSERT INTO publisher_content_revisions VALUES (new.id, 1, new.created_at, 'snapshot', 0,
                        news_publisher_input(new.title, coalesce(new.description, ''), new.content));
                END;
                DROP TRIGGER IF EXISTS trg_publisher_content_update;
                CREATE TRIGGER trg_publisher_content_update AFTER UPDATE OF title, description, content ON articles
                WHEN old.title IS NOT new.title OR old.description IS NOT new.description OR old.content IS NOT new.content
                BEGIN
                    UPDATE article_enrichment SET summary = NULL, key_points = NULL, sentiment = NULL,
                        entities = NULL, topics = NULL, category = NULL, confidence = NULL,
                        model_identifier = NULL, analysis_version = NULL, input_content_version = NULL, input_text_hash = NULL
                        WHERE article_id = new.id;
                    DELETE FROM event_overviews WHERE event_id IN (SELECT event_id FROM event_members WHERE article_id = new.id)
                        OR id IN (SELECT overview_id FROM event_overview_citations WHERE article_id = new.id);
                    INSERT INTO publisher_content_revisions
                    SELECT new.id, coalesce(max(version), 0) + 1, new.updated_at,
                        CASE WHEN old.title IS NOT new.title OR old.description IS NOT new.description OR coalesce(old.content, '') != ''
                             THEN 'publisher_update' ELSE 'extraction' END,
                        (old.title IS NOT new.title) + 2 * (old.description IS NOT new.description) + 4 * (old.content IS NOT new.content),
                        news_publisher_input(new.title, coalesce(new.description, ''), new.content)
                    FROM publisher_content_revisions WHERE article_id = new.id
                    HAVING old.title IS NOT new.title OR old.description IS NOT new.description OR new.content IS NOT NULL;
                    -- Keep compact metadata for the latest twenty observations, not publisher body copies.
                    DELETE FROM publisher_content_revisions WHERE article_id = new.id AND version <
                        (SELECT max(version) - 19 FROM publisher_content_revisions WHERE article_id = new.id);
                END;
                """)
                try Task.checkCancellation()
                try setUserVersion(16)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 17 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Story importance (StoryVisibilityPolicy) and stories that expired before more publishers covered them.
                try executeSimple("""
                CREATE TABLE IF NOT EXISTS story_importance (
                    article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    level INTEGER NOT NULL,
                    judged_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS expired_stories (
                    key TEXT PRIMARY KEY,
                    expired_at REAL NOT NULL
                );
                DROP TRIGGER IF EXISTS trg_articles_importance_rejudge;
                CREATE TRIGGER trg_articles_importance_rejudge AFTER UPDATE OF title, description ON articles
                WHEN old.title IS NOT new.title OR old.description IS NOT new.description
                BEGIN
                    DELETE FROM story_importance WHERE article_id = old.id;
                END;
                """)
                try setUserVersion(17)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 18 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Lead images found on publisher pages for stories whose feeds carry none; NULL records a page without one.
                try executeSimple("""
                CREATE TABLE IF NOT EXISTS story_images (
                    article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    image_url TEXT,
                    checked_at REAL NOT NULL
                );
                """)
                try setUserVersion(18)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 19 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple("CREATE INDEX IF NOT EXISTS idx_story_images_url ON story_images(image_url);")
                try setUserVersion(19)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 20 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // The on-device model generation that produced stored overviews and summaries (`reconcileModelGeneration`).
                try executeSimple("CREATE TABLE IF NOT EXISTS model_generation (id INTEGER PRIMARY KEY CHECK (id = 1), value TEXT NOT NULL);")
                try setUserVersion(20)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
        if version < 21 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Page images found to be shared site defaults (#338), so a later story declaring one never keeps it.
                try executeSimple("CREATE TABLE IF NOT EXISTS story_image_defaults (url TEXT PRIMARY KEY);")
                try setUserVersion(21)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }
    
    /// Muting predicates for list queries (`MuteRules`); both are pure functions of their arguments.
    private func registerFunctions() throws {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        guard sqlite3_create_function_v2(db, "news_publisher_input", 3, flags, nil, publisherInputFunction, nil, nil, nil) == SQLITE_OK,
              sqlite3_create_function_v2(db, "news_muted_source", 2, flags, nil, mutedSourceFunction, nil, nil, nil) == SQLITE_OK,
              sqlite3_create_function_v2(db, "news_muted_topic", 3, flags, nil, mutedTopicFunction, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot register database functions"])
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

    private func columnNames(of table: String) throws -> Set<String> {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot inspect \(table) schema"])
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
        return columns
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
    static func isDocumentURL(_ value: String) -> Bool {
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

    /// Resolves ID aliases in bounded queries, preserving input order and ambiguous/missing fallbacks.
    func resolvedArticleIDs(_ ids: [String]) throws -> [String] {
        // SQLite BINARY keys distinguish UTF-8 spellings that Swift String considers equal.
        var seen = Set<Data>()
        let uniqueIDs = ids.filter { seen.insert(Data($0.utf8)).inserted }
        var targets: [Data: String] = [:]
        for start in stride(from: 0, to: uniqueIDs.count, by: 400) {
            try Task.checkCancellation()
            let slice = Array(uniqueIDs[start..<min(start + 400, uniqueIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try eventRows("SELECT value, article_id FROM article_aliases WHERE kind = 'id' AND value IN (\(placeholders));",
                                     slice.map { .text($0) })
            for row in rows {
                if let alias = row[0], let target = row[1] { targets[Data(alias.utf8)] = target }
            }
        }
        return ids.map { targets[Data($0.utf8)] ?? $0 }
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

    // A refresh whose item brings no publisher text (?17 = 0), such as a document holding only feed media,
    // keeps a stored document that has text, and its content (ReaderDocument.hasPublisherText).
    private static let storedHasPublisherText = """
    EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(articles.reader_document)
        THEN articles.reader_document ELSE '{}' END, '$.blocks') WHERE json_extract(value, '$.kind') <> 'figure')
    """

    private static let articleUpsertSQL = """
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
        content = CASE WHEN articles.reader_document IS NOT NULL AND (excluded.reader_document IS NULL
                OR (?17 = 0 AND \(storedHasPublisherText)))
            THEN articles.content ELSE coalesce(excluded.content, articles.content) END,
        reader_document = CASE WHEN ?17 = 0 AND \(storedHasPublisherText)
            THEN articles.reader_document ELSE coalesce(excluded.reader_document, articles.reader_document) END,
        image_url = coalesce(excluded.image_url, articles.image_url),
        category = coalesce(excluded.category, articles.category),
        feed_url = coalesce(articles.feed_url, excluded.feed_url),
        updated_at = excluded.updated_at;
    """

    private struct ArticleUpsertValues {
        let id: String
        let canonical: String
        let pubDate: Double
        let identityFeedURL: String?
        let validLink: Bool
        let now: Double
    }

    private func bindArticleUpsertStatement(
        _ artStmt: OpaquePointer?,
        article: FeedArticle,
        values: ArticleUpsertValues
    ) throws {
        sqlite3_reset(artStmt)
        sqlite3_bind_text(artStmt, 1, values.id, -1, Self.sqliteTransient)
        if let g = article.guid { sqlite3_bind_text(artStmt, 2, g, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 2) }
        sqlite3_bind_text(artStmt, 3, values.canonical, -1, Self.sqliteTransient)
        sqlite3_bind_text(artStmt, 4, article.title, -1, Self.sqliteTransient)
        sqlite3_bind_text(artStmt, 5, article.description, -1, Self.sqliteTransient)
        if let c = article.fullContent { sqlite3_bind_text(artStmt, 6, c, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 6) }
        sqlite3_bind_double(artStmt, 7, values.pubDate)
        sqlite3_bind_text(artStmt, 8, article.source, -1, Self.sqliteTransient)
        if let img = article.imageUrl { sqlite3_bind_text(artStmt, 9, img, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 9) }
        if let cat = article.category { sqlite3_bind_text(artStmt, 10, cat, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 10) }
        if let f = values.identityFeedURL { sqlite3_bind_text(artStmt, 11, f, -1, Self.sqliteTransient) } else { sqlite3_bind_null(artStmt, 11) }
        sqlite3_bind_double(artStmt, 12, values.now)
        sqlite3_bind_double(artStmt, 13, values.now)
        if let document = article.readerDocument {
            let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
            sqlite3_bind_text(artStmt, 14, encoded, -1, Self.sqliteTransient)
        } else { sqlite3_bind_null(artStmt, 14) }

        sqlite3_bind_int(artStmt, 15, values.validLink ? 1 : 0)
        sqlite3_bind_double(artStmt, 16, DateParser.unknownDate.timeIntervalSince1970)
        sqlite3_bind_int(artStmt, 17, article.readerDocument?.hasPublisherText == true ? 1 : 0)
    }

    /// `validators` accompany a fresh 200 response. They and the response's content stats are written in the same
    /// transaction as the articles, so a feed is only ever answered "not modified" for content that was durably ingested.
    @discardableResult
    func upsertArticles(_ articles: [FeedArticle], feedUrl: String? = nil, validators: FeedValidators? = nil, preservingStoredContent: Bool = false) throws -> Set<String> {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !articles.isEmpty else { return [] }
        
        let signpostState = NewsSignposts.begin(NewsSignposts.database, name: "DatabaseBatchUpsert", metadata: "count=\(articles.count)")
        defer { NewsSignposts.end(NewsSignposts.database, name: "DatabaseBatchUpsert", state: signpostState) }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }
        
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
        
        guard sqlite3_prepare_v2(db, Self.articleUpsertSQL, -1, &artStmt, nil) == SQLITE_OK,
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
        var expiredStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM expired_stories WHERE key IN (?, ?);", -1, &expiredStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare expired story query"])
        }
        defer { sqlite3_finalize(expiredStmt) }
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
            if existenceStatus == SQLITE_DONE {
                // A story that expired while waiting for coverage is not brought back by feeds that still list it.
                sqlite3_reset(expiredStmt)
                sqlite3_bind_text(expiredStmt, 1, id, -1, Self.sqliteTransient)
                sqlite3_bind_text(expiredStmt, 2, canonical, -1, Self.sqliteTransient)
                if sqlite3_step(expiredStmt) == SQLITE_ROW { continue }
                insertedIDs.insert(id)
            }

            // Bookmarking a frozen/aliased snapshot must register identity without reverting publisher content.
            let preserveExisting = preservingStoredContent && existenceStatus == SQLITE_ROW
            // 1. Insert/Update Article
            if !preserveExisting {
                let values = ArticleUpsertValues(
                    id: id,
                    canonical: canonical,
                    pubDate: pubDate,
                    identityFeedURL: identityFeedURL,
                    validLink: validLink,
                    now: now
                )
                try bindArticleUpsertStatement(artStmt, article: article, values: values)
                if sqlite3_step(artStmt) != SQLITE_DONE {
                    try rollbackTransaction()
                    throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to step article insert"])
                }
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
            if !preserveExisting {
                sqlite3_reset(enrichStmt)
                sqlite3_bind_text(enrichStmt, 1, id, -1, Self.sqliteTransient)
                // Feed/legacy snapshots carry no analysis-input provenance. Only guarded analysis writes supply summaries.
                sqlite3_bind_null(enrichStmt, 2)
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
        }
        
        if let feedUrl, let validators {
            try recordFeedFetch(validators, stats: FeedContentStats(articles: articles), for: feedUrl, at: now)
        }
        try Task.checkCancellation()
        try commitTransaction()
        return insertedIDs
    }

    // MARK: - Feed Fetch State

    /// Stored validators, retry schedule and content stats keyed by subscription URL.
    func feedFetchStates() throws -> [String: FeedFetchState] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = "SELECT url, etag, last_modified, consecutive_failures, next_attempt_at, last_fetched_at, latest_item_at, item_count, full_text_items FROM feeds;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed state query"])
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
        }
        var result: [String: FeedFetchState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = text(0) else { continue }
            let validators = FeedValidators(etag: text(1), lastModified: text(2))
            result[url] = FeedFetchState(
                validators: validators.isEmpty ? nil : validators,
                failures: Int(sqlite3_column_int(statement, 3)),
                retryAt: date(4), lastFetchedAt: date(5), latestItemAt: date(6),
                itemCount: Int(sqlite3_column_int(statement, 7)), fullTextItems: Int(sqlite3_column_int(statement, 8)))
        }
        return result
    }

    /// A successful response (200 or 304) ends any backoff. Validators are untouched: they change only with ingestion.
    func recordFeedSuccess(_ feedURL: String, at now: Date) throws {
        try writeFeedSchedule(feedURL, failures: 0, retryAt: nil, fetchedAt: now.timeIntervalSince1970)
    }

    /// Counts a failed request and returns when the feed may be requested again.
    @discardableResult
    func recordFeedFailure(_ feedURL: String, retryAfter: TimeInterval?, at now: Date) throws -> Date {
        let previous = try feedFetchStates()[feedURL]
        // A long quiet period forgives old failures; a subscription removed and re-added months later starts fresh.
        let stale = previous?.retryAt.map { now.timeIntervalSince($0) > FeedRetryPolicy.maximumDelay } ?? false
        let failures = (stale ? 0 : previous?.failures ?? 0) + 1
        let retryAt = now.addingTimeInterval(FeedRetryPolicy.delay(afterFailures: failures, retryAfter: retryAfter))
        try writeFeedSchedule(feedURL, failures: failures, retryAt: retryAt, fetchedAt: nil)
        return retryAt
    }

    private func writeFeedSchedule(_ feedURL: String, failures: Int, retryAt: Date?, fetchedAt: Double?) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = """
        INSERT INTO feeds (id, url, created_at, last_fetched_at, consecutive_failures, next_attempt_at) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET last_fetched_at = coalesce(excluded.last_fetched_at, feeds.last_fetched_at),
            consecutive_failures = excluded.consecutive_failures, next_attempt_at = excluded.next_attempt_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed schedule write"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, feedURL, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        if let fetchedAt { sqlite3_bind_double(statement, 4, fetchedAt) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_int(statement, 5, Int32(failures))
        if let retryAt { sqlite3_bind_double(statement, 6, retryAt.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 6) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed schedule"])
        }
    }

    /// Writes a fresh response's validators (cleared when empty) and content stats; the caller owns the transaction.
    private func recordFeedFetch(_ validators: FeedValidators, stats: FeedContentStats, for feedURL: String, at now: Double) throws {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let sql = """
        INSERT INTO feeds (id, url, created_at, last_fetched_at, etag, last_modified, latest_item_at, item_count, full_text_items)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET last_fetched_at = excluded.last_fetched_at, etag = excluded.etag,
            last_modified = excluded.last_modified, latest_item_at = excluded.latest_item_at,
            item_count = excluded.item_count, full_text_items = excluded.full_text_items;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed fetch write"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, feedURL, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        for (index, value) in [(5, validators.etag), (6, validators.lastModified)] {
            if let value { sqlite3_bind_text(statement, Int32(index), value, -1, Self.sqliteTransient) } else { sqlite3_bind_null(statement, Int32(index)) }
        }
        if let latest = stats.latestItem { sqlite3_bind_double(statement, 7, latest.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 7) }
        sqlite3_bind_int(statement, 8, Int32(stats.itemCount))
        sqlite3_bind_int(statement, 9, Int32(stats.fullTextItems))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed fetch state"])
        }
    }
    
    // Unknown publisher dates retain their identity sentinel; ingestion time orders them.
    private static let articleDateOrder = "CASE WHEN a.published_at = \(DateParser.unknownDate.timeIntervalSince1970) THEN a.created_at ELSE a.published_at END"

    private static let savedDocumentIDs = "SELECT article_id FROM article_state WHERE is_saved = 1 UNION SELECT r.duplicate_id FROM article_reconciliations r JOIN article_state s ON s.article_id = r.survivor_id WHERE s.is_saved = 1"
    private static let visibleArticle = "NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)"
    /// A story waiting for more coverage (`StoryVisibilityPolicy`): rated below important, no report of its event rated
    /// important, and no more than `minorStorySources` publishers in its event. Unrated stories never wait.
    private static let waitingStory = """
    (EXISTS (SELECT 1 FROM story_importance i WHERE i.article_id = a.id AND i.level < \(StoryVisibilityPolicy.importantLevel.rawValue))
     AND NOT EXISTS (SELECT 1 FROM event_members m JOIN event_members peer ON peer.event_id = m.event_id
        JOIN story_importance pi ON pi.article_id = peer.article_id
        WHERE m.article_id = a.id AND pi.level >= \(StoryVisibilityPolicy.importantLevel.rawValue))
     AND coalesce((SELECT count(DISTINCT x.source) FROM event_members m JOIN event_members peer ON peer.event_id = m.event_id
        JOIN articles x ON x.id = peer.article_id WHERE m.article_id = a.id), 1) <= \(StoryVisibilityPolicy.minorStorySources))
    """
    /// Binds `MuteRules.sourceParameter` and `MuteRules.topicParameter`, in that order.
    private static let mutedArticle = "(news_muted_source(a.canonical_url, ?) OR news_muted_topic(a.title, a.description, ?))"

    private typealias QueryParameter = (type: String, val: Any)

    private func bind(_ params: [QueryParameter], to statement: OpaquePointer?) {
        for (idx, p) in params.enumerated() {
            let col = Int32(idx + 1)
            if p.type == "int", let v = p.val as? Int {
                sqlite3_bind_int(statement, col, Int32(v))
            } else if p.type == "double", let v = p.val as? Double {
                sqlite3_bind_double(statement, col, v)
            } else if p.type == "text", let v = p.val as? String {
                sqlite3_bind_text(statement, col, v, -1, Self.sqliteTransient)
            }
        }
    }

    private static func mutingParameters(_ muting: MuteRules) -> [QueryParameter] {
        [("text", muting.sourceParameter), ("text", muting.topicParameter)]
    }

    /// Read, saved and section conditions shared by list pages and their muted counts.
    private func listConditions(section: String?, isRead: Bool?, isSaved: Bool?) -> (sql: String, params: [QueryParameter]) {
        var sql = ""
        var params: [QueryParameter] = []
        if let read = isRead {
            sql += " AND s.is_read = ?"
            params.append(("int", read ? 1 : 0))
        }
        if let saved = isSaved {
            sql += " AND s.is_saved = ?"
            params.append(("int", saved ? 1 : 0))
        }
        if let sec = section, !["Today", "Unread", "Saved Stories", "History"].contains(sec) {
            let terms = ArticleSection.keywords[sec] ?? [sec.lowercased()]
            sql += " AND (" + terms.map { _ in "instr(lower(a.title || ' ' || coalesce(a.description, '') || ' ' || coalesce(a.category, '')), ?) > 0" }.joined(separator: " OR ") + ")"
            params += terms.map { ("text", $0) }
        }
        return (sql, params)
    }

    /// The full-text join and operator conditions shared by search pages and their muted counts.
    private func searchConditions(_ parsed: ArticleFilterQuery) -> (join: String, sql: String, params: [QueryParameter]) {
        var join = " WHERE 1=1"
        var sql = ""
        var params: [QueryParameter] = []
        if !parsed.terms.isEmpty {
            join = " JOIN article_fts_rows f ON f.article_id = a.id JOIN articles_fts fts ON fts.rowid = f.fts_rowid WHERE articles_fts MATCH ?"
            // Sanitize FTS search term: wrap terms with quotes or escape special FTS characters
            let sanitizedFtsTerm = parsed.terms.map { term in
                let cleaned = term.replacingOccurrences(of: "\"", with: "")
                return "\"\(cleaned)\"*"
            }.joined(separator: " ")
            params.append(("text", sanitizedFtsTerm))
        }
        if let sf = parsed.sourceFilter {
            sql += " AND a.source LIKE ?"
            params.append(("text", "%\(sf)%"))
        }
        if let cf = parsed.categoryFilter {
            sql += " AND a.category LIKE ?"
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
        return (join, sql, params)
    }

    private struct FetchCriteria {
        var section: String?
        var isRead: Bool?
        var isSaved: Bool?
        var limit: Int?
        var after: ArticleQueryCursor?
        var id: String?
        var canonicalURL: String?
        var eventID: String?
        var includingOriginals: Bool
        var publicationWindow: ClosedRange<Date>?
        var muting: MuteRules
        var hidingWaitingStories: Bool
    }

    /// Builds the SQL query string and parameters for fetching articles based on criteria.
    private func buildFetchArticlesQuery(criteria: FetchCriteria) throws -> (sql: String, params: [QueryParameter]) {
        var query = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, coalesce(ae.category, a.category),
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment, a.reader_document, \(Self.articleDateOrder)
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        WHERE 1=1
        """

        if !criteria.includingOriginals { query += " AND " + Self.visibleArticle }
        var params: [QueryParameter] = []
        
        if let id = criteria.id {
            query += " AND a.id = ?"
            params.append(("text", criteria.includingOriginals ? id : try resolvedArticleID(id)))
        }
        if let canonicalURL = criteria.canonicalURL {
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
        if let eventID = criteria.eventID {
            query += " AND a.id IN (SELECT article_id FROM event_members WHERE event_id = ?)"
            params.append(("text", try resolvedEventID(eventID) ?? eventID))
        }
        if let publicationWindow = criteria.publicationWindow {
            query += " AND a.published_at >= ? AND a.published_at <= ?"
            params += [("double", publicationWindow.lowerBound.timeIntervalSince1970),
                       ("double", publicationWindow.upperBound.timeIntervalSince1970)]
        }
        let list = listConditions(section: criteria.section, isRead: criteria.isRead, isSaved: criteria.isSaved)
        query += list.sql
        params += list.params
        // Muting and waiting stories are predicates before LIMIT, so every page is full and cursors stay exact.
        if !criteria.muting.isEmpty {
            query += " AND NOT " + Self.mutedArticle
            params += Self.mutingParameters(criteria.muting)
        }
        if criteria.hidingWaitingStories { query += " AND NOT " + Self.waitingStory }
        if let after = criteria.after {
            query += " AND (\(Self.articleDateOrder) < ? OR (\(Self.articleDateOrder) = ? AND a.id > ?))"
            params += [("double", after.value), ("double", after.value), ("text", after.id)]
        }

        query += " ORDER BY \(Self.articleDateOrder) DESC, a.id"
        
        if let lim = criteria.limit {
            query += " LIMIT ?"
            params.append(("int", lim))
        }

        return (query, params)
    }

    // MARK: - Article Queries

    func fetchArticles(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        limit: Int? = 500,
        after: ArticleQueryCursor? = nil,
        id: String? = nil,
        canonicalURL: String? = nil,
        eventID: String? = nil,
        includingOriginals: Bool = false,
        publicationWindow: ClosedRange<Date>? = nil,
        muting: MuteRules = MuteRules(),
        hidingWaitingStories: Bool = false
    ) throws -> [FeedArticle] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        let criteria = FetchCriteria(
            section: section,
            isRead: isRead,
            isSaved: isSaved,
            limit: limit,
            after: after,
            id: id,
            canonicalURL: canonicalURL,
            eventID: eventID,
            includingOriginals: includingOriginals,
            publicationWindow: publicationWindow,
            muting: muting,
            hidingWaitingStories: hidingWaitingStories
        )
        let (query, params) = try buildFetchArticlesQuery(criteria: criteria)
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare fetch query: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        bind(params, to: stmt)
        
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
        
        return includingOriginals ? results : try curateImages(in: results)
    }
    
    // MARK: - Full Text Search (FTS5)
    
    private func buildSearchQuery(parsed: ArticleFilterQuery, muting: MuteRules, after: ArticleQueryCursor?, limit: Int) -> (sql: String, params: [QueryParameter]) {
        let cleanTerms = parsed.terms
        let hasFTS = !cleanTerms.isEmpty

        var sql = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, coalesce(ae.category, a.category),
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment, a.reader_document
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        """

        sql = sql.replacingOccurrences(of: "a.reader_document\n", with: "a.reader_document, " + (cleanTerms.isEmpty ? Self.articleDateOrder : "fts.rank") + "\n")
        let conditions = searchConditions(parsed)
        sql += conditions.join + " AND " + Self.visibleArticle + conditions.sql
        var params = conditions.params
        if !muting.isEmpty {
            sql += " AND NOT " + Self.mutedArticle
            params += Self.mutingParameters(muting)
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

        return (sql, params)
    }

    func searchArticles(
        query: String,
        limit: Int = 100,
        after: ArticleQueryCursor? = nil,
        muting: MuteRules = MuteRules()
    ) throws -> [FeedArticle] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parsed = ArticleFilterQuery.parse(trimmed)
        let (sql, params) = buildSearchQuery(parsed: parsed, muting: muting, after: after, limit: limit)
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare FTS search query: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        bind(params, to: stmt)
        
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
        return try curateImages(in: results)
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
            let resolvedIds = try resolvedArticleIDs(articleIds)
            for articleId in resolvedIds {
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
            let resolvedIDs = try resolvedArticleIDs(Array(articleIds))
            for articleId in resolvedIDs {
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

    private func curateImages(in articles: [FeedArticle]) throws -> [FeedArticle] {
        var repeatedBySource = [String: Set<String>]()
        let curated = try articles.map { original in
            try Task.checkCancellation()
            var article = original
            guard article.imageUrl != nil || article.readerDocument?.images?.isEmpty == false else { return article }
            let repeated: Set<String>
            if let known = repeatedBySource[article.source] { repeated = known }
            else {
                repeated = try repeatedImageURLs(source: article.source)
                repeatedBySource[article.source] = repeated
            }
            if let document = article.readerDocument, document.version >= 4 {
                article.readerDocument = document.curated(feedImage: nil, title: article.title, excluding: repeated)
                article.imageUrl = article.readerDocument?.leadImageURL
            } else if let url = article.imageUrl, repeated.contains(url) || !ReaderImageCandidate.usable(url: url) {
                article.imageUrl = nil
            }
            return article
        }
        let found = try storyImages(for: curated.filter { $0.imageUrl == nil }.map(\.id))
        return curated.map { original in
            var article = original
            if article.imageUrl == nil { article.imageUrl = found[article.id] }
            return article
        }
    }

    // ponytail: flag three distinct documents, return at most 64 recurring URLs per publisher.
    // This rejects repeated furniture heuristically; a publisher-specific allowlist needs corpus evidence.
    /// Recurrence is publisher-local and counts distinct documents, not GUID copies.
    func repeatedImageURLs(source: String) throws -> Set<String> {
        let sql = """
        SELECT url FROM (
            SELECT image_url AS url, canonical_url FROM articles WHERE source = ?
            UNION
            SELECT json_extract(j.value, '$.url'), a.canonical_url FROM articles a,
                json_each(CASE WHEN json_valid(a.reader_document) THEN a.reader_document ELSE '{}' END, '$.images') j
                WHERE a.source = ?
        ) WHERE url IS NOT NULL AND canonical_url IS NOT NULL
        GROUP BY url HAVING count(DISTINCT canonical_url) >= 3 ORDER BY count(DISTINCT canonical_url) DESC, url LIMIT 64;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher image recurrence"])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, source, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, source, -1, Self.sqliteTransient)
        var urls = Set<String>()
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) { urls.insert(String(cString: text)) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read publisher image recurrence"])
        }
        return urls
    }

    func publisherContentRevisions(for articleID: String) throws -> [PublisherContentRevision] {
        let id = try resolvedArticleID(articleID)
        return try eventRows("SELECT version, observed_at, kind, changed_fields, input_text_hash FROM publisher_content_revisions WHERE article_id = ? ORDER BY version DESC LIMIT 20;", [.text(id)]).compactMap { row in
            guard let version = row[0].flatMap(Int.init), let timestamp = row[1].flatMap(Double.init),
                  let kind = row[2].flatMap(PublisherContentRevision.Kind.init(rawValue:)),
                  let fields = row[3].flatMap(Int.init), let hash = row[4] else { return nil }
            return PublisherContentRevision(version: version, observedAt: Date(timeIntervalSince1970: timestamp),
                                            kind: kind, changedFields: fields, inputHash: hash)
        }
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
        var expectedInputHash: String? = nil
    }

    @discardableResult
    func updateEnrichment(articleId: String, update: EnrichmentUpdate) throws -> Bool {
        let articleId = try resolvedArticleID(articleId)
        if let expected = update.expectedInputHash {
            guard try fetchArticles(limit: 1, id: articleId).first?.publisherInputHash == expected else { return false }
        }
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
            if let document = readerDocument, document.version >= 4 {
                if let selected = document.leadImageURL {
                    updates.append("image_url = ?")
                    params.append(("text", selected))
                } else { updates.append("image_url = NULL") }
            } else if let img = image {
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
        return true
    }

    /// Persists structured ArticleAnalysis into article_enrichment.
    @discardableResult
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String, expectedInputHash: String? = nil) throws -> Bool {
        let articleId = try resolvedArticleID(articleId)
        guard let article = try fetchArticles(limit: 1, id: articleId).first else { return false }
        let inputHash = article.publisherInputHash
        if let expectedInputHash, expectedInputHash != inputHash { return false }
        let inputVersion = try publisherContentRevisions(for: articleId).first?.version ?? 1
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        let sql = """
        INSERT INTO article_enrichment (
            article_id, summary, key_points, category, confidence, sentiment, entities, model_identifier, analysis_version, enriched_at, content_fetched, input_content_version, input_text_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
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
            content_fetched = 1,
            input_content_version = excluded.input_content_version,
            input_text_hash = excluded.input_text_hash;
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
        sqlite3_bind_int(stmt, 11, Int32(inputVersion))
        sqlite3_bind_text(stmt, 12, inputHash, -1, Self.sqliteTransient)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Step failed: \(msg)"])
        }
        return true
    }

    /// Fetches persisted ArticleAnalysis for an article (if previously analyzed).
    func fetchArticleAnalysis(for articleId: String) -> ArticleAnalysis? {
        guard let db = db, let articleId = try? resolvedArticleID(articleId) else { return nil }
        let sql = """
        SELECT summary, key_points, category, sentiment, entities, model_identifier, analysis_version
        FROM article_enrichment
        WHERE article_id = ? AND summary IS NOT NULL AND input_text_hash = ?
            AND input_content_version = (SELECT max(version) FROM publisher_content_revisions WHERE article_id = ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard let article = try? fetchArticles(limit: 1, id: articleId).first else { return nil }
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, article.publisherInputHash, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, articleId, -1, Self.sqliteTransient)
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
            try pruneEmptyEvents()
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
    
    /// How many stories muting removes from a list or search, across every page, under the list's own filters.
    func mutedArticleCount(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        search: String? = nil,
        muting: MuteRules
    ) throws -> Int {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !muting.isEmpty else { return 0 }
        var sql = "SELECT count(*) FROM articles a JOIN article_state s ON s.article_id = a.id"
        var params: [QueryParameter]
        let searchText = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if searchText.isEmpty {
            let conditions = listConditions(section: section, isRead: isRead, isSaved: isSaved)
            sql += " WHERE " + Self.visibleArticle + conditions.sql
            params = conditions.params
        } else {
            let conditions = searchConditions(ArticleFilterQuery.parse(searchText))
            sql += conditions.join + " AND " + Self.visibleArticle + conditions.sql
            params = conditions.params
        }
        sql += " AND " + Self.mutedArticle
        params += Self.mutingParameters(muting)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare muted count: \(String(cString: sqlite3_errmsg(db)))"])
        }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Story Visibility

    /// Stories a list hides while they wait for more coverage, under the list's own filters and muting.
    func waitingStoryCount(section: String? = nil, isRead: Bool? = nil, isSaved: Bool? = nil, muting: MuteRules = MuteRules()) throws -> Int {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        let conditions = listConditions(section: section, isRead: isRead, isSaved: isSaved)
        var sql = "SELECT count(*) FROM articles a JOIN article_state s ON s.article_id = a.id WHERE "
            + Self.visibleArticle + conditions.sql + " AND " + Self.waitingStory
        var params = conditions.params
        if !muting.isEmpty {
            sql += " AND NOT " + Self.mutedArticle
            params += Self.mutingParameters(muting)
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare waiting count: \(String(cString: sqlite3_errmsg(db)))"])
        }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Recent stories without an importance rating, best-covered and newest first.
    func pendingImportanceRows(activeSince: Date, limit: Int) throws -> [EventMatchRow] {
        try eventMatchRows("""
        \(Self.eventMatchColumns)
        WHERE NOT EXISTS (SELECT 1 FROM story_importance i WHERE i.article_id = a.id)
            AND \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle)
        ORDER BY (SELECT count(*) FROM event_members peer WHERE peer.event_id = m.event_id) DESC, \(Self.articleDateOrder) DESC, a.id
        LIMIT ?;
        """, [.real(activeSince.timeIntervalSince1970), .integer(limit)])
    }

    /// Recent visible stories rated at `level`, newest first: the population of the independent importance review (#309).
    func ratedImportanceRows(level: StoryImportance, activeSince: Date) throws -> [EventMatchRow] {
        try eventMatchRows("""
        \(Self.eventMatchColumns)
        WHERE EXISTS (SELECT 1 FROM story_importance i WHERE i.article_id = a.id AND i.level = ?)
            AND \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle)
        ORDER BY \(Self.articleDateOrder) DESC, a.id;
        """, [.integer(level.rawValue), .real(activeSince.timeIntervalSince1970)])
    }

    @discardableResult
    func recordImportance(_ articleID: String, _ importance: StoryImportance, at date: Date = Date(),
                          expectedTitle: String? = nil, expectedDescription: String? = nil) throws -> Bool {
        let title: EventValue = .text(expectedTitle ?? "")
        let description: EventValue = .text(expectedDescription ?? "")
        try eventRows("""
        INSERT INTO story_importance(article_id, level, judged_at)
        SELECT id, ?, ? FROM articles WHERE id = ?
            AND (? = 0 OR title IS ?) AND (? = 0 OR coalesce(description, '') IS ?)
        ON CONFLICT(article_id) DO UPDATE SET level = excluded.level, judged_at = excluded.judged_at;
        """, [.integer(importance.rawValue), .real(date.timeIntervalSince1970), .text(articleID),
              .integer(expectedTitle == nil ? 0 : 1), title, .integer(expectedDescription == nil ? 0 : 1), description])
        return sqlite3_changes(db) > 0
    }

    /// Committed stories eligible for notification after curation; expired or waiting stories are excluded.
    func notificationStoryIDs(_ articleIDs: [String]) throws -> Set<String> {
        var eligible = Set<String>()
        for start in stride(from: 0, to: articleIDs.count, by: 500) {
            let ids = Array(articleIDs[start..<min(start + 500, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try eventRows("SELECT a.id FROM articles a WHERE a.id IN (\(placeholders)) AND \(Self.visibleArticle) AND NOT \(Self.waitingStory);",
                                    ids.map { .text($0) })
            eligible.formUnion(rows.compactMap { $0[0] })
        }
        return eligible
    }

    /// Deletes stories that waited longer than `minorStoryLifetime` (counted from the first report of their event) and
    /// remembers their IDs and document URLs, so feeds that still list them do not bring them back. Saved, read and cited
    /// stories stay, and so do stories delivered by `keepingFeedURLs` (the tension panel while collection is on, whose
    /// past days are rebuilt from stored articles). Forgets expiries after `expiryMemory`. Returns the number removed.
    @discardableResult
    func expireWaitingStories(now: Date = Date(), keepingFeedURLs: [String] = []) throws -> Int {
        let cutoff = now.timeIntervalSince1970 - StoryVisibilityPolicy.minorStoryLifetime
        let kept = Array(repeating: "?", count: keepingFeedURLs.count).joined(separator: ", ")
        let expired = """
        SELECT a.id FROM articles a JOIN article_state s ON s.article_id = a.id
        WHERE s.is_read = 0 AND s.is_saved = 0 AND \(Self.visibleArticle) AND \(Self.waitingStory)
            AND coalesce((SELECT min(x.created_at) FROM event_members m JOIN event_members peer ON peer.event_id = m.event_id
                JOIN articles x ON x.id = peer.article_id WHERE m.article_id = a.id), a.created_at) < ?
            AND NOT EXISTS (SELECT 1 FROM event_overview_citations c WHERE c.article_id = a.id)
            AND NOT EXISTS (SELECT 1 FROM article_feeds af WHERE af.article_id = a.id AND af.feed_url IN (\(kept)))
        """
        let expiredValues: [EventValue] = [.real(cutoff)] + keepingFeedURLs.map { .text($0) }
        let removed = try inEventTransaction { () throws -> Int in
            let rows = try eventRows("""
            SELECT id, canonical_url FROM articles WHERE id IN (\(expired)
                UNION SELECT r.duplicate_id FROM article_reconciliations r WHERE r.survivor_id IN (\(expired)));
            """, expiredValues + expiredValues)
            for row in rows {
                for key in [row[0], row[1].flatMap { Self.isDocumentURL($0) ? $0 : nil }].compactMap({ $0 }) {
                    try eventRows("INSERT OR REPLACE INTO expired_stories(key, expired_at) VALUES (?, ?);",
                                  [.text(key), .real(now.timeIntervalSince1970)])
                }
                if let id = row[0] { try eventRows("DELETE FROM articles WHERE id = ?;", [.text(id)]) }
            }
            try eventRows("DELETE FROM expired_stories WHERE expired_at < ?;",
                          [.real(now.timeIntervalSince1970 - StoryVisibilityPolicy.expiryMemory)])
            return rows.count
        }
        if removed > 0 { try pruneEmptyEvents() }
        return removed
    }

    // MARK: - Story Images

    /// Shown, recent stories without any image in their event and not looked up yet: clustered stories first, then the
    /// newest. Each row carries its event so a pass looks up one report per event.
    func imagelessStoryRows(activeSince: Date, limit: Int, muting: MuteRules = MuteRules()) throws -> [(id: String, link: String, eventID: String?)] {
        // ponytail: at most 2,000 recent candidates per pass, matching the clustering bound.
        let rows = try eventRows("""
        SELECT a.id, a.canonical_url, m.event_id FROM articles a
        LEFT JOIN event_members m ON m.article_id = a.id
        WHERE \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle) AND NOT \(Self.waitingStory)
            AND NOT \(Self.mutedArticle)
            AND NOT EXISTS (SELECT 1 FROM story_images si WHERE si.article_id = a.id)
        ORDER BY (SELECT count(*) FROM event_members peer WHERE peer.event_id = m.event_id) DESC, \(Self.articleDateOrder) DESC, a.id
        LIMIT 2000;
        """, [.real(activeSince.timeIntervalSince1970), .text(muting.sourceParameter), .text(muting.topicParameter)])
        var results: [(id: String, link: String, eventID: String?)] = []
        var picturedEvents: [String: Bool] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard results.count < limit else { break }
            guard let id = row[0], let link = row[1] else { continue }
            let key = row[2] ?? id
            let pictured: Bool
            if let cached = picturedEvents[key] { pictured = cached }
            else {
                let members = try fetchArticles(limit: nil, id: row[2] == nil ? id : nil, eventID: row[2])
                pictured = FeedArticle.bestCardImage(in: members) != nil
                picturedEvents[key] = pictured
            }
            if !pictured { results.append((id, link, row[2])) }
        }
        return results
    }

    /// Records a looked-up page: its lead image, or nil when it has none. An image another story already declared is a
    /// site default (a brand card), not a lead: it is cleared for both and remembered, so no later story keeps it.
    /// Returns whether an image was stored.
    @discardableResult
    func recordStoryImage(_ articleID: String, imageURL: String?, at date: Date = Date(), expectedLink: String? = nil) throws -> Bool {
        try inEventTransaction { () throws -> Bool in
            if let expectedLink, (try eventRows("SELECT canonical_url FROM articles WHERE id = ?;", [.text(articleID)])).first?[0] != expectedLink {
                return false
            }
            var image = imageURL
            if let url = imageURL, !(try eventRows("""
                SELECT 1 FROM story_image_defaults WHERE url = ?1
                UNION ALL SELECT 1 FROM story_images WHERE image_url = ?1 AND article_id != ?2 LIMIT 1;
                """, [.text(url), .text(articleID)])).isEmpty {
                try eventRows("INSERT OR IGNORE INTO story_image_defaults(url) VALUES (?);", [.text(url)])
                try eventRows("UPDATE story_images SET image_url = NULL WHERE image_url = ?;", [.text(url)])
                image = nil
            }
            try eventRows("INSERT OR REPLACE INTO story_images(article_id, image_url, checked_at) VALUES (?, ?, ?);",
                          [.text(articleID), image.map { .text($0) } ?? .null, .real(date.timeIntervalSince1970)])
            return image != nil
        }
    }

    /// Found lead images by article ID.
    func storyImages(for articleIDs: [String]) throws -> [String: String] {
        guard !articleIDs.isEmpty else { return [:] }
        var images: [String: String] = [:]
        for chunk in stride(from: 0, to: articleIDs.count, by: 500).map({ Array(articleIDs[$0..<min($0 + 500, articleIDs.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try eventRows("SELECT article_id, image_url FROM story_images WHERE image_url IS NOT NULL AND article_id IN (\(placeholders));",
                                     chunk.map { .text($0) }) {
                if let id = row[0], let url = row[1] { images[id] = url }
            }
        }
        return images
    }

    /// Stored stories each muting rule covers, for the muting settings. One pass over the library.
    func mutedRuleCounts(_ rules: MuteRules) throws -> MuteRuleCounts {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        var counts = MuteRuleCounts()
        guard !rules.isEmpty else { return counts }
        let sql = "SELECT a.canonical_url, a.title, coalesce(a.description, '') FROM articles a WHERE \(Self.visibleArticle);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare muting counts"])
        }
        defer { sqlite3_finalize(stmt) }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
        }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            for source in rules.matchedSources(link: text(0)) { counts.sources[source, default: 0] += 1 }
            for topic in rules.matchedTopics(title: text(1), description: text(2)) { counts.topics[topic, default: 0] += 1 }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return counts
    }

    /// Stored articles a set of feeds delivered with a publication date inside `day`, with their event, for the news
    /// tension experiment. One row per article and delivering feed; undated stories never fall inside a day.
    func tensionCorpus(day: DateInterval, feedURLs: [String]) throws -> [TensionCorpusRow] {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }
        guard !feedURLs.isEmpty else { return [] }
        let sql = """
        SELECT a.id, a.guid, a.canonical_url, a.title, a.description, a.content,
               a.published_at, a.source, a.image_url, coalesce(ae.category, a.category),
               ae.summary, ae.content_fetched,
               s.is_read, s.is_saved,
               ae.key_points, ae.entities, ae.sentiment, a.reader_document, af.feed_url, em.event_id
        FROM articles a
        JOIN article_state s ON s.article_id = a.id
        JOIN article_feeds af ON af.article_id = a.id
        LEFT JOIN article_enrichment ae ON ae.article_id = a.id
        LEFT JOIN event_members em ON em.article_id = a.id
        WHERE af.feed_url IN (\(Array(repeating: "?", count: feedURLs.count).joined(separator: ", ")))
          AND a.published_at >= ? AND a.published_at < ? AND \(Self.visibleArticle)
        ORDER BY a.published_at, a.id, af.feed_url;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare tension corpus: \(String(cString: sqlite3_errmsg(db)))"])
        }
        defer { sqlite3_finalize(stmt) }
        var params: [QueryParameter] = feedURLs.map { ("text", $0) }
        params += [("double", day.start.timeIntervalSince1970), ("double", day.end.timeIntervalSince1970)]
        bind(params, to: stmt)
        var rows: [TensionCorpusRow] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            if let article = parseArticleRow(stmt), let feedURL = sqlite3_column_text(stmt, 18).map({ String(cString: $0) }) {
                rows.append(TensionCorpusRow(article: article, feedURL: feedURL,
                                             eventID: sqlite3_column_text(stmt, 19).map { String(cString: $0) }))
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(domain: "DatabaseEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return rows
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

    /// Records an event overview only after deterministic verification of claims.
    /// If verification fails, converts the overview to a safe fallback excerpts document
    /// and stores that instead, guaranteeing a failed retelling is never stored as finished synthesized overview.
    func recordVerifiedOverview(
        _ overview: EventOverviewDocument,
        passages: [EvidencePassage],
        articles: [FeedArticle]
    ) throws -> (saved: Bool, document: EventOverviewDocument) {
        let report = OverviewClaimVerifier.verifyOverview(overview, passages: passages, articles: articles)
        let documentToStore: EventOverviewDocument
        if report.isFullyVerified {
            documentToStore = overview
        } else {
            documentToStore = OverviewClaimVerifier.createFallbackOverview(
                from: overview,
                passages: passages,
                articles: articles,
                report: report
            )
        }
        let saved = try recordEventOverview(documentToStore)
        return (saved: saved, document: documentToStore)
    }

    @discardableResult
    func recordEventOverview(_ overview: EventOverviewDocument, expectedArticleInputs: [String: String]? = nil) throws -> Bool {
        guard let db = db else { throw NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }

        if let expectedArticleInputs {
            for (id, hash) in expectedArticleInputs {
                guard try fetchArticles(limit: 1, id: id).first?.publisherInputHash == hash else { return false }
            }
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
        let factsJSON: String
        if let evidence = overview.content.evidenceSections, !evidence.isEmpty {
            struct OverviewFactsEnvelope: Codable {
                let facts: [OverviewFact]
                let evidenceSections: OverviewEvidenceSections?
            }
            let envelope = OverviewFactsEnvelope(facts: overview.facts, evidenceSections: evidence)
            factsJSON = String(decoding: try encoder.encode(envelope), as: UTF8.self)
        } else {
            factsJSON = String(decoding: try encoder.encode(overview.facts), as: UTF8.self)
        }
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
            // Citation IDs are unique within one overview only (`cite_<passage>_<n>`), so the row key carries the
            // overview ID: another event citing the same passage must not collide with this one.
            sqlite3_bind_text(citationStmt, 1, Self.citationRowID(overviewID: overview.id, citationID: citation.id), -1, Self.sqliteTransient)
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
        var facts: [OverviewFact] = []
        var evidenceSections: OverviewEvidenceSections?
        let trimmedFacts = factsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFacts.hasPrefix("{") {
            struct OverviewFactsEnvelope: Codable {
                let facts: [OverviewFact]
                let evidenceSections: OverviewEvidenceSections?
            }
            if let envelope = try? decoder.decode(OverviewFactsEnvelope.self, from: Data(factsJSON.utf8)) {
                facts = envelope.facts
                evidenceSections = envelope.evidenceSections
            }
        } else {
            facts = (try? decoder.decode([OverviewFact].self, from: Data(factsJSON.utf8))) ?? []
        }
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
            let citID = Self.citationID(fromRowID: String(cString: sqlite3_column_text(citationStmt, 0)), overviewID: id)
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
                leadImage: leadImage,
                evidenceSections: evidenceSections
            ),
            provenance: OverviewProvenance(
                memberArticleIDs: memberArticleIDs,
                kind: kind,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )
    }

    static func citationRowID(overviewID: String, citationID: String) -> String {
        overviewID + "|" + citationID
    }

    /// Rows stored before overview-scoped keys carry the bare citation ID and are read unchanged.
    static func citationID(fromRowID rowID: String, overviewID: String) -> String {
        let prefix = overviewID + "|"
        return rowID.hasPrefix(prefix) ? String(rowID.dropFirst(prefix.count)) : rowID
    }

    /// Resolves the event overview associated with a given article ID (via event membership or citations).
    func fetchEventOverview(forArticleID articleID: String) throws -> EventOverviewDocument? {
        if let eventID = try eventID(forArticle: articleID),
           let overview = try fetchEventOverview(eventID: eventID) {
            return overview
        }

        // Fallback: check overview citations for direct article attribution
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        let sql = """
        SELECT o.event_id FROM event_overview_citations c
        JOIN event_overviews o ON o.id = c.overview_id
        WHERE c.article_id = ? LIMIT 1;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, articleID, -1, Self.sqliteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW, let eventIDText = sqlite3_column_text(stmt, 0) {
            let eventID = String(cString: eventIDText)
            return try fetchEventOverview(eventID: eventID)
        }
        return nil
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

    // MARK: - Events

    private enum EventValue {
        case text(String), integer(Int), real(Double), null
    }

    private static func eventError(_ message: String) -> NSError {
        NSError(domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Runs one statement and returns its rows as text columns (NULL as nil).
    @discardableResult
    private func eventRows(_ sql: String, _ values: [EventValue] = []) throws -> [[String?]] {
        guard let db = db else { throw Self.eventError("Database not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.eventError("Cannot prepare event statement: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.sqliteTransient)
            case .integer(let number): sqlite3_bind_int64(statement, position, Int64(number))
            case .real(let number): sqlite3_bind_double(statement, position, number)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw Self.eventError("Cannot execute event statement: \(String(cString: sqlite3_errmsg(db)))")
        }
        return rows
    }

    private func inEventTransaction<T>(_ body: () throws -> T) throws -> T {
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { try? rollbackTransaction() }
        }
        let result = try body()
        try commitTransaction()
        return result
    }

    /// When the on-device model generation differs from the one that produced stored results, every overview and
    /// article summary is marked provisional (analysis version 0), so each is regenerated with the current model the
    /// next time it is requested. Importance ratings and event memberships are decisions already applied to the
    /// library and stay. Returns whether stored results were invalidated.
    @discardableResult
    func reconcileModelGeneration(_ current: String) throws -> Bool {
        try inEventTransaction { () throws -> Bool in
            guard try eventRows("SELECT value FROM model_generation WHERE id = 1;").first?[0] != current else { return false }
            try eventRows("UPDATE event_overviews SET analysis_version = 0;")
            try eventRows("UPDATE article_enrichment SET analysis_version = 0 WHERE summary IS NOT NULL;")
            try eventRows("INSERT OR REPLACE INTO model_generation(id, value) VALUES (1, ?);", [.text(current)])
            return true
        }
    }

    /// The live event an ID refers to, following merge forwards; nil once the event is gone.
    func resolvedEventID(_ id: String) throws -> String? {
        var current = id
        var visited = Set<String>()
        while visited.insert(current).inserted {
            guard let row = try eventRows("SELECT merged_into FROM events WHERE id = ?;", [.text(current)]).first else { return nil }
            guard let next = row[0] else { return current }
            current = next
        }
        return nil
    }

    func fetchEvent(id: String) throws -> StoryEvent? {
        guard let live = try resolvedEventID(id),
              let row = try eventRows("SELECT membership_version, created_at, updated_at FROM events WHERE id = ?;", [.text(live)]).first else {
            return nil
        }
        let members = try eventRows("SELECT article_id FROM event_members WHERE event_id = ? ORDER BY article_id;", [.text(live)]).compactMap { $0[0] }
        return StoryEvent(
            id: live,
            membershipVersion: row[0].flatMap { Int($0) } ?? 1,
            memberArticleIDs: members,
            createdAt: Date(timeIntervalSince1970: row[1].flatMap { Double($0) } ?? 0),
            updatedAt: Date(timeIntervalSince1970: row[2].flatMap { Double($0) } ?? 0)
        )
    }

    /// The event that currently holds an article; old article IDs resolve to the stored document.
    func eventID(forArticle articleID: String) throws -> String? {
        guard let member = try memberArticleID(articleID) else { return nil }
        return try eventRows("SELECT event_id FROM event_members WHERE article_id = ?;", [.text(member)]).first?[0]
    }

    /// Creates an event with a new stable ID. Articles already in another event move here.
    @discardableResult
    func createEvent(memberArticleIDs articleIDs: [String], at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            try insertEvent(members: try resolvedMembers(articleIDs), at: date.timeIntervalSince1970)
        }
        return try requireEvent(id)
    }

    @discardableResult
    func addArticles(_ articleIDs: [String], toEvent eventID: String, at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let target = try liveEvent(eventID)
            let now = date.timeIntervalSince1970
            if try assignMembers(try resolvedMembers(articleIDs), to: target.id, joinedVersion: target.version + 1, at: now) {
                try bumpMembershipVersion(target.id, at: now)
            }
            return target.id
        }
        return try requireEvent(id)
    }

    /// Removes articles from an event. An event left empty keeps its ID until retention drops it.
    @discardableResult
    func removeArticles(_ articleIDs: [String], fromEvent eventID: String, at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let target = try liveEvent(eventID)
            var changed = false
            for member in try resolvedMembers(articleIDs) {
                try eventRows("DELETE FROM event_members WHERE article_id = ? AND event_id = ?;", [.text(member), .text(target.id)])
                if sqlite3_changes(db) > 0 { changed = true }
            }
            if changed { try bumpMembershipVersion(target.id, at: date.timeIntervalSince1970) }
            return target.id
        }
        return try requireEvent(id)
    }

    /// Moves every member of `absorbedID` into `survivorID`. The absorbed ID forwards to the survivor,
    /// so stored links keep resolving; article rows and their read/save state are untouched.
    @discardableResult
    /// With `expectedVersions`, the merge is refused if either event changed since the caller read it.
    func mergeEvents(_ absorbedID: String, into survivorID: String, expectedVersions: (absorbed: Int, survivor: Int)? = nil,
                     at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let survivor = try liveEvent(survivorID)
            let absorbed = try liveEvent(absorbedID)
            guard absorbed.id != survivor.id else { return survivor.id }
            if let expectedVersions, expectedVersions.absorbed != absorbed.version || expectedVersions.survivor != survivor.version {
                throw Self.eventError("An event changed before it could be merged")
            }
            let now = date.timeIntervalSince1970
            try eventRows("UPDATE event_members SET event_id = ?, joined_version = ? WHERE event_id = ?;",
                          [.text(survivor.id), .integer(survivor.version + 1), .text(absorbed.id)])
            let moved = sqlite3_changes(db) > 0
            // Forwards stay one hop deep.
            try eventRows("UPDATE events SET merged_into = ? WHERE merged_into = ?;", [.text(survivor.id), .text(absorbed.id)])
            try eventRows("UPDATE events SET merged_into = ?, membership_version = membership_version + 1, updated_at = ? WHERE id = ?;",
                          [.text(survivor.id), .real(now), .text(absorbed.id)])
            if moved { try bumpMembershipVersion(survivor.id, at: now) }
            return survivor.id
        }
        return try requireEvent(id)
    }

    /// Moves some members into a new event with its own stable ID. The original keeps its ID and the
    /// remaining members; both member sets stay non-empty.
    @discardableResult
    func splitEvent(_ eventID: String, movingArticles articleIDs: [String], at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let source = try liveEvent(eventID)
            let moving = try resolvedMembers(articleIDs)
            let current = Set(try eventRows("SELECT article_id FROM event_members WHERE event_id = ?;", [.text(source.id)]).compactMap { $0[0] })
            guard !moving.isEmpty, Set(moving).isSubset(of: current), moving.count < current.count else {
                throw Self.eventError("A split moves some, but not all, members of the event")
            }
            return try insertEvent(members: moving, at: date.timeIntervalSince1970)
        }
        return try requireEvent(id)
    }

    private func requireEvent(_ id: String) throws -> StoryEvent {
        guard let event = try fetchEvent(id: id) else { throw Self.eventError("Unknown event") }
        return event
    }

    private func liveEvent(_ id: String) throws -> (id: String, version: Int) {
        guard let live = try resolvedEventID(id),
              let version = try eventRows("SELECT membership_version FROM events WHERE id = ?;", [.text(live)]).first?[0].flatMap({ Int($0) }) else {
            throw Self.eventError("Unknown event")
        }
        return (live, version)
    }

    private func insertEvent(members: [String], at now: Double) throws -> String {
        guard !members.isEmpty else { throw Self.eventError("An event needs at least one article") }
        let id = UUID().uuidString
        try eventRows("INSERT INTO events(id, membership_version, created_at, updated_at) VALUES (?, 1, ?, ?);",
                      [.text(id), .real(now), .real(now)])
        _ = try assignMembers(members, to: id, joinedVersion: 1, at: now)
        return id
    }

    /// Membership references the surviving stored document, never an alias or a reconciled copy.
    private func memberArticleID(_ id: String) throws -> String? {
        var resolved = try resolvedArticleID(id)
        if let survivor = try eventRows("SELECT survivor_id FROM article_reconciliations WHERE duplicate_id = ?;", [.text(resolved)]).first?[0] {
            resolved = survivor
        }
        return try eventRows("SELECT 1 FROM articles WHERE id = ?;", [.text(resolved)]).isEmpty ? nil : resolved
    }

    private func resolvedMembers(_ articleIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        var members: [String] = []
        for articleID in articleIDs {
            guard let member = try memberArticleID(articleID) else { throw Self.eventError("Unknown event member article") }
            if seen.insert(member).inserted { members.append(member) }
        }
        return members
    }

    /// Moves members into `eventID`; every event that loses an article gains one membership version.
    /// Returns whether the target's member set changed.
    private func assignMembers(_ members: [String], to eventID: String, joinedVersion: Int, at now: Double) throws -> Bool {
        var losing = Set<String>()
        var changed = false
        for member in members {
            try Task.checkCancellation()
            let previous = try eventRows("SELECT event_id FROM event_members WHERE article_id = ?;", [.text(member)]).first?[0]
            if previous == eventID { continue }
            if let previous { losing.insert(previous) }
            try eventRows("""
            INSERT INTO event_members(article_id, event_id, joined_version) VALUES (?, ?, ?)
            ON CONFLICT(article_id) DO UPDATE SET event_id = excluded.event_id, joined_version = excluded.joined_version;
            """, [.text(member), .text(eventID), .integer(joinedVersion)])
            changed = true
        }
        for event in losing {
            try bumpMembershipVersion(event, at: now)
        }
        return changed
    }

    private func bumpMembershipVersion(_ eventID: String, at now: Double) throws {
        try eventRows("UPDATE events SET membership_version = membership_version + 1, updated_at = ? WHERE id = ?;",
                      [.real(now), .text(eventID)])
    }

    /// Event-matching candidates: FTS hits within `window` of `date`, best ranked first and capped at
    /// `limit`. Hidden reconciled copies, `articleID` itself and members of events unchanged since
    /// `activeSince` are excluded, so closed events never grow.
    func eventCandidateRows(
        matching query: String, around date: Date, window: TimeInterval,
        activeSince: Date, excluding articleID: String, limit: Int
    ) throws -> [(id: String, title: String, description: String, eventID: String?)] {
        let sql = """
        SELECT a.id, a.title, coalesce(a.description, ''), m.event_id
        FROM articles_fts fts
        JOIN article_fts_rows f ON f.fts_rowid = fts.rowid
        JOIN articles a ON a.id = f.article_id
        LEFT JOIN event_members m ON m.article_id = a.id
        LEFT JOIN events e ON e.id = m.event_id
        WHERE articles_fts MATCH ? AND a.id != ?
            AND \(Self.articleDateOrder) BETWEEN ? AND ?
            AND \(Self.visibleArticle)
            AND (m.event_id IS NULL OR e.updated_at >= ?)
        ORDER BY fts.rank, a.id
        LIMIT ?;
        """
        let center = date.timeIntervalSince1970
        return try eventRows(sql, [.text(query), .text(articleID), .real(center - window), .real(center + window),
                                   .real(activeSince.timeIntervalSince1970), .integer(limit)]).compactMap { row in
            guard let id = row[0], let title = row[1] else { return nil }
            return (id: id, title: title, description: row[2] ?? "", eventID: row[3])
        }
    }

    // MARK: - Event Matching

    private static let eventMatchColumns = """
    SELECT a.id, a.title, coalesce(a.description, ''), a.source, \(DatabaseEngine.articleDateOrder), m.event_id,
        ms.article_id IS NOT NULL
    FROM articles a
    LEFT JOIN event_members m ON m.article_id = a.id
    LEFT JOIN event_match_state ms ON ms.article_id = a.id
    """

    private func eventMatchRows(_ sql: String, _ values: [EventValue]) throws -> [EventMatchRow] {
        try eventRows(sql, values).compactMap { row in
            guard let id = row[0], let title = row[1] else { return nil }
            return EventMatchRow(id: id, title: title, description: row[2] ?? "", source: row[3] ?? "",
                                 date: Date(timeIntervalSince1970: row[4].flatMap { Double($0) } ?? 0), eventID: row[5],
                                 previouslyMatched: row[6] == "1")
        }
    }

    /// Visible articles dated after `activeSince` that the current matcher has not processed, oldest
    /// first. Older articles are never matched again, so the archive is not recomputed. Rows pending
    /// only because an older matcher processed them report `previouslyMatched`.
    func pendingEventMatchRows(activeSince: Date, matcherVersion: Int, limit: Int) throws -> [EventMatchRow] {
        try eventMatchRows("""
        \(Self.eventMatchColumns)
        WHERE (ms.article_id IS NULL OR ms.matcher_version < ?)
            AND \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle)
        ORDER BY \(Self.articleDateOrder), a.id
        LIMIT ?;
        """, [.integer(matcherVersion), .real(activeSince.timeIntervalSince1970), .integer(limit)])
    }

    func eventMatchRows(articleIDs: [String]) throws -> [EventMatchRow] {
        var rows: [EventMatchRow] = []
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            rows += try eventMatchRows("\(Self.eventMatchColumns) WHERE a.id IN (\(placeholders));", slice.map { .text($0) })
        }
        return rows
    }

    /// The live event, its membership version and its members, for a whole-event check.
    func eventMatchMembers(eventID: String) throws -> (id: String, version: Int, members: [EventMatchRow])? {
        guard let live = try? liveEvent(eventID) else { return nil }
        let members = try eventMatchRows("\(Self.eventMatchColumns) WHERE m.event_id = ?;", [.text(live.id)])
        return (live.id, live.version, members)
    }

    /// Every live event updated since `activeSince`, with its members, for merging fragments of one story.
    func activeEventMembers(since activeSince: Date) throws -> [(id: String, version: Int, members: [EventMatchRow])] {
        let since = activeSince.timeIntervalSince1970
        let versions = try eventRows("SELECT id, membership_version FROM events WHERE merged_into IS NULL AND updated_at >= ? ORDER BY id;",
                                     [.real(since)])
        let rows = try eventMatchRows("""
        \(Self.eventMatchColumns)
        JOIN events e ON e.id = m.event_id
        WHERE e.merged_into IS NULL AND e.updated_at >= ?;
        """, [.real(since)])
        let byEvent = Dictionary(grouping: rows) { $0.eventID ?? "" }
        return versions.compactMap { row in
            guard let id = row[0], let members = byEvent[id], !members.isEmpty else { return nil }
            return (id, row[1].flatMap { Int($0) } ?? 1, members.sorted { $0.id < $1.id })
        }
    }

    /// Articles the user marked as a different event from `articleID`.
    func eventExclusions(of articleID: String) throws -> Set<String> {
        guard let member = try memberArticleID(articleID) else { return [] }
        return try eventExclusions(for: [member])[member] ?? []
    }

    /// A symmetric exclusion snapshot for stored member IDs, in bounded SQLite batches.
    func eventExclusions(for articleIDs: [String]) throws -> [String: Set<String>] {
        let ids = Set(articleIDs).sorted()
        var exclusions: [String: Set<String>] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            try Task.checkCancellation()
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try eventRows("""
            SELECT article_id, other_article_id FROM event_exclusions
            WHERE article_id IN (\(placeholders)) OR other_article_id IN (\(placeholders));
            """, (slice + slice).map { .text($0) })
            for row in rows {
                guard let first = row[0], let second = row[1] else { continue }
                exclusions[first, default: []].insert(second)
                exclusions[second, default: []].insert(first)
            }
        }
        return exclusions
    }

    func markEventMatchProcessed(_ articleIDs: [String], matcherVersion: Int, at date: Date = Date()) throws {
        try inEventTransaction { () throws -> Void in
            for articleID in articleIDs {
                try markMatched(articleID, matcherVersion: matcherVersion, at: date.timeIntervalSince1970)
            }
        }
    }

    private func markMatched(_ articleID: String, matcherVersion: Int, at now: Double) throws {
        // An article deleted in the meantime has nothing left to mark.
        try eventRows("""
        INSERT INTO event_match_state(article_id, matcher_version, processed_at)
        SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM articles WHERE id = ?)
        ON CONFLICT(article_id) DO UPDATE SET matcher_version = excluded.matcher_version, processed_at = excluded.processed_at;
        """, [.text(articleID), .integer(matcherVersion), .real(now), .text(articleID)])
    }

    private func excluded(_ articleID: String, from others: [String]) throws -> Bool {
        for other in others where other != articleID {
            let (low, high) = articleID < other ? (articleID, other) : (other, articleID)
            if try !eventRows("SELECT 1 FROM event_exclusions WHERE article_id = ? AND other_article_id = ?;", [.text(low), .text(high)]).isEmpty {
                return true
            }
        }
        return false
    }

    /// Applies a matcher decision only if the state it was made against still holds: the target event
    /// keeps the expected version, new-event partners are still unassigned and no pair is excluded.
    /// Otherwise nothing changes and the article stays pending for the next pass.
    func applyEventMatch(_ articleID: String, _ decision: EventMatchDecision, matcherVersion: Int, at date: Date = Date()) throws -> EventMatchOutcome {
        try inEventTransaction { () throws -> EventMatchOutcome in
            let now = date.timeIntervalSince1970
            guard let member = try memberArticleID(articleID) else { return .conflict }
            switch decision {
            case .join(let eventID, let expectedVersion):
                guard try resolvedEventID(eventID) == eventID, let live = try? liveEvent(eventID),
                      live.version == expectedVersion else { return .conflict }
                let members = try eventRows("SELECT article_id FROM event_members WHERE event_id = ?;", [.text(eventID)]).compactMap { $0[0] }
                guard !(try excluded(member, from: members)) else { return .conflict }
                if try assignMembers([member], to: eventID, joinedVersion: live.version + 1, at: now) {
                    try bumpMembershipVersion(eventID, at: now)
                }
                try markMatched(member, matcherVersion: matcherVersion, at: now)
                return .joined(eventID)
            case .create(let partners):
                var group = [member]
                for partner in partners {
                    guard let resolved = try memberArticleID(partner), !group.contains(resolved),
                          try eventRows("SELECT 1 FROM event_members WHERE article_id = ?;", [.text(resolved)]).isEmpty,
                          !(try excluded(resolved, from: group)) else { return .conflict }
                    group.append(resolved)
                }
                guard group.count >= 2 else { return .conflict }
                let id = try insertEvent(members: group, at: now)
                for article in group { try markMatched(article, matcherVersion: matcherVersion, at: now) }
                return .created(id)
            }
        }
    }

    /// "These are different events": takes the article out of the event and records an exclusion
    /// against every remaining member. Later passes may match it elsewhere, never back with them.
    @discardableResult
    func separateArticle(_ articleID: String, fromEvent eventID: String, at date: Date = Date()) throws -> StoryEvent {
        let id = try inEventTransaction { () throws -> String in
            let target = try liveEvent(eventID)
            guard let member = try memberArticleID(articleID) else { throw Self.eventError("Unknown event member article") }
            let members = try eventRows("SELECT article_id FROM event_members WHERE event_id = ?;", [.text(target.id)]).compactMap { $0[0] }
            guard members.contains(member) else { throw Self.eventError("The article is not part of this event") }
            let now = date.timeIntervalSince1970
            try eventRows("DELETE FROM event_members WHERE article_id = ? AND event_id = ?;", [.text(member), .text(target.id)])
            try bumpMembershipVersion(target.id, at: now)
            for other in members where other != member {
                let (low, high) = member < other ? (member, other) : (other, member)
                try eventRows("INSERT OR IGNORE INTO event_exclusions(article_id, other_article_id, created_at) VALUES (?, ?, ?);",
                              [.text(low), .text(high), .real(now)])
            }
            try eventRows("DELETE FROM event_match_state WHERE article_id = ?;", [.text(member)])
            return target.id
        }
        return try requireEvent(id)
    }

    // MARK: - Event Reading State

    /// Records that the reader has seen the event up to `version` (the current version by default,
    /// never beyond it). Seen versions only grow. Article read and saved state is not touched.
    @discardableResult
    func markEventSeen(_ eventID: String, version: Int? = nil, at date: Date = Date()) throws -> Int {
        try inEventTransaction { () throws -> Int in
            let live = try liveEvent(eventID)
            let seen = max(1, min(version ?? live.version, live.version))
            try eventRows("""
            INSERT INTO event_state(event_id, seen_version, seen_at) VALUES (?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET seen_version = max(seen_version, excluded.seen_version), seen_at = excluded.seen_at;
            """, [.text(live.id), .integer(seen), .real(date.timeIntervalSince1970)])
            return try eventRows("SELECT seen_version FROM event_state WHERE event_id = ?;", [.text(live.id)]).first?[0].flatMap { Int($0) } ?? seen
        }
    }

    func eventSeenVersion(_ eventID: String) throws -> Int? {
        guard let live = try resolvedEventID(eventID) else { return nil }
        return try eventRows("SELECT seen_version FROM event_state WHERE event_id = ?;", [.text(live)]).first?[0].flatMap { Int($0) }
    }

    /// Every visible member of the events that hold any of `articleIDs`, newest first, with the
    /// state a feed card needs. No article text beyond the title is read.
    func eventFeedSummaries(forArticles articleIDs: [String]) throws -> [EventFeedSummary] {
        var eventIDs: [String] = []
        var seen = Set<String>()
        for start in stride(from: 0, to: articleIDs.count, by: 400) {
            let slice = Array(articleIDs[start..<min(start + 400, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            for row in try eventRows("SELECT DISTINCT event_id FROM event_members WHERE article_id IN (\(placeholders));", slice.map { .text($0) }) {
                if let id = row[0], seen.insert(id).inserted { eventIDs.append(id) }
            }
        }
        var summaries: [EventFeedSummary] = []
        for start in stride(from: 0, to: eventIDs.count, by: 400) {
            let slice = Array(eventIDs[start..<min(start + 400, eventIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
            let rows = try eventRows("""
            SELECT m.event_id, e.membership_version, st.seen_version, a.id, a.source, a.title,
                   \(Self.articleDateOrder), m.joined_version, s.is_read, s.is_saved
            FROM event_members m
            JOIN events e ON e.id = m.event_id
            JOIN articles a ON a.id = m.article_id
            JOIN article_state s ON s.article_id = a.id
            LEFT JOIN event_state st ON st.event_id = m.event_id
            WHERE m.event_id IN (\(placeholders)) AND \(Self.visibleArticle)
            ORDER BY m.event_id, \(Self.articleDateOrder) DESC, a.id;
            """, slice.map { .text($0) })
            var current: (id: String, version: Int, seen: Int?, members: [EventFeedMember])?
            for row in rows {
                guard let eventID = row[0], let articleID = row[3] else { continue }
                if current?.id != eventID {
                    if let current { summaries.append(EventFeedSummary(eventID: current.id, membershipVersion: current.version, seenVersion: current.seen, members: current.members)) }
                    current = (eventID, row[1].flatMap { Int($0) } ?? 1, row[2].flatMap { Int($0) }, [])
                }
                current?.members.append(EventFeedMember(
                    articleID: articleID, source: row[4] ?? "", title: row[5] ?? "",
                    date: Date(timeIntervalSince1970: row[6].flatMap { Double($0) } ?? 0),
                    joinedVersion: row[7].flatMap { Int($0) } ?? 1,
                    isRead: row[8] == "1", isSaved: row[9] == "1"))
            }
            if let current { summaries.append(EventFeedSummary(eventID: current.id, membershipVersion: current.version, seenVersion: current.seen, members: current.members)) }
        }
        return summaries
    }

    /// Drops events left without members unless an overview still refers to them. A forward dies with
    /// its survivor; merges keep forwards one hop deep, so two passes clear them.
    private func pruneEmptyEvents() throws {
        for _ in 0..<2 {
            try executeSimple("""
            DELETE FROM events WHERE merged_into IS NULL
                AND NOT EXISTS (SELECT 1 FROM event_members m WHERE m.event_id = events.id)
                AND NOT EXISTS (SELECT 1 FROM event_overviews o WHERE o.event_id = events.id);
            """)
        }
    }

}

// MARK: - SQLite functions

/// `news_muted_source(url, hosts)`: 1 when the URL's host is a muted host or one of its subdomains.
private func mutedSourceFunction(_ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard count == 2, let values else { return sqlite3_result_int(context, 0) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    sqlite3_result_int(context, MuteRules.sourceList(text(1), mutes: text(0)) ? 1 : 0)
}

/// `news_muted_topic(title, description, phrases)`: 1 when the headline or summary contains a muted phrase as whole words.
private func mutedTopicFunction(_ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard count == 3, let values else { return sqlite3_result_int(context, 0) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    sqlite3_result_int(context, MuteRules.topicList(text(2), mutes: text(0) + "\n" + text(1)) ? 1 : 0)
}

/// Pure SQLite bridge; publisher text is hashed locally and never logged.
func publisherInputFunction(_ context: OpaquePointer?, _ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?) {
    guard count == 3, let arguments else { sqlite3_result_null(context); return }
    func text(_ index: Int) -> String { sqlite3_value_text(arguments[index]).map { String(cString: $0) } ?? "" }
    let hash = PublisherContentRevision.inputHash(title: text(0), description: text(1), content: text(2))
    sqlite3_result_text(context, hash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}
