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

// Angelia · Athena (editorial selection) owns this file. Experimental, no production consumer.
// Register: docs/ANGELIA.md.

import Darwin
import Foundation
import SQLite3

struct PersonalizationPolicy: Sendable {
    let halfLife: TimeInterval
    let clickWeight: Double
    let saveWeight: Double
    let skipWeight: Double
}
struct EditorialRenderedImpression: Sendable {
    let impressionID: String
    let articleID: String
    let topicID: String
    let vector: [Float]?
    let modelVersion: String
    let at: Date
}
struct PersonalizationCounts: Sendable {
    let impressions: Int
    let skips: Int
    let clicks: Int
    let saves: Int
}
struct DiscoveryCandidate: Sendable {
    let articleID: String
    let topicID: String
    let isAdjacent: Bool
    let priorImpressions: Int
}
struct DiscoveryAllocation: Sendable {
    let requested: Int
    let articleIDs: [String]
    let shortage: Int
    let remainder: Int
}
enum PersonalizationError: Error {
    case invalidPolicy, invalidInput, invalidTime, foreignDatabase, sqlite
}

private final class PersonalizationConnection {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}

/// Experimental private store. Reward timestamps must be globally nondecreasing; failures roll back.
/// Raw impressions expire after 30 days; the derived profile persists until reset.
/// An impression ID identifies one visible episode. Scrolling past without engagement closes
/// it; a later click or save requires a new rendered impression ID. Scrolling after engagement
/// is neutral, and subsequent engagement on that episode remains valid.
actor EditorialPersonalization {
    private static let appID: Int32 = 0x4E45_5750
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let policy: PersonalizationPolicy
    private let modelVersion: String
    private let owner: PersonalizationConnection
    private var db: OpaquePointer { owner.handle }
    private let now: @Sendable () -> Date
    private var enabled = false

    init(
        policy: PersonalizationPolicy, modelVersion: String, path: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard policy.halfLife.isFinite, policy.halfLife > 0, policy.clickWeight.isFinite,
            policy.clickWeight > 0, policy.saveWeight.isFinite, policy.saveWeight > 0,
            policy.skipWeight.isFinite, policy.skipWeight < 0, !modelVersion.isEmpty, !modelVersion.contains("\0"),
            now().timeIntervalSince1970.isFinite
        else { throw PersonalizationError.invalidPolicy }
        self.policy = policy
        self.modelVersion = modelVersion
        self.now = now
        self.owner = try Self.openStore(path: path, modelVersion: modelVersion, now: now())
    }

    private static func openStore(path: String?, modelVersion: String, now: Date) throws -> PersonalizationConnection {
        if let path {
            let fd = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            if fd >= 0 {
                var reserved = stat()
                defer { Darwin.close(fd) }
                guard fstat(fd, &reserved) == 0 else { throw PersonalizationError.sqlite }
                do {
                    let owner = try openConnection(path, flags: SQLITE_OPEN_READWRITE)
                    try verifyIdentity(path, reserved)
                    try verifyEmpty(owner.handle)
                    try initialize(owner.handle, modelVersion: modelVersion)
                    try verifyStore(owner.handle, modelVersion: modelVersion)
                    try expire(owner.handle, at: now)
                    return owner
                } catch {
                    if (try? verifyIdentity(path, reserved)) != nil { _ = Darwin.unlink(path) }
                    throw error
                }
            }
            guard errno == EEXIST else { throw PersonalizationError.sqlite }
            var before = stat()
            guard lstat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
                throw PersonalizationError.foreignDatabase
            }
            let readonly = try openConnection(path, flags: SQLITE_OPEN_READONLY)
            try verifyIdentity(path, before)
            try verifyStore(readonly.handle, modelVersion: modelVersion)
            let owner = try openConnection(path, flags: SQLITE_OPEN_READWRITE)
            try verifyIdentity(path, before)
            try verifyStore(owner.handle, modelVersion: modelVersion)
            try expire(owner.handle, at: now)
            return owner
        }
        let owner = try openConnection(":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try initialize(owner.handle, modelVersion: modelVersion)
        return owner
    }

    private static func verifyIdentity(_ path: String, _ expected: stat) throws {
        var current = stat()
        guard lstat(path, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG,
            current.st_dev == expected.st_dev, current.st_ino == expected.st_ino
        else { throw PersonalizationError.foreignDatabase }
    }

    private static func openConnection(_ path: String, flags: Int32) throws -> PersonalizationConnection {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw PersonalizationError.sqlite
        }
        return PersonalizationConnection(handle)
    }

    private static func verifyEmpty(_ db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw PersonalizationError.foreignDatabase
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) == 0 else {
            throw PersonalizationError.foreignDatabase
        }
    }

    private static func verifyStore(_ db: OpaquePointer, modelVersion: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA application_id", -1, &statement, nil) == SQLITE_OK else {
            throw PersonalizationError.foreignDatabase
        }
        let valid = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == appID
        sqlite3_finalize(statement)
        guard valid else { throw PersonalizationError.foreignDatabase }
        statement = nil
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw PersonalizationError.foreignDatabase
        }
        let versionMatches = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
        sqlite3_finalize(statement)
        guard versionMatches else { throw PersonalizationError.foreignDatabase }
        statement = nil
        guard sqlite3_prepare_v2(db, "SELECT model FROM metadata WHERE singleton=1", -1, &statement, nil) == SQLITE_OK
        else {
            sqlite3_finalize(statement)
            throw PersonalizationError.foreignDatabase
        }
        let matches =
            sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_text(statement, 0).map { String(cString: $0) == modelVersion } == true
        sqlite3_finalize(statement)
        guard matches else { throw PersonalizationError.invalidInput }
    }

    private static func initialize(_ db: OpaquePointer, modelVersion: String) throws {
        let schema = """
            BEGIN IMMEDIATE;
            PRAGMA application_id=1313167184;
            PRAGMA user_version=1;
            CREATE TABLE metadata(singleton INTEGER PRIMARY KEY CHECK(singleton=1), model TEXT NOT NULL, last_reward REAL);
            CREATE TABLE impressions(id TEXT PRIMARY KEY, article TEXT NOT NULL, topic TEXT NOT NULL,
                vector BLOB, rendered REAL NOT NULL, skip REAL, click REAL, save REAL);
            CREATE INDEX impressions_rendered ON impressions(rendered);
            CREATE TABLE profile(singleton INTEGER PRIMARY KEY CHECK(singleton=1), vector BLOB, updated REAL, model TEXT NOT NULL);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw PersonalizationError.sqlite }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO metadata(singleton,model) VALUES(1,?)", -1, &stmt, nil) == SQLITE_OK
        else {
            sqlite3_finalize(stmt)
            throw PersonalizationError.sqlite
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, modelVersion, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw PersonalizationError.sqlite
        }
    }

    private static func expire(_ db: OpaquePointer, at: Date) throws {
        guard at.timeIntervalSince1970.isFinite else { throw PersonalizationError.invalidTime }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM impressions WHERE rendered < ?", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw PersonalizationError.sqlite
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, at.timeIntervalSince1970 - 30 * 86400)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PersonalizationError.sqlite }
    }

    func setEnabled(_ value: Bool) { enabled = value }

    func recordRendered(_ impression: EditorialRenderedImpression) throws {
        guard enabled else { return }
        let (impressionID, articleID, topicID, vector, modelVersion, at) = (
            impression.impressionID, impression.articleID, impression.topicID, impression.vector,
            impression.modelVersion, impression.at
        )
        guard !impressionID.isEmpty, !articleID.isEmpty, !topicID.isEmpty,
            impressionID.utf8.count <= 1024, articleID.utf8.count <= 1024, topicID.utf8.count <= 1024,
            !impressionID.contains("\0"), !articleID.contains("\0"), !topicID.contains("\0"),
            modelVersion == self.modelVersion, at.timeIntervalSince1970.isFinite,
            vector.map({ $0.count == 384 && $0.allSatisfy(\.isFinite) }) ?? true
        else { throw PersonalizationError.invalidInput }
        let clockNow = now()
        let current = clockNow.timeIntervalSince1970
        let rendered = at.timeIntervalSince1970
        guard current.isFinite, rendered <= current, rendered >= current - 30 * 86400 else {
            throw PersonalizationError.invalidTime
        }
        try prune(at: clockNow)
        let stmt = try prepare(
            "INSERT OR IGNORE INTO impressions(id,article,topic,vector,rendered) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(impressionID, to: 1, in: stmt)
        bind(articleID, to: 2, in: stmt)
        bind(topicID, to: 3, in: stmt)
        if let vector { bind(vector, to: 4, in: stmt) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_double(stmt, 5, at.timeIntervalSince1970)
        try done(stmt)
    }
    func recordScrolledPast(impressionID: String, at: Date) throws {
        try record(.skip, id: impressionID, at: at)
    }
    func recordClick(impressionID: String, at: Date) throws {
        try record(.click, id: impressionID, at: at)
    }
    func recordSave(impressionID: String, at: Date) throws {
        try record(.save, id: impressionID, at: at)
    }

    private enum Action {
        case skip, click, save

        var column: Int32 {
            switch self {
            case .skip: 1
            case .click: 2
            case .save: 3
            }
        }
        var sql: String {
            switch self {
            case .skip: "UPDATE impressions SET skip=? WHERE id=?"
            case .click: "UPDATE impressions SET click=? WHERE id=?"
            case .save: "UPDATE impressions SET save=? WHERE id=?"
            }
        }
        func weight(policy: PersonalizationPolicy, engaged: Bool) -> Double {
            switch self {
            case .skip: engaged ? 0 : policy.skipWeight
            case .click: policy.clickWeight
            case .save: policy.saveWeight
            }
        }
    }

    private struct RecordedImpression {
        let rendered: Double
        let already: Bool
        let engaged: Bool
        let skipped: Bool
        let latestAction: Double?
        let vector: [Float]?
    }

    private func record(_ kind: Action, id: String, at: Date) throws {
        guard enabled else { return }
        guard !id.isEmpty, id.utf8.count <= 1024, !id.contains("\0") else {
            throw PersonalizationError.invalidInput
        }
        let clockNow = now()
        let time = at.timeIntervalSince1970
        guard time.isFinite, clockNow.timeIntervalSince1970.isFinite,
            time <= clockNow.timeIntervalSince1970
        else { throw PersonalizationError.invalidTime }
        try prune(at: clockNow)
        try execute("BEGIN IMMEDIATE")
        do {
            let impression = try loadImpression(id, kind: kind)
            guard time >= impression.rendered else { throw PersonalizationError.invalidTime }
            guard kind == .skip || !impression.skipped || impression.engaged else {
                throw PersonalizationError.invalidInput
            }
            if !impression.already {
                if let latestAction = impression.latestAction, time < latestAction {
                    throw PersonalizationError.invalidTime
                }
                try validateClock(time)
                try markAction(kind, id: id, time: time)
                let weight = kind.weight(policy: policy, engaged: impression.engaged)
                if weight != 0 {
                    try advanceClock(time)
                    if let vector = impression.vector { try updateProfile(vector, weight: weight, time: time) }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func loadImpression(_ id: String, kind: Action) throws -> RecordedImpression {
        let query = try prepare("SELECT rendered,skip,click,save,vector FROM impressions WHERE id=?")
        defer { sqlite3_finalize(query) }
        bind(id, to: 1, in: query)
        guard sqlite3_step(query) == SQLITE_ROW else { throw PersonalizationError.invalidInput }
        let column = kind.column
        let vector = readVector(query, column: 4)
        guard sqlite3_column_type(query, 4) == SQLITE_NULL || vector != nil else {
            throw PersonalizationError.invalidInput
        }
        return .init(
            rendered: sqlite3_column_double(query, 0),
            already: sqlite3_column_type(query, column) != SQLITE_NULL,
            engaged: sqlite3_column_type(query, 2) != SQLITE_NULL || sqlite3_column_type(query, 3) != SQLITE_NULL,
            skipped: sqlite3_column_type(query, 1) != SQLITE_NULL,
            latestAction: (1...3).compactMap { column -> Double? in
                sqlite3_column_type(query, Int32(column)) == SQLITE_NULL
                    ? nil : sqlite3_column_double(query, Int32(column))
            }.max(),
            vector: vector)
    }

    private func validateClock(_ time: Double) throws {
        let clock = try prepare("SELECT last_reward FROM metadata WHERE singleton=1")
        defer { sqlite3_finalize(clock) }
        guard sqlite3_step(clock) == SQLITE_ROW else { throw PersonalizationError.sqlite }
        if sqlite3_column_type(clock, 0) != SQLITE_NULL && time < sqlite3_column_double(clock, 0) {
            throw PersonalizationError.invalidTime
        }
    }

    private func markAction(_ kind: Action, id: String, time: Double) throws {
        let stmt = try prepare(kind.sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, time)
        bind(id, to: 2, in: stmt)
        try done(stmt)
    }

    private func advanceClock(_ time: Double) throws {
        let stmt = try prepare("UPDATE metadata SET last_reward=? WHERE singleton=1")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, time)
        try done(stmt)
    }

    private func updateProfile(_ vector: [Float], weight: Double, time: Double) throws {
        let articleNorm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard articleNorm > 0 else { return }
        let profile = try readProfile()
        let decay = profile.map { exp(-log(2) * (time - $0.time) / policy.halfLife) } ?? 0
        let old = profile?.vector ?? Array(repeating: 0, count: 384)
        let combined = zip(old, vector).map { Double($0) * decay + Double($1) / articleNorm * weight }
        let norm = sqrt(combined.reduce(0.0) { $0 + $1 * $1 })
        guard norm.isFinite else { throw PersonalizationError.invalidInput }
        let next = norm == 0 ? Array(repeating: Float.zero, count: 384) : combined.map { Float($0 / norm) }
        let stmt = try prepare("INSERT OR REPLACE INTO profile(singleton,vector,updated,model) VALUES(1,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(next, to: 1, in: stmt)
        sqlite3_bind_double(stmt, 2, time)
        bind(modelVersion, to: 3, in: stmt)
        try done(stmt)
    }

    func profile(at: Date) throws -> [Float]? {
        guard enabled else { return nil }
        try prune(at: now())
        guard let profile = try readProfile() else { return nil }
        guard at.timeIntervalSince1970.isFinite, at.timeIntervalSince1970 >= profile.time else {
            throw PersonalizationError.invalidTime
        }
        let norm = sqrt(profile.vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { return nil }
        return profile.vector.map { Float(Double($0) / norm) }
    }
    func prune(at: Date) throws {
        guard at.timeIntervalSince1970.isFinite else { throw PersonalizationError.invalidTime }
        try Self.expire(db, at: at)
    }
    func reset() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute(
                "DELETE FROM impressions; DELETE FROM profile; UPDATE metadata SET last_reward=NULL")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    func counts() throws -> PersonalizationCounts {
        try prune(at: now())
        let stmt = try prepare("SELECT count(*),count(skip),count(click),count(save) FROM impressions")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw PersonalizationError.sqlite }
        return .init(
            impressions: Int(sqlite3_column_int64(stmt, 0)), skips: Int(sqlite3_column_int64(stmt, 1)),
            clicks: Int(sqlite3_column_int64(stmt, 2)), saves: Int(sqlite3_column_int64(stmt, 3)))
    }
    func storageBytes() throws -> Int64 {
        func pragma(_ sql: String) throws -> Int64 {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw PersonalizationError.sqlite }
            return sqlite3_column_int64(stmt, 0)
        }
        return try pragma("PRAGMA page_count") * pragma("PRAGMA page_size")
    }
    /// Deterministic 3/20 allocation among adjacent candidates below the baseline exposure.
    static func discoveryAllocation(
        batchSize: Int, remainder: Int, candidates: [DiscoveryCandidate], baselineExposure: Int
    ) throws -> DiscoveryAllocation {
        guard (0...500).contains(batchSize), (0..<20).contains(remainder), candidates.count <= 500,
            baselineExposure >= 0,
            candidates.allSatisfy({
                !$0.articleID.isEmpty && !$0.topicID.isEmpty && $0.priorImpressions >= 0
            }),
            Set(candidates.map(\.articleID)).count == candidates.count
        else { throw PersonalizationError.invalidInput }
        let numerator = 3 * batchSize + remainder
        let requested = numerator / 20
        let eligible = candidates.filter { $0.isAdjacent && $0.priorImpressions < baselineExposure }
            .sorted {
                $0.priorImpressions == $1.priorImpressions
                    ? $0.articleID < $1.articleID : $0.priorImpressions < $1.priorImpressions
            }
        let chosen = Array(eligible.prefix(requested)).map(\.articleID)
        return .init(
            requested: requested, articleIDs: chosen, shortage: requested - chosen.count,
            remainder: numerator % 20)
    }
    private func readProfile() throws -> (vector: [Float], time: Double)? {
        let stmt = try prepare("SELECT vector,updated,model FROM profile WHERE singleton=1")
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let model = sqlite3_column_text(stmt, 2),
            String(cString: model) == modelVersion,
            let vector = readVector(stmt, column: 0)
        else { throw PersonalizationError.invalidInput }
        return (vector, sqlite3_column_double(stmt, 1))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PersonalizationError.sqlite
        }
        return stmt
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw PersonalizationError.sqlite
        }
    }
    private func done(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PersonalizationError.sqlite }
    }
    private func bind(_ value: String, to index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }
    private func bind(_ value: [Float], to index: Int32, in stmt: OpaquePointer) {
        value.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }
    private func readVector(_ stmt: OpaquePointer, column: Int32) -> [Float]? {
        guard sqlite3_column_bytes(stmt, column) == 384 * MemoryLayout<Float>.size,
            let data = sqlite3_column_blob(stmt, column)
        else { return nil }
        var vector = Array(repeating: Float.zero, count: 384)
        vector.withUnsafeMutableBytes {
            $0.copyMemory(from: UnsafeRawBufferPointer(start: data, count: $0.count))
        }
        return vector.allSatisfy(\.isFinite) ? vector : nil
    }
}
