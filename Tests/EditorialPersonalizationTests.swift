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

private final class PersonalizationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

enum EditorialPersonalizationTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, line: UInt = #line) {
        checks += 1
        if !value {
            failures += 1
            print("FAIL EditorialPersonalizationTests:\(line)")
        }
    }

    static func run() async {
        do {
            try await controls()
            #if !EDITORIAL_STANDALONE
                if let output = ProcessInfo.processInfo.environment["NEWS_PERSONALIZATION_OUTPUT"] {
                    try await EditorialPersonalizationEvaluation.run(output: output)
                }
            #endif
        } catch {
            failures += 1
            print("FAIL EditorialPersonalizationTests: unexpected error \(error)")
        }
        print("Finished \(checks) personalization checks with \(failures) failures")
        if failures > 0 { exit(1) }
    }

    static func controls() async throws {
        let p = PersonalizationPolicy(halfLife: 10, clickWeight: 1, saveWeight: 2, skipWeight: -1)
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let foreign = dir.appendingPathComponent("foreign.sqlite").path
        var raw: OpaquePointer?
        check(sqlite3_open(foreign, &raw) == SQLITE_OK)
        check(
            sqlite3_exec(raw, "CREATE TABLE keep(value); INSERT INTO keep VALUES(42)", nil, nil, nil)
                == SQLITE_OK)
        sqlite3_close(raw)
        do {
            _ = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: foreign, now: { Date(timeIntervalSince1970: 100) })
            check(false)  // "foreign")
        } catch PersonalizationError.foreignDatabase {}
        raw = nil
        check(sqlite3_open(foreign, &raw) == SQLITE_OK)
        var statement: OpaquePointer?
        check(
            sqlite3_prepare_v2(raw, "SELECT value FROM keep", -1, &statement, nil) == SQLITE_OK)
        check(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 42)
        sqlite3_finalize(statement)
        sqlite3_close(raw)
        let store = try EditorialPersonalization(
            policy: p, modelVersion: "v1", path: path, now: { Date(timeIntervalSince1970: 111) })
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        check((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        let emptyPath = dir.appendingPathComponent("empty.sqlite").path
        check(FileManager.default.createFile(atPath: emptyPath, contents: Data()))
        do {
            _ = try EditorialPersonalization(policy: p, modelVersion: "v1", path: emptyPath)
            check(false)  // "empty")
        } catch PersonalizationError.foreignDatabase {}
        // Future schemas must be rejected before any expiration or other write.
        let futurePath = dir.appendingPathComponent("future.sqlite").path
        _ = try EditorialPersonalization(
            policy: p, modelVersion: "v1", path: futurePath,
            now: { Date(timeIntervalSince1970: 100) })
        raw = nil
        check(sqlite3_open(futurePath, &raw) == SQLITE_OK)
        check(
            sqlite3_exec(
                raw,
                "PRAGMA user_version=2; INSERT INTO impressions(id,article,topic,rendered) VALUES('keep','a','t',0)",
                nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        do {
            _ = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: futurePath,
                now: { Date(timeIntervalSince1970: 100 + 31 * 86400) })
            check(false)
        } catch PersonalizationError.foreignDatabase {}
        raw = nil
        check(sqlite3_open(futurePath, &raw) == SQLITE_OK)
        statement = nil
        check(
            sqlite3_prepare_v2(raw, "SELECT count(*) FROM impressions WHERE id='keep'", -1, &statement, nil)
                == SQLITE_OK)
        check(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)
        sqlite3_close(raw)
        // An idle, already-open store expires rows when counts is its next operation.
        let clock = PersonalizationTestClock(Date(timeIntervalSince1970: 100))
        let ttlStore = try EditorialPersonalization(
            policy: p, modelVersion: "v1",
            path: dir.appendingPathComponent("ttl.sqlite").path, now: { clock.now() })
        await ttlStore.setEnabled(true)
        try await ttlStore.recordRendered(
            impressionID: "ttl", articleID: "a", topicID: "t", vector: nil,
            modelVersion: "v1", at: clock.now())
        check(try await ttlStore.counts().impressions == 1)
        clock.set(Date(timeIntervalSince1970: 100 + 30 * 86400 + 1))
        check(try await ttlStore.counts().impressions == 0)
        let t = Date(timeIntervalSince1970: 100)
        var x = Array(repeating: Float(0), count: 384)
        x[0] = 1
        var y = x
        y[0] = 0
        y[1] = 1
        try await store.recordRendered(
            impressionID: "disabled", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t)
        check(try await store.counts().impressions == 0)
        await store.setEnabled(true)
        try await store.recordRendered(
            impressionID: "a", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t)
        try await store.recordRendered(
            impressionID: "b", articleID: "a", topicID: "t", vector: y, modelVersion: "v1", at: t)
        try await store.recordRendered(
            impressionID: "c", articleID: "c", topicID: "t", vector: nil, modelVersion: "v1", at: t)
        try await store.recordClick(impressionID: "a", at: t)
        try await store.recordClick(impressionID: "a", at: t)
        try await store.recordClick(impressionID: "c", at: t.addingTimeInterval(5))
        do {
            try await store.recordSave(impressionID: "b", at: t.addingTimeInterval(4))
            check(false)  // "clock")
        } catch PersonalizationError.invalidTime {}
        check(try await store.counts().saves == 0)
        try await store.recordSave(impressionID: "b", at: t.addingTimeInterval(10))
        try await store.recordSave(impressionID: "b", at: t.addingTimeInterval(10))
        let profile = try await store.profile(at: t.addingTimeInterval(10))!
        check(
            abs(profile[0] - Float(0.5 / sqrt(4.25))) < 0.00001
                && abs(profile[1] - Float(2 / sqrt(4.25))) < 0.00001)
        try await store.recordScrolledPast(impressionID: "b", at: t.addingTimeInterval(11))
        let after = try await store.profile(at: t.addingTimeInterval(11))!
        check(after == profile)
        let counts = try await store.counts()
        check(
            counts.impressions == 3 && counts.clicks == 2 && counts.saves == 1 && counts.skips == 1)
        // A neutral skip after engagement keeps the episode open for a later save.
        try await store.recordScrolledPast(impressionID: "a", at: t.addingTimeInterval(11))
        do {
            try await store.recordSave(impressionID: "a", at: t.addingTimeInterval(10))
            check(false)
        } catch PersonalizationError.invalidTime { check(true) }
        // A duplicate earlier click remains idempotent even after the later scroll.
        try await store.recordClick(impressionID: "a", at: t)
        try await store.recordSave(impressionID: "a", at: t.addingTimeInterval(11))
        try await store.recordRendered(
            impressionID: "closed", articleID: "d", topicID: "t", vector: x, modelVersion: "v1", at: t)
        try await store.recordScrolledPast(impressionID: "closed", at: t.addingTimeInterval(11))
        do {
            try await store.recordClick(impressionID: "closed", at: t.addingTimeInterval(11))
            check(false)  // "closed episode")
        } catch PersonalizationError.invalidInput {}
        do {
            try await store.recordSave(impressionID: "closed", at: t.addingTimeInterval(11))
            check(false)  // "closed episode save")
        } catch PersonalizationError.invalidInput {}
        try await store.recordRendered(
            impressionID: "returned", articleID: "d", topicID: "t", vector: x, modelVersion: "v1", at: t)
        try await store.recordClick(impressionID: "returned", at: t.addingTimeInterval(11))
        do {
            try await store.recordRendered(
                impressionID: "future", articleID: "d", topicID: "t", vector: x,
                modelVersion: "v1", at: t.addingTimeInterval(12))
            check(false)  // "future render")
        } catch PersonalizationError.invalidTime {}
        do {
            try await store.recordRendered(
                impressionID: "old", articleID: "d", topicID: "t", vector: x,
                modelVersion: "v1", at: t.addingTimeInterval(11 - 30 * 86400 - 1))
            check(false)  // "expired render")
        } catch PersonalizationError.invalidTime {}
        do {
            try await store.recordSave(impressionID: "returned", at: t.addingTimeInterval(12))
            check(false)  // "future reward")
        } catch PersonalizationError.invalidTime {}
        await store.setEnabled(false)
        check(try await store.profile(at: t.addingTimeInterval(11)) == nil)
        let expired = try EditorialPersonalization(
            policy: p, modelVersion: "v1", path: path,
            now: { Date(timeIntervalSince1970: 100 + 30 * 86400 + 1) })
        check(try await expired.counts().impressions == 0)
        await store.setEnabled(true)
        try await store.recordRendered(
            impressionID: "fresh", articleID: "a", topicID: "t", vector: x,
            modelVersion: "v1", at: t)
        let reopened = try EditorialPersonalization(
            policy: p, modelVersion: "v1", path: path, now: { Date(timeIntervalSince1970: 100) })
        await reopened.setEnabled(true)
        check(try await reopened.counts().impressions == 1)
        do {
            _ = try EditorialPersonalization(
                policy: p, modelVersion: "v2", path: path, now: { Date(timeIntervalSince1970: 100) })
            check(false)  // "model")
        } catch PersonalizationError.invalidInput {}
        try await reopened.prune(at: t.addingTimeInterval(30 * 86400))
        check(try await reopened.counts().impressions == 1)
        try await reopened.prune(at: t.addingTimeInterval(30 * 86400 + 1))
        check(try await reopened.counts().impressions == 0)
        try await reopened.reset()
        check(try await reopened.profile(at: t.addingTimeInterval(100)) == nil)
        do {
            try await reopened.recordRendered(
                impressionID: "bad", articleID: "a", topicID: "t", vector: [1], modelVersion: "v1", at: t)
            check(false)  // "dimension")
        } catch PersonalizationError.invalidInput {}
        try await reopened.recordRendered(
            impressionID: "corrupt", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t)
        raw = nil
        check(sqlite3_open(path, &raw) == SQLITE_OK)
        check(
            sqlite3_exec(raw, "UPDATE impressions SET vector=x'00' WHERE id='corrupt'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        do {
            try await reopened.recordClick(impressionID: "corrupt", at: t)
            check(false)  // "corrupt")
        } catch PersonalizationError.invalidInput {}
        check(try await reopened.counts().clicks == 0)
        let candidates = [
            DiscoveryCandidate(articleID: "b", topicID: "t", isAdjacent: true, priorImpressions: 2),
            DiscoveryCandidate(articleID: "a", topicID: "t", isAdjacent: true, priorImpressions: 1),
            DiscoveryCandidate(articleID: "c", topicID: "t", isAdjacent: false, priorImpressions: 0),
        ]
        let d = try EditorialPersonalization.discoveryAllocation(
            batchSize: 20, remainder: 0, candidates: candidates, baselineExposure: 3)
        check(
            d.requested == 3 && d.articleIDs == ["a", "b"] && d.shortage == 1 && d.remainder == 0)
        let e = try EditorialPersonalization.discoveryAllocation(
            batchSize: 1, remainder: 0, candidates: candidates, baselineExposure: 3)
        check(e.requested == 0 && e.remainder == 3)
        print("Personalization behavioral controls passed")
    }
}

#if EDITORIAL_STANDALONE
    @main struct PersonalizationStandalone {
        static func main() async { await EditorialPersonalizationTests.run() }
    }
#endif
