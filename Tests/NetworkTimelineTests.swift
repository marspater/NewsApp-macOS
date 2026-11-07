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

/// What an export needs to reconstruct a network change during a refresh (#929).
enum NetworkTimelineTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ NetworkTimeline: \(message)")
        }
    }

    static let wifi = NetworkTimeline.PathState(status: "satisfied", interfaceTypes: ["wifi"], hasTunnel: false)
    static let vpn = NetworkTimeline.PathState(status: "satisfied", interfaceTypes: ["wifi", "other"], hasTunnel: true)

    static func checkDetail() {
        check(FeedError.timeout.failureDetail() == "timeout", "a plain kind")
        check(FeedError.httpStatus(503).failureDetail() == "http, http 503", "an HTTP status")
        check(FeedError.serverBusy(status: 429, retryAfter: 60).failureDetail() == "http, http 429", "a busy server")
        check(FeedError.noSuchHost("secret.example").failureDetail() == "noSuchHost", "no such host, without its name")
        check(
            FeedError.dnsUnanswered(host: "secret.example", reason: "dns -65568").failureDetail()
                == "dns, unresolvable dns -65568", "a resolver error keeps its code")
        check(
            FeedError.dnsUnanswered(host: "secret.example", reason: "Timed out").failureDetail()
                == "dns, unresolvable timeout", "a resolver timeout")
        check(
            FeedError.dnsUnanswered(host: "x", reason: "A server with the specified hostname secret.example")
                .failureDetail()
                == "dns, unresolvable", "free text from a system message never passes")
        check(
            FeedError.substitutedAnswer(host: "secret.example", kind: .fakeIP).failureDetail() == "fakeIP, fakeIP",
            "a substituted answer")
        check(
            FeedError.blockedHost(host: "secret.example", reason: "Private address 10.0.0.1").failureDetail()
                == "policy, blocked", "a blocked address is not printed")
        check(
            FeedError.network("Lost connection to secret.example").failureDetail(urlErrorCode: -1005)
                == "transport, URLError -1005", "a transport failure keeps its code and drops its message")
    }

    static func checkTimeline() {
        let clock = OSAllocatedUnfairLock(initialState: t0)
        let timeline = NetworkTimeline(now: { clock.withLock { $0 } })
        timeline.record(path: wifi)
        for _ in 0..<40 { timeline.record(resolverOutcome: "allowed") }
        check(timeline.entries.count == 2, "consecutive lookups of one class share an entry")
        check(timeline.entries[1].event == .resolver(outcome: "allowed", count: 40), "the shared entry counts them")
        clock.withLock { $0 = t0.addingTimeInterval(5) }
        timeline.record(path: vpn)
        timeline.record(resolverOutcome: "blocked fakeIP")
        check(
            timeline.entries.map(\.date.timeIntervalSince1970).last == t0.timeIntervalSince1970 + 5, "entries are dated"
        )
        for index in 0..<60 { timeline.record(resolverOutcome: index % 2 == 0 ? "allowed" : "noSuchHost") }
        check(timeline.entries.count == NetworkTimeline.entryLimit, "the timeline keeps the last 50 entries")
        check(timeline.entries.last?.event == .resolver(outcome: "noSuchHost", count: 1), "the newest entry is last")

        for (result, outcome) in [
            (IPAddressValidator.ValidationResult.allowed(ips: ["1.1.1.1"]), "allowed"),
            (.blocked(reason: "Reserved (0.0.0.0/8)"), "blocked sinkhole"),
            (.blocked(reason: "benchmarking range"), "blocked fakeIP"),
            (.blocked(reason: "Private address 10.0.0.1"), "blocked"), (.noSuchHost, "noSuchHost"),
            (.unresolvable(reason: "Timed out"), "unresolvable timeout"),
            (.unresolvable(reason: "Cancelled"), "cancelled"),
            (.unresolvable(reason: "dns -65568"), "unresolvable dns -65568"),
            (.unresolvable(reason: "dns lookup failed for secret.example"), "unresolvable"),
        ] {
            check(NetworkTimeline.outcomeClass(result) == outcome, "outcome class \(outcome)")
        }

        let batches = NetworkTimeline(now: { t0 })
        batches.record(path: wifi)
        check(batches.pathChanges == 0, "the first path report is not a change")
        batches.record(path: wifi)
        check(batches.pathChanges == 1, "a later report is a change even when its summary reads the same")
        let start = batches.pathChanges
        batches.record(path: vpn)
        batches.record(attempted: 5, failed: 5, takenForOffline: true, pathChangesAtStart: start)
        check(
            batches.batches.first?.description
                == "\(t0.formatted(.iso8601)): 5 requests, 5 failed, taken for offline, path satisfied, wifi+other, tunnel present, path changed during the batch",
            "a batch reads in one line: \(batches.batches.first?.description ?? "")")
        for _ in 0..<30 {
            batches.record(attempted: 1, failed: 0, takenForOffline: false, pathChangesAtStart: batches.pathChanges)
        }
        check(batches.batches.count == NetworkTimeline.batchLimit, "batches stay bounded")
        check(batches.batches.last?.pathChanged == false, "a quiet batch says so")

        let text = DiagnosticsExport.network(
            gatewayPort: nil, resolverCancellations: 0, feedStatuses: [:], proxy: [], timeline: timeline.entries,
            log: [])
        check(text.contains("resolver: noSuchHost × 1"), "network.txt prints the timeline")
        let quiet = DiagnosticsExport.network(
            gatewayPort: nil, resolverCancellations: 0, feedStatuses: [:], proxy: [], log: [])
        check(quiet.contains("timeline this launch, newest last\nnone"), "an empty timeline says so")
    }

    /// A resolver reports each result's class to its timeline, and a scripted one stays out of the shared timeline.
    static func checkResolver() async {
        let timeline = NetworkTimeline(now: { t0 })
        let resolver = ProxyResolver(lookup: { _ in .noSuchHost }, timeline: timeline)
        _ = await resolver.resolve("secret.example")
        check(
            timeline.entries.first?.event == .resolver(outcome: "noSuchHost", count: 1), "a resolver records its class")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await resolver.resolve("secret.example")
        }
        _ = await cancelled.value
        check(
            timeline.entries.last?.event == .resolver(outcome: "cancelled", count: 1), "a cancelled lookup is recorded")
    }

    /// A refresh records its batch and each feed's cause, and an offline batch holds nothing against a feed.
    static func checkRefresh() async throws {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        defer { MockURLProtocol.requestHandler = nil }
        let client = NewsTests.mockHTTPClient(configuration: config)
        let timeline = NetworkTimeline(now: { t0 })
        timeline.record(path: wifi)
        let fetcher = FeedFetcher(client: client, timeline: timeline, now: { t0 })
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let good = "https://8.8.8.8/good.xml"
        let bad = "https://8.8.8.8/bad.xml"
        let lost = "https://8.8.4.4/lost.xml"
        let body = Data(
            "<rss version='2.0'><channel><title>T</title><item><title>One</title><link>https://example.com/one</link></item></channel></rss>"
                .utf8)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/lost.xml" { throw URLError(.networkConnectionLost) }
            let status = request.url?.path == "/good.xml" ? 200 : 503
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                status == 200 ? body : Data()
            )
        }
        _ = await fetcher.fetchAllFeeds(urls: [good, bad, lost], state: db)
        var states = try await db.feedFetchStates()
        check(states[bad]?.lastFailureAt == t0, "a failure is dated")
        check(states[bad]?.lastFailureDetail == "http, http 503", "a failure stores its cause")
        check(states[lost]?.lastFailureDetail == "transport, URLError -1005", "a transport failure stores its code")
        check(states[good]?.lastFailureAt == nil, "a healthy feed has no failure")
        check(
            timeline.batches.last
                == NetworkTimeline.Batch(
                    date: t0, attempted: 3, failed: 2, takenForOffline: false, path: wifi, pathChanged: false),
            "the batch is recorded")

        let offline = NetworkTimeline(now: { t0 })
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let unplugged = FeedFetcher(client: client, timeline: offline, now: { t0 })
        _ = await unplugged.fetchAllFeeds(urls: [good], state: db)
        states = try await db.feedFetchStates()
        check(offline.batches.last?.takenForOffline == true, "an all-connectivity batch is taken for offline")
        check(states[good]?.lastFailureAt == nil, "an offline batch records no failure against the feed")
        let text = DiagnosticsExport.feeds(
            feedURLs: [bad, good], states: states, statuses: [:], batches: offline.batches, now: t0)
        check(text.contains("taken for offline"), "feeds.txt prints the batch")
        check(text.contains("(http, http 503)"), "feeds.txt prints the cause")
        check(text.contains("last recorded failure time not recorded"), "feeds.txt does not claim a feed never failed")
        check(!text.contains("/bad.xml"), "feeds.txt keeps to hosts")
        await db.close()
    }

    /// A v34 library upgrades, keeps what it stored, and its old failure has no time or cause.
    static func checkMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let feed = "https://8.8.8.8/feed.xml"
        var db = DatabaseEngine(path: path)
        try await db.open()
        try await db.recordFeedFailure(feed, kind: .timeout, detail: "timeout", retryAfter: nil, at: t0)
        var state = try await db.feedFetchStates()[feed]
        check(state?.lastFailureAt == t0 && state?.lastFailureDetail == "timeout", "time and cause are stored")
        try await db.recordFeedSuccess(feed, at: t0.addingTimeInterval(60))
        state = try await db.feedFetchStates()[feed]
        check(state?.lastFailureKind == nil && state?.lastFailureAt == t0, "a success keeps the last failure's time")
        try await db.recordFeedFailure(
            feed, kind: .timeout, detail: String(repeating: "x", count: 500), retryAfter: nil, at: t0)
        state = try await db.feedFetchStates()[feed]
        check(state?.lastFailureDetail?.count == 120, "the stored cause is bounded")
        await db.close()

        var handle: OpaquePointer?
        check(sqlite3_open(path, &handle) == SQLITE_OK, "open the fixture")
        check(
            sqlite3_exec(
                handle,
                """
                PRAGMA legacy_alter_table=ON;
                ALTER TABLE feeds DROP COLUMN last_failure_at;
                ALTER TABLE feeds DROP COLUMN last_failure_detail;
                PRAGMA user_version=34;
                """, nil, nil, nil) == SQLITE_OK, "take the library back to v34")
        sqlite3_close(handle)
        db = DatabaseEngine(path: path)
        try await db.open()
        state = try await db.feedFetchStates()[feed]
        check(state?.lastFailureKind == .timeout && state?.failures == 1, "an upgraded library keeps its fetch state")
        check(state?.lastFailureAt == nil && state?.lastFailureDetail == nil, "an older failure has no time or cause")
        check(try await db.storedSchemaVersion() == DatabaseEngine.schemaVersion, "a v34 library upgrades")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(files.contains { $0.contains("-before-v34-") }, "the upgrade keeps a rollback copy")
        await db.close()
    }

    static func run() async {
        checkDetail()
        checkTimeline()
        await checkResolver()
        do {
            try await checkRefresh()
            try await checkMigration()
        } catch { check(false, "Unexpected error: \(error)") }
        print("Finished \(checks) network timeline checks with \(failures) failures.")
        if failures > 0 { recordFailure("NetworkTimelineTests: \(failures) check failure(s)") }
    }
}
