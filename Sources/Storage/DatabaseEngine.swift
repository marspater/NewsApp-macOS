import Foundation
import SQLite3
import os

/// Actor-isolated SQLite persistence engine.
/// Manages connection lifecycle, WAL mode, schema versioning, FTS5 full-text indexing,
/// atomic batch transactions, and retention pruning.
actor DatabaseEngine {
    static let shared = DatabaseEngine()
    let logger = NewsSignposts.databaseLog
    private struct DBConnection: @unchecked Sendable {
        var handle: OpaquePointer?
    }
    private var connection = DBConnection()
    var db: OpaquePointer? {
        get { connection.handle }
        set { connection.handle = newValue }
    }
    private let dbPath: String
    private var inMemoryWorldTension: [WorldTensionReading] = []
    private var collectionOnlyFeedURLs: [String] = []
    private var spellingCache: (key: String, words: [String: Int])?
    /// The clock of the last story pass over this library (#581); process-local, nil until the first pass.
    private(set) var lastStoryPass: Date?
    /// Story work skipped or interrupted since the last completed pass; retried when energy permits.
    private(set) var storyPassPending = false

    func deferStoryPass() { storyPassPending = true }

    func recordStoryPass(at date: Date) {
        lastStoryPass = date
        storyPassPending = false
    }
    private(set) var healthNotice: String?
    /// True while the library is open read-only (integrity issue, newer schema, failed backup); its side files are
    /// then left alone too, so nothing beside the database changes either.
    private(set) var isReadOnly = false
    /// The newest schema `migrateSchemaIfNeeded` writes; a library above it came from a newer build (#747).
    static let schemaVersion = 27
    /// How long a statement waits for another connection's lock before SQLite reports it busy.
    static let busyTimeoutMilliseconds: Int32 = 5_000

    func databaseHealthNotice() -> String? {
        healthNotice
    }

    func setCollectionOnlyFeedURLs(_ urls: [String]) {
        collectionOnlyFeedURLs = Array(Set(urls)).sorted()
    }

    /// Analysis-only panel reports stay outside the reading feed; read/saved reports remain accessible.
    private func collectionScope() -> (sql: String, params: [QueryParameter]) {
        guard !collectionOnlyFeedURLs.isEmpty else { return ("", []) }
        let placeholders = Array(repeating: "?", count: collectionOnlyFeedURLs.count).joined(separator: ",")
        return (
            """
             AND (EXISTS (SELECT 1 FROM article_state kept WHERE kept.article_id = a.id AND (kept.is_saved = 1 OR kept.is_read = 1))
                 OR NOT EXISTS (SELECT 1 FROM article_feeds af WHERE af.article_id = a.id)
                 OR EXISTS (SELECT 1 FROM article_feeds af WHERE af.article_id = a.id AND af.feed_url NOT IN (\(placeholders))))
            """, collectionOnlyFeedURLs.map { ("text", $0) }
        )
    }

    // sqliteTransient destructor constant (-1 converted to unsafe pointer)
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        if let handle = connection.handle {
            sqlite3_close_v2(handle)
            connection.handle = nil
        }
    }

    /// Runs `PRAGMA optimize;` and `PRAGMA wal_checkpoint(TRUNCATE);` before app termination (#536).
    func checkpointAndOptimize() {
        guard db != nil else { return }
        do {
            try executeSimple("PRAGMA optimize;")
            try executeSimple("PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            logger.error("Database checkpoint/optimize failed: \(error.localizedDescription)")
        }
    }

    private func verifyQuickCheck() -> String? {
        guard let db = db else { return "Database not open" }
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(db, "PRAGMA quick_check(1);", -1, &stmt, nil)
        guard status == SQLITE_OK else {
            return String(cString: sqlite3_errmsg(db))
        }
        defer { sqlite3_finalize(stmt) }
        let stepStatus = sqlite3_step(stmt)
        if stepStatus == SQLITE_ROW {
            let text = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "unknown"
            return text.lowercased() == "ok" ? nil : text
        }
        if stepStatus == SQLITE_DONE {
            return nil
        }
        return String(cString: sqlite3_errmsg(db))
    }

    private func getAutoVacuumMode() throws -> Int {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA auto_vacuum;", -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db, "Could not read auto_vacuum mode")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw sqliteError(db, "Could not read auto_vacuum mode")
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    deinit {
        if let handle = connection.handle {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - Connection & Schema Setup

    func open() throws {
        guard db == nil else { return }
        healthNotice = nil
        isReadOnly = false

        let parentDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard status == SQLITE_OK, let openDb = handle else {
            let errMsg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let handle = handle { sqlite3_close(handle) }
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open database at \(dbPath): \(errMsg)"])
        }

        // Another process on the same library (a second development build) waits for a lock instead of failing busy.
        sqlite3_busy_timeout(openDb, Self.busyTimeoutMilliseconds)
        self.db = openDb

        if let issue = verifyQuickCheck() {
            let notice =
                "The library database reported an integrity issue (\(issue)). Back up your library file before clearing or replacing storage."
            healthNotice = notice
            logger.error(
                "SQLite quick_check reported an integrity issue at \(self.dbPath, privacy: .public): \(issue, privacy: .public)"
            )
            reopenReadOnly(closing: openDb)
            return
        }

        // Held from the version check through the backup and the migration, so a second process opening the same
        // library waits and then sees the migrated version instead of copying or migrating it again.
        var migrationLock: Int32 = -1
        defer { if migrationLock >= 0 { Darwin.close(migrationLock) } }
        do {
            var version = try getUserVersion()
            if version < Self.schemaVersion, dbPath != ":memory:" {
                migrationLock = try lockForMigration()
                version = try getUserVersion()
            }
            // A library from a newer build is never migrated or written to by this one (#747).
            if version > Self.schemaVersion {
                healthNotice =
                    "This library was saved by a newer version of News (schema \(version); this version knows \(Self.schemaVersion)). It is open read-only and unchanged. Install the newer version to keep using it."
                logger.error(
                    "Library schema \(version) is newer than this build's \(Self.schemaVersion); opening read-only")
                reopenReadOnly(closing: openDb)
                return
            }
            // An existing library is copied before any migration step runs; a brand-new file has nothing to keep (#746).
            if version < Self.schemaVersion, try hasTables() {
                do {
                    try backUpBeforeMigration(from: version)
                } catch {
                    healthNotice =
                        "News couldn't back up the library before upgrading it (\(error.localizedDescription)), so it is open read-only and unchanged. Free some disk space and reopen News."
                    logger.error("Pre-migration backup failed: \(error.localizedDescription, privacy: .public)")
                    reopenReadOnly(closing: openDb)
                    return
                }
            }
            // Configure incremental auto-vacuum before first-page allocation on brand-new databases (#536).
            if version == 0 {
                try executeSimple("PRAGMA auto_vacuum = INCREMENTAL;")
            }
            // Optimize SQLite for high concurrency and safety
            try executeSimple("PRAGMA journal_mode = WAL;")
            try executeSimple("PRAGMA synchronous = NORMAL;")
            try executeSimple("PRAGMA foreign_keys = ON;")
            try registerFunctions()

            try migrateSchemaIfNeeded()
            // Publisher-name corrections also apply to libraries already migrated with an earlier catalog.
            try executeSimple(
                "UPDATE articles SET source = news_publisher_name(canonical_url, source) WHERE source != news_publisher_name(canonical_url, source);"
            )
            // Fill old classification cache misses before publisher metadata can replace the repaired labels.
            try executeSimple(
                "UPDATE article_enrichment SET category = (SELECT news_topic(a.title, coalesce(a.description, ''), a.content) FROM articles a WHERE a.id = article_enrichment.article_id) WHERE category IS NULL;"
            )

            // Notification delivery state (#545, #665, docs/notifications.md): side tables created on open, outside
            // the numbered migrations, so they need no schema version.
            try executeSimple(
                """
                CREATE TABLE IF NOT EXISTS event_notifications (
                    event_id TEXT PRIMARY KEY,
                    notified_at REAL NOT NULL,
                    lead_key TEXT NOT NULL,
                    lane INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS notification_deliveries (
                    id INTEGER PRIMARY KEY,
                    lane INTEGER NOT NULL,
                    grouped INTEGER NOT NULL,
                    feed_url TEXT,
                    story_count INTEGER NOT NULL,
                    delivered_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_notification_deliveries_time ON notification_deliveries(delivered_at);
                CREATE TABLE IF NOT EXISTS notification_priority_queue (
                    event_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    score REAL NOT NULL,
                    lead_key TEXT NOT NULL,
                    queued_at REAL NOT NULL,
                    story_id TEXT NOT NULL DEFAULT ''
                );
                """
            )
            if try !columnNames(of: "event_notifications").contains("lane") {
                try executeSimple("ALTER TABLE event_notifications ADD COLUMN lane INTEGER NOT NULL DEFAULT 0;")
            }
            if try !columnNames(of: "notification_priority_queue").contains("story_id") {
                try executeSimple(
                    "ALTER TABLE notification_priority_queue ADD COLUMN story_id TEXT NOT NULL DEFAULT '';")
            }
            // Overviews stored under a story's summed version before #789 sit above their event's own version; a later
            // event version could equal it with unchanged inputs and read as current, so they regenerate instead.
            try executeSimple(
                """
                DELETE FROM event_overviews WHERE membership_version >
                    (SELECT e.membership_version FROM events e WHERE e.id = event_overviews.event_id);
                """)
            // Ensure article_embeddings table exists on all databases (including pre-existing v21 databases) (#127, #307)
            try executeSimple(
                """
                CREATE TABLE IF NOT EXISTS article_embeddings (
                    article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                    model_version INTEGER NOT NULL,
                    vector BLOB NOT NULL
                );
                """
            )
        } catch {
            sqlite3_close(openDb)
            self.db = nil
            throw error
        }

    }

    /// Closes the writable handle and reopens the library read-only, keeping the health notice already set.
    private func reopenReadOnly(closing openDb: OpaquePointer) {
        isReadOnly = true
        sqlite3_close_v2(openDb)
        self.db = nil
        var roHandle: OpaquePointer?
        let roFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &roHandle, roFlags, nil) == SQLITE_OK, let roDb = roHandle {
            sqlite3_busy_timeout(roDb, Self.busyTimeoutMilliseconds)
            self.db = roDb
            do {
                try registerFunctions()
            } catch {
                logger.error(
                    "Failed to register functions on read-only fallback database: \(error.localizedDescription)")
            }
        } else if let roHandle = roHandle {
            sqlite3_close_v2(roHandle)
        }
    }

    /// An exclusive `flock` on `<library>.migration-lock`; closing the descriptor releases it.
    private func lockForMigration() throws -> Int32 {
        let descriptor = Darwin.open(dbPath + ".migration-lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileLocking)
        }
        return descriptor
    }

    private func hasTables() throws -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil) == SQLITE_OK,
            sqlite3_step(stmt) == SQLITE_ROW
        else {
            sqlite3_finalize(stmt)
            throw sqliteError(db, "Could not read the database schema")
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_column_int(stmt, 0) > 0
    }

    /// Copies the library with the SQLite online backup API to `<name>-before-v<old>-<yyyy-MM-dd>.sqlite3` beside it,
    /// keeping the newest two such copies (#746).
    private func backUpBeforeMigration(from version: Int) throws {
        guard db != nil, dbPath != ":memory:" else { return }
        let target = try keepCopyBeside(label: "before-v\(version)", group: "before-v")
        logger.info("Backed up schema v\(version) library to \(target.lastPathComponent, privacy: .public)")
    }

    /// Copies the library to `<name>-<label>-<yyyy-MM-dd>.sqlite3` beside it (`<yyyy-MM-dd-HHmmss>` with `withTime`) and
    /// keeps the newest two copies whose names start with `<name>-<group>`. The copy is written under a temporary name
    /// and renamed when complete; a copy with the same name is replaced atomically, so it survives if the new one can't
    /// be put in place. With `fallingBackToFile`, a library that can't be copied online (closed, or too damaged) is
    /// copied as a file instead.
    @discardableResult
    private func keepCopyBeside(
        label: String, group: String, withTime: Bool = false, fallingBackToFile: Bool = false
    ) throws -> URL {
        let library = URL(fileURLWithPath: dbPath)
        let folder = library.deletingLastPathComponent()
        let prefix = "\(library.deletingPathExtension().lastPathComponent)-\(group)"
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = withTime ? "yyyy-MM-dd-HHmmss" : "yyyy-MM-dd"
        let target = folder.appendingPathComponent(
            "\(library.deletingPathExtension().lastPathComponent)-\(label)-\(stamp.string(from: Date())).sqlite3")
        let partial = folder.appendingPathComponent(
            ".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).partial")
        let fileManager = FileManager.default
        do {
            try copyLibrary(to: partial)
        } catch  where fallingBackToFile {
            try? fileManager.removeItem(at: partial)
            try fileManager.copyItem(at: library, to: partial)
        }
        do {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }

        // Pruning is best-effort: a leftover copy never blocks the caller.
        let listing = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        let copies = (listing ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite3" }
            .sorted { lhs, rhs in
                let left =
                    (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let right =
                    (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return left > right
            }
        for old in copies.dropFirst(2) where old != target {
            try? fileManager.removeItem(at: old)
        }
        return target
    }

    /// Writes a consistent, self-contained copy of the open library to `partial` with the SQLite online backup API,
    /// replacing any file there; a failed copy leaves nothing behind (#746, #563).
    private func copyLibrary(to partial: URL) throws {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partial)
        // The copy holds the same reading history as the library, so it gets the library's permissions, not the
        // default ones; SQLite then opens the empty file as a new database.
        // Read from the resolved file: a symbolic link's own mode would give the copy broader permissions.
        let resolvedPath = URL(fileURLWithPath: dbPath).resolvingSymlinksInPath().path
        let permissions = (try? fileManager.attributesOfItem(atPath: resolvedPath)[.posixPermissions]) ?? 0o600
        guard fileManager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: permissions])
        else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create \(partial.lastPathComponent)"])
        }

        var copy: OpaquePointer?
        guard sqlite3_open_v2(partial.path, &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let copy
        else {
            sqlite3_close_v2(copy)
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create \(partial.lastPathComponent)"])
        }
        sqlite3_busy_timeout(copy, Self.busyTimeoutMilliseconds)
        let backup = sqlite3_backup_init(copy, "main", db, "main")
        var status = backup.map { backup in
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            return step == SQLITE_DONE ? finish : step
        }
        // The copy inherits the library's WAL header; rollback mode keeps it one self-contained file.
        if status == SQLITE_OK { status = sqlite3_exec(copy, "PRAGMA journal_mode = DELETE;", nil, nil, nil) }
        let failure = (backup == nil || status != SQLITE_OK) ? sqliteError(copy, "Library backup failed") : nil
        sqlite3_close_v2(copy)
        // Leaving WAL mode can leave an empty shared-memory file behind.
        for sidecar in ["-wal", "-shm"] { try? fileManager.removeItem(atPath: partial.path + sidecar) }
        if let failure {
            try? fileManager.removeItem(at: partial)
            throw failure
        }
    }

    /// The table a user backup keeps the reader's settings and the World Tension history in (#563).
    static let backupExtrasTable = "news_backup"

    /// Writes a user backup to `destination` (#563): an online copy of the library that also carries `settings` and the
    /// World Tension history in ``backupExtrasTable``. It is built in a scratch folder on the destination's volume and
    /// moved into place whole, so a file already there is only ever replaced by a complete backup.
    func writeBackup(to destination: URL, settings: Data) throws {
        guard dbPath != ":memory:" else { throw CocoaError(.fileNoSuchFile) }
        let fileManager = FileManager.default
        // Replacing the library (or its WAL files) with its own backup would destroy it: compare resolved paths, and the
        // file identity for an existing file, so a symbolic or hard link to the library is refused too.
        func identity(_ path: String) -> (resolved: String, file: [Int]?) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let attributes = try? fileManager.attributesOfItem(atPath: resolved)
            let file = (attributes?[.systemNumber] as? Int).flatMap { device in
                (attributes?[.systemFileNumber] as? Int).map { [device, $0] }
            }
            return (resolved, file)
        }
        let target = identity(destination.path)
        for path in [dbPath, dbPath + "-wal", dbPath + "-shm"] {
            let live = identity(path)
            guard target.resolved != live.resolved, target.file == nil || target.file != live.file else {
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "That file is the News library itself. Choose another name or folder for the backup."
                    ])
            }
        }
        let scratch =
            (try? fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true))
            ?? fileManager.temporaryDirectory.appendingPathComponent("news-backup-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let partial = scratch.appendingPathComponent(destination.lastPathComponent)
        try copyLibrary(to: partial)
        var extras = ["settings": settings]
        extras["world-tension"] = try? Data(contentsOf: worldTensionURL)
        try withConnection(to: partial) { copy in
            try exec(copy, "CREATE TABLE \(Self.backupExtrasTable) (name TEXT PRIMARY KEY, value BLOB);")
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    copy, "INSERT INTO \(Self.backupExtrasTable) (name, value) VALUES (?, ?);", -1, &statement, nil)
                    == SQLITE_OK
            else { throw sqliteError(copy, "Could not write the backup") }
            defer { sqlite3_finalize(statement) }
            for (name, value) in extras {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, name, -1, Self.sqliteTransient)
                _ = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), Self.sqliteTransient)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(copy, "Could not write the backup")
                }
            }
        }
        // A backup holds the reader's whole history, so only its owner can read it.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
        logger.info("Wrote a library backup")
    }

    /// Replaces the library with the backup at `archive` and returns the settings it carries, if any (#563).
    ///
    /// The archive is checked on a staging copy first: a damaged file, one saved by a newer build (the #747 rule), or one
    /// this build can't open and migrate is refused with the library untouched. The current library is first kept as
    /// `<name>-before-restore-<yyyy-MM-dd>.sqlite3` (newest two kept), so a mistaken restore can be undone. On success
    /// the library stays closed; the caller relaunches the app.
    func restoreBackup(from archive: URL) async throws -> Data? {
        guard dbPath != ":memory:" else { throw CocoaError(.fileNoSuchFile) }
        let fileManager = FileManager.default
        let library = URL(fileURLWithPath: dbPath)
        // A folder of its own beside the library: the trial open below writes its lock and any migration copy there.
        let stagingFolder = library.deletingLastPathComponent().appendingPathComponent(
            ".\(library.lastPathComponent).restoring-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let staging = stagingFolder.appendingPathComponent(library.lastPathComponent)
        defer { try? fileManager.removeItem(at: stagingFolder) }
        try? fileManager.removeItem(at: stagingFolder)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: false)
        try fileManager.copyItem(at: archive, to: staging)
        // The restored library gets the current one's permissions, not whatever the chosen file had.
        let resolvedPath = library.resolvingSymlinksInPath().path
        let permissions = (try? fileManager.attributesOfItem(atPath: resolvedPath)[.posixPermissions]) ?? 0o600
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path)
        let damaged = NSError(
            domain: "DatabaseEngine", code: -1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "This file is damaged or isn't a News library backup, so nothing was restored."
            ])

        let extras = try withConnection(to: staging) { copy -> [String: Data] in
            func value(_ sql: String) -> String? {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(copy, sql, -1, &statement, nil) == SQLITE_OK,
                    sqlite3_step(statement) == SQLITE_ROW
                else { return nil }
                return sqlite3_column_text(statement, 0).map { String(cString: $0) }
            }
            guard value("PRAGMA integrity_check(1);") == "ok",
                value("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'articles';") == "1",
                let version = value("PRAGMA user_version;").flatMap({ Int($0) })
            else { throw damaged }
            guard version <= Self.schemaVersion else {
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "This backup was saved by a newer version of News (schema \(version); this version knows \(Self.schemaVersion)), so nothing was restored. Install the newer version to restore it."
                    ])
            }
            var extras: [String: Data] = [:]
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            // A plain library file (an older pre-migration copy) has no extras and restores without settings.
            if sqlite3_prepare_v2(copy, "SELECT name, value FROM \(Self.backupExtrasTable);", -1, &statement, nil)
                == SQLITE_OK
            {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let name = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
                    let bytes = sqlite3_column_blob(statement, 1)
                    extras[name] =
                        bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 1))) } ?? Data()
                }
                try exec(copy, "DROP TABLE \(Self.backupExtrasTable);")
            }
            return extras
        }
        // The staged copy must open and migrate here, exactly as the swapped-in library will on relaunch; a file with the
        // right table names but the wrong columns fails now instead of after the swap.
        let trial = DatabaseEngine(path: staging.path)
        do {
            try await trial.open()
        } catch {
            await trial.close()
            throw damaged
        }
        let trialNotice = await trial.databaseHealthNotice()
        await trial.close()
        guard trialNotice == nil else { throw damaged }

        // Nothing is swapped in until the current library is kept; a library too damaged to copy online is copied as a file.
        if fileManager.fileExists(atPath: dbPath) {
            let kept = try keepCopyBeside(
                label: "before-restore", group: "before-restore", withTime: true, fallingBackToFile: true)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kept.path)
        }
        // The side file goes before the library: it is small, and the old one is put back from memory if the swap fails.
        let previousTension = try? Data(contentsOf: worldTensionURL)
        func putTension(_ data: Data?) throws {
            if let data {
                try data.write(to: worldTensionURL, options: .atomic)
            } else if fileManager.fileExists(atPath: worldTensionURL.path) {
                try fileManager.removeItem(at: worldTensionURL)
            }
        }
        // A plain library file carries no extras and leaves the side file as it is.
        if !extras.isEmpty { try putTension(extras["world-tension"]) }

        close()
        for sidecar in ["-wal", "-shm"] { try? fileManager.removeItem(atPath: dbPath + sidecar) }
        do {
            if fileManager.fileExists(atPath: dbPath) {
                _ = try fileManager.replaceItemAt(library, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: library)
            }
        } catch {
            // A failed atomic replace leaves the library in place; its side file goes back too.
            if !extras.isEmpty { try? putTension(previousTension) }
            try? open()
            throw error
        }
        logger.info("Restored the library from a backup")
        return extras["settings"]
    }

    /// Runs `body` on a separate read-write connection to `file`, closed afterwards.
    private func withConnection<T>(to file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open \(file.lastPathComponent)"])
        }
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
        return try body(handle)
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(handle, "Backup step failed")
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
            // One transaction: a half-created schema would otherwise report version 0 and fail on the next launch.
            try beginTransaction()
            do {
                try executeSimple(schema)
                try setUserVersion(1)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
            logger.info("Database schema migrated to version 1")
        }
        if version < 2 {
            try beginTransaction()
            do {
                try executeSimple("ALTER TABLE articles ADD COLUMN reader_document TEXT;")
                try setUserVersion(2)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 3 {
            try beginTransaction()
            do {
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 4 {
            try beginTransaction()
            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "PRAGMA table_info(article_enrichment);", -1, &statement, nil) == SQLITE_OK
                else {
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot inspect enrichment schema"])
                }
                defer { sqlite3_finalize(statement) }
                var columns = Set<String>()
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw NSError(
                        domain: "DatabaseEngine", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Cannot read enrichment schema"])
                }
                for (name, definition) in [
                    ("key_points", "TEXT"), ("category", "TEXT"), ("confidence", "REAL"),
                    ("model_identifier", "TEXT"), ("analysis_version", "INTEGER DEFAULT 1"),
                ] where !columns.contains(name) {
                    try executeSimple("ALTER TABLE article_enrichment ADD COLUMN \(name) \(definition);")
                }
                try setUserVersion(4)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 5 {
            try beginTransaction()
            do {
                try executeSimple(
                    """
                    CREATE TABLE article_aliases (
                        kind TEXT NOT NULL CHECK(kind IN ('id', 'url')),
                        value TEXT NOT NULL,
                        article_id TEXT REFERENCES articles(id) ON DELETE CASCADE,
                        PRIMARY KEY(kind, value)
                    );
                    CREATE INDEX idx_article_aliases_article ON article_aliases(article_id);
                    """)
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(db, "SELECT id, canonical_url FROM articles;", -1, &statement, nil) == SQLITE_OK
                else {
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot prepare alias migration"])
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
                    throw NSError(
                        domain: "DatabaseEngine", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Cannot read alias migration rows"])
                }
                try setUserVersion(5)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot prepare scoped GUID migration"])
                }
                defer { sqlite3_finalize(statement) }
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    let id = String(cString: sqlite3_column_text(statement, 0))
                    let guid = String(cString: sqlite3_column_text(statement, 1))
                    let feed = String(cString: sqlite3_column_text(statement, 2))
                    if id == ArticleIdentity.computeId(guid: guid, link: ""),
                        let scoped = ArticleIdentity.scopedGUID(guid, feedURL: feed)
                    {
                        try recordAlias(kind: "id", value: scoped, articleID: id)
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw NSError(
                        domain: "DatabaseEngine", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Cannot read scoped GUID migration rows"])
                }
                try setUserVersion(6)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 7 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple(
                    """
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher text migration"])
                }
                defer { sqlite3_finalize(statement) }
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    func text(_ column: Int32) -> String {
                        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                    }
                    let article = FeedArticle(
                        title: text(2), link: text(1), guid: nil,
                        description: text(3), pubDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                        source: text(6), fullContent: text(4))
                    for fingerprint in ArticleIdentity.publisherTextFingerprints(article) {
                        try recordAlias(kind: "content", value: fingerprint, articleID: text(0))
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else {
                    throw NSError(
                        domain: "DatabaseEngine", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Cannot read publisher text migration"])
                }
                try Task.checkCancellation()
                try setUserVersion(7)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 8 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 9 {
            try beginTransaction()
            do {
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 10 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Libraries reconstructed at an older version may already carry the columns.
                let columns = try columnNames(of: "feeds")
                for (name, definition) in [
                    ("consecutive_failures", "INTEGER NOT NULL DEFAULT 0"), ("next_attempt_at", "REAL"),
                ]
                where !columns.contains(name) {
                    try executeSimple("ALTER TABLE feeds ADD COLUMN \(name) \(definition);")
                }
                try setUserVersion(10)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 11 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                let columns = try columnNames(of: "feeds")
                for (name, definition) in [
                    ("latest_item_at", "REAL"), ("item_count", "INTEGER NOT NULL DEFAULT 0"),
                    ("full_text_items", "INTEGER NOT NULL DEFAULT 0"),
                ]
                where !columns.contains(name) {
                    try executeSimple("ALTER TABLE feeds ADD COLUMN \(name) \(definition);")
                }
                try setUserVersion(11)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 12 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 13 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // An article belongs to at most one event. A merged event keeps its row as a forward
                // to the survivor so links to the old ID still resolve.
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 14 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Matching progress, the user's "different events" decisions and the event version a
                // reader has seen. A changed title or description makes the article pending again.
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 15 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // A durable integer key avoids reading the FTS content blob just to join article IDs.
                // Do not use articles.rowid: VACUUM may change a hidden rowid on a TEXT-keyed table.
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
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
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 17 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Historical importance ratings and expiry tombstones; current visibility/retention ignore importance.
                try executeSimple(
                    """
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 18 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Lead images found on publisher pages for stories whose feeds carry none; NULL records a page without one.
                try executeSimple(
                    """
                    CREATE TABLE IF NOT EXISTS story_images (
                        article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                        image_url TEXT,
                        checked_at REAL NOT NULL
                    );
                    """)
                try setUserVersion(18)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
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
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 20 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // The on-device model generation that produced stored overviews and summaries (`reconcileModelGeneration`).
                try executeSimple(
                    "CREATE TABLE IF NOT EXISTS model_generation (id INTEGER PRIMARY KEY CHECK (id = 1), value TEXT NOT NULL);"
                )
                try setUserVersion(20)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 21 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Page images found to be shared site defaults (#338), so a later story declaring one never keeps it.
                try executeSimple("CREATE TABLE IF NOT EXISTS story_image_defaults (url TEXT PRIMARY KEY);")
                // On-device neural sentence embeddings (384-dim normalized float32 vectors, 1536 bytes) (#127, #307).
                try executeSimple(
                    """
                    CREATE TABLE IF NOT EXISTS article_embeddings (
                        article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                        model_version INTEGER NOT NULL,
                        vector BLOB NOT NULL
                    );
                    """
                )
                try setUserVersion(21)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 22 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Repair generated topic labels from the substring classifier; publisher bodies and user state stay.
                try executeSimple(
                    "UPDATE articles SET category = news_topic(title, coalesce(description, ''), content), source = news_publisher_name(canonical_url, source);"
                )
                try executeSimple("UPDATE article_enrichment SET category = NULL, confidence = NULL;")
                try Task.checkCancellation()
                try setUserVersion(22)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 23 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                try executeSimple(
                    """
                    UPDATE articles
                    SET source = trim(substr(source, 1, instr(source, char(10)) - 1))
                    WHERE instr(source, char(10)) > 0;
                    """
                )
                try Task.checkCancellation()
                try setUserVersion(23)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 24 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // Stored matcher signals and pair decisions (#522). Features are the JSON of `EventFeatures` under its
                // storage version; a pair row is kept only for decisions the clusterer made (match, related act,
                // borderline). Both follow their articles, and a changed title or description drops them with the
                // match state and the embedding, which until now survived text changes.
                try executeSimple(
                    """
                    CREATE TABLE IF NOT EXISTS article_features (
                        article_id TEXT PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
                        version INTEGER NOT NULL,
                        features TEXT NOT NULL,
                        computed_at REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS pair_assessments (
                        article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                        other_article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                        matcher_version INTEGER NOT NULL,
                        decision TEXT NOT NULL,
                        reason TEXT NOT NULL,
                        score REAL NOT NULL,
                        features TEXT,
                        assessed_at REAL NOT NULL,
                        PRIMARY KEY (article_id, other_article_id),
                        CHECK (article_id < other_article_id)
                    );
                    CREATE INDEX IF NOT EXISTS idx_pair_assessments_other ON pair_assessments(other_article_id);
                    CREATE INDEX IF NOT EXISTS idx_pair_assessments_decision ON pair_assessments(decision);
                    DROP TRIGGER IF EXISTS trg_articles_event_rematch;
                    CREATE TRIGGER trg_articles_event_rematch AFTER UPDATE OF title, description ON articles
                    WHEN old.title IS NOT new.title OR old.description IS NOT new.description
                    BEGIN
                        DELETE FROM event_match_state WHERE article_id = old.id;
                        DELETE FROM article_features WHERE article_id = old.id;
                        DELETE FROM article_embeddings WHERE article_id = old.id;
                        DELETE FROM pair_assessments WHERE article_id = old.id OR other_article_id = old.id;
                    END;
                    """
                )
                try Task.checkCancellation()
                try setUserVersion(24)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 25 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // "Same event" corrections (#524), the mirror of event_exclusions: pairs the reader put together, which
                // every later pass keeps together. The newer of an inclusion and an exclusion of one pair wins.
                try executeSimple(
                    """
                    CREATE TABLE IF NOT EXISTS event_inclusions (
                        article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                        other_article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
                        created_at REAL NOT NULL,
                        PRIMARY KEY (article_id, other_article_id),
                        CHECK (article_id < other_article_id)
                    );
                    CREATE INDEX IF NOT EXISTS idx_event_inclusions_other ON event_inclusions(other_article_id);
                    """
                )
                try Task.checkCancellation()
                try setUserVersion(25)
                try commitTransaction()
            } catch {
                loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                throw error
            }
        }
        if version < 26 {
            try Task.checkCancellation()
            // Switch existing libraries to incremental auto-vacuum (#536) so daily retention pruning can return free
            // pages to the filesystem without a full rebuild on every launch. VACUUM cannot run inside a transaction.
            let currentAutoVacuum = loggedOptional("getAutoVacuumMode", { try getAutoVacuumMode() }) ?? 0
            if currentAutoVacuum != 2 {
                try executeSimple("PRAGMA auto_vacuum = INCREMENTAL;")
                if dbPath != ":memory:" {
                    logger.info("Rebuilding library database once to enable incremental auto-vacuum (v26)")
                    try executeSimple("VACUUM;")
                }
            }
            try Task.checkCancellation()
            try setUserVersion(26)
        }
        if version < 27 {
            try beginTransaction()
            do {
                try Task.checkCancellation()
                // The story layer (#581): a live event may belong to a story, named by the id of its earliest event.
                // The clusterer's story pass rewrites it for active events; NULL means the event is a story of its own.
                // A fixture that re-runs the migrations from an older version may already carry the column.
                if !(try columnNames(of: "events")).contains("story_id") {
                    try executeSimple("ALTER TABLE events ADD COLUMN story_id TEXT;")
                }
                try executeSimple("CREATE INDEX IF NOT EXISTS idx_events_story ON events(story_id);")
                try Task.checkCancellation()
                try setUserVersion(27)
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
        guard
            sqlite3_create_function_v2(db, "news_topic", 3, flags, nil, topicFunction, nil, nil, nil) == SQLITE_OK,
            sqlite3_create_function_v2(db, "news_section", 4, flags, nil, sectionFunction, nil, nil, nil) == SQLITE_OK,
            sqlite3_create_function_v2(db, "news_publisher_name", 2, flags, nil, publisherNameFunction, nil, nil, nil)
                == SQLITE_OK,
            sqlite3_create_function_v2(db, "news_publisher_input", 3, flags, nil, publisherInputFunction, nil, nil, nil)
                == SQLITE_OK,
            sqlite3_create_function_v2(db, "news_muted_source", 2, flags, nil, mutedSourceFunction, nil, nil, nil)
                == SQLITE_OK,
            sqlite3_create_function_v2(db, "news_muted_topic", 3, flags, nil, mutedTopicFunction, nil, nil, nil)
                == SQLITE_OK,
            sqlite3_create_function_v2(db, "news_cosine", 2, flags, nil, cosineFunction, nil, nil, nil) == SQLITE_OK
        else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot register database functions"])
        }
    }

    private func executeBound(_ sql: String, _ values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare reconciliation statement"])
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot execute reconciliation statement"])
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare historical reconciliation"])
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
            let id = text(0)
            let url = text(1)
            if url != currentURL {
                survivors.removeAll(keepingCapacity: true)
                currentURL = url
            }
            if Self.isDocumentURL(url) {
                let body = text(4)
                let article = FeedArticle(
                    title: text(2), link: url, guid: nil,
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
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Cannot read historical articles"])
        }
    }

    private func reconcileHistoricalArticle(
        _ duplicate: String, into survivor: String, url: String, fingerprint: String
    ) throws {
        try executeBound(
            "INSERT OR IGNORE INTO article_reconciliation_history SELECT * FROM article_state WHERE article_id IN (?, ?);",
            [duplicate, survivor])
        try executeBound(
            """
            UPDATE article_state SET (is_read, is_saved, read_at, saved_at) =
                (SELECT max(is_read), max(is_saved), max(read_at), max(saved_at)
                 FROM article_state WHERE article_id IN (?, ?)) WHERE article_id = ?;
            """, [duplicate, survivor, survivor])
        try executeBound(
            "INSERT OR IGNORE INTO article_feeds SELECT ?, feed_url FROM article_feeds WHERE article_id = ?;",
            [survivor, duplicate])
        try executeBound(
            "INSERT INTO article_reconciliations VALUES (?, ?, ?, ?);", [duplicate, survivor, url, fingerprint])
        try executeBound("UPDATE article_aliases SET article_id = ? WHERE article_id = ?;", [survivor, duplicate])
        try executeBound(
            """
            INSERT INTO article_aliases(kind, value, article_id) VALUES ('id', ?, ?)
            ON CONFLICT(kind, value) DO UPDATE SET article_id = excluded.article_id;
            """, [duplicate, survivor])
        // Keep URL/content ambiguity tombstones: reconciliation does not infer
        // ownership of conflicting or previously removed alias targets.
    }

    private static func historicalFingerprint(_ article: FeedArticle) -> String? {
        // A present body must qualify itself; its teaser cannot override different prose.
        let body = article.fullContent ?? ""
        let evidence = FeedArticle(
            title: article.title, link: article.link, guid: nil,
            description: body.isEmpty ? article.description : "", pubDate: article.pubDate,
            source: article.source, fullContent: body.isEmpty ? nil : body)
        return ArticleIdentity.publisherTextFingerprints(evidence).first
    }

    private func historicalTarget(_ article: FeedArticle) throws -> String? {
        guard let fingerprint = Self.historicalFingerprint(article) else { return nil }
        var statement: OpaquePointer?
        let sql =
            "SELECT DISTINCT survivor_id FROM article_reconciliations WHERE canonical_url = ? AND fingerprint = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare historical identity lookup"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, article.normalizedLink, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, fingerprint, -1, Self.sqliteTransient)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Cannot read historical identity"])
        }
        let target = String(cString: sqlite3_column_text(statement, 0))
        let next = sqlite3_step(statement)
        guard next == SQLITE_ROW || next == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(next),
                userInfo: [NSLocalizedDescriptionKey: "Cannot finish historical identity lookup"])
        }
        return next == SQLITE_DONE ? target : nil
    }

    private func columnNames(of table: String) throws -> Set<String> {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot inspect \(table) schema"])
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }
        return columns
    }

    private func getUserVersion() throws -> Int {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        var stmt: OpaquePointer?
        // A failed read must not look like a fresh file: the version 1 schema would then run again.
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db, "Could not read the database version")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw sqliteError(db, "Could not read the database version")
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// The open library's schema version (`PRAGMA user_version`), for Help › Export Diagnostics (#564).
    func storedSchemaVersion() throws -> Int { try getUserVersion() }

    private func sqliteError(_ db: OpaquePointer, _ context: String) -> NSError {
        NSError(
            domain: "DatabaseEngine", code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: sqlite3_errmsg(db)))"])
    }

    private func setUserVersion(_ version: Int) throws {
        try executeSimple("PRAGMA user_version = \(version);")
    }

    func executeSimple(_ sql: String) throws {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SQL execution error: \(msg) in statement: \(sql)"])
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

    @discardableResult
    private func loggedOptional<T>(_ operation: StaticString, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription)")
            return nil
        }
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare article alias"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 3, articleID, -1, Self.sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot persist article alias"])
        }
    }

    private func aliasTarget(kind: String, value: String) throws -> String? {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT article_id FROM article_aliases WHERE kind = ? AND value = ?;", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot prepare alias lookup"]
            )
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
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot read article alias"])
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
            let rows = try eventRows(
                "SELECT value, article_id FROM article_aliases WHERE kind = 'id' AND value IN (\(placeholders));",
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
        let urlTarget =
            Self.isDocumentURL(article.normalizedLink)
            ? try aliasTarget(kind: "url", value: article.normalizedLink) : nil
        if let idTarget, let urlTarget, idTarget != urlTarget {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Conflicting article identity signals"])
        }
        if let target = idTarget ?? urlTarget { return target }
        if let target = try publisherTextTarget(article) { return target }
        if let target = try historicalTarget(article) { return target }
        if let target = try publisherTitleTarget(article) { return target }
        // Direct legacy callers may still supply an unscoped model. Keep that key
        // only if unused; a GUID already owned by another feed needs its scoped key.
        if let scoped, article.storedID == nil,
            try aliasTarget(kind: "id", value: article.id) != nil
        {
            return scoped
        }
        return article.id
    }

    /// Validated evidence extends one existing document; it never merges stored rows.
    func recordDocumentIdentity(_ evidence: DocumentIdentityEvidence, articleID: String) throws {
        let id = try resolvedArticleID(articleID)
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { loggedOptional("rollbackTransaction") { try rollbackTransaction() } }
        }
        guard try aliasTarget(kind: "url", value: evidence.requestedURL) == id else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Document evidence does not belong to the requested article"])
        }
        for url in evidence.urls {
            try Task.checkCancellation()
            if Self.isDocumentURL(url) { try recordAlias(kind: "url", value: url, articleID: id) }
        }
        try commitTransaction()
    }

    /// The stored story of the same publisher with the same folded headline, published within
    /// `publisherTitleWindow` (#583). The publisher's stories of that window are read and compared in Swift, so no alias
    /// row and no schema change are needed. The lookup uses the publisher name the upsert stores as `source`; for a
    /// site the catalog does not name, that is the feed's own title ("World news"), so the stored story must also come
    /// from the same host. Two stored stories with that headline (a pair the window kept apart) make the target
    /// ambiguous, and the item stays a story of its own.
    private func publisherTitleTarget(_ article: FeedArticle) throws -> String? {
        guard article.pubDate != DateParser.unknownDate,
            let key = ArticleIdentity.publisherTitleKey(title: article.title, source: article.publisherName)
        else { return nil }
        var statement: OpaquePointer?
        let sql = """
            SELECT id, title, canonical_url FROM articles
            WHERE source = ? AND published_at BETWEEN ? AND ?
                AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = articles.id)
            ORDER BY published_at, id;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher title lookup"])
        }
        defer { sqlite3_finalize(statement) }
        let published = article.pubDate.timeIntervalSince1970
        sqlite3_bind_text(statement, 1, article.publisherName, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 2, published - ArticleIdentity.publisherTitleWindow)
        sqlite3_bind_double(statement, 3, published + ArticleIdentity.publisherTitleWindow)
        let catalogued = FeedCatalog.publisher(forLink: article.link) != nil
        let host = MuteRules.linkHost(article.normalizedLink)
        var matches: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else {
                continue
            }
            let storedHost = sqlite3_column_text(statement, 2).flatMap { MuteRules.linkHost(String(cString: $0)) }
            guard catalogued || (host != nil && storedHost == host) else { continue }
            if ArticleIdentity.publisherTitleKey(title: String(cString: title), source: article.publisherName) == key {
                matches.append(String(cString: id))
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func publisherTextTarget(_ article: FeedArticle) throws -> String? {
        let fingerprints = ArticleIdentity.publisherTextFingerprints(article)
        guard !fingerprints.isEmpty else { return nil }
        let placeholders = fingerprints.map { _ in "?" }.joined(separator: ",")
        var statement: OpaquePointer?
        let sql = "SELECT article_id FROM article_aliases WHERE kind = 'content' AND value IN (\(placeholders));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher text lookup"])
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read publisher text lookup"])
        }
        return targets.count == 1 ? targets.first : nil
    }

    // A refresh whose item brings no publisher text (?17 = 0), such as a document holding only feed media,
    // keeps a stored document that has text, and its content (ReaderDocument.hasPublisherText).
    private static let storedHasPublisherText = """
        EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(articles.reader_document)
            THEN articles.reader_document ELSE '{}' END, '$.blocks') WHERE json_extract(value, '$.kind') NOT IN ('figure', 'divider', 'embed'))
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
                    OR (?17 = 0 AND \(storedHasPublisherText))
                    OR (json_extract(articles.reader_document, '$.isComplete') IS NOT 0 AND json_extract(excluded.reader_document, '$.isComplete') = 0))
                THEN articles.content ELSE coalesce(excluded.content, articles.content) END,
            reader_document = CASE WHEN articles.reader_document IS NOT NULL AND (?17 = 0 AND \(storedHasPublisherText)
                    OR (json_extract(articles.reader_document, '$.isComplete') IS NOT 0 AND json_extract(excluded.reader_document, '$.isComplete') = 0))
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
        if let g = article.guid {
            sqlite3_bind_text(artStmt, 2, g, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(artStmt, 2)
        }
        sqlite3_bind_text(artStmt, 3, values.canonical, -1, Self.sqliteTransient)
        sqlite3_bind_text(artStmt, 4, article.title, -1, Self.sqliteTransient)
        sqlite3_bind_text(artStmt, 5, article.description, -1, Self.sqliteTransient)
        if let c = article.fullContent {
            sqlite3_bind_text(artStmt, 6, c, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(artStmt, 6)
        }
        sqlite3_bind_double(artStmt, 7, values.pubDate)
        sqlite3_bind_text(artStmt, 8, article.publisherName, -1, Self.sqliteTransient)
        if let img = article.imageUrl {
            sqlite3_bind_text(artStmt, 9, img, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(artStmt, 9)
        }
        if let cat = article.category {
            sqlite3_bind_text(artStmt, 10, cat, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(artStmt, 10)
        }
        if let f = values.identityFeedURL {
            sqlite3_bind_text(artStmt, 11, f, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(artStmt, 11)
        }
        sqlite3_bind_double(artStmt, 12, values.now)
        sqlite3_bind_double(artStmt, 13, values.now)
        if let document = article.readerDocument {
            let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
            sqlite3_bind_text(artStmt, 14, encoded, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(artStmt, 14)
        }

        sqlite3_bind_int(artStmt, 15, values.validLink ? 1 : 0)
        sqlite3_bind_double(artStmt, 16, DateParser.unknownDate.timeIntervalSince1970)
        sqlite3_bind_int(artStmt, 17, article.readerDocument?.hasPublisherText == true ? 1 : 0)
    }

    /// `validators` accompany a fresh 200 response. They and the response's content stats are written in the same
    /// transaction as the articles, so a feed is only ever answered "not modified" for content that was durably ingested.
    @discardableResult
    func upsertArticles(
        _ articles: [FeedArticle], feedUrl: String? = nil, validators: FeedValidators? = nil,
        preservingStoredContent: Bool = false
    ) throws -> Set<String> {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        guard !articles.isEmpty else {
            // An emptied feed still answered 200: its validators (possibly none, clearing the old ones) and stats
            // must be stored, or the old ETag keeps being sent and health keeps the old item counts.
            if let feedUrl, let validators {
                // Same rule as the articles path: a refresh cancelled while waiting writes nothing.
                try beginTransaction()
                defer {
                    if sqlite3_get_autocommit(db) == 0 {
                        loggedOptional("rollbackTransaction") { try rollbackTransaction() }
                    }
                }
                try recordFeedFetch(
                    validators, stats: FeedContentStats(articles: []), for: feedUrl, at: Date().timeIntervalSince1970)
                try Task.checkCancellation()
                try commitTransaction()
            }
            return []
        }

        let signpostState = NewsSignposts.begin(
            NewsSignposts.database, name: "DatabaseBatchUpsert", metadata: "count=\(articles.count)")
        defer { NewsSignposts.end(NewsSignposts.database, name: "DatabaseBatchUpsert", state: signpostState) }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { loggedOptional("rollbackTransaction") { try rollbackTransaction() } }
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
            sqlite3_prepare_v2(db, enrichmentSql, -1, &enrichStmt, nil) == SQLITE_OK
        else {
            sqlite3_finalize(artStmt)
            sqlite3_finalize(stateStmt)
            sqlite3_finalize(enrichStmt)
            try rollbackTransaction()
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare batch upsert statements"])
        }

        defer {
            sqlite3_finalize(artStmt)
            sqlite3_finalize(stateStmt)
            sqlite3_finalize(enrichStmt)
        }

        guard
            sqlite3_prepare_v2(
                db, "INSERT OR IGNORE INTO article_feeds(article_id, feed_url) VALUES (?, ?);", -1, &feedStmt, nil)
                == SQLITE_OK
        else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed association"])
        }
        defer { sqlite3_finalize(feedStmt) }
        var existenceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM articles WHERE id = ?;", -1, &existenceStmt, nil) == SQLITE_OK
        else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare article existence query"])
        }
        defer { sqlite3_finalize(existenceStmt) }
        var expiredStmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT 1 FROM expired_stories WHERE key IN ('pruned:' || ?, 'pruned:' || ?);", -1, &expiredStmt,
                nil)
                == SQLITE_OK
        else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare pruned story query"])
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
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to check stored article identity"])
            }
            if existenceStatus == SQLITE_DONE {
                // A story pruned by retention that its feed still serves stays pruned (#783), by its resolved ID or
                // its feed-scoped GUID. An explicit save (preserving stored content) may bring it back.
                if !preservingStoredContent {
                    let scoped = ArticleIdentity.scopedGUID(article.guid, feedURL: identityFeedURL) ?? id
                    sqlite3_reset(expiredStmt)
                    sqlite3_bind_text(expiredStmt, 1, id, -1, Self.sqliteTransient)
                    sqlite3_bind_text(expiredStmt, 2, scoped, -1, Self.sqliteTransient)
                    let expiredStatus = sqlite3_step(expiredStmt)
                    if expiredStatus == SQLITE_ROW { continue }
                    guard expiredStatus == SQLITE_DONE else { throw sqliteError(db, "Could not check pruned story") }
                }
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to step article insert"])
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed association"])
                }
            }

            // 2. Insert State (preserves existing read/saved state on conflict)
            sqlite3_reset(stateStmt)
            sqlite3_bind_text(stateStmt, 1, id, -1, Self.sqliteTransient)
            if sqlite3_step(stateStmt) != SQLITE_DONE {
                try rollbackTransaction()
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to step state insert"])
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to step enrichment insert"])
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
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let sql =
            "SELECT url, etag, last_modified, consecutive_failures, next_attempt_at, last_fetched_at, latest_item_at, item_count, full_text_items FROM feeds;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed state query"])
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
        }
        var result: [String: FeedFetchState] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let url = text(0) {
                let validators = FeedValidators(etag: text(1), lastModified: text(2))
                result[url] = FeedFetchState(
                    validators: validators.isEmpty ? nil : validators,
                    failures: Int(sqlite3_column_int(statement, 3)),
                    retryAt: date(4), lastFetchedAt: date(5), latestItemAt: date(6),
                    itemCount: Int(sqlite3_column_int(statement, 7)),
                    fullTextItems: Int(sqlite3_column_int(statement, 8)))
            }
            status = sqlite3_step(statement)
        }
        // A partial map would drop validators and backoff for the feeds after the error.
        guard status == SQLITE_DONE else { throw sqliteError(db, "Could not load feed fetch states") }
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
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let sql = """
            INSERT INTO feeds (id, url, created_at, last_fetched_at, consecutive_failures, next_attempt_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET last_fetched_at = coalesce(excluded.last_fetched_at, feeds.last_fetched_at),
                consecutive_failures = excluded.consecutive_failures, next_attempt_at = excluded.next_attempt_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed schedule write"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, feedURL, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        if let fetchedAt { sqlite3_bind_double(statement, 4, fetchedAt) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_int(statement, 5, Int32(failures))
        if let retryAt {
            sqlite3_bind_double(statement, 6, retryAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed schedule"])
        }
    }

    /// Writes a fresh response's validators (cleared when empty) and content stats; the caller owns the transaction.
    private func recordFeedFetch(
        _ validators: FeedValidators, stats: FeedContentStats, for feedURL: String, at now: Double
    ) throws {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let sql = """
            INSERT INTO feeds (id, url, created_at, last_fetched_at, etag, last_modified, latest_item_at, item_count, full_text_items)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET last_fetched_at = excluded.last_fetched_at, etag = excluded.etag,
                last_modified = excluded.last_modified, latest_item_at = excluded.latest_item_at,
                item_count = excluded.item_count, full_text_items = excluded.full_text_items;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare feed fetch write"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.sqliteTransient)
        sqlite3_bind_text(statement, 2, feedURL, -1, Self.sqliteTransient)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        for (index, value) in [(5, validators.etag), (6, validators.lastModified)] {
            if let value {
                sqlite3_bind_text(statement, Int32(index), value, -1, Self.sqliteTransient)
            } else {
                sqlite3_bind_null(statement, Int32(index))
            }
        }
        if let latest = stats.latestItem {
            sqlite3_bind_double(statement, 7, latest.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_int(statement, 8, Int32(stats.itemCount))
        sqlite3_bind_int(statement, 9, Int32(stats.fullTextItems))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to persist feed fetch state"])
        }
    }

    // Unknown publisher dates retain their identity sentinel; ingestion time orders them.
    static let articleDateOrder =
        "CASE WHEN a.published_at = \(DateParser.unknownDate.timeIntervalSince1970) THEN a.created_at ELSE a.published_at END"

    private static let savedDocumentIDs =
        "SELECT article_id FROM article_state WHERE is_saved = 1 UNION SELECT r.duplicate_id FROM article_reconciliations r JOIN article_state s ON s.article_id = r.survivor_id WHERE s.is_saved = 1"
    static let visibleArticle =
        "NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)"
    /// Binds `MuteRules.sourceParameter` and `MuteRules.topicParameter`, in that order.
    private static let mutedArticle =
        "(news_muted_source(a.canonical_url, ?) OR news_muted_topic(a.title, a.description, ?))"

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
    private func listConditions(section: String?, isRead: Bool?, isSaved: Bool?, includeCollection: Bool = false) -> (
        sql: String, params: [QueryParameter]
    ) {
        var sql = ""
        var params: [QueryParameter] = []
        if !includeCollection, isRead != true, isSaved != true, !["Saved Stories", "History"].contains(section ?? "") {
            let scope = collectionScope()
            sql += scope.sql
            params += scope.params
        }
        if let read = isRead {
            sql += " AND s.is_read = ?"
            params.append(("int", read ? 1 : 0))
        }
        if let saved = isSaved {
            sql += " AND s.is_saved = ?"
            params.append(("int", saved ? 1 : 0))
        }
        if let sec = section, !["Today", "Unread", "Saved Stories", "History"].contains(sec) {
            sql += " AND news_section(a.title, coalesce(a.description, ''), coalesce(ae.category, a.category), ?) = 1"
            params.append(("text", sec))
        }
        return (sql, params)
    }

    /// The full-text join and operator conditions shared by search pages and their muted counts.
    private func searchConditions(_ parsed: ArticleFilterQuery) -> (join: String, sql: String, params: [QueryParameter])
    {
        var join = " WHERE 1=1"
        var sql = ""
        var params: [QueryParameter] = []
        if !parsed.terms.isEmpty {
            join =
                " JOIN article_fts_rows f ON f.article_id = a.id JOIN articles_fts fts ON fts.rowid = f.fts_rowid WHERE articles_fts MATCH ?"
            // Each term is a quoted prefix phrase, so typed text cannot inject FTS5 syntax (the parser already
            // removed quotes themselves).
            params.append(("text", parsed.terms.map { "\"\($0)\"*" }.joined(separator: " ")))
        }
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
        var wholeStory = false
        var includingOriginals: Bool
        var publicationWindow: ClosedRange<Date>?
        var muting: MuteRules
        var hidingWaitingStories: Bool
    }

    private func idFilterConditions(id: String, includingOriginals: Bool) throws -> (
        sql: String, params: [QueryParameter]
    ) {
        let resolvedID = includingOriginals ? id : try resolvedArticleID(id)
        return (" AND a.id = ?", [("text", resolvedID)])
    }

    private func canonicalURLFilterConditions(canonicalURL: String) throws -> (sql: String, params: [QueryParameter]) {
        if let target = try aliasTarget(kind: "url", value: canonicalURL) {
            return (" AND a.id = ?", [("text", target)])
        } else {
            let sql = """
                 AND a.canonical_url = ?
                 AND (SELECT count(*) FROM articles WHERE canonical_url = ?) = 1
                 AND NOT EXISTS (SELECT 1 FROM article_aliases WHERE kind = 'url' AND value = ? AND article_id IS NULL)
                """
            return (sql, [("text", canonicalURL), ("text", canonicalURL), ("text", canonicalURL)])
        }
    }

    private func eventFilterConditions(eventID: String, wholeStory: Bool = false) throws -> (
        sql: String, params: [QueryParameter]
    ) {
        let resolvedID = try resolvedEventID(eventID) ?? eventID
        guard wholeStory else {
            return (" AND a.id IN (SELECT article_id FROM event_members WHERE event_id = ?)", [("text", resolvedID)])
        }
        // Every live event of the event's story (#581), the event itself when it is a story of its own.
        let sql = """
             AND a.id IN (SELECT m.article_id FROM event_members m JOIN events e ON e.id = m.event_id
                WHERE e.merged_into IS NULL
                    AND coalesce(e.story_id, e.id) = (SELECT coalesce(story_id, id) FROM events WHERE id = ?))
            """
        return (sql, [("text", resolvedID)])
    }

    private func publicationWindowConditions(_ publicationWindow: ClosedRange<Date>) -> (
        sql: String, params: [QueryParameter]
    ) {
        // Undated stories fall back to ingestion time, as ordering and paging do.
        let sql = " AND \(Self.articleDateOrder) >= ? AND \(Self.articleDateOrder) <= ?"
        let params: [QueryParameter] = [
            ("double", publicationWindow.lowerBound.timeIntervalSince1970),
            ("double", publicationWindow.upperBound.timeIntervalSince1970),
        ]
        return (sql, params)
    }

    private func cursorConditions(_ after: ArticleQueryCursor) -> (sql: String, params: [QueryParameter]) {
        let sql = " AND (\(Self.articleDateOrder) < ? OR (\(Self.articleDateOrder) = ? AND a.id > ?))"
        let params: [QueryParameter] = [
            ("double", after.value),
            ("double", after.value),
            ("text", after.id),
        ]
        return (sql, params)
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
            let filter = try idFilterConditions(id: id, includingOriginals: criteria.includingOriginals)
            query += filter.sql
            params += filter.params
        }
        if let canonicalURL = criteria.canonicalURL {
            let filter = try canonicalURLFilterConditions(canonicalURL: canonicalURL)
            query += filter.sql
            params += filter.params
        }
        if let eventID = criteria.eventID {
            let filter = try eventFilterConditions(eventID: eventID, wholeStory: criteria.wholeStory)
            query += filter.sql
            params += filter.params
        }
        if let publicationWindow = criteria.publicationWindow {
            let filter = publicationWindowConditions(publicationWindow)
            query += filter.sql
            params += filter.params
        }
        let list = listConditions(
            section: criteria.section, isRead: criteria.isRead, isSaved: criteria.isSaved,
            includeCollection: criteria.id != nil || criteria.canonicalURL != nil || criteria.eventID != nil)
        query += list.sql
        params += list.params
        // Muting and waiting stories are predicates before LIMIT, so every page is full and cursors stay exact.
        if !criteria.muting.isEmpty {
            query += " AND NOT " + Self.mutedArticle
            params += Self.mutingParameters(criteria.muting)
        }
        if let after = criteria.after {
            let filter = cursorConditions(after)
            query += filter.sql
            params += filter.params
        }

        query += " ORDER BY \(Self.articleDateOrder) DESC, a.id"

        if let lim = criteria.limit {
            query += " LIMIT ?"
            params.append(("int", lim))
        }

        return (query, params)
    }

    // MARK: - Article Queries

    private func executeQueryArticles(sql: String, params: [QueryParameter], prepareErrorMessage: String) throws
        -> [FeedArticle]
    {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(prepareErrorMessage): \(msg)"])
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
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return results
    }

    func fetchArticles(
        section: String? = nil,
        isRead: Bool? = nil,
        isSaved: Bool? = nil,
        limit: Int? = 500,
        after: ArticleQueryCursor? = nil,
        id: String? = nil,
        canonicalURL: String? = nil,
        eventID: String? = nil,
        wholeStory: Bool = false,
        includingOriginals: Bool = false,
        publicationWindow: ClosedRange<Date>? = nil,
        muting: MuteRules = MuteRules(),
        hidingWaitingStories: Bool = false
    ) throws -> [FeedArticle] {
        let criteria = FetchCriteria(
            section: section,
            isRead: isRead,
            isSaved: isSaved,
            limit: limit,
            after: after,
            id: id,
            canonicalURL: canonicalURL,
            eventID: eventID,
            wholeStory: wholeStory,
            includingOriginals: includingOriginals,
            publicationWindow: publicationWindow,
            muting: muting,
            hidingWaitingStories: hidingWaitingStories
        )
        let (query, params) = try buildFetchArticlesQuery(criteria: criteria)
        let results = try executeQueryArticles(
            sql: query, params: params, prepareErrorMessage: "Failed to prepare fetch query")
        return includingOriginals ? results : try curateImages(in: results)
    }

    // MARK: - Full Text Search (FTS5)

    private func buildSearchQuery(parsed: ArticleFilterQuery, muting: MuteRules, after: ArticleQueryCursor?, limit: Int)
        -> (sql: String, params: [QueryParameter])
    {
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

        sql = sql.replacingOccurrences(
            of: "a.reader_document\n",
            with: "a.reader_document, " + (cleanTerms.isEmpty ? Self.articleDateOrder : "fts.rank") + "\n")
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
        guard db != nil else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parsed = ArticleFilterQuery.parse(trimmed)
        let (sql, params) = buildSearchQuery(parsed: parsed, muting: muting, after: after, limit: limit)
        let results = try executeQueryArticles(
            sql: sql, params: params, prepareErrorMessage: "Failed to prepare FTS search query")
        return try curateImages(in: results)
    }

    /// "Search for …" when a search finds nothing (#708): the query with misspelled words replaced by the closest
    /// words of stored headlines and feed summaries, offered only when that search finds stories.
    func searchSuggestion(query: String, muting: MuteRules = MuteRules()) throws -> String? {
        guard let corrected = SearchSpelling.corrected(query, vocabulary: try spellingVocabulary()) else { return nil }
        return try searchArticles(query: corrected, limit: 1, muting: muting).isEmpty ? nil : corrected
    }

    /// Word counts of visible headlines and feed summaries, rebuilt only after stories are added, removed, re-worded
    /// or reconciled: every insert and every headline or summary change appends a `publisher_content_revisions` row.
    private func spellingVocabulary() throws -> [String: Int] {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        func eachRow(_ sql: String, _ body: (OpaquePointer?) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db, "Cannot prepare spelling vocabulary query")
            }
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                body(statement)
                status = sqlite3_step(statement)
            }
            // A scan that stops early must not be cached as the whole vocabulary.
            guard status == SQLITE_DONE else { throw sqliteError(db, "Cannot read spelling vocabulary") }
        }
        var key = ""
        try eachRow(
            """
            SELECT (SELECT count(*) FROM articles), (SELECT coalesce(max(rowid), 0) FROM publisher_content_revisions),
                   (SELECT count(*) FROM article_reconciliations);
            """
        ) {
            key = "\(sqlite3_column_int64($0, 0)):\(sqlite3_column_int64($0, 1)):\(sqlite3_column_int64($0, 2))"
        }
        if let spellingCache, spellingCache.key == key { return spellingCache.words }
        var words: [String: Int] = [:]
        try eachRow(
            "SELECT a.title || ' ' || coalesce(a.description, '') FROM articles a WHERE \(Self.visibleArticle);"
        ) {
            guard let text = sqlite3_column_text($0, 0) else { return }
            for word in SearchSpelling.words(in: String(cString: text)) { words[word, default: 0] += 1 }
        }
        spellingCache = (key, words)
        return words
    }

    // MARK: - State Mutations

    func markRead(articleId: String, isRead: Bool) throws {
        let articleId = try resolvedArticleID(articleId)
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let sql = """
            INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
            VALUES (?, ?, 0, ?, NULL)
            ON CONFLICT(article_id) DO UPDATE SET
                is_read = excluded.is_read,
                read_at = excluded.read_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare markRead statement"])
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
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to execute markRead"])
        }
    }

    func markReadBatch(articleIds: [String], isRead: Bool) throws {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare markReadBatch statement"])
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to execute markReadBatch for id: \(articleId)"])
                }
            }
            try commitTransaction()
        } catch {
            loggedOptional("rollbackTransaction") { try rollbackTransaction() }
            throw error
        }
    }

    func batchMarkSaved(_ articleIds: Set<String>) throws {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare batchMarkSaved statement"])
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to execute batchMarkSaved for \(articleId)"])
                }
            }
            try commitTransaction()
        } catch {
            loggedOptional("rollbackTransaction") { try rollbackTransaction() }
            throw error
        }
    }

    func markAllRead(feedUrl: String? = nil, muting: MuteRules = MuteRules()) throws {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        // Only unread stories the reading feed shows: earlier read times stay as they were, and reconciled
        // originals, muted stories and analysis-only panel reports stay as they are (marking a panel report read would
        // surface it in History; a muted one would count as a reading interest).
        let collection = collectionScope()
        var params: [QueryParameter] = [("double", Date().timeIntervalSince1970)] + collection.params
        var sql = """
            UPDATE article_state SET is_read = 1, read_at = ?
            WHERE is_read = 0 AND article_id IN (
                SELECT a.id FROM articles a WHERE \(Self.visibleArticle)\(collection.sql)
            """
        if let feedUrl {
            sql += " AND a.id IN (SELECT article_id FROM article_feeds WHERE feed_url = ?)"
            params.append(("text", feedUrl))
        }
        if !muting.isEmpty {
            sql += " AND NOT \(Self.mutedArticle)"
            params += Self.mutingParameters(muting)
        }
        sql += ");"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    func toggleSaved(articleId: String) throws -> Bool {
        let next = try !isSaved(articleId: articleId)
        try setSaved(articleId: articleId, isSaved: next)
        return next
    }

    func setSaved(articleId: String, isSaved: Bool) throws {
        let articleId = try resolvedArticleID(articleId)
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let sql = """
            INSERT INTO article_state (article_id, is_read, is_saved, read_at, saved_at)
            VALUES (?, 0, ?, NULL, ?)
            ON CONFLICT(article_id) DO UPDATE SET
                is_saved = excluded.is_saved,
                saved_at = excluded.saved_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare toggleSaved statement"])
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to execute toggleSaved"])
        }
    }

    func isRead(articleId: String) throws -> Bool {
        let articleId = try resolvedArticleID(articleId)
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
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
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
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
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let sql =
            "SELECT article_id FROM article_state s WHERE is_read = 1 AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = s.article_id);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db, "Could not load read stories")
        }
        defer { sqlite3_finalize(stmt) }

        var set = Set<String>()
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                set.insert(String(cString: cStr))
            }
            status = sqlite3_step(stmt)
        }
        // A partial list would show read stories as unread.
        guard status == SQLITE_DONE else { throw sqliteError(db, "Could not load read stories") }
        return set
    }

    func getSavedArticles() throws -> [FeedArticle] {
        return try fetchArticles(isSaved: true)
    }

    /// Saved stories, newest save first, or the read history, newest read first, for File › Export (#565).
    func exportedStories(saved: Bool) throws -> [StoryExportEntry] {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let time = saved ? "s.saved_at" : "s.read_at"
        let sql = """
            SELECT a.title, a.canonical_url, a.source, a.published_at, \(time) FROM articles a
            JOIN article_state s ON s.article_id = a.id
            WHERE \(saved ? "s.is_saved" : "s.is_read") = 1 AND \(Self.visibleArticle)
            ORDER BY \(time) DESC, a.published_at DESC, a.id;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db, "Could not load stories to export")
        }
        defer { sqlite3_finalize(stmt) }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
        }
        var entries = [StoryExportEntry]()
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            let published = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let marked =
                sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let link = text(1)
            let publisher = FeedCatalog.publisher(forLink: link) ?? EventFeedSummary.displaySource(text(2))
            var entry = StoryExportEntry(
                title: text(0), publisher: publisher, url: link,
                published: published == DateParser.unknownDate ? nil : published)
            if saved { entry.savedAt = marked } else { entry.readAt = marked }
            entries.append(entry)
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw sqliteError(db, "Could not load stories to export") }
        return entries
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
            if let known = repeatedBySource[article.source] {
                repeated = known
            } else {
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher image recurrence"])
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
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Cannot read publisher image recurrence"])
        }
        return urls
    }

    func publisherContentRevisions(for articleID: String) throws -> [PublisherContentRevision] {
        let id = try resolvedArticleID(articleID)
        return try eventRows(
            "SELECT version, observed_at, kind, changed_fields, input_text_hash FROM publisher_content_revisions WHERE article_id = ? ORDER BY version DESC LIMIT 20;",
            [.text(id)]
        ).compactMap { row in
            guard let version = row[0].flatMap(Int.init), let timestamp = row[1].flatMap(Double.init),
                let kind = row[2].flatMap(PublisherContentRevision.Kind.init(rawValue:)),
                let fields = row[3].flatMap(Int.init), let hash = row[4]
            else { return nil }
            return PublisherContentRevision(
                version: version, observedAt: Date(timeIntervalSince1970: timestamp),
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
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }

        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { loggedOptional("rollbackTransaction") { try rollbackTransaction() } }
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
                }
            } else if let readerDocument {
                updates.append("reader_document = ?")
                params.append(("text", String(decoding: try JSONEncoder().encode(readerDocument), as: UTF8.self)))
            }
            if let document = readerDocument, document.version >= 4, let selected = document.leadImageURL {
                updates.append("image_url = ?")
                params.append(("text", selected))
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
                    throw NSError(
                        domain: "DatabaseEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot update publisher content"])
                }
            } else {
                throw NSError(
                    domain: "DatabaseEngine", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot prepare publisher content update"])
            }
        }

        // 2. Update enrichment table
        let enrichSql = """
            INSERT INTO article_enrichment (
                article_id, summary, sentiment, entities, topics, content_fetched, enriched_at, category
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(article_id) DO UPDATE SET
                category = coalesce(excluded.category, article_enrichment.category),
                summary = coalesce(excluded.summary, article_enrichment.summary),
                sentiment = coalesce(excluded.sentiment, article_enrichment.sentiment),
                entities = coalesce(excluded.entities, article_enrichment.entities),
                topics = coalesce(excluded.topics, article_enrichment.topics),
                content_fetched = max(excluded.content_fetched, article_enrichment.content_fetched),
                enriched_at = excluded.enriched_at;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, enrichSql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prepare enrichment update"])
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        if let s = summary {
            sqlite3_bind_text(stmt, 2, s, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let sent = sentiment { sqlite3_bind_double(stmt, 3, sent) } else { sqlite3_bind_null(stmt, 3) }
        if let ent = entities,
            let data = loggedOptional("encodeEntities", { try JSONEncoder().encode(ent) }),
            let str = String(data: data, encoding: .utf8)
        {
            sqlite3_bind_text(stmt, 4, str, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let top = topics,
            let data = loggedOptional("encodeTopics", { try JSONEncoder().encode(top) }),
            let str = String(data: data, encoding: .utf8)
        {
            sqlite3_bind_text(stmt, 5, str, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, content != nil ? 1 : 0)
        sqlite3_bind_double(stmt, 7, now)
        if let category {
            sqlite3_bind_text(stmt, 8, category, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot update enrichment"])
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
    func saveArticleAnalysis(_ analysis: ArticleAnalysis, for articleId: String, expectedInputHash: String? = nil)
        throws -> Bool
    {
        let articleId = try resolvedArticleID(articleId)
        guard let article = try fetchArticles(limit: 1, id: articleId).first else { return false }
        let inputHash = article.publisherInputHash
        if let expectedInputHash, expectedInputHash != inputHash { return false }
        let inputVersion = try publisherContentRevisions(for: articleId).first?.version ?? 1
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }

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
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Prepare failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, analysis.summary, -1, Self.sqliteTransient)

        if let kpData = loggedOptional("encodeKeyPoints", { try JSONEncoder().encode(analysis.keyPoints) }),
            let kpStr = String(data: kpData, encoding: .utf8)
        {
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

        if let entData = loggedOptional("encodeAnalysisEntities", { try JSONEncoder().encode(analysis.entities) }),
            let entStr = String(data: entData, encoding: .utf8)
        {
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
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Step failed: \(msg)"])
        }
        return true
    }

    /// Fetches persisted ArticleAnalysis for an article (if previously analyzed).
    func fetchArticleAnalysis(for articleId: String) -> ArticleAnalysis? {
        guard let db = db,
            let articleId = loggedOptional("resolvedArticleID", { try resolvedArticleID(articleId) })
        else { return nil }
        let sql = """
            SELECT summary, key_points, category, sentiment, entities, model_identifier, analysis_version
            FROM article_enrichment
            WHERE article_id = ? AND summary IS NOT NULL AND input_text_hash = ?
                AND input_content_version = (SELECT max(version) FROM publisher_content_revisions WHERE article_id = ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard
            let article = loggedOptional(
                "fetchArticlesForAnalysis", { try fetchArticles(limit: 1, id: articleId) })?.first
        else { return nil }
        sqlite3_bind_text(stmt, 1, articleId, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, article.publisherInputHash, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, articleId, -1, Self.sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let summaryCStr = sqlite3_column_text(stmt, 0) else { return nil }
        let summary = String(cString: summaryCStr)

        var keyPoints: [String] = []
        if let kpCStr = sqlite3_column_text(stmt, 1) {
            let kpStr = String(cString: kpCStr)
            if let data = kpStr.data(using: .utf8),
                let decoded = loggedOptional("decodeKeyPoints", { try JSONDecoder().decode([String].self, from: data) })
            {
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
            if let data = entStr.data(using: .utf8),
                let decoded = loggedOptional(
                    "decodeAnalysisEntities", { try JSONDecoder().decode([EntityResult].self, from: data) })
            {
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

    /// Clears all AI analysis data: summaries, key points, entities, event overviews, story embeddings, stored matcher
    /// signals, the pair decisions' stored signals (which resets the verdict calibration, #629) and the World Tension
    /// history. Articles, events, pair decisions and subscriptions remain intact.
    func clearArticleEnrichment() throws {
        guard db != nil else { return }
        try requireWritable()
        try beginTransaction()
        do {
            try clearWorldTensionHistory()
            try executeSimple("DELETE FROM article_enrichment;")
            try clearEventOverviews()
            try executeSimple("DELETE FROM article_embeddings;")
            try executeSimple("DELETE FROM article_features;")
            try executeSimple("UPDATE pair_assessments SET features = NULL;")
            try commitTransaction()
        } catch {
            loggedOptional("rollbackTransaction") { try rollbackTransaction() }
            throw error
        }
        logger.info("Cleared all article enrichment data.")
    }

    /// Clears persisted article body text from local storage.
    /// Preserves subscriptions, saved stories, and read history markers.
    func clearArticleCache() throws {
        try beginTransaction()
        do {
            try executeSimple(
                "UPDATE articles SET content = NULL, reader_document = NULL WHERE id NOT IN (\(Self.savedDocumentIDs));"
            )
            try executeSimple("DELETE FROM article_enrichment WHERE article_id NOT IN (\(Self.savedDocumentIDs));")
            // Feed-provided bodies return only from an unconditional refresh.
            try executeSimple("UPDATE feeds SET etag = NULL, last_modified = NULL;")
            try commitTransaction()
        } catch {
            loggedOptional("rollbackTransaction") { try rollbackTransaction() }
            throw error
        }
    }

    /// Clears replaceable data; article headers, read history and saved bodies are user data.
    func clearAllDatabaseCache() throws {
        try requireWritable()
        try clearWorldTensionHistory()
        try beginTransaction()
        do {
            try executeSimple("DELETE FROM article_enrichment;")
            try executeSimple(
                "UPDATE articles SET content = NULL, reader_document = NULL WHERE id NOT IN (\(Self.savedDocumentIDs));"
            )
            try executeSimple("UPDATE feeds SET etag = NULL, last_modified = NULL;")
            try commitTransaction()
        } catch {
            loggedOptional("rollbackTransaction") { try rollbackTransaction() }
            throw error
        }
    }

    // MARK: - Retention Policy & Pruning

    /// Prunes read articles older than `keepReadDays` and derived intelligence rows outside active windows (#536, #537).
    /// Never prunes unread articles or saved stories.
    @discardableResult
    func pruneOldArticles(keepReadDays: Int = 30, now: Date = Date()) throws -> Int {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        let nowTimestamp = now.timeIntervalSince1970
        let cutoff = nowTimestamp - Double(keepReadDays * 86400)

        let expired = """
            SELECT a.id FROM articles a JOIN article_state s ON s.article_id = a.id
            WHERE s.is_read = 1 AND s.is_saved = 0 AND \(Self.articleDateOrder) < ?1
                AND \(Self.visibleArticle)
                AND NOT EXISTS (SELECT 1 FROM event_overview_citations c
                    WHERE c.article_id = a.id OR c.article_id IN (
                        SELECT duplicate_id FROM article_reconciliations WHERE survivor_id = a.id))
            """
        let doomed = """
            \(expired)
            UNION SELECT r.duplicate_id FROM article_reconciliations r WHERE r.survivor_id IN (\(expired))
            """
        // A feed can keep serving a story long after it was read and pruned. Its stored ID and identity aliases
        // stay behind in `expired_stories` under a `pruned:` prefix, so `upsertArticles` never brings it back as a
        // new, unread story (#783). Only ID keys are kept: a URL can later carry a different story (a recurring or
        // live page), which must still arrive. Unprefixed rows are old importance-expiry tombstones and suppress
        // nothing.
        // ponytail: tombstones are never pruned (about three short rows per pruned story); expire old ones if the
        // table ever matters for size.
        let tombstones = """
            INSERT OR REPLACE INTO expired_stories (key, expired_at)
            SELECT 'pruned:' || value, ?2 FROM article_aliases
                WHERE kind = 'id' AND article_id IN (\(doomed))
            UNION SELECT 'pruned:' || id, ?2 FROM articles WHERE id IN (\(doomed));
            """
        try beginTransaction()
        defer {
            if sqlite3_get_autocommit(db) == 0 { loggedOptional("rollbackTransaction") { try rollbackTransaction() } }
        }
        var changes = 0
        for (sql, step) in [(tombstones, "tombstones"), ("DELETE FROM articles WHERE id IN (\(doomed));", "pruning")] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db, "Could not prepare retention \(step)")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            if sql == tombstones { sqlite3_bind_double(stmt, 2, nowTimestamp) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError(db, "Retention \(step) failed") }
            changes = Int(sqlite3_changes(db))
        }
        try commitTransaction()
        // The only delete of stories: SQLite may reuse a deleted top rowid, so the spelling cache key could repeat.
        if changes > 0 { spellingCache = nil }
        try pruneEmptyEvents()

        // Prune derived intelligence rows that are no longer needed for active clustering (#537):
        // 1. Pair assessments older than 30 days.
        let pairCutoff = nowTimestamp - 30 * 86400
        var pairStmt: OpaquePointer?
        // A pair the reader judged keeps its signals: the verdict calibration (#629) fits on them.
        let prunePairs = """
            DELETE FROM pair_assessments WHERE assessed_at < ?
                AND NOT EXISTS (SELECT 1 FROM event_inclusions i
                    WHERE i.article_id = pair_assessments.article_id AND i.other_article_id = pair_assessments.other_article_id)
                AND NOT EXISTS (SELECT 1 FROM event_exclusions x
                    WHERE x.article_id = pair_assessments.article_id AND x.other_article_id = pair_assessments.other_article_id);
            """
        if sqlite3_prepare_v2(db, prunePairs, -1, &pairStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(pairStmt) }
            sqlite3_bind_double(pairStmt, 1, pairCutoff)
            _ = sqlite3_step(pairStmt)
        }

        // 2. Cached matcher features and sentence embeddings for articles outside the 72-hour active clustering
        //    window that are not members of any stored event.
        let activeWindowCutoff = nowTimestamp - 72 * 3600
        let staleSingletonArticleIDs = """
            SELECT a.id FROM articles a
            WHERE \(Self.articleDateOrder) < ?
                AND NOT EXISTS (SELECT 1 FROM event_members m WHERE m.article_id = a.id)
            """
        for derivedTable in ["article_features", "article_embeddings"] {
            var derivedStmt: OpaquePointer?
            let derivedSQL = "DELETE FROM \(derivedTable) WHERE article_id IN (\(staleSingletonArticleIDs));"
            if sqlite3_prepare_v2(db, derivedSQL, -1, &derivedStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(derivedStmt) }
                sqlite3_bind_double(derivedStmt, 1, activeWindowCutoff)
                _ = sqlite3_step(derivedStmt)
            }
        }

        // Return freed pages to the filesystem without a full-table rebuild (#536).
        try executeSimple("PRAGMA incremental_vacuum;")

        if changes > 0 {
            logger.info("Pruned \(changes) read articles older than \(keepReadDays) days")
        }
        return changes
    }

    // MARK: - Counts & Diagnostics

    func counts() throws -> (unread: Int, saved: Int, total: Int) {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }

        var total = 0
        var unread = 0
        var saved = 0

        var stmt: OpaquePointer?
        let scope = collectionScope()
        let sql = """
            SELECT
                count(a.id) as total_count,
                coalesce(sum(case when s.is_read = 0 then 1 else 0 end), 0) as unread_count,
                coalesce(sum(case when s.is_saved = 1 then 1 else 0 end), 0) as saved_count
            FROM articles a
            JOIN article_state s ON s.article_id = a.id
            WHERE \(Self.visibleArticle) \(scope.sql);
            """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            bind(scope.params, to: stmt)
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
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        guard !muting.isEmpty else { return 0 }
        var sql =
            "SELECT count(*) FROM articles a JOIN article_state s ON s.article_id = a.id LEFT JOIN article_enrichment ae ON ae.article_id = a.id"
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to prepare muted count: \(String(cString: sqlite3_errmsg(db)))"
                ])
        }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Story Visibility

    /// Compatibility for historical audit callers. Importance no longer hides stories.
    func waitingStoryCount(
        section _: String? = nil, isRead _: Bool? = nil, isSaved _: Bool? = nil, muting _: MuteRules = MuteRules()
    ) throws -> Int {
        0
    }

    /// Recent stories without an importance rating, best-covered and newest first.
    func pendingImportanceRows(activeSince: Date, limit: Int) throws -> [EventMatchRow] {
        try eventMatchRows(
            """
            \(Self.eventMatchColumns)
            WHERE NOT EXISTS (SELECT 1 FROM story_importance i WHERE i.article_id = a.id)
                AND \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle)
            ORDER BY (SELECT count(*) FROM event_members peer WHERE peer.event_id = m.event_id) DESC, \(Self.articleDateOrder) DESC, a.id
            LIMIT ?;
            """, [.real(activeSince.timeIntervalSince1970), .integer(limit)])
    }

    /// Recent visible stories rated at `level`, newest first: the population of the independent importance review (#309).
    func ratedImportanceRows(level: StoryImportance, activeSince: Date) throws -> [EventMatchRow] {
        try eventMatchRows(
            """
            \(Self.eventMatchColumns)
            WHERE EXISTS (SELECT 1 FROM story_importance i WHERE i.article_id = a.id AND i.level = ?)
                AND \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle)
            ORDER BY \(Self.articleDateOrder) DESC, a.id;
            """, [.integer(level.rawValue), .real(activeSince.timeIntervalSince1970)])
    }

    @discardableResult
    func recordImportance(
        _ articleID: String, _ importance: StoryImportance, at date: Date = Date(),
        expectedTitle: String? = nil, expectedDescription: String? = nil
    ) throws -> Bool {
        let title: EventValue = .text(expectedTitle ?? "")
        let description: EventValue = .text(expectedDescription ?? "")
        try eventRows(
            """
            INSERT INTO story_importance(article_id, level, judged_at)
            SELECT id, ?, ? FROM articles WHERE id = ?
                AND (? = 0 OR title IS ?) AND (? = 0 OR coalesce(description, '') IS ?)
            ON CONFLICT(article_id) DO UPDATE SET level = excluded.level, judged_at = excluded.judged_at;
            """,
            [
                .integer(importance.rawValue), .real(date.timeIntervalSince1970), .text(articleID),
                .integer(expectedTitle == nil ? 0 : 1), title, .integer(expectedDescription == nil ? 0 : 1),
                description,
            ])
        return sqlite3_changes(db) > 0
    }

    /// Committed, unreconciled stories eligible for notification, independent of importance.
    func notificationStoryIDs(_ articleIDs: [String]) throws -> Set<String> {
        var eligible = Set<String>()
        for start in stride(from: 0, to: articleIDs.count, by: 500) {
            let ids = Array(articleIDs[start..<min(start + 500, articleIDs.count)])
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try eventRows(
                "SELECT a.id FROM articles a WHERE a.id IN (\(placeholders)) AND \(Self.visibleArticle);",
                ids.map { .text($0) })
            eligible.formUnion(rows.compactMap { $0[0] })
        }
        return eligible
    }

    /// The delivery tables as of `now` (#665). A time later than `now`, left by a clock set back, is rewritten as `now`
    /// first, so no window outlasts its length; rows past their use are dropped.
    func notificationLedger(now: Date) throws -> NotificationLedger {
        let clock = now.timeIntervalSince1970
        try eventRows(
            "UPDATE notification_deliveries SET delivered_at = ? WHERE delivered_at > ?;", [.real(clock), .real(clock)])
        try eventRows(
            "UPDATE event_notifications SET notified_at = ? WHERE notified_at > ?;", [.real(clock), .real(clock)])
        try eventRows(
            "UPDATE notification_priority_queue SET queued_at = ? WHERE queued_at > ?;", [.real(clock), .real(clock)])
        try eventRows("DELETE FROM notification_priority_queue WHERE queued_at < ?;", [.real(clock - 86400)])
        try foldMergedNotifications(since: clock - 86400)
        func count(_ sql: String, since: TimeInterval) throws -> Int {
            let value = try eventRows(sql, [.real(clock - since)]).first?.first ?? nil
            return value.flatMap { Int($0) } ?? 0
        }
        var ledger = NotificationLedger()
        ledger.normalLastHour = try count(
            "SELECT count(*) FROM notification_deliveries WHERE lane = 0 AND delivered_at > ?;", since: 3600)
        ledger.priorityLastHalfHour = try count(
            "SELECT count(*) FROM notification_deliveries WHERE lane = 2 AND grouped = 0 AND delivered_at > ?;",
            since: NotificationService.priorityWindow)
        ledger.priorityGroupLastHalfHour =
            try count(
                "SELECT count(*) FROM notification_deliveries WHERE lane = 2 AND grouped = 1 AND delivered_at > ?;",
                since: NotificationService.priorityWindow) > 0
        for row in try eventRows(
            "SELECT feed_url, max(delivered_at) FROM notification_deliveries WHERE lane = 1 GROUP BY feed_url;")
        {
            if let feed = row[0], let time = row[1].flatMap(Double.init) {
                ledger.lastStarred[feed] = Date(timeIntervalSince1970: time)
            }
        }
        for row in try eventRows(
            "SELECT event_id, lead_key, lane FROM event_notifications WHERE notified_at >= ?;", [.real(clock - 86400)])
        {
            if let event = row[0], let key = row[1], let lane = row[2].flatMap(Int.init).flatMap(NotificationLane.init)
            {
                ledger.announced[event] = .init(leadKey: key, lane: lane)
            }
        }
        ledger.priorityQueue = try eventRows(
            "SELECT event_id, title, score, lead_key, story_id FROM notification_priority_queue ORDER BY score DESC;"
        ).compactMap { row in
            guard let event = row[0], let title = row[1], let score = row[2].flatMap({ Double($0) }), let key = row[3]
            else { return nil }
            return QueuedPriority(event: event, title: title, score: score, leadKey: key, story: row[4] ?? "")
        }
        return ledger
    }

    /// An event merged into another (#524, #541) hands its delivery state to the event it joined (#545), so a merge
    /// never makes an announced story new again. An announcement of the last day keeps its time and lane under the
    /// survivor, recorded with the survivor's lead headline now (or the survivor's own recent one), so only a later
    /// change of that headline notifies again. A waiting priority key moves the same way. Merges forward one hop, so
    /// one pass settles every row.
    private func foldMergedNotifications(since cutoff: TimeInterval) throws {
        let forwarded = "JOIN events e ON e.id = t.event_id WHERE e.merged_into IS NOT NULL"
        let announced = try eventRows(
            "SELECT t.event_id, e.merged_into, t.lead_key, t.notified_at, t.lane FROM event_notifications t \(forwarded);"
        )
        let queued = try eventRows(
            "SELECT t.event_id, e.merged_into, t.lead_key FROM notification_priority_queue t \(forwarded);")
        guard !announced.isEmpty || !queued.isEmpty else { return }
        let leads = try eventLeadTitles(Set((announced + queued).compactMap { $0[1] }))
        func leadKey(_ row: [String?]) -> String {
            row[1].flatMap { leads[$0] }.map { EventFeedSummary.titleKey($0) } ?? row[2] ?? ""
        }
        for row in announced {
            guard let absorbed = row[0], let survivor = row[1] else { continue }
            if let time = row[3].flatMap({ Double($0) }), time >= cutoff, let lane = row[4].flatMap({ Int($0) }) {
                try eventRows(
                    """
                    INSERT INTO event_notifications (event_id, notified_at, lead_key, lane) VALUES (?, ?, ?, ?)
                    ON CONFLICT(event_id) DO UPDATE SET
                        lane = CASE WHEN event_notifications.notified_at >= ?
                            THEN max(event_notifications.lane, excluded.lane) ELSE excluded.lane END,
                        lead_key = CASE WHEN event_notifications.notified_at >= ?
                            THEN event_notifications.lead_key ELSE excluded.lead_key END,
                        notified_at = max(event_notifications.notified_at, excluded.notified_at);
                    """,
                    [
                        .text(survivor), .real(time), .text(leadKey(row)), .integer(lane), .real(cutoff),
                        .real(cutoff),
                    ])
            }
            try eventRows("DELETE FROM event_notifications WHERE event_id = ?;", [.text(absorbed)])
        }
        for row in queued {
            guard let absorbed = row[0], let survivor = row[1] else { continue }
            // A survivor already waiting keeps its own row.
            try eventRows(
                "UPDATE OR IGNORE notification_priority_queue SET event_id = ?, lead_key = ? WHERE event_id = ?;",
                [.text(survivor), .text(leadKey(row)), .text(absorbed)])
            try eventRows("DELETE FROM notification_priority_queue WHERE event_id = ?;", [.text(absorbed)])
        }
    }

    /// Records one posted banner (#665): its delivery row, and each event it announces with the highest lane that
    /// covered it in the last day. Announced events leave the priority queue; rows older than a week go.
    func recordNotification(_ banner: PlannedBanner, at date: Date) throws {
        let now = date.timeIntervalSince1970
        try eventRows(
            """
            INSERT INTO notification_deliveries (lane, grouped, feed_url, story_count, delivered_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            [
                .integer(banner.lane.rawValue), .integer(banner.grouped ? 1 : 0),
                banner.feedURL.map { .text($0) } ?? .null,
                .integer(banner.count), .real(now),
            ])
        for (event, key) in banner.announces {
            try eventRows(
                """
                INSERT INTO event_notifications (event_id, notified_at, lead_key, lane) VALUES (?, ?, ?, ?)
                ON CONFLICT(event_id) DO UPDATE SET
                    lane = CASE WHEN event_notifications.notified_at >= ? THEN max(event_notifications.lane, excluded.lane)
                        ELSE excluded.lane END,
                    notified_at = excluded.notified_at, lead_key = excluded.lead_key;
                """, [.text(event), .real(now), .text(key), .integer(banner.lane.rawValue), .real(now - 86400)])
            try eventRows("DELETE FROM notification_priority_queue WHERE event_id = ?;", [.text(event)])
        }
        try eventRows("DELETE FROM event_notifications WHERE notified_at < ?;", [.real(now - 7 * 86400)])
        try eventRows("DELETE FROM notification_deliveries WHERE delivered_at < ?;", [.real(now - 7 * 86400)])
    }

    /// Priority keys over both priority limits wait here for the next grouped priority banner, at most a day.
    func queuePriority(_ waiting: [QueuedPriority], at date: Date) throws {
        for item in waiting {
            try eventRows(
                """
                INSERT INTO notification_priority_queue (event_id, title, score, lead_key, queued_at, story_id)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO UPDATE SET title = excluded.title, score = max(score, excluded.score),
                    lead_key = excluded.lead_key, story_id = excluded.story_id;
                """,
                [
                    .text(item.event), .text(item.title), .real(item.score), .text(item.leadKey),
                    .real(date.timeIntervalSince1970), .text(item.story),
                ])
        }
    }

    /// Visible, unmuted stories each feed brought in (`created_at`) after its given time, oldest first (#665).
    func feedStories(since: [String: Date], muting: MuteRules) throws -> [String: [FeedArticle]] {
        var stories: [String: [FeedArticle]] = [:]
        for (feed, time) in since {
            let ids = try eventRows(
                """
                SELECT a.id FROM article_feeds af JOIN articles a ON a.id = af.article_id
                WHERE af.feed_url = ? AND a.created_at > ? AND \(Self.visibleArticle) ORDER BY a.created_at, a.id;
                """, [.text(feed), .real(time.timeIntervalSince1970)]
            ).compactMap { $0.first ?? nil }
            stories[feed] = try ids.compactMap { try fetchArticles(limit: 1, id: $0, muting: muting).first }
        }
        return stories
    }

    /// The title of each event's lead story: the one that opened the event (lowest joined version, then earliest
    /// publication). It stays the same when later reports join, unlike the newest member a card shows.
    func eventLeadTitles(_ eventIDs: Set<String>) throws -> [String: String] {
        var titles: [String: String] = [:]
        let ids = eventIDs.sorted()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            for row in try eventRows(
                """
                SELECT m.event_id, a.title FROM event_members m JOIN articles a ON a.id = m.article_id
                WHERE m.event_id IN (\(placeholders)) ORDER BY m.event_id, m.joined_version, a.published_at, a.id;
                """, slice.map { .text($0) })
            {
                if let event = row[0], let title = row[1], titles[event] == nil { titles[event] = title }
            }
        }
        return titles
    }

    /// Distinct publishers among the members of each event, for notification triage (#588).
    func eventPublisherCounts(_ eventIDs: Set<String>) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let ids = eventIDs.sorted()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            for row in try eventRows(
                """
                SELECT m.event_id, count(DISTINCT a.source) FROM event_members m JOIN articles a ON a.id = m.article_id
                WHERE m.event_id IN (\(placeholders)) GROUP BY m.event_id;
                """, slice.map { .text($0) })
            {
                if let event = row[0], let count = row[1].flatMap({ Int($0) }) { counts[event] = count }
            }
        }
        return counts
    }

    /// Compatibility for historical audit callers. Only ordinary user-configured retention deletes stories.
    @discardableResult
    func expireWaitingStories(now: Date = Date(), keepingFeedURLs: [String] = []) throws -> Int {
        0
    }

    /// Interest signals stay on device and use a bounded recent reading/saving history, never publisher volume.
    /// When `resetAt` is provided, user reading/saving history before `resetAt` is ignored without modifying stored reading state or bookmarks.
    func briefingInterests(now: Date = Date(), resetAt: Date? = nil) throws -> [String: Int] {
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)
        let cutoff = max(thirtyDaysAgo, resetAt ?? .distantPast)
        let rows = try eventRows(
            """
            SELECT coalesce(ae.category, a.category), s.is_saved FROM article_state s JOIN articles a ON a.id = s.article_id
            LEFT JOIN article_enrichment ae ON ae.article_id = a.id
            WHERE (s.is_saved = 1 OR s.is_read = 1) AND max(coalesce(s.saved_at, 0), coalesce(s.read_at, 0)) >= ?
            ORDER BY max(coalesce(s.saved_at, 0), coalesce(s.read_at, 0)) DESC LIMIT 200;
            """, [.real(cutoff.timeIntervalSince1970)])
        var interests: [String: Int] = [:]
        for row in rows {
            if let category = row[0].flatMap(NewsCategory.match(from:)) {
                interests[category.rawValue.lowercased(), default: 0] += row[1] == "1" ? 3 : 1
            }
        }
        return interests
    }

    /// Stored signals only: one bounded read for the Briefing's at most 500 candidates and their event members.
    func briefingPriorities(articleIDs: [String]) throws -> [String: BriefingPriority] {
        let ids = Array(Set(articleIDs)).sorted()
        guard !ids.isEmpty else { return [:] }
        guard ids.count <= FiniteBriefing.candidateLimit else {
            throw Self.eventError("Too many Briefing candidates")
        }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try eventRows(
            """
            SELECT candidate.id, a.source, a.canonical_url, i.level, mine.event_id
            FROM articles candidate
            LEFT JOIN event_members mine ON mine.article_id = candidate.id
            LEFT JOIN event_members peer ON peer.event_id = mine.event_id
            JOIN articles a ON a.id = coalesce(peer.article_id, candidate.id)
            LEFT JOIN story_importance i ON i.article_id = a.id
            WHERE candidate.id IN (\(placeholders)) AND \(Self.visibleArticle)
            ORDER BY candidate.id, a.id;
            """, ids.map { .text($0) })
        var publishers: [String: Set<String>] = [:]
        var levels: [String: StoryImportance] = [:]
        var events: [String: String] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard let id = row[0] else { continue }
            events[id] = row[4]
            let publisher = FeedCatalog.publisher(forLink: row[2] ?? "") ?? row[1] ?? ""
            publishers[id, default: []].insert(EventFeedSummary.displaySource(publisher).lowercased())
            if let raw = row[3].flatMap(Int.init), let level = StoryImportance(rawValue: raw) {
                levels[id] = max(levels[id] ?? level, level)
            }
        }
        return Dictionary(
            uniqueKeysWithValues: publishers.map {
                (
                    $0.key,
                    BriefingPriority(
                        sourceCount: max(1, $0.value.count), importance: levels[$0.key], eventID: events[$0.key])
                )
            })
    }

    // MARK: - Story Images

    /// Shown, recent stories without any image in their event and not looked up yet: clustered stories first, then the
    /// newest. Each row carries its event so a pass looks up one report per event.
    /// `isRequestable` drops links the image client would refuse before they count toward `limit`, so they cannot
    /// crowd out stories behind them on every pass (#818).
    func imagelessStoryRows(
        activeSince: Date, limit: Int, muting: MuteRules = MuteRules(),
        isRequestable: @Sendable (String) -> Bool = { _ in true }
    ) throws -> [(
        id: String, link: String, eventID: String?
    )] {
        // ponytail: at most 2,000 recent candidates per pass, matching the clustering bound.
        let scope = collectionScope()
        let rows = try eventRows(
            """
            SELECT a.id, a.canonical_url, m.event_id FROM articles a
            LEFT JOIN event_members m ON m.article_id = a.id
            WHERE \(Self.articleDateOrder) >= ? AND \(Self.visibleArticle) \(scope.sql)
                AND NOT \(Self.mutedArticle)
                AND NOT EXISTS (SELECT 1 FROM story_images si WHERE si.article_id = a.id)
            ORDER BY (SELECT count(*) FROM event_members peer WHERE peer.event_id = m.event_id) DESC, \(Self.articleDateOrder) DESC, a.id
            LIMIT 2000;
            """,
            [.real(activeSince.timeIntervalSince1970)] + scope.params.map { .text($0.val as? String ?? "") }
                + [.text(muting.sourceParameter), .text(muting.topicParameter)])
        var results: [(id: String, link: String, eventID: String?)] = []
        var picturedEvents: [String: Bool] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard results.count < limit else { break }
            guard let id = row[0], let link = row[1], isRequestable(link) else { continue }
            let key = row[2] ?? id
            let pictured: Bool
            if let cached = picturedEvents[key] {
                pictured = cached
            } else {
                var members = try fetchArticles(limit: nil, id: row[2] == nil ? id : nil, eventID: row[2])
                // A member only on a collection feed (World Tension panel) is hidden from lists: its image does not
                // spare the listed stories a lookup (#595).
                if let eventID = row[2], !scope.sql.isEmpty {
                    let listed = Set(
                        try eventRows(
                            "SELECT a.id FROM event_members m JOIN articles a ON a.id = m.article_id WHERE m.event_id = ? \(scope.sql);",
                            [.text(eventID)] + scope.params.map { .text($0.val as? String ?? "") }
                        ).compactMap { $0[0] })
                    members = members.filter { listed.contains($0.id) }
                }
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
    func recordStoryImage(_ articleID: String, imageURL: String?, at date: Date = Date(), expectedLink: String? = nil)
        throws -> Bool
    {
        try inEventTransaction { () throws -> Bool in
            if let expectedLink,
                (try eventRows("SELECT canonical_url FROM articles WHERE id = ?;", [.text(articleID)])).first?[0]
                    != expectedLink
            {
                return false
            }
            var image = imageURL
            if let url = imageURL,
                !(try eventRows(
                    """
                    SELECT 1 FROM story_image_defaults WHERE url = ?1
                    UNION ALL SELECT 1 FROM story_images WHERE image_url = ?1 AND article_id != ?2 LIMIT 1;
                    """, [.text(url), .text(articleID)])).isEmpty
            {
                try eventRows("INSERT OR IGNORE INTO story_image_defaults(url) VALUES (?);", [.text(url)])
                try eventRows("UPDATE story_images SET image_url = NULL WHERE image_url = ?;", [.text(url)])
                image = nil
            }
            try eventRows(
                "INSERT OR REPLACE INTO story_images(article_id, image_url, checked_at) VALUES (?, ?, ?);",
                [.text(articleID), image.map { .text($0) } ?? .null, .real(date.timeIntervalSince1970)])
            return image != nil
        }
    }

    /// Found lead images by article ID.
    func storyImages(for articleIDs: [String]) throws -> [String: String] {
        guard !articleIDs.isEmpty else { return [:] }
        var images: [String: String] = [:]
        for chunk in stride(from: 0, to: articleIDs.count, by: 500).map({
            Array(articleIDs[$0..<min($0 + 500, articleIDs.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try eventRows(
                "SELECT article_id, image_url FROM story_images WHERE image_url IS NOT NULL AND article_id IN (\(placeholders));",
                chunk.map { .text($0) })
            {
                if let id = row[0], let url = row[1] { images[id] = url }
            }
        }
        return images
    }

    /// Stored stories each muting rule covers, for the muting settings. One pass over the library.
    func mutedRuleCounts(_ rules: MuteRules) throws -> MuteRuleCounts {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
        var counts = MuteRuleCounts()
        guard !rules.isEmpty else { return counts }
        let sql =
            "SELECT a.canonical_url, a.title, coalesce(a.description, '') FROM articles a WHERE \(Self.visibleArticle);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to prepare muting counts"])
        }
        defer { sqlite3_finalize(stmt) }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
        }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            for source in rules.matchedSources(link: text(0)) { counts.sources[source, default: 0] += 1 }
            for topic in rules.matchedTopics(title: text(1), description: text(2)) {
                counts.topics[topic, default: 0] += 1
            }
            for id in rules.matchedTopicSets(title: text(1), description: text(2)) {
                counts.topicSets[id, default: 0] += 1
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return counts
    }

    /// Stored articles a set of feeds delivered with a publication date inside `day`, with their event, for the news
    /// tension experiment. One row per article and delivering feed; undated stories never fall inside a day.
    func tensionCorpus(day: DateInterval, feedURLs: [String]) throws -> [TensionCorpusRow] {
        guard let db = db else {
            throw NSError(
                domain: "DatabaseEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
        }
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
            throw NSError(
                domain: "DatabaseEngine", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to prepare tension corpus: \(String(cString: sqlite3_errmsg(db)))"
                ])
        }
        defer { sqlite3_finalize(stmt) }
        var params: [QueryParameter] = feedURLs.map { ("text", $0) }
        params += [("double", day.start.timeIntervalSince1970), ("double", day.end.timeIntervalSince1970)]
        bind(params, to: stmt)
        var rows: [TensionCorpusRow] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            if let article = parseArticleRow(stmt),
                let feedURL = sqlite3_column_text(stmt, 18).map({ String(cString: $0) })
            {
                rows.append(
                    TensionCorpusRow(
                        article: article, feedURL: feedURL,
                        eventID: sqlite3_column_text(stmt, 19).map { String(cString: $0) }))
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw NSError(
                domain: "DatabaseEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return rows
    }

    // MARK: - Row Parser

    /// AI methodology v2 has its own atomic history; v1 formula scores are never relabelled as AI assessments.
    func worldTensionStorageKey() -> String { dbPath + ":world-tension-v2" }

    /// Days of World Tension readings kept on device: 90 since methodology v3 (#585), 30 before.
    static let worldTensionHistoryDays = 90

    private var worldTensionURL: URL {
        URL(fileURLWithPath: dbPath + ".world-tension-v2.json")
    }

    private func requireWritable() throws {
        if isReadOnly { throw CocoaError(.fileWriteVolumeReadOnly) }
    }

    private func clearWorldTensionHistory() throws {
        try requireWritable()
        if dbPath == ":memory:" {
            inMemoryWorldTension = []
            return
        }
        if FileManager.default.fileExists(atPath: worldTensionURL.path) {
            try Data("[]".utf8).write(to: worldTensionURL, options: .atomic)
        }
    }

    func worldTensionHistory() throws -> [WorldTensionReading] {
        guard db != nil else { throw CocoaError(.fileReadUnknown) }
        if dbPath == ":memory:" { return inMemoryWorldTension }
        guard FileManager.default.fileExists(atPath: worldTensionURL.path) else { return [] }
        let file = try FileHandle(forReadingFrom: worldTensionURL)
        defer { try? file.close() }
        let data = try file.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let history = try JSONDecoder().decode([WorldTensionReading].self, from: data)
        guard history.count <= Self.worldTensionHistoryDays, Set(history.map(\.id)).count == history.count,
            history.allSatisfy({
                $0.assessment.isValid(headlines: $0.headlines) && $0.evaluatedAt.timeIntervalSince1970.isFinite
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        return history.sorted { $0.evaluatedAt < $1.evaluatedAt }
    }

    /// Replaces the day's reading. With `keepingAssessment`, a model assessment already saved for that day stays and
    /// nothing is written (false), so a keyword estimate never replaces one (#523).
    @discardableResult
    func saveWorldTensionReading(_ reading: WorldTensionReading, keepingAssessment: Bool = false) throws -> Bool {
        try Task.checkCancellation()
        try requireWritable()
        guard reading.assessment.isValid(headlines: reading.headlines),
            reading.evaluatedAt.timeIntervalSince1970.isFinite
        else { throw CocoaError(.fileWriteInvalidFileName) }
        var history = try worldTensionHistory()
        if keepingAssessment, history.contains(where: { $0.id == reading.id && $0.assessment.isEstimate != true }) {
            return false
        }
        history.removeAll { $0.id == reading.id }
        history.append(reading)
        history.sort { $0.evaluatedAt < $1.evaluatedAt }
        history = Array(history.suffix(Self.worldTensionHistoryDays))
        if dbPath == ":memory:" {
            inMemoryWorldTension = history
            return true
        }
        try JSONEncoder().encode(history).write(to: worldTensionURL, options: .atomic)
        return true
    }

    private func parseArticleRow(_ stmt: OpaquePointer?) -> FeedArticle? {
        guard let stmt = stmt else { return nil }

        guard let idStr = sqlite3_column_text(stmt, 0),
            let canonicalStr = sqlite3_column_text(stmt, 2),
            let titleStr = sqlite3_column_text(stmt, 3),
            let sourceStr = sqlite3_column_text(stmt, 7)
        else {
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
            if let data = kpStr.data(using: .utf8),
                let decoded = loggedOptional(
                    "decodeRowKeyPoints", { try JSONDecoder().decode([String].self, from: data) })
            {
                keyPoints = decoded
            }
        }

        var entities: [EntityResult]?
        if let entCStr = sqlite3_column_text(stmt, 15) {
            let entStr = String(cString: entCStr)
            if let data = entStr.data(using: .utf8),
                let decoded = loggedOptional(
                    "decodeRowEntities", { try JSONDecoder().decode([EntityResult].self, from: data) })
            {
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
            readerDocument: sqlite3_column_text(stmt, 17).flatMap { raw in
                loggedOptional("decodeReaderDocument") {
                    try JSONDecoder().decode(ReaderDocument.self, from: Data(String(cString: raw).utf8))
                }
            }
        )
    }
}

// MARK: - SQLite functions

/// `news_muted_source(url, hosts)`: 1 when the URL's host is a muted host or one of its subdomains.
private func mutedSourceFunction(
    _ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 2, let values else { return sqlite3_result_int(context, 0) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    sqlite3_result_int(context, MuteRules.sourceList(text(1), mutes: text(0)) ? 1 : 0)
}

/// `news_muted_topic(title, description, phrases)`: 1 when the headline or summary contains a muted phrase as whole words.
private func mutedTopicFunction(
    _ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 3, let values else { return sqlite3_result_int(context, 0) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    sqlite3_result_int(context, MuteRules.topicList(text(2), mutes: text(0) + "\n" + text(1)) ? 1 : 0)
}

/// Pure SQLite bridge; publisher text is hashed locally and never logged.
func publisherInputFunction(
    _ context: OpaquePointer?, _ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 3, let arguments else {
        sqlite3_result_null(context)
        return
    }
    func text(_ index: Int) -> String { sqlite3_value_text(arguments[index]).map { String(cString: $0) } ?? "" }
    let hash = PublisherContentRevision.inputHash(title: text(0), description: text(1), content: text(2))
    sqlite3_result_text(context, hash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

/// `news_cosine(a, b)`: similarity of two stored `article_embeddings` vectors through vDSP
/// (`SentenceEmbedder.cosineSimilarity`; stored vectors are L2-normalized). NULL unless both are 384-float blobs.
func cosineFunction(
    _ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 2, let values else { return sqlite3_result_null(context) }
    func vector(_ index: Int) -> [Float]? {
        let value = values[index]
        guard sqlite3_value_type(value) == SQLITE_BLOB, let blob = sqlite3_value_blob(value) else { return nil }
        let dimension = SentenceEmbedder.vectorDimension
        let byteCount = dimension * MemoryLayout<Float>.stride
        guard Int(sqlite3_value_bytes(value)) == byteCount else { return nil }
        // SQLite does not promise Float alignment for blob memory, so copy the bytes instead of rebinding them.
        return [Float](unsafeUninitializedCapacity: dimension) { buffer, initialized in
            memcpy(buffer.baseAddress!, blob, byteCount)
            initialized = dimension
        }
    }
    guard let left = vector(0), let right = vector(1) else { return sqlite3_result_null(context) }
    sqlite3_result_double(context, SentenceEmbedder.cosineSimilarity(left, right))
}

/// Pure content classification for the one-time topic repair; never trusts an earlier generated label.
private func topicFunction(
    _ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 3, let values else { return sqlite3_result_null(context) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    let category =
        NaturalLanguageTopicClassifier.classifyContent(
            title: text(0), description: text(1), text: text(2))?.category ?? NewsCategory.world.rawValue
    sqlite3_result_text(context, category, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private func publisherNameFunction(
    _ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 2, let values else { return sqlite3_result_null(context) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    let name = FeedCatalog.publisher(forLink: text(0)) ?? text(1)
    sqlite3_result_text(context, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

/// Lists and in-memory callers share category precedence and whole-word fallback.
private func sectionFunction(
    _ context: OpaquePointer?, _ count: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard count == 4, let values else { return sqlite3_result_int(context, 0) }
    func text(_ index: Int) -> String { sqlite3_value_text(values[index]).map { String(cString: $0) } ?? "" }
    sqlite3_result_int(
        context, ArticleSection.matches(text(3), title: text(0), description: text(1), category: text(2)) ? 1 : 0)
}
