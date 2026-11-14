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
import Testing

/// Copy of EditorialPersonalizationTests.swift's `private` clock.
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

/// Copy of EditorialPersonalizationTests.swift's `private` clock that fails on its second reading.
private final class FailingInitializationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return Date(timeIntervalSince1970: calls == 1 ? 100 : .nan)
    }
}

/// Native port of the `EditorialPersonalizationTests` atom (#1070): its one control function as one test, with each
/// local `check` turned into `expectTrue` of NativeExpectations.swift (the runner log is invisible to Swift Testing,
/// and like the runner's check it carries no message: the recorded line names it) and each force unwrap or forced
/// cast in the throwing scope into `#require`, so a failure is recorded instead of crashing the run. The two `private`
/// clocks are copied above. The evaluation the runner starts when `NEWS_PERSONALIZATION_OUTPUT` is set is a research
/// mode (`script/test_editorial_personalization.sh`) and is not ported. The runner keeps its copy until CI shows
/// parity.
extension NativeSuites {
    @Suite(.tags(.editorial, .integration)) struct EditorialPersonalizationSuite {
        @Test func controls() async throws {
            let p = PersonalizationPolicy(halfLife: 10, clickWeight: 1, saveWeight: 2, skipWeight: -1)
            let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("store.sqlite").path
            let foreign = dir.appendingPathComponent("foreign.sqlite").path
            var raw: OpaquePointer?
            expectTrue(sqlite3_open(foreign, &raw) == SQLITE_OK)
            expectTrue(
                sqlite3_exec(raw, "CREATE TABLE keep(value); INSERT INTO keep VALUES(42)", nil, nil, nil)
                    == SQLITE_OK)
            sqlite3_close(raw)
            do {
                _ = try EditorialPersonalization(
                    policy: p, modelVersion: "v1", path: foreign, now: { Date(timeIntervalSince1970: 100) })
                expectTrue(false)  // "foreign")
            } catch PersonalizationError.foreignDatabase {}
            raw = nil
            expectTrue(sqlite3_open(foreign, &raw) == SQLITE_OK)
            var statement: OpaquePointer?
            expectTrue(
                sqlite3_prepare_v2(raw, "SELECT value FROM keep", -1, &statement, nil) == SQLITE_OK)
            expectTrue(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 42)
            sqlite3_finalize(statement)
            sqlite3_close(raw)
            let failedPath = dir.appendingPathComponent("failed.sqlite").path
            let failingClock = FailingInitializationClock()
            do {
                _ = try EditorialPersonalization(
                    policy: p, modelVersion: "v1", path: failedPath,
                    now: { failingClock.now() })
                expectTrue(false)
            } catch PersonalizationError.invalidTime { expectTrue(true) }
            expectTrue(!FileManager.default.fileExists(atPath: failedPath))
            _ = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: failedPath,
                now: { Date(timeIntervalSince1970: 100) })
            expectTrue(FileManager.default.fileExists(atPath: failedPath))
            do {
                _ = try EditorialPersonalization(policy: p, modelVersion: "v1\0other")
                expectTrue(false)
            } catch PersonalizationError.invalidPolicy { expectTrue(true) }
            let store = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: path, now: { Date(timeIntervalSince1970: 111) })
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            expectTrue(try #require(attributes[.posixPermissions] as? NSNumber).intValue == 0o600)
            let emptyPath = dir.appendingPathComponent("empty.sqlite").path
            expectTrue(FileManager.default.createFile(atPath: emptyPath, contents: Data()))
            do {
                _ = try EditorialPersonalization(policy: p, modelVersion: "v1", path: emptyPath)
                expectTrue(false)  // "empty")
            } catch PersonalizationError.foreignDatabase {}
            // Future schemas must be rejected before any expiration or other write.
            let futurePath = dir.appendingPathComponent("future.sqlite").path
            _ = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: futurePath,
                now: { Date(timeIntervalSince1970: 100) })
            raw = nil
            expectTrue(sqlite3_open(futurePath, &raw) == SQLITE_OK)
            expectTrue(
                sqlite3_exec(
                    raw,
                    "PRAGMA user_version=2; INSERT INTO impressions(id,article,topic,rendered) VALUES('keep','a','t',0)",
                    nil, nil, nil) == SQLITE_OK)
            sqlite3_close(raw)
            do {
                _ = try EditorialPersonalization(
                    policy: p, modelVersion: "v1", path: futurePath,
                    now: { Date(timeIntervalSince1970: 100 + 31 * 86400) })
                expectTrue(false)
            } catch PersonalizationError.foreignDatabase {}
            raw = nil
            expectTrue(sqlite3_open(futurePath, &raw) == SQLITE_OK)
            statement = nil
            expectTrue(
                sqlite3_prepare_v2(raw, "SELECT count(*) FROM impressions WHERE id='keep'", -1, &statement, nil)
                    == SQLITE_OK)
            expectTrue(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1)
            sqlite3_finalize(statement)
            sqlite3_close(raw)
            // An idle, already-open store expires rows when counts is its next operation.
            let clock = PersonalizationTestClock(Date(timeIntervalSince1970: 100))
            let ttlStore = try EditorialPersonalization(
                policy: p, modelVersion: "v1",
                path: dir.appendingPathComponent("ttl.sqlite").path, now: { clock.now() })
            await ttlStore.setEnabled(true)
            try await ttlStore.recordRendered(
                .init(
                    impressionID: "ttl", articleID: "a", topicID: "t", vector: nil,
                    modelVersion: "v1", at: clock.now()))
            expectTrue(try await ttlStore.counts().impressions == 1)
            clock.set(Date(timeIntervalSince1970: 100 + 30 * 86400 + 1))
            expectTrue(try await ttlStore.counts().impressions == 0)
            let t = Date(timeIntervalSince1970: 100)
            var x = Array(repeating: Float(0), count: 384)
            x[0] = 1
            var y = x
            y[0] = 0
            y[1] = 1
            try await store.recordRendered(
                .init(
                    impressionID: "disabled", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t))
            expectTrue(try await store.counts().impressions == 0)
            await store.setEnabled(true)
            for bad in [
                EditorialRenderedImpression(
                    impressionID: "a\0b", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t),
                EditorialRenderedImpression(
                    impressionID: "a", articleID: "a\0b", topicID: "t", vector: x, modelVersion: "v1", at: t),
                EditorialRenderedImpression(
                    impressionID: "a", articleID: "a", topicID: "t\0b", vector: x, modelVersion: "v1", at: t),
            ] {
                do {
                    try await store.recordRendered(bad)
                    expectTrue(false)
                } catch PersonalizationError.invalidInput { expectTrue(true) }
            }
            do {
                try await store.recordClick(impressionID: "a\0b", at: t)
                expectTrue(false)
            } catch PersonalizationError.invalidInput { expectTrue(true) }
            try await store.recordRendered(
                .init(
                    impressionID: "a", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t))
            try await store.recordRendered(
                .init(
                    impressionID: "b", articleID: "a", topicID: "t", vector: y, modelVersion: "v1", at: t))
            try await store.recordRendered(
                .init(
                    impressionID: "c", articleID: "c", topicID: "t", vector: nil, modelVersion: "v1", at: t))
            try await store.recordClick(impressionID: "a", at: t)
            try await store.recordClick(impressionID: "a", at: t)
            try await store.recordClick(impressionID: "c", at: t.addingTimeInterval(5))
            do {
                try await store.recordSave(impressionID: "b", at: t.addingTimeInterval(4))
                expectTrue(false)  // "clock")
            } catch PersonalizationError.invalidTime {}
            expectTrue(try await store.counts().saves == 0)
            try await store.recordSave(impressionID: "b", at: t.addingTimeInterval(10))
            try await store.recordSave(impressionID: "b", at: t.addingTimeInterval(10))
            let profile = try #require(try await store.profile(at: t.addingTimeInterval(10)))
            expectTrue(
                abs(profile[0] - Float(0.5 / sqrt(4.25))) < 0.00001
                    && abs(profile[1] - Float(2 / sqrt(4.25))) < 0.00001)
            try await store.recordScrolledPast(impressionID: "b", at: t.addingTimeInterval(11))
            let after = try #require(try await store.profile(at: t.addingTimeInterval(11)))
            expectTrue(after == profile)
            let counts = try await store.counts()
            expectTrue(
                counts.impressions == 3 && counts.clicks == 2 && counts.saves == 1 && counts.skips == 1)
            // A neutral skip after engagement keeps the episode open for a later save.
            try await store.recordScrolledPast(impressionID: "a", at: t.addingTimeInterval(11))
            do {
                try await store.recordSave(impressionID: "a", at: t.addingTimeInterval(10))
                expectTrue(false)
            } catch PersonalizationError.invalidTime { expectTrue(true) }
            // A duplicate earlier click remains idempotent even after the later scroll.
            try await store.recordClick(impressionID: "a", at: t)
            try await store.recordSave(impressionID: "a", at: t.addingTimeInterval(11))
            try await store.recordRendered(
                .init(
                    impressionID: "closed", articleID: "d", topicID: "t", vector: x, modelVersion: "v1", at: t))
            try await store.recordScrolledPast(impressionID: "closed", at: t.addingTimeInterval(11))
            do {
                try await store.recordClick(impressionID: "closed", at: t.addingTimeInterval(11))
                expectTrue(false)  // "closed episode")
            } catch PersonalizationError.invalidInput {}
            do {
                try await store.recordSave(impressionID: "closed", at: t.addingTimeInterval(11))
                expectTrue(false)  // "closed episode save")
            } catch PersonalizationError.invalidInput {}
            try await store.recordRendered(
                .init(
                    impressionID: "returned", articleID: "d", topicID: "t", vector: x, modelVersion: "v1", at: t))
            try await store.recordClick(impressionID: "returned", at: t.addingTimeInterval(11))
            do {
                try await store.recordRendered(
                    .init(
                        impressionID: "future", articleID: "d", topicID: "t", vector: x,
                        modelVersion: "v1", at: t.addingTimeInterval(12)))
                expectTrue(false)  // "future render")
            } catch PersonalizationError.invalidTime {}
            do {
                try await store.recordRendered(
                    .init(
                        impressionID: "old", articleID: "d", topicID: "t", vector: x,
                        modelVersion: "v1", at: t.addingTimeInterval(11 - 30 * 86400 - 1)))
                expectTrue(false)  // "expired render")
            } catch PersonalizationError.invalidTime {}
            do {
                try await store.recordSave(impressionID: "returned", at: t.addingTimeInterval(12))
                expectTrue(false)  // "future reward")
            } catch PersonalizationError.invalidTime {}
            await store.setEnabled(false)
            expectTrue(try await store.profile(at: t.addingTimeInterval(11)) == nil)
            let expired = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: path,
                now: { Date(timeIntervalSince1970: 100 + 30 * 86400 + 1) })
            expectTrue(try await expired.counts().impressions == 0)
            await store.setEnabled(true)
            try await store.recordRendered(
                .init(
                    impressionID: "fresh", articleID: "a", topicID: "t", vector: x,
                    modelVersion: "v1", at: t))
            let reopened = try EditorialPersonalization(
                policy: p, modelVersion: "v1", path: path, now: { Date(timeIntervalSince1970: 100) })
            await reopened.setEnabled(true)
            expectTrue(try await reopened.counts().impressions == 1)
            do {
                _ = try EditorialPersonalization(
                    policy: p, modelVersion: "v2", path: path, now: { Date(timeIntervalSince1970: 100) })
                expectTrue(false)  // "model")
            } catch PersonalizationError.invalidInput {}
            try await reopened.prune(at: t.addingTimeInterval(30 * 86400))
            expectTrue(try await reopened.counts().impressions == 1)
            try await reopened.prune(at: t.addingTimeInterval(30 * 86400 + 1))
            expectTrue(try await reopened.counts().impressions == 0)
            try await reopened.reset()
            expectTrue(try await reopened.profile(at: t.addingTimeInterval(100)) == nil)
            do {
                try await reopened.recordRendered(
                    .init(
                        impressionID: "bad", articleID: "a", topicID: "t", vector: [1], modelVersion: "v1", at: t))
                expectTrue(false)  // "dimension")
            } catch PersonalizationError.invalidInput {}
            try await reopened.recordRendered(
                .init(
                    impressionID: "corrupt", articleID: "a", topicID: "t", vector: x, modelVersion: "v1", at: t))
            raw = nil
            expectTrue(sqlite3_open(path, &raw) == SQLITE_OK)
            expectTrue(
                sqlite3_exec(raw, "UPDATE impressions SET vector=x'00' WHERE id='corrupt'", nil, nil, nil)
                    == SQLITE_OK)
            sqlite3_close(raw)
            do {
                try await reopened.recordClick(impressionID: "corrupt", at: t)
                expectTrue(false)  // "corrupt")
            } catch PersonalizationError.invalidInput {}
            expectTrue(try await reopened.counts().clicks == 0)
            let candidates = [
                DiscoveryCandidate(articleID: "b", topicID: "t", isAdjacent: true, priorImpressions: 2),
                DiscoveryCandidate(articleID: "a", topicID: "t", isAdjacent: true, priorImpressions: 1),
                DiscoveryCandidate(articleID: "c", topicID: "t", isAdjacent: false, priorImpressions: 0),
            ]
            let d = try EditorialPersonalization.discoveryAllocation(
                batchSize: 20, remainder: 0, candidates: candidates, baselineExposure: 3)
            expectTrue(
                d.requested == 3 && d.articleIDs == ["a", "b"] && d.shortage == 1 && d.remainder == 0)
            let e = try EditorialPersonalization.discoveryAllocation(
                batchSize: 1, remainder: 0, candidates: candidates, baselineExposure: 3)
            expectTrue(e.requested == 0 && e.remainder == 3)
            var remainderA = 0
            var remainderB = 0
            var requestedA = 0
            var requestedB = 0
            for index in 0..<20 {
                let a = try EditorialPersonalization.discoveryAllocation(
                    batchSize: 1, remainder: remainderA, candidates: candidates, baselineExposure: 3)
                remainderA = a.remainder
                requestedA += a.requested
                if index < 7 {
                    let b = try EditorialPersonalization.discoveryAllocation(
                        batchSize: 1, remainder: remainderB, candidates: candidates, baselineExposure: 3)
                    remainderB = b.remainder
                    requestedB += b.requested
                }
            }
            expectTrue(requestedA == 3 && remainderA == 0)
            expectTrue(requestedB == 1 && remainderB == 1)
        }
    }
}
