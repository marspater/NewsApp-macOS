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

import AppIntents
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import PDFKit
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - MockURLProtocol for Testing
class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var mockData: Data?
    static var mockResponse: HTTPURLResponse?
    static var mockError: Error?
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        if let handler = MockURLProtocol.requestHandler {
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }

        if let error = MockURLProtocol.mockError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let response = MockURLProtocol.mockResponse {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        if let data = MockURLProtocol.mockData {
            client?.urlProtocol(self, didLoad: data)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Responses are delivered synchronously; this mock has no pending load to cancel.
    }
}

func assertEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line
) {
    if actual != expected {
        print("❌ ASSERTION FAILED: \(message)")
        print("   Expected: \(expected)")
        print("   Actual:   \(actual)")
        print("   Location: \(file):\(line)")
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message) (expected true, got false)")
        print("   Location: \(file):\(line)")
        exit(1)
    }
}

func assertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        print("❌ ASSERTION FAILED: \(message) (expected false, got true)")
        print("   Location: \(file):\(line)")
        exit(1)
    }
}

// MARK: - Controllable doubles for refresh scheduling tests

/// Deterministic clock for retry schedules.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// Holds every request open until the test answers it, so concurrency and ordering are observable.
final class GatedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var held: [GatedURLProtocol] = []
    private static var startedURLs: [URL] = []
    private static var peakTotal = 0
    private static var peakByHost: [String: Int] = [:]

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        held = []
        startedURLs = []
        peakTotal = 0
        peakByHost = [:]
    }
    static var heldURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return held.compactMap { $0.request.url }
    }
    static var started: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return startedURLs
    }
    static var peak: (total: Int, byHost: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        return (peakTotal, peakByHost)
    }

    @discardableResult
    static func respond(to url: URL, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) -> Bool {
        lock.lock()
        guard let index = held.firstIndex(where: { $0.request.url == url }) else {
            lock.unlock()
            return false
        }
        let request = held.remove(at: index)
        lock.unlock()
        request.client?.urlProtocol(
            request,
            didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
            cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: body)
        request.client?.urlProtocolDidFinishLoading(request)
        return true
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        Self.held.append(self)
        Self.startedURLs.append(request.url!)
        Self.peakTotal = max(Self.peakTotal, Self.held.count)
        let host = request.url?.host ?? ""
        Self.peakByHost[host] = max(Self.peakByHost[host] ?? 0, Self.held.filter { $0.request.url?.host == host }.count)
    }

    override func stopLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        Self.held.removeAll { $0 === self }
    }
}

/// Suspends every waiter until opened, so tests can hold follow-up work in flight.
/// Records page fetches for overview evidence tests: links in order and the most that ran at once.
actor ExtractionLog {
    private(set) var links: [String] = []
    private(set) var peak = 0
    private var active = 0
    func begin(_ link: String) {
        links.append(link)
        active += 1
        peak = max(peak, active)
    }
    func end() { active -= 1 }
    func count(_ link: String) -> Int { links.filter { $0 == link }.count }
    var isIdle: Bool { active == 0 }
}

extension ExtractionOutcome {
    /// The case name, for aggregate audit counts without page text.
    var kindName: String {
        switch self {
        case .success: "success"
        case .networkError: "networkError"
        case .httpError: "httpError"
        case .securityBlocked: "securityBlocked"
        case .emptyContent: "emptyContent"
        case .contentParsingFailed: "contentParsingFailed"
        case .qualityValidationFailed: "qualityRejected"
        case .subscriberOnly: "subscriberOnly"
        }
    }
}

/// Outcomes of live publisher-text fetches in the overview audit (#308 step 2).
actor EvidenceFetchTally {
    private(set) var counts: [String: Int] = [:]
    func add(_ kind: String) { counts[kind, default: 0] += 1 }
}

/// Scripted publisher pages for overview evidence tests.
actor TestPages {
    struct Reply: Sendable {
        var outcome: ExtractionOutcome = .emptyContent
        var delay: Duration = .zero
        var during: (@Sendable () async -> Void)?
        /// Held until opened, ignoring cancellation, like an extractor that does not cooperate.
        var gate: OpenGate?
    }
    private var replies: [String: Reply] = [:]
    func set(
        _ link: String, _ outcome: ExtractionOutcome, delay: Duration = .zero,
        during: (@Sendable () async -> Void)? = nil, gate: OpenGate? = nil
    ) {
        replies[link] = Reply(outcome: outcome, delay: delay, during: during, gate: gate)
    }
    func reply(for link: String) -> Reply { replies[link] ?? Reply() }
}

actor OpenGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Records the feed batches a refresh requested.
actor TestRecorder {
    private(set) var batches: [[String]] = []
    func record(_ urls: [String]) { batches.append(urls) }
}

/// Synthetic event control set: one earthquake reported three ways, plus hard negatives (strikes on
/// different days in one region, two quarterly reports of one company, identical generic headlines).
/// Invented text, no publisher content.
enum EventControlSet {
    static func articles(now: Date, root: URL) -> [(article: FeedArticle, event: String?)] {
        func item(
            _ id: String, _ title: String, _ description: String, hoursAgo: Double, source: String, event: String?
        ) -> (article: FeedArticle, event: String?) {
            (
                FeedArticle(
                    storedID: id, title: title, link: root.appendingPathComponent("control/\(id)").absoluteString,
                    guid: id,
                    description: description, pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source), event
            )
        }
        return [
            item(
                "quake-1", "Earthquake of magnitude 7 strikes eastern Turkey near Malatya",
                "A powerful earthquake of magnitude 7 struck eastern Turkey near the city of Malatya on Monday, damaging buildings and forcing residents into the streets, the disaster agency AFAD said.",
                hoursAgo: 6, source: "Wire One", event: "quake"),
            item(
                "quake-2", "Magnitude 7 earthquake hits eastern Turkey, damaging buildings in Malatya",
                "A magnitude 7 earthquake struck eastern Turkey on Monday near Malatya, damaging buildings, the disaster agency AFAD said. Residents fled into the streets.",
                hoursAgo: 5, source: "Daily Two", event: "quake"),
            item(
                "quake-3", "Strong earthquake shakes Malatya in eastern Turkey",
                "Buildings were damaged in Malatya after a strong magnitude 7 earthquake struck eastern Turkey on Monday, according to the disaster agency AFAD.",
                hoursAgo: 4, source: "Herald Three", event: "quake"),
            item(
                "strike-monday", "Russian drone strike on Kharkiv kills 3",
                "A Russian drone struck an apartment building in Kharkiv late on Monday, killing three people, regional governor Oleh Syniehubov said.",
                hoursAgo: 20, source: "Wire One", event: "strike-monday"),
            item(
                "strike-tuesday", "Russian missile strike on Kharkiv injures 12",
                "A Russian missile hit a railway station in Kharkiv on Tuesday afternoon, injuring 12 people, regional governor Oleh Syniehubov said.",
                hoursAgo: 2, source: "Daily Two", event: "strike-tuesday"),
            item(
                "apple-q3", "Apple reports record third-quarter revenue",
                "Apple said on Thursday that revenue in its fiscal third quarter rose to a record, led by iPhone sales in China.",
                hoursAgo: 8, source: "Wire One", event: "apple-q3"),
            item(
                "apple-q4", "Apple reports record fourth-quarter revenue",
                "Apple said on Thursday that revenue in its fiscal fourth quarter rose to a record, led by iPhone sales in China.",
                hoursAgo: 7, source: "Daily Two", event: "apple-q4"),
            item(
                "live-1", "Live updates: the latest", "Follow our live coverage.", hoursAgo: 3, source: "Wire One",
                event: nil),
            item(
                "live-2", "Live updates: the latest", "Follow our live coverage.", hoursAgo: 3, source: "Daily Two",
                event: nil),
        ]
    }
}

struct NewsTests {
    static func mockHTTPClient(configuration: URLSessionConfiguration) -> SecureHTTPClient {
        // URLProtocol supplies bytes; fixture DNS must also stay independent of the network.
        SecureHTTPClient(
            configuration: configuration,
            resolver: { host in
                IPAddressValidator.validateHost(
                    host,
                    resolver: { fixtureHost in
                        ["example.com", "example.org", "api.github.com", "reader.invalid", "8.8.8.8", "8.8.4.4"]
                            .contains(fixtureHost)
                            ? .allowed(ips: ["8.8.8.8"])
                            : .unresolvable(reason: "No configured mock DNS address")
                    })
            })
    }

    static func main() async {
        do {
            try await runTests()
        } catch {
            print("❌ TEST FAILED with unexpected error: \(error)")
            exit(1)
        }
    }

    /// Tests that take longer than a whole shard; NEWS_TEST_SHARD=slow runs only these, in their own process.
    static let slowTests: Set<String> = ["testActiveWorkCancellation"]
    /// The loopback socket tests. They share the machine's ephemeral ports and 4-tuples with every parallel process
    /// and collided on CI (EADDRINUSE twice in one run, 6 November 2026; docs/audits/2026-11-06-socket-contention.md);
    /// NEWS_TEST_SHARD=sockets runs only these, one after another in their own process, beside the other lanes.
    static let socketTests: Set<String> = [
        "testGatewayRejectionIsTransport", "testSocketNetworkBoundary", "testTransportCancellation",
        "testGatewayAddressFallback",
    ]

    /// NEWS_TEST_SHARD="i/n" runs every n-th test from the i-th (0-based) that is neither slow nor a socket test,
    /// "slow" the slow ones and "sockets" the socket ones; test.sh runs the lanes as separate processes, so each test
    /// keeps the process-wide state it expects. NEWS_TEST_TIMING=1 prints each duration.
    static func shardIncludes(_ index: Int, name: String) -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["NEWS_TEST_SHARD"] else { return true }
        if spec == "slow" { return slowTests.contains(name) }
        if spec == "sockets" { return socketTests.contains(name) }
        let parts = spec.split(separator: "/").compactMap { Int($0) }
        return !slowTests.contains(name) && !socketTests.contains(name) && index % parts[1] == parts[0]
    }

    /// A malformed or out-of-range shard would run nothing and pass; it stops the process instead.
    static func validateShard() {
        guard let spec = ProcessInfo.processInfo.environment["NEWS_TEST_SHARD"], spec != "slow", spec != "sockets"
        else { return }
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let shard = parts[0], let count = parts[1], count > 0, (0..<count).contains(shard)
        else {
            print("❌ NEWS_TEST_SHARD must be \"slow\", \"sockets\" or i/n with 0 <= i < n, not \"\(spec)\"")
            exit(2)
        }
    }

    static func runSharded(_ tests: [(name: String, run: () async throws -> Void)]) async throws {
        validateShard()
        let timing = ProcessInfo.processInfo.environment["NEWS_TEST_TIMING"] == "1"
        for (index, test) in tests.enumerated() where shardIncludes(index, name: test.name) {
            let start = ContinuousClock.now
            try await test.run()
            if timing { print("    ⏱ \(test.name) \(ContinuousClock.now - start)") }
        }
    }

    /// The fixture URL the suites resolve their documents against.
    static let defaultFixtureHost = "example.com"
    static let defaultFixtureRoot = URL(string: "https://\(defaultFixtureHost)")!

    static func runTests(fixtureHost: String = "example.com") async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--curation-live"), CommandLine.arguments.count > index + 2
        {
            try await measureLiveCuration(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--overviews-live"), CommandLine.arguments.count > index + 2
        {
            try await measureLiveOverviews(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--related-live"), CommandLine.arguments.count > index + 2 {
            try await measureLiveRelations(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--notification-priority-live"),
            CommandLine.arguments.count > index + 2
        {
            try measureLivePriority(path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--images-live"), CommandLine.arguments.count > index + 2 {
            try await measureLiveImages(
                path: CommandLine.arguments[index + 1], output: CommandLine.arguments[index + 2])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-cache-audit") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private cache path")
            }
            try StoryCorpus.auditCache(path: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-page-texts") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private page directory")
            }
            try StoryCorpus.pageTexts(directory: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-pages") {
            guard CommandLine.arguments.indices.contains(index + 1),
                let urls = CommandLine.arguments.firstIndex(of: "--corpus-urls"),
                CommandLine.arguments.indices.contains(urls + 1)
            else { throw StoryCorpus.Failure.invalid("Supply private directory and --corpus-urls JSON") }
            try await StoryCorpus.capturePages(
                directory: CommandLine.arguments[index + 1], requestsPath: CommandLine.arguments[urls + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-capture") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private capture directory")
            }
            try await StoryCorpus.capture(directory: CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-readiness") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private capture directory")
            }
            let review = try StoryCorpus.reviewCaptures(
                directory: CommandLine.arguments[index + 1],
                holdout: CommandLine.arguments.contains("--corpus-holdout"), readinessOnly: true)
            let data = try JSONSerialization.data(withJSONObject: review.report, options: [.sortedKeys])
            print("CAPTURE_READINESS_REPORT " + String(decoding: data, as: UTF8.self))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-review") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing private capture directory")
            }
            let review = try StoryCorpus.reviewCaptures(
                directory: CommandLine.arguments[index + 1],
                holdout: CommandLine.arguments.contains("--corpus-holdout"))
            let data = try JSONSerialization.data(withJSONObject: review.report, options: [.sortedKeys])
            print("CAPTURE_FINGERPRINT_REPORT " + String(decoding: data, as: UTF8.self))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--seed-launch-library") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw StoryCorpus.Failure.invalid("Missing library path")
            }
            try await seedLaunchLibrary(path: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--matcher-regressions") {
            try await testMatcherRegressionCorpus()
            try await testStoryRegressionCorpus()
            return
        }
        if CommandLine.arguments.contains("--verdict-replay") {
            // NEWS_VERDICTS: a JSON array of {"pairModel", "cosine", "sharedSpecific", "gapHours", "sameAct", "same"}
            // (#629); without it, the synthetic verdicts of the unit test.
            struct Verdict: Decodable {
                let pairModel: Double, cosine: Double?, sharedSpecific: Int, gapHours: Double, sameAct: Bool, same: Bool
            }
            var rows = syntheticVerdicts(120)
            if let path = ProcessInfo.processInfo.environment["NEWS_VERDICTS"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                rows = try JSONDecoder().decode([Verdict].self, from: data).map {
                    PairCalibration.Row(
                        features: PairCalibration.features(
                            pairModel: $0.pairModel, cosine: $0.cosine, sharedSpecific: $0.sharedSpecific,
                            gapHours: $0.gapHours, sameAct: $0.sameAct),
                        same: $0.same)
                }
            }
            let replay = verdictReplay(rows)
            print(
                "    verdict replay (#629): \(replay.verdicts) verdicts, \(replay.bare) decided as the reader did at the"
                    + " cutoff, \(replay.calibrated) with the calibration\(replay.fitted ? "" : " (dormant)")")
            assertTrue(
                replay.fitted, "The verdict replay needs 50 verdicts with both answers; a dormant replay proves nothing"
            )
            assertTrue(replay.calibrated >= replay.bare, "The calibration decides no fewer verdicts right")
            return
        }
        if CommandLine.arguments.contains("--embedding-vectors") {
            guard let output = ProcessInfo.processInfo.environment["NEWS_EVENT_OUTPUT"] else {
                throw StoryCorpus.Failure.invalid("--embedding-vectors needs NEWS_EVENT_OUTPUT")
            }
            try await exportEmbeddingVectors(output: output)
            return
        }
        if CommandLine.arguments.contains("--compute-plan") {
            try await reportComputePlacement()
            return
        }
        if CommandLine.arguments.contains("--fragment-merge-timing") {
            try await timeFragmentMerge()
            return
        }
        if CommandLine.arguments.contains("--review-pairs") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let output = environment["NEWS_EVENT_OUTPUT"] else {
                throw StoryCorpus.Failure.invalid("--review-pairs needs NEWS_SNAPSHOT_DB and NEWS_EVENT_OUTPUT")
            }
            if CommandLine.arguments.contains("--holdout-candidates") {
                let rows = try await exportHoldoutCandidates(snapshot: snapshot, outputDirectory: output)
                print("    exported \(rows) library holdout candidate pairs (#579)")
                return
            }
            let rows = try await exportPairReview(snapshot: snapshot, outputDirectory: output)
            print("    exported \(rows) pair decisions for review (#551)")
            return
        }
        if CommandLine.arguments.contains("--features") {
            // Local: the matcher signals of each headline (one per line, optional tab and lead) in NEWS_FEATURES_FILE.
            guard let path = ProcessInfo.processInfo.environment["NEWS_FEATURES_FILE"] else {
                throw StoryCorpus.Failure.invalid("--features needs NEWS_FEATURES_FILE")
            }
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                let value = EventFeatures(title: parts[0], description: parts.count > 1 ? parts[1] : "", date: Date())
                print(parts[0])
                print(
                    "    people \(value.people.sorted()) orgs \(value.organizations.sorted()) places \(value.places.sorted())"
                        + " names \(value.names.sorted()) numbers \(value.titleNumbers.sorted()) act \(value.actClass)")
                print("    keywords \(value.keywords.sorted())")
                print(
                    "    days \(value.calendarDays.sorted()) series \(value.series ?? "none") \(value.seriesTerms.sorted())"
                        + " editions \(value.editions.sorted())")
            }
            return
        }
        if CommandLine.arguments.contains("--duplicate-replay") {
            // Local (#583): every same-publisher, same-headline pair of the last seven days of a library copy, re-ingested
            // into a fresh store as two feed items; prints how many pairs become one story and how many stay two.
            guard let snapshotPath = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] else {
                throw StoryCorpus.Failure.invalid("--duplicate-replay needs NEWS_SNAPSHOT_DB")
            }
            // Resolved first, so a link outside the container cannot point the replay at the live library.
            let snapshot = URL(fileURLWithPath: snapshotPath).resolvingSymlinksInPath().path
            guard !snapshot.contains("/Library/Containers/") else {
                throw StoryCorpus.Failure.invalid("Replay a copy of the library, never the live file")
            }
            let source = DatabaseEngine(path: snapshot)
            try await source.open()
            // Every article of the last seven days; the pairs are formed with the resolver's own folded key, so
            // punctuation and diacritics fold as in production and both sides of a pair lie inside the window.
            let articles = try await source.eventRows(
                """
                SELECT title, source, guid, canonical_url, published_at, id FROM articles
                WHERE published_at > (SELECT max(published_at) FROM articles) - 7 * 86400
                ORDER BY published_at, id;
                """)
            await source.close()
            var byKey: [String: [[String?]]] = [:]
            for row in articles {
                guard let title = row[0], let publisher = row[1],
                    let key = ArticleIdentity.publisherTitleKey(title: title, source: publisher)
                else { continue }
                byKey[key, default: []].append(row)
            }
            var pairs = 0
            var merged = 0
            var apart = 0
            for group in byKey.values.sorted(by: { ($0.first?[5] ?? "") < ($1.first?[5] ?? "") })
            where group.count >= 2 {
                for i in group.indices {
                    for j in group.indices where j > i {
                        let (x, y) = (group[i], group[j])
                        guard let title = x[0], let publisher = x[1], let first = x[4].flatMap(Double.init),
                            let second = y[4].flatMap(Double.init)
                        else { continue }
                        pairs += 1
                        let fresh = DatabaseEngine(path: ":memory:")
                        try await fresh.open()
                        let a = FeedArticle(
                            title: title, link: x[3] ?? "", guid: x[2], description: "",
                            pubDate: Date(timeIntervalSince1970: first), source: publisher)
                        let b = FeedArticle(
                            title: y[0] ?? title, link: y[3] ?? "", guid: y[2], description: "",
                            pubDate: Date(timeIntervalSince1970: second), source: publisher)
                        try await fresh.upsertArticles([a])
                        try await fresh.upsertArticles([b])
                        let one =
                            try await fresh.resolvedArticleID(for: a) == (try await fresh.resolvedArticleID(for: b))
                        await fresh.close()
                        if one { merged += 1 } else { apart += 1 }
                        print(
                            String(
                                format: "      %@ %.1fh %@: %@", one ? "one story " : "two stories",
                                abs(second - first) / 3600, publisher, title))
                    }
                }
            }
            print("    duplicate replay: \(pairs) same-publisher pairs, \(merged) become one story, \(apart) stay two")
            return
        }
        if CommandLine.arguments.contains("--library-holdout") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let holdout = environment["NEWS_LIBRARY_HOLDOUT"]
            else {
                throw StoryCorpus.Failure.invalid("--library-holdout needs NEWS_SNAPSHOT_DB and NEWS_LIBRARY_HOLDOUT")
            }
            try await evaluateLibraryHoldout(snapshot: snapshot, holdout: holdout)
            return
        }
        if CommandLine.arguments.contains("--model-outcome-check") {
            try await checkOnDeviceModelOutcomes()
            return
        }
        if CommandLine.arguments.contains("--active-work-cancellation") {
            try await testActiveWorkCancellation()
            return
        }
        let corpusMode =
            CommandLine.arguments.contains("--corpus-fingerprints") || CommandLine.arguments.contains("--corpus-events")
        try await StoryCorpus.run(evaluate: corpusMode)
        if corpusMode { return }
        var fixtureURL = URLComponents()
        fixtureURL.scheme = "https"
        fixtureURL.host = fixtureHost
        let fixtureRoot = fixtureURL.url!
        if CommandLine.arguments.contains("--fts-refresh-regression") {
            try await testUnchangedFTSRefresh()
            try await testFTSRowIDMigration()
            try await testDatabaseHealthAndDerivedRetention()
            try await testRealLibraryMigrationFixture()
            try await testLibraryBackupAndFutureSchemaGuard()
            try await testLibraryBackupRestore()
            try await testSQLiteFailuresAreNotEmptyResults()
            return
        }
        if CommandLine.arguments.contains("--export-pairs") {
            let environment = ProcessInfo.processInfo.environment
            guard let snapshots = environment["NEWS_SNAPSHOT_DB"], let output = environment["NEWS_EVENT_OUTPUT"],
                let corpusPath = environment["NEWS_EVENT_CORPUS"]
            else {
                throw StoryCorpus.Failure.invalid(
                    "--export-pairs needs NEWS_SNAPSHOT_DB, NEWS_EVENT_OUTPUT and NEWS_EVENT_CORPUS")
            }
            try await exportTrainingPairs(
                snapshots: snapshots, output: output, corpusPath: corpusPath,
                holdoutPath: environment["NEWS_LIBRARY_HOLDOUT"],
                verdictsOnly: CommandLine.arguments.contains("--verdicts-only"))
            return
        }
        if CommandLine.arguments.contains("--export-categories") {
            try await exportCategorySample()
            return
        }
        if CommandLine.arguments.contains("--event-corpus") {
            guard let path = ProcessInfo.processInfo.environment["NEWS_EVENT_CORPUS"] else {
                print("❌ Set NEWS_EVENT_CORPUS to a labeled event corpus JSON file")
                exit(1)
            }
            print("🏃 Evaluating event clustering on \(path)...")
            try await evaluateEventCorpus(
                path: path, selectedSplit: CommandLine.arguments.contains("--corpus-holdout") ? "holdout" : "tune",
                language: ProcessInfo.processInfo.environment["NEWS_EVENT_LANGUAGE"],
                outputDirectory: ProcessInfo.processInfo.environment["NEWS_EVENT_OUTPUT"])
            return
        }
        if CommandLine.arguments.contains("--performance-baseline") {
            try await runPerformanceBaseline()
            return
        }
        if CommandLine.arguments.contains("--search-memory") {
            try await runSearchMemory()
            return
        }
        if CommandLine.arguments.contains("--transport-cancellation") {
            try await testTransportCancellation()
            return
        }
        if CommandLine.arguments.contains("--publisher-cancellation") {
            try await testPublisherCancellation()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--debug-extract") {
            for path in CommandLine.arguments[(index + 1)...] {
                let html = ContentExtractionPipeline.shared.decodeHTML(
                    data: try Data(contentsOf: URL(fileURLWithPath: path)))
                let outcome = ContentExtractionPipeline.shared.extractFromHTML(html, baseUrl: "https://example.com/a")
                if case .success(let content, _, let doc) = outcome {
                    print(
                        "DBG", path.split(separator: "/").last!, "OK words",
                        content.split(whereSeparator: \.isWhitespace).count,
                        "complete", doc?.isComplete.map(String.init) ?? "nil")
                    // NEWS_DEBUG_BLOCKS=1 prints every block: kind, then its text or image URL.
                    if ProcessInfo.processInfo.environment["NEWS_DEBUG_BLOCKS"] != nil {
                        for block in doc?.blocks ?? [] {
                            let image = block.kind == .figure ? (block.imageURL ?? "") + " | " : ""
                            print("  [\(block.kind)] \(image)\(block.text)")
                        }
                    }
                } else {
                    print("DBG", path.split(separator: "/").last!, outcome)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--catalog-reader-access") {
            await testCatalogReaderAccess()
            return
        }
        if CommandLine.arguments.contains("--reader-live-pages") {
            await testLiveReader(pagesOnly: true)
            print("✅ Live reader pages passed")
            return
        }
        if CommandLine.arguments.contains("--story-regressions") {
            try await testReaderPhaseC(fixtureRoot: fixtureRoot)
            testReaderPassageMatcher()
            try await testReaderFigures(fixtureRoot: fixtureRoot)
            testReaderExtractionFidelity(fixtureRoot: fixtureRoot)
            try await testCanonicalArticleIngestion(fixtureRoot: fixtureRoot)
            try await testPersistentArticleAliases(fixtureRoot: fixtureRoot)
            try await testBatchStateAliasResolution()
            try await testFeedScopedGUIDs(fixtureRoot: fixtureRoot)
            try await testValidatedDocumentIdentity(fixtureRoot: fixtureRoot)
            try await testIdentityBaselineScenarios(fixtureRoot: fixtureRoot)
            try await testPublisherTextFingerprints()
            try await testOverviewDocumentModelBoundToInputsAndVersions(fixtureHost: fixtureHost)
            try await testOverviewVersionFollowsEventNotStorySum()
            try await testOverviewPassageSelectionAndTokenBudget(fixtureHost: fixtureHost)
            try await testPromptInjectionDefenses(fixtureHost: fixtureHost)
            try await testPassageAnchoredFactExtraction()
            try await testOverviewCompositionFromVerifiedFacts(fixtureHost: fixtureHost)
            try await testPlainTextGeneration(fixtureHost: fixtureHost)
            try await testOverviewPublisherEvidence(fixtureHost: fixtureHost)
            try await testOverviewQualityAuditAndReleaseGate(fixtureHost: fixtureHost)
            try await testOnDemandOverviewGenerationAndCaching(fixtureHost: fixtureHost)
            try await testOverviewGenerationCancellationAndSupersession(fixtureHost: fixtureHost)
            try await testDeterministicClaimVerification(fixtureHost: fixtureHost)
            testOverviewVerifierControls()
            try await testEventOverviewReaderMode(fixtureHost: fixtureHost)
            try await testOverviewResolutionWhenOpeningMemberArticle(fixtureHost: fixtureHost)
            try await testOverviewTimeline(fixtureHost: fixtureHost)
            try await testEventTimelineWithSourcedItems(fixtureHost: fixtureHost)
            try await testAttributedPerspectivesOfParticipantsAndPublishers(fixtureHost: fixtureHost)
            try await testThematicAngleFromExistingFacts(fixtureHost: fixtureHost)
            try await testCoverageSentimentEvaluation(fixtureHost: fixtureHost)
            try await testHistoricalReconciliation(fixtureRoot: fixtureRoot)
            try await testEventDataModel(fixtureRoot: fixtureRoot)
            try await testEventCandidateGeneration(fixtureRoot: fixtureRoot)
            try await testRelatedStoryEvents(fixtureRoot: fixtureRoot)
            try await testEventMatcherRules()
            testActClassTable()
            try await testEventClustering(fixtureRoot: fixtureRoot)
            try await testArticleSignalsRoundTrip()
            try await testPairAssessmentsRecorded()
            try await testReaderVerdictsExportAndGate()
            try await testStoryLayer()
            try await testStoryPassOrderIndependent()
            try await testEventInclusions()
            try await testPairModelGreyZone()
            try await testEventEmbeddingIntegration()
            try await testEventFragmentMergingAndJudge(fixtureRoot: fixtureRoot)
            try await testStoryVisibility(fixtureRoot: fixtureRoot)
            try await testStoryImages(fixtureRoot: fixtureRoot)
            try await testEventReadingState(fixtureRoot: fixtureRoot)
            testEventFeedSummaryUnit()
            await testEventFeedGroupingAndStability()
            testEventFeedGroupingOptimization()
            try await testFiniteBriefing()
            try await testPublisherContentProvenance()
            try await testRefreshClustersEvents(fixtureRoot: fixtureRoot)
            try await testStoryCheckForUpdates(fixtureRoot: fixtureRoot)
            try await testEventCorpusHarness(fixtureRoot: fixtureRoot)
            try await testMatcherRegressionCorpus()
            try await testStoryRegressionCorpus()
            try await testPairCalibration()
            try testCapturedFingerprintReview()
            try await testAuditPersistenceAndRoutingRegressions(fixtureRoot: fixtureRoot)
            try await testUndatedArticleOrdering()
            try await testFutureDatedItems()
            await testDatabaseEnginePersistence()
            await testFTS5SearchAndOperators()
            try await testUnchangedFTSRefresh()
            try await testSearchSpellingSuggestion()
            try await testRefreshStateKeepsChangesMadeWhileLoading()
            try await testCountsStayExactAcrossToggleAndBulkChanges()
            try await testUnreadCountAndSavedStateCoverTheLibrary()
            try await testFTSRowIDMigration()
            try await testDatabaseHealthAndDerivedRetention()
            try await testRealLibraryMigrationFixture()
            await testReaderParsingRegressions()
            await testStructuredReaderAndTags()
            await testReaderStoreUpdates()
            await testArticleRetentionPolicy()
            try await testGranularCacheClearingAndRetention()
            await testMultiPublisherExtractionFixtures()
            await testReaderFurnitureRemoval()
            print("✅ Story regressions passed")
            return
        }
        print("🏃 Running NewsApp Unit Tests...")
        let tests: [(name: String, run: () async throws -> Void)] = [
            ("testGatewayRejectionIsTransport", { try await rerunningLoopbackFlake(testGatewayRejectionIsTransport) }),
            ("testUserMuting", { try await testUserMuting() }),
            ("testSmartBinders", { try await testSmartBinders() }),
            ("testNavigationCommands", { await testNavigationCommands() }),
            ("testStoryExport", { try await testStoryExport() }),
            ("testStoryImages", { try await testStoryImages(fixtureRoot: fixtureRoot) }),
            ("testFiniteBriefing", { try await testFiniteBriefing() }),
            ("testDockBadgeCount", { testDockBadgeCount() }),
            ("testBriefingBoardLayout", { testBriefingBoardLayout() }),
            ("testDesignSystemAndArticleFilter", { await testDesignSystemAndArticleFilter() }),
            ("testNewsURLParserAndSchemeRouting", { await testNewsURLParserAndSchemeRouting() }),
            ("testAppIntentsExecutionAndValidation", { await testAppIntentsExecutionAndValidation() }),
            ("testAppShortcutsProviderDeclarations", { await testAppShortcutsProviderDeclarations() }),
            ("testSpotlightSavedStoriesIndexing", { try await testSpotlightSavedStoriesIndexing() }),
            ("testMenuBarExtraSettingsAndUnreadCount", { await testMenuBarExtraSettingsAndUnreadCount() }),
            ("EpicNE2ETests", { await EpicNE2ETests.run() }),
            ("testSocketNetworkBoundary", { try await rerunningLoopbackFlake(testSocketNetworkBoundary) }),
            ("testTransportCancellation", { try await rerunningLoopbackFlake(testTransportCancellation) }),
            ("testGatewayAddressFallback", { try await rerunningLoopbackFlake(testGatewayAddressFallback) }),
            ("testActiveWorkCancellation", { try await testActiveWorkCancellation() }),
            ("testSignpostHelperExecution", { await testSignpostHelperExecution() }),
            ("testOnboardingAndPermissionTiming", { await testOnboardingAndPermissionTiming() }),
            ("testStoryBannerRoute", { try await testStoryBannerRoute() }),
            ("testFeedArticleWrapContextNavigation", { await testFeedArticleWrapContextNavigation() }),
            ("testDiagnosticsExport", { try await testDiagnosticsExport() }),
            ("testLogWindowModel", { await testLogWindowModel() }),
            ("testDiagnosticsLibrary", { try await testDiagnosticsLibrary() }),
            ("testDiagnosticsFeeds", { await testDiagnosticsFeeds() }),
            ("testDiagnosticsClustering", { try await testDiagnosticsClustering() }),
            ("testDiagnosticsIntelligence", { try await testDiagnosticsIntelligence() }),
            ("testDiagnosticsNotifications", { try await testDiagnosticsNotifications() }),
            ("testDiagnosticsImages", { try await testDiagnosticsImages() }),
            ("testDiagnosticsNetwork", { await testDiagnosticsNetwork() }),
            ("testDiagnosticsProcess", { await testDiagnosticsProcess() }),
            ("testDiagnosticsLogFiles", { await testDiagnosticsLogFiles() }),
            ("testDiagnosticsSpotlightAndCaches", { await testDiagnosticsSpotlightAndCaches() }),
            ("testDiagnosticsSections", { try await testDiagnosticsSections() }),
            ("testCardImagePrefetchFirstPaint", { await testCardImagePrefetchFirstPaint() }),
            ("testStoryQuickLookPreview", { await testStoryQuickLookPreview() }),
        ]
        try await runSharded(tests)

        if ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1" {
            await testLiveReader()
        }
        if ProcessInfo.processInfo.environment["NEWS_LIVE_CATALOG_CHECK"] == "1" {
            await testLiveCatalog()
        }
        if let snapshot = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] {
            let database = DatabaseEngine(path: snapshot)
            try await database.open()
            let articles = try await database.fetchArticles(limit: 500)
            assertFalse(articles.isEmpty, "Migrated snapshot must display stored articles")
            let counts = try await database.counts()
            print("  - Migrated isolated snapshot: \(counts.total) stories, \(counts.saved) saved")
            await database.close()
        }
        print("✅ SUCCESS: All tests passed!")
    }

    /// Writes a new 10,000-story library for `script/launch_baseline.sh`: unread, recent and already clustered,
    /// so launch measures loading a steady-state archive rather than a first-run clustering backlog.
    static func seedLaunchLibrary(path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw StoryCorpus.Failure.invalid("Refusing to overwrite \(path)")
        }
        let db = DatabaseEngine(path: path)
        try await db.open()
        let now = Date()
        let prose = (1...20).map {
            "Researchers in London compared observation \($0) with the published evidence and documented the results."
        }.joined(separator: " ")
        let archive = (0..<10_000).map { index in
            FeedArticle(
                title: "Research report \(index)", link: "https://launch.invalid/article/\(index)",
                guid: "launch-\(index)",
                description: "Research evidence", pubDate: now.addingTimeInterval(-Double(index) * 15),
                source: "Publisher \(index % 20)", fullContent: prose,
                readerDocument: ReaderDocument(blocks: [ReaderBlock(kind: .paragraph, text: prose)]))
        }
        try await db.upsertArticles(archive, feedUrl: "https://launch.invalid/feed.xml")
        try await db.markEventMatchProcessed(archive.map(\.id), matcherVersion: EventMatcher.version, at: now)
        await db.close()
        print("Seeded \(archive.count) stories at \(path)")
    }

    /// Writes the sentence embedding of every authored-corpus article to `embedding-vectors.json` (#540), so a change
    /// to `SentenceEmbedder` can be compared vector by vector with the implementation before it.
    static func exportEmbeddingVectors(output: String) async throws {
        struct Item: Decodable { let id: String, title: String, description: String? }
        struct Fixture: Decodable { let articles: [Item] }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/matcher-regressions-v1.json")))
        let texts = fixture.articles.map {
            EventFeatures.matchingText(title: $0.title, description: $0.description ?? "")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let vectors = await SentenceEmbedder.shared.embedBatch(texts)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var byID: [String: [Float]] = [:]
        for (item, vector) in zip(fixture.articles, vectors) {
            guard let vector else { throw StoryCorpus.Failure.invalid("No embedding for \(item.id); nothing written") }
            byID[item.id] = vector
        }
        let file = try StoryCorpus.privateDirectory(output).appendingPathComponent("embedding-vectors.json")
        let data = try JSONSerialization.data(
            withJSONObject: byID.mapValues { $0.map(Double.init) }, options: [.sortedKeys])
        // An existing dump is the reference of a comparison, so it is never overwritten; use another directory.
        try StoryCorpus.writePrivate(data, to: file, replacing: false)
        print(
            String(
                format: "    embedded %d of %d texts in %.0f ms -> %@", byID.count, texts.count, elapsed * 1000,
                file.path))
    }

    /// Opt-in controlled service timings; not a rendered UI or network benchmark.
    @MainActor
    static func runPerformanceBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("test.performance")
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        settings.feedURLs = (0..<5).map { "https://baseline.example/feed-\($0)" }
        let db = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let prose = (1...20).map {
            "Researchers in London compared observation \($0) with the published evidence and documented the results."
        }.joined(separator: " ")
        // Past wall-clock dates: an upsert stores a future feed date as unknown (#981), which would empty the candidate
        // window below and leave the refreshed stories undated, behind the archive (#1043).
        let clusterNow = Date()
        func article(_ index: Int) -> FeedArticle {
            let image = "https://baseline.example/media/publisher-\(index % 20).jpg"
            let document = ReaderDocument(
                blocks: [ReaderBlock(kind: .paragraph, text: prose)],
                images: [ReaderImageCandidate(url: image, origin: .body, width: 1200, height: 800)], leadImageURL: image
            )
            return FeedArticle(
                title: "Research report \(index)", link: "https://baseline.example/article/\(index)",
                guid: "baseline-\(index)", description: "Research evidence",
                pubDate: clusterNow.addingTimeInterval(Double(index) - 10_250),
                source: "Publisher \(index % 20)", imageUrl: image, fullContent: prose, readerDocument: document)
        }
        let archive = (0..<10_000).map(article)
        try await db.upsertArticles(archive, now: clusterNow)
        // Steady-state archive, rather than a first-launch clustering backlog competing with refresh.
        try await db.markEventMatchProcessed(archive.map(\.id), matcherVersion: EventMatcher.version, at: clusterNow)
        var measurements = [String: [Double]]()
        func record(_ name: String, from start: Double) {
            measurements[name, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        // Diagnostics reports (#1006) on the 10,000-story library: every state writer plus the log and the redaction.
        // The app snapshot and the zip that Help › Export Diagnostics adds are not part of this time.
        let exportStart = ProcessInfo.processInfo.systemUptime
        let exportLog = try DiagnosticsExport.logLines(since: .distantPast)
        let exportSections = await DiagnosticsExport.sectionFiles(
            db, app: DiagnosticsExport.AppSnapshot(feedURLs: settings.feedURLs), log: exportLog, now: clusterNow)
        let exportFiles = DiagnosticsExport.files(
            summary: "News diagnostics\n", sections: exportSections, log: exportLog, titles: archive.map(\.title))
        record("diagnosticsExport", from: exportStart)
        print(
            "Diagnostics reports (no snapshot or zip): \(exportFiles.count) files in \(measurements["diagnosticsExport"]?.last ?? 0) ms"
        )
        let coldStart = ProcessInfo.processInfo.systemUptime
        assertTrue(await store.refreshState(), "Baseline snapshot hydrates")
        record("snapshot_first_500_ms", from: coldStart)
        assertEqual(store.articles.count, 500, "Baseline keeps the real snapshot limit")
        let batches = (0..<5).map { offset in (0..<50).map { article(10_000 + offset * 50 + $0) } }
        let freshGUIDs = Set(batches.flatMap { $0.compactMap(\.guid) })
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                zip(urls, batches).map { ($0.0, $0.1, nil, nil) }
            })
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            await manager.fetchFeedsAsync()
            record("refresh_5_mocked_feeds_ms", from: start)
            assertEqual(manager.articles.count, 500, "Refresh publishes the bounded snapshot")
            assertTrue(
                freshGUIDs.isSubset(of: Set(manager.articles.compactMap(\.guid))), "Refresh publishes the new stories")
            await manager.waitForEventClustering()
        }
        assertEqual(try await db.counts().total, 10_250, "Repeated refreshes keep one row per document")
        manager.stopBackgroundWork()

        // Paired query comparison on one database/index; alternate order to avoid warm-cache bias.
        var comparisonHandle: OpaquePointer?
        assertEqual(
            sqlite3_open_v2(
                directory.appendingPathComponent("library.sqlite3").path, &comparisonHandle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK, "Open isolated candidate comparison")
        defer { sqlite3_close(comparisonHandle) }
        let probe = archive[9_800]
        let candidateQuery = "{title description} : (\"research\" OR \"report\")"
        func legacyCandidateRows() -> [[String?]] {
            let sql = """
                SELECT a.id, a.title, coalesce(a.description, ''), m.event_id
                FROM articles_fts fts JOIN articles a ON a.id = fts.article_id
                LEFT JOIN event_members m ON m.article_id = a.id
                LEFT JOIN events e ON e.id = m.event_id
                WHERE articles_fts MATCH ? AND a.id != ?
                    AND CASE WHEN a.published_at = \(DateParser.unknownDate.timeIntervalSince1970)
                        THEN a.created_at ELSE a.published_at END BETWEEN ? AND ?
                    AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)
                    AND (m.event_id IS NULL OR e.updated_at >= ?)
                ORDER BY fts.rank, a.id LIMIT 80;
                """
            var statement: OpaquePointer?
            assertEqual(
                sqlite3_prepare_v2(comparisonHandle, sql, -1, &statement, nil), SQLITE_OK,
                "Prepare legacy candidate comparison")
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, candidateQuery, -1, transient)
            sqlite3_bind_text(statement, 2, probe.id, -1, transient)
            sqlite3_bind_double(statement, 3, probe.pubDate.timeIntervalSince1970 - 48 * 3600)
            sqlite3_bind_double(statement, 4, probe.pubDate.timeIntervalSince1970 + 48 * 3600)
            sqlite3_bind_double(statement, 5, clusterNow.timeIntervalSince1970 - 72 * 3600)
            var rows: [[String?]] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                rows.append((0..<4).map { sqlite3_column_text(statement, Int32($0)).map { String(cString: $0) } })
                status = sqlite3_step(statement)
            }
            assertEqual(status, SQLITE_DONE, "Legacy candidate comparison completes")
            return rows
        }
        let expectedCandidates = legacyCandidateRows()
        assertEqual(expectedCandidates.count, 80, "Paired comparison returns the full candidate cap")
        func measureLegacy() {
            let start = ProcessInfo.processInfo.systemUptime
            let rows = legacyCandidateRows()
            record("event_candidate_legacy_join_ms", from: start)
            assertEqual(rows, expectedCandidates, "Legacy candidate comparison stays deterministic")
        }
        func measureMapped() async throws {
            let start = ProcessInfo.processInfo.systemUptime
            let rows = try await db.eventCandidateRows(
                matching: candidateQuery, around: probe.pubDate,
                window: 48 * 3600, activeSince: clusterNow.addingTimeInterval(-72 * 3600), excluding: probe.id,
                limit: 80)
            record("event_candidate_rowid_join_ms", from: start)
            assertEqual(
                rows.map { [$0.id, $0.title, $0.description, $0.eventID] }, expectedCandidates,
                "Durable rowid join preserves all ordered candidate fields")
        }
        for iteration in 0..<10 {
            if iteration.isMultiple(of: 2) {
                measureLegacy()
                try await measureMapped()
            } else {
                try await measureMapped()
                measureLegacy()
            }
        }
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let rows = try await db.searchArticles(query: "Research", limit: 100)
            record("fts_first_100_ms", from: start)
            assertEqual(rows.count, 100, "FTS benchmark returns expected rows")
        }

        // Hybrid search (FTS5 BM25 + embedding cosine, RRF; #708). A query every story matches, so both arms rank the
        // whole library: the worst case of the lexical arm. Synthetic unit vectors: the first 150 stories align with the
        // query (cosine 0.9), the rest do not (0.1).
        let vectorDimension = SentenceEmbedder.vectorDimension
        let halfDimension = sqrt(Double(vectorDimension / 2))
        let benchmarkQueryVector: [Float] = (0..<vectorDimension).map { $0 % 2 == 0 ? Float(1 / halfDimension) : 0 }
        func syntheticEmbeddings(_ articles: ArraySlice<FeedArticle>) -> [String: [Float]] {
            var vectors: [String: [Float]] = [:]
            vectors.reserveCapacity(articles.count)
            for (index, article) in articles.enumerated() {
                let align = index < 150 ? 0.9 : 0.1
                let even = Float(align / halfDimension)
                let odd = Float(sqrt(max(0, 1 - align * align)) / halfDimension)
                vectors[article.id] = (0..<vectorDimension).map { $0 % 2 == 0 ? even : odd }
            }
            return vectors
        }
        // #708's acceptance: a 5,000-story seeded library, every story embedded.
        let searchLibrary = DatabaseEngine(path: directory.appendingPathComponent("search-5000.sqlite3").path)
        try await searchLibrary.open()
        try await searchLibrary.upsertArticles(Array(archive.prefix(5_000)))
        try await searchLibrary.upsertArticleEmbeddings(
            syntheticEmbeddings(archive.prefix(5_000)), modelVersion: SentenceEmbedder.modelVersion)
        // The 10,000-story archive above with 5,000 of its stories embedded: the number #953 first reported.
        try await db.upsertArticleEmbeddings(
            syntheticEmbeddings(archive.prefix(5_000)), modelVersion: SentenceEmbedder.modelVersion)
        let searchRuns = [
            (searchLibrary, "hybrid_search_5000_stories_ms", 5_000),
            (db, "hybrid_search_10000_archive_ms", 10_250),
        ]
        // Alternate the order of the two libraries so neither always runs on a warmer cache.
        for iteration in 0..<10 {
            for (library, name, total) in iteration.isMultiple(of: 2) ? searchRuns : searchRuns.reversed() {
                let start = ProcessInfo.processInfo.systemUptime
                let rows = try await library.searchArticles(
                    query: "Research", limit: 100, queryEmbedding: benchmarkQueryVector)
                record(name, from: start)
                assertEqual(rows.count, 100, "Hybrid search benchmark returns a full page (\(total) matches)")
                assertTrue(rows.allSatisfy { $0.searchSnippet != nil }, "Every lexical hit of the page has a snippet")
            }
        }
        await searchLibrary.close()
        let html =
            "<article><h2>Evidence</h2><p>\(prose)</p><figure><img src='/photo.jpg' width='1200' height='800'></figure><p>\(prose)</p></article>"
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            assertTrue(
                ContentExtractionPipeline.shared.extractFromHTML(html, baseUrl: "https://baseline.example/story")
                    .isSuccess, "Benchmark extraction succeeds")
            record("html_extraction_ms", from: start)
            let analysisStart = ProcessInfo.processInfo.systemUptime
            let analysis = try await ArticleAnalyzer.shared.analyze(
                title: "Research evidence", content: prose, allowFoundationModels: false)
            record("natural_language_analysis_ms", from: analysisStart)
            assertFalse(analysis.summary.isEmpty, "Deterministic analysis returns publisher-derived text")
        }

        // Event clustering & feed grouping (#104, #153). Unchanged archives must do no matching work.
        try await db.markEventMatchProcessed(
            batches.flatMap { $0 }.map(\.id), matcherVersion: EventMatcher.version, at: clusterNow)
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let report = try await EventClusterer.run(in: db, now: clusterNow)
            record("event_clustering_unchanged_ms", from: start)
            assertEqual(report.processed, 0, "Unchanged refresh does not recompute the archive")
        }
        // Reset the same 200 rows for each dense candidate pass: equal work, not successive backlog slices.
        let denseIDs = archive.suffix(200).map(\.id)
        var processedRows: [Int] = []
        for _ in 0..<5 {
            try await db.markEventMatchProcessed(denseIDs, matcherVersion: 0, at: clusterNow)
            let start = ProcessInfo.processInfo.systemUptime
            let report = try await EventClusterer.run(in: db, now: clusterNow, limit: 200)
            record("event_clustering_dense_200_ms", from: start)
            processedRows.append(report.processed)
            assertEqual(report.processed, 200, "Each dense pass processes exactly the reset rows")
            assertTrue(
                try await db.pendingEventMatchRows(
                    activeSince: clusterNow.addingTimeInterval(-72 * 3600),
                    matcherVersion: EventMatcher.version, limit: 1
                ).isEmpty, "Dense pass drains its bounded work")
        }
        let snapshotArticles = Array(store.articles.prefix(500))
        let snapshotIDs = snapshotArticles.map(\.id)
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let summaries = try await store.eventFeedSummaries(for: snapshotIDs)
            let entries = EventFeedGrouping.entries(for: snapshotArticles, events: summaries, mode: .events)
            record("event_feed_grouping_ms", from: start)
            assertFalse(entries.isEmpty, "Grouped feed entries are not empty")
        }

        // Overview generation & cached lookup (#104, #153)
        let eventArticles = Array(archive.prefix(3))
        let queue = EnrichmentQueue(store: store)
        let coordinator = OverviewGenerationCoordinator(store: store, queue: queue)
        for i in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let doc = await coordinator.requestOverview(
                eventID: "bench-event-\(i)",
                eventTitle: "Research report on observation",
                membershipVersion: 1,
                articles: eventArticles,
                priority: .visibleEvent
            )
            record("overview_generation_ms", from: start)
            assertTrue(doc != nil, "Benchmark overview generation succeeds")
        }
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let cached = try await store.fetchEventOverview(eventID: "bench-event-0")
            record("overview_cached_ms", from: start)
            assertTrue(cached != nil, "Cached overview lookup succeeds")
        }
        for _ in 0..<10 {
            let entered = TestCounter()
            let cancelledManager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { _, _ in
                    await entered.increment()
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {}
                    return []
                })
            let refresh = Task { await cancelledManager.fetchFeedsAsync() }
            while await entered.value == 0 { await Task.yield() }
            let start = ProcessInfo.processInfo.systemUptime
            cancelledManager.stopBackgroundWork()
            await refresh.value
            record("refresh_cancel_mock_wait_ms", from: start)
        }
        // Embedding throughput (#540): a fresh embedder, model load included, over 2,000 archive texts.
        if await SentenceEmbedder.shared.isAvailable {
            let texts = archive.prefix(2_000).map {
                EventFeatures.matchingText(title: $0.title, description: $0.description)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let vectors = await SentenceEmbedder().embedBatch(texts)
            record("embedding_cold_2000_ms", from: start)
            guard vectors.allSatisfy({ $0 != nil }) else { fatalError("Every archive text embeds") }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("Cannot obtain process memory high-water mark") }
        let report: [String: Any] = [
            "library_rows": 10_250, "publishers": 20, "snapshot_rows": 500,
            "search_library_rows": 5_000, "search_library_embeddings": 5_000, "archive_embeddings": 5_000,
            "feed_count": 5, "fresh_rows_per_feed": 50, "prose_characters": prose.count, "html_characters": html.count,
            "dense_clustering_processed_rows": processedRows,
            "candidate_comparison_rows": expectedCandidates.count,
            "sqlite_version": String(cString: sqlite3_libversion()),
            "peak_process_rss_bytes": usage.ru_maxrss, "measurements_ms": measurements,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_count": ProcessInfo.processInfo.processorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "optimization": "-O (test.sh performance mode)",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("PERFORMANCE_BASELINE_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("PERFORMANCE_BASELINE_JSON_END")
        await db.close()
    }

    /// Opt-in (#708): the process footprint over repeated searches of a 5,000-story seeded library, each through the
    /// path a list's search takes (`ArticleListView.performQueryReload`): the text embedded by the on-device model,
    /// the first page, the muted count and the masthead totals, the next page, and for every tenth a spelling
    /// suggestion. Every search has new text, as typing does, so each one embeds and runs a new query vector.
    /// Footprint is sampled after each block of searches; the check passes when the last sample is within
    /// `NEWS_SEARCH_MEMORY_LIMIT_MB` (default 6) of the first one after the warm-up. Runs on 3 November 2026 showed
    /// one-time steps of up to 3.8 MiB and no trend over 1,500 searches. Over the default 500 searches, 6 MiB fails
    /// any steady growth above about 12.3 KiB a search (6 MiB / 500), far below one retained model output
    /// (128 × 384 floats, 192 KiB); smaller or intermittent growth can stay under it.
    @MainActor
    static func runSearchMemory() async throws {
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { fatalError("Cannot read the process footprint") }
            return info.phys_footprint
        }
        func mebibytes(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
        guard await SentenceEmbedder.shared.isAvailable else {
            fatalError("The search memory check needs the embedder")
        }
        let environment = ProcessInfo.processInfo.environment
        let blocks = Int(environment["NEWS_SEARCH_MEMORY_BLOCKS"] ?? "") ?? 10
        // Zero blocks would compare the warm-up sample with itself and pass without a measured search.
        guard blocks >= 1 else { fatalError("NEWS_SEARCH_MEMORY_BLOCKS must be at least 1") }
        let perBlock = 50
        let limit = Double(environment["NEWS_SEARCH_MEMORY_LIMIT_MB"] ?? "") ?? 6

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-search-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
        try await db.open()
        let topics = [
            "central bank raises interest rates", "wildfire forces evacuations", "parliament passes budget",
            "storm floods coastal towns", "court rules on election appeal", "chipmaker reports record revenue",
            "vaccine trial shows results", "football club signs striker", "satellite launch succeeds",
            "strike halts rail services",
        ]
        let prose = (1...20).map {
            "Researchers in London compared observation \($0) with the published evidence and documented the results."
        }.joined(separator: " ")
        let archive = (0..<5_000).map { index in
            FeedArticle(
                title: "\(topics[index % topics.count].capitalized) in report \(index)",
                link: "https://memory.invalid/article/\(index)", guid: "memory-\(index)",
                description: "Research evidence on \(topics[(index / 10) % topics.count])",
                pubDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                source: "Publisher \(index % 20)", fullContent: prose)
        }
        try await db.upsertArticles(archive)
        let vectors = await SentenceEmbedder.shared.embedBatch(
            archive.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
        var embeddings: [String: [Float]] = [:]
        for (article, vector) in zip(archive, vectors) { embeddings[article.id] = vector }
        guard embeddings.count == archive.count else { fatalError("Every seeded story embeds") }
        try await db.upsertArticleEmbeddings(embeddings, modelVersion: SentenceEmbedder.modelVersion)
        embeddings = [:]

        let muting = MuteRules(topics: ["wildfire"])
        var searches = 0
        var listed = 0
        var durations: [Double] = []
        func search() async throws {
            // New text every time, as typing gives: a topic, a number and a word that changes the embedding.
            let words = ["latest", "update", "analysis", "reaction", "impact"]
            let text = "\(topics[searches % topics.count]) \(words[(searches / 10) % words.count]) \(searches)"
            searches += 1
            let start = ProcessInfo.processInfo.systemUptime
            let page = try await db.searchArticles(query: text, limit: 201, muting: muting)
            let vector = try await db.searchQueryVector(for: text)
            _ = try await db.mutedArticleCount(search: text, searchVector: vector, muting: muting)
            let totals = try await db.listTotals(search: text, searchVector: vector, muting: muting)
            if let last = page.last {
                _ = try await db.searchArticles(
                    query: text, limit: 201, after: ArticleQueryCursor(last), muting: muting)
            }
            if searches.isMultiple(of: 10) {
                _ = try await db.searchSuggestion(query: "wildfyre evacuashuns \(searches)", muting: muting)
            }
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            listed += totals.stories
        }
        for _ in 0..<perBlock { try await search() }  // Warm-up: model, SQLite page cache, spelling vocabulary.
        // Latency and listed counts cover the measured searches only, as the footprint samples do.
        durations.removeAll()
        listed = 0
        var samples = [footprint()]
        for _ in 0..<blocks {
            for _ in 0..<perBlock { try await search() }
            samples.append(footprint())
        }
        await db.close()
        // Raw bytes are compared with the limit; only the reported value is rounded.
        let rawGrowth = (Double(samples.last!) - Double(samples.first!)) / 1_048_576
        let growth = (rawGrowth * 10).rounded() / 10
        let sorted = durations.sorted()
        let report: [String: Any] = [
            "library_rows": archive.count, "embeddings": archive.count, "warm_up_searches": perBlock,
            "measured_searches": blocks * perBlock, "searches_per_sample": perBlock,
            "footprint_mb": samples.map(mebibytes), "growth_mb": growth, "limit_mb": limit,
            "search_round_ms_median": sorted[sorted.count / 2], "search_round_ms_p95": sorted[sorted.count * 95 / 100],
            "mean_listed_stories": listed / (blocks * perBlock),
            "sqlite_version": String(cString: sqlite3_libversion()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "optimization": "-O (test.sh search memory mode)",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("SEARCH_MEMORY_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("SEARCH_MEMORY_JSON_END")
        assertTrue(listed > 0, "Searches list stories")
        assertTrue(
            rawGrowth <= limit,
            "Footprint stays within the limit over \(blocks * perBlock) searches: grew \(growth) MiB"
                + " (limit \(limit) MiB)")
    }

    static func testLiveReader(pagesOnly: Bool = false) async {
        for link in [
            "https://www.bbc.co.uk/news/articles/c6jdvmy1287yo", "https://www.bbc.co.uk/news/articles/cm750pyz5r0eo",
        ] {
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(from: link)
            guard case .success(let content, _, let document) = outcome else {
                assertTrue(false, "BBC reader regression must extract publisher prose")
                continue
            }
            assertTrue(document != nil, "Live publisher retains reader structure")
            print(
                "Live page: \(link), \(content.count) prose characters, \(document?.blocks.count ?? 0) blocks, \(document?.images?.count ?? 0) image candidates"
            )
            assertFalse(content.contains("Get in touch"), "BBC contact furniture excluded")
            assertFalse(content.contains("17:45 weekdays"), "BBC listening promotion excluded")
        }

        if pagesOnly { return }
        for url in [
            "https://www.theguardian.com/world/rss", "https://feeds.arstechnica.com/arstechnica/index",
            "https://www.nasa.gov/feed/",
        ] {
            let result = await FeedFetcher.shared.fetchSingleFeed(urlString: url)
            assertTrue(result.error == nil, "Live feed fetch must succeed for \(url)")
            guard let article = result.articles?.first else {
                assertTrue(false, "Live feed must contain an article")
                continue
            }
            let outcome = await ContentExtractionPipeline.shared.extractArticleDetailed(from: article.link)
            let content = article.fullContent ?? outcome.content ?? ""
            assertFalse(
                ArticleContentRedactor.redactAndSplit(content).isEmpty,
                "Live publisher article must provide readable prose for \(url)")
            print(
                "  - Live reader: \(URL(string: url)!.host!), \(result.articles!.count) items, \(content.count) body characters; extraction success: \(outcome.isSuccess)"
            )
        }
    }

    /// Upstream failures reach `URLSession` only as the gateway's SOCKS rejection, so this runs the real gateway and
    /// the real `URLSession`: if the error the OS reports for it changes, a VPN switch must not turn into `unknown`.
    static func testGatewayRejectionIsTransport() async throws {
        print("  - Testing that a gateway rejection is classified as transport (#927)...")
        let publicAddress: IPAddressValidator.ValidationResult = .allowed(ips: ["93.184.216.34"])
        func failure(gatewayAnswer: IPAddressValidator.ValidationResult) async -> FeedFailureKind? {
            let gateway = NetworkBoundaryProxy(
                resolver: { _ in gatewayAnswer },
                // Port 1 on loopback refuses at once: an upstream that cannot be reached.
                connector: { _, _ in NWConnection(host: "127.0.0.1", port: 1, using: .tcp) })
            assertTrue(NetworkBoundaryProxy.directParameters.preferNoProxies, "Upstream asks for no proxy (#929)")
            assertTrue(NetworkBoundaryProxy.permitsUpstream(proxyConfigured: false), "A direct connection may relay")
            assertTrue(!NetworkBoundaryProxy.permitsUpstream(proxyConfigured: true), "A proxied connection is refused")
            assertTrue(!NetworkBoundaryProxy.permitsUpstream(proxyConfigured: nil), "A missing report is refused")
            let client = SecureHTTPClient(gateway: gateway, resolver: { _ in publicAddress })
            let result = await FeedFetcher(client: client).fetchSingleFeed(urlString: "https://example.com/feed.xml")
            await gateway.stop()
            return result.error?.failureKind
        }
        assertEqual(
            await failure(gatewayAnswer: publicAddress), .transport,
            "An upstream that refuses is a transport failure")
        assertEqual(
            await failure(gatewayAnswer: .unresolvable(reason: "Timed out")), .transport,
            "A lookup the gateway could not finish is a transport failure")
    }

    /// Polls observable state with a deadline so a regression fails instead of hanging.
    static func eventually(_ message: String, timeout: Duration = .seconds(10), _ condition: @escaping () async -> Bool)
        async
    {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                assertTrue(false, message)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Fetches every catalog feed through the app's own protected networking and parsers. Needs the network.
    static func testLiveCatalog() async {
        print("  - Live catalog check: fetching \(FeedCatalog.feeds.count) feeds...")
        let results = await FeedFetcher().fetchAllFeeds(urls: FeedCatalog.feeds.map(\.url))
        var failures: [String] = []
        for feed in FeedCatalog.feeds {
            guard let result = results.first(where: { $0.urlString == feed.url }) else {
                failures.append("\(feed.id): no result")
                continue
            }
            if let error = result.error {
                failures.append("\(feed.id): \(error.localizedDescription)")
            } else if (result.articles ?? []).isEmpty {
                failures.append("\(feed.id): no articles")
            }
        }
        for failure in failures { print("    ✗ \(failure)") }
        assertTrue(
            failures.isEmpty,
            "Every catalog feed fetches and parses (\(failures.count) of \(FeedCatalog.feeds.count) failed)")
    }

    /// Opt-in, live: opens the newest stories of every catalog feed in the app's own reader extraction. Free, open
    /// feeds only: a feed whose articles refuse the reader (HTTP 403, paywall teaser) does not belong in the catalog.
    static func testCatalogReaderAccess() async {
        let only = Set(
            (ProcessInfo.processInfo.environment["NEWS_CATALOG_FEEDS"] ?? "").split(separator: ",").map(String.init))
        let sample = Int(ProcessInfo.processInfo.environment["NEWS_CATALOG_SAMPLE"] ?? "") ?? 3
        let feeds = FeedCatalog.allFeeds.filter { only.isEmpty || only.contains($0.id) }
        print("  - Catalog reader access: \(feeds.count) feeds, up to \(sample) stories each...")
        let results = await FeedFetcher().fetchAllFeeds(urls: feeds.map(\.url))
        await withTaskGroup(of: String.self) { group in
            for feed in feeds {
                let links = (results.first { $0.urlString == feed.url }?.articles ?? [])
                    .map(\.link).filter { !$0.isEmpty }.prefix(sample)
                group.addTask {
                    guard !links.isEmpty else { return "\(feed.id)\tno stories in feed" }
                    var readable = 0
                    var words: [Int] = []
                    var failures: [String] = []
                    for link in links {
                        let outcome = await ContentExtractionPipeline.shared.extractArticleWithIdentity(from: link)
                            .outcome
                        if case .success(let content, _, _) = outcome {
                            readable += 1
                            words.append(content.split(whereSeparator: \.isWhitespace).count)
                        } else {
                            failures.append("\(outcome)".prefix(60).description)
                        }
                    }
                    let median = words.sorted().dropFirst(words.count / 2).first ?? 0
                    return
                        "\(feed.id)\t\(feed.language)\treadable \(readable)/\(links.count)\tmedian words \(median)\t\(failures.joined(separator: "; "))"
                }
            }
            var lines: [String] = []
            for await line in group { lines.append(line) }
            for line in lines.sorted() { print("    \(line)") }
        }
    }

    @MainActor
    static func testUserMuting() async throws {
        print("  - Testing user-controlled source and topic muting...")
        assertEqual(
            MuteRules.words("Art's covid-19 Zürich").map(String.init), ["art", "s", "covid", "19", "zürich"],
            "Topic words keep diacritics and split on everything but letters and digits")
        assertEqual(
            MuteRules.foldedWords("Art's covid-19 Zürich ZURICH"), ["art", "s", "covid", "19", "zurich", "zurich"],
            "Folded words drop case and diacritics for text-to-text matching")
        var rules = MuteRules()
        assertEqual(
            rules.addSource("https://www.Example.com/world?id=1"), "example.com", "A URL mutes its publisher host")
        assertEqual(rules.addSource("EXAMPLE.com"), nil, "A host is muted once")
        assertEqual(MuteRules.host("not a host"), nil, "Text with spaces is not a host")
        assertEqual(MuteRules.host("localhost"), nil, "A muted host needs a domain")
        assertEqual(MuteRules.host("news..example.com"), nil, "Empty host labels are rejected")
        assertTrue(rules.mutesSource(link: "https://news.example.com/a"), "A host covers its subdomains")
        assertFalse(
            rules.mutesSource(link: "https://badexample.com/a"), "A host does not cover another name ending in it")
        assertFalse(
            rules.mutesSource(link: "https://example.com.attacker.net/a"),
            "A host does not cover a name that only contains it")
        assertFalse(rules.mutesSource(link: ""), "A story without a document URL is never source-muted")
        assertFalse(rules.mutesTopic(title: "Example.com launches", description: ""), "Source rules never match words")

        assertEqual(
            rules.addTopic("  Climate   change "), "Climate change",
            "Topics keep the reader's words with whitespace collapsed")
        assertEqual(rules.addTopic("CLIMATE CHANGE"), nil, "A topic is muted once in any letter case")
        assertEqual(rules.addTopic("?!"), nil, "A topic needs a word")
        assertEqual(
            rules.addTopic(String(repeating: "a", count: MuteRules.topicLength + 1)), nil,
            "Overlong topics are rejected")
        for topic in ["art", "Війна", "covid-19", "cafe"] {
            assertEqual(rules.addTopic(topic), topic, "Topic \(topic) is added")
        }
        func mutesTopic(_ title: String, _ description: String = "") -> Bool {
            rules.mutesTopic(title: title, description: description)
        }
        assertTrue(mutesTopic("Modern art fair opens"), "A topic matches a whole word in the headline")
        assertTrue(
            mutesTopic("Gallery news", "The Art's new home"), "Topics match in the feed summary and before apostrophes")
        assertFalse(mutesTopic("Artist wins prize"), "A topic never matches inside a longer word")
        assertTrue(mutesTopic("Climate-change protests grow"), "Phrases match across punctuation")
        assertFalse(mutesTopic("Climate policy change"), "Phrase words must be adjacent and in order")
        assertTrue(mutesTopic("ВІЙНА триває"), "Matching ignores letter case beyond ASCII")
        assertFalse(mutesTopic("Війни не буде"), "Other word forms are other words")
        assertTrue(mutesTopic("COVID 19 cases fall"), "A hyphenated topic matches the same words")
        assertFalse(mutesTopic("Best café in town"), "Diacritics are significant")
        assertFalse(rules.mutesSource(link: "https://art.org/climate-change"), "Topic rules never match links")
        assertEqual(
            rules.matchedTopics(title: "Art and climate change", description: ""), ["Climate change", "art"],
            "Each covering topic is reported")
        assertEqual(MuteRules(sources: rules.sources, topics: rules.topics), rules, "Stored rules restore unchanged")

        // A topic set mutes its fixed phrases with one switch (#590); whole words keep "Dubai" and "aid" visible.
        let aiSet = MuteTopicSet.artificialIntelligence.id
        var sets = MuteRules()
        assertTrue(sets.addTopicSet(aiSet), "A known topic set switches on")
        assertFalse(sets.addTopicSet(aiSet), "A topic set switches on once")
        assertFalse(sets.addTopicSet("unknown-set"), "Unknown sets are ignored")
        assertFalse(sets.isEmpty, "A switched-on set is a muting rule")
        assertTrue(
            sets.mutesTopic(title: "OpenAI says its agents disabled their own safety monitors", description: ""),
            "A set phrase matches as a whole word in the headline")
        assertTrue(sets.mutesTopic(title: "Firms rush to adopt A.I. tools", description: ""), "A.I. matches")
        assertFalse(sets.mutesTopic(title: "Dubai aid flight lands in Gaza", description: ""), "Dubai and aid stay")
        assertFalse(sets.mutesTopic(title: "Claudette reopens", description: "Said the mayor"), "Longer words stay")
        assertEqual(sets.matchedTopicSets(title: "AI startup raises funds", description: ""), [aiSet], "Sets report")
        assertEqual(MuteRules(topicSets: sets.topicSets), sets, "Stored sets restore unchanged")
        sets.removeTopicSet(aiSet)
        assertTrue(sets.isEmpty, "Switching a set off removes every phrase")

        // SQLite applies muting before LIMIT and reports what it hid.
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func story(_ index: Int, _ link: String, _ title: String, _ description: String = "") -> FeedArticle {
            FeedArticle(
                title: title, link: link, guid: "mute-\(index)", description: description,
                pubDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60), source: "Publisher")
        }
        let stories = [
            story(0, "https://www.example.com/0", "Example lead"),
            story(1, "https://news.example.com/1", "Example subdomain"),
            story(2, "https://other.org/2", "Climate change summit"),
            story(3, "https://other.org/3", "Budget passes", "Markets react"),
            story(4, "https://other.org/4", "Artist profile", "A gallery opening"),
            story(5, "https://other.org/5", "Election results", "Art market shrugs"),
            story(6, "https://other.org/6", "Weather"),
        ]
        try await db.upsertArticles(stories)
        let muting = MuteRules(sources: ["example.com"], topics: ["Climate change", "art"])
        let firstPage = try await db.fetchArticles(limit: 1, muting: muting)
        assertEqual(
            firstPage.map(\.id), [stories[3].id],
            "The first page is filled from unmuted stories, not trimmed after LIMIT")
        let remainder = try await db.fetchArticles(limit: nil, after: ArticleQueryCursor(firstPage[0]), muting: muting)
        assertEqual(
            (firstPage + remainder).map(\.id), [stories[3].id, stories[4].id, stories[6].id],
            "Cursor pages continue over unmuted stories only")
        assertEqual(
            try await db.mutedArticleCount(muting: muting), 4,
            "The list counts every muted story, beyond the first page")
        assertEqual(try await db.fetchArticles(limit: nil).count, stories.count, "Nothing is hidden without rules")
        assertEqual(try await db.mutedArticleCount(muting: MuteRules()), 0, "No rules hide no stories")
        try await db.markRead(articleId: stories[0].id, isRead: true)
        assertEqual(
            try await db.mutedArticleCount(isRead: false, muting: muting), 3, "Hidden counts use the list's own filters"
        )
        try await db.setSaved(articleId: stories[2].id, isSaved: true)
        assertEqual(
            try await db.fetchArticles(isSaved: true).map(\.id), [stories[2].id],
            "Saved Stories, queried without rules, keep muted stories")
        assertTrue(try await db.searchArticles(query: "example", muting: muting).isEmpty, "Search applies muting")
        assertEqual(
            try await db.searchArticles(query: "example").count, 2, "Search without rules finds the muted stories")
        assertEqual(
            try await db.mutedArticleCount(search: "example", muting: muting), 2,
            "Search reports how many stories muting hid")
        let ruleCounts = try await db.mutedRuleCounts(muting)
        assertEqual(ruleCounts.sources, ["example.com": 2], "Settings count the stories each source rule covers")
        assertEqual(
            ruleCounts.topics, ["Climate change": 1, "art": 1], "Settings count the stories each topic rule covers")
        try await db.upsertArticles([
            story(7, "https://other.org/7", "OpenAI agents disabled monitors"),
            story(8, "https://other.org/8", "Dubai aid flight lands", "AIDS research funded"),
        ])
        let aiMuting = MuteRules(topicSets: [aiSet])
        assertEqual(
            try await db.mutedArticleCount(muting: aiMuting), 1, "SQLite hides a set's stories by whole words only")
        assertEqual(
            try await db.fetchArticles(limit: nil, muting: aiMuting).count, stories.count + 1,
            "The SQLite and Swift paths agree on what a set hides")
        assertEqual(try await db.mutedRuleCounts(aiMuting).topicSets, [aiSet: 1], "Settings count a set's stories")

        // The masthead counts the whole list, not its loaded page (#782): an event counts once it groups a listed
        // story, and its read or muted reports still count toward its size, as on its card.
        _ = try await db.applyEventMatch(
            stories[3].id, .create(with: [stories[6].id]), matcherVersion: EventMatcher.version)
        _ = try await db.applyEventMatch(
            stories[4].id, .create(with: [stories[0].id]), matcherVersion: EventMatcher.version)
        let totals = try await db.listTotals(section: "Today", isRead: false, muting: muting)
        assertEqual(totals.stories, 5, "Totals count unread, unmuted stories across every page")
        assertEqual(totals.events, 2, "Totals count the events grouping listed stories")
        let whole = try await db.fetchArticles(section: "Today", isRead: false, limit: nil, muting: muting)
        let grouped = EventFeedGrouping.entries(
            for: whole, events: try await db.eventFeedSummaries(forArticles: whole.map(\.id)), mode: .events)
        assertEqual(
            grouped.filter { if case .event = $0 { return true } else { return false } }.count, totals.events,
            "Totals group events exactly as the list does")
        assertEqual(whole.count, totals.stories, "Totals match the list's stories")
        assertEqual(
            try await db.listTotals(search: "example").stories, 2, "Search totals use the search's own filters")
        await db.close()

        // Rules persist with the reader's settings; Unmute All clears them.
        let suite = testDefaultsSuite("test.muting")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        assertTrue(settings.muteRules.isEmpty, "Nothing is muted by default")
        assertEqual(
            settings.muteSource("https://www.example.com/a"), "example.com", "Settings mute a host from a story link")
        assertEqual(settings.muteSource("example.com"), nil, "A muted host is not added twice")
        assertEqual(settings.muteTopic("Election"), "Election", "Settings mute a topic")
        assertEqual(AppSettings(defaults: defaults).muteRules, settings.muteRules, "Muting persists across launches")
        settings.unmuteTopic("Election")
        assertEqual(AppSettings(defaults: defaults).muteRules.topics, [], "Unmuting a topic is stored")
        settings.setTopicSet(aiSet, muted: true)
        assertEqual(AppSettings(defaults: defaults).muteRules.topicSets, [aiSet], "A switched-on set is stored")
        settings.setTopicSet(aiSet, muted: false)
        assertEqual(AppSettings(defaults: defaults).muteRules.topicSets, [], "Switching a set off is stored")
        settings.setTopicSet(aiSet, muted: true)
        settings.clearMuting()
        assertTrue(AppSettings(defaults: defaults).muteRules.isEmpty, "Unmute All clears the stored rules")

        // Muted stories never notify.
        settings.feedURLs = ["https://other.org/feed.xml"]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.muteSource("example.com")
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        var notified: [String] = []
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [stories[0], stories[3]], nil, nil) } },
            notifyBatch: { articles, _ in notified.append(contentsOf: articles.map(\.title)) })
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        assertEqual(notified, [stories[3].title], "Only unmuted new stories notify")
        assertEqual(manager.articles.count, 2, "Muted stories are still stored")
        manager.stopBackgroundWork()
    }

    static func testSmartBinders() async throws {
        print("  - Testing Dynamic Smart Binders (Compound Topic Rules #709)...")

        // 1. Pure rule-to-SQL translation with 100% parameterised queries (no string concatenation of user input)
        let complexBinder = SmartBinder(
            name: "Apple Silicon Watch",
            icon: "cpu",
            categories: ["Tech", "Business"],
            includeKeywords: ["apple", "silicon"],
            excludeKeywords: ["rumor", "leak"],
            publishers: ["Ars Technica", "The Verge"],
            matchAllKeywords: false
        )
        let (sql, params) = complexBinder.sqlCondition()

        // 100% Parameterized verification: SQL string must contain '?' and never raw user text
        for forbidden in ["apple", "silicon", "rumor", "leak", "Ars Technica", "The Verge", "Tech", "Business"] {
            assertFalse(
                sql.lowercased().contains(forbidden.lowercased()),
                "SQL must not concatenate user text '\(forbidden)'; found in: \(sql)"
            )
        }
        assertTrue(sql.contains("coalesce(ae.category, a.category) LIKE ?"), "Categories use parameterised LIKE")
        assertTrue(sql.contains("a.source LIKE ?"), "Publishers use parameterised LIKE")
        assertTrue(
            sql.contains("a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\'"),
            "Keywords use parameterised LIKE with ESCAPE")
        assertTrue(
            sql.contains("NOT (a.title LIKE ? ESCAPE '\\' OR coalesce(a.description, '') LIKE ? ESCAPE '\\')"),
            "Exclude keywords use parameterised NOT with ESCAPE")

        // Parameters match the expected formatted wildcards
        assertTrue(params.contains("%Tech%"), "Params contain category wildcard")
        assertTrue(params.contains("%Business%"), "Params contain category wildcard")
        assertTrue(params.contains("%apple%"), "Params contain include keyword wildcard")
        assertTrue(params.contains("%silicon%"), "Params contain include keyword wildcard")
        assertTrue(params.contains("%rumor%"), "Params contain exclude keyword wildcard")
        assertTrue(params.contains("%leak%"), "Params contain exclude keyword wildcard")

        // SQL Injection Attempt
        let maliciousBinder = SmartBinder(
            name: "Injection Test",
            includeKeywords: ["' OR '1'='1'; DROP TABLE articles; --"],
            excludeKeywords: ["'; DELETE FROM article_state; --"]
        )
        let (maliciousSQL, maliciousParams) = maliciousBinder.sqlCondition()
        assertFalse(maliciousSQL.contains("DROP TABLE"), "Malicious input must never be interpolated into SQL")
        assertFalse(maliciousSQL.contains("DELETE FROM"), "Malicious input must never be interpolated into SQL")
        assertTrue(
            maliciousParams.contains("%' OR '1'='1'; DROP TABLE articles; --%"), "Literal string passed as parameter")

        // Wildcard escaping: % and _ should be escaped with \ to prevent accidental wildcard expansion
        let wildcardBinder = SmartBinder(
            name: "Wildcard Test",
            includeKeywords: ["100% genuine", "foo_bar"]
        )
        let (wcSQL, wcParams) = wildcardBinder.sqlCondition()
        assertTrue(wcSQL.contains("ESCAPE '\\'"), "SQL LIKE clauses contain ESCAPE clause")
        assertTrue(wcParams.contains("%100\\% genuine%"), "Wildcard % is escaped in parameter")
        assertTrue(wcParams.contains("%foo\\_bar%"), "Wildcard _ is escaped in parameter")

        // 2. Compound include/exclude rules (in-memory matching)
        let artMatching = FeedArticle(
            title: "Apple introduces M4 Max Silicon",
            link: "https://arstechnica.com/apple-m4",
            guid: "sb-1",
            description: "New chip delivers record performance across all tasks",
            pubDate: Date(),
            source: "Ars Technica",
            category: "Tech"
        )
        let artExcluded = FeedArticle(
            title: "Apple announces M4 chip amid new leak",
            link: "https://arstechnica.com/apple-leak",
            guid: "sb-2",
            description: "New rumor claims supply issues in Taiwan",
            pubDate: Date(),
            source: "Ars Technica",
            category: "Tech"
        )
        let artWrongPublisher = FeedArticle(
            title: "Apple Silicon review",
            link: "https://wsj.com/apple-silicon",
            guid: "sb-3",
            description: "A fast Mac processor tested",
            pubDate: Date(),
            source: "Wall Street Journal",
            category: "Tech"
        )
        let artWrongCategory = FeedArticle(
            title: "Apple Silicon in restaurants",
            link: "https://arstechnica.com/apple-cooking",
            guid: "sb-4",
            description: "Kitchen management systems powered by silicon",
            pubDate: Date(),
            source: "Ars Technica",
            category: "Food"
        )

        assertTrue(complexBinder.matches(article: artMatching), "Article matching all compound rules must pass")
        assertFalse(
            complexBinder.matches(article: artExcluded),
            "Article matching include but containing exclude keyword must fail")
        assertFalse(complexBinder.matches(article: artWrongPublisher), "Article with non-matching publisher must fail")
        assertFalse(complexBinder.matches(article: artWrongCategory), "Article with non-matching category must fail")

        // Match all keywords mode
        let allKeywordsBinder = SmartBinder(
            name: "Strict Apple Silicon",
            includeKeywords: ["apple", "silicon"],
            matchAllKeywords: true
        )
        let artOnlyApple = FeedArticle(
            title: "Apple releases quarterly earnings report",
            link: "https://example.com/apple-earnings",
            guid: "sb-5",
            description: "Services revenue hit record high",
            pubDate: Date(),
            source: "Example",
            category: "Business"
        )
        assertTrue(
            allKeywordsBinder.matches(article: artMatching),
            "Article with both keywords matches under matchAllKeywords=true")
        assertFalse(
            allKeywordsBinder.matches(article: artOnlyApple),
            "Article with only one keyword fails under matchAllKeywords=true")

        // 3. Database query and Mute Rules honoured in Smart Binders
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()

        let dbStories = [
            FeedArticle(
                title: "Apple M4 Silicon review",
                link: "https://arstechnica.com/apple-m4-review",
                guid: "db-1",
                description: "Deep dive into performance",
                pubDate: Date(timeIntervalSince1970: 1_700_000_100),
                source: "Ars Technica",
                category: "Tech"
            ),
            FeedArticle(
                title: "Apple chip supply chain rumor",
                link: "https://arstechnica.com/apple-supply-rumor",
                guid: "db-2",
                description: "Unconfirmed reports from suppliers",
                pubDate: Date(timeIntervalSince1970: 1_700_000_090),
                source: "Ars Technica",
                category: "Tech"
            ),
            FeedArticle(
                title: "Apple Silicon developer tooling",
                link: "https://theverge.com/apple-tooling",
                guid: "db-3",
                description: "Xcode optimizations for M4",
                pubDate: Date(timeIntervalSince1970: 1_700_000_080),
                source: "The Verge",
                category: "Tech"
            ),
            FeedArticle(
                title: "Global monetary policy update",
                link: "https://bbc.com/economy",
                guid: "db-4",
                description: "Interest rate discussion",
                pubDate: Date(timeIntervalSince1970: 1_700_000_070),
                source: "BBC",
                category: "Business"
            ),
        ]
        try await db.upsertArticles(dbStories)

        let testBinder = SmartBinder(
            name: "Apple Silicon",
            categories: ["Tech"],
            includeKeywords: ["apple"],
            excludeKeywords: ["rumor"]
        )

        // Query without muting: db-1 and db-3 match, db-2 is excluded by rumor, db-4 is not Tech/no Apple
        let binderArticles = try await db.fetchArticles(smartBinder: testBinder)
        assertEqual(binderArticles.map(\.id), ["db-1", "db-3"], "Smart binder query returns matching articles")
        let binderTotals = try await db.listTotals(smartBinder: testBinder)
        assertEqual(binderTotals.stories, 2, "List totals reflects binder matching count")

        // SQL and in-memory matching must agree when every keyword is required.
        let strictBinder = SmartBinder(
            name: "Strict", includeKeywords: ["apple", "developer"], matchAllKeywords: true)
        let strictArticles = try await db.fetchArticles(smartBinder: strictBinder)
        assertEqual(strictArticles.map(\.id), ["db-3"], "matchAllKeywords requires every keyword in SQL")
        assertTrue(strictBinder.matches(article: dbStories[2]), "In-memory matching agrees for db-3")
        assertFalse(strictBinder.matches(article: dbStories[0]), "In-memory matching agrees for db-1")

        // U.S. Politics category uses ArticleSection matching semantics in SQL and in-memory
        let polStory = FeedArticle(
            title: "White House press briefing on new legislation",
            link: "https://example.com/us-politics-1",
            guid: "pol-1",
            description: "Administration officials discussed the bill",
            pubDate: Date(timeIntervalSince1970: 1_700_000_150),
            source: "Example News",
            category: "Politics"
        )
        let nonPolStory = FeedArticle(
            title: "Global Astronomy Conference Opens in Tokyo",
            link: "https://example.com/science-1",
            guid: "sci-1",
            description: "Researchers discuss deep space telescope discoveries",
            pubDate: Date(timeIntervalSince1970: 1_700_000_140),
            source: "Example News",
            category: "Science"
        )
        try await db.upsertArticles([polStory, nonPolStory])
        let usPolBinder = SmartBinder(name: "US Pol", categories: ["U.S. Politics"])
        let usPolArticles = try await db.fetchArticles(smartBinder: usPolBinder)
        assertTrue(
            usPolArticles.contains { $0.id == "pol-1" },
            "U.S. Politics binder matches classified Politics story in SQL")
        assertFalse(
            usPolArticles.contains { $0.id == "sci-1" },
            "U.S. Politics binder excludes non-politics story in SQL")
        assertTrue(
            usPolBinder.matches(article: polStory),
            "U.S. Politics matches in-memory for classified Politics story")
        assertFalse(
            usPolBinder.matches(article: nonPolStory),
            "U.S. Politics excludes non-politics story in-memory")

        // Case-insensitivity: "u.s. politics" also uses ArticleSection matching
        let lowerUsPolBinder = SmartBinder(name: "US Pol Lower", categories: ["u.s. politics"])
        let lowerUsPolArticles = try await db.fetchArticles(smartBinder: lowerUsPolBinder)
        assertTrue(
            lowerUsPolArticles.contains { $0.id == "pol-1" },
            "Case-insensitive u.s. politics binder matches in SQL")
        assertTrue(
            lowerUsPolBinder.matches(article: polStory),
            "Case-insensitive u.s. politics binder matches in-memory")

        // Mute rules strictly honoured: mute theverge.com
        var binderMuting = MuteRules(sources: ["theverge.com"])
        let mutedArticles = try await db.fetchArticles(smartBinder: testBinder, muting: binderMuting)
        assertEqual(mutedArticles.map(\.id), ["db-1"], "Muted publisher theverge.com is excluded from smart binder")
        let mutedCount = try await db.mutedArticleCount(smartBinder: testBinder, muting: binderMuting)
        assertEqual(mutedCount, 1, "Muted count reports exactly 1 story hidden by muting")

        // Rule edits produce distinct cache entries without requiring database writes
        var editedBinder = testBinder
        editedBinder.includeKeywords = ["nonexistent"]
        let editedMutedCount = try await db.mutedArticleCount(smartBinder: editedBinder, muting: binderMuting)
        assertEqual(editedMutedCount, 0, "Edited binder rules use a distinct cache entry")

        // Mute by topic: mute "review"
        binderMuting.addTopic("review")
        let topicMutedArticles = try await db.fetchArticles(smartBinder: testBinder, muting: binderMuting)
        assertTrue(topicMutedArticles.isEmpty, "Topic muting eliminates remaining story with 'review'")
        let doubleMutedCount = try await db.mutedArticleCount(smartBinder: testBinder, muting: binderMuting)
        assertEqual(doubleMutedCount, 2, "Both stories now counted as muted under smart binder")

        // Wildcard escaping in live database queries
        let wcArticles = [
            FeedArticle(
                title: "100% Genuine Silicon",
                link: "https://example.com/genuine",
                guid: "wc-1",
                description: "Authentic hardware",
                pubDate: Date(timeIntervalSince1970: 1_700_000_200),
                source: "Example",
                category: "Tech"
            ),
            FeedArticle(
                title: "10000 Genuine Silicon",
                link: "https://example.com/not-percent",
                guid: "wc-2",
                description: "Different number",
                pubDate: Date(timeIntervalSince1970: 1_700_000_190),
                source: "Example",
                category: "Tech"
            ),
        ]
        try await db.upsertArticles(wcArticles)
        let exactPercentBinder = SmartBinder(
            name: "Percent Test",
            includeKeywords: ["100%"]
        )
        let percentMatches = try await db.fetchArticles(smartBinder: exactPercentBinder)
        assertEqual(percentMatches.map(\.id), ["wc-1"], "Escaped % matches only literal %, not arbitrary digits")

        await db.close()

        // 4. Persistence round trip and settings backup/restore
        let suite = testDefaultsSuite("test.smartbinders")
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }

        try await MainActor.run {
            let settings = AppSettings(defaults: testDefaults)
            assertEqual(settings.smartBinders.count, 0, "Initially zero smart binders")

            let persistentBinder = SmartBinder(
                id: UUID(),
                name: "Custom Defense & Tech",
                icon: "cube",
                categories: ["Tech", "World"],
                includeKeywords: ["radar", "satellite"],
                excludeKeywords: ["speculation"],
                publishers: ["Defense News"]
            )
            settings.addSmartBinder(persistentBinder)
            assertEqual(settings.smartBinders.count, 1, "Binder added to settings")
            assertEqual(
                settings.smartBinder(id: persistentBinder.id)?.name, "Custom Defense & Tech",
                "Binder lookup by ID works")
            assertEqual(
                settings.smartBinder(forTag: persistentBinder.sidebarTag)?.icon, "cube", "Binder lookup by tag works")

            // Update binder
            var modifiedBinder = persistentBinder
            modifiedBinder.name = "Aerospace & Tech"
            assertTrue(
                modifiedBinder.hashValue != persistentBinder.hashValue,
                "Modified binder produces distinct hash value for view cache invalidation")
            settings.updateSmartBinder(modifiedBinder)
            assertEqual(
                settings.smartBinder(id: persistentBinder.id)?.name, "Aerospace & Tech", "Binder update persists")

            // Backup settings
            let backupData = try AppSettings.backupSettings(from: testDefaults)

            // Clear defaults suite and verify restoration
            testDefaults.removePersistentDomain(forName: suite)
            try AppSettings.restoreSettings(backupData, to: testDefaults)

            let restoredSettings = AppSettings(defaults: testDefaults)
            assertEqual(restoredSettings.smartBinders.count, 1, "Smart binders cleanly restored from backup")
            let restoredBinder = restoredSettings.smartBinders.first
            assertEqual(restoredBinder?.id, persistentBinder.id, "Restored binder preserves ID")
            assertEqual(restoredBinder?.name, "Aerospace & Tech", "Restored binder preserves updated name")
            assertEqual(restoredBinder?.icon, "cube", "Restored binder preserves icon")
            assertEqual(restoredBinder?.categories, ["Tech", "World"], "Restored binder preserves categories")
            assertEqual(
                restoredBinder?.includeKeywords, ["radar", "satellite"], "Restored binder preserves includeKeywords")
            assertEqual(restoredBinder?.excludeKeywords, ["speculation"], "Restored binder preserves excludeKeywords")
            assertEqual(restoredBinder?.publishers, ["Defense News"], "Restored binder preserves publishers")

            // Remove binder
            restoredSettings.removeSmartBinder(persistentBinder)
            assertEqual(restoredSettings.smartBinders.count, 0, "Binder removal persists cleanly")

            // SmartBinder tags and ID extraction
            assertTrue(SmartBinder.isBinderTag(persistentBinder.sidebarTag), "isBinderTag recognizes valid tag")
            assertFalse(SmartBinder.isBinderTag("category:all"), "isBinderTag rejects other tags")
            assertEqual(
                SmartBinder.binderID(fromTag: persistentBinder.sidebarTag), persistentBinder.id,
                "binderID parses valid tag")
            assertEqual(
                SmartBinder.binderID(fromTag: "category:all"), nil, "binderID returns nil for non-binder tag")

            // SmartBinderSheet helpers and draft builder
            assertEqual(
                SmartBinderSheet.parseCommaSeparated("apple, silicon, m4"), ["apple", "silicon", "m4"],
                "Comma-separated parsing trims and filters")
            assertEqual(
                SmartBinderSheet.parseCommaSeparated("   "), [], "Blank comma-separated string yields empty list")

            let newDraft = SmartBinderSheet.Draft(
                name: "  Apple Silicon  ",
                icon: "cpu",
                categories: ["Tech", "Science"],
                includeKeywordsText: "m4, pro",
                excludeKeywordsText: "rumor",
                publishersText: "The Verge",
                matchAllKeywords: true
            )
            let createdBinder = SmartBinderSheet.buildBinder(from: newDraft)
            assertEqual(createdBinder.name, "Apple Silicon", "buildBinder trims name")
            assertEqual(createdBinder.icon, "cpu", "buildBinder sets icon")
            assertEqual(createdBinder.categories, ["Science", "Tech"], "buildBinder sorts categories")
            assertEqual(createdBinder.includeKeywords, ["m4", "pro"], "buildBinder parses includes")
            assertEqual(createdBinder.excludeKeywords, ["rumor"], "buildBinder parses excludes")
            assertEqual(createdBinder.publishers, ["The Verge"], "buildBinder parses publishers")
            assertTrue(createdBinder.matchAllKeywords, "buildBinder sets matchAllKeywords")

            let editDraft = SmartBinderSheet.Draft(
                existing: createdBinder,
                name: "Updated Silicon",
                icon: "folder",
                categories: ["Tech"],
                includeKeywordsText: "",
                excludeKeywordsText: "",
                publishersText: "",
                matchAllKeywords: false
            )
            let updatedBinder = SmartBinderSheet.buildBinder(from: editDraft)
            assertEqual(updatedBinder.id, createdBinder.id, "Updating preserves binder ID")
            assertEqual(updatedBinder.name, "Updated Silicon", "Updating sets new name")
            assertEqual(updatedBinder.icon, "folder", "Updating sets new icon")
            assertFalse(updatedBinder.matchAllKeywords, "Updating clears matchAllKeywords")

            // Exercise SmartBinderSheet view body in creation and edit modes
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }

            let sheetNew = SmartBinderSheet()
            let hostNew = NSHostingView(rootView: sheetNew.environmentObject(settings))
            window.contentView = hostNew
            // Laid out in a window that is never ordered on screen: the headless suite opens none (#991).
            hostNew.layoutSubtreeIfNeeded()
            _ = hostNew.fittingSize

            let sheetEdit = SmartBinderSheet(binder: createdBinder)
            let hostEdit = NSHostingView(rootView: sheetEdit.environmentObject(settings))
            window.contentView = hostEdit
            hostEdit.layoutSubtreeIfNeeded()
            _ = hostEdit.fittingSize
        }
    }

    static func testNavigationCommands() async {
        print("  - Testing Keyboard Navigation Offset Logic...")

        let sampleArticles = (0..<5).map { i in
            FeedArticle(
                title: "Article \(i)",
                link: "https://example.com/article-\(i)",
                guid: "guid-\(i)",
                description: "Description \(i)",
                pubDate: Date(timeIntervalSince1970: Double(1000 + i * 100)),
                source: "Source"
            )
        }

        let currentID = "guid-2"
        let currentIndex = sampleArticles.firstIndex(where: { $0.id == currentID })!
        assertEqual(currentIndex, 2, "Current index should be 2")

        let nextIndex = min(currentIndex + 1, sampleArticles.count - 1)
        assertEqual(nextIndex, 3, "Next index should be 3")
        assertEqual(sampleArticles[nextIndex].id, "guid-3", "Next article should be guid-3")

        let prevIndex = max(currentIndex - 1, 0)
        assertEqual(prevIndex, 1, "Previous index should be 1")
        assertEqual(sampleArticles[prevIndex].id, "guid-1", "Previous article should be guid-1")
    }

    static func testStoryExport() async throws {
        print("  - Testing saved-story and history export (#565)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func noBOM(_ data: Data) -> Bool { !data.starts(with: [0xEF, 0xBB, 0xBF]) }
        for saved in [true, false] {
            let entries = try await db.exportedStories(saved: saved)
            assertTrue(entries.isEmpty, "An empty library exports an empty list")
            let json = try StoryExport.json(entries)
            assertTrue(noBOM(json), "JSON export is UTF-8 without a byte order mark")
            assertTrue((try JSONSerialization.jsonObject(with: json) as? [Any])?.isEmpty == true, "Empty JSON list")
            let markdown = String(decoding: StoryExport.markdown(entries, title: "History"), as: UTF8.self)
            assertEqual(markdown, "# History\n\n", "Empty Markdown export is the heading alone")
        }
        let cafe = FeedArticle(
            title: "Café [live] reopens", link: "https://example.com/news/cafe", guid: "cafe",
            description: "Report", pubDate: Date(timeIntervalSince1970: 1_790_000_000), source: "Example News\nWorld")
        let undated = FeedArticle(
            title: "Undated item", link: "https://example.com/news/undated", guid: "undated", description: "Report",
            pubDate: DateParser.unknownDate, source: "Example News")
        try await db.upsertArticles([cafe, undated], feedUrl: "https://example.com/feed")
        try await db.setSaved(articleId: cafe.id, isSaved: true)
        try await db.markRead(articleId: undated.id, isRead: true)
        try await db.markRead(articleId: cafe.id, isRead: true)
        // A reconciled duplicate, saved and read most recently, is never exported; exact times decide the order.
        let copy = FeedArticle(
            title: "Café [live] reopens (copy)", link: "https://example.com/news/cafe-copy", guid: "cafe-copy",
            description: "Report", pubDate: cafe.pubDate, source: "Example News")
        try await db.upsertArticles([copy], feedUrl: "https://example.com/feed")
        try await db.setSaved(articleId: copy.id, isSaved: true)
        try await db.markRead(articleId: copy.id, isRead: true)
        let stored = Dictionary(
            try await db.fetchArticles(limit: nil, includingOriginals: true).map { ($0.title, $0.id) },
            uniquingKeysWith: { first, _ in first })
        let cafeID = stored[cafe.title]!
        let undatedID = stored[undated.title]!
        let copyID = stored[copy.title]!
        try await db.executeSimple(
            """
            UPDATE article_state SET saved_at = 2000, read_at = 3000 WHERE article_id = '\(cafeID)';
            UPDATE article_state SET read_at = 3500 WHERE article_id = '\(undatedID)';
            UPDATE article_state SET saved_at = 9000, read_at = 9000 WHERE article_id = '\(copyID)';
            INSERT INTO article_reconciliations (duplicate_id, survivor_id, canonical_url, fingerprint)
                VALUES ('\(copyID)', '\(cafeID)', '\(cafe.link)', 'test');
            """)

        let saved = try await db.exportedStories(saved: true)
        assertEqual(saved.map(\.title), [cafe.title], "Only saved stories are exported as saved")
        assertEqual(saved.first?.publisher, "Example News", "The publisher is the feed's first title line")
        assertEqual(saved.first?.published, cafe.pubDate, "The publication date is exported")
        assertEqual(saved.first?.savedAt, Date(timeIntervalSince1970: 2000), "Saved export carries the exact save time")
        assertTrue(saved.first?.readAt == nil, "Saved export names no read time")
        let history = try await db.exportedStories(saved: false)
        assertEqual(history.map(\.title), [undated.title, cafe.title], "History lists every read story, newest first")
        assertEqual(
            history.map(\.readAt), [Date(timeIntervalSince1970: 3500), Date(timeIntervalSince1970: 3000)],
            "History carries the exact read times")
        assertTrue(history.allSatisfy { $0.savedAt == nil }, "History names no save time")
        assertTrue(history.contains { $0.title == undated.title && $0.published == nil }, "Unknown dates are left out")

        let json = try StoryExport.json(saved)
        assertTrue(noBOM(json), "JSON export is UTF-8 without a byte order mark")
        let object = (try JSONSerialization.jsonObject(with: json) as? [[String: Any]])?.first
        assertEqual(object?["title"] as? String, "Café [live] reopens", "Non-ASCII titles round-trip as UTF-8")
        assertEqual(object?["url"] as? String, cafe.link, "The story URL is exported unescaped")
        assertTrue(object?["savedAt"] is String && object?["readAt"] == nil, "Saved JSON names the save time only")
        assertEqual(object?["published"] as? String, "2026-09-21T14:13:20Z", "Dates are ISO 8601 in UTC")
        let markdownData = StoryExport.markdown(history, title: "History")
        assertTrue(noBOM(markdownData), "Markdown export is UTF-8 without a byte order mark")
        let markdown = String(decoding: markdownData, as: UTF8.self)
        assertTrue(markdown.hasPrefix("# History\n\n- "), "Markdown export is a heading and a list")
        let cafeLine = "- [Café \\[live\\] reopens](<https://example.com/news/cafe>) · Example News · published "
        assertTrue(markdown.contains(cafeLine), "Markdown escapes brackets in titles and links the story")
        let undatedLine = "- [Undated item](<https://example.com/news/undated>) · Example News · read "
        assertTrue(markdown.contains(undatedLine), "Undated stories list the read time only")
        let broken = StoryExportEntry(
            title: "Line one\r\nline two\rthree\nfour", publisher: "P", url: "https://example.com/x", published: nil)
        let brokenMarkdown = String(decoding: StoryExport.markdown([broken], title: "History"), as: UTF8.self)
        assertEqual(
            brokenMarkdown, "# History\n\n- [Line one line two three four](<https://example.com/x>) · P\n",
            "Line breaks in a title stay inside one list item")
    }

    /// Opt-in live measurement on a SQLite backup under the temporary directory, never the installed library.
    static func measureLiveCuration(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "LiveCuration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Use a library backup and output under /private/tmp"])
        }
        let db = DatabaseEngine(path: url.path)
        try await db.open()
        let clock = Date()
        let activeSince = clock.addingTimeInterval(-EventCandidatePolicy.standard.activeEventLifetime)
        let all = try await db.fetchArticles(limit: nil)
        let active = all.filter { $0.pubDate >= activeSince }
        var ratings: [[String: String]] = []
        for pass in 1...100 {
            let before = ratings.count
            let pending = try await db.pendingImportanceRows(activeSince: activeSince, limit: 60)
            if pending.isEmpty { break }
            for row in pending {
                try Task.checkCancellation()
                guard let importance = await OnDeviceImportanceJudge.shared.rate(OnDeviceImportanceJudge.report(row))
                else {
                    continue
                }
                if try await db.recordImportance(
                    row.id, importance, at: clock, expectedTitle: row.title, expectedDescription: row.description)
                {
                    ratings.append([
                        "id": row.id, "title": row.title, "summary": row.description,
                        "importance": String(describing: importance),
                    ])
                }
            }
            print("CURATION_PASS \(pass) rated=\(ratings.count)")
            fflush(stdout)
            if ratings.count == before { break }
        }
        let visible = Set(try await db.fetchArticles(limit: nil, hidingWaitingStories: true).map(\.id))
        let hiddenMajor = ratings.filter { $0["importance"] == "major" && !visible.contains($0["id"] ?? "") }.count
        assertEqual(hiddenMajor, 0, "No rated major story is hidden")
        // #309: every minor-rated story in the window, whether it waits, and one sampled re-rate that bypasses the cache.
        // The review sheet built from this file hides the waiting flag and the re-rate from the labeller.
        let minorRows = try await db.ratedImportanceRows(level: .minor, activeSince: activeSince)
        let shownMinor = try await db.notificationStoryIDs(minorRows.map(\.id))
        var review: [[String: String]] = []
        for row in minorRows {
            try Task.checkCancellation()
            let rerate = await OnDeviceImportanceJudge.modelRating(OnDeviceImportanceJudge.report(row), sampled: true)
            review.append([
                "id": row.id, "title": row.title, "summary": row.description, "source": row.source,
                "waiting": shownMinor.contains(row.id) ? "no" : "yes",
                "rerate": rerate.map { String(describing: $0) } ?? "none",
            ])
        }
        print("CURATION_REVIEW minor=\(review.count) waiting=\(review.filter { $0["waiting"] == "yes" }.count)")
        let report: [String: Int] = [
            "library": all.count, "active": active.count, "rated": ratings.count,
            "major": ratings.filter { $0["importance"] == "major" }.count,
            "notable": ratings.filter { $0["importance"] == "notable" }.count,
            "minor": ratings.filter { $0["importance"] == "minor" }.count,
            "waiting": try await db.waitingStoryCount(), "hiddenMajor": hiddenMajor,
            "unrated": try await db.pendingImportanceRows(activeSince: activeSince, limit: 10000).count,
        ]
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ratings).write(to: directory.appendingPathComponent("ratings-private.json"))
        try encoder.encode(review).write(to: directory.appendingPathComponent("minor-review-private.json"))
        try encoder.encode(report).write(to: directory.appendingPathComponent("curation.json"))
        print("CURATION_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        await db.close()
    }

    /// Opt-in protected publisher requests on an already rated, temporary library backup.
    /// How often the priority rule (#665) fires on a library backup: for each event, the first visible story, created in
    /// the last 14 days, that qualifies with the publishers its event had when that story arrived. Read-only.
    static func measureLivePriority(path: String, output: String) throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "LivePriority", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a temporary library backup"]
            )
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "LivePriority", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(path)"])
        }
        defer { sqlite3_close(connection) }
        let now =
            ProcessInfo.processInfo.environment["NEWS_PRIORITY_NOW"].flatMap(TimeInterval.init)
            ?? Date().timeIntervalSince1970
        let query = """
            SELECT a.id, a.title, coalesce(a.description, ''), a.created_at, m.event_id,
                (SELECT count(DISTINCT b.source) FROM event_members n JOIN articles b ON b.id = n.article_id
                 WHERE n.event_id = m.event_id AND b.created_at <= a.created_at)
            FROM articles a JOIN event_members m ON m.article_id = a.id
            WHERE a.created_at >= ? AND a.created_at <= ?
                AND NOT EXISTS (SELECT 1 FROM article_reconciliations r WHERE r.duplicate_id = a.id)
            ORDER BY a.created_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "LivePriority", code: 3, userInfo: [NSLocalizedDescriptionKey: "Query failed"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now - 14 * 86400)
        sqlite3_bind_double(statement, 2, now)
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var first: [String: (day: String, title: String, score: Double, publishers: Int)] = [:]
        var stories = 0
        var days = Set<String>()
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(statement) == SQLITE_ROW {
            stories += 1
            let created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            days.insert(dayFormat.string(from: created))
            let event = text(4)
            guard first[event] == nil else { continue }
            let title = text(1)
            let publishers = Int(sqlite3_column_int(statement, 5))
            let score = NotificationService.shared.computeImportance(title: title, description: text(2))
            if NotificationService.isPriority(title: title, score: score, publishers: publishers) {
                first[event] = (dayFormat.string(from: created), title, score, publishers)
            }
        }
        var lines = [
            "Priority keys (#665) over 14 days: \(first.count), from \(stories) clustered stories on \(days.count) days with ingestion"
        ]
        for day in days.sorted() {
            let keys = first.values.filter { $0.day == day }.sorted { $0.score > $1.score }
            lines.append("\(day): \(keys.count)")
            for key in keys {
                lines.append("  - \(String(format: "%.2f", key.score)), \(key.publishers) publishers: \(key.title)")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }

    static func measureLiveImages(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(
                domain: "LiveImages", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a temporary library backup"])
        }
        let db = DatabaseEngine(path: url.path)
        try await db.open()
        // NEWS_IMAGES_NOW (seconds since 1970) repeats an earlier measurement on the same 72-hour denominator (#312).
        let clock =
            ProcessInfo.processInfo.environment["NEWS_IMAGES_NOW"].flatMap(TimeInterval.init).map(
                Date.init(timeIntervalSince1970:)) ?? Date()
        var placeholders: [[String: String]] = []
        func coverage() async throws -> (cards: Int, pictured: Int) {
            let articles = try await db.fetchArticles(
                limit: nil, publicationWindow: clock.addingTimeInterval(-72 * 3600)...clock, hidingWaitingStories: true)
            let summaries = try await db.eventFeedSummaries(forArticles: articles.map(\.id))
            let entries = EventFeedGrouping.entries(for: articles, events: summaries, mode: .events)
            var pictured = 0
            placeholders = []
            let pending = Set(
                try await db.imagelessStoryRows(
                    activeSince: clock.addingTimeInterval(-EventCandidatePolicy.standard.activeEventLifetime),
                    limit: 2000
                ).map(\.id))
            for entry in entries {
                let members: [FeedArticle]
                switch entry {
                case .article(let article): members = [article]
                case .event(let summary, _, _):
                    members = try await db.fetchArticles(limit: nil, eventID: summary.eventID)
                }
                if FeedArticle.bestCardImage(in: members) != nil {
                    pictured += 1
                    continue
                }
                // Private: which cards keep the placeholder, and whether their pages were looked up.
                let looked = try await db.storyImages(for: members.map(\.id))
                for member in members {
                    let checked =
                        pending.contains(member.id)
                        ? "not looked up" : looked[member.id] == nil ? "looked up, none" : "found"
                    placeholders.append([
                        "card": members.count > 1 ? "event" : "single", "members": String(members.count),
                        "link": member.link, "lookup": checked,
                    ])
                }
            }
            return (entries.count, pictured)
        }
        let before = try await coverage()
        let placeholdersBefore = placeholders
        var checks = 0
        var found = 0
        for pass in 1...10 {
            let report = try await StoryCurator.run(
                in: db, imageFinder: .publisherPages, now: clock)
            checks += report.imagesChecked
            found += report.imagesFound
            print("IMAGE_PASS \(pass) checked=\(report.imagesChecked) found=\(report.imagesFound)")
            fflush(stdout)
            if report.imagesChecked == 0 { break }
        }
        let after = try await coverage()
        let images = try await db.storyImages(for: try await db.fetchArticles(limit: nil).map(\.id))
        var decoded = 0
        var failed = 0
        for link in Set(images.values) {
            if let url = URL(string: link), (try? await SecureHTTPClient.shared.fetchReaderImage(from: url)) != nil {
                decoded += 1
            } else {
                failed += 1
            }
        }
        let report = [
            "cardsBefore": before.cards, "picturedBefore": before.pictured,
            "cardsAfter": after.cards, "picturedAfter": after.pictured, "checks": checks, "imagesFound": found,
            "pageImagesDecoded": decoded, "pageImagesFailed": failed,
        ]
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("images.json"))
        try JSONSerialization.data(
            withJSONObject: ["before": placeholdersBefore, "after": placeholders],
            options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: directory.appendingPathComponent("placeholders-private.json"))
        print("IMAGE_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        await db.close()
    }

    /// Opt-in #314 measurement on a copied library: every event's related-story links, each mixed with a hard near-miss
    /// control (an earlier candidate sharing a person, organization or place that the rule rejected), plus
    /// `near-misses-private.json`: up to 25 rejected candidates per stage for a recall read. Private text stays in the
    /// temporary audit directory; `script/evaluation/relation_review.py` builds the blind sheet and the report.
    static func measureLiveRelations(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(domain: "LiveRelations", code: 1)
        }
        let db = DatabaseEngine(path: url.path)
        try await db.open()
        var report: [String: Int] = ["eventsWithLinks": 0, "links": 0, "controls": 0]
        // `NEWS_RELATED_RECLUSTER=1` first runs the production clustering pass on the copy, with the clock at its last
        // refresh, so an older library gets the events the current matcher would build.
        if ProcessInfo.processInfo.environment["NEWS_RELATED_RECLUSTER"] == "1",
            let newest = try await db.fetchArticles(limit: nil).map(\.pubDate).max()
        {
            var converged = false
            for pass in 1...5 where !converged {
                let clustering = try await EventClusterer.run(in: db, now: newest.addingTimeInterval(3600))
                report["reclusterPasses"] = pass
                report["reclusterChangedEvents", default: 0] += clustering.changedEvents.count
                converged = clustering.changedEvents.isEmpty
            }
            // A pass that still changes events leaves a partial re-cluster; measuring it would mislead.
            guard converged else {
                await db.close()
                throw NSError(
                    domain: "LiveRelations", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Re-clustering still changed events after five passes"])
            }
        }
        let articles = try await db.fetchArticles(limit: nil)
        let events = try await db.eventFeedSummaries(forArticles: articles.map(\.id))
        report["events"] = events.count
        struct Pair {
            let kind: String
            let earlierID: String
            let laterID: String
            let earlier: [EventMatchRow]
            let later: [EventMatchRow]
        }
        var pairs: [Pair] = []
        // Rejected candidates by stage, so a recall sample can show which condition loses real developing stories.
        var nearMisses: [Pair] = []
        for event in events {
            let snapshot = try await db.relatedStoryEventRows(eventID: event.eventID)
            let common = try await EventStoryRelation.commonActors(of: snapshot.target, in: db)
            let links = try EventStoryRelation.links(
                target: snapshot.target, candidates: snapshot.candidates, commonActors: common)
            guard let start = snapshot.target.map(\.date).min() else { continue }
            report["linksPerEvent_\(links.count)", default: 0] += 1
            let linked = Set(links.map(\.eventID))
            if !links.isEmpty { report["eventsWithLinks", default: 0] += 1 }
            for candidate in snapshot.candidates where linked.contains(candidate.id) {
                pairs.append(
                    Pair(
                        kind: "link", earlierID: candidate.id, laterID: event.eventID, earlier: candidate.members,
                        later: snapshot.target))
            }
            let later = snapshot.target.map {
                EventFeatures(title: $0.title, description: $0.description, date: $0.date)
            }
            // Candidates the window rule skips before any pair is compared, and how many of them would link on their
            // earlier, in-window members alone.
            for candidate in snapshot.candidates where !candidate.members.isEmpty {
                let inWindow = candidate.members.filter {
                    $0.date < start && start.timeIntervalSince($0.date) <= EventStoryRelation.window
                }
                guard inWindow.count < candidate.members.count else { continue }
                let stage =
                    candidate.members.contains { $0.date >= start } ? "continuesAfterStart" : "olderThanWindow"
                report["candidateStage_\(stage)", default: 0] += 1
                nearMisses.append(
                    Pair(
                        kind: stage, earlierID: candidate.id, laterID: event.eventID, earlier: candidate.members,
                        later: snapshot.target))
                if !inWindow.isEmpty,
                    try !EventStoryRelation.links(
                        target: snapshot.target, candidates: [(candidate.id, inWindow)], commonActors: common
                    ).isEmpty
                {
                    report["windowBlocked_\(stage)_wouldLink", default: 0] += 1
                }
            }
            // Aggregate rejection stages over earlier candidates within the window: the first condition no pair meets.
            for candidate in snapshot.candidates
            where !candidate.members.isEmpty
                && candidate.members.allSatisfy({
                    $0.date < start && start.timeIntervalSince($0.date) <= EventStoryRelation.window
                })
            {
                let earlier = candidate.members.map {
                    EventFeatures(title: $0.title, description: $0.description, date: $0.date)
                }
                let pairs = earlier.flatMap { e in later.map { (e, $0) } }
                let stage =
                    if !pairs.contains(where: {
                        !$0.people.isDisjoint(with: $1.people)
                            || !$0.organizations.isDisjoint(with: $1.organizations)
                    }) {
                        earlier.allSatisfy { $0.people.isEmpty && $0.organizations.isEmpty }
                            || later.allSatisfy { $0.people.isEmpty && $0.organizations.isEmpty }
                            ? "noActorOnOneSide" : "differentActors"
                    } else if !pairs.contains(where: { !$0.places.isDisjoint(with: $1.places) }) {
                        "noSharedPlace"
                    } else if !pairs.contains(where: { EventStoryRelation.supports($0, $1, commonActors: common) }) {
                        "noPairMeetsAll"
                    } else if linked.contains(candidate.id) { "linked" } else { "belowTwoThirdsSupport" }
                report["candidateStage_\(stage)", default: 0] += 1
                if stage != "linked" {
                    nearMisses.append(
                        Pair(
                            kind: stage, earlierID: candidate.id, laterID: event.eventID, earlier: candidate.members,
                            later: snapshot.target))
                }
            }
            // The hardest rejected candidate: earlier, within the window, sharing an actor or a local place.
            let control = snapshot.candidates.first { candidate in
                !linked.contains(candidate.id) && !candidate.members.isEmpty
                    && candidate.members.allSatisfy {
                        $0.date < start && start.timeIntervalSince($0.date) <= EventStoryRelation.window
                    }
                    && candidate.members.contains { row in
                        let earlier = EventFeatures(title: row.title, description: row.description, date: row.date)
                        return later.contains {
                            !earlier.people.isDisjoint(with: $0.people)
                                || !earlier.organizations.isDisjoint(with: $0.organizations)
                                || !earlier.localPlaces.isDisjoint(with: $0.localPlaces)
                        }
                    }
            }
            if !links.isEmpty, let control {
                pairs.append(
                    Pair(
                        kind: "control", earlierID: control.id, laterID: event.eventID, earlier: control.members,
                        later: snapshot.target))
            }
        }
        report["links"] = pairs.filter { $0.kind == "link" }.count
        report["controls"] = pairs.filter { $0.kind == "control" }.count
        func describe(_ rows: [EventMatchRow]) -> (titles: String, summary: String, first: Date) {
            let titles = rows.prefix(3).map { "\($0.title) (\($0.source))" }.joined(separator: " | ")
            return (titles, String((rows.first?.description ?? "").prefix(300)), rows.map(\.date).min() ?? .distantPast)
        }
        func row(_ pair: Pair) -> (String, [String: Any]) {
            let (earlier, later) = (describe(pair.earlier), describe(pair.later))
            let hash = ArticleIdentity.sha256Hex(pair.earlierID + ">" + pair.laterID)
            return (
                hash,
                [
                    "hash": hash, "kind": pair.kind,
                    "earlierEvent": pair.earlierID, "laterEvent": pair.laterID, "earlier": earlier.titles,
                    "earlier_summary": earlier.summary, "later": later.titles, "later_summary": later.summary,
                    "gap_hours": String(format: "%.1f", later.first.timeIntervalSince(earlier.first) / 3600),
                ]
            )
        }
        // Pairs sorted by a hash, so links and controls interleave; `relation_review.py sheet` hides their kind.
        let rows = pairs.map(row).sorted { $0.0 < $1.0 }.map(\.1)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("relations-private.json"), options: .withoutOverwriting)
        // Recall sample: up to 25 rejected candidates per stage, chosen by hash. `kind` names the rejecting stage.
        var perStage: [String: Int] = [:]
        var sample: [[String: Any]] = []
        for (_, fields) in nearMisses.map(row).sorted(by: { $0.0 < $1.0 }) {
            let stage = fields["kind"] as? String ?? ""
            guard perStage[stage, default: 0] < 25 else { continue }
            perStage[stage, default: 0] += 1
            sample.append(fields)
        }
        try JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("near-misses-private.json"), options: .withoutOverwriting)
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RELATION_REPORT \(String(decoding: encoded, as: UTF8.self))")
        await db.close()
    }

    /// Opt-in #308/#313 measurement on a copied library: labeled controls, model overviews for covered events until
    /// `NEWS_OVERVIEWS_TARGET` drafts (default 30) are accepted, and deterministic perspective coverage for every covered
    /// event in the window. `NEWS_OVERVIEWS_EXCLUDE` names an earlier output directory whose live events are skipped for
    /// generation. Private text stays in the temporary audit directory.
    @MainActor
    static func measureLiveOverviews(path: String, output: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/"), output.hasPrefix("/private/tmp/")
        else {
            throw NSError(domain: "LiveOverviews", code: 1)
        }
        let environment = ProcessInfo.processInfo.environment
        let target = environment["NEWS_OVERVIEWS_TARGET"].flatMap(Int.init) ?? 30
        let maxAttempts = environment["NEWS_OVERVIEWS_MAX_EVENTS"].flatMap(Int.init) ?? 120
        var excluded = Set<String>()
        if let previous = environment["NEWS_OVERVIEWS_EXCLUDE"] {
            let previousDirectory = URL(fileURLWithPath: previous)
            for file in try FileManager.default.contentsOfDirectory(atPath: previous)
            where file.hasPrefix("overview-private-live-") {
                let object =
                    try JSONSerialization.jsonObject(
                        with: Data(contentsOf: previousDirectory.appendingPathComponent(file))) as? [String: Any]
                if let id = (object?["document"] as? [String: Any])?["eventID"] as? String { excluded.insert(id) }
            }
            guard !excluded.isEmpty else { throw NSError(domain: "LiveOverviews", code: 2) }
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func runGitCommand(_ arguments: [String]) -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = arguments
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }

        func fileSHA256(_ fileURL: URL) -> String? {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        // Consistent snapshot of the input library, WAL included. The input opens read-only, so the
        // snapshot never checkpoints or otherwise writes the library it reads.
        let snapshotURL = directory.appendingPathComponent("library-snapshot.sqlite3")
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            try FileManager.default.removeItem(at: snapshotURL)
        }
        let inputFiles = [url, URL(fileURLWithPath: url.path + "-wal")]
        let inputHashes = inputFiles.map(fileSHA256)
        let sqliteProc = Process()
        sqliteProc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqliteProc.arguments = [
            url.absoluteString + "?mode=ro",
            "VACUUM INTO '\(snapshotURL.path.replacingOccurrences(of: "'", with: "''"))';",
        ]
        let sqliteErrPipe = Pipe()
        sqliteProc.standardError = sqliteErrPipe
        try sqliteProc.run()
        sqliteProc.waitUntilExit()
        guard sqliteProc.terminationStatus == 0, FileManager.default.fileExists(atPath: snapshotURL.path) else {
            let errData = sqliteErrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(decoding: errData, as: UTF8.self)
            throw NSError(
                domain: "LiveOverviews", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create SQLite snapshot: \(errMsg)"])
        }
        guard inputFiles.map(fileSHA256) == inputHashes else {
            throw NSError(
                domain: "LiveOverviews", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Snapshot changed the input library"])
        }
        guard let snapshotSHA256 = fileSHA256(snapshotURL) else {
            throw NSError(
                domain: "LiveOverviews", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compute snapshot SHA256"])
        }

        let runLibraryURL = directory.appendingPathComponent("run-library.sqlite3")
        if FileManager.default.fileExists(atPath: runLibraryURL.path) {
            try FileManager.default.removeItem(at: runLibraryURL)
        }
        try FileManager.default.copyItem(at: snapshotURL, to: runLibraryURL)

        let db = DatabaseEngine(path: runLibraryURL.path)
        try await db.open()

        let captureDate = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let captureTimeUTC = isoFormatter.string(from: captureDate)

        // NEWS_OVERVIEWS_NOW=<epoch> pins the 72 h window, so a rerun on the same copy measures the same events (#670).
        let selectionAnchor =
            environment["NEWS_OVERVIEWS_NOW"].flatMap { raw -> Date? in
                guard let seconds = TimeInterval(raw), seconds.isFinite else { return nil }
                return Date(timeIntervalSince1970: seconds)
            } ?? captureDate
        let selectionWindowStart = selectionAnchor.addingTimeInterval(-72 * 3600)
        let selectionWindowEnd = selectionAnchor
        let selectionAnchorUTC = isoFormatter.string(from: selectionAnchor)
        let selectionStartUTC = isoFormatter.string(from: selectionWindowStart)
        let selectionEndUTC = isoFormatter.string(from: selectionWindowEnd)

        let gitCommit = runGitCommand(["rev-parse", "HEAD"]) ?? "unknown"
        let gitBranch = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"]) ?? "unknown"
        let gitStatus = runGitCommand(["status", "--porcelain"]) ?? ""
        let dirtyFingerprint =
            gitStatus.isEmpty ? "clean" : "dirty (\(gitStatus.split(separator: "\n").count) uncommitted changes)"

        let preProvenance: [String: Any] = [
            "stage": "pre-generation",
            "run": environment["NEWS_OVERVIEWS_RUN_NAME"] ?? "live-overview-measurement",
            "issue": 308,
            "captureTimeUTC": captureTimeUTC,
            "gitCommit": gitCommit,
            "gitBranch": gitBranch,
            "dirtyCodeFingerprint": dirtyFingerprint,
            "selectionBoundsUTC": [
                "anchor": selectionAnchorUTC,
                "start": selectionStartUTC,
                "end": selectionEndUTC,
            ],
            "librarySnapshot": [
                "path": "library-snapshot.sqlite3",
                "sha256": snapshotSHA256,
                "sourcePath": url.path,
            ],
        ]
        let preProvenanceData = try JSONSerialization.data(
            withJSONObject: preProvenance, options: [.prettyPrinted, .sortedKeys])
        try preProvenanceData.write(to: directory.appendingPathComponent("provenance-pre-generation.json"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let active = try await db.fetchArticles(
            limit: nil, publicationWindow: selectionWindowStart...selectionWindowEnd, hidingWaitingStories: true)
        let events = try await db.eventFeedSummaries(forArticles: active.map(\.id)).filter { $0.sources.count > 1 }
            .sorted { $0.sources.count > $1.sources.count }
        var report = [
            "liveEvents": 0, "liveGenerated": 0, "liveClaims": 0, "liveUnsupported": 0, "liveCritical": 0,
            "controls": 0, "controlsGenerated": 0, "controlClaims": 0, "controlUnsupported": 0, "controlCritical": 0,
            "target": target, "excludedEvents": excluded.count,
        ]
        var coverage: [String: Int] = ["events": 0, "twoOrMore": 0, "one": 0, "none": 0]
        let measuredModel = NewsTextModel { prompt, tokens in
            let answer = try await NewsTextModel.onDevice.respond(prompt, tokens)
            let data = try JSONSerialization.data(
                withJSONObject: ["prompt": prompt, "answer": answer], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("model-private-\(UUID().uuidString).json"))
            return answer
        }
        /// Model failures by kind; refusals surface as FoundationModels guardrail or refusal errors.
        func failureKind(_ error: Error) -> String {
            if error is NewsTextModel.TemporarilyUnavailable { return "unavailable" }
            if let urlError = error as? URLError, urlError.code == .resourceUnavailable { return "unavailable" }
            let name = String(reflecting: error).lowercased()
            if name.contains("guardrail") || name.contains("refusal") { return "refusal" }
            return name.contains("context") ? "contextWindow" : "error"
        }
        /// The first step that left an event with fewer than two perspectives.
        func perspectiveGap(shown: Int, diagnosis: OverviewPerspectivesDiagnosis) -> String? {
            guard shown < 2 else { return nil }
            if diagnosis.passages == 0 { return "noPassages" }
            if diagnosis.candidates == 0 {
                return diagnosis.passagesWithUnmatchedSpeech > 0 ? "speechNotMatched" : "noAttributedSpeech"
            }
            if diagnosis.voices == 0 { return "onlyVagueSpeakers" }
            if diagnosis.perspectives < 2 { return diagnosis.rejections.isEmpty ? "singleVoice" : "validatorRejected" }
            return "fallbackOverview"
        }
        func measure(
            id: String, title: String, passages: [EvidencePassage], articles: [FeedArticle], live: Bool,
            membership: Int = 1, sources: Int = 0, perspectives: OverviewPerspectivesDiagnosis? = nil,
            evidence: [String: Any]? = nil
        ) async throws {
            let fallback = OverviewComposer.composeOverview(
                eventID: id, eventTitle: title,
                verifiedFacts: PassageFactExtractor.deterministicExtract(passages: passages), passages: passages,
                articles: articles, membershipVersion: membership)
            let start = Date()
            var document = fallback
            var outcome: OverviewModelOutcome?
            var failure: String?
            do {
                let composed = try await OverviewComposer.composeWithModelOutcome(
                    fallback: fallback, passages: passages, articles: articles, model: measuredModel)
                document = composed.document
                outcome = composed.outcome
            } catch is CancellationError { throw CancellationError() } catch { failure = failureKind(error) }
            let duration = Date().timeIntervalSince(start)
            let audit = OverviewQualityAuditor.auditOverview(document, passages: passages, duration: duration)
            let prefix = live ? "live" : "control"
            report[live ? "liveEvents" : "controls", default: 0] += 1
            report[live ? "liveGenerated" : "controlsGenerated", default: 0] += outcome?.result == .accepted ? 1 : 0
            report[live ? "liveClaims" : "controlClaims", default: 0] += audit.totalClaims
            report[live ? "liveUnsupported" : "controlUnsupported", default: 0] += audit.unsupportedClaims
            report[live ? "liveCritical" : "controlCritical", default: 0] += audit.totalCriticalErrors
            report["\(prefix)Outcome_\(failure ?? outcome?.result.rawValue ?? "unknown")", default: 0] += 1
            var privateJSON: [String: Any] = [
                "document": try JSONSerialization.jsonObject(with: encoder.encode(document)),
                "passages": try JSONSerialization.jsonObject(with: encoder.encode(passages)),
                "audit": try JSONSerialization.jsonObject(with: encoder.encode(audit)),
                "durationSeconds": duration, "sources": sources, "failure": failure.map { $0 as Any } ?? NSNull(),
                "outcome": try outcome.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) } ?? NSNull(),
            ]
            if let perspectives {
                privateJSON["perspectives"] = try JSONSerialization.jsonObject(with: encoder.encode(perspectives))
            }
            if let evidence { privateJSON["evidence"] = evidence }
            try JSONSerialization.data(withJSONObject: privateJSON, options: [.prettyPrinted, .sortedKeys]).write(
                to: directory.appendingPathComponent(
                    "overview-private-\(prefix)-\(report[live ? "liveEvents" : "controls"]!).json"))
            if live { _ = try await db.recordEventOverview(document) }
            print(
                "OVERVIEW_AUDIT \(prefix) result=\(failure ?? outcome?.result.rawValue ?? "unknown") seconds=\(String(format: "%.1f", duration)) claims=\(audit.totalClaims) critical=\(audit.totalCriticalErrors)"
            )
            fflush(stdout)
        }
        for sample in OverviewControlSample.standardBenchmark() {
            try await measure(
                id: sample.eventID, title: sample.title, passages: sample.passages, articles: sample.articles,
                live: false)
        }
        // `NEWS_OVERVIEWS_EXTRACT=1` (#308 step 2): before each measured event, the production coordinator stores
        // publisher text for its representatives, with its deadline and fetch limit, and the run records the step.
        let fetches = EvidenceFetchTally()
        let evidenceStore = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        let evidenceCoordinator: OverviewGenerationCoordinator? =
            environment["NEWS_OVERVIEWS_EXTRACT"] == "1"
            ? OverviewGenerationCoordinator(
                store: evidenceStore,
                extractText: { link in
                    let outcome = await ContentExtractionPipeline.shared.extractArticleWithIdentity(from: link).outcome
                    await fetches.add(Task.isCancelled ? "cutAtDeadline" : outcome.kindName)
                    return outcome
                }) : nil
        // Industry Impact (#670) on every covered event: the share that shows the section, and each entry with the full
        // text of the passages it cites, for the 30-event support review. Private, like the other outputs.
        var industryEntries: [[String: Any]] = []
        for event in events {
            var members = try await db.fetchArticles(limit: nil, eventID: event.eventID)
            guard let first = members.first else { continue }
            let measured =
                !excluded.contains(event.eventID) && report["liveGenerated", default: 0] < target
                && report["liveEvents", default: 0] < maxAttempts
            var evidence: [String: Any]?
            if measured, let evidenceCoordinator, Set(members.map { $0.source.lowercased() }).count > 1 {
                let before = await fetches.counts
                let lacking = Set(members.filter { !OverviewGenerationCoordinator.hasPublisherText($0) }.map(\.id))
                let start = Date()
                members = await evidenceCoordinator.articlesWithPublisherText(
                    members, excluding: [], store: evidenceStore)
                let after = await fetches.counts
                let outcomes = after.reduce(into: [String: Int]()) { result, entry in
                    let added = entry.value - (before[entry.key] ?? 0)
                    if added > 0 { result[entry.key] = added }
                }
                evidence = [
                    "seconds": Date().timeIntervalSince(start), "pageRequests": outcomes.values.reduce(0, +),
                    "storedTexts": members.filter {
                        lacking.contains($0.id) && OverviewGenerationCoordinator.hasPublisherText($0)
                    }.count,
                    "outcomes": outcomes,
                ]
            }
            let passages = OverviewPassageSelector().selectPassages(from: members, budget: OverviewTokenBudget())
                .passages
            // Every passage is citable, as in a synthesized overview, so the diagnosis sees what the extractor would.
            let citations = Dictionary(
                passages.map {
                    (
                        $0.id,
                        OverviewCitation(
                            id: $0.id, articleID: $0.articleID, passageID: $0.id,
                            passageFingerprint: $0.fingerprint, quote: String($0.text.prefix(200)))
                    )
                }, uniquingKeysWith: { kept, _ in kept })
            let diagnosis = OverviewPerspectivesExtractor.diagnosePerspectives(
                passages: passages, articles: members, existingCitations: citations)
            let composed = OverviewComposer.composeOverview(
                eventID: event.eventID, eventTitle: first.title,
                verifiedFacts: PassageFactExtractor.deterministicExtract(passages: passages), passages: passages,
                articles: members,
                membershipVersion: event.membershipVersion
            )
            let shown = composed.perspectives.count
            let impact = composed.evidenceSections?.industryImpact ?? []
            if !impact.isEmpty {
                coverage["industryImpactEvents", default: 0] += 1
                coverage["industryImpactEntries", default: 0] += impact.count
                let passageText = Dictionary(passages.map { ($0.id, $0.text) }, uniquingKeysWith: { kept, _ in kept })
                industryEntries.append([
                    "eventID": event.eventID, "eventTitle": first.title, "sources": event.sources.count,
                    "entries": impact.map { item in
                        [
                            "industry": item.industry, "implication": item.implication,
                            "citedPassages": item.citationIDs.compactMap { id in
                                composed.citations[id].map { passageText[$0.passageID] ?? $0.quote }
                            },
                        ] as [String: Any]
                    },
                ])
            }
            coverage["events", default: 0] += 1
            coverage[shown >= 2 ? "twoOrMore" : shown == 1 ? "one" : "none", default: 0] += 1
            if let gap = perspectiveGap(shown: shown, diagnosis: diagnosis) { coverage["gap_\(gap)", default: 0] += 1 }
            for (key, value) in [
                "passages": diagnosis.passages, "passagesWithCandidates": diagnosis.passagesWithCandidates,
                "passagesWithUnmatchedSpeech": diagnosis.passagesWithUnmatchedSpeech,
                "passagesWithTypographicQuotes": diagnosis.passagesWithTypographicQuotes,
                "candidates": diagnosis.candidates, "vagueCandidates": diagnosis.vagueCandidates,
                "voices": diagnosis.voices, "extractedPerspectives": diagnosis.perspectives,
            ] {
                coverage[key, default: 0] += value
            }
            for (rule, count) in diagnosis.rejections { coverage["rejected_\(rule)", default: 0] += count }
            guard measured else { continue }
            try await measure(
                id: event.eventID, title: first.title, passages: passages, articles: members, live: true,
                membership: event.membershipVersion, sources: event.sources.count, perspectives: diagnosis,
                evidence: evidence)
        }
        if let harsh = active.first(where: { ($0.title + $0.description).lowercased().contains("killed") }) {
            let analysis = try await ArticleAnalyzer(textModel: measuredModel).analyze(
                title: harsh.title, content: harsh.fullContent ?? harsh.description)
            report["sensitiveAnalysisUsedModel"] = analysis.modelIdentifier == "apple.foundation-model" ? 1 : 0
            try encoder.encode(analysis).write(to: directory.appendingPathComponent("analysis-private.json"))
        }
        try encoder.encode(report).write(to: directory.appendingPathComponent("overviews.json"))
        try encoder.encode(coverage).write(to: directory.appendingPathComponent("perspectives.json"))
        try JSONSerialization.data(withJSONObject: industryEntries, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("industry-impact-private.json"), options: .withoutOverwriting)
        print("OVERVIEW_REPORT \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        print("PERSPECTIVE_COVERAGE \(String(decoding: try encoder.encode(coverage), as: UTF8.self))")

        // Automatically record synchronous run receipt and provenance (#308/#313).
        var outputFiles: [String: [String: Any]] = [:]
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator.allObjects {
                guard !fileURL.hasDirectoryPath,
                    fileURL.lastPathComponent != "receipt.json",
                    fileURL.lastPathComponent != "run-library.sqlite3",
                    fileURL.lastPathComponent != "run-library.sqlite3-wal",
                    fileURL.lastPathComponent != "run-library.sqlite3-shm"
                else { continue }
                if let hash = fileSHA256(fileURL) {
                    outputFiles[fileURL.lastPathComponent] = [
                        "sha256": hash
                    ]
                }
            }
        }

        let receipt: [String: Any] = [
            "run": environment["NEWS_OVERVIEWS_RUN_NAME"] ?? "live-overview-measurement",
            "issue": 308,
            "receiptType": "live",
            "captureTimeUTC": captureTimeUTC,
            "gitCommit": gitCommit,
            "gitBranch": gitBranch,
            "dirtyCodeFingerprint": dirtyFingerprint,
            "selectionBoundsUTC": [
                "anchor": selectionAnchorUTC,
                "start": selectionStartUTC,
                "end": selectionEndUTC,
            ],
            "library": [
                "snapshotPath": "library-snapshot.sqlite3",
                "snapshotSHA256": snapshotSHA256,
                "sourcePath": url.path,
                "articleCount": active.count,
                "multiSourceActiveEvents": events.count,
            ],
            "outputs": outputFiles,
        ]

        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try receiptData.write(to: directory.appendingPathComponent("receipt.json"))
        print("LIVE_RUN_RECEIPT \(String(decoding: receiptData, as: UTF8.self))")
        await db.close()
    }

    static func testStoryImages(fixtureRoot: URL) async throws {
        print("  - Testing lead images found on publisher pages for stories without any...")
        let page = "https://news.example/world/story"
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<head><meta property=\"og:image\" content=\"/media/lead.jpg?w=1200&amp;q=80\"></head>",
                pageURL: page),
            .found("https://news.example/media/lead.jpg?w=1200&q=80"),
            "A relative og:image resolves against the page and decodes entities")
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<meta name=\"twitter:image\" content=\"https://cdn.example/a.jpg\">", pageURL: page),
            .found("https://cdn.example/a.jpg"), "twitter:image counts")
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<meta property=\"og:image\" content=\"https://news.example/logo.png\">", pageURL: page),
            .none, "Logos are not lead images")
        assertEqual(
            StoryImageFinder.leadImage(in: "<p>No image</p>", pageURL: page), .none,
            "A page without a declared image has none")
        let schema =
            #"<script type="application/ld+json">{"@graph":[{"@type":"Organization","image":"/logo.png"},{"@type":"NewsArticle","image":[{"url":"/photo.jpg"}]}]}</script>"#
        assertEqual(
            StoryImageFinder.leadImage(in: schema, pageURL: page), .found("https://news.example/photo.jpg"),
            "schema.org article images are found; publisher organization logos are skipped")
        assertEqual(
            StoryImageFinder.leadImage(
                in: "<meta property='og:image' content='/logo.png'><meta name='twitter:image' content='/photo.jpg'>",
                pageURL: page),
            .found("https://news.example/photo.jpg"), "A rejected og logo does not hide a usable Twitter image")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = mockHTTPClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }
        let head = "<meta property='og:image' content='/caf\u{00e9}.jpg'>"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=iso-8859-1", "Content-Length": "1048576"])!
            return (response, head.data(using: .isoLatin1)! + Data(repeating: 32, count: 1024 * 1024))
        }
        let (prefix, _) = try await client.fetchArticleHead(from: URL(string: "https://example.com/story")!)
        assertEqual(prefix.count, 256 * 1024, "Only a bounded page prefix is retained even for a large declared body")
        assertEqual(
            await StoryImageFinder.publisherPages(using: client).find("https://example.com/story"),
            .found("https://example.com/caf%C3%A9.jpg"),
            "The protected finder respects the publisher's declared character encoding")

        // #312: pages that declare no image. Body prose must pass reader validation, as on a real article page.
        let prose = (1...4).map {
            "Paragraph \($0) of the report describes how regional officials responded to the flooding, which closed roads and schools across the valley this week."
        }
        func articlePage(_ figures: String) -> String {
            "<html><head><title>Flooding closes roads</title></head><body><header><img src='/brand/logo.png' alt='Publisher logo'></header>"
                + "<article><p>\(prose[0])</p>\(figures)<p>\(prose[1])</p><p>\(prose[2])</p><p>\(prose[3])</p></article></body></html>"
        }
        let pages = [
            // All prose precedes the padding, so only the figure lies beyond the prefix.
            "/late": "<html><body><article>" + prose.map { "<p>\($0)</p>" }.joined() + "<div>"
                + String(repeating: " ", count: 300 * 1024)
                + "<figure><img src='/photos/late.jpg' width='1200' height='800'></figure></div></article></body></html>",
            "/early": "<html><body><article>" + prose.map { "<p>\($0)</p>" }.joined()
                + "<div><figure><img src='/photos/late.jpg' width='1200' height='800'></figure></div></article></body></html>",
            "/figure": articlePage(
                "<figure><img src='/photos/pixel.gif' width='1' height='1'></figure>"
                    + "<figure><img src='/photos/flooded-road.jpg' width='1200' height='800' alt='A flooded road'><figcaption>A flooded road near the valley</figcaption></figure>"
                    + "<figure><img src='/photos/second.jpg' width='1200' height='800'></figure>"),
            "/furniture": articlePage(
                "<figure><img src='/photos/strip.jpg' width='4000' height='200'></figure>"
                    + "<figure><img src='/promo/n.jpg' alt='A thin banner promoting the Morning Briefing newsletter'></figure>"
                    + "<figure><img src='/photos/pixel.gif' width='1' height='1'></figure>"),
        ]
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"])!,
                Data((pages[request.url!.path] ?? "").utf8)
            )
        }
        let pageFinder = StoryImageFinder.publisherPages(using: client)
        assertEqual(
            await pageFinder.find("https://example.com/figure"), .found("https://example.com/photos/flooded-road.jpg"),
            "Without a declaration, the first qualifying figure in the article body is the lead")
        assertEqual(
            await pageFinder.find("https://example.com/furniture"), StoryImageLookup.none,
            "Logos, newsletter banners, tracking pixels and extreme strips never stand in for a lead")
        assertEqual(
            await pageFinder.find("https://example.com/early"), .found("https://example.com/photos/late.jpg"),
            "A figure after the article prose qualifies within the prefix")
        assertEqual(
            await pageFinder.find("https://example.com/late"), StoryImageLookup.none,
            "Only figures within the bounded page prefix are considered")
        assertEqual(StoryImageFinder.pageURL(""), nil, "An empty link is never requested")
        assertEqual(StoryImageFinder.pageURL("/relative/story"), nil, "A relative link is never requested")
        assertEqual(
            StoryImageFinder.pageURL("https://example.com:22/story"), nil, "A link on a refused port is never requested"
        )
        assertEqual(
            StoryImageFinder.pageURL("http://example.com/story")?.absoluteString, "https://example.com/story",
            "An http link is requested over https")
        // #818: a refused page is answered as no image (recorded, not retried); rate limits and outages retry.
        for (status, expected) in [
            (403, StoryImageLookup.none), (404, .none), (410, .none), (429, .unreachable), (503, .unreachable),
        ] {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            assertEqual(
                await pageFinder.find("https://example.com/refused"), expected,
                "HTTP \(status) from a publisher page maps to its lookup state")
        }
        MockURLProtocol.requestHandler = nil

        var small = FeedArticle(
            title: "Report", link: page, guid: "small", description: "", pubDate: Date(), source: "One")
        small.readerDocument = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(url: "https://news.example/small.jpg", origin: .feed, width: 300, height: 200)
            ], leadImageURL: "https://news.example/small.jpg")
        var large = small
        large.readerDocument = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(url: "https://news.example/large.jpg", origin: .body, width: 1200, height: 800)
            ], leadImageURL: "https://news.example/large.jpg")
        assertEqual(
            FeedArticle.bestCardImage(in: [small, large])?.absoluteString, "https://news.example/large.jpg",
            "Cards select the largest usable member lead")

        var captioned = FeedArticle(
            title: "Report", link: page, guid: "captioned", description: "", pubDate: Date(), source: "Two")
        captioned.readerDocument = ReaderDocument(
            blocks: [],
            images: [
                ReaderImageCandidate(
                    url: "https://news.example/wide.jpg", origin: .body, width: 1600, height: 900,
                    caption: "  Crews clear the flooded road.  ", credit: "Photo: A. Reporter")
            ], leadImageURL: "https://news.example/wide.jpg")
        assertEqual(
            FeedArticle.cardImages(in: [small, large, captioned, large]).map(\.absoluteString),
            ["https://news.example/wide.jpg", "https://news.example/large.jpg", "https://news.example/small.jpg"],
            "Event cards rank every distinct usable member lead, best first")
        assertEqual(
            OverviewComposer.leadImage(from: [small, captioned]),
            OverviewLeadImage(
                url: "https://news.example/wide.jpg", caption: "Crews clear the flooded road.",
                credit: "Photo: A. Reporter", sourceArticleID: captioned.id),
            "The overview lead is the best member image, with its publisher caption, credit and source")
        assertEqual(
            OverviewComposer.leadImage(from: [small])?.caption, nil,
            "A lead without publisher metadata carries no invented caption")
        assertEqual(
            OverviewComposer.leadImage(from: [
                FeedArticle(
                    title: "Bare", link: page, guid: "bare", description: "", pubDate: Date(), source: "Three")
            ]),
            nil, "An event without a usable image has no overview lead")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let now = Date()
        func story(_ id: String, _ source: String, image: String? = nil) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id)",
                link: fixtureRoot.appendingPathComponent("images/\(id)").absoluteString,
                guid: id, description: "Summary.", pubDate: now.addingTimeInterval(-3600), source: source,
                imageUrl: image)
        }
        try await db.upsertArticles([
            story("plain", "One"), story("pictured", "One", image: "https://cdn.example/p.jpg"),
            story("e1", "One"), story("e2", "Two"), story("f1", "One"),
            story("f2", "Two", image: "https://cdn.example/f.jpg"),
            story("down", "Three"), story("waiting", "Three"),
        ])
        _ = try await db.createEvent(memberArticleIDs: ["e1", "e2"], at: now)
        _ = try await db.createEvent(memberArticleIDs: ["f1", "f2"], at: now)
        try await db.recordImportance("waiting", .minor, at: now)
        let rows = try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20)
        assertEqual(
            Set(rows.map(\.id)), ["plain", "e1", "e2", "down", "waiting"],
            "Minor-rated stories retain image eligibility; pictured events need no lookup"
        )
        assertTrue(rows.first.map { ["e1", "e2"].contains($0.id) } == true, "Clustered stories come first")
        let pastRefused = try await db.imagelessStoryRows(
            activeSince: now.addingTimeInterval(-86_400), limit: 1,
            isRequestable: { !$0.hasSuffix("/e1") && !$0.hasSuffix("/e2") })
        assertTrue(
            pastRefused.count == 1 && !["e1", "e2"].contains(pastRefused[0].id),
            "Links the client would refuse do not use up the candidate limit (#818)")
        assertEqual(
            rows.first(where: { $0.id == "plain" })?.link, story("plain", "One").link,
            "A freshly ingested story has a usable URL before reader extraction")

        let finder = StoryImageFinder { link in
            if link.hasSuffix("/down") { return .unreachable }
            if link.hasSuffix("/plain") { return .none }
            if link.hasSuffix("/waiting") { return .found("https://cdn.example/waiting.jpg") }
            return .found("https://cdn.example/found.jpg")
        }
        let report = try await StoryCurator.run(in: db, imageFinder: finder, now: now)
        assertEqual(report.imagesFound, 2, "Both an event and a minor singleton receive images")
        assertEqual(
            try await db.storyImages(for: ["e1", "e2", "plain"]).count, 1,
            "Found images are stored; misses are not images")
        assertTrue(
            FeedArticle.bestCardImage(
                in: try await db.fetchArticles(limit: nil, eventID: try await db.eventID(forArticle: "e1"))) != nil,
            "Shared storage exposes fetched images to grouped cards and Briefing, without list-only decoration")
        let remaining = Set(
            try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20).map(\.id))
        assertEqual(remaining, ["down"], "Pages without an image are not read again; unreachable pages are retried")
        assertFalse(
            try await db.recordStoryImage("down", imageURL: "https://cdn.example/found.jpg", at: now),
            "An image another story already declared is a site default")
        assertTrue(
            try await db.storyImages(for: ["e1", "e2", "down"]).isEmpty, "A site default is cleared for every story")
        assertFalse(
            try await db.recordStoryImage("plain", imageURL: "https://cdn.example/found.jpg", at: now),
            "A third story declaring a cleared site default does not keep it (#338)")
        assertTrue(
            try await db.storyImages(for: ["e1", "e2", "down", "plain"]).isEmpty,
            "Site defaults stay cleared regardless of lookup order")

        // #595: a pictured member only on a World Tension panel feed is hidden from lists, so the listed member of
        // its event is still looked up.
        let panelURL = TensionMethodology.v1.panel[8].url
        _ = try await db.upsertArticles([story("g1", "One")], feedUrl: "https://example.com/subscribed.xml")
        _ = try await db.upsertArticles([story("g2", "Panel", image: "https://cdn.example/g.jpg")], feedUrl: panelURL)
        _ = try await db.createEvent(memberArticleIDs: ["g1", "g2"], at: now)
        let unscoped = try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20)
        assertFalse(unscoped.contains { $0.id == "g1" }, "Without collection feeds every member counts")
        await db.setCollectionOnlyFeedURLs([panelURL])
        let scoped = try await db.imagelessStoryRows(activeSince: now.addingTimeInterval(-86_400), limit: 20)
        assertTrue(scoped.contains { $0.id == "g1" }, "A hidden member's image does not skip the listed story")
        assertFalse(scoped.contains { $0.id == "g2" }, "The hidden member itself is never looked up")
        await db.close()
        try await testStoryImageIndexMigration(fixtureRoot: fixtureRoot)
        try await testMarkAllReadScope(fixtureRoot: fixtureRoot)
    }

    /// #784: Mark All as Read marks only unread stories the reading feed shows. Earlier read times stay, and
    /// analysis-only panel reports stay unread, since a read panel report would surface in History.
    static func testMarkAllReadScope(fixtureRoot: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-mark-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        func report(_ id: String) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Report \(id)", link: fixtureRoot.appendingPathComponent(id).absoluteString,
                guid: id, description: "Report.", pubDate: Date(), source: "Publisher")
        }
        let panelURL = TensionMethodology.v1.panel[8].url
        try await db.upsertArticles([report("earlier"), report("unread")], feedUrl: "https://example.com/rss")
        try await db.upsertArticles([report("panel")], feedUrl: panelURL)
        await db.setCollectionOnlyFeedURLs([panelURL])
        try await db.markRead(articleId: "earlier", isRead: true)
        func readAt(_ id: String) -> Double? {
            var handle: OpaquePointer?
            var statement: OpaquePointer?
            defer {
                sqlite3_finalize(statement)
                sqlite3_close(handle)
            }
            guard sqlite3_open(path, &handle) == SQLITE_OK,
                sqlite3_prepare_v2(
                    handle, "SELECT read_at FROM article_state WHERE article_id = ? AND is_read = 1", -1,
                    &statement, nil) == SQLITE_OK
            else { return nil }
            sqlite3_bind_text(statement, 1, id, -1, DatabaseEngine.sqliteTransient)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_double(statement, 0) : nil
        }
        let earlier = readAt("earlier")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await db.markAllRead()
        assertEqual(readAt("earlier"), earlier, "Mark All as Read keeps the time a story was first read")
        assertTrue(readAt("unread") != nil, "Mark All as Read marks unread listed stories")
        assertTrue(readAt("panel") == nil, "Analysis-only panel reports stay unread and out of History")
        try await db.markRead(articleId: "unread", isRead: false)
        try await db.markAllRead(feedUrl: panelURL)
        assertTrue(readAt("panel") == nil, "A panel feed's own Mark All as Read leaves its hidden reports alone")
        assertTrue(readAt("unread") == nil, "Another feed's Mark All as Read leaves this feed's stories unread")
        try await db.markAllRead(feedUrl: "https://example.com/rss")
        assertTrue(readAt("unread") != nil, "A feed's Mark All as Read marks its own unread stories")
        // Muted stories are not in the list, so they stay unread rather than becoming reading interests.
        try await db.upsertArticles(
            [
                FeedArticle(
                    storedID: "muted", title: "Muted report", link: "https://muted.example/story", guid: "muted",
                    description: "Report.", pubDate: Date(), source: "Muted Publisher")
            ],
            feedUrl: "https://example.com/rss")
        try await db.markRead(articleId: "unread", isRead: false)
        var muting = MuteRules()
        _ = muting.addSource("muted.example")
        try await db.markAllRead(muting: muting)
        assertTrue(readAt("muted") == nil, "Mark All as Read leaves muted stories unread")
        assertTrue(readAt("unread") != nil, "Mute rules still let unmuted stories be marked")
        await db.close()
    }

    static func testStoryImageIndexMigration(fixtureRoot: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-image-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let article = FeedArticle(
            storedID: "index-story", title: "Publisher report",
            link: fixtureRoot.appendingPathComponent("index-story").absoluteString,
            guid: "index-story", description: "Report.", pubDate: Date(), source: "Publisher")
        try await db.upsertArticles([article])
        try await db.markRead(articleId: article.id, isRead: true)
        try await db.setSaved(articleId: article.id, isSaved: true)
        _ = try await db.recordStoryImage(article.id, imageURL: "https://cdn.example/index.jpg")
        let neighbors = (0..<64).map { index in
            FeedArticle(
                storedID: "image-neighbor-\(index)", title: "Other report",
                link: fixtureRoot.appendingPathComponent("image-neighbor-\(index)").absoluteString,
                guid: "image-neighbor-\(index)", description: "Report.", pubDate: Date(), source: "Publisher")
        }
        try await db.upsertArticles(neighbors)
        for neighbor in neighbors {
            _ = try await db.recordStoryImage(neighbor.id, imageURL: "https://cdn.example/\(neighbor.id).jpg")
        }
        await db.close()
        var handle: OpaquePointer?
        assertEqual(sqlite3_open(path, &handle), SQLITE_OK, "Open the isolated image migration fixture")
        defer { sqlite3_close(handle) }
        func value(_ sql: String, column: Int32 = 0) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, column) else {
                return nil
            }
            return String(cString: text)
        }
        assertEqual(
            sqlite3_exec(handle, "DROP INDEX idx_story_images_url; PRAGMA user_version = 18;", nil, nil, nil),
            SQLITE_OK,
            "Reconstruct an existing v18 image library")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await db.open()
        }
        do {
            try await cancelled.value
            assertTrue(false, "Cancelled migration must fail")
        } catch { assertTrue(error is CancellationError, "Cancelled migration preserves cancellation") }
        await db.close()
        assertEqual(value("PRAGMA user_version;"), "18", "Cancellation keeps the previous schema version")
        assertEqual(
            value("SELECT count(*) FROM sqlite_master WHERE name='idx_story_images_url';"), "0",
            "Cancellation leaves no partial index")
        try await db.open()
        assertEqual(
            value("PRAGMA user_version;"), String(DatabaseEngine.schemaVersion),
            "Existing v18 libraries receive the image index migration")
        assertEqual(
            sqlite3_exec(handle, "ANALYZE story_images;", nil, nil, nil), SQLITE_OK,
            "Use current fixture cardinality for the query planner")
        assertTrue(
            value(
                "EXPLAIN QUERY PLAN SELECT article_id FROM story_images WHERE image_url='https://cdn.example/index.jpg' AND article_id<>'other';",
                column: 3)?.contains("idx_story_images_url") == true,
            "Duplicate-image checks use the image URL index")
        assertEqual(
            try await db.storyImages(for: [article.id])[article.id], "https://cdn.example/index.jpg",
            "Migration preserves cached images")
        assertTrue(try await db.isRead(articleId: article.id), "Migration preserves read history")
        assertTrue(try await db.isSaved(articleId: article.id), "Migration preserves saved stories")
        await db.close()
        try await db.open()
        assertEqual(
            value("SELECT count(*) FROM sqlite_master WHERE name='idx_story_images_url';"), "1",
            "Reopening preserves one index")
        assertTrue(
            value(
                "EXPLAIN QUERY PLAN SELECT a.id FROM articles a ORDER BY \(DatabaseEngine.articleDateOrder) DESC, a.id LIMIT 201;",
                column: 3)?.contains("idx_articles_order") == true,
            "List pages walk the date-order index instead of sorting every story (#778)")
        assertEqual(
            value("SELECT count(*) FROM sqlite_master WHERE name='story_image_defaults';"), "1",
            "Upgraded libraries remember site defaults")

        // #817: classifier output stays out of the publisher-hint column, and v28 clears the rows it reached.
        let hints = ["hint-classified", "hint-publisher", "hint-unclassified", "hint-unrated"].map { id in
            FeedArticle(
                storedID: id, title: "Hint report \(id)", link: fixtureRoot.appendingPathComponent(id).absoluteString,
                guid: id, description: "Report.", pubDate: Date(), source: "Publisher")
        }
        try await db.upsertArticles(hints)
        for hint in hints.prefix(2) {
            try await db.updateEnrichment(articleId: hint.id, update: .init(category: "World"))
        }
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-classified';"), nil,
            "A classification is stored in article_enrichment only (#817)")
        assertEqual(
            try await db.fetchArticles(limit: 1, id: "hint-classified").first?.category, "World",
            "Lists still show the classifier's category")
        await db.close()
        assertEqual(
            sqlite3_exec(
                handle,
                "UPDATE articles SET category = 'World' WHERE id = 'hint-classified'; UPDATE articles SET category = 'Sport' WHERE id = 'hint-publisher'; UPDATE articles SET category = 'World' WHERE id = 'hint-unclassified'; UPDATE articles SET category = 'Politics' WHERE id = 'hint-unrated'; PRAGMA user_version = 27;",
                nil, nil, nil), SQLITE_OK, "Reconstruct a v27 library with a classifier category in the hint column")
        try await db.open()
        assertEqual(
            value("PRAGMA user_version;"), String(DatabaseEngine.schemaVersion), "The v27 library migrates to v28")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-classified';"), nil,
            "v28 clears a hint that holds the classifier's category")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-publisher';"), "Sport",
            "v28 keeps a publisher category that differs from the classifier's")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-unclassified';"), nil,
            "v28 clears a classifier label left in the hint after its enrichment category was cleared")
        assertEqual(
            value("SELECT category FROM articles WHERE id = 'hint-unrated';"), "Politics",
            "v28 keeps a publisher label that differs from the label the classifier gives the article")
        await db.close()
    }

    static func testActiveWorkCancellation() async throws {
        print("  - Testing cancellation during real clustering, transactional ingestion and feed parsing...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-active-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ingestion.sqlite3").path
        let db = DatabaseEngine(path: path)
        try await db.open()
        let now = Date()
        let feed = "https://cancel.example/feed"
        let original = FeedArticle(
            storedID: "preserved", title: "Preserved report", link: "https://cancel.example/preserved",
            guid: "preserved", description: "Original description", pubDate: now,
            source: "Publisher", fullContent: "Originalbodytoken")
        try await db.upsertArticles(
            [original], feedUrl: feed, validators: FeedValidators(etag: "original", lastModified: nil))
        try await db.markRead(articleId: original.id, isRead: true)
        try await db.setSaved(articleId: original.id, isSaved: true)
        var observer: OpaquePointer?
        assertEqual(
            sqlite3_open_v2(path, &observer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK,
            "Observe only the temporary ingestion database")
        defer { sqlite3_close(observer) }
        func snapshot() -> [String: [[String?]]] {
            var result: [String: [[String?]]] = [:]
            for table in [
                "articles", "article_state", "article_aliases", "article_enrichment", "article_feeds", "feeds",
                "articles_fts",
            ] {
                var statement: OpaquePointer?
                assertEqual(
                    sqlite3_prepare_v2(observer, "SELECT * FROM \(table) ORDER BY 1, 2;", -1, &statement, nil),
                    SQLITE_OK, "Prepare fixture snapshot")
                var rows: [[String?]] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    rows.append(
                        (0..<sqlite3_column_count(statement)).map { column in
                            sqlite3_column_text(statement, column).map { String(cString: $0) }
                        })
                    status = sqlite3_step(statement)
                }
                assertEqual(status, SQLITE_DONE, "Read complete fixture snapshot")
                sqlite3_finalize(statement)
                result[table] = rows
            }
            return result
        }
        let before = snapshot()
        let changed = FeedArticle(
            storedID: original.id, title: "Rolledback report", link: original.link,
            guid: original.guid, description: original.description, pubDate: now,
            source: original.source, fullContent: "Rolledbackbodytoken")
        let body = String(
            repeating: "Controlled publisher prose describes research and independent observations. ", count: 110)
        // The measured run keeps the audited workload. The regression run clusters 150 rows (one batch of 100 commits,
        // 50 stay pending at cancel) and parses 100 items, which still cancel mid-work. Ingestion keeps 20,000 rows:
        // the wait is for the page cache to spill, which takes the same time at any batch size; 4,000 rows commit first.
        let measuring = CommandLine.arguments.contains("--active-work-cancellation")
        // Exceed the native page-cache spill threshold so WAL growth occurs before COMMIT.
        let batch =
            [changed]
            + (0..<20_000).map { index in
                FeedArticle(
                    storedID: "cancel-insert-\(index)", title: "New report \(index)",
                    link: "https://cancel.example/insert/\(index)",
                    guid: "cancel-insert-\(index)", description: "Controlled report \(index)", pubDate: now,
                    source: "Publisher", fullContent: body)
            }
        let sampleCount = measuring ? 5 : 1
        var samples: [String: [Double]] = [:]
        for _ in 0..<sampleCount {
            assertEqual(
                sqlite3_exec(observer, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK,
                "Reset only the temporary WAL between equal-work samples")
            let done = SocketObservation()
            let write = Task.detached { () -> (Bool, Double) in
                let cancelled: Bool
                do {
                    _ = try await db.upsertArticles(
                        batch, feedUrl: feed, validators: FeedValidators(etag: "new", lastModified: nil))
                    cancelled = false
                } catch is CancellationError { cancelled = true } catch {
                    assertTrue(false, "Unexpected ingestion error: \(error)")
                    cancelled = false
                }
                let end = ProcessInfo.processInfo.systemUptime
                done.recordText("finished")
                return (cancelled, end)
            }
            // The spill comes later on a loaded machine, so wait for it or for the write to end, never a wall clock
            // alone (#692); a write that ends first fails the next assertion.
            await eventually("Actual transaction spills pages to the WAL before cancellation", timeout: .seconds(300)) {
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue
                    ?? 0
                return size > 1_048_576 || done.count > 0
            }
            assertEqual(done.count, 0, "Ingestion is still active at the observed WAL spill")
            let start = ProcessInfo.processInfo.systemUptime
            write.cancel()
            await eventually("Active ingestion cancels and rolls back within its deadline", timeout: .seconds(2)) {
                done.count == 1
            }
            let (cancelled, end) = await write.value
            assertTrue(cancelled, "Active ingestion reports CancellationError")
            samples["ingestion_rollback", default: []].append((end - start) * 1000)
            assertEqual(
                snapshot(), before,
                "Rollback preserves articles, read/save timestamps, identities, enrichment, feed metadata and FTS")
            assertEqual(try await db.counts().total, 1, "No cancelled batch row is committed")
            assertEqual(
                try await db.searchArticles(query: "Originalbodytoken").map(\.id), [original.id],
                "Original searchable text survives cancellation")
            assertTrue(
                try await db.searchArticles(query: "Rolledbackbodytoken").isEmpty, "Cancelled searchable text is absent"
            )
        }
        assertEqual(
            sqlite3_exec(observer, "INSERT INTO articles_fts(articles_fts) VALUES('integrity-check');", nil, nil, nil),
            SQLITE_OK, "FTS remains valid after repeated rollbacks")
        await db.close()

        let clustering = DatabaseEngine(path: directory.appendingPathComponent("clustering.sqlite3").path)
        try await clustering.open()
        let articles = (0..<(measuring ? 400 : 150)).map { index in
            FeedArticle(
                storedID: "cancel-cluster-\(index)", title: "Research observatory reports measurement \(index)",
                link: "https://cancel.example/cluster/\(index)", guid: "cancel-cluster-\(index)",
                description: "The research observatory published independent measurement results for project \(index).",
                pubDate: now, source: "Publisher \(index % 20)")
        }
        try await clustering.upsertArticles(articles)
        try await clustering.markRead(articleId: articles[0].id, isRead: true)
        try await clustering.setSaved(articleId: articles[0].id, isSaved: true)
        var pendingAtCancel: [Int] = []
        for _ in 0..<sampleCount {
            try await clustering.markEventMatchProcessed(articles.map(\.id), matcherVersion: 0, at: now)
            let done = SocketObservation()
            let work = Task.detached { () -> (Bool, Double) in
                let cancelled: Bool
                do {
                    _ = try await EventClusterer.run(in: clustering, now: now)
                    cancelled = false
                } catch is CancellationError { cancelled = true } catch {
                    assertTrue(false, "Unexpected clustering error: \(error)")
                    cancelled = false
                }
                let end = ProcessInfo.processInfo.systemUptime
                done.recordText("finished")
                return (cancelled, end)
            }
            await eventually("Clustering commits real progress before cancellation") {
                let count = try? await clustering.pendingEventMatchRows(
                    activeSince: now.addingTimeInterval(-72 * 3600),
                    matcherVersion: EventMatcher.version, limit: articles.count
                ).count
                return count.map { $0 < articles.count } ?? false
            }
            let remaining = try await clustering.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: articles.count
            ).count
            assertTrue(
                remaining > 0 && remaining < articles.count,
                "Clustering has completed some work and still has pending rows")
            assertEqual(done.count, 0, "Clustering is active when cancelled")
            pendingAtCancel.append(remaining)
            let start = ProcessInfo.processInfo.systemUptime
            work.cancel()
            await eventually("Active clustering cancels within its deadline", timeout: .seconds(2)) { done.count == 1 }
            let (cancelled, end) = await work.value
            assertTrue(cancelled, "Active clustering reports CancellationError")
            samples["clustering", default: []].append((end - start) * 1000)
            assertEqual(
                try await clustering.counts().total, articles.count, "Cancellation never deletes source articles")
            assertTrue(
                try await clustering.isRead(articleId: articles[0].id), "Clustering cancellation preserves read state")
            assertTrue(
                try await clustering.isSaved(articleId: articles[0].id), "Clustering cancellation preserves saved state"
            )
        }
        let resumed = try await EventClusterer.run(in: clustering, now: now)
        assertTrue(resumed.processed > 0, "A later pass resumes cancelled work")
        assertTrue(
            try await clustering.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-72 * 3600),
                matcherVersion: EventMatcher.version, limit: 1
            ).isEmpty, "Resumed clustering drains remaining rows")
        assertEqual(
            try await EventClusterer.run(in: clustering, now: now).processed, 0, "The resumed archive is not recomputed"
        )
        await clustering.close()

        // Feed parsing extracts every item's HTML; a cancelled refresh must not finish that work or keep its result.
        let paragraph =
            "<p>Controlled publisher prose describes <em>research</em> and independent observations in detail.</p>"
        let itemCount = measuring ? 500 : 100
        let items = (0..<itemCount).map { index in
            "<item><title>Parsed report \(index)</title><link>https://cancel.example/parse/\(index)</link><guid>parse-\(index)</guid>"
                + "<description>Report \(index)</description><content:encoded><![CDATA[<h2>Section</h2>"
                + String(repeating: paragraph, count: 15) + "]]></content:encoded></item>"
        }.joined()
        let feedData = Data(
            ("<?xml version=\"1.0\"?><rss version=\"2.0\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\">"
                + "<channel><title>Publisher</title>" + items + "</channel></rss>").utf8)
        let fullStart = ProcessInfo.processInfo.systemUptime
        assertEqual(
            FeedXMLParser(data: feedData, feedURL: feed).parse().count, itemCount,
            "The uncancelled fixture parses every item"
        )
        let fullParse = ProcessInfo.processInfo.systemUptime - fullStart
        assertTrue(fullParse > 0.1, "The parsing fixture runs long enough to cancel mid-feed")
        for _ in 0..<sampleCount {
            let started = SocketObservation()
            let done = SocketObservation()
            let parse = Task.detached { () -> (Int, Double) in
                started.recordText("started")
                let parsed = FeedXMLParser(data: feedData, feedURL: feed).parse().count
                let end = ProcessInfo.processInfo.systemUptime
                done.recordText("finished")
                return (parsed, end)
            }
            await eventually("Feed parsing starts before cancellation") { started.count == 1 }
            try await Task.sleep(for: .seconds(fullParse / 4))
            assertEqual(done.count, 0, "Feed parsing is active when cancelled")
            let start = ProcessInfo.processInfo.systemUptime
            parse.cancel()
            await eventually("Active feed parsing stops within its deadline", timeout: .seconds(2)) { done.count == 1 }
            let (parsed, end) = await parse.value
            assertEqual(parsed, 0, "A cancelled parse returns no articles")
            samples["feed_parsing", default: []].append((end - start) * 1000)
        }
        let jsonFeed = Data(
            #"{"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://cancel.example/json/1","content_html":"<p>Body</p>"}]}"#
                .utf8)
        let cancelledJSON = await Task.detached { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return JSONFeedParser.parse(data: jsonFeed, feedURL: feed)?.count
        }.value
        assertEqual(cancelledJSON, nil, "A cancelled JSON Feed parse returns no articles")
        assertEqual(
            JSONFeedParser.parse(data: jsonFeed, feedURL: feed)?.count, 1,
            "The same JSON Feed parses when not cancelled")

        let report: [String: Any] = [
            "samples_ms": samples, "samples_per_operation": sampleCount, "ingestion_batch_rows": batch.count,
            "ingestion_body_characters": body.count, "wal_spill_threshold_bytes": 1_048_576,
            "clustering_library_rows": articles.count, "clustering_pending_at_cancel": pendingAtCancel,
            "parsing_feed_items": itemCount, "parsing_feed_bytes": feedData.count,
            "parsing_uncancelled_ms": fullParse * 1000,
            "sqlite_version": String(cString: sqlite3_libversion()),
        ]
        print(
            "ACTIVE_CANCELLATION_REPORT "
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        )
    }

    static func testDockBadgeCount() {
        print("  - Testing the Dock badge: today's unread Briefing plus notified stories (#584)...")
        // 3,502 stories, 3,454 of them unread; 10 Briefing stories, 8 unread; 2 notified stories, unread.
        let library = (0..<3_502).map { "story-\($0)" }
        let edition = Array(library[0..<10])
        let read = Set(library[3_456...]).union(edition[0..<2])
        assertEqual(library.filter { !read.contains($0) }.count, 3_454, "The seeded library has 3,454 unread stories")
        let notified: Set<String> = ["story-20", "story-21"]
        let now = Date()
        let selectedAt = FiniteBriefing.editionStart(now: now, hour: 7)
        func badge(_ read: Set<String>, notified: Set<String> = notified, selectedAt: Date = selectedAt) -> Int {
            FiniteBriefing.dockBadgeCount(
                editionIDs: edition.joined(separator: "\n"), selectedAt: selectedAt, hour: 7, notified: notified,
                read: read, now: now)
        }
        assertEqual(badge(read), 10, "8 unread Briefing stories and 2 notified ones make the badge 10, not 3,454")
        assertEqual(badge(read.union(["story-5"])), 9, "Reading a Briefing story lowers the badge at once")
        assertEqual(badge(read, notified: notified.union(["story-6"])), 10, "A notified Briefing story counts once")
        assertEqual(badge(read.union(notified)), 8, "Read notified stories no longer count")
        let yesterday = FiniteBriefing.editionStart(now: now, hour: 7).addingTimeInterval(-60)
        assertEqual(badge(read, selectedAt: yesterday), 2, "An edition from before the edition hour counts nothing")
        assertEqual(badge(Set(library)), 0, "Nothing unread hides the badge")
    }

    /// #780: the Briefing carousel takes the stories with the most publishers, edition order breaking ties, and the
    /// tiles group by topic in the order the edition reaches each one, uncategorised stories last.
    static func testBriefingBoardLayout() {
        print("  - Testing the Briefing board: hero ranking by publishers and tiles grouped by topic (#780)...")
        let now = Date(timeIntervalSince1970: 1_793_372_400)
        func story(_ id: String, _ category: String?) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Story \(id)", link: "https://example.com/\(id)", guid: id, description: "",
                pubDate: now, source: "Publisher", category: category)
        }
        func event(_ id: String, _ category: String?, publishers: Int, members: Int? = nil) -> FeedEntry {
            let article = story(id, category)
            let rows = (0..<(members ?? publishers)).map { index in
                EventFeedMember(
                    articleID: index == 0 ? id : "\(id)-\(index)", source: "Outlet \(index % publishers)",
                    title: article.title, date: now, joinedVersion: 1, isRead: false, isSaved: false)
            }
            return .event(
                EventFeedSummary(eventID: "event-\(id)", membershipVersion: 1, seenVersion: nil, members: rows),
                representative: article, visibleMembers: [article])
        }
        let entries: [FeedEntry] = [
            .article(story("a", "World")), event("b", "Business", publishers: 3),
            event("c", "International", publishers: 9),
            .article(story("d", nil)), event("e", "Technology", publishers: 3, members: 7),
            event("f", "World", publishers: 5), .article(story("g", "Science")),
        ]
        assertEqual(
            entries.map(\.publisherCount), [1, 3, 9, 1, 3, 5, 1],
            "Coverage counts distinct publishers, not reports: seven reports from three outlets are three")
        assertEqual(
            BriefingView.heroEntries(entries).map(\.id), ["c", "f", "b", "e", "a"],
            "The carousel shows five stories, most publishers first, edition order breaking ties")
        assertEqual(BriefingView.heroEntries(Array(entries.prefix(2))).count, 2, "Fewer stories show what there is")
        let sections = BriefingView.sections(entries)
        assertEqual(
            sections.map(\.title), ["World", "Business", "Technology", "Science", BriefingView.otherSection],
            "Sections follow the edition; a feed category maps to the app's topics and no category comes last")
        assertEqual(sections[0].entries.map(\.id), ["a", "c", "f"], "A section keeps edition order")
        assertEqual(sections.flatMap(\.entries).count, entries.count, "Every story has one tile")
    }

    static func testFiniteBriefing() async throws {
        print("  - Testing bounded, balanced and frozen briefings (#162)...")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_780_000_000)  // 2026-05-28 20:26 UTC
        let dayStart = utc.startOfDay(for: morning)
        assertEqual(
            FiniteBriefing.editionStart(now: morning, hour: 7, calendar: utc), dayStart.addingTimeInterval(7 * 3600),
            "After the edition hour, today's edition is due")
        let early = dayStart.addingTimeInterval(5 * 3600)
        assertEqual(
            FiniteBriefing.editionStart(now: early, hour: 7, calendar: utc),
            dayStart.addingTimeInterval(-17 * 3600), "Before the edition hour, yesterday's edition is still due")
        assertTrue(
            FiniteBriefing.isCurrent(
                selectedAt: dayStart.addingTimeInterval(8 * 3600), now: morning, hour: 7, calendar: utc),
            "An edition selected after today's hour stays current")
        assertFalse(
            FiniteBriefing.isCurrent(
                selectedAt: dayStart.addingTimeInterval(6 * 3600), now: morning, hour: 7, calendar: utc),
            "An edition selected before today's hour is replaced")
        assertFalse(
            FiniteBriefing.isCurrent(selectedAt: morning.addingTimeInterval(60), now: morning, hour: 7, calendar: utc),
            "An edition stamped in the future is not trusted")
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        // 24 October 2026 08:00 BST; clocks go back on the 25th, so the next 07:00 is 25 hours later.
        let beforeChange = london.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 8))!
        let next = FiniteBriefing.nextEditionStart(now: beforeChange, hour: 7, calendar: london)
        assertEqual(
            london.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 7),
            "The next edition keeps its local hour across a daylight-saving change")

        let now = Date(timeIntervalSince1970: 1_790_928_000)
        func article(_ id: String, age: TimeInterval, source: String = "Dominant", category: String = "Tech")
            -> FeedArticle
        {
            FeedArticle(
                storedID: id, title: "Briefing story \(id)", link: "https://example.com/briefing/\(id)",
                guid: id, description: "Publisher report \(id)", pubDate: now.addingTimeInterval(-age),
                source: source, category: category)
        }
        var candidates = (0..<40).map { article("dominant-\($0)", age: Double($0)) }
        candidates += [
            article("world", age: 100, source: "World Desk", category: "World"),
            article("science", age: 200, source: "Science Desk", category: "Science"),
            article("read", age: 0), article("old", age: FiniteBriefing.duration + 1),
            article("future", age: -1), article("boundary", age: FiniteBriefing.duration),
        ]
        var undated = article("undated", age: 0)
        undated = FeedArticle(
            storedID: undated.id, title: undated.title, link: undated.link,
            guid: undated.guid, description: undated.description, pubDate: DateParser.unknownDate,
            source: undated.source)
        candidates.append(undated)
        let session = FiniteBriefing(candidates: candidates + [candidates[0]], readIDs: ["read"], now: now)
        assertEqual(session.articles.count, 4, "The briefing caps a dominant publisher at two stories")
        assertEqual(Set(session.articles.map(\.id)).count, 4, "Duplicate candidates cannot consume slots")
        assertEqual(
            Array(session.articles.prefix(3).map(\.id)), ["dominant-0", "world", "science"],
            "Recency ties break a source/category mix deterministically")
        assertFalse(
            session.articles.contains { ["read", "old", "future", "undated"].contains($0.id) },
            "Read, old, future and undated stories stay out")
        let frozen = session.articles
        candidates.insert(article("arriving-later", age: 0), at: 0)
        assertEqual(session.articles, frozen, "Incoming stories cannot change an existing selection")
        let allRead = Set(session.articles.map(\.id))
        assertTrue(session.isComplete(allRead), "Reading all selected stories completes the briefing")
        assertEqual(session.readCount([session.articles[0].id]), 1, "Completion follows article read state")
        assertFalse(session.isComplete([]), "An unread briefing is incomplete")
        assertFalse(
            FiniteBriefing(candidates: [], readIDs: [], now: now).isComplete([]),
            "An empty window is not a completed briefing")

        let ranked = [
            article("covered", age: 200), article("major", age: 0),
            article("stored", age: 100), article("neutral", age: 20), article("minor", age: 10),
        ]
        let priority: [String: BriefingPriority] = [
            "covered": .init(sourceCount: 3, importance: .minor),
            "major": .init(sourceCount: 1, importance: .major),
            "stored": .init(sourceCount: 2, importance: .major),
            "neutral": .init(sourceCount: 2),
            "minor": .init(sourceCount: 2, importance: .minor),
        ]
        assertEqual(
            FiniteBriefing(candidates: ranked, readIDs: [], now: now, priorities: priority).articles.map(\.id),
            ["covered", "minor"],
            "Coverage precedes recency when importance is removed; one publisher cannot occupy the briefing")

        let personalized = [
            article("general", age: 0, source: "General", category: "World"),
            article("interest", age: 20, source: "Science Desk", category: "Science"),
            article("duplicate-event", age: 10, source: "Other", category: "Science"),
        ]
        let personalizedBriefing = FiniteBriefing(
            candidates: personalized, readIDs: [], now: now,
            priorities: ["interest": .init(eventID: "one-event"), "duplicate-event": .init(eventID: "one-event")],
            interests: ["science": 3])
        assertEqual(
            personalizedBriefing.articles.first?.id, "duplicate-event",
            "Interest breaks coverage ties before recency")
        assertEqual(personalizedBriefing.articles.count, 2, "One event cannot consume two briefing slots")

        // Direct unit tests for FiniteBriefing.rank contract
        let r1 = FiniteBriefing.rank(
            priority: .init(sourceCount: 3), interest: 0, sourceCount: 0, categoryCount: 0)
        let r2 = FiniteBriefing.rank(
            priority: .init(sourceCount: 1), interest: 5, sourceCount: 0, categoryCount: 0)
        assertTrue(r2.lexicographicallyPrecedes(r1), "Source coverage precedes interest")
        let r3 = FiniteBriefing.rank(
            priority: .init(sourceCount: 2), interest: 3, sourceCount: 1, categoryCount: 1)
        assertEqual(
            r3, [2, 3, -2, -1],
            "Rank vector formula matches [sourceCount, interest, -(sources + categories), -sources]")

        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        _ = try await db.upsertArticles(candidates)
        try await db.markRead(articleId: "read", isRead: true)
        let fetched = try await db.fetchArticles(
            isRead: false, limit: 500,
            publicationWindow: now.addingTimeInterval(-FiniteBriefing.duration)...now)
        let ids = Set(fetched.map(\.id))
        assertTrue(ids.contains("boundary"), "The lower time boundary is included")
        assertFalse(
            ids.contains("old") || ids.contains("future") || ids.contains("undated") || ids.contains("read"),
            "SQLite filters the exact window and read state before selection")
        assertEqual(
            try await db.fetchArticles(limit: nil).count, candidates.count, "The briefing leaves archive access intact")

        // Test non-destructive briefing interests reset
        let testNow = Date(timeIntervalSince1970: 1_700_000_000)
        let interestsDb = DatabaseEngine(path: ":memory:")
        try await interestsDb.open()
        let testArticles = [
            article("int-tech", age: 0, category: "Technology"),
            article("int-science", age: 0, category: "Science"),
            article("int-politics", age: 0, category: "Politics"),
            article("int-old", age: 0, category: "Business"),
        ]
        _ = try await interestsDb.upsertArticles(testArticles)

        let tenDaysAgo = testNow.addingTimeInterval(-10 * 86400)
        try await interestsDb.markRead(articleId: "int-tech", isRead: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tenDaysAgo.timeIntervalSince1970), .text("int-tech")])

        let twoDaysAgo = testNow.addingTimeInterval(-2 * 86400)
        try await interestsDb.markRead(articleId: "int-science", isRead: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(twoDaysAgo.timeIntervalSince1970), .text("int-science")])

        let oneDayAgo = testNow.addingTimeInterval(-1 * 86400)
        try await interestsDb.setSaved(articleId: "int-politics", isSaved: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET saved_at = ? WHERE article_id = ?;",
            [.real(oneDayAgo.timeIntervalSince1970), .text("int-politics")])

        let thirtyFiveDaysAgo = testNow.addingTimeInterval(-35 * 86400)
        try await interestsDb.markRead(articleId: "int-old", isRead: true)
        _ = try await interestsDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(thirtyFiveDaysAgo.timeIntervalSince1970), .text("int-old")])

        // 1. Without resetAt: respects 30-day window (excludes 35-day-old article)
        let defaultInterests = try await interestsDb.briefingInterests(now: testNow)
        assertEqual(defaultInterests["technology"], 1, "Read tech story within 30 days scores 1")
        assertEqual(defaultInterests["science"], 1, "Read science story within 30 days scores 1")
        assertEqual(defaultInterests["politics"], 3, "Saved politics story within 30 days scores 3")
        assertTrue(defaultInterests["business"] == nil, "Business story older than 30 days excluded")

        // 2. With resetAt = 5 days ago: excludes tech (10 days ago), keeps science (2 days ago) and politics (1 day ago)
        let reset5DaysAgo = testNow.addingTimeInterval(-5 * 86400)
        let resetInterests = try await interestsDb.briefingInterests(now: testNow, resetAt: reset5DaysAgo)
        assertTrue(resetInterests["technology"] == nil, "Tech story read before reset cutoff is excluded")
        assertEqual(resetInterests["science"], 1, "Science story read after reset cutoff is retained")
        assertEqual(resetInterests["politics"], 3, "Politics story saved after reset cutoff is retained")

        // 3. With resetAt = testNow: interests are completely cleared
        let clearedInterests = try await interestsDb.briefingInterests(now: testNow, resetAt: testNow)
        assertTrue(clearedInterests.isEmpty, "Resetting to now produces zero inferred interests")

        // 3b. Notification triage honors the reset like the Briefing does (#806)
        let triageUnreset = await FeedManager.triageInterests(database: interestsDb, now: testNow, resetAt: nil)
        assertFalse(triageUnreset.isEmpty, "Triage without a reset still ranks the read history")
        let triageReset = await FeedManager.triageInterests(database: interestsDb, now: testNow, resetAt: testNow)
        assertTrue(triageReset.isEmpty, "Triage after a reset has no interests from earlier history")

        // 4. Non-destructive assertion: read markers and bookmarks remain intact
        assertTrue(
            try await interestsDb.isRead(articleId: "int-tech"),
            "Read status preserved after interests reset")
        assertTrue(
            try await interestsDb.isRead(articleId: "int-science"),
            "Read status preserved after interests reset")
        assertTrue(
            try await interestsDb.isSaved(articleId: "int-politics"),
            "Saved status preserved after interests reset")

        try await testAdversarialDatabaseInterestsReset()
    }

    @MainActor
    static func testAdversarialDatabaseInterestsReset() async throws {
        print("  - Adversarial empirical challenge: briefingInterests boundary values & SQLite integrity...")
        let testNow = Date(timeIntervalSince1970: 1_750_000_000)

        func makeTestArticle(id: String, category: String, age: TimeInterval = 0) -> FeedArticle {
            FeedArticle(
                storedID: id,
                title: "Test Article \(id)",
                link: "https://example.com/test/\(id)",
                guid: id,
                description: "Description \(id)",
                pubDate: testNow.addingTimeInterval(-age),
                source: "Test Source",
                category: category
            )
        }

        // Test 1: Empty Database
        let emptyDb = DatabaseEngine(path: ":memory:")
        try await emptyDb.open()
        let empty1 = try await emptyDb.briefingInterests(now: testNow, resetAt: nil)
        assertTrue(empty1.isEmpty, "Empty database returns empty interests with nil resetAt")
        let empty2 = try await emptyDb.briefingInterests(now: testNow, resetAt: testNow)
        assertTrue(empty2.isEmpty, "Empty database returns empty interests with resetAt = now")
        let empty3 = try await emptyDb.briefingInterests(now: testNow, resetAt: testNow.addingTimeInterval(86400))
        assertTrue(empty3.isEmpty, "Empty database returns empty interests with future resetAt")
        await emptyDb.close()

        // Test 2: Cutoff Boundary Values (Future, Exactly 30 Days, 40 Days, Exactly Now)
        let boundaryDb = DatabaseEngine(path: ":memory:")
        try await boundaryDb.open()

        let artAt30d = makeTestArticle(id: "b-exact-30d", category: "Technology")
        let artOlder30d = makeTestArticle(id: "b-older-30d", category: "Technology")
        let artNewer30d = makeTestArticle(id: "b-newer-30d", category: "Technology")
        let artAt35d = makeTestArticle(id: "b-35d", category: "Business")
        let artAt45d = makeTestArticle(id: "b-45d", category: "Business")
        let artAt10d = makeTestArticle(id: "b-10d", category: "Science")
        let artAt1d = makeTestArticle(id: "b-1d", category: "World")
        let artAtNow = makeTestArticle(id: "b-now", category: "Politics")

        _ = try await boundaryDb.upsertArticles([
            artAt30d, artOlder30d, artNewer30d, artAt35d, artAt45d, artAt10d, artAt1d, artAtNow,
        ])

        let thirtyDaysSeconds = 30.0 * 86400.0
        let tExact30d = testNow.addingTimeInterval(-thirtyDaysSeconds)
        let tOlder30d = testNow.addingTimeInterval(-thirtyDaysSeconds - 2.0)
        let tNewer30d = testNow.addingTimeInterval(-thirtyDaysSeconds + 2.0)
        let t35d = testNow.addingTimeInterval(-35.0 * 86400.0)
        let t45d = testNow.addingTimeInterval(-45.0 * 86400.0)
        let t10d = testNow.addingTimeInterval(-10.0 * 86400.0)
        let t1d = testNow.addingTimeInterval(-1.0 * 86400.0)
        let tNow = testNow

        // Set read/saved timestamps in article_state
        try await boundaryDb.markRead(articleId: "b-exact-30d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tExact30d.timeIntervalSince1970), .text("b-exact-30d")])

        try await boundaryDb.markRead(articleId: "b-older-30d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tOlder30d.timeIntervalSince1970), .text("b-older-30d")])

        try await boundaryDb.markRead(articleId: "b-newer-30d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tNewer30d.timeIntervalSince1970), .text("b-newer-30d")])

        try await boundaryDb.markRead(articleId: "b-35d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(t35d.timeIntervalSince1970), .text("b-35d")])

        try await boundaryDb.markRead(articleId: "b-45d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(t45d.timeIntervalSince1970), .text("b-45d")])

        try await boundaryDb.markRead(articleId: "b-10d", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(t10d.timeIntervalSince1970), .text("b-10d")])

        try await boundaryDb.setSaved(articleId: "b-1d", isSaved: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET saved_at = ? WHERE article_id = ?;",
            [.real(t1d.timeIntervalSince1970), .text("b-1d")])

        try await boundaryDb.markRead(articleId: "b-now", isRead: true)
        _ = try await boundaryDb.eventRows(
            "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
            [.real(tNow.timeIntervalSince1970), .text("b-now")])

        // 2a. Boundary: resetAt exactly 30 days ago (resetAt == thirtyDaysAgo)
        // Technology should include exact-30d (1 pt) + newer-30d (1 pt) = 2 pts. Older-30d is excluded.
        let interests30d = try await boundaryDb.briefingInterests(now: testNow, resetAt: tExact30d)
        assertEqual(
            interests30d["technology"], 2,
            "Exact 30-day cutoff includes interaction at exact boundary and newer, excludes older")

        // 2b. Boundary: resetAt 40 days ago (resetAt < thirtyDaysAgo)
        // Even though resetAt is 40 days ago, 30-day window max(thirtyDaysAgo, resetAt) must prevail.
        // Therefore, b-35d and b-45d (Business) must NOT appear in interests.
        let t40d = testNow.addingTimeInterval(-40.0 * 86400.0)
        let interests40d = try await boundaryDb.briefingInterests(now: testNow, resetAt: t40d)
        assertTrue(interests40d["business"] == nil, "resetAt 40 days ago cannot bypass 30-day maximum lookback")
        assertEqual(interests40d["technology"], 2, "Technology interactions within 30 days still scored")
        assertEqual(interests40d["science"], 1, "Science 10d interaction scored")
        assertEqual(interests40d["world"], 3, "World 1d saved interaction scored 3")

        // 2c. Boundary: resetAt in the future (resetAt > now)
        let tFuture = testNow.addingTimeInterval(3600)
        let interestsFuture = try await boundaryDb.briefingInterests(now: testNow, resetAt: tFuture)
        assertTrue(interestsFuture.isEmpty, "Future resetAt produces empty interests dictionary without error")

        // 2d. Boundary: resetAt == now
        // An interaction with read_at strictly before now is excluded.
        let interestsNow = try await boundaryDb.briefingInterests(now: testNow, resetAt: testNow)
        assertTrue(
            interestsNow["technology"] == nil,
            "Technology interactions prior to now excluded when resetAt == now")
        assertTrue(
            interestsNow["science"] == nil,
            "Science interactions prior to now excluded when resetAt == now")
        assertTrue(
            interestsNow["world"] == nil,
            "World interactions prior to now excluded when resetAt == now")

        // Call with resetAt strictly after the latest interaction:
        let interestsAfterAll = try await boundaryDb.briefingInterests(
            now: testNow, resetAt: testNow.addingTimeInterval(0.001))
        assertTrue(interestsAfterAll.isEmpty, "Resetting after all interactions produces completely empty interests")

        // Test 3: Exactly 200 interaction records
        let limitDb = DatabaseEngine(path: ":memory:")
        try await limitDb.open()

        var articles200: [FeedArticle] = []
        for i in 0..<100 {
            articles200.append(makeTestArticle(id: "tech-200-\(i)", category: "Technology"))
        }
        for i in 0..<100 {
            articles200.append(makeTestArticle(id: "sci-200-\(i)", category: "Science"))
        }
        _ = try await limitDb.upsertArticles(articles200)

        for i in 0..<100 {
            let artId = "tech-200-\(i)"
            try await limitDb.markRead(articleId: artId, isRead: true)
            let stamp = testNow.addingTimeInterval(-Double(i + 1) * 3600.0)
            _ = try await limitDb.eventRows(
                "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
                [.real(stamp.timeIntervalSince1970), .text(artId)])
        }
        for i in 0..<100 {
            let artId = "sci-200-\(i)"
            try await limitDb.setSaved(articleId: artId, isSaved: true)
            let stamp = testNow.addingTimeInterval(-Double(i + 1) * 3600.0)
            _ = try await limitDb.eventRows(
                "UPDATE article_state SET saved_at = ? WHERE article_id = ?;",
                [.real(stamp.timeIntervalSince1970), .text(artId)])
        }

        let interests200 = try await limitDb.briefingInterests(now: testNow)
        assertEqual(interests200["technology"], 100, "Exactly 100 read articles score 100 points")
        assertEqual(interests200["science"], 300, "Exactly 100 saved articles score 300 points")

        // Test 4: >200 records (e.g., 250 records testing recency DESC and LIMIT 200 truncation)
        // Add 50 Business articles that were read 20 days ago (older than the 200 Tech & Science articles)
        var articles50Extra: [FeedArticle] = []
        for i in 0..<50 {
            articles50Extra.append(makeTestArticle(id: "biz-extra-\(i)", category: "Business"))
        }
        _ = try await limitDb.upsertArticles(articles50Extra)
        for i in 0..<50 {
            let artId = "biz-extra-\(i)"
            try await limitDb.markRead(articleId: artId, isRead: true)
            let oldStamp = testNow.addingTimeInterval(-20.0 * 86400.0 - Double(i))
            _ = try await limitDb.eventRows(
                "UPDATE article_state SET read_at = ? WHERE article_id = ?;",
                [.real(oldStamp.timeIntervalSince1970), .text(artId)])
        }

        // Total interactions in limitDb = 250.
        // Because briefingInterests has LIMIT 200 ORDER BY interaction DESC,
        // the 200 newest (100 Tech + 100 Science) should consume all 200 slots.
        // The 50 older Business articles must be truncated out!
        let interests250 = try await limitDb.briefingInterests(now: testNow)
        assertEqual(interests250["technology"], 100, "Top 200 keeps all recent Technology reads")
        assertEqual(interests250["science"], 300, "Top 200 keeps all recent Science saves")
        assertTrue(interests250["business"] == nil, "50 older interactions truncated by LIMIT 200 clause")

        // Test 5: 100% User Data Integrity in SQLite article_state
        struct ArticleStateRow: Equatable {
            let articleId: String
            let isRead: String
            let readAt: String
            let isSaved: String
            let savedAt: String
        }

        func queryArticleStates(engine: DatabaseEngine) async throws -> [ArticleStateRow] {
            let sql = """
                SELECT article_id, coalesce(is_read, '0'), coalesce(read_at, 'null'),
                       coalesce(is_saved, '0'), coalesce(saved_at, 'null')
                FROM article_state ORDER BY article_id;
                """
            let rows = try await engine.eventRows(sql)
            return rows.map { r in
                ArticleStateRow(
                    articleId: r[0] ?? "",
                    isRead: r[1] ?? "",
                    readAt: r[2] ?? "",
                    isSaved: r[3] ?? "",
                    savedAt: r[4] ?? ""
                )
            }
        }

        let stateSnapshotBefore = try await queryArticleStates(engine: boundaryDb)
        assertTrue(!stateSnapshotBefore.isEmpty, "article_state is populated before reset tests")

        // Call briefingInterests with many different resetAt values repeatedly
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: testNow)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: tFuture)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: t1d)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: t40d)
        _ = try await boundaryDb.briefingInterests(now: testNow, resetAt: nil)

        let stateSnapshotAfter = try await queryArticleStates(engine: boundaryDb)
        assertEqual(
            stateSnapshotBefore.count, stateSnapshotAfter.count,
            "article_state row count is 100% unchanged after resetAt calls")
        assertEqual(
            stateSnapshotBefore, stateSnapshotAfter,
            "Every single field of article_state (is_read, read_at, is_saved, saved_at) is 100% bit-for-bit preserved")

        await boundaryDb.close()
        await limitDb.close()
    }

    /// The authored English corpus replayed through the real clusterer (#506). Regression evidence with a ratchet;
    /// the private holdout (#509) stays the acceptance measurement. Pairs are printed by fixture id only.
    /// Opt-in, live, local only (#508): the real on-device model over authored reports of violence. Prints the
    /// identifier and version the reader would store and whether a second request repeats the outcome; the
    /// `NewsTextModel` log category carries the outcome label. No publisher text, nothing stored.
    static func checkOnDeviceModelOutcomes() async throws {
        let reports: [(name: String, title: String, content: String)] = [
            (
                "benign",
                "City council approves new library branch",
                """
                The city council voted on Tuesday to fund a new library branch in the eastern district. \
                Construction is expected to start next spring and take eighteen months. \
                Councillors said the branch would include a children's reading room and a community hall. \
                The budget was approved without opposition after a short debate.
                """
            ),
            (
                "shooting",
                "Three dead after gunman opens fire at shopping mall",
                """
                A gunman shot and killed three people at a shopping mall on Saturday afternoon before a police \
                officer shot him dead, police said. Two more people were wounded and taken to hospital. \
                Witnesses described shoppers running from the food court as shots rang out. \
                Police have not named the attacker and said the motive was unknown.
                """
            ),
            (
                "war",
                "Air strike on apartment block kills at least twelve",
                """
                An overnight air strike hit a residential block in the city's northern district, killing at least \
                twelve people including four children, the regional governor said on Monday. \
                Rescue teams pulled survivors from the rubble through the morning as shelling continued nearby. \
                The military said it had struck a command post; residents said the building housed only families.
                """
            ),
        ]
        let analyzer = ArticleAnalyzer(textModel: .onDevice)
        for report in reports {
            let first = try await analyzer.analyze(title: report.title, content: report.content)
            let second = try await analyzer.analyze(title: report.title, content: report.content)
            print(
                "    \(report.name): identifier \(first.modelIdentifier) version \(first.analysisVersion), "
                    + "repeat identifier \(second.modelIdentifier) version \(second.analysisVersion), "
                    + "summary \(first.summary.count) chars")
        }
        // A prompt past the context window is the one rejection that needs no sensitive text to provoke.
        do {
            _ = try await NewsTextModel.onDevice.respond(String(repeating: "word ", count: 40_000), 32)
            print("    oversized prompt: answered")
        } catch let rejected as NewsTextModel.Rejected {
            print("    oversized prompt: rejected:\(rejected.reason.rawValue) (final)")
        } catch {
            print("    oversized prompt: \(type(of: error)) (provisional)")
        }
        print(
            "    Outcome labels: log show --predicate 'subsystem == \"com.marspater.news\" AND category == \"NewsTextModel\"' "
                + "--last 10m")
    }

    /// A verdict replay (#629): how many verdicts the pair model decides as the reader did at `base`, and with the
    /// calibration fitted on them. Clean when the calibration decides at least as many as the bare cutoff.
    static func verdictReplay(
        _ rows: [PairCalibration.Row], base: Double = EventMatchPolicy.standard.pairModelThreshold
    ) -> (verdicts: Int, bare: Int, calibrated: Int, fitted: Bool) {
        // Fitted as production fits: on at most the first 1,000 rows (verdicts.csv is written in pair-id order).
        let calibration = PairCalibration.fit(Array(rows.prefix(1_000)))
        var bare = 0
        var calibrated = 0
        for row in rows {
            if (row.features[0] >= base) == row.same { bare += 1 }
            let cutoff = calibration?.cutoff(base, row.features) ?? base
            if (row.features[0] >= cutoff) == row.same { calibrated += 1 }
        }
        return (rows.count, bare, calibrated, calibration != nil)
    }

    /// Synthetic verdicts: the pair model spread over 0.82–0.98, and the reader says "same" for reports under 24 h
    /// apart, which the bare cutoff cannot see.
    static func syntheticVerdicts(_ count: Int) -> [PairCalibration.Row] {
        (0..<count).map { index in
            let gap = Double(index * 7 % 60)
            return PairCalibration.Row(
                features: PairCalibration.features(
                    pairModel: 0.82 + 0.16 * Double(index % 17) / 16, cosine: 0.7, sharedSpecific: 2, gapHours: gap,
                    sameAct: true),
                same: gap < 24)
        }
    }

    struct EventCorpusMetrics {
        var truePositives = 0, falsePositives = 0, falseNegatives = 0, impureEvents = 0
        var precision: Double? {
            truePositives + falsePositives == 0 ? nil : Double(truePositives) / Double(truePositives + falsePositives)
        }
        var recall: Double? {
            truePositives + falseNegatives == 0 ? nil : Double(truePositives) / Double(truePositives + falseNegatives)
        }
        mutating func add(predicted: Bool, gold: Bool) {
            if predicted && gold {
                truePositives += 1
            } else if predicted {
                falsePositives += 1
            } else if gold {
                falseNegatives += 1
            }
        }
        var line: String {
            let precisionText = precision.map { String(format: "%.3f", $0) } ?? "n/a"
            let recallText = recall.map { String(format: "%.3f", $0) } ?? "n/a"
            func interval(_ successes: Int, _ trials: Int) -> String {
                StoryCorpus.wilson(successes, of: trials).map {
                    String(format: " [95%% %.3f–%.3f]", $0.lowerBound, $0.upperBound)
                } ?? ""
            }
            return
                "precision \(precisionText)\(interval(truePositives, truePositives + falsePositives)) (TP \(truePositives), FP \(falsePositives)), recall \(recallText)\(interval(truePositives, truePositives + falseNegatives)) (FN \(falseNegatives))"
        }
    }

    /// Replays a labeled corpus through the real clusterer in six-hour steps, as refreshes would, and
    /// reports pairwise precision, recall and false merges per split, language and source. Tuning
    /// must use the "tune" split only; the "holdout" split is the acceptance measurement (#102).
    /// Format: {"articles": [{"id", "title", "description", "source", "published" (ISO 8601),
    /// "event" (label, or absent for singletons), "split" ("tune" or "holdout")}]}.
    @discardableResult
    static func evaluateEventCorpus(
        path: String, selectedSplit: String = "tune", language: String? = nil,
        outputDirectory: String? = nil
    ) async throws -> [String: EventCorpusMetrics] {
        let output = try outputDirectory.map {
            try StoryCorpus.privateDirectory($0).appendingPathComponent("event-replay-\(selectedSplit).json")
        }
        if let output, FileManager.default.fileExists(atPath: output.path) {
            throw StoryCorpus.Failure.invalid("Replay evidence already exists; refusing to score again")
        }
        struct Corpus: Decodable {
            struct Item: Decodable {
                let id: String, title: String, description: String?, source: String, published: Date, event: String?,
                    split: String?
                let url: String?
            }
            let articles: [Item]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var results: [String: EventCorpusMetrics] = [:]
        for split in [selectedSplit] {
            let items = corpus.articles.filter {
                ($0.split ?? "tune") == split
                    && (language == nil
                        || EventMatchKey.language(of: $0.title + "\n" + ($0.description ?? "")) == language)
            }.sorted { ($0.published, $0.id) < ($1.published, $1.id) }
            let articles = items.map { item in
                FeedArticle(
                    storedID: item.id, title: item.title, link: item.url ?? "https://corpus.invalid/\(item.id)",
                    guid: item.id,
                    description: item.description ?? "", pubDate: item.published, source: item.source)
            }
            var passes: [[String: Int]] = []
            let memberships = try await StoryCorpus.eventMemberships(articles: articles) { report in
                passes.append([
                    "processed": report.processed, "joined": report.joined, "created": report.created,
                    "merged": report.merged, "conflicts": report.conflicts,
                    "detached": report.detached,
                ])
            }
            // Per-pair gate values for every labeled or linked pair, ids only: which gate holds a missed pair out,
            // and what a wrong pair passed. Opt-in; the aggregate lines above are the measurement.
            if ProcessInfo.processInfo.environment["NEWS_EVENT_DIAGNOSE"] == "1" {
                var featureCache: [String: EventFeatures] = [:]
                var vectorCache: [String: [Float]] = [:]
                for item in items {
                    featureCache[item.id] = EventFeatures(
                        title: item.title, description: item.description ?? "", date: item.published)
                    if let vector = await SentenceEmbedder.shared.embed(
                        EventFeatures.matchingText(title: item.title, description: item.description ?? ""))
                    {
                        vectorCache[item.id] = vector
                    }
                }
                // The replay's scorer (a candidate model or none under NEWS_PAIR_MODEL=0), else the shipped one; built once.
                let probability =
                    StoryCorpus.pairProbabilityFromEnvironment()
                    ?? { @Sendable a, b in await PairScorer.shared.probability(a, b) }
                for i in items.indices {
                    for j in items.indices where j > i {
                        let gold = items[i].event != nil && items[i].event == items[j].event
                        let linked =
                            memberships[items[i].id] != nil && memberships[items[i].id] == memberships[items[j].id]
                        guard gold || linked, let a = featureCache[items[i].id], let b = featureCache[items[j].id]
                        else { continue }
                        var similarity: Double?
                        if let va = vectorCache[items[i].id], let vb = vectorCache[items[j].id] {
                            similarity = SentenceEmbedder.cosineSimilarity(va, vb)
                        }
                        let diagnosePolicy = StoryCorpus.policyFromEnvironment()
                        var pair = EventMatcher.assess(
                            a, b, policy: diagnosePolicy, embeddingSimilarity: similarity,
                            samePublisher: !items[i].source.isEmpty && items[i].source == items[j].source)
                        // The clusterer's same-publisher gate (NEWS_SAME_PUBLISHER=1), so the printed gate is the real one.
                        if diagnosePolicy.samePublisherRequiresMatch, !pair.isMatch, !items[i].source.isEmpty,
                            items[i].source == items[j].source
                        {
                            pair.isCompatible = false
                        }
                        func input(_ index: Int) -> String {
                            let known = !items[i].source.isEmpty && !items[j].source.isEmpty
                            return EventMatcher.pairModelText(
                                title: items[index].title, description: items[index].description ?? "",
                                gap: abs(items[i].published.timeIntervalSince(items[j].published)),
                                samePublisher: known ? items[i].source == items[j].source : nil, policy: diagnosePolicy)
                        }
                        let pairModel = EventMatcher.needsPairModel(pair) ? await probability(input(i), input(j)) : nil
                        // As the clusterer does: a borderline pair the model confirms at the cutoff is a match.
                        if let pairModel, pairModel >= diagnosePolicy.pairModelThreshold {
                            pair = EventMatcher.modelConfirmed(pair, policy: diagnosePolicy)
                        }
                        pair = EventMatcher.applyingBorderlineFloor(
                            pair, probability: pairModel, policy: diagnosePolicy)
                        let nonPlaceB = b.keywords.union(b.titleNumbers).union(b.tollNumbers)
                        let nonPlaceA = a.keywords.union(a.titleNumbers).union(a.tollNumbers)
                        let primaryDisjoint =
                            (!a.primaryTitleTerms.isEmpty && a.primaryTitleTerms.isDisjoint(with: nonPlaceB))
                            || (!b.primaryTitleTerms.isEmpty && b.primaryTitleTerms.isDisjoint(with: nonPlaceA))
                        let gap = abs(items[i].published.timeIntervalSince(items[j].published)) / 3600
                        print(
                            String(
                                format: "      pair %@+%@ gold=%d linked=%d gap=%.1fh conflict=%@ primaryDisjoint=%d "
                                    + "match=%d compatible=%d borderline=%d specific=%d anchors=%d keywords=%d what=%.2f "
                                    + "score=%.2f cosine=%@ pairModel=%@",
                                items[i].id, items[j].id, gold ? 1 : 0, linked ? 1 : 0, gap,
                                pair.conflict?.rawValue ?? "-", primaryDisjoint ? 1 : 0, pair.isMatch ? 1 : 0,
                                pair.isCompatible ? 1 : 0, pair.isBorderline ? 1 : 0, pair.sharedSpecificAnchors,
                                pair.sharedAnchors, pair.sharedKeywords, pair.what, pair.score,
                                similarity.map { String(format: "%.2f", $0) } ?? "-",
                                pairModel.map { String(format: "%.3f", $0) } ?? "-"))
                    }
                }
            }
            if let output {
                let receipt: [String: Any] = [
                    "split": split, "language": language ?? "all", "matcherVersion": EventMatcher.version,
                    "memberships": memberships, "passes": passes,
                ]
                try StoryCorpus.writePrivate(
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), to: output,
                    replacing: false)
            }
            let predicted = items.map { memberships[$0.id] }
            let languages = items.map {
                EventMatchKey.language(of: $0.title + "\n" + ($0.description ?? "")) ?? "unknown"
            }
            var total = EventCorpusMetrics()
            var byLanguage: [String: EventCorpusMetrics] = [:]
            var bySource: [String: EventCorpusMetrics] = [:]
            for i in items.indices {
                for j in items.indices where j > i {
                    let isPredicted = predicted[i] != nil && predicted[i] == predicted[j]
                    let isGold = items[i].event != nil && items[i].event == items[j].event
                    guard isPredicted || isGold else { continue }
                    total.add(predicted: isPredicted, gold: isGold)
                    byLanguage[languages[i] == languages[j] ? languages[i] : "mixed", default: EventCorpusMetrics()]
                        .add(predicted: isPredicted, gold: isGold)
                    for source in Set([items[i].source, items[j].source]) {
                        bySource[source, default: EventCorpusMetrics()].add(predicted: isPredicted, gold: isGold)
                    }
                }
            }
            var labelsByEvent: [String: Set<String>] = [:]
            for (position, event) in predicted.enumerated() {
                guard let event else { continue }
                labelsByEvent[event, default: []].insert(items[position].event ?? "unlabeled-\(items[position].id)")
            }
            total.impureEvents = labelsByEvent.values.filter { $0.count > 1 }.count
            print(
                "    \(split): \(items.count) articles, \(total.line), \(total.falsePositives) falsely merged pairs in \(total.impureEvents) events"
            )
            for (language, metrics) in byLanguage.sorted(by: { $0.key < $1.key }) {
                print("      language \(language): \(metrics.line)")
            }
            for (source, metrics) in bySource.sorted(by: { $0.key < $1.key }) {
                print("      source \(source): \(metrics.line)")
            }
            if CommandLine.arguments.contains("--export-features") {
                let pairs = try await exportPairFeatures(
                    items: items.map {
                        PairExportItem(
                            id: $0.id, title: $0.title, description: $0.description ?? "", published: $0.published,
                            event: $0.event, source: $0.source)
                    },
                    predicted: predicted, split: split, outputDirectory: outputDirectory)
                print("    exported \(pairs) candidate pairs with features for the fit (#524)")
            }
            var thresholds = EventEmbeddingComparison.sweep
            if split == "holdout" {
                // The holdout is scored at one cutoff chosen on tune, never swept.
                thresholds =
                    ProcessInfo.processInfo.environment["NEWS_EMBEDDING_THRESHOLD"].flatMap { Double($0) }.map { [$0] }
                    ?? []
            }
            let comparisonItems = items.map {
                EventEmbeddingComparison.Item(
                    title: $0.title, description: $0.description ?? "", date: $0.published,
                    event: $0.event, membership: memberships[$0.id])
            }
            EventEmbeddingComparison(items: comparisonItems, thresholds: thresholds).report(split: split)
            results[split] = total
        }
        return results
    }

    /// Every stored pair decision of a library copy with both headlines, publishers, dates, event ids and the reader's
    /// corrections, as `pairs-review.csv` in the private directory (#551). The CSV carries headlines, so it is never
    /// written inside the checkout and never overwritten; a file inside an app container is refused.
    static func exportPairReview(snapshot: String, outputDirectory: String) async throws -> Int {
        guard !snapshot.contains("/Library/Containers/") else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        let file = try StoryCorpus.privateDirectory(outputDirectory).appendingPathComponent("pairs-review.csv")
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let db = DatabaseEngine(path: snapshot)
        try await db.open()
        let rows = try await db.eventRows(
            """
            SELECT p.article_id, p.other_article_id, p.decision, p.reason, p.score, p.matcher_version, p.assessed_at,
                coalesce(p.features, ''), a.source, a.title, a.published_at, coalesce(ma.event_id, ''),
                b.source, b.title, b.published_at, coalesce(mb.event_id, ''),
                EXISTS (SELECT 1 FROM event_inclusions i
                    WHERE i.article_id = p.article_id AND i.other_article_id = p.other_article_id),
                EXISTS (SELECT 1 FROM event_exclusions x
                    WHERE x.article_id = p.article_id AND x.other_article_id = p.other_article_id)
            FROM pair_assessments p
            JOIN articles a ON a.id = p.article_id
            JOIN articles b ON b.id = p.other_article_id
            LEFT JOIN event_members ma ON ma.article_id = a.id
            LEFT JOIN event_members mb ON mb.article_id = b.id
            ORDER BY p.decision, p.score DESC, p.article_id, p.other_article_id;
            """)
        await db.close()
        var lines = [
            "article_id,other_article_id,decision,reason,score,matcher_version,assessed_at,features,"
                + "source_a,title_a,published_a,event_a,source_b,title_b,published_b,event_b,included,excluded"
        ]
        for row in rows {
            lines.append(
                row.enumerated().map { index, value in
                    [7, 8, 9, 12, 13].contains(index) ? quoted(value ?? "") : (value ?? "")
                }.joined(separator: ","))
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        return rows.count
    }

    /// A story of a library copy as the holdout tools read it.
    struct LibraryRow {
        let id: String, title: String, description: String, source: String, date: Date, event: String?
    }

    /// Stories in the three days ending at `now` (by default the copy's newest story), with their live event.
    static func recentLibraryRows(
        _ db: DatabaseEngine, now: Date? = nil
    ) async throws -> (rows: [LibraryRow], newest: Date) {
        let newest: TimeInterval
        if let now {
            newest = now.timeIntervalSince1970
        } else {
            newest =
                try await db.eventRows(
                    "SELECT max(published_at) FROM articles WHERE published_at < ?;",
                    [.real(Date().timeIntervalSince1970 + 86_400)]
                ).first?.first.flatMap { $0 }.flatMap(Double.init) ?? Date().timeIntervalSince1970
        }
        let rows = try await db.eventRows(
            """
            SELECT a.id, a.title, coalesce(a.description, ''), a.source, a.published_at, e.id
            FROM articles a
            LEFT JOIN event_members m ON m.article_id = a.id
            LEFT JOIN events e ON e.id = m.event_id AND e.merged_into IS NULL
            WHERE a.published_at >= ? AND a.published_at <= ? AND \(DatabaseEngine.visibleArticle)
            ORDER BY a.published_at, a.id;
            """, [.real(newest - 3 * 86_400), .real(newest)]
        ).compactMap { row -> LibraryRow? in
            guard let id = row[0], let title = row[1], let published = row[4].flatMap(Double.init) else { return nil }
            return LibraryRow(
                id: id, title: title, description: row[2] ?? "", source: row[3] ?? "",
                date: Date(timeIntervalSince1970: published), event: row[5])
        }
        return (rows, Date(timeIntervalSince1970: newest))
    }

    /// Candidate pairs for the library holdout (#579), as `holdout-candidates.csv` in the private directory: borderline
    /// decisions scored ≥ 0.6, singleton headlines sharing a specific anchor and a keyword with an event member within
    /// 36 h, and pairs of active events sharing two terms (one representative pair each). Each class is drawn in SHA-256
    /// order of the two ids, so a rerun draws the same pairs. Headlines travel with the rows; never written in the checkout.
    static func exportHoldoutCandidates(snapshot: String, outputDirectory: String) async throws -> Int {
        guard !snapshot.contains("/Library/Containers/") else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        let file = try StoryCorpus.privateDirectory(outputDirectory).appendingPathComponent("holdout-candidates.csv")
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func order(_ a: String, _ b: String) -> String {
            SHA256.hash(data: Data((a + b).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let db = DatabaseEngine(path: snapshot)
        try await db.open()
        let (rows, _) = try await recentLibraryRows(db)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = [
            "kind,article_id,other_article_id,evidence,source_a,title_a,published_a,source_b,title_b,published_b"
        ]
        var seen = Set<String>()
        func append(_ kind: String, _ a: LibraryRow, _ b: LibraryRow, _ evidence: String) {
            let (low, high) = a.id < b.id ? (a, b) : (b, a)
            guard seen.insert(low.id + "\n" + high.id).inserted else { return }
            lines.append(
                [
                    kind, low.id, high.id, evidence, quoted(low.source), quoted(low.title),
                    String(low.date.timeIntervalSince1970), quoted(high.source), quoted(high.title),
                    String(high.date.timeIntervalSince1970),
                ].joined(separator: ","))
        }
        // 1. Borderline decisions with a high score, the pairs the rules nearly matched.
        var borderline = try await db.eventRows(
            "SELECT article_id, other_article_id, score FROM pair_assessments WHERE decision = 'borderline' AND score >= 0.6;"
        ).compactMap { row -> (LibraryRow, LibraryRow, String)? in
            guard let a = row[0].flatMap({ byID[$0] }), let b = row[1].flatMap({ byID[$0] }) else { return nil }
            return (a, b, String(format: "borderline %.2f", Double(row[2] ?? "") ?? 0))
        }
        borderline.sort { order($0.0.id, $0.1.id) < order($1.0.id, $1.1.id) }
        for (a, b, evidence) in borderline.prefix(100) { append("borderline", a, b, evidence) }
        // 2. Singletons next to an event they share a specific anchor and a keyword with.
        let features = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0.id, EventFeatures(title: $0.title, description: $0.description, date: $0.date))
            })
        let members = rows.filter { $0.event != nil }
        var singles: [(LibraryRow, LibraryRow, String)] = []
        for single in rows where single.event == nil {
            guard let features1 = features[single.id] else { continue }
            var best: (LibraryRow, Int)?
            for member in members where abs(member.date.timeIntervalSince(single.date)) <= 36 * 3600 {
                guard let features2 = features[member.id],
                    !features1.specificAnchors.isDisjoint(with: features2.specificAnchors)
                else { continue }
                let shared = features1.keywords.intersection(features2.keywords).count
                if shared >= 1, shared > (best?.1 ?? 0) { best = (member, shared) }
            }
            if let best { singles.append((single, best.0, "singleton shares \(best.1) keywords")) }
        }
        singles.sort { order($0.0.id, $0.1.id) < order($1.0.id, $1.1.id) }
        for (a, b, evidence) in singles.prefix(60) { append("singleton", a, b, evidence) }
        // 3. Fragments: two active events sharing two terms, represented by their earliest members.
        let events = Dictionary(grouping: members) { $0.event ?? "" }
        let terms = events.mapValues { group in
            group.reduce(into: Set<String>()) { set, row in
                if let value = features[row.id] { set.formUnion(value.specificAnchors.union(value.keywords)) }
            }
        }
        var fragments: [(LibraryRow, LibraryRow, String)] = []
        let ids = events.keys.sorted()
        for (n, first) in ids.enumerated() {
            for second in ids[(n + 1)...] {
                let shared = (terms[first] ?? []).intersection(terms[second] ?? []).count
                guard shared >= 2, let a = events[first]?.min(by: { $0.date < $1.date }),
                    let b = events[second]?.min(by: { $0.date < $1.date }),
                    abs(a.date.timeIntervalSince(b.date)) <= 36 * 3600
                else { continue }
                fragments.append((a, b, "fragments share \(shared) terms"))
            }
        }
        fragments.sort { order($0.0.id, $0.1.id) < order($1.0.id, $1.1.id) }
        for (a, b, evidence) in fragments.prefix(60) { append("fragments", a, b, evidence) }
        await db.close()
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        return lines.count - 1
    }

    /// One clustering pass's stages (#691), in seconds; matching is what the fragment merge and story pass leave of the total.
    static func stageLine(_ stages: EventClusteringStages) -> String {
        func value(_ seconds: Double) -> String { String(format: "%.2f", seconds) }
        let matching = stages.total - stages.fragmentMerge - stages.storyPass
        return "total \(value(stages.total)) s = matching \(value(matching)) + fragment merge "
            + "\(value(stages.fragmentMerge)) + story pass \(value(stages.storyPass)); across them: features "
            + "\(value(stages.features)), embeddings \(value(stages.embeddings)) (\(stages.embeddedRows) rows), rules "
            + "\(value(stages.ruleAssessment)), pair model \(value(stages.pairModel)) (\(stages.pairModelCalls) calls), "
            + "writes \(value(stages.writes)), candidate search \(value(stages.candidateSearch)), event reads "
            + "\(value(stages.eventReads)), match commits \(value(stages.matchCommits))"
    }

    /// The admission verdict of a matched pair the clustering kept apart (#737, `NEWS_EVENT_DIAGNOSE=1`, local console
    /// only): each article's event, and whether the article would enter the other's event as that event stands now, with
    /// the rules that refuse it and the cross-pairs behind them. Assessed like the clusterer's own pass, so a verdict
    /// describes the final membership; the greedy pass may have refused against fewer members.
    static func printAdmissionVerdict(
        _ a: String, _ b: String, memberships: [String: String], in db: DatabaseEngine, policy: EventMatchPolicy,
        calibration: PairCalibration?, titles: [String: String]
    ) async throws {
        var eventMembers: [String: [EventMatchRow]] = [:]
        for id in [memberships[a], memberships[b]].compactMap({ $0 }) where eventMembers[id] == nil {
            eventMembers[id] = try await db.eventMatchMembers(eventID: id)?.members ?? []
        }
        let rows = try await db.eventMatchRows(articleIDs: [a, b])
        let everyRow = rows + eventMembers.values.flatMap { $0 }
        let ids = Array(Set(everyRow.map(\.id)))
        let stored = try await db.fetchArticleFeatures(articleIDs: ids, version: EventFeatures.storageVersion)
        let vectors = try await db.fetchArticleEmbeddings(articleIDs: ids, modelVersion: SentenceEmbedder.modelVersion)
        func features(_ row: EventMatchRow) -> EventFeatures {
            var value =
                stored[row.id] ?? EventFeatures(title: row.title, description: row.description, date: row.date)
            value.date = row.date
            return value
        }
        let probability =
            StoryCorpus.pairProbabilityFromEnvironment()
            ?? { @Sendable a, b in await PairScorer.shared.probability(a, b) }
        func assessed(_ a: EventMatchRow, _ b: EventMatchRow) async -> (pair: EventPairAssessment, model: Double?) {
            let cosine = vectors[a.id].flatMap { left in
                vectors[b.id].map { SentenceEmbedder.cosineSimilarity(left, $0) }
            }
            let samePublisher = !a.source.isEmpty && a.source == b.source
            var pair = EventMatcher.assess(
                features(a), features(b), policy: policy, embeddingSimilarity: cosine, samePublisher: samePublisher)
            var model: Double?
            if EventMatcher.needsPairModel(pair) {
                let gap: TimeInterval? = policy.pairModelPrefix ? abs(a.date.timeIntervalSince(b.date)) : nil
                let known = policy.pairModelPrefix && !a.source.isEmpty && !b.source.isEmpty
                model = await probability(
                    EventMatcher.pairModelText(
                        title: a.title, description: a.description, gap: gap,
                        samePublisher: known ? samePublisher : nil, policy: policy),
                    EventMatcher.pairModelText(
                        title: b.title, description: b.description, gap: gap,
                        samePublisher: known ? samePublisher : nil, policy: policy))
                let cutoff =
                    calibration?.cutoff(
                        policy.pairModelThreshold,
                        PairCalibration.features(
                            pairModel: model ?? 0, cosine: pair.embeddingCosine,
                            sharedSpecific: pair.sharedSpecificAnchors,
                            gapHours: abs(a.date.timeIntervalSince(b.date)) / 3600,
                            sameAct: pair.conflict != .differentAct)) ?? policy.pairModelThreshold
                if let model, model >= cutoff { pair = EventMatcher.modelConfirmed(pair, policy: policy) }
                pair = EventMatcher.applyingBorderlineFloor(pair, probability: model, policy: policy)
            }
            if policy.samePublisherRequiresMatch, !pair.isMatch, samePublisher { pair.isCompatible = false }
            if policy.editionAdmission {
                pair.rowIsEdition = EventMatcher.isNewsletterEdition(title: a.title)
                pair.memberIsEdition = EventMatcher.isNewsletterEdition(title: b.title)
            }
            return (pair, model)
        }
        for (label, id, other) in [("a", a, b), ("b", b, a)] {
            guard let row = rows.first(where: { $0.id == id }) else { continue }
            let event = memberships[id]
            let size = event.flatMap { eventMembers[$0]?.count } ?? 0
            print("        \(label) in \(event ?? "no event") (\(size) members)")
            guard let target = memberships[other], let members = eventMembers[target] else {
                print("        \(label) into the other's event: the other holds no event")
                continue
            }
            var assessments: [(member: EventMatchRow, pair: EventPairAssessment, model: Double?)] = []
            for member in members.sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }) {
                let (pair, model) = await assessed(row, member)
                assessments.append((member, pair, model))
            }
            let pairs = assessments.map(\.pair)
            let score = EventMatcher.eventScore(pairs: pairs, policy: policy)
            let failures = admissionFailures(pairs, policy: policy)
            print(
                "        \(label) into the other's event: "
                    + (score.map { "admitted, score \(String(format: "%.2f", $0))" }
                        ?? "refused: \(failures.joined(separator: "; "))"))
            // ponytail: the first twelve refusing cross-pairs; the counts above cover a larger event.
            let refusing = assessments.filter { !$0.pair.isCompatible || $0.pair.conflict != nil }
            for item in refusing.prefix(12) {
                let pair = item.pair
                print(
                    "          x \(titles[item.member.id] ?? item.member.id)\n"
                        + "            \(pair.conflict?.rawValue ?? "no conflict") match=\(pair.isMatch ? 1 : 0) "
                        + "compatible=\(pair.isCompatible ? 1 : 0) specific=\(pair.sharedSpecificAnchors) "
                        + "score=\(String(format: "%.2f", pair.score)) "
                        + "cosine=\(pair.embeddingCosine.map { String(format: "%.2f", $0) } ?? "-") "
                        + "model=\(item.model.map { String(format: "%.3f", $0) } ?? "-")")
            }
            if refusing.count > 12 { print("          … \(refusing.count - 12) more refusing cross-pairs") }
        }
    }

    /// The rules of `EventMatcher.eventScore(pairs:policy:)` a set of cross-pairs fails, in words.
    static func admissionFailures(_ allPairs: [EventPairAssessment], policy: EventMatchPolicy) -> [String] {
        var failures: [String] = []
        if allPairs.count >= policy.maximumEventSize { failures.append("event full") }
        let pairs = EventMatcher.admissionPairs(allPairs, policy: policy)
        if EventMatcher.conflictsBlock(pairs, policy: policy) {
            let conflicts = Dictionary(grouping: pairs.compactMap(\.conflict), by: \.rawValue).mapValues(\.count)
            let named = conflicts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            failures.append("veto \(pairs.filter { $0.conflict != nil }.count)/\(pairs.count) (\(named))")
        }
        let nameless = pairs.filter { $0.sharedSpecificAnchors < 1 && !$0.modelConfirmed }.count
        if nameless > 0 { failures.append("no shared name \(nameless)/\(pairs.count)") }
        if !pairs.contains(where: \.isMatch) { failures.append("no matched pair") }
        let required = Int((Double(pairs.count) * policy.compatibleShare).rounded(.up))
        let compatible = pairs.filter(\.isCompatible).count
        if compatible < required { failures.append("two-thirds \(compatible)/\(pairs.count), needs \(required)") }
        let mean = pairs.isEmpty ? 0 : pairs.map(\.score).reduce(0, +) / Double(pairs.count)
        if mean < policy.eventScore {
            failures.append("mean \(String(format: "%.2f", mean)) below \(policy.eventScore)")
        }
        return failures
    }

    /// The library holdout (#579): `NEWS_LIBRARY_HOLDOUT` is a JSON array of `{"a", "b", "label"}` with article ids of
    /// `NEWS_SNAPSHOT_DB` and labels `same`, `related` or `different`. A temporary copy of the library is re-clustered
    /// from scratch inside the active window (events, memberships, match state, pair decisions and corrections removed;
    /// stored signals and vectors kept), then every labelled pair is scored twice (#627): strict event (both stories in
    /// one event; `same` is a true pair, `related` or `different` a false one, `different` also counted alone) and story
    /// level (both stories' events in one `story_id`; `same` and `related` are true pairs, only `different` is a false
    /// merge). Also prints the share of recent stories shown in a multi-publisher event. The copy is deleted afterwards.
    static func evaluateLibraryHoldout(snapshot: String, holdout: String) async throws {
        guard !snapshot.contains("/Library/Containers/") else {
            throw StoryCorpus.Failure.invalid("Evaluate on a copy of the library, never the live file")
        }
        struct Pair: Decodable {
            let a: String, b: String, label: String
        }
        let pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: URL(fileURLWithPath: holdout)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite3").path
        try StoryCorpus.writableCopy(of: snapshot, to: copy)
        let db = DatabaseEngine(path: copy)
        try await db.open()
        // The reader's verdicts (#552) are read before the corrections are cleared: the matcher alone must keep every
        // "Same Event" pair together and every "Not the Same Event" pair apart, or the change fails the gate.
        let verdicts = try await db.eventRows(
            """
            SELECT article_id, other_article_id, 1 FROM event_inclusions
            UNION ALL SELECT article_id, other_article_id, 0 FROM event_exclusions;
            """
        ).compactMap { row -> (a: String, b: String, same: Bool)? in
            guard let a = row[0], let b = row[1] else { return nil }
            return (a, b, row[2] == "1")
        }
        // The calibration the app would apply (#629) is read before the verdicts and pair decisions are cleared and
        // handed to every pass, so the holdout measures the cutoff production uses.
        let calibrationRows = try await db.calibrationRows()
        for table in [
            "event_overview_citations", "event_overviews", "event_state", "event_members", "event_match_state",
            "pair_assessments", "event_exclusions", "event_inclusions", "events",
        ] {
            try await db.eventRows("DELETE FROM \(table);")
        }
        // NEWS_HOLDOUT_COLD=1 (#691) also drops the stored signals and vectors, as a clear or a version bump of them does.
        if ProcessInfo.processInfo.environment["NEWS_HOLDOUT_COLD"] == "1" {
            for table in ["article_features", "article_embeddings"] { try await db.eventRows("DELETE FROM \(table);") }
        }
        // NEWS_HOLDOUT_NOW=<epoch> pins the clock to when the holdout was drawn, for a copy taken later (#688).
        let pinned = ProcessInfo.processInfo.environment["NEWS_HOLDOUT_NOW"].flatMap { TimeInterval($0) }
            .map { Date(timeIntervalSince1970: $0) }
        let newest = try await recentLibraryRows(db, now: pinned).newest
        let policy = StoryCorpus.policyFromEnvironment()
        let modelOff = ProcessInfo.processInfo.environment["NEWS_PAIR_MODEL"] == "0"
        let candidate = ProcessInfo.processInfo.environment["NEWS_PAIR_MODEL_PATH"]
        let started = Date()
        var passes = 0
        var total = EventClusteringReport()
        repeat {
            let report = try await EventClusterer.run(
                in: db, matchPolicy: policy, now: newest, allowsEnergy: true,
                pairProbability: StoryCorpus.pairProbabilityFromEnvironment(),
                storyProbabilities: StoryCorpus.storyProbabilitiesFromEnvironment(), calibrationRows: calibrationRows)
            passes += 1
            total.processed += report.processed
            total.joined += report.joined
            total.created += report.created
            total.merged += report.merged
            total.stages.add(report.stages)
            print("    pass \(passes): processed \(report.processed), \(stageLine(report.stages))")
            if report.processed == 0 || passes >= 20 { break }
        } while true
        let elapsed = Date().timeIntervalSince(started)
        print("    stages: \(stageLine(total.stages))")
        let memberships = try await db.eventIDs(
            forArticles: pairs.flatMap { [$0.a, $0.b] } + verdicts.flatMap { [$0.a, $0.b] })
        var verdictFailures: [String] = []
        for verdict in verdicts {
            let linked = memberships[verdict.a] != nil && memberships[verdict.a] == memberships[verdict.b]
            if linked != verdict.same {
                verdictFailures.append(
                    "\(verdict.same ? "inclusion separated" : "exclusion re-merged"): \(verdict.a) + \(verdict.b)")
            }
        }
        var storyOf: [String: String] = [:]
        for row in try await db.eventRows("SELECT id, coalesce(story_id, id) FROM events WHERE merged_into IS NULL;") {
            if let id = row[0], let story = row[1] { storyOf[id] = story }
        }
        var truePairs = 0
        var falsePairs = 0
        var missed = 0
        var keptApart = 0
        var byLabel: [String: (linked: Int, total: Int)] = [:]
        var inStory: [String: (linked: Int, total: Int)] = [:]
        // NEWS_EVENT_DIAGNOSE=1 names the misses and the wrong links with their headlines (local console only).
        let diagnose = ProcessInfo.processInfo.environment["NEWS_EVENT_DIAGNOSE"] == "1"
        var titles: [String: String] = [:]
        if diagnose {
            for row in try await db.eventRows("SELECT id, source || ': ' || title FROM articles;") {
                if let id = row[0] { titles[id] = row[1] ?? "" }
            }
        }
        for (pairNumber, pair) in pairs.enumerated() {
            let linked = memberships[pair.a] != nil && memberships[pair.a] == memberships[pair.b]
            byLabel[pair.label, default: (0, 0)].total += 1
            if linked { byLabel[pair.label, default: (0, 0)].linked += 1 }
            let story = memberships[pair.a].map { storyOf[$0] ?? $0 }
            let storyLinked = story != nil && story == memberships[pair.b].map { storyOf[$0] ?? $0 }
            inStory[pair.label, default: (0, 0)].total += 1
            if storyLinked { inStory[pair.label, default: (0, 0)].linked += 1 }
            switch (pair.label == "same", linked) {
            case (true, true): truePairs += 1
            case (true, false): missed += 1
            case (false, true): falsePairs += 1
            case (false, false): keptApart += 1
            }
            if diagnose, storyLinked, !linked, pair.label == "different" {
                print("      WRONG STORY [different] \(titles[pair.a] ?? pair.a) || \(titles[pair.b] ?? pair.b)")
            }
            if diagnose, (pair.label == "same") != linked {
                let (low, high) = pair.a < pair.b ? (pair.a, pair.b) : (pair.b, pair.a)
                let decision = try await db.eventRows(
                    "SELECT decision, reason, coalesce(features, '') FROM pair_assessments WHERE article_id = ? AND other_article_id = ?;",
                    [.text(low), .text(high)]
                ).first
                print(
                    "      \(linked ? "WRONG LINK" : "MISSED") [\(pair.label)] \(titles[pair.a] ?? pair.a) || "
                        + "\(titles[pair.b] ?? pair.b)\n        decision \(decision?[0] ?? "none") \(decision?[1] ?? "") "
                        + "\(decision?[2] ?? "")")
                if !linked, decision?[0] == "match" {
                    print("        pair \(pairNumber) a \(pair.a) b \(pair.b)")
                    try await printAdmissionVerdict(
                        pair.a, pair.b, memberships: memberships, in: db, policy: policy,
                        calibration: PairCalibration.fit(calibrationRows), titles: titles)
                }
            }
        }
        let precision = truePairs + falsePairs == 0 ? 0 : Double(truePairs) / Double(truePairs + falsePairs)
        let recall = truePairs + missed == 0 ? 0 : Double(truePairs) / Double(truePairs + missed)
        // Story-level view: recent stories shown in an event with two or more publishers, and in a story (#581).
        let recent = try await recentLibraryRows(db, now: newest).rows
        let sources = Dictionary(grouping: recent.filter { $0.event != nil }) { $0.event ?? "" }
            .mapValues { Set($0.map(\.source)).count }
        let multi = recent.filter { ($0.event.flatMap { sources[$0] } ?? 0) >= 2 }.count
        let byStory = Dictionary(grouping: recent.filter { $0.event != nil }) { storyOf[$0.event ?? ""] ?? "" }
        let storySources = byStory.mapValues { Set($0.map(\.source)).count }
        let multiStory = recent.filter { ($0.event.flatMap { storySources[storyOf[$0] ?? ""] } ?? 0) >= 2 }.count
        // Events per story over every event, not only those with reports in the audit window.
        let eventsOf = Dictionary(grouping: storyOf.keys) { storyOf[$0] ?? "" }.mapValues(\.count)
        let joinedStories = byStory.filter { (eventsOf[$0.key] ?? 0) >= 2 }
        // The feed's cards: one per story, one per report no story holds (#581).
        func card(_ row: LibraryRow) -> String { row.event.map { storyOf[$0] ?? $0 } ?? row.id }
        let cards = Set(recent.map(card)).count
        if let output = ProcessInfo.processInfo.environment["NEWS_EVENT_OUTPUT"] {
            // Every report of the clusterer's window (72 h before its clock, NEWS_HOLDOUT_NOW when set) with its card, for
            // card counts and named cases (#581).
            let windowRows = try await db.eventRows(
                """
                SELECT a.id, a.source, a.published_at, m.event_id, a.title,
                    (SELECT count(*) FROM event_members x WHERE x.event_id = m.event_id)
                FROM articles a LEFT JOIN event_members m ON m.article_id = a.id
                WHERE a.published_at >= ? AND a.published_at <= ? AND \(DatabaseEngine.visibleArticle)
                ORDER BY a.published_at, a.id;
                """, [.real(newest.timeIntervalSince1970 - 3 * 86_400), .real(newest.timeIntervalSince1970)])
            let cardLines =
                ["card,article,source,published,event,event_size,title"]
                + windowRows.map { row in
                    let card = row[3].map { storyOf[$0] ?? $0 } ?? row[0] ?? ""
                    // Every field is quoted: ids and sources are free text ("Example, Inc.").
                    func quoted(_ value: String?) -> String {
                        "\"" + (value ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    }
                    return ([card, row[0], row[1], row[2], row[3], row[5], row[4]].map(quoted)).joined(separator: ",")
                }
            try StoryCorpus.writePrivate(
                Data(cardLines.joined(separator: "\n").utf8),
                to: try StoryCorpus.privateDirectory(output).appendingPathComponent("story-cards.csv"),
                replacing: false)
            // One line per story that joins two or more events: each event's earliest headline within the window,
            // for the group review.
            // Countries named in headlines (#737): a story whose events name disjoint countries ("Jordan" beside "US")
            // is flagged cross_country for the review; so is an event whose reports do.
            func headlineCountries(_ rows: [LibraryRow]) -> Set<String> {
                rows.reduce(into: Set<String>()) {
                    $0.formUnion(EventFeatures(title: $1.title, description: "", date: $1.date).countries)
                }
            }
            func disjointCountries(_ sets: [Set<String>]) -> Bool {
                let named = sets.filter { !$0.isEmpty }
                return named.indices.contains { i in named.indices.contains { j in named[i].isDisjoint(with: named[j]) }
                }
            }
            var crossCountryStories = 0
            var lines = ["story_id,events,recent_members,cross_country,countries,recent_acts"]
            for (story, rows) in joinedStories.sorted(by: { $0.key < $1.key }) {
                let groups = Dictionary(grouping: rows) { $0.event ?? "" }.values
                let acts =
                    groups
                    .compactMap { group in
                        group.min(by: { $0.date < $1.date }).map { "\(group.count)× \($0.source): \($0.title)" }
                    }
                    .sorted()
                let countrySets = groups.map { headlineCountries($0) }
                let cross = disjointCountries(countrySets)
                if cross { crossCountryStories += 1 }
                let countries: String = countrySets.map { $0.sorted().joined(separator: " ") }.sorted()
                    .joined(separator: " | ")
                let headlines: String = acts.joined(separator: " || ").replacingOccurrences(of: "\"", with: "\"\"")
                let fields: [String] = [
                    story, String(eventsOf[story] ?? acts.count), String(rows.count), cross ? "yes" : "no",
                    "\"\(countries)\"", "\"\(headlines)\"",
                ]
                lines.append(fields.joined(separator: ","))
            }
            let crossCountryEvents = Dictionary(grouping: recent.filter { $0.event != nil }) { $0.event ?? "" }.values
                .filter { group in disjointCountries(group.map { headlineCountries([$0]) }) }
            print(
                "    cross-country (headline countries disjoint): \(crossCountryStories) of \(joinedStories.count) story groups, "
                    + "\(crossCountryEvents.count) events")
            var eventLines = ["event,reports,countries,headlines"]
            for group in crossCountryEvents {
                eventLines.append(
                    [
                        group.first?.event ?? "", String(group.count),
                        "\""
                            + group.map { headlineCountries([$0]).sorted().joined(separator: " ") }.joined(
                                separator: " | ") + "\"",
                        "\""
                            + group.map { "\($0.source): \($0.title)" }.joined(separator: " || ")
                            .replacingOccurrences(of: "\"", with: "\"\"") + "\"",
                    ].joined(separator: ","))
            }
            try StoryCorpus.writePrivate(
                Data(eventLines.joined(separator: "\n").utf8),
                to: try StoryCorpus.privateDirectory(output).appendingPathComponent("cross-country-events.csv"),
                replacing: false)
            try StoryCorpus.writePrivate(
                Data(lines.joined(separator: "\n").utf8),
                to: try StoryCorpus.privateDirectory(output).appendingPathComponent("story-groups.csv"),
                replacing: false)
        }
        await db.close()
        print(
            String(
                format:
                    "    stories: %d (%.0f%%) recent stories in a multi-publisher story; %d stories join two or more events",
                multiStory, recent.isEmpty ? 0 : 100 * Double(multiStory) / Double(recent.count), joinedStories.count))
        print("    cards: \(cards) for \(recent.count) recent stories (one per story, one per report no story holds)")
        if !verdicts.isEmpty {
            print("    verdicts (#552): \(verdicts.count) in the copy, \(verdictFailures.count) violated")
            for failure in verdictFailures { print("      \(failure)") }
        }
        print(
            String(
                format:
                    "    library holdout: %d pairs, precision %.3f (TP %d, FP %d), recall %.3f (FN %d), kept apart %d",
                pairs.count, precision, truePairs, falsePairs, recall, missed, keptApart))
        for (label, counts) in byLabel.sorted(by: { $0.key < $1.key }) {
            print("      \(label): \(counts.linked) of \(counts.total) linked")
        }
        // The dual gate (#627): strict event and story level, the counts the gate compares.
        let same = byLabel["same"] ?? (0, 0)
        let related = byLabel["related"] ?? (0, 0)
        let different = byLabel["different"] ?? (0, 0)
        let linkedPairs = same.linked + related.linked + different.linked
        print(
            String(
                format: "    strict event: %d linked = %d same, %d related, %d different; precision %.3f, "
                    + "recall %.3f (%d of %d same)",
                linkedPairs, same.linked, related.linked, different.linked,
                linkedPairs == 0 ? 0 : Double(same.linked) / Double(linkedPairs),
                same.total == 0 ? 0 : Double(same.linked) / Double(same.total), same.linked, same.total))
        let storyTrue = (inStory["same"]?.linked ?? 0) + (inStory["related"]?.linked ?? 0)
        let storyFalse = inStory["different"]?.linked ?? 0
        let storyTotal = (inStory["same"]?.total ?? 0) + (inStory["related"]?.total ?? 0)
        print(
            String(
                format: "    story level: %d in one story = %d same or related (%d same, %d related), %d different; "
                    + "precision %.3f, recall %.3f (%d of %d same or related)",
                storyTrue + storyFalse, storyTrue, inStory["same"]?.linked ?? 0, inStory["related"]?.linked ?? 0,
                storyFalse, storyTrue + storyFalse == 0 ? 0 : Double(storyTrue) / Double(storyTrue + storyFalse),
                storyTotal == 0 ? 0 : Double(storyTrue) / Double(storyTotal), storyTrue, storyTotal))
        print(
            String(
                format: "    library: %d recent stories, %d (%.0f%%) in a multi-publisher event; %d passes, "
                    + "processed %d, joined %d, created %d, merged %d, %.1f s; matcher v%d, pair cutoff %.2f%@",
                recent.count, multi, recent.isEmpty ? 0 : 100 * Double(multi) / Double(recent.count), passes,
                total.processed, total.joined, total.created, total.merged, elapsed, EventMatcher.version,
                policy.pairModelThreshold,
                modelOff ? ", pair model off" : (candidate.map { ", pair model \($0)" } ?? "")))
        guard verdictFailures.isEmpty else {
            throw StoryCorpus.Failure.invalid("\(verdictFailures.count) reader verdicts violated (#552)")
        }
    }

    /// Opt-in, local: times one fragment-merge pass (`limit: 0`) over a temporary copy of `NEWS_SNAPSHOT_DB`, with
    /// `now` at the newest event, and prints the merge count (#541, #582). The copy is deleted afterwards; a file
    /// inside an app container is refused, so the live library is never opened.
    static func timeFragmentMerge() async throws {
        guard let snapshot = ProcessInfo.processInfo.environment["NEWS_SNAPSHOT_DB"] else {
            throw StoryCorpus.Failure.invalid("--fragment-merge-timing needs NEWS_SNAPSHOT_DB")
        }
        guard !snapshot.contains("/Library/Containers/") else {
            throw StoryCorpus.Failure.invalid("Measure on a copy of the library, never the live file")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite3").path
        try StoryCorpus.writableCopy(of: snapshot, to: copy)
        let db = DatabaseEngine(path: copy)
        try await db.open()
        let newest =
            try await db.eventRows("SELECT max(updated_at) FROM events WHERE merged_into IS NULL;").first?.first
            .flatMap { $0 }.flatMap(Double.init) ?? Date().timeIntervalSince1970
        let active = try await db.activeEventMembers(
            since: Date(timeIntervalSince1970: newest - EventCandidatePolicy.standard.activeEventLifetime))
        let started = Date()
        let report = try await EventClusterer.run(in: db, now: Date(timeIntervalSince1970: newest), limit: 0)
        let elapsed = Date().timeIntervalSince(started)
        await db.close()
        print(
            String(
                format: "    fragment merge: %d active events, %d members, %d merged in %.2f s",
                active.count, active.reduce(0) { $0 + $1.members.count }, report.merged, elapsed))
    }

    /// One CSV row per pair within the candidate window that shares an anchor or a keyword, or a gold event: the
    /// matcher's pair features, the act classes and the labels, for the offline fit of the decision head (#524). Pairs
    /// without a specific anchor are kept, so the fit can measure that gate. Corpus ids only; no publisher text.
    /// Requires `NEWS_EVENT_OUTPUT` and refuses to overwrite.
    struct PairExportItem {
        let id: String
        let title: String
        let description: String
        let published: Date
        let event: String?
        var source = ""
    }

    static func exportPairFeatures(
        items: [PairExportItem], predicted: [String?], split: String, outputDirectory: String?
    ) async throws -> Int {
        guard let outputDirectory else {
            throw StoryCorpus.Failure.invalid("--export-features needs NEWS_EVENT_OUTPUT")
        }
        let file = try StoryCorpus.privateDirectory(outputDirectory)
            .appendingPathComponent("pair-features-\(split).csv")
        let extracted = items.map { EventFeatures(title: $0.title, description: $0.description, date: $0.published) }
        var vectors: [[Float]?] = Array(repeating: nil, count: items.count)
        if await SentenceEmbedder.shared.isAvailable {
            vectors = await SentenceEmbedder.shared.embedBatch(
                items.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
        }
        var lines = [
            "id_a,id_b,label,predicted_same,gap_hours,what,entity,shared_anchors,shared_specific,shared_keywords,"
                + "toll_agree,number_agree,cosine,act_a,act_b,conflict,is_match,is_borderline"
        ]
        for i in items.indices {
            for j in items.indices where j > i {
                let a = extracted[i]
                let b = extracted[j]
                let gap = abs(a.date.timeIntervalSince(b.date))
                guard gap <= EventCandidatePolicy.standard.window else { continue }
                var cosine: Double? = nil
                if let left = vectors[i], let right = vectors[j] {
                    cosine = SentenceEmbedder.cosineSimilarity(left, right)
                }
                // The clusterer's publisher identity, so edition conflicts and series evidence match it (#688).
                let pair = EventMatcher.assess(
                    a, b, embeddingSimilarity: cosine,
                    samePublisher: !items[i].source.isEmpty && items[i].source == items[j].source)
                let gold = items[i].event != nil && items[i].event == items[j].event
                guard gold || pair.sharedAnchors + pair.sharedKeywords >= 1 else { continue }
                let same = predicted[i] != nil && predicted[i] == predicted[j]
                let tollAgree = !a.tollNumbers.isDisjoint(with: b.tollNumbers)
                let numberAgree = !a.titleNumbers.isDisjoint(with: b.titleNumbers)
                lines.append(
                    [
                        items[i].id, items[j].id, gold ? "1" : "0", same ? "1" : "0",
                        String(format: "%.2f", gap / 3600), String(format: "%.4f", pair.what),
                        String(format: "%.4f", pair.entity), String(pair.sharedAnchors),
                        String(pair.sharedSpecificAnchors), String(pair.sharedKeywords), tollAgree ? "1" : "0",
                        numberAgree ? "1" : "0", cosine.map { String(format: "%.4f", $0) } ?? "",
                        a.actClass.rawValue, b.actClass.rawValue, pair.conflict?.rawValue ?? "",
                        pair.isMatch ? "1" : "0", pair.isBorderline ? "1" : "0",
                    ].joined(separator: ","))
            }
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        return lines.count - 1
    }

    /// Re-clusters a copy of a library from scratch at the current matcher, in the order the stories arrived (#627), so
    /// its events and stories (`story_id`) are the ones this build would make: events, memberships, match state and
    /// pair decisions are cleared, and a clock walks the publication dates in 6 h steps. The copy starts without
    /// articles; each step inserts the stories published by it, with their rows in every table that references them
    /// (corrections once both reports are in), and clusters at that time, so no candidate is a story from after the
    /// clock. Returns the copy, made in `directory`.
    static func reclusteredLibraryCopy(_ path: String, in directory: URL) async throws -> String {
        let copy = directory.appendingPathComponent(UUID().uuidString + ".sqlite3").path
        let source = directory.appendingPathComponent(UUID().uuidString + "-source.sqlite3").path
        try StoryCorpus.writableCopy(of: path, to: copy)
        try StoryCorpus.writableCopy(of: path, to: source)
        // The source is migrated like the copy, so both have the same columns for the row copies below.
        let migrated = DatabaseEngine(path: source)
        try await migrated.open()
        await migrated.close()
        let db = DatabaseEngine(path: copy)
        try await db.open()
        for table in [
            "event_overview_citations", "event_overviews", "event_state", "event_members", "event_match_state",
            "pair_assessments", "events",
        ] {
            try await db.eventRows("DELETE FROM \(table);")
        }
        let date = DatabaseEngine.articleDateOrder
        // Every table that references an article, with its referencing columns; FTS rows follow the articles'
        // triggers, new stories get no match state, so each step's stories are pending, and pair decisions and
        // memberships are this build's own, never the source's.
        var dependents: [(table: String, columns: [String])] = []
        for row in try await db.eventRows(
            """
            SELECT m.name, group_concat(f."from") FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f
            WHERE m.type = 'table' AND f."table" = 'articles' GROUP BY m.name ORDER BY m.name;
            """)
        {
            guard let table = row[0], let columns = row[1],
                ![
                    "article_fts_rows", "event_match_state", "event_members", "event_overview_citations",
                    "pair_assessments",
                ].contains(table)
            else { continue }
            dependents.append((table, columns.split(separator: ",").map(String.init)))
        }
        for dependent in dependents { try await db.eventRows("DELETE FROM \(dependent.table);") }
        try await db.eventRows("DELETE FROM articles;")
        try await db.eventRows("ATTACH DATABASE ? AS src;", [.text(source)])
        let dates = try await db.eventRows("SELECT DISTINCT \(date) FROM src.articles a ORDER BY 1;")
            .compactMap { $0.first.flatMap { $0 }.flatMap(Double.init) }
        let policy = StoryCorpus.policyFromEnvironment()
        var total = EventClusteringReport()
        var steps = 0
        var previous = -Double.infinity
        var index = 0
        while index < dates.count {
            let clock = max(dates[index], previous + 6 * 3600)
            let arriving = "SELECT id FROM src.articles a WHERE \(date) > ? AND \(date) <= ?"
            try await db.eventRows(
                "INSERT INTO articles SELECT * FROM src.articles a WHERE \(date) > ? AND \(date) <= ?;",
                [.real(previous), .real(clock)])
            // A row joins once every report it names is in and one of them arrives now.
            for dependent in dependents {
                let present = dependent.columns.map { "(\($0) IS NULL OR \($0) IN (SELECT id FROM main.articles))" }
                let new = dependent.columns.map { "\($0) IN (\(arriving))" }
                try await db.eventRows(
                    "INSERT OR IGNORE INTO main.\(dependent.table) SELECT * FROM src.\(dependent.table) WHERE "
                        + present.joined(separator: " AND ") + " AND (" + new.joined(separator: " OR ") + ");",
                    Array(repeating: [DatabaseEngine.EventValue.real(previous), .real(clock)], count: new.count)
                        .flatMap { $0 })
            }
            var passes = 0
            repeat {
                let report = try await EventClusterer.run(
                    in: db, matchPolicy: policy, now: Date(timeIntervalSince1970: clock), allowsEnergy: true,
                    pairProbability: StoryCorpus.pairProbabilityFromEnvironment(),
                    storyProbabilities: StoryCorpus.storyProbabilitiesFromEnvironment())
                total.processed += report.processed
                total.created += report.created
                total.merged += report.merged
                passes += 1
                if report.processed == 0 || passes >= 20 { break }
            } while true
            steps += 1
            previous = clock
            while index < dates.count, dates[index] <= clock { index += 1 }
        }
        let stories = try await db.eventRows(
            "SELECT count(DISTINCT coalesce(story_id, id)), count(*) FROM events WHERE merged_into IS NULL;"
        ).first
        try await db.eventRows("DETACH DATABASE src;")
        await db.close()
        try? FileManager.default.removeItem(atPath: source)
        print(
            "    re-clustered \(URL(fileURLWithPath: path).lastPathComponent) at matcher v\(EventMatcher.version): "
                + "\(steps) steps, processed \(total.processed), created \(total.created), merged \(total.merged); "
                + "\(stories?[1] ?? "0") events in \(stories?[0] ?? "0") stories")
        return copy
    }

    /// Writes a sample of stored stories for the topic-classifier audit (#546) to `NEWS_EVENT_OUTPUT/categories.csv`:
    /// id, headline, summary, publisher, the publisher's own category, the category the deterministic classifier
    /// assigns now and the one stored in the library. `NEWS_SNAPSHOT_DB` is a library copy (a file inside an app
    /// container is refused). `NEWS_CATEGORY_SAMPLE` sets the size (default 200) and `NEWS_CATEGORY_SEED` the fixed
    /// pseudo-random order, so the same sample is drawn before and after a rule change; `NEWS_CATEGORY_IDS`, a file
    /// with one story id per line, exports exactly those stories instead, whatever their age. The file carries
    /// headlines, so it goes to the private directory only and is never overwritten; labels are kept beside it, never
    /// in the repository.
    static func exportCategorySample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let snapshot = environment["NEWS_SNAPSHOT_DB"], let output = environment["NEWS_EVENT_OUTPUT"] else {
            throw StoryCorpus.Failure.invalid("--export-categories needs NEWS_SNAPSHOT_DB and NEWS_EVENT_OUTPUT")
        }
        guard !snapshot.contains("/Library/Containers/") else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        let size = Int(environment["NEWS_CATEGORY_SAMPLE"] ?? "") ?? 200
        let seed = environment["NEWS_CATEGORY_SEED"] ?? "546"
        let wanted = try environment["NEWS_CATEGORY_IDS"].map {
            try String(contentsOfFile: $0, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        }
        let file = try StoryCorpus.privateDirectory(output).appendingPathComponent("categories.csv")
        let db = DatabaseEngine(path: snapshot)
        try await db.open()
        let rows = try await db.eventRows(
            """
            SELECT a.id, a.title, coalesce(a.description, ''), a.source, coalesce(a.category, ''), a.content,
                coalesce(e.category, '')
            FROM articles a LEFT JOIN article_enrichment e ON e.article_id = a.id
            WHERE a.published_at >= ? ORDER BY a.id;
            """,
            // A listed sample is exported whatever its age, so it can be measured again on a later day.
            [.real(wanted == nil ? Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970 : 0)])
        await db.close()
        // A fixed pseudo-random order (FNV-1a of the seed and the id), then the first `size` rows.
        func order(_ id: String) -> UInt64 {
            (seed + id).utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let selected: [[String?]]
        if let wanted {
            let byID = Dictionary(rows.compactMap { row in row[0].map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
            selected = wanted.compactMap { byID[$0] }
        } else {
            selected = Array(rows.sorted { order($0[0] ?? "") < order($1[0] ?? "") }.prefix(size))
        }
        var lines = ["id,title,summary,publisher,publisher_category,assigned,stored"]
        for row in selected {
            let title = row[1] ?? ""
            let description = row[2] ?? ""
            let assigned =
                NaturalLanguageTopicClassifier.classifyContent(title: title, description: description, text: row[5])?
                .category ?? NewsCategory.world.rawValue
            lines.append(
                [row[0] ?? "", title, description, row[3] ?? "", row[4] ?? "", assigned, row[6] ?? ""].map(quoted)
                    .joined(separator: ","))
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        print(
            "    exported \(selected.count) of \(rows.count) stories \(wanted == nil ? "from the last 14 days" : "listed") for the category audit (#546)"
        )
    }

    /// Mines labelled pairs for the pair model (#525) from copies of real libraries into `NEWS_EVENT_OUTPUT/pairs.csv`.
    /// `NEWS_SNAPSHOT_DB` lists the copies, colon-separated; a file inside an app container is refused, so the live
    /// library is never opened. Rows follow the three-way contract of `script/training/train_pair_model.py` (#627):
    /// `label` 0 different, 1 related, 2 same; `marginal` empty, or the classes whose summed probability is the target.
    /// Each copy is first re-clustered from scratch by this build (`reclusteredLibraryCopy`), so events and stories
    /// are current. Positives (2): two English reports from different publishers in one event that the current rules
    /// match directly, unless the recorded decision was the pair model's alone (#627: 21% of those were false in the #551
    /// review; a reader verdict or a reviewed label brings such a pair back). Negatives: two reports sharing a specific
    /// name or place 36 h to 7 days apart, which the matcher's window keeps apart by definition (0, marginal `01`: not
    /// one occurrence, possibly a later act of one story); never act-class negatives. Same-day negatives (0, weight 2):
    /// the same within 36 h across two events of two or more members in different stories, only with a hard conflict
    /// (place, figure, period, year, weekday) or a cosine below 0.58, so fragments of one story are not negatives.
    /// Articles of the private corpus (`NEWS_EVENT_CORPUS`, tune and holdout) are left out by URL and headline, and every
    /// article from a day around the corpus dates, so no other report of a corpus event is trained on; the articles of
    /// the library holdout (`holdoutPath`, #579) and any copy of their headlines are left out too. The CSV carries
    /// headline and lead text, so it is written only to the private directory and never overwritten.
    /// The reader's verdicts (#552) come first with weight 5: every "Same Event" pair as same (2) and every "Not the
    /// Same Event" pair as not one occurrence (0, marginal `01`), group `v:<low id>`; a mined row of the same pair is
    /// then skipped. With `verdictsOnly` only those rows are written, as `verdicts.csv`.
    static func exportTrainingPairs(
        snapshots: String, output: String, corpusPath: String, holdoutPath: String? = nil, verdictsOnly: Bool = false
    ) async throws {
        let file = try StoryCorpus.privateDirectory(output)
            .appendingPathComponent(verdictsOnly ? "verdicts.csv" : "pairs.csv")
        struct Corpus: Decodable {
            struct Item: Decodable {
                let title: String, url: String?, published: Date
            }
            let articles: [Item]
        }
        func key(_ title: String) -> String { MuteRules.foldedWords(title).joined(separator: " ") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let corpusTitles = Set(corpus.articles.map { key($0.title) })
        let corpusURLs = Set(corpus.articles.compactMap(\.url))
        // Other publishers' reports of the corpus events stay out too: nothing from a day around its dates is used.
        let dates = corpus.articles.map(\.published)
        let corpusWindow =
            (dates.min() ?? .distantFuture).addingTimeInterval(
                -86400)...(dates.max() ?? .distantPast)
            .addingTimeInterval(86400)
        struct HoldoutPair: Decodable {
            let a: String, b: String
        }
        let holdoutIDs = Set(
            try holdoutPath.map {
                try JSONDecoder().decode([HoldoutPair].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
            }?.flatMap { [$0.a, $0.b] } ?? [])
        struct Row {
            let id: String, title: String, description: String, source: String, date: Date, event: String?
            var text: String { EventFeatures.matchingText(title: title, description: description) }
        }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        // The app's own word pieces travel with each text, so training sees exactly the ids the app will send.
        let tokenizer = try BertWordPieceTokenizer(vocabURL: URL(fileURLWithPath: "Sources/Resources/CoreML/vocab.txt"))
        func pieces(_ text: String) -> String { tokenizer.pieces(text).map { String($0) }.joined(separator: " ") }
        var lines = ["label,group,text_a,text_b,pieces_a,pieces_b,weight,marginal"]
        var seen = Set<String>()
        var excluded = 0
        var holdoutExcluded = 0
        var verdicts = 0
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Every copy of a holdout headline is left out, whichever snapshot holds it and under whichever id: the titles
        // are collected from all snapshots first.
        var holdoutTitles = Set<String>()
        var unresolvedHoldoutIDs = holdoutIDs
        // The live library is refused before anything reads or copies it.
        guard !snapshots.split(separator: ":").contains(where: { $0.contains("/Library/Containers/") }) else {
            throw StoryCorpus.Failure.invalid("Export from a copy of the library, never the live file")
        }
        for path in snapshots.split(separator: ":").map(String.init) where !holdoutIDs.isEmpty {
            let copy = scratch.appendingPathComponent("titles-\(UUID().uuidString).sqlite3").path
            try StoryCorpus.writableCopy(of: path, to: copy)
            let db = DatabaseEngine(path: copy)
            try await db.open()
            for row in try await db.eventRows("SELECT id, title FROM articles;") {
                if let id = row[0], let title = row[1], holdoutIDs.contains(id) {
                    holdoutTitles.insert(key(title))
                    unresolvedHoldoutIDs.remove(id)
                }
            }
            await db.close()
        }
        guard unresolvedHoldoutIDs.isEmpty else {
            throw StoryCorpus.Failure.invalid(
                "Snapshots do not resolve \(unresolvedHoldoutIDs.count) library holdout IDs")
        }
        for path in snapshots.split(separator: ":").map(String.init) {
            // Mined pairs come from this build's events and stories, not the ones stored by an older matcher.
            let db = DatabaseEngine(path: verdictsOnly ? path : try await reclusteredLibraryCopy(path, in: scratch))
            try await db.open()
            var rows: [Row] = []
            let articles = try await db.eventRows(
                """
                SELECT a.id, a.title, coalesce(a.description, ''), a.source, a.published_at,
                    coalesce(a.canonical_url, ''), e.id
                FROM articles a
                LEFT JOIN event_members m ON m.article_id = a.id
                LEFT JOIN events e ON e.id = m.event_id AND e.merged_into IS NULL
                WHERE a.published_at IS NOT NULL;
                """)
            for values in articles {
                guard let id = values[0], let title = values[1], let published = values[4].flatMap({ Double($0) })
                else { continue }
                if holdoutIDs.contains(id) || holdoutTitles.contains(key(title)) {
                    holdoutExcluded += 1
                    continue
                }
                if corpusTitles.contains(key(title)) || corpusURLs.contains(values[5] ?? "")
                    || corpusWindow.contains(Date(timeIntervalSince1970: published))
                {
                    excluded += 1
                    continue
                }
                let row = Row(
                    id: id, title: title, description: values[2] ?? "", source: values[3] ?? "",
                    date: Date(timeIntervalSince1970: published), event: values[6])
                if EventMatchKey.language(of: row.title + "\n" + row.description) == "en" { rows.append(row) }
            }
            let corrections = try await db.eventRows(
                """
                SELECT article_id, other_article_id, 1 FROM event_inclusions
                UNION ALL SELECT article_id, other_article_id, 0 FROM event_exclusions ORDER BY 1, 2;
                """)
            // Pairs the pair model alone linked (#627), keyed low id first like the decisions.
            let modelOnly = Set(
                try await db.eventRows(
                    "SELECT article_id || char(10) || other_article_id FROM pair_assessments "
                        + "WHERE decision = 'match' AND reason = 'pairModel';"
                ).compactMap { $0.first ?? nil })
            // The story of each event (#581); a copy clustered before the story layer has each event as its own story.
            var storyOf: [String: String] = [:]
            let stories = "SELECT id, coalesce(story_id, id) FROM events WHERE merged_into IS NULL;"
            for row in try await db.eventRows(stories) {
                if let id = row[0], let story = row[1] { storyOf[id] = story }
            }
            await db.close()
            let features = rows.map { EventFeatures(title: $0.title, description: $0.description, date: $0.date) }
            let prefixed = StoryCorpus.policyFromEnvironment().pairModelPrefix
            func append(_ label: Int, _ group: String, _ i: Int, _ j: Int, weight: Int = 1, marginal: String = "") {
                let pairKey = [key(rows[i].title) + "|" + rows[i].source, key(rows[j].title) + "|" + rows[j].source]
                    .sorted().joined(separator: "\n")
                if weight == 5 {
                    // A verdict is one article pair: keyed by ids, so two pairs with the same headlines stay
                    // distinct; the text key is taken as well, so the mined row of that pair is skipped.
                    guard seen.insert([rows[i].id, rows[j].id].sorted().joined(separator: "\n")).inserted else {
                        return
                    }
                    seen.insert(pairKey)
                } else {
                    guard seen.insert(pairKey).inserted else { return }
                }
                // The prefix the model reads at run time (#626): the pair's gap and whether one publisher wrote both.
                func input(_ index: Int) -> String {
                    // Unknown stays unknown: an undated article or an empty publisher gives no gap or relation.
                    let dated = rows[i].date != DateParser.unknownDate && rows[j].date != DateParser.unknownDate
                    let known = !rows[i].source.isEmpty && !rows[j].source.isEmpty
                    return prefixed
                        ? EventMatcher.pairModelInput(
                            rows[index].text, gap: dated ? abs(rows[i].date.timeIntervalSince(rows[j].date)) : nil,
                            samePublisher: known ? rows[i].source == rows[j].source : nil) : rows[index].text
                }
                lines.append(
                    [
                        String(label), quoted(group), quoted(input(i)), quoted(input(j)), pieces(input(i)),
                        pieces(input(j)), String(weight), marginal,
                    ].joined(separator: ","))
            }
            let indexByID = Dictionary(rows.indices.map { (rows[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
            for correction in corrections {
                guard let low = correction[0].flatMap({ indexByID[$0] }),
                    let high = correction[1].flatMap({ indexByID[$0] })
                else { continue }
                let before = lines.count
                if correction[2] == "1" {
                    append(2, "v:" + rows[low].id, low, high, weight: 5)
                } else {
                    append(0, "v:" + rows[low].id, low, high, weight: 5, marginal: "01")
                }
                verdicts += lines.count - before
            }
            if verdictsOnly { continue }
            // Positives: events, scored with the same embedding the clusterer uses.
            let members = Dictionary(grouping: rows.indices.filter { rows[$0].event != nil }) { rows[$0].event ?? "" }
            var vectors: [Int: [Float]] = [:]
            for index in members.values.filter({ $0.count >= 2 }).flatMap({ $0 }) {
                vectors[index] = await SentenceEmbedder.shared.embed(rows[index].text)
            }
            func cosine(_ i: Int, _ j: Int) -> Double? {
                vectors[i].flatMap { a in vectors[j].map { SentenceEmbedder.cosineSimilarity(a, $0) } }
            }
            var positives = 0
            var modelOnlySkipped = 0
            for (event, indices) in members where indices.count >= 2 {
                for (n, i) in indices.enumerated() {
                    for j in indices[(n + 1)...] where rows[i].source != rows[j].source {
                        guard EventMatcher.assess(features[i], features[j], embeddingSimilarity: cosine(i, j)).isMatch
                        else { continue }
                        let (low, high) = rows[i].id < rows[j].id ? (rows[i].id, rows[j].id) : (rows[j].id, rows[i].id)
                        if modelOnly.contains(low + "\n" + high) {
                            modelOnlySkipped += 1
                            continue
                        }
                        let before = lines.count
                        append(2, "e:" + event, i, j)
                        positives += lines.count - before
                    }
                }
            }
            // Negatives: a shared specific anchor, too far apart to be one event. Very common anchors are capped.
            var byAnchor: [String: [Int]] = [:]
            for (index, value) in features.enumerated() {
                for anchor in value.specificAnchors { byAnchor[anchor, default: []].append(index) }
            }
            var candidates = Set<[Int]>()
            for indices in byAnchor.values {
                let sample =
                    indices.count > 80 ? Array(indices.sorted { rows[$0].id < rows[$1].id }.prefix(80)) : indices
                for (n, i) in sample.enumerated() {
                    // Cross-publisher only, like the positives: otherwise the publisher alone would predict the label.
                    for j in sample[(n + 1)...] where rows[i].source != rows[j].source {
                        let gap = abs(rows[i].date.timeIntervalSince(rows[j].date))
                        guard gap > 36 * 3600, gap <= 7 * 86400 else { continue }
                        if let event = rows[i].event, event == rows[j].event { continue }
                        candidates.insert(i < j ? [i, j] : [j, i])
                    }
                }
            }
            // A fixed pseudo-random order (FNV-1a of the ids), then twice as many negatives as positives.
            func order(_ pair: [Int]) -> UInt64 {
                (rows[pair[0]].id + rows[pair[1]].id).utf8.reduce(14_695_981_039_346_656_037) {
                    ($0 ^ UInt64($1)) &* 1_099_511_628_211
                }
            }
            let negatives = candidates.sorted { order($0) < order($1) }.prefix(2 * positives)
            for pair in negatives { append(0, "n:" + rows[pair[0]].id, pair[0], pair[1], marginal: "01") }
            // Same-day negatives (#625): two reports sharing a specific anchor within 36 h that sit in different
            // events of two or more members each, the same-topic-different-story case the model confuses. Fragments
            // of one story sit in such events too (#627), so only pairs in different stories with a hard conflict or a
            // cosine below 0.58 are kept. They repeat the matcher's own separations, so they weigh 2, not 5 like a
            // reviewed label, and are capped at the number of positives.
            let eventSizes = Dictionary(grouping: rows.indices.filter { rows[$0].event != nil }) {
                rows[$0].event ?? ""
            }
            .mapValues(\.count)
            let hardConflicts: Set<EventConflict> = [.places, .titleNumbers, .period, .year, .weekday, .edition]
            var sameDay = Set<[Int]>()
            for indices in byAnchor.values {
                let sample =
                    indices.count > 80 ? Array(indices.sorted { rows[$0].id < rows[$1].id }.prefix(80)) : indices
                for (n, i) in sample.enumerated() {
                    // Same-publisher pairs stay in: two items of one series in different events are the commonest
                    // false merge (#551), so they are the most useful negatives.
                    for j in sample[(n + 1)...] {
                        guard let a = rows[i].event, let b = rows[j].event, a != b, (eventSizes[a] ?? 0) >= 2,
                            (eventSizes[b] ?? 0) >= 2, rows[i].date != DateParser.unknownDate,
                            rows[j].date != DateParser.unknownDate,
                            abs(rows[i].date.timeIntervalSince(rows[j].date)) <= 36 * 3600,
                            (storyOf[a] ?? a) != (storyOf[b] ?? b)
                        else { continue }
                        // The clusterer's publisher relation, so two editions of one series meet their edition conflict.
                        let conflict = EventMatcher.assess(
                            features[i], features[j],
                            samePublisher: !rows[i].source.isEmpty && rows[i].source == rows[j].source
                        ).conflict
                        guard conflict.map(hardConflicts.contains) == true || (cosine(i, j) ?? 1) < 0.58 else {
                            continue
                        }
                        sameDay.insert(i < j ? [i, j] : [j, i])
                    }
                }
            }
            var sameDayWritten = 0
            for pair in sameDay.sorted(by: { order($0) < order($1) }) where sameDayWritten < positives {
                let before = lines.count
                append(0, "s:" + rows[pair[0]].id, pair[0], pair[1], weight: 2)
                sameDayWritten += lines.count - before
            }
            print(
                "    \(URL(fileURLWithPath: path).lastPathComponent): \(rows.count) English articles, \(positives) positives "
                    + "(\(modelOnlySkipped) pair-model-only links left out), \(negatives.count) negatives, "
                    + "\(sameDayWritten) of \(sameDay.count) clean same-day negatives (#625, #627)"
            )
        }
        try StoryCorpus.writePrivate(Data(lines.joined(separator: "\n").utf8), to: file, replacing: false)
        print(
            "    exported \(lines.count - 1) pairs for the pair model (#525), \(verdicts) of them reader verdicts (#552); "
                + "\(excluded) corpus or corpus-window articles and \(holdoutExcluded) library-holdout articles "
                + "(\(holdoutIDs.count) ids) left out"
        )
    }

    /// Native sentence embeddings against deterministic matching on the same labeled pairs (#127).
    /// Evaluation only: production matching uses no embeddings. Vectors are compared only within one
    /// language, because separate language models share no vector space, and only inside the matcher's
    /// time window, where a deterministic link is possible at all. "Veto" keeps a deterministic link
    /// only when the embeddings agree; "rescue" adds embedding links to it. Scores are pairwise and skip
    /// the whole-event check, so a rescue row overstates what clustering would accept.
    struct EventEmbeddingComparison {
        struct Item {
            let title: String, description: String, date: Date, event: String?, membership: String?
        }
        struct Row {
            let threshold: Double
            var embedding = EventCorpusMetrics(), veto = EventCorpusMetrics(), rescue = EventCorpusMetrics()
        }
        struct Scores {
            var deterministic = EventCorpusMetrics()
            var rows: [Row]
        }
        struct Support {
            var articles = 0
            /// Nil when the system has no sentence embedding for the language.
            let dimension: Int?
        }

        /// Cosine-distance cutoffs swept on the tune split.
        static let sweep = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

        let thresholds: [Double]
        /// Detected languages; articles without a confident language are only counted.
        var languages: [String: Support] = [:]
        var undetected = 0
        /// Per language, plus "all".
        var scores: [String: Scores] = [:]
        /// Labeled or deterministically linked pairs left out of the comparison, by reason.
        var notCompared: [String: Int] = [:]

        init(
            items: [Item], thresholds: [Double], window: TimeInterval = EventMatchPolicy.standard.maximumTimeGap,
            model: (NLLanguage) -> NLEmbedding? = { NLEmbedding.sentenceEmbedding(for: $0) }
        ) {
            self.thresholds = thresholds
            var models: [String: NLEmbedding] = [:]
            var codes: [String?] = []
            var vectors: [[Double]?] = []
            for item in items {
                // As in the deterministic features: the title and the start of the plain description.
                let description = String(
                    item.description.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                        .prefix(EventFeatures.descriptionPrefix))
                let language = EventMatchKey.language(of: item.title + "\n" + item.description)
                codes.append(language)
                guard let code = language else {
                    undetected += 1
                    vectors.append(nil)
                    continue
                }
                if languages[code] == nil {
                    let embedding = model(NLLanguage(rawValue: code))
                    models[code] = embedding
                    languages[code] = Support(dimension: embedding?.dimension)
                }
                languages[code]?.articles += 1
                vectors.append(models[code]?.vector(for: item.title + "\n" + description))
            }

            let empty = Scores(rows: thresholds.map { Row(threshold: $0) })
            for i in items.indices {
                for j in items.indices where j > i {
                    let gold = items[i].event != nil && items[i].event == items[j].event
                    let linked = items[i].membership != nil && items[i].membership == items[j].membership
                    var reason: String?
                    if codes[i] == nil || codes[j] == nil {
                        reason = "unknown language"
                    } else if codes[i] != codes[j] {
                        reason = "cross-language"
                    } else if abs(items[i].date.timeIntervalSince(items[j].date)) > window {
                        reason = "outside time window"
                    } else if vectors[i] == nil || vectors[j] == nil {
                        reason = "no sentence embedding"
                    }
                    guard reason == nil, let code = codes[i], let left = vectors[i], let right = vectors[j] else {
                        if gold || linked, let reason { notCompared[reason, default: 0] += 1 }
                        continue
                    }
                    let distance = Self.cosineDistance(left, right)
                    for key in [code, "all"] {
                        var entry = scores[key] ?? empty
                        entry.deterministic.add(predicted: linked, gold: gold)
                        for index in entry.rows.indices {
                            let close = distance <= entry.rows[index].threshold
                            entry.rows[index].embedding.add(predicted: close, gold: gold)
                            entry.rows[index].veto.add(predicted: linked && close, gold: gold)
                            entry.rows[index].rescue.add(predicted: linked || close, gold: gold)
                        }
                        scores[key] = entry
                    }
                }
            }
        }

        static func cosineDistance(_ left: [Double], _ right: [Double]) -> Double {
            var dot = 0.0
            var leftNorm = 0.0
            var rightNorm = 0.0
            for (x, y) in zip(left, right) {
                dot += x * y
                leftNorm += x * x
                rightNorm += y * y
            }
            guard leftNorm > 0, rightNorm > 0 else { return 2 }
            return 1 - dot / (leftNorm * rightNorm).squareRoot()
        }

        func report(split: String) {
            let skipped = notCompared.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(
                separator: ", ")
            print(
                "    \(split) embeddings (#127): labeled or linked pairs not compared: \(skipped.isEmpty ? "none" : skipped)"
            )
            for (code, support) in languages.sorted(by: { $0.key < $1.key }) {
                let model = support.dimension.map { "\($0)-dimensional sentence embedding" } ?? "no sentence embedding"
                print("      language \(code): \(support.articles) articles, \(model)")
            }
            if undetected > 0 { print("      \(undetected) articles without a confident language") }
            let keys = ["all"] + scores.keys.filter({ $0 != "all" }).sorted()
            for key in keys {
                guard let entry = scores[key] else { continue }
                print("      \(key) deterministic: \(entry.deterministic.line)")
                for row in entry.rows {
                    let cutoff = String(format: "%.2f", row.threshold)
                    print("        distance ≤ \(cutoff) embedding: \(row.embedding.line)")
                    print("        distance ≤ \(cutoff) veto: \(row.veto.line)")
                    print("        distance ≤ \(cutoff) rescue: \(row.rescue.line)")
                }
            }
            if thresholds.isEmpty {
                print("      Set NEWS_EMBEDDING_THRESHOLD to the cutoff chosen on tune to score embeddings on \(split)")
            }
        }
    }

    /// Runs on the main actor: resolving an AppKit-backed Color off the main thread waits on SwiftUI's main-thread
    /// lock, which this runner's main executor never grants, so the check hung.
    @MainActor
    static func testTagTextContrast() {
        // Tinted tag text keeps 4.5:1 on its wash over the page, light and dark, with and without Increase Contrast
        // (#754). The accent path mixes from accent text, so each system accent is checked through that math.
        func srgb(_ color: Color, _ environment: EnvironmentValues, over page: Color.Resolved? = nil) -> NSColor {
            let top = color.resolve(in: environment)
            let alpha = page == nil ? 1 : top.opacity
            func channel(_ value: Float, _ under: Float?) -> CGFloat {
                CGFloat(value * alpha + (under ?? 0) * (1 - alpha))
            }
            return NSColor(
                srgbRed: channel(top.red, page?.red), green: channel(top.green, page?.green),
                blue: channel(top.blue, page?.blue), alpha: 1)
        }
        let accents: [NSColor] = [
            .systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .systemGray,
        ]
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                // System colors resolve differently with Increase Contrast, so each pass resolves under its own setting.
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                environment._colorSchemeContrast = contrast
                let page = AppColor.background.resolve(in: environment)
                let reference = scheme == .dark ? srgb(AppColor.background, environment) : .white
                // The accent branch mixes from accent text, whatever accent the runner has.
                assertEqual(
                    TagView.textColor(tint: AppColor.accent, contrast: contrast).resolve(in: environment),
                    TagView.textColor(tint: AppColor.accentText, contrast: contrast).resolve(in: environment),
                    "Accent tag text mixes from accent text (\(scheme), \(contrast))")
                var pairs: [(String, Color, Color)] = [
                    ("current accent", TagView.textColor(tint: AppColor.accent, contrast: contrast), AppColor.accent)
                ]
                // readableAccent reads the system colors under the current AppKit appearance, so it matches the pass.
                let appearance = NSAppearance(
                    named: scheme == .dark
                        ? (contrast == .increased ? .accessibilityHighContrastDarkAqua : .darkAqua)
                        : (contrast == .increased ? .accessibilityHighContrastAqua : .aqua))
                assertTrue(appearance != nil, "Appearance for \(scheme), \(contrast) exists")
                for accent in accents {
                    var readable = accent
                    appearance?.performAsCurrentDrawingAppearance {
                        readable = AppColor.readableAccent(accent, dark: scheme == .dark, on: reference)
                    }
                    let base = Color(nsColor: readable)
                    pairs.append(
                        ("\(accent)", TagView.textColor(tint: base, contrast: contrast), Color(nsColor: accent)))
                }
                for (name, text, tint) in pairs {
                    let wash = srgb(TagView.fill(tint: tint, contrast: contrast), environment, over: page)
                    assertTrue(
                        AppColor.contrastRatio(srgb(text, environment), wash) >= 4.5,
                        "Tag text on its \(name) wash keeps 4.5:1 (\(scheme), \(contrast))")
                }
            }
        }
    }

    static func testDesignSystemAndArticleFilter() async {
        print("  - Testing Phase 4 Design System Tokens and Article Filter Query Parser...")

        // 1. Spacing tokens
        assertEqual(AppSpacing.xxs, 4.0, "AppSpacing.xxs should be 4.0")
        assertEqual(AppSpacing.xs, 8.0, "AppSpacing.xs should be 8.0")
        assertEqual(AppSpacing.sm, 12.0, "AppSpacing.sm should be 12.0")
        assertEqual(AppSpacing.md, 16.0, "AppSpacing.md should be 16.0")
        assertEqual(AppSpacing.lg, 24.0, "AppSpacing.lg should be 24.0")

        // 2. Radius tokens
        assertEqual(AppRadius.card, 12.0, "AppRadius.card should be 12.0")
        assertEqual(AppRadius.control, 6.0, "AppRadius.control should be 6.0")
        assertEqual(AppRadius.container, 16.0, "AppRadius.container should be 16.0")

        // 3. Layout tokens
        assertEqual(AppLayout.pageInset, 24.0, "AppLayout.pageInset should be 24.0")
        assertEqual(AppLayout.sidebarInset, 12.0, "AppLayout.sidebarInset should be 12.0")
        assertEqual(AppLayout.cardGap, 16.0, "AppLayout.cardGap should be 16.0")
        assertEqual(AppLayout.readingMeasure, 720.0, "AppLayout.readingMeasure should be 720.0")
        assertEqual(AppLayout.listMaxWidth, 1000.0, "AppLayout.listMaxWidth should be 1000.0")
        assertEqual(AppLayout.gridColumnMinimum, 300.0, "AppLayout.gridColumnMinimum should be 300.0")
        assertEqual(AppLayout.gridColumnMaximum, 420.0, "AppLayout.gridColumnMaximum should be 420.0")
        assertEqual(AppSpacing.textStack, 2.0, "AppSpacing.textStack should be 2.0")
        assertEqual(AppSpacing.eyebrowGap, 6.0, "AppSpacing.eyebrowGap should be 6.0")
        assertEqual(AppTypography.eyebrowTracking, 0.5, "AppTypography.eyebrowTracking should be 0.5")

        // 4. Ghost Typography Theme tokens
        assertEqual(AppTypography.bodyLineSpacing(for: .casper), 10.0, "Casper theme line spacing should be 10")
        assertEqual(AppTypography.bodyLineSpacing(for: .edition), 8.0, "Edition theme line spacing should be 8")
        assertEqual(AppTypography.bodyLineSpacing(for: .alto), 12.0, "Alto theme line spacing should be 12")

        await testTagTextContrast()

        // 4. ArticleFilterQuery structured parsing
        let complexQuery = "source:Bloomberg category:Tech is:unread apple silicon"
        let parsed = ArticleFilterQuery.parse(complexQuery)
        assertEqual(parsed.sourceFilter, "bloomberg", "Should parse source: operator")
        assertEqual(parsed.categoryFilter, "tech", "Should parse category: operator")
        assertEqual(parsed.isReadFilter, false, "Should parse is:unread operator")
        assertEqual(parsed.terms, ["apple", "silicon"], "Should extract search terms")

        // 5. Article matching logic
        let art1 = FeedArticle(
            title: "Apple introduces M4 Max Silicon",
            link: "https://bloomberg.com/news/apple-m4",
            guid: "test-art-1",
            description: "New chip delivers record performance",
            pubDate: Date(),
            source: "Bloomberg",
            category: "Technology"
        )
        let art2 = FeedArticle(
            title: "Federal Reserve holds interest rates steady",
            link: "https://wsj.com/fed-rates",
            guid: "test-art-2",
            description: "Central bank maintains current policy stance",
            pubDate: Date(),
            source: "Wall Street Journal",
            category: "Economy"
        )

        assertTrue(parsed.matches(article: art1, isRead: false, isSaved: false), "Article 1 should match query")
        assertFalse(
            parsed.matches(article: art1, isRead: true, isSaved: false), "Article 1 should fail because it is read")
        assertFalse(
            parsed.matches(article: art2, isRead: false, isSaved: false), "Article 2 should fail source/terms match")

        // 6. Settings Pane Bounds and Section Header Tracking (#475)
        assertEqual(AppLayout.settingsPaneWidth, 720.0, "AppLayout.settingsPaneWidth should be 720.0")
        assertEqual(AppLayout.settingsPaneHeight, 560.0, "AppLayout.settingsPaneHeight should be 560.0")
        assertEqual(AppTypography.sectionHeaderTracking, 0.6, "AppTypography.sectionHeaderTracking should be 0.6")

        // 7. ArchiveSearchToken Semantic Display Names and Symbols (#475)
        let unreadToken = ArchiveSearchToken(completedExpression: "is:unread")!
        assertEqual(unreadToken.displayName, "Unread", "Unread token has display name Unread")
        assertEqual(unreadToken.systemImage, "circle.circle", "Unread token uses circle.circle")

        let readToken = ArchiveSearchToken(completedExpression: "is:read")!
        assertEqual(readToken.displayName, "Read", "Read token has display name Read")
        assertEqual(readToken.systemImage, "checkmark.circle", "Read token uses checkmark.circle")

        let savedToken = ArchiveSearchToken(completedExpression: "is:saved")!
        assertEqual(savedToken.displayName, "Saved", "Saved token has display name Saved")
        assertEqual(savedToken.systemImage, "bookmark", "Saved token uses bookmark")

        let sourceToken = ArchiveSearchToken(completedExpression: "source:reuters")!
        assertEqual(sourceToken.displayName, "Source: reuters", "Source token has formatted display name")
        assertEqual(sourceToken.systemImage, "newspaper", "Source token uses newspaper")

        let categoryToken = ArchiveSearchToken(completedExpression: "category:science")!
        assertEqual(categoryToken.displayName, "Category: science", "Category token has formatted display name")
        assertEqual(categoryToken.systemImage, "tag", "Category token uses tag")

        let fallbackToken = ArchiveSearchToken(expression: "custom:term")
        assertEqual(fallbackToken.displayName, "custom:term", "Fallback token keeps raw expression")
        assertEqual(fallbackToken.systemImage, "magnifyingglass", "Fallback token uses magnifyingglass")

        // 8. ArticleSearchState tag search transformations and navigation breadcrumbs (#930)
        // Category token generation and sanitization
        assertEqual(
            ArticleSearchState.sanitizeCategory("Science"),
            "science",
            "Category sanitization lowercases and trims"
        )
        assertEqual(
            ArticleSearchState.sanitizeCategory("category:Science"),
            "science",
            "Category sanitization strips existing category: prefix"
        )
        assertEqual(
            ArticleSearchState.sanitizeCategory("  World  News  "),
            "world-news",
            "Multi-word category converts whitespace runs to hyphens"
        )
        assertEqual(
            ArticleSearchState.sanitizeCategory("Économie & Finance"),
            "économie-&-finance",
            "Category sanitization preserves diacritics"
        )
        assertEqual(
            ArticleSearchState.categoryToken(for: "Science").expression,
            "category:science",
            "Category token produces category: prefix"
        )
        assertEqual(
            ArticleSearchState.categoryToken(for: "Technology").displayName,
            "Category: technology",
            "Category token has human-readable display name"
        )
        assertEqual(
            ArticleSearchState.categoryToken(for: "Science").systemImage,
            "tag",
            "Category token uses tag SF Symbol"
        )

        // Entity phrase query generation and sanitization
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Cold Fusion"),
            "Cold Fusion",
            "Entity sanitization preserves title casing"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("\"Cold Fusion\""),
            "Cold Fusion",
            "Entity sanitization strips existing surrounding quotes"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("“Cold Fusion”"),
            "Cold Fusion",
            "Entity sanitization strips curly quotes"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("«Cold Fusion»"),
            "Cold Fusion",
            "Entity sanitization strips guillemets"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Beyoncé"),
            "Beyoncé",
            "Entity sanitization preserves diacritics"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Apple Inc."),
            "Apple Inc.",
            "Entity sanitization preserves punctuation"
        )
        assertEqual(
            ArticleSearchState.sanitizeEntityName("Dwight \"The Rock\" Johnson"),
            "Dwight 'The Rock' Johnson",
            "Internal double quotes become single quotes"
        )
        assertEqual(
            ArticleSearchState.entityQuery(for: "Cold Fusion"),
            "\"Cold Fusion\"",
            "Entity query wraps name in phrase quotes"
        )
        assertEqual(
            ArticleSearchState.entityQuery(for: "\"Cold Fusion\""),
            "\"Cold Fusion\"",
            "Already quoted entity is not double-quoted"
        )
        assertEqual(
            ArticleSearchState.entityQuery(for: "   "),
            "",
            "Empty entity produces empty query"
        )

        // Combined searchQuery helper and ArticleFilterQuery compatibility
        let catQuery = ArticleSearchState.searchQuery(for: "Science", isCategory: true)
        assertEqual(catQuery.token?.expression, "category:science", "Category query sets token")
        assertEqual(catQuery.text, "", "Category query has empty text")
        assertEqual(catQuery.query, "category:science", "Combined query string matches token")
        let parsedCat = ArticleFilterQuery.parse(catQuery.query)
        assertEqual(parsedCat.categoryFilter, "science", "ArticleFilterQuery extracts category from query")

        let entQuery = ArticleSearchState.searchQuery(for: "Cold Fusion", isCategory: false)
        assertEqual(entQuery.token, nil, "Entity query has no token")
        assertEqual(entQuery.text, "\"Cold Fusion\"", "Entity query wraps phrase in quotes")
        assertEqual(entQuery.query, "\"Cold Fusion\"", "Combined entity query is quoted phrase")
        let parsedEnt = ArticleFilterQuery.parse(entQuery.query)
        assertEqual(parsedEnt.terms, ["cold fusion"], "ArticleFilterQuery retains the entity phrase")
        let mixed = ArticleFilterQuery.parse("climate \"Cold Fusion\" is:unread")
        assertEqual(mixed.terms, ["climate", "cold fusion"], "Mixed words and phrases remain distinct")
        assertEqual(mixed.isReadFilter, false, "An operator outside the phrase still applies")
        assertEqual(ArticleFilterQuery.parse("\"is:read\"").terms, ["is:read"], "A quoted operator is text")

        // State & Navigation breadcrumb round trip
        await MainActor.run {
            let testSearchState = ArticleSearchState()
            assertEqual(testSearchState.isSearching, false, "Initial search state is not searching")
            assertEqual(testSearchState.returnStory, nil, "Initial return story is nil")

            var navPath = NavigationPath()
            let wrapA = FeedArticleWrap(article: art1, contextArticles: [art1, art2])
            navPath.append(wrapA)
            assertEqual(navPath.count, 1, "Navigation path has originating story")

            // Clicking a tag opens search, empties path, saves breadcrumb
            testSearchState.openTag(tag: "Cold Fusion", isCategory: false, from: wrapA, path: &navPath)
            assertEqual(navPath.count, 0, "Navigation path is cleared to reveal search results")
            assertEqual(testSearchState.isSearching, true, "Search state is active")
            assertEqual(testSearchState.searchText, "\"Cold Fusion\"", "Search text holds quoted entity")
            assertEqual(testSearchState.searchPresented, true, "Search is marked presented")
            assertEqual(testSearchState.returnStory?.article.id, art1.id, "Return story points to originating story")
            assertTrue(testSearchState.searchHistory.contains("\"Cold Fusion\""), "Search history records query")

            // Esc or Back returns to story
            testSearchState.returnToStory(path: &navPath)
            assertEqual(navPath.count, 1, "Navigation path restores originating story")
            assertEqual(testSearchState.returnStory, nil, "Return story is cleared on return")
            assertEqual(testSearchState.searchPresented, false, "Search presentation collapses on return")
            assertEqual(testSearchState.searchText, "", "Search text is cleared on return")
            assertTrue(testSearchState.consumeReturnTextChange(""), "Return reset is ignored by the text observer")
            assertFalse(testSearchState.consumeReturnTextChange(""), "A later text edit is not ignored")
            assertTrue(
                testSearchState.searchHistory.contains("\"Cold Fusion\""),
                "Search history keeps query after return")

            // Nested search tags (Story A -> tag search 1 -> Story B -> tag search 2)
            let wrapB = FeedArticleWrap(article: art2, contextArticles: [art2])
            navPath = NavigationPath()
            navPath.append(wrapA)
            testSearchState.openTag(tag: "Science", isCategory: true, from: wrapA, path: &navPath)
            assertEqual(testSearchState.searchTokens.first?.expression, "category:science", "Category token is active")
            assertEqual(testSearchState.returnStory?.article.id, art1.id, "Return story is art1")

            // User opens Story B from search results, then clicks an entity tag
            navPath.append(wrapB)
            testSearchState.openTag(tag: "AI Silicon", isCategory: false, from: wrapB, path: &navPath)
            assertEqual(testSearchState.returnStory?.article.id, art2.id, "Top return story is art2")

            // First Back returns to Story B
            testSearchState.returnToStory(path: &navPath)
            assertEqual(navPath.count, 1, "Restored Story B")

            assertTrue(testSearchState.consumeReturnTextChange(""), "Nested return ignores its text reset")
            // A token search reset is tracked independently from text.
            testSearchState.searchTokens = [ArticleSearchState.categoryToken(for: "Science")]
            // Second Back returns to Story A
            testSearchState.returnToStory(path: &navPath)
            assertEqual(navPath.count, 2, "Restored Story A")
            assertTrue(testSearchState.consumeReturnTokensChange([]), "Return ignores the token reset")
            assertFalse(testSearchState.consumeReturnTokensChange([]), "A later token edit is not ignored")
            assertEqual(testSearchState.returnStory, nil, "Return stack is now empty")

            testSearchState.openTag(tag: "Cold Fusion", isCategory: false, from: wrapA, path: &navPath)
            testSearchState.searchTokens = [ArticleSearchState.categoryToken(for: "Science")]
            testSearchState.returnToStory(path: &navPath)
            testSearchState.cancelPendingReturnChanges()
            assertFalse(testSearchState.consumeReturnTextChange(""), "A real edit cancels text reset suppression")
            assertFalse(testSearchState.consumeReturnTokensChange([]), "A real edit cancels token reset suppression")
        }
    }

    @MainActor
    static func testNewsURLParserAndSchemeRouting() async {
        print("  - Testing NewsURLParser URL Schemes, Insecure HTTP Gating, and Deep Linking...")

        // 1. Standard feed:// scheme normalizes to https://
        let u1 = URL(string: "feed://example.com/rss.xml")!
        let d1 = NewsURLParser.parse(url: u1, allowInsecureHTTP: false)
        assertEqual(
            d1, .addFeed(url: URL(string: "https://example.com/rss.xml")!),
            "Standard feed:// normalizes to https://")

        // 2. feed:https:// scheme
        let u2 = URL(string: "feed:https://example.com/feed.atom")!
        let d2 = NewsURLParser.parse(url: u2, allowInsecureHTTP: false)
        assertEqual(
            d2, .addFeed(url: URL(string: "https://example.com/feed.atom")!),
            "feed:https:// normalizes cleanly")

        // 3. feed://https:// double-slash composite scheme
        let u3 = URL(string: "feed://https://example.com/feed.atom")!
        let d3 = NewsURLParser.parse(url: u3, allowInsecureHTTP: false)
        assertEqual(
            d3, .addFeed(url: URL(string: "https://example.com/feed.atom")!),
            "feed://https:// normalizes cleanly")

        // 4. Insecure HTTP upgrade when allowInsecureHTTP is false
        let u4 = URL(string: "feed:http://insecure.example.com/rss")!
        let d4 = NewsURLParser.parse(url: u4, allowInsecureHTTP: false)
        assertEqual(
            d4, .addFeed(url: URL(string: "https://insecure.example.com/rss")!),
            "feed:http:// upgraded to https:// when insecure HTTP disallowed")

        let u4b = URL(string: "feed://http://insecure.example.com/rss")!
        let d4b = NewsURLParser.parse(url: u4b, allowInsecureHTTP: false)
        assertEqual(
            d4b, .addFeed(url: URL(string: "https://insecure.example.com/rss")!),
            "feed://http:// upgraded to https:// when insecure HTTP disallowed")

        // 5. Insecure HTTP preserved when allowInsecureHTTP is true
        let u5 = URL(string: "feed:http://insecure.example.com/rss")!
        let d5 = NewsURLParser.parse(url: u5, allowInsecureHTTP: true)
        assertEqual(
            d5, .addFeed(url: URL(string: "http://insecure.example.com/rss")!),
            "feed:http:// preserved when insecure HTTP allowed")

        let u5b = URL(string: "feed://http://insecure.example.com/rss")!
        let d5b = NewsURLParser.parse(url: u5b, allowInsecureHTTP: true)
        assertEqual(
            d5b, .addFeed(url: URL(string: "http://insecure.example.com/rss")!),
            "feed://http:// preserved when insecure HTTP allowed")

        // 6. Slashed feeds retain meaningful trailing slash
        let u6 = URL(string: "feed://example.com/feed/")!
        let d6 = NewsURLParser.parse(url: u6, allowInsecureHTTP: false)
        assertEqual(
            d6, .addFeed(url: URL(string: "https://example.com/feed/")!),
            "Meaningful trailing slash preserved")

        // 7. Feeds with custom ports
        let u7 = URL(string: "feed://example.com:8080/feed.xml")!
        let d7 = NewsURLParser.parse(url: u7, allowInsecureHTTP: false)
        assertEqual(
            d7, .addFeed(url: URL(string: "https://example.com:8080/feed.xml")!),
            "Port 8080 preserved in normalized feed URL")

        // 8. Story deep linking: news://story/<id>
        let u8 = URL(string: "news://story/story-uuid-1234")!
        let d8 = NewsURLParser.parse(url: u8, allowInsecureHTTP: false)
        assertEqual(
            d8, .story(id: "story-uuid-1234"),
            "news://story/<id> extracts story ID")

        // 9. Story deep linking with trailing slash
        let u9 = URL(string: "news://story/story-uuid-5678/")!
        let d9 = NewsURLParser.parse(url: u9, allowInsecureHTTP: false)
        assertEqual(
            d9, .story(id: "story-uuid-5678"),
            "Trailing slash trimmed from story ID")

        // 10. Story deep linking with percent encoding
        let u10 = URL(string: "news://story/story%20id%20with%20spaces")!
        let d10 = NewsURLParser.parse(url: u10, allowInsecureHTTP: false)
        assertEqual(
            d10, .story(id: "story id with spaces"),
            "Percent-encoded story ID decoded")

        let u10b = URL(string: "news://story/https%3A%2F%2Fexample.com%2Fstory%25201%2F")!
        assertEqual(
            NewsURLParser.parse(url: u10b, allowInsecureHTTP: false),
            .story(id: "https://example.com/story%201/"),
            "Percent-encoded story ID is decoded exactly once and keeps encoded slashes")

        let u10c = URL(string: "news:story/https://example.com/story%25201")!
        assertEqual(
            NewsURLParser.parse(url: u10c, allowInsecureHTTP: false),
            .story(id: "https://example.com/story%201"),
            "Opaque news:story/ URL keeps double slashes and decodes once")

        // 11. Malformed and empty feeds safely rejected
        assertEqual(NewsURLParser.parse(urlString: "feed:", allowInsecureHTTP: false), nil, "Bare feed: rejected")
        assertEqual(NewsURLParser.parse(urlString: "feed://", allowInsecureHTTP: false), nil, "Bare feed:// rejected")
        assertEqual(NewsURLParser.parse(urlString: "feed:///", allowInsecureHTTP: false), nil, "Bare feed:/// rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed://   ", allowInsecureHTTP: false), nil, "Whitespace feed rejected")

        // 12. Disallowed protocols rejected
        assertEqual(
            NewsURLParser.parse(urlString: "feed:javascript:alert(1)", allowInsecureHTTP: false), nil,
            "javascript: rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed:file:///etc/passwd", allowInsecureHTTP: false), nil, "file: rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed://ftp://example.com/feed", allowInsecureHTTP: false), nil,
            "ftp: rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "feed:data:text/html,bad", allowInsecureHTTP: false), nil, "data: rejected")

        // 13. Malformed news URLs rejected
        assertEqual(
            NewsURLParser.parse(urlString: "news://story", allowInsecureHTTP: false), nil, "Missing ID rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "news://story/", allowInsecureHTTP: false), nil, "Slash with no ID rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "news://article/123", allowInsecureHTTP: false), nil,
            "Wrong host 'article' rejected")
        assertEqual(
            NewsURLParser.parse(urlString: "news://settings/account", allowInsecureHTTP: false), nil,
            "Wrong host 'settings' rejected")

        // 14. Unrelated schemes rejected
        assertEqual(
            NewsURLParser.parse(urlString: "https://example.com/rss", allowInsecureHTTP: false), nil,
            "Direct https scheme rejected by parser")
        assertEqual(
            NewsURLParser.parse(urlString: "http://example.com/rss", allowInsecureHTTP: false), nil,
            "Direct http scheme rejected by parser")
        assertEqual(NewsURLParser.parse(urlString: "", allowInsecureHTTP: false), nil, "Empty string rejected")

        // 15. Duplicate feed prevention
        let suiteName = testDefaultsSuite("test.url.duplicate.prevention")
        let tempDefaults = UserDefaults(suiteName: suiteName)!
        defer { removeTestDefaults(suiteName) }
        let settings = AppSettings(defaults: tempDefaults)

        let addResult1 = settings.addFeed(url: "https://example.com/rss.xml")
        assertEqual(addResult1, "https://example.com/rss.xml", "First feed subscription succeeds")
        assertTrue(settings.hasFeed("https://example.com/rss.xml"), "Settings reports hasFeed as true")

        let addResult2 = settings.addFeed(url: "https://example.com/rss.xml")
        assertEqual(addResult2, nil, "Duplicate subscription attempt returns nil")

        let addResult3 = settings.addFeed(url: "https://example.com/rss.xml/")
        assertEqual(addResult3, nil, "Duplicate subscription attempt with slash variant returns nil")
    }

    @MainActor
    static func testAppIntentsExecutionAndValidation() async {
        print("  - Testing App Intents Execution, Validation, Gating and Resolution...")

        // 1. RefreshFeedsIntent: verify title, openAppWhenRun, isolated execution and dialog
        assertEqual(RefreshFeedsIntent.title, "Refresh Feeds", "RefreshFeedsIntent title is 'Refresh Feeds'")
        assertFalse(RefreshFeedsIntent.openAppWhenRun, "RefreshFeedsIntent does not open app")

        let refreshSuite = testDefaultsSuite("test.intent.refresh")
        let refreshDefaults = UserDefaults(suiteName: refreshSuite)!
        defer { removeTestDefaults(refreshSuite) }
        let refreshSettings = AppSettings(defaults: refreshDefaults)
        let refreshStore = ArticleStore(
            database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await refreshStore.initialize()
        let refreshFeedManager = FeedManager(settings: refreshSettings, store: refreshStore, schedulesRefresh: false)

        let refreshIntent = RefreshFeedsIntent(feedManager: refreshFeedManager)
        do {
            let result = try await refreshIntent.perform()
            let dialogText = extractDialogText(from: result)
            assertTrue(
                dialogText != nil && dialogText!.contains("Feeds refreshed successfully"),
                "RefreshFeedsIntent returns confirmation dialog")
        } catch {
            assertTrue(false, "RefreshFeedsIntent perform threw: \(error)")
        }

        // Test RefreshFeedsIntent via IntentDependencyResolver
        IntentDependencyResolver.feedManagerOverride = refreshFeedManager
        defer { IntentDependencyResolver.feedManagerOverride = nil }
        let defaultRefreshIntent = RefreshFeedsIntent()
        do {
            let result = try await defaultRefreshIntent.perform()
            let dialogText = extractDialogText(from: result)
            assertTrue(
                dialogText != nil && dialogText!.contains("Feeds refreshed successfully"),
                "Default RefreshFeedsIntent uses IntentDependencyResolver")
        } catch {
            assertTrue(false, "Default RefreshFeedsIntent perform threw: \(error)")
        }

        // 2. AddFeedIntent: parameters, validation, duplicate prevention, and insecure HTTP gating
        assertEqual(AddFeedIntent.title, "Add Feed", "AddFeedIntent title is 'Add Feed'")
        assertFalse(AddFeedIntent.openAppWhenRun, "AddFeedIntent does not open app")

        let addSuite = testDefaultsSuite("test.intent.addfeed")
        let addDefaults = UserDefaults(suiteName: addSuite)!
        defer { removeTestDefaults(addSuite) }
        let addSettings = AppSettings(defaults: addDefaults)
        // Adding goes through FeedManager (#798), so the feed is fetched at once; the stub records the fetch.
        let addFetches = TestRecorder()
        let addStore = ArticleStore(
            database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await addStore.initialize()
        let addManager = FeedManager(
            settings: addSettings, store: addStore, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await addFetches.record(urls)
                return urls.map { ($0, [], nil, nil) }
            })
        defer { addManager.stopBackgroundWork() }

        // Valid feed URL with default settings (allowInsecureHTTP = false)
        let validURL = URL(string: "https://example.com/rss.xml")!
        let addIntent1 = AddFeedIntent(url: validURL, feedManager: addManager)
        do {
            let res1 = try await addIntent1.perform()
            assertEqual(res1.value, true, "AddFeedIntent with valid URL returns true")
            assertTrue(addSettings.hasFeed("https://example.com/rss.xml"), "Feed is registered in AppSettings")
            var fetched = false
            for _ in 0..<100 where !fetched {
                fetched = await addFetches.batches.contains { $0.contains("https://example.com/rss.xml") }
                if !fetched { try? await Task.sleep(for: .milliseconds(20)) }
            }
            assertTrue(fetched, "AddFeedIntent fetches the new feed at once through FeedManager")
            let dialog1 = extractDialogText(from: res1)
            assertTrue(
                dialog1 != nil && dialog1!.contains("Subscribed to feed"),
                "AddFeedIntent returns subscription dialog")
        } catch {
            assertTrue(false, "AddFeedIntent 1 threw: \(error)")
        }

        // A later subscription change cancels the run the Shortcut awaits; the action still returns only once the
        // replacement run has collected the new feed.
        let slowSuite = testDefaultsSuite("test.intent.addfeed.slow")
        let slowDefaults = UserDefaults(suiteName: slowSuite)!
        defer { removeTestDefaults(slowSuite) }
        let slowSettings = AppSettings(defaults: slowDefaults)
        let slowFetches = TestRecorder()
        let slowManager = FeedManager(
            settings: slowSettings, store: addStore, schedulesRefresh: false,
            fetchBatch: { urls, _ in
                await slowFetches.record(urls)
                try? await Task.sleep(for: .milliseconds(250))
                return urls.map { ($0, [], nil, nil) }
            })
        defer { slowManager.stopBackgroundWork() }
        let slowAdd = Task { @MainActor in await slowManager.addFeedAndCollect(url: "https://slow.example.com/a.xml") }
        await eventually("Feed A's refresh has started") {
            await slowFetches.batches.contains { $0.contains("https://slow.example.com/a.xml") }
        }
        slowManager.addFeed(url: "https://slow.example.com/b.xml")
        _ = await slowAdd.value
        assertFalse(slowManager.isAnyFeedLoading, "Add Feed returns only after the replacement run has finished")

        // Duplicate subscription rejection
        let addIntentDup = AddFeedIntent(url: validURL, feedManager: addManager)
        do {
            let resDup = try await addIntentDup.perform()
            assertEqual(resDup.value, false, "Duplicate subscription returns false")
            let dialogDup = extractDialogText(from: resDup)
            assertTrue(
                dialogDup != nil && dialogDup!.contains("Could not subscribe"),
                "Duplicate subscription returns failure dialog")
        } catch {
            assertTrue(false, "AddFeedIntent duplicate threw: \(error)")
        }

        // Trailing slash variant is recognized as duplicate
        let slashURL = URL(string: "https://example.com/rss.xml/")!
        let addIntentSlash = AddFeedIntent(url: slashURL, feedManager: addManager)
        do {
            let resSlash = try await addIntentSlash.perform()
            assertEqual(resSlash.value, false, "Trailing slash duplicate returns false")
        } catch {
            assertTrue(false, "AddFeedIntent trailing slash threw: \(error)")
        }

        // Insecure HTTP URL upgraded when allowInsecureHTTP is false
        let httpURL = URL(string: "http://insecure-feed.org/feed.xml")!
        let addIntentHTTP = AddFeedIntent(url: httpURL, feedManager: addManager)
        do {
            let resHTTP = try await addIntentHTTP.perform()
            assertEqual(resHTTP.value, true, "HTTP feed subscription succeeds via HTTPS upgrade")
            assertTrue(addSettings.hasFeed("https://insecure-feed.org/feed.xml"), "Feed was upgraded to HTTPS")
            assertTrue(
                extractDialogText(from: resHTTP)?.contains("https://insecure-feed.org/feed.xml") == true,
                "The dialog names the upgraded address that was subscribed")
            assertFalse(addSettings.hasFeed("http://insecure-feed.org/feed.xml"), "HTTP URL was not preserved")
        } catch {
            assertTrue(false, "AddFeedIntent HTTP upgrade threw: \(error)")
        }

        // Insecure HTTP URL preserved when allowInsecureHTTP is true
        let insecureSuite = testDefaultsSuite("test.intent.insecure")
        let insecureDefaults = UserDefaults(suiteName: insecureSuite)!
        defer { removeTestDefaults(insecureSuite) }
        let insecureSettings = AppSettings(defaults: insecureDefaults)
        insecureSettings.setAllowInsecureHTTP(true)
        let insecureManager = FeedManager(
            settings: insecureSettings, store: addStore, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [], nil, nil) } })
        defer { insecureManager.stopBackgroundWork() }

        let plainHTTPURL = URL(string: "http://plain-http.org/feed.xml")!
        let addIntentPlain = AddFeedIntent(url: plainHTTPURL, feedManager: insecureManager)
        do {
            let resPlain = try await addIntentPlain.perform()
            assertEqual(resPlain.value, true, "Plain HTTP feed subscription succeeds when allowed")
            assertTrue(insecureSettings.hasFeed("http://plain-http.org/feed.xml"), "Plain HTTP URL preserved")
        } catch {
            assertTrue(false, "AddFeedIntent plain HTTP threw: \(error)")
        }

        // Invalid scheme / unparseable URL returns false
        let invalidURL = URL(string: "file:///etc/passwd")!
        let addIntentInvalid = AddFeedIntent(url: invalidURL, feedManager: addManager)
        do {
            let resInvalid = try await addIntentInvalid.perform()
            assertEqual(resInvalid.value, false, "file:// URL scheme rejected")
        } catch {
            assertTrue(false, "AddFeedIntent invalid threw: \(error)")
        }

        // AddFeedIntent via IntentDependencyResolver
        IntentDependencyResolver.feedManagerOverride = addManager
        defer { IntentDependencyResolver.feedManagerOverride = nil }
        let resolverFeedURL = URL(string: "https://resolver-test.com/feed.xml")!
        let resolverAddIntent = AddFeedIntent(url: resolverFeedURL)
        do {
            let resResolver = try await resolverAddIntent.perform()
            assertEqual(resResolver.value, true, "AddFeedIntent uses IntentDependencyResolver feedManagerOverride")
            assertTrue(addSettings.hasFeed("https://resolver-test.com/feed.xml"), "Feed registered via resolver")
        } catch {
            assertTrue(false, "AddFeedIntent resolver threw: \(error)")
        }

        // 3. OpenSectionIntent: AppSection enumeration and navigation routing
        assertEqual(OpenSectionIntent.title, "Open Section", "OpenSectionIntent title is 'Open Section'")
        assertTrue(OpenSectionIntent.openAppWhenRun, "OpenSectionIntent opens app in foreground")

        let sections: [AppSection] = [.today, .unread, .briefing, .savedStories]
        for section in sections {
            var routedSection: AppSection?
            let openIntent = OpenSectionIntent(section: section) { s in
                routedSection = s
            }
            do {
                _ = try await openIntent.perform()
                assertEqual(routedSection, section, "OpenSectionIntent routes to \(section.rawValue)")
            } catch {
                assertTrue(false, "OpenSectionIntent for \(section) threw: \(error)")
            }
        }

        // OpenSectionIntent via IntentDependencyResolver.sectionNavigationHandler
        var ambientRouted: AppSection?
        IntentDependencyResolver.sectionNavigationHandler = { s in
            ambientRouted = s
        }
        defer { IntentDependencyResolver.sectionNavigationHandler = nil }
        let ambientOpenIntent = OpenSectionIntent(section: .briefing)
        do {
            _ = try await ambientOpenIntent.perform()
            assertEqual(ambientRouted, .briefing, "OpenSectionIntent routes through IntentDependencyResolver")
        } catch {
            assertTrue(false, "Ambient OpenSectionIntent threw: \(error)")
        }

        // 4. MarkAllAsReadIntent: unread count clearing, idempotency, and dialog
        assertEqual(MarkAllAsReadIntent.title, "Mark All as Read", "MarkAllAsReadIntent title is 'Mark All as Read'")
        assertFalse(MarkAllAsReadIntent.openAppWhenRun, "MarkAllAsReadIntent does not open app")

        let markStore = ArticleStore(
            database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await markStore.initialize()
        let sample1 = FeedArticle(
            title: "Story 1", link: "https://example.com/1", guid: "g1", description: "D1", pubDate: Date(),
            source: "Publisher")
        let sample2 = FeedArticle(
            title: "Story 2", link: "https://example.com/2", guid: "g2", description: "D2", pubDate: Date(),
            source: "Publisher")
        await markStore.batchUpsert(articles: [sample1, sample2])
        assertEqual(markStore.unreadCount, 2, "2 unread stories before MarkAllAsReadIntent")

        let markIntent = MarkAllAsReadIntent(articleStore: markStore)
        do {
            let resMark = try await markIntent.perform()
            assertEqual(markStore.unreadCount, 0, "Unread count is 0 after MarkAllAsReadIntent")
            let dialogMark = extractDialogText(from: resMark)
            assertTrue(
                dialogMark != nil && dialogMark!.contains("All visible stories marked as read"),
                "MarkAllAsReadIntent returns confirmation dialog")
        } catch {
            assertTrue(false, "MarkAllAsReadIntent perform threw: \(error)")
        }

        // Idempotent execution when unread is already 0
        do {
            let resMark2 = try await markIntent.perform()
            assertEqual(markStore.unreadCount, 0, "Unread count remains 0 on repeat MarkAllAsReadIntent")
            let dialogMark2 = extractDialogText(from: resMark2)
            assertTrue(
                dialogMark2 != nil && dialogMark2!.contains("All visible stories marked as read"),
                "Confirmation dialog returned on idempotent run")
        } catch {
            assertTrue(false, "MarkAllAsReadIntent repeat threw: \(error)")
        }

        // MarkAllAsReadIntent via IntentDependencyResolver
        IntentDependencyResolver.articleStoreOverride = markStore
        defer { IntentDependencyResolver.articleStoreOverride = nil }
        let ambientMarkIntent = MarkAllAsReadIntent()
        do {
            let resAmbientMark = try await ambientMarkIntent.perform()
            let dialogAmbient = extractDialogText(from: resAmbientMark)
            assertTrue(
                dialogAmbient != nil && dialogAmbient!.contains("All visible stories marked as read"),
                "Ambient MarkAllAsReadIntent succeeds via resolver")
        } catch {
            assertTrue(false, "Ambient MarkAllAsReadIntent threw: \(error)")
        }

        // 5. NewBriefingIntent: edition reset and dialog
        assertEqual(NewBriefingIntent.title, "New Briefing", "NewBriefingIntent title is 'New Briefing'")
        assertFalse(NewBriefingIntent.openAppWhenRun, "NewBriefingIntent does not open app")

        var customResetTriggered = false
        let customBriefingIntent = NewBriefingIntent(resetAction: {
            customResetTriggered = true
        })
        do {
            let resBriefing = try await customBriefingIntent.perform()
            assertTrue(customResetTriggered, "NewBriefingIntent custom reset action executed")
            let dialogBriefing = extractDialogText(from: resBriefing)
            assertTrue(
                dialogBriefing != nil && dialogBriefing!.contains("New briefing generated"),
                "NewBriefingIntent dialog confirms generation")
        } catch {
            assertTrue(false, "NewBriefingIntent custom action threw: \(error)")
        }

        // Default NewBriefingIntent resets UserDefaults
        let defaultBriefingIntent = NewBriefingIntent()
        do {
            let resDefaultBriefing = try await defaultBriefingIntent.perform()
            assertTrue(
                UserDefaults.standard.double(forKey: "briefingEditionSelectedAt") > 0,
                "briefingEditionSelectedAt timestamp updated in UserDefaults")
            assertEqual(
                UserDefaults.standard.string(forKey: "briefingEditionArticleIDs"), "",
                "briefingEditionArticleIDs cleared in UserDefaults")
            let dialogDefault = extractDialogText(from: resDefaultBriefing)
            assertTrue(
                dialogDefault != nil && dialogDefault!.contains("New briefing generated"),
                "NewBriefingIntent default execution dialog")
        } catch {
            assertTrue(false, "Default NewBriefingIntent threw: \(error)")
        }
    }

    static func extractDialogText(from result: some IntentResult) -> String? {
        let mirror = Mirror(reflecting: result)
        for child in mirror.children where child.label == "dialog" {
            let desc = String(describing: child.value)
            if desc.starts(with: "nil") || desc == "Optional(nil)" { return nil }
            return desc
        }
        return nil
    }

    private static func shortcutMetadata(from shortcut: AppShortcut) -> (
        shortTitle: String, systemImage: String, phrases: [String]
    ) {
        let mirror = Mirror(reflecting: shortcut)
        var title = ""
        var image = ""
        var phrases: [String] = []
        for child in mirror.children {
            if child.label == "shortTitle" {
                title = String(describing: child.value)
            } else if child.label == "systemImageName" {
                if let opt = child.value as? String? {
                    image = opt ?? ""
                }
            } else if child.label == "basePhraseTemplates" {
                if let list = child.value as? [String] {
                    phrases = list
                }
            }
        }
        return (title, image, phrases)
    }

    @MainActor
    static func testAppShortcutsProviderDeclarations() async {
        print("  - Testing NewsShortcuts AppShortcutsProvider Declarations & Terminology...")

        // 1. Shortcut tile color
        assertEqual(NewsShortcuts.shortcutTileColor, .navy, "NewsShortcuts tile color is navy")

        // 2. Exactly 5 shortcuts
        let shortcuts = NewsShortcuts.appShortcuts
        assertEqual(shortcuts.count, 5, "NewsShortcuts defines exactly 5 App Shortcuts")

        // 3. Inspect each shortcut declaration
        let refreshMeta = shortcutMetadata(from: shortcuts[0])
        assertTrue(refreshMeta.shortTitle.contains("Refresh Feeds"), "Shortcut 0 shortTitle contains 'Refresh Feeds'")
        assertEqual(refreshMeta.systemImage, "arrow.clockwise", "Shortcut 0 icon is arrow.clockwise")
        assertTrue(refreshMeta.phrases.contains("Refresh ${applicationName}"), "Shortcut 0 contains refresh phrase")

        let addFeedMeta = shortcutMetadata(from: shortcuts[1])
        assertTrue(addFeedMeta.shortTitle.contains("Add Feed"), "Shortcut 1 shortTitle contains 'Add Feed'")
        assertEqual(addFeedMeta.systemImage, "plus", "Shortcut 1 icon is plus")

        let openSectionMeta = shortcutMetadata(from: shortcuts[2])
        assertTrue(openSectionMeta.shortTitle.contains("Open Section"), "Shortcut 2 shortTitle contains 'Open Section'")
        assertEqual(openSectionMeta.systemImage, "sidebar.left", "Shortcut 2 icon is sidebar.left")

        let markReadMeta = shortcutMetadata(from: shortcuts[3])
        assertTrue(
            markReadMeta.shortTitle.contains("Mark All as Read"), "Shortcut 3 shortTitle contains 'Mark All as Read'")
        assertEqual(markReadMeta.systemImage, "checkmark.circle", "Shortcut 3 icon is checkmark.circle")

        let newBriefingMeta = shortcutMetadata(from: shortcuts[4])
        assertTrue(newBriefingMeta.shortTitle.contains("New Briefing"), "Shortcut 4 shortTitle contains 'New Briefing'")
        assertEqual(newBriefingMeta.systemImage, "text.book.closed", "Shortcut 4 icon is text.book.closed")

        // 4. Terminology review: ensure strictly 'story'/'stories' and never 'article' in shortcut titles and phrases
        for (idx, shortcut) in shortcuts.enumerated() {
            let meta = shortcutMetadata(from: shortcut)
            assertFalse(
                meta.shortTitle.lowercased().contains("article"),
                "Shortcut [\(idx)] title '\(meta.shortTitle)' must not contain 'article'"
            )
            for phrase in meta.phrases {
                assertFalse(
                    phrase.lowercased().contains("article"),
                    "Shortcut [\(idx)] phrase '\(phrase)' must not contain 'article'"
                )
            }
        }
    }

    final class SocketObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [String] = []
        private var completed = false
        func recordText(_ value: String) { lock.withLock { targets.append(value) } }
        func record(_ host: NWEndpoint.Host) { lock.withLock { targets.append(String(describing: host)) } }
        var count: Int { lock.withLock { targets.count } }
        var hosts: [String] { lock.withLock { targets } }
        func claim() -> Bool {
            lock.withLock {
                if completed { return false }
                completed = true
                return true
            }
        }
    }

    static func socketSend(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    static func socketRead(_ connection: NWConnection, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let next: Data = try await withCheckedThrowingContinuation { continuation in
                let once = SocketObservation()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if once.claim() {
                        connection.cancel()
                        continuation.resume(throwing: LoopbackTimeout())
                    }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) {
                    bytes, _, eof, error in
                    guard once.claim() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let bytes, !bytes.isEmpty {
                        continuation.resume(returning: bytes)
                    } else {
                        continuation.resume(throwing: eof ? FeedError.network("EOF") : LoopbackTimeout())
                    }
                }
            }
            data.append(next)
        }
        return data
    }

    static func socksConnect(_ proxy: NetworkBoundaryProxy, host: String, command: UInt8 = 1, port: UInt16 = 80)
        async throws -> (NWConnection, Data)
    {
        let endpoint = try await proxy.port()
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint)!, using: .tcp)
        // A loopback connect can fail with EADDRINUSE when parallel runs churn ephemeral ports. NWConnection
        // then parks in .waiting and never completes a send, so surface that state instead of hanging.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = SocketObservation()
            client.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .waiting(let error), .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            client.start(queue: .global())
        }
        client.stateUpdateHandler = nil
        try await socketSend(client, Data([5, 1, 0]))
        assertEqual(try await socketRead(client, count: 2), Data([5, 0]), "SOCKS greeting succeeds")
        let hostBytes = Data(host.utf8)
        var request = Data([5, command, 0, 3, UInt8(hostBytes.count)])
        request.append(hostBytes)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 255)])
        // Fragment across every protocol boundary, not just a single network packet.
        try await socketSend(client, Data(request.prefix(1)))
        try await socketSend(client, Data(request.dropFirst()))
        return (client, try await socketRead(client, count: 10))
    }

    /// Hold a real HTTP response open until cancellation closes the upstream socket.
    static func holdCancellationResponse(
        _ connection: NWConnection, ready: SocketObservation,
        closed: SocketObservation, request: Data = Data()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { bytes, _, eof, error in
            guard error == nil, !eof, let bytes else {
                connection.cancel()
                return
            }
            let request = request + bytes
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                holdCancellationResponse(connection, ready: ready, closed: closed, request: request)
                return
            }
            let header = String(decoding: request, as: UTF8.self)
            if header.hasPrefix("GET /drain ") {
                ready.recordText("drain")
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { bytes, _, eof, error in
                    assertTrue(
                        error == nil && eof && (bytes?.isEmpty ?? true),
                        "The proxy forwards the client's write-close before the response")
                    connection.send(
                        content: Data(repeating: 120, count: 65536), contentContext: .finalMessage,
                        completion: .contentProcessed { error in
                            assertTrue(error == nil, "The upstream sends its complete response after request EOF")
                            closed.recordText("drain")
                            connection.cancel()
                        })
                }
                return
            }
            assertTrue(
                header.hasPrefix("GET /headers/") || header.hasPrefix("GET /body/"),
                "Only the cancellation fixture is requested")
            let waitForClose: @Sendable () -> Void = {
                ready.recordText(header)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { _, _, eof, error in
                    assertTrue(eof || error != nil, "Cancellation closes the upstream transport")
                    closed.recordText(header)
                    connection.cancel()
                }
            }
            if header.hasPrefix("GET /body/") {
                // The response starts but cannot complete: only 4 KiB of the declared 1 MiB is sent.
                var response = Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\nContent-Length: 1048576\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                        .utf8)
                response.append(Data(repeating: 32, count: 4096))
                connection.send(
                    content: response,
                    completion: .contentProcessed { error in
                        assertTrue(error == nil, "The partial HTTP body is written before cancellation")
                        waitForClose()
                    })
            } else {
                waitForClose()
            }
        }
    }

    static func redirect(
        _ coordinator: SecureSessionDelegateCoordinator, _ session: URLSession, _ task: URLSessionTask,
        to target: String
    ) async -> URLRequest? {
        let response = HTTPURLResponse(
            url: task.originalRequest!.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": target])!
        return await withCheckedContinuation { continuation in
            coordinator.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)
            ) { continuation.resume(returning: $0) }
        }
    }

    /// A first address that never connects (a broken IPv6 route) falls back to the second well inside the
    /// handshake timeout (#945).
    @MainActor
    static func testGatewayAddressFallback() async throws {
        print("  - Testing the gateway's address fallback: a dead first address yields to the second (#945)...")
        // The dead address connects through a SOCKS proxy that accepts and never answers, so the attempt stays
        // in preparation the way an unanswered SYN does.
        let silent = try NWListener(using: .tcp, on: .any)
        let silentQueue = DispatchQueue(label: "test.fallback.silent")
        let held = SocketObservation()
        let heldClosed = SocketObservation()
        silent.newConnectionHandler = { connection in
            held.recordText("held")
            connection.start(queue: silentQueue)
            recordClose(connection, closed: heldClosed)
        }
        let upstream = try NWListener(using: .tcp, on: .any)
        let upstreamQueue = DispatchQueue(label: "test.fallback.upstream")
        upstream.newConnectionHandler = { connection in
            connection.start(queue: upstreamQueue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, _ in
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        for listener in [silent, upstream] {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = SocketObservation()
                listener.stateUpdateHandler = { state in
                    if case .ready = state, once.claim() { continuation.resume() }
                    if case .failed(let error) = state, once.claim() { continuation.resume(throwing: error) }
                }
                listener.start(queue: listener === silent ? silentQueue : upstreamQueue)
            }
        }
        defer {
            silent.cancel()
            upstream.cancel()
        }
        let observed = SocketObservation()
        let silentPort = silent.port!
        let upstreamPort = upstream.port!
        @Sendable func silentConnection(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> NWConnection {
            let parameters = NWParameters.tcp
            let context = NWParameters.PrivacyContext(description: "test.fallback.silent")
            context.proxyConfigurations = [
                ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: silentPort))
            ]
            parameters.setPrivacyContext(context)
            return NWConnection(host: host, port: port, using: parameters)
        }
        let proxy = NetworkBoundaryProxy(
            resolver: { _ in .allowed(ips: ["2606:4700::1111", "93.184.216.34"]) },
            connector: { host, port in
                observed.record(host)
                if case .ipv6 = host { return silentConnection(host, port) }
                return NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
            })
        let started = ContinuousClock.now
        let (client, reply) = try await socksConnect(proxy, host: "dual.invalid")
        let elapsed = ContinuousClock.now - started
        assertEqual(reply[1], 0, "The second address connects while the first is still waiting")
        assertTrue(elapsed < .seconds(5), "The fallback takes about a quarter second, not the handshake timeout")
        assertEqual(
            observed.hosts, ["2606:4700::1111", "93.184.216.34"], "IPv6 was tried first, IPv4 after the delay")
        assertEqual(held.count, 1, "The dead attempt reached the silent proxy exactly once")
        try await socketSend(client, Data("fallback".utf8))
        assertEqual(try await socketRead(client, count: 8), Data("fallback".utf8), "The tunnel relays over the winner")
        // Before the client closes: only the winner's selection, not the tunnel's shutdown, may close the loser.
        await eventually("The losing attempt is cancelled once the winner connects") { heldClosed.count == 1 }
        client.cancel()
        await proxy.stop()

        // Three stalled attempts fill every slot; the fourth address still starts a stagger later, retiring the
        // oldest, instead of waiting for the handshake timeout.
        let tried = SocketObservation()
        let crowded = NetworkBoundaryProxy(
            resolver: { _ in .allowed(ips: ["93.184.216.1", "93.184.216.2", "93.184.216.3", "93.184.216.4"]) },
            connector: { host, port in
                tried.record(host)
                guard String(describing: host) == "93.184.216.4" else { return silentConnection(host, port) }
                return NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
            })
        let crowdedStart = ContinuousClock.now
        let (crowdedClient, crowdedReply) = try await socksConnect(crowded, host: "crowded.invalid")
        assertEqual(crowdedReply[1], 0, "The fourth address connects while three attempts stall")
        assertTrue(ContinuousClock.now - crowdedStart < .seconds(5), "Stalled attempts do not hold the fourth address")
        assertEqual(tried.hosts.count, 4, "Each address was tried once")
        crowdedClient.cancel()
        await crowded.stop()
    }

    /// Reads until the peer closes, then records the close: EOF or an error both mean the attempt was torn down.
    static func recordClose(_ connection: NWConnection, closed: SocketObservation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { _, _, eof, error in
            if eof || error != nil {
                closed.recordText("closed")
                connection.cancel()
            } else {
                recordClose(connection, closed: closed)
            }
        }
    }

    @MainActor
    static func testTransportCancellation() async throws {
        print("  - Testing refresh shutdown over real HTTP/SOCKS sockets...")
        let upstream = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.cancellation.upstream")
        let ready = SocketObservation()
        let closed = SocketObservation()
        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            holdCancellationResponse(connection, ready: ready, closed: closed)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = SocketObservation()
            upstream.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
                if case .failed(let error) = state, once.claim() { continuation.resume(throwing: error) }
            }
            queue.asyncAfter(deadline: .now() + 5) {
                if once.claim() {
                    upstream.cancel()
                    continuation.resume(throwing: LoopbackTimeout())
                }
            }
            upstream.start(queue: queue)
        }
        defer { upstream.cancel() }
        let port = upstream.port!
        let observed = SocketObservation()
        let proxy = NetworkBoundaryProxy(connector: { host, _ in
            observed.record(host)
            return NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        })
        let (halfClosed, reply) = try await socksConnect(proxy, host: "93.184.216.34")
        assertEqual(reply[1], 0, "The drain control uses the protected socket")
        try await socketSend(halfClosed, Data("GET /drain HTTP/1.1\r\nHost: 93.184.216.34\r\n\r\n".utf8))
        await eventually("The drain fixture receives the request before its write-close") { ready.count == 1 }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            halfClosed.send(
                content: nil, contentContext: .finalMessage,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
        assertEqual(
            try await socketRead(halfClosed, count: 65536), Data(repeating: 120, count: 65536),
            "A half-closed request drains the entire response across relay buffers")
        do {
            _ = try await socketRead(halfClosed, count: 1)
            assertTrue(false, "The response ends with forwarded EOF")
        } catch let error as FeedError {
            assertEqual(error, .network("EOF"), "The upstream write-close reaches the client after all response bytes")
        }
        halfClosed.cancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [try await proxy.configuration()]
        let client = SecureHTTPClient(configuration: configuration)
        var samples: [String: [Double]] = [:]
        for phase in ["headers", "body"] {
            for index in 0..<5 {
                let db = DatabaseEngine(path: ":memory:")
                let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
                await store.initialize()
                let suite = testDefaultsSuite("test.transport-cancellation")
                defer { removeTestDefaults(suite) }
                let defaults = UserDefaults(suiteName: suite)!
                let settings = AppSettings(defaults: defaults)
                let feed = "http://93.184.216.34/\(phase)/\(index).xml"
                settings.feedURLs = [feed]
                settings.allowInsecureHTTP = true
                settings.aiEnabled = false
                let fetcher = FeedFetcher(client: client)
                let manager = FeedManager(
                    settings: settings, store: store, schedulesRefresh: false,
                    fetchBatch: { urls, allowHTTP in
                        await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db)
                    },
                    notifyBatch: { _, _ in })
                let done = SocketObservation()
                let count = ready.count
                let refresh = Task {
                    await manager.fetchFeedsAsync()
                    let end = ContinuousClock.now
                    done.recordText("finished")
                    return end
                }
                await eventually("The real HTTP request reaches the held response") { ready.count == count + 1 }
                assertTrue(manager.isAnyFeedLoading, "A stalled response keeps refresh active")
                assertEqual(done.count, 0, "The incomplete HTTP response cannot finish before shutdown")
                let start = ContinuousClock.now
                manager.stopBackgroundWork()
                await eventually("Shutdown completes without waiting for the network timeout", timeout: .seconds(2)) {
                    done.count == 1
                }
                let duration = start.duration(to: await refresh.value)
                let milliseconds =
                    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                samples[phase, default: []].append(milliseconds)
                await eventually("Shutdown closes the protected upstream socket", timeout: .seconds(2)) {
                    closed.count == count + 1
                }
                assertFalse(manager.isAnyFeedLoading, "Shutdown clears refresh loading")
                assertEqual(try await db.counts().total, 0, "Cancellation ingests no partial articles")
                assertEqual(
                    try await db.feedFetchStates()[feed], nil, "Cancellation records no feed failure or validators")
                await db.close()
            }
        }
        assertEqual(observed.count, 11, "The drain control and each cancellation sample use one protected connection")
        assertTrue(
            observed.hosts.allSatisfy { $0 == "93.184.216.34" },
            "Production resolution pins the public numeric address before fixture routing")
        await proxy.stop()
        let report: [String: Any] = [
            "samples_ms": samples, "samples_per_phase": 5,
            "transport": "URLSession -> production SOCKS proxy -> controlled TCP fixture",
            "response_bytes_sent": 4096, "response_bytes_declared": 1_048_576,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("TRANSPORT_CANCELLATION_REPORT " + String(decoding: data, as: UTF8.self))
    }

    /// Opt-in and live: refreshes the twelve panel feeds over the production client (real DNS, TLS and publishers),
    /// then stops refreshes at staggered offsets so shutdowns land during handshakes, transfers, parsing or ingestion.
    @MainActor
    static func testPublisherCancellation() async throws {
        let feeds = TensionMethodology.v1.panel.map(\.url)
        print("  - Live: refreshing and cancelling \(feeds.count) publisher feeds over HTTPS...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news-publisher-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ label: String, cancelAfter offset: Duration?) async throws -> [String: Any] {
            let path = directory.appendingPathComponent("\(label).sqlite3").path
            let db = DatabaseEngine(path: path)
            let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
            await store.initialize()
            let suite = testDefaultsSuite("test.publisher-cancellation")
            let defaults = UserDefaults(suiteName: suite)!
            defer { removeTestDefaults(suite) }
            let settings = AppSettings(defaults: defaults)
            settings.feedURLs = feeds
            settings.aiEnabled = false
            settings.notificationsEnabled = false
            let fetcher = FeedFetcher()
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, allowHTTP in
                    await fetcher.fetchAllFeeds(urls: urls, allowHTTP: allowHTTP, state: db)
                },
                notifyBatch: { _, _ in
                    // Notifications are off and out of scope for this measurement.
                })
            let done = SocketObservation()
            let started = ContinuousClock.now
            let refresh = Task {
                await manager.fetchFeedsAsync()
                let end = ContinuousClock.now
                done.recordText("finished")
                return end
            }
            var result: [String: Any] = ["label": label]
            if let offset {
                try await Task.sleep(for: offset)
                let finishedFirst = done.count == 1
                result["finished_before_cancel"] = finishedFirst
                let cancelled = ContinuousClock.now
                manager.stopBackgroundWork()
                await eventually("Shutdown of a live refresh completes within its deadline", timeout: .seconds(2)) {
                    done.count == 1
                }
                let end = await refresh.value
                if !finishedFirst { result["stop_ms"] = milliseconds(cancelled.duration(to: end)) }
                assertFalse(manager.isAnyFeedLoading, "Shutdown clears refresh loading")
            } else {
                result["refresh_ms"] = milliseconds(started.duration(to: await refresh.value))
                manager.stopBackgroundWork()
            }
            result["articles"] = try await db.counts().total
            result["feed_states"] = try await db.feedFetchStates().count
            await db.close()
            // Validators are only ever stored with the articles they describe, so a later 304 cannot hide unsaved items.
            var handle: OpaquePointer?
            assertEqual(
                sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK, "Open the temporary library")
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(
                handle,
                """
                SELECT COUNT(*) FROM feeds f WHERE (f.etag IS NOT NULL OR f.last_modified IS NOT NULL)
                AND NOT EXISTS (SELECT 1 FROM article_feeds af WHERE af.feed_url = f.url);
                """, -1, &statement, nil)
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Count validators without articles")
            assertEqual(sqlite3_column_int(statement, 0), 0, "\(label): no feed keeps validators without its articles")
            sqlite3_finalize(statement)
            sqlite3_prepare_v2(handle, "PRAGMA integrity_check;", -1, &statement, nil)
            assertEqual(sqlite3_step(statement), SQLITE_ROW, "Run the integrity check")
            assertEqual(
                sqlite3_column_text(statement, 0).map { String(cString: $0) }, "ok",
                "\(label): the library stays intact")
            sqlite3_finalize(statement)
            return result
        }
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var samples: [[String: Any]] = []
        for index in 0..<2 { samples.append(try await run("full-\(index)", cancelAfter: nil)) }
        for offset in [25, 75, 150, 300, 600, 1200] {
            samples.append(try await run("cancel-\(offset)ms", cancelAfter: .milliseconds(offset)))
        }
        // Ordinary completion within the deadline is not evidence: require stops that interrupted live work.
        let full = samples.prefix(2).compactMap { $0["articles"] as? Int }.min() ?? 0
        let active = samples.filter { $0["stop_ms"] != nil }
        assertFalse(active.isEmpty, "At least one stop lands while the refresh is still running")
        assertTrue(
            active.contains { ($0["articles"] as? Int) == 0 && ($0["feed_states"] as? Int) == 0 } && full > 0,
            "A stop during the network phase stores no articles and records no feed outcome")
        for sample in active {
            assertTrue(
                (sample["stop_ms"] as? Double ?? .infinity) < 250,
                "\(sample["label"] ?? ""): the refresh stops promptly")
        }
        let report: [String: Any] = [
            "feeds": feeds.count, "samples": samples, "client": "SecureHTTPClient.shared (production proxy, live TLS)",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PUBLISHER_CANCELLATION_REPORT " + String(decoding: data, as: UTF8.self))
    }

    @MainActor
    final class WebBoundaryProbe: NSObject, WKNavigationDelegate {
        static func permitsNavigation(_ url: URL) -> Bool {
            url.scheme == "http" && url.host == "rebind.invalid" && url.path == "/page"
                && (url.port == nil || url.port == 80) && url.user == nil && url.password == nil
        }
        func webView(
            _ _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, Self.permitsNavigation(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        let once = SocketObservation()
        var complete: ((Result<Void, Error>) -> Void)?
        func webView(_ _: WKWebView, didFinish _: WKNavigation!) {
            if once.claim() { complete?(.success(())) }
        }
        func webView(_ _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            if once.claim() { complete?(.failure(error)) }
        }
    }

    @MainActor
    static func verifyWebKitBoundary(proxy: ProxyConfiguration) async throws {
        for address in [
            "http://127.0.0.1/page", "https://rebind.invalid/page", "http://rebind.invalid/other",
            "http://rebind.invalid:8080/page", "http://user@rebind.invalid/page",
        ] {
            assertFalse(
                WebBoundaryProbe.permitsNavigation(URL(string: address)!),
                "Probe rejects navigation outside its exact fixture")
        }
        assertTrue(
            WebBoundaryProbe.permitsNavigation(URL(string: "http://rebind.invalid/page")!),
            "Probe allows its controlled fixture")
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.configuration.userContentController.add(try await WebPreviewPolicy.contentRules())
        let probe = WebBoundaryProbe()
        view.navigationDelegate = probe
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.complete = { continuation.resume(with: $0) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if probe.once.claim() {
                    view.stopLoading()
                    continuation.resume(throwing: FeedError.timeout)
                }
            }
            view.load(URLRequest(url: URL(string: "http://rebind.invalid/page")!))
        }
    }

    static func respondToFixture(
        _ connection: NWConnection, data: Data?, port: UInt16,
        receivedRequests: SocketObservation, live: Bool
    ) {
        let response: Data
        if data?.starts(with: Data("GET ".utf8)) == true {
            let request = String(decoding: data!, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            receivedRequests.recordText(request)
            if request.contains("/redirect.css ") {
                let redirect = Data(
                    "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/forbidden-redirect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .utf8)
                connection.send(
                    content: redirect, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let body: String
            if request.contains("/page ") {
                body =
                    "<html><head><link rel='stylesheet' href='http://assets.invalid/style.css'><link rel='stylesheet' href='http://assets.invalid/redirect.css'></head><body>Publisher prose<img src='http://assets.invalid/image.svg'><img src='http://127.0.0.1:\(port)/forbidden'><img src='http://localhost:\(port)/forbidden-localhost'><img src='http://2130706433:\(port)/forbidden-decimal'><img src='http://0x7f000001:\(port)/forbidden-hex'><img src='http://127.1:\(port)/forbidden-short'><img src='http://0x7f.0.0.1:\(port)/forbidden-mixed-hex'><img src='http://0177.0.0.1:\(port)/forbidden-octal'><img src='http://%31%32%37.0.0.1:\(port)/forbidden-encoded'><img src='http://user@127.0.0.1:\(port)/forbidden-userinfo'><img src='http://127.0.0.1.:\(port)/forbidden-trailing-dot'>\(live ? "<img src='http://localtest.me:\(port)/forbidden-dns'>" : "")</body></html>"
            } else if request.contains(".svg ") {
                body = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>"
            } else if request.contains("/style.css ") {
                body = "body { color: black; }"
            } else {
                body = "OK"
            }
            let mime: String
            if request.contains(".svg ") {
                mime = "image/svg+xml"
            } else if request.contains(".css ") {
                mime = "text/css"
            } else {
                mime = "text/html"
            }
            let cacheHeader =
                request.contains("/cached-image.svg ")
                ? "Cache-Control: public, max-age=600\r\n" : "Cache-Control: no-store\r\n"
            response = Data(
                "HTTP/1.1 200 OK\r\n\(cacheHeader)Content-Type: \(mime)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    .utf8)
        } else {
            response = data ?? Data()
        }
        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A loopback socket wait that ran out; distinct from `FeedError.timeout` (the WebKit boundary's navigation deadline),
    /// which is never rerun.
    struct LoopbackTimeout: Error {}

    /// The loopback socket tests share ephemeral ports with every parallel test process. On a loaded machine
    /// (CircleCI runs atoms side by side) a connect fails with EADDRINUSE, or parks in `.waiting` until a 5 s socket
    /// read gives up, while the proxy's own 15 s handshake bound is still running. Such a transport error reruns the
    /// test once; an assertion failure, any other error or a second transport error still fails.
    @MainActor
    static func rerunningLoopbackFlake(_ test: @MainActor () async throws -> Void) async throws {
        do {
            try await test()
        } catch let error where error is LoopbackTimeout || error as? NWError == .posix(.EADDRINUSE) {
            print("  ↻ Loopback transport error under load (\(error)); running the socket test once more")
            do { try await test() } catch {
                // The second failure carries the error and the socket state, so a CI log can say what collided.
                print("  socket state at the second failure (\(error)): \(loopbackSocketSummary())")
                throw error
            }
        }
    }

    /// TIME_WAIT counts (all, loopback rows, and the distinct loopback local ports inside the ephemeral range),
    /// loopback LISTEN/ESTABLISHED counts and the ephemeral port range, from netstat and sysctl.
    static func loopbackSocketSummary() -> String {
        func run(_ path: String, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let sockets = run("/usr/sbin/netstat", ["-an", "-p", "tcp"]).split(separator: "\n")
        let timeWait = sockets.filter { $0.contains("TIME_WAIT") }.count
        let loopback = sockets.filter { $0.contains("127.0.0.1") }
        let loopbackTimeWait = loopback.filter { $0.contains("TIME_WAIT") }
        let bounds = run("/usr/sbin/sysctl", ["-n", "net.inet.ip.portrange.first", "net.inet.ip.portrange.last"])
            .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let ephemeral = bounds.count == 2 && bounds[0] <= bounds[1] ? bounds[0]...bounds[1] : 49152...65535
        // netstat columns: Proto Recv-Q Send-Q Local-Address Foreign-Address State; the local port follows the last
        // dot. Only ports inside the ephemeral range count towards exhaustion.
        let localPorts = Set(
            loopbackTimeWait.compactMap { line -> Int? in
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count > 3, let port = columns[3].split(separator: ".").last.flatMap({ Int($0) }),
                    ephemeral.contains(port)
                else { return nil }
                return port
            })
        let range = "\(ephemeral.lowerBound)-\(ephemeral.upperBound)"
        return
            "TIME_WAIT \(timeWait) (loopback \(loopbackTimeWait.count), \(localPorts.count) distinct ephemeral local ports), "
            + "loopback LISTEN \(loopback.filter { $0.contains("LISTEN") }.count), "
            + "loopback ESTABLISHED \(loopback.filter { $0.contains("ESTABLISHED") }.count), ephemeral ports \(range)"
    }

    static func testSocketNetworkBoundary() async throws {
        print("  - Testing socket boundary: pinning, mixed DNS, loopback, malformed commands and fail-closed proxy...")
        let upstream = try NWListener(using: .tcp, on: .any)
        let upstreamQueue = DispatchQueue(label: "test.proxy.upstream")
        let receivedRequests = SocketObservation()
        let live = ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1"
        if live {
            assertTrue(
                {
                    if case .blocked = IPAddressValidator.validateHost("localtest.me") { return true }
                    return false
                }(), "Live DNS-alias control resolves to a private address")
        }
        upstream.newConnectionHandler = { connection in
            connection.start(queue: upstreamQueue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, _ in
                respondToFixture(
                    connection, data: data, port: upstream.port!.rawValue,
                    receivedRequests: receivedRequests, live: live)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = SocketObservation()
            upstream.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
            }
            upstream.start(queue: upstreamQueue)
        }
        defer { upstream.cancel() }
        let fixturePort = upstream.port!
        let observed = SocketObservation()
        let connector: NetworkBoundaryProxy.Connector = { host, _ in
            observed.record(host)
            return NWConnection(host: "127.0.0.1", port: fixturePort, using: .tcp)
        }
        let mixed = NetworkBoundaryProxy(
            resolver: { _ in .allowed(ips: ["93.184.216.34", "127.0.0.1"]) }, connector: connector)
        let (mixedClient, mixedReply) = try await socksConnect(mixed, host: "mixed.invalid")
        assertEqual(mixedReply[1], 2, "Mixed public/private DNS answers are rejected before connecting")
        mixedClient.cancel()
        await mixed.stop()
        let production = NetworkBoundaryProxy(connector: connector)
        for host in [
            "127.0.0.1", "localhost", "2130706433", "0x7f000001", "localhost.", "test.local.", "intranet", "::1",
            "fe80::1%en0",
        ] {
            let (client, reply) = try await socksConnect(production, host: host)
            assertEqual(reply[1], 2, "Private/alternate/scoped address denied at the socket boundary")
            client.cancel()
        }
        let (udpClient, udpReply) = try await socksConnect(production, host: "93.184.216.34", command: 3)
        assertEqual(udpReply[1], 2, "UDP ASSOCIATE is denied")
        try await socketSend(udpClient, Data("trailing".utf8))
        do {
            _ = try await socketRead(udpClient, count: 1)
            assertTrue(false, "Rejected tunnel never relays trailing client bytes")
        } catch let error as FeedError {
            assertEqual(error, .network("EOF"), "Rejected tunnel drains unread bytes and closes without a reset")
        }
        udpClient.cancel()
        let (portClient, portReply) = try await socksConnect(production, host: "93.184.216.34", port: 22)
        assertEqual(portReply[1], 2, "Unapproved ports denied")
        portClient.cancel()
        assertEqual(observed.count, 0, "Rejected requests never construct an upstream connection")
        await production.stop()
        let allowed = NetworkBoundaryProxy(
            resolver: { host in
                ["rebind.invalid", "93.184.216.34", "assets.invalid"].contains(host)
                    ? .allowed(ips: ["93.184.216.34"]) : IPAddressValidator.validateHost(host)
            }, connector: connector)
        let (client, reply) = try await socksConnect(allowed, host: "rebind.invalid")
        assertEqual(reply[1], 0, "Approved destinations connect")
        try await socketSend(client, Data("relay proof".utf8))
        assertEqual(
            try await socketRead(client, count: 11), Data("relay proof".utf8),
            "Tunnel forwards data without rewriting it")
        client.cancel()
        assertEqual(
            observed.hosts, ["93.184.216.34"], "Connector receives the validated numeric IP, never the DNS hostname")
        let configuration = URLSessionConfiguration.ephemeral
        let proxy = try await allowed.configuration()
        assertFalse(proxy.allowFailover, "Native proxy may not fall back to direct connections")
        configuration.proxyConfigurations = [proxy]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let (body, _) = try await session.data(from: URL(string: "http://93.184.216.34/")!)
        assertEqual(String(decoding: body, as: UTF8.self), "OK", "Native URLSession uses the protected SOCKS tunnel")
        // Native image caching must reuse bytes without bypassing destination policy.
        let imageConfiguration = URLSessionConfiguration.ephemeral
        imageConfiguration.proxyConfigurations = [proxy]
        imageConfiguration.timeoutIntervalForRequest = 2
        imageConfiguration.urlCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
        let imageClient = SecureHTTPClient(configuration: imageConfiguration)
        let imageURL = URL(string: "http://93.184.216.34/cached-image.svg")!
        let initialRequests = receivedRequests.count
        let (firstImage, _) = try await imageClient.fetchImage(from: imageURL, allowHTTP: true)
        let (cachedImage, _) = try await imageClient.fetchImage(from: imageURL, allowHTTP: true)
        assertEqual(cachedImage, firstImage, "Cached image preserves publisher bytes")
        assertEqual(receivedRequests.count, initialRequests + 1, "Fresh images use one protected upstream request")
        do {
            _ = try await imageClient.fetchImage(from: imageURL)
            assertTrue(false, "Cached HTTP images cannot bypass disabled HTTP policy")
        } catch is URLError {
            // With HTTP off the address is requested over HTTPS instead (#794), which this plain-HTTP fixture cannot
            // answer: the cached http bytes are never returned.
        }
        _ = try await imageClient.fetchArticleHTML(from: imageURL, allowHTTP: true)
        assertEqual(receivedRequests.count, initialRequests + 2, "Article fetching still reloads cached URLs")
        let uncachedURL = URL(string: "http://93.184.216.34/uncached-image.svg")!
        _ = try await imageClient.fetchImage(from: uncachedURL, allowHTTP: true)
        _ = try await imageClient.fetchImage(from: uncachedURL, allowHTTP: true)
        assertEqual(receivedRequests.count, initialRequests + 4, "No-store images are fetched again")
        try await verifyWebKitBoundary(proxy: proxy)
        let paths = receivedRequests.hosts
        assertTrue(paths.contains { $0.contains("/style.css ") }, "WebKit stylesheet traverses the protected proxy")
        assertTrue(paths.contains { $0.contains("/image.svg ") }, "WebKit image traverses the protected proxy")
        assertFalse(
            paths.contains { $0.contains("/forbidden") }, "WebKit does not contact the reachable private fixture")
        await allowed.stop()
        let requestCount = receivedRequests.count
        do {
            _ = try await session.data(from: URL(string: "http://rebind.invalid/forbidden-after-stop")!)
            assertTrue(false, "Stopped gateway must not fall back to direct transport")
        } catch {
            // Failure is expected: the preceding assertion rejects an unexpected success.
        }
        assertEqual(
            receivedRequests.count, requestCount, "Stopped proxy never falls back to a reachable direct endpoint")
        if live {
            let publicURL = URL(string: "https://www.nasa.gov/feed/")!
            let directControl = URLSession(configuration: .ephemeral)
            let (controlBody, _) = try await directControl.data(from: publicURL)
            assertFalse(controlBody.isEmpty, "Public control is reachable without the stopped proxy")
            directControl.invalidateAndCancel()
            do {
                _ = try await session.data(from: publicURL)
                assertTrue(false, "Stopped proxy cannot fall back to a proven reachable public host")
            } catch {
                // The stopped proxy must reject the otherwise reachable public endpoint.
            }
        }
        session.invalidateAndCancel()
        for host in ["::127.0.0.1", "2002:7f00:1::", "2001::1", "2001:db8::1", "198.18.0.1", "192.0.2.1"] {
            assertTrue(
                IPAddressValidator.checkLiteralIP(host) != nil,
                "Transition/reserved addresses cannot escape the public boundary")
        }
        // A gateway that stopped or failed after startup restarts on next use; the client follows its new port.
        let gatewayClient = SecureHTTPClient(gateway: allowed, resolver: { _ in .allowed(ips: ["93.184.216.34"]) })
        let restartURL = URL(string: "http://93.184.216.34/restart")!
        let (beforeStop, _) = try await gatewayClient.fetchArticleHTML(from: restartURL, allowHTTP: true)
        assertEqual(String(decoding: beforeStop, as: UTF8.self), "OK", "The client reaches the gateway it started")
        await allowed.stop()
        let (afterStop, _) = try await gatewayClient.fetchArticleHTML(from: restartURL, allowHTTP: true)
        assertEqual(
            String(decoding: afterStop, as: UTF8.self), "OK", "The next request after a gateway stop succeeds")
        await allowed.stop()
    }

    actor TestCounter {
        var value: Int = 0
        func increment() { value += 1 }
    }

    struct SimulatedRefreshError: Error, Equatable {}

    static func testSignpostHelperExecution() async {
        print("  - Testing OSSignposter Measure Execution & Error Propagation (Sync & Async)...")

        // 1. Synchronous helper executes work and returns result
        let result = NewsSignposts.measure(
            signposter: NewsSignposts.database, name: "TestMeasure", metadata: "test=true"
        ) {
            return 42
        }
        assertEqual(result, 42, "measure should return work value")

        // 2. Synchronous helper propagates thrown errors
        struct TestError: Error, Equatable {}
        var caughtError = false
        do {
            try NewsSignposts.measure(signposter: NewsSignposts.feeds, name: "TestError") {
                throw TestError()
            }
        } catch is TestError {
            caughtError = true
        } catch {
            assertTrue(false, "measure must preserve the original error type")
        }
        assertTrue(caughtError, "measure should propagate thrown error")

        // 3. Asynchronous helper executes async work and returns result
        let asyncResult = try? await NewsSignposts.measure(
            signposter: NewsSignposts.database, name: "TestAsyncMeasure", metadata: "async=true"
        ) {
            try await Task.sleep(nanoseconds: 1_000_000)
            return 84
        }
        assertEqual(asyncResult, 84, "async measure should return async work value")

        // 4. Asynchronous helper propagates thrown errors
        var caughtAsyncError = false
        do {
            try await NewsSignposts.measure(signposter: NewsSignposts.feeds, name: "TestAsyncError") {
                try await Task.sleep(nanoseconds: 1_000_000)
                throw TestError()
            }
        } catch is TestError {
            caughtAsyncError = true
        } catch {
            assertTrue(false, "async measure must preserve the original error type")
        }
        assertTrue(caughtAsyncError, "async measure should propagate thrown error")
    }

    @MainActor
    static func testOnboardingAndPermissionTiming() async {
        print("  - Testing the first-launch setting and the deferred notification request (#562)...")
        // The flow walks forward and back one step at a time, from Welcome to Done.
        var walked = [OnboardingStep.welcome]
        while let next = walked.last?.next { walked.append(next) }
        assertEqual(walked, OnboardingStep.allCases, "Continue visits every step once, in order")
        assertEqual(
            walked.map(\.title),
            [
                "Welcome to News", "Choose Your Feeds", "Pick Your Sections", "On-Device Intelligence",
                "Notifications", "You're All Set",
            ], "Each step has its own screen")
        var back = [OnboardingStep.done]
        while let previous = back.last?.previous { back.append(previous) }
        assertEqual(back, walked.reversed(), "Back retraces the same steps")
        assertTrue(OnboardingStep.welcome.previous == nil, "Welcome has no Back")
        assertTrue(OnboardingStep.done.isLast && !OnboardingStep.notifications.isLast, "Only Done is last")
        assertEqual(OnboardingStep.done.continueTitle, "Start Reading", "The last step starts reading")
        assertEqual(OnboardingStep.feeds.continueTitle, "Continue", "Other steps continue")
        assertEqual(OnboardingStep.feeds.position, "Step 2 of 6", "The indicator names the step and the count")
        assertTrue(walked.allSatisfy { !$0.tip.isEmpty && $0.companions.count <= 3 }, "Every step has a tip and art")
        func suite(_ name: String, seed: [String: Any] = [:]) -> (String, UserDefaults) {
            let name = testDefaultsSuite(name)
            let defaults = UserDefaults(suiteName: name)!
            for (key, value) in seed { defaults.set(value, forKey: key) }
            return (name, defaults)
        }
        let (freshName, fresh) = suite("onboarding-fresh")
        let (feedsName, feeds) = suite(
            "onboarding-feeds", seed: [AppSettings.feedURLsKey: ["https://example.com/feed"]])
        let (modeName, mode) = suite("onboarding-mode", seed: [AppSettings.notificationModeKey: "full"])
        defer { for name in [freshName, feedsName, modeName] { removeTestDefaults(name) } }
        assertFalse(AppSettings(defaults: fresh).firstLaunchCompleted, "A fresh install shows the first-launch sheet")
        assertFalse(AppSettings(defaults: fresh).firstLaunchCompleted, "A sheet closed by quitting shows again")
        AppSettings(defaults: fresh).completeFirstLaunch()
        assertTrue(AppSettings(defaults: fresh).firstLaunchCompleted, "Completing the sheet persists")
        assertTrue(AppSettings(defaults: feeds).firstLaunchCompleted, "Existing subscriptions skip the sheet")
        assertTrue(AppSettings(defaults: mode).firstLaunchCompleted, "Settings from an earlier version skip the sheet")

        // The permission request waits for a refresh that leaves stories, the closed sheet and the setting.
        // Refreshes deliver nothing until `delivering` is incremented; then each feed brings one story.
        func manager(_ settings: AppSettings, delivering: TestCounter) async -> FeedManager {
            settings.aiEnabled = false
            let store = ArticleStore(
                database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
            await store.initialize()
            return FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in
                    guard await delivering.value > 0 else { return [] }
                    return urls.map { url in
                        let story = FeedArticle(
                            title: "First story", link: "https://example.com/onboarding/story", guid: "first",
                            description: "", pubDate: Date(), source: "Publisher")
                        return (url, [story], nil, nil)
                    }
                },
                notifyBatch: { _, _ in }, imageFinder: .unavailable)
        }
        let (newName, newDefaults) = suite("onboarding-permission")
        let (offName, offDefaults) = suite("onboarding-permission-off")
        defer { for name in [newName, offName] { removeTestDefaults(name) } }
        let settings = AppSettings(defaults: newDefaults)
        let delivering = TestCounter()
        let feedManager = await manager(settings, delivering: delivering)
        var requests = 0
        var requestedMidRefresh = false
        let request = NotificationPermissionRequest(feedManager: feedManager, settings: settings) {
            requests += 1
            requestedMidRefresh = requestedMidRefresh || feedManager.isAnyFeedLoading
        }
        assertEqual(requests, 0, "Nothing is asked at launch")
        settings.completeFirstLaunch()
        await feedManager.fetchFeedsAsync()
        assertEqual(requests, 0, "A refresh that brings no stories does not ask")
        await delivering.increment()
        await feedManager.fetchFeedsAsync()
        assertTrue(!feedManager.articles.isEmpty, "The second refresh brings a story")
        assertEqual(requests, 1, "The first refresh with stories asks once")
        assertFalse(requestedMidRefresh, "After an empty refresh, the next one asks only once it has completed")
        await feedManager.fetchFeedsAsync()
        settings.setNotificationsEnabled(false)
        settings.setNotificationsEnabled(true)
        assertEqual(requests, 1, "Later refreshes and toggles in the same launch do not ask again")
        assertTrue(request.hasRequested, "The request records that it asked")
        feedManager.stopBackgroundWork()

        // Stories and a refresh first: the sheet's closing, then turning notifications on, decide.
        let quiet = AppSettings(defaults: offDefaults)
        quiet.setNotificationsEnabled(false)
        let quietDelivering = TestCounter()
        await quietDelivering.increment()
        let quietManager = await manager(quiet, delivering: quietDelivering)
        var quietRequests = 0
        let quietRequest = NotificationPermissionRequest(feedManager: quietManager, settings: quiet) {
            quietRequests += 1
        }
        await quietManager.fetchFeedsAsync()
        assertEqual(quietRequests, 0, "Nothing is asked while the first-launch sheet is open")
        quiet.completeFirstLaunch()
        assertEqual(quietRequests, 0, "With notifications off, closing the sheet does not ask")
        quiet.setNotificationsEnabled(true)
        assertEqual(quietRequests, 1, "Turning notifications on after a refresh with stories asks")
        assertTrue(quietRequest.hasRequested, "The request records that it asked")
        quietManager.stopBackgroundWork()
    }

    /// #926: macOS asks `willPresent` only while News is active, so a story posted while News is behind another app
    /// is offered to the app's banner at post time. Exactly one banner either way: drawn means not added.
    static func testStoryBannerRoute() async throws {
        print("  - Testing the story banner route: app banner behind another app, never both (#926)...")
        assertTrue(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .banner, previews: .always),
            "Banners with previews are the app's")
        assertTrue(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .banner, previews: .whenAuthenticated),
            "Previews when unlocked still allow the app banner")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .alert, previews: .always),
            "The Alerts style stays with the system")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .none, previews: .always),
            "Alert style None draws nothing from the app")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .disabled, style: .banner, previews: .always),
            "Banners off draw nothing from the app")
        assertFalse(
            StoryBannerRoute.allowsAppBanner(alert: .enabled, style: .banner, previews: .never),
            "Hidden previews stay with the system, which redacts them")

        func request(story: Bool) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = "Publisher"
            content.subtitle = "Headline"
            if story { content.categoryIdentifier = NotificationActionIdentifier.category }
            return UNNotificationRequest(identifier: "news-route", content: content, trigger: nil)
        }
        final class Calls: @unchecked Sendable {
            var presented = 0
            var added = 0
            var settingsRead = 0
        }
        func route(
            story: Bool = true, active: Bool, drawn: Bool = true,
            settings: (UNNotificationSetting, UNAlertStyle, UNShowPreviewsSetting) = (.enabled, .banner, .always)
        ) async throws -> (StoryBannerRoute, Calls) {
            let calls = Calls()
            let result = try await StoryBannerRoute.deliver(
                request(story: story), active: active,
                settings: {
                    calls.settingsRead += 1
                    return settings
                },
                present: { _ in
                    calls.presented += 1
                    return drawn
                },
                add: { _ in calls.added += 1 })
            return (result, calls)
        }

        // Behind another app with a window on screen: the app draws it and nothing is added (log of 3 November).
        var (result, calls) = try await route(active: false)
        assertEqual(result, .appBanner, "Inactive story banners are drawn by the app")
        assertEqual(calls.presented, 1, "The presenter is asked once")
        assertEqual(calls.added, 0, "A drawn banner is not also added: never both banners")
        // No window on screen (hidden, in the Dock): the presenter declines and the system banner shows.
        (result, calls) = try await route(active: false, drawn: false)
        assertEqual(result, .notificationCenter, "A declined banner goes to the system")
        assertEqual(calls.added, 1, "A declined banner is added exactly once")
        // Active: the post adds it and `willPresent` draws it, as before.
        (result, calls) = try await route(active: true)
        assertEqual(result, .notificationCenter, "Active posts are added for willPresent")
        assertEqual(calls.presented + calls.settingsRead, 0, "An active post neither presents nor reads settings")
        assertEqual(calls.added, 1, "An active post is added once")
        // Grouped and summary banners always stay with the system.
        (result, calls) = try await route(story: false, active: false)
        assertEqual(result, .notificationCenter, "Grouped banners stay with the system")
        assertEqual(calls.presented, 0, "A grouped banner is never offered to the app")
        // Alerts style or hidden previews: the system draws it, the app does not.
        for settings: (UNNotificationSetting, UNAlertStyle, UNShowPreviewsSetting) in [
            (.enabled, .alert, .always), (.enabled, .banner, .never), (.disabled, .banner, .always),
        ] {
            (result, calls) = try await route(active: false, settings: settings)
            assertEqual(result, .notificationCenter, "Settings the app does not draw under go to the system")
            assertEqual(calls.presented, 0, "The presenter is not asked under those settings")
            assertEqual(calls.added, 1, "Those posts are added once")
        }
        // A refused add still throws to the caller, which logs it and does not record the banner.
        struct Refused: Error {}
        var threw = false
        do {
            _ = try await StoryBannerRoute.deliver(
                request(story: true), active: true, settings: { (.enabled, .banner, .always) },
                present: { _ in true }, add: { _ in throw Refused() })
        } catch is Refused {
            threw = true
        }
        assertTrue(threw, "A refused add surfaces as a failed post")
        // Without an app (tests, helpers) no presenter is installed, so nothing is drawn.
        assertTrue(await MainActor.run { NotificationService.presentAppBanner == nil }, "No presenter outside the app")
        // The hop to the main actor re-checks activity: a post made as News became active is added, not drawn.
        guard let banner = StoryBanner(request(story: true)) else {
            return assertTrue(false, "A story request makes a banner")
        }
        let offered = await MainActor.run {
            var received: (StoryBanner, Bool)?
            let presenter: (StoryBanner, Bool) -> Bool = { banner, sounds in
                received = (banner, sounds)
                return true
            }
            let drawn = StoryBannerRoute.offer(banner, sounds: true, active: false, presenter: presenter)
            let declined = StoryBannerRoute.offer(banner, sounds: true, active: true, presenter: presenter)
            let absent = StoryBannerRoute.offer(banner, sounds: true, active: false, presenter: nil)
            return (drawn, declined, absent, received)
        }
        assertTrue(offered.0, "Inactive: the presenter draws the copied banner")
        assertEqual(offered.3?.0, banner, "The presenter receives the banner copied out of the request")
        assertEqual(offered.3?.1, true, "The presenter is told the banner asks for a sound")
        assertFalse(offered.1, "Became active meanwhile: declined, so the add files it for willPresent")
        assertFalse(offered.2, "No presenter installed: nothing is drawn")
        // The request form copies the banner out and hops to the main actor; without a presenter it declines.
        assertFalse(await StoryBannerRoute.offer(request(story: true)), "No presenter: a story request is declined")
        assertFalse(await StoryBannerRoute.offer(request(story: false)), "A grouped request makes no banner")
    }

    static func testFeedArticleWrapContextNavigation() async {
        print("  - Testing FeedArticleWrap Context Preservation & Filtered Navigation Boundaries...")

        let artA = FeedArticle(
            title: "Article A", link: "https://example.com/a", guid: "a", description: "Desc A", pubDate: Date(),
            source: "Source 1", category: "Technology")
        let artB = FeedArticle(
            title: "Article B", link: "https://example.com/b", guid: "b", description: "Desc B", pubDate: Date(),
            source: "Source 2", category: "Science")
        let artC = FeedArticle(
            title: "Article C", link: "https://example.com/c", guid: "c", description: "Desc C", pubDate: Date(),
            source: "Source 1", category: "Technology")
        let artD = FeedArticle(
            title: "Article D", link: "https://example.com/d", guid: "d", description: "Desc D", pubDate: Date(),
            source: "Source 3", category: "Business")

        let allGlobal = [artA, artB, artC, artD]
        let techFilter = [artA, artC]

        // 1. Wrap with filtered context
        let wrap = FeedArticleWrap(article: artA, contextArticles: techFilter)
        assertEqual(wrap.article.id, artA.id, "Wrapped article ID must match artA")
        assertEqual(wrap.contextArticles.count, 2, "Filtered context must contain exactly 2 articles")
        assertEqual(
            wrap.contextArticles.map(\.id), [artA.id, artC.id], "Filtered context articles must match techFilter")

        // 2. Boundary simulation in filtered context:
        // In techFilter: artA is index 0. Has next (artC), but NO previous.
        let idxA = wrap.contextArticles.firstIndex(where: { $0.id == artA.id })
        assertEqual(idxA, 0, "artA should be at index 0 in filtered context")
        let hasPrevInFilter = idxA.map { $0 > 0 } ?? false
        let hasNextInFilter = idxA.map { $0 + 1 < wrap.contextArticles.count } ?? false
        assertFalse(hasPrevInFilter, "artA must not have previous article in filtered context")
        assertTrue(hasNextInFilter, "artA must have next article (artC) in filtered context")

        // In techFilter: Next article from artA is artC (skipping artB which is Science!)
        let nextArt = wrap.contextArticles[idxA! + 1]
        assertEqual(nextArt.id, artC.id, "Next article in tech filter must be artC, skipping artB")

        // In global context without filter: Next article from artA would have been artB
        let globalIdxA = allGlobal.firstIndex(where: { $0.id == artA.id })!
        let globalNext = allGlobal[globalIdxA + 1]
        assertEqual(globalNext.id, artB.id, "In unfiltered global context, next is artB")

        // 3. Fallback behavior when contextArticles is empty
        let wrapEmpty = FeedArticleWrap(article: artB)
        assertTrue(wrapEmpty.contextArticles.isEmpty, "Default contextArticles should be empty")

        // 4. Stable uniqueness of wrap identity
        let wrap2 = FeedArticleWrap(article: artA, contextArticles: techFilter)
        assertTrue(wrap.id != wrap2.id, "Each wrap must have a distinct UUID identity for navigation state")
    }

    @MainActor
    static func testDiagnosticsExport() async throws {
        print("  - Testing the diagnostics export and its redaction (#564)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let title = "Minister resigns over leaked budget memo"
        let log = [
            DiagnosticsExport.LogLine(
                date: now, category: "Feeds", level: "Error",
                message: "Fetch failed for https://reader:pw@news.example.com/world/2026/leaked-memo?id=7 after 3 tries"
            ),
            DiagnosticsExport.LogLine(
                date: now, category: "Database", level: "Notice",
                message: "Integrity check at /Users/mars/Library/Containers/com.marspater.news/Data/news.sqlite: ok"),
            DiagnosticsExport.LogLine(
                date: now, category: "Feeds", level: "Info", message: "Stored \(title) from feed:https://x.example/a"),
        ]
        let suite = testDefaultsSuite("diagnostics-export")
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        let failing = FeedHealth(FeedFetchState(failures: 2), now: now)
        let summary = DiagnosticsExport.summary(
            settings: settings, feedHealth: ["https://feeds.example.org/private/world.xml": failing], schema: 26,
            now: now)
        let files = DiagnosticsExport.files(summary: summary, log: log, titles: [title, "Short"])
        let text = files.values.joined()
        for hidden in ["/world/", "leaked-memo", "id=7", "reader:pw", "/private/world.xml", "/Users/mars", title] {
            assertTrue(!text.contains(hidden), "The export leaves out \(hidden)")
        }
        let tricky = DiagnosticsExport.redact(
            "a https://news.example.com/private'token b https://reader@mail@news.example.com:8443/p c", titles: [])
        assertEqual(tricky, "a news.example.com b news.example.com c", "Quotes and repeated @ never keep URL text")
        let logText = files["log.txt"] ?? ""
        assertTrue(logText.contains("Fetch failed for news.example.com after 3 tries"), "URLs keep their host")
        assertTrue(logText.contains("at ~/Library/Containers/com.marspater.news/Data/news.sqlite"), "Home becomes ~")
        assertTrue(logText.contains("Stored <story> from feed:x.example"), "Story titles are replaced")
        assertTrue(logText.hasPrefix("2026-09-21T14:13:20Z Error Feeds: "), "Lines carry date, level and category")
        let summaryText = files["summary.txt"] ?? ""
        assertTrue(summaryText.contains("Library schema version: 26"), "The summary names the schema version")
        assertTrue(summaryText.contains("Feeds: 2, starred: 0"), "The summary counts subscriptions")
        assertTrue(
            summaryText.contains("feeds.example.org: Not responding (2 failed attempts)"), "Feed health by host")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("News Diagnostics.zip")
        try DiagnosticsExport.archive(files, to: zip)
        try DiagnosticsExport.archive(files, to: zip)  // An existing file is replaced.
        assertTrue(try Data(contentsOf: zip).starts(with: [0x50, 0x4B, 0x03, 0x04]), "The export is a zip archive")
        let listing = Process()
        let output = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", zip.path]
        listing.standardOutput = output
        try listing.run()
        listing.waitUntilExit()
        let names = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        assertTrue(
            names.contains("News Diagnostics/summary.txt") && names.contains("News Diagnostics/log.txt"),
            "The zip holds the summary and the log: \(names)")

        // This process's own entries are readable from the unified log, as the app's are; private values stay redacted.
        let marker = "diagnostics-check-\(UUID().uuidString)"
        let secret = "https://feeds.example/private?token=\(UUID().uuidString)"
        NewsSignposts.launchLog.notice("\(marker, privacy: .public) \(secret)")
        // The unified log may store the entry a moment later; poll briefly instead of reading once.
        let deadline = ContinuousClock.now + .seconds(5)
        var found = false
        while !found && ContinuousClock.now < deadline {
            let own = try DiagnosticsExport.currentLaunchLog()
            found = own.contains { $0.message == "\(marker) <private>" && $0.category == "Launch" }
            if !found { try await Task.sleep(for: .milliseconds(100)) }
        }
        assertTrue(found, "The export reads this launch's log")
    }

    @MainActor
    static func testLogWindowModel() async {
        print("  - Testing the development Log window's filters and gate (#1005)...")
        assertTrue(LogWindowModel.isAvailable(bundleIdentifier: "com.marspater.news.dev"), "make run shows the Log")
        assertTrue(!LogWindowModel.isAvailable(bundleIdentifier: "com.marspater.news"), "A release build has no Log")
        assertTrue(!LogWindowModel.isAvailable(bundleIdentifier: nil), "No bundle id, no Log")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func line(_ offset: TimeInterval, _ category: String, _ level: String, _ message: String)
            -> DiagnosticsExport.LogLine
        {
            DiagnosticsExport.LogLine(
                date: start.addingTimeInterval(offset), category: category, level: level, message: message)
        }
        let model = LogWindowModel()
        model.follows = false
        model.clear()
        assertTrue(model.follows, "Clear follows new lines again: an empty view has nothing to scroll back from")
        model.append([
            line(0, "Feeds", "Info", "Fetched 12 items"), line(1, "Database", "Error", "Integrity check failed"),
            line(2, "Feeds", "Error", "Fetch failed for news.example.com"),
        ])
        // A reread from the last line's time returns it again; only newer lines are added.
        model.append([
            line(2, "Feeds", "Error", "Fetch failed for news.example.com"), line(3, "Launch", "Notice", "Ready"),
        ])
        assertEqual(model.entries.count, 4, "Rereads add only newer lines")
        assertEqual(model.visible.map(\.line.message).last, "Ready", "Newest last")
        assertEqual(model.categories, ["Database", "Feeds", "Launch"], "Categories come from the entries")
        model.level = "Error"
        assertEqual(model.visible.count, 2, "Level filter")
        model.category = "Feeds"
        assertEqual(model.visible.map(\.line.message), ["Fetch failed for news.example.com"], "Level and category")
        model.level = nil
        model.search = "FETCHED"
        assertEqual(model.visible.map(\.line.message), ["Fetched 12 items"], "Search ignores case")
        model.category = nil
        model.search = "database"
        assertEqual(model.visible.count, 1, "Search matches the category too")
        assertTrue(model.visibleText.hasSuffix("Error Database: Integrity check failed"), "Copy holds visible lines")
        model.search = ""
        model.clear()
        assertTrue(model.visible.isEmpty, "Clear hides what was shown")
        model.append([line(1, "Feeds", "Info", "Old"), line(4, "Feeds", "Info", "After clear")])
        assertEqual(model.visible.map(\.line.message), ["After clear"], "Lines shown before Clear stay hidden")
    }

    /// A seeded in-memory library for the diagnostics writers (#1006): two stories, one matched by an older matcher.
    static func diagnosticsLibrary() async throws -> DatabaseEngine {
        let database = DatabaseEngine(path: ":memory:")
        try await database.open()
        let stories = (0..<2).map { index in
            FeedArticle(
                title: "Minister resigns over leaked budget memo \(index)",
                link: "https://news.example.com/world/memo-\(index)", guid: "memo-\(index)", description: "Memo",
                pubDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)), source: "Example")
        }
        try await database.upsertArticles(stories)
        try await database.markEventMatchProcessed([stories[0].id], matcherVersion: EventMatcher.version)
        try await database.markEventMatchProcessed([stories[1].id], matcherVersion: EventMatcher.version - 1)
        return database
    }

    static func testDiagnosticsLibrary() async throws {
        print("  - Testing the diagnostics library writer (#1006)...")
        let text = try await DiagnosticsExport.library(try await diagnosticsLibrary())
        assertTrue(
            text.contains("Schema version: \(DatabaseEngine.schemaVersion)"), "Library names its schema: \(text)")
        assertTrue(text.contains("Integrity check: ok"), "Library runs the integrity check")
        assertTrue(text.contains("\narticles: 2\n"), "Library counts rows per table")
        assertTrue(text.contains("Oldest story: 2026-09-21T14:13:20Z"), "Library names the oldest story's date")
        assertTrue(!text.contains("Minister"), "Library carries no story text")
    }

    static func testDiagnosticsFeeds() async {
        print("  - Testing the diagnostics feeds writer (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let url = "https://feeds.example.org/private/world.xml?token=1"
        var state = FeedFetchState(failures: 2)
        state.validators = FeedValidators(etag: "\"abc\"", lastModified: nil)
        state.retryAt = now.addingTimeInterval(600)
        state.itemCount = 12
        state.fullTextItems = 3
        let text = DiagnosticsExport.feeds(
            feedURLs: [url, "https://other.example/rss"], states: [url: state],
            statuses: [url: DiagnosticsExport.failureKind(.httpStatus(503))], now: now)
        assertTrue(
            text.contains("1. feeds.example.org: status httpStatus 503, last fetch never, failures 2"),
            "Feeds list status and failures by host: \(text)")
        assertTrue(text.contains("validators ETag, items 12, full text 3 of 12"), "Feeds list validators and items")
        assertTrue(text.contains("2. other.example: status idle"), "Every subscription is listed")
        assertTrue(!text.contains("/private/") && !text.contains("token"), "Feeds keep only the host")
        assertTrue(
            DiagnosticsExport.feeds(feedURLs: [url], states: nil, statuses: [:], now: now)
                .contains("1. feeds.example.org: status idle, fetch state unreadable"),
            "An unreadable library is named, not reported as empty states")
        assertEqual(
            DiagnosticsExport.failureKind(.network("https://x.example/a failed")), "network",
            "A failure kind carries no payload")
    }

    static func testDiagnosticsClustering() async throws {
        print("  - Testing the diagnostics clustering writer (#1006)...")
        var stages = EventClusteringStages(total: 2, pairModelCalls: 3)
        stages.add(EventClusteringStages(total: 1, candidateSearch: 0.5, pairModelCalls: 4))
        assertEqual(stages.total, 3, "A run's stage seconds add up over its passes (#691)")
        assertEqual(stages.candidateSearch, 0.5, "Candidate search adds up over passes")
        assertEqual(stages.pairModelCalls, 7, "Pair-model calls add up over passes")
        var report = EventClusteringReport()
        report.processed = 4
        report.deferred = 1
        let pass = FeedManager.ClusteringPass(
            report: report, seconds: 0.25, finishedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let text = try await DiagnosticsExport.clustering(
            try await diagnosticsLibrary(), lastPass: pass, embedderAvailable: true, pairModelAvailable: false)
        assertTrue(text.contains("Matcher version: \(EventMatcher.version)"), "Clustering names the matcher: \(text)")
        assertTrue(text.contains("older matcher): 1"), "Clustering counts stories pending a match")
        assertTrue(text.contains("version \(SentenceEmbedder.modelVersion), available"), "Embedder state")
        assertTrue(
            text.contains("Pair model: matcher version \(EventMatcher.version), unavailable"), "Pair model state")
        assertTrue(text.contains("0.25 s, processed 4") && text.contains("deferred 1"), "The last pass and deferrals")
    }

    static func testDiagnosticsIntelligence() async throws {
        print("  - Testing the diagnostics intelligence writer (#1006)...")
        let overviews = OverviewGenerationCoordinator.Counts(
            inFlight: 1, extractions: 2, failedExtractions: 3, cached: 4)
        let text = try await DiagnosticsExport.intelligence(
            try await diagnosticsLibrary(), foundationModels: "available", queue: ["queued": 5, "running": 1],
            overviews: overviews)
        assertTrue(text.contains("Foundation Models: available"), "Intelligence names model availability: \(text)")
        assertTrue(text.contains("Enrichment queue: queued 5, running 1"), "The queue by state")
        assertTrue(
            text.contains(#/Enrichment rows: 2, enriched \d+, with a summary \d+/#), "Stored enrichment counts: \(text)"
        )
        assertTrue(
            text.contains("in flight: 1, page fetches running 2, failed this launch 3, held in memory 4"),
            "Overview work in flight")
        let counts = await EnrichmentQueue().stateCounts()
        assertTrue(counts.isEmpty, "A new queue holds nothing")
    }

    static func testDiagnosticsNotifications() async throws {
        print("  - Testing the diagnostics notifications writer (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let database = try await diagnosticsLibrary()
        let clock = now.timeIntervalSince1970
        try await database.eventRows(
            "INSERT INTO notification_deliveries(lane, grouped, feed_url, story_count, delivered_at) VALUES (0, 0, NULL, 1, ?), (2, 1, NULL, 3, ?), (0, 0, NULL, 1, ?);",
            [.real(clock - 60), .real(clock - 120), .real(clock - 2 * 86400)])
        let log = [
            DiagnosticsExport.LogLine(
                date: now, category: "StoryBanner", level: "Notice", message: "posted <private> route=appBanner"),
            DiagnosticsExport.LogLine(
                date: now, category: "StoryBanner", level: "Notice",
                message: "posted <private> route=notificationCenter"),
            DiagnosticsExport.LogLine(
                date: now, category: "NotificationService", level: "Error",
                message: "Failed to schedule full notification '<private>': domain=UNErrorDomain code=1 Not allowed"),
        ]
        let text = try await DiagnosticsExport.notifications(
            database, settings: ["Authorization: authorized"], log: log, now: now)
        assertTrue(text.contains("Authorization: authorized"), "Notifications list the settings: \(text)")
        assertTrue(text.contains("normal: 1, 1") && text.contains("priority, grouped: 1, 3"), "The last 24 h by lane")
        assertTrue(
            text.contains("appBanner: 1") && text.contains("notificationCenter: 1")
                && text.contains("refused UNErrorDomain 1: 1"), "Routes and refusals")
    }

    static func testDiagnosticsImages() async throws {
        print("  - Testing the diagnostics images writer (#1006)...")
        let now = Date()
        let database = try await diagnosticsLibrary()
        let ids = try await database.eventRows("SELECT id FROM articles ORDER BY id;").compactMap { $0[0] }
        try await database.recordStoryImage(ids[0], imageURL: "https://img.example/a.jpg", at: now)
        try await database.recordStoryImage(ids[1], imageURL: nil, at: now)
        var lookup = StoryCurator.Report()
        lookup.imagesFound = 1
        lookup.imagesChecked = 2
        let text = try await DiagnosticsExport.images(database, lastLookup: lookup, now: now)
        assertTrue(
            text.contains("Lookup rows: 2, with an image 1, refused or without one 1, checked in the last 24 hours 2"),
            "Images count the lookup table: \(text)")
        assertTrue(text.contains("found 1, checked 2 of a budget of \(StoryCurator.imageBudget)"), "The last pass")
        assertTrue(
            text.contains("full size at most \(DecodedImageCache.fullCountLimit) images")
                && text.contains("card size at most \(DecodedImageCache.cardCountLimit) images"),
            "The decoded caches' limits")
    }

    static func testDiagnosticsNetwork() async {
        print("  - Testing the diagnostics network writer (#1006)...")
        let log = [
            DiagnosticsExport.LogLine(
                date: Date(), category: "NetworkBoundaryProxy", level: "Error",
                message: "Upstream connect to port 443 refused: posix ECONNREFUSED"),
            DiagnosticsExport.LogLine(
                date: Date(), category: "NetworkBoundaryProxy", level: "Error",
                message: "Upstream connect to port 443 refused: posix ECONNREFUSED"),
        ]
        let text = DiagnosticsExport.network(
            gatewayPort: 50_123, resolverCancellations: 2,
            feedStatuses: ["https://a.example/rss": "timeout", "https://b.example/rss": "timeout", "c": "idle"],
            proxy: DiagnosticsExport.proxyLines(["HTTPSEnable": 1, "__SCOPED__": ["utun3": [:], "en0": [:]]]), log: log)
        assertTrue(text.contains("listening on 127.0.0.1:50123"), "Network names the gateway: \(text)")
        assertTrue(text.contains("cancelled before they answered 2"), "Resolver cancellations")
        assertTrue(text.contains("timeout: 2"), "Feed failures by kind")
        assertTrue(text.contains("refused posix ECONNREFUSED: 2"), "Upstream outcomes from the log")
        assertTrue(text.contains("HTTPS proxy: on") && text.contains("VPN interfaces: utun3"), "Proxy and VPN state")
        assertTrue(!text.contains("en0"), "Only tunnel interfaces are listed")
    }

    static func testDiagnosticsProcess() async {
        print("  - Testing the diagnostics process writer (#1006)...")
        let snapshot = DiagnosticsExport.processSnapshot(
            displayScale: 2, reduceMotion: true, increaseContrast: false, voiceOver: false)
        assertTrue(snapshot.footprintBytes ?? 0 > 0, "The process reads its memory footprint")
        assertTrue(snapshot.launchedAt != nil, "The process reads its start time")
        let text = DiagnosticsExport.process(snapshot, now: Date())
        assertTrue(text.contains("Display scale: 2.0"), "Process names the display scale: \(text)")
        assertTrue(text.contains("Reduce Motion: on, Increase Contrast: off, VoiceOver: off"), "Accessibility")
        assertTrue(text.contains("Thermal state: ") && text.contains("Locale: "), "Energy and locale")
    }

    static func testDiagnosticsLogFiles() async {
        print("  - Testing the diagnostics log files (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let log = [
            DiagnosticsExport.LogLine(date: now, category: "Feeds", level: "Info", message: "one"),
            DiagnosticsExport.LogLine(date: now, category: "Database", level: "Error", message: "two"),
            DiagnosticsExport.LogLine(date: now, category: "Feeds", level: "Info", message: "three"),
        ]
        let files = DiagnosticsExport.logFiles(log)
        assertEqual(files.keys.sorted(), ["log-Database.txt", "log-Feeds.txt", "log.txt"], "One file per category")
        assertEqual(files["log-Feeds.txt"]?.components(separatedBy: "\n").count, 3, "A category file holds its lines")
        assertEqual(files["log.txt"]?.components(separatedBy: "\n").count, 4, "The combined file holds every line")
    }

    static func testDiagnosticsSpotlightAndCaches() async {
        print("  - Testing the diagnostics Spotlight and caches writer (#1006)...")
        var app = DiagnosticsExport.AppSnapshot()
        app.savedStories = 3
        app.spotlightAvailable = true
        app.urlCache = (memory: 1024, disk: 2048, memoryCapacity: 4096, diskCapacity: 8192)
        let log = [
            DiagnosticsExport.LogLine(
                date: Date(timeIntervalSince1970: 1_790_000_000), category: "CacheManager", level: "Info",
                message: "Cleared HTTP network cache.")
        ]
        let text = DiagnosticsExport.spotlightAndCaches(app, log: log)
        assertTrue(text.contains("indexing available, saved stories to index 3"), "Spotlight state: \(text)")
        assertTrue(text.contains("URL cache: memory 1 KB of 4 KB"), "URL cache use")
        assertTrue(text.contains("2026-09-21T14:13:20Z Cleared HTTP network cache."), "Clear commands run")
    }

    static func testDiagnosticsSections() async throws {
        print("  - Testing the diagnostics archive's file list (#1006)...")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let sections = await DiagnosticsExport.sectionFiles(
            try await diagnosticsLibrary(), app: DiagnosticsExport.AppSnapshot(), log: [], now: now)
        let files = DiagnosticsExport.files(summary: "News diagnostics\n", sections: sections, log: [], titles: [])
        let summary = files["summary.txt"] ?? ""
        for name in files.keys {
            assertTrue(summary.contains("\n\(name)\n") || summary.hasSuffix("\n\(name)\n"), "summary.txt lists \(name)")
        }
        for name in [
            "library.txt", "feeds.txt", "clustering.txt", "intelligence.txt", "notifications.txt", "images.txt",
            "network.txt", "gateway-timing.txt", "process.txt", "spotlight-and-caches.txt", "log.txt",
        ] {
            assertTrue(files[name] != nil, "The archive holds \(name)")
        }
    }

    /// A loader whose completions wait in a queue until the test releases them, oldest first (#591).
    @MainActor final class QueuedImageLoader {
        private struct Waiting {
            let id: UUID
            let url: URL
            let continuation: CheckedContinuation<CGImage, Error>
        }
        let honorsCancellation: Bool
        private(set) var requests: [URL] = []
        /// The pixel bound each request asked for, in request order.
        private(set) var pixelBounds: [Int] = []
        private var queue: [Waiting] = []
        private let image: CGImage = {
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .makeImage()!
        }()
        var queued: Int { queue.count }

        init(honorsCancellation: Bool = true) { self.honorsCancellation = honorsCancellation }

        var loader: @Sendable (URL, Int) async throws -> CGImage {
            { url, maxPixels in try await self.enqueue(url, maxPixels: maxPixels) }
        }

        private func enqueue(_ url: URL, maxPixels: Int) async throws -> CGImage {
            requests.append(url)
            pixelBounds.append(maxPixels)
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.append(Waiting(id: id, url: url, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard honorsCancellation, let index = queue.firstIndex(where: { $0.id == id }) else { return }
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        /// Completes the `count` oldest waiting loads.
        func release(_ count: Int) {
            let released = queue.prefix(count)
            queue.removeFirst(released.count)
            for waiting in released { waiting.continuation.resume(returning: image) }
        }

        /// Waits until the loads that released ones lead to have reached the queue: no change across ten 1 ms polls.
        func settle() async {
            var last = (-1, -1)
            var stable = 0
            while stable < 10 {
                try? await Task.sleep(for: .milliseconds(1))
                let now = (requests.count, queue.count)
                stable = now == last ? stable + 1 : 0
                last = now
            }
        }
    }

    /// #591: scrolling 200 cards shows at most 5% placeholders at first paint when prefetch decodes each card's own
    /// image ahead of it, and nothing else is fetched; a decode that finished is kept though its only waiter cancelled.
    @MainActor static func testCardImagePrefetchFirstPaint() async {
        print("  - Testing card image prefetch and placeholders at first paint...")
        DecodedImageCache.clear()
        defer {
            DecodedImageCache.cardFirstPaints = nil
            DecodedImageCache.clear()
        }

        // This loader ignores cancellation, so it finishes after the shared task was cancelled.
        let stubborn = QueuedImageLoader(honorsCancellation: false)
        let keptURL = URL(string: "https://cards.example/kept/\(UUID().uuidString).jpg")!
        let waiter = Task { @MainActor in _ = try? await DecodedImageCache.load(keptURL, using: stubborn.loader) }
        await eventually("The stubborn load is queued before its waiter cancels") { @MainActor in
            stubborn.requests.count == 1 && stubborn.queued == 1
        }
        let shared = DecodedImageCache.sharedLoad(for: keptURL)
        assertTrue(shared != nil, "The stubborn load is shared under its URL")
        waiter.cancel()
        // The last waiter's cancellation cancels the shared task on the main actor; release only after it has.
        await eventually("The shared load is cancelled while its decode is still queued") { @MainActor in
            shared?.task.isCancelled == true && stubborn.queued == 1
        }
        stubborn.release(1)
        _ = await waiter.value
        await stubborn.settle()
        assertTrue(DecodedImageCache.cached(keptURL) != nil, "A finished decode is kept after its waiter cancelled")

        // 200 cards: every fifth an event of three reports with an image each, every tenth without an image.
        let now = Date()
        var articles: [FeedArticle] = []
        var events: [EventFeedSummary] = []
        for index in 0..<200 {
            let members = (0..<(index % 5 == 0 ? 3 : 1)).map { member in
                FeedArticle(
                    title: "Prefetch story \(index) report \(member)",
                    link: "https://news.example/\(index)/\(member)", guid: "prefetch-\(index)-\(member)",
                    description: "Summary", pubDate: now.addingTimeInterval(-Double(index * 10 + member)),
                    source: "Publisher \(member)",
                    imageUrl: index % 10 == 9 ? nil : "https://cards.example/\(index)/\(member).jpg")
            }
            articles += members
            if members.count > 1 {
                events.append(
                    EventFeedSummary(
                        eventID: "prefetch-event-\(index)", membershipVersion: 1, seenVersion: nil,
                        members: members.map {
                            EventFeedMember(
                                articleID: $0.id, source: $0.source, title: $0.title, date: $0.pubDate,
                                joinedVersion: 1, isRead: false, isSaved: false)
                        }))
            }
        }
        let entries = FeedSnapshot(articles: articles, events: events).entries(.events)
        assertEqual(entries.count, 200, "The seeded list has 200 cards")
        let cardURLs = Set(entries.compactMap(\.cardImageURL))
        assertEqual(cardURLs.count, 180, "180 cards show an image of their own")

        // Each card appears (ArticleRemoteImage.init asks the cache), moves the prefetch window, and two queued
        // loads complete before the next card appears.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            print("    skipped: Low Power Mode turns prefetch off")
            return
        }
        let probe = QueuedImageLoader()
        let prefetch = CardImagePrefetch()
        DecodedImageCache.cardFirstPaints = (0, 0)
        let initial = Task { @MainActor in
            await CardImagePrefetch.first(
                CardImagePrefetch.initialURLs(entries), leadAtFullSize: false, using: probe.loader)
        }
        await probe.settle()
        for (index, entry) in entries.enumerated() {
            if let url = entry.cardImageURL { _ = ArticleRemoteImage(url: url, size: .card) { _ in EmptyView() } }
            prefetch.ahead(of: index, in: entries, using: probe.loader)
            await probe.settle()
            probe.release(2)
            await probe.settle()
        }
        let counts = DecodedImageCache.cardFirstPaints ?? (0, 0)
        assertEqual(counts.placeholders + counts.images, 180, "Every card with an image is counted once")
        print("    card placeholders at first paint: \(counts.placeholders) of 180")
        assertTrue(
            Double(counts.placeholders) <= 0.05 * 180, "At most 5% of cards show a placeholder at first paint")
        let others = Set(probe.requests).subtracting(cardURLs)
        assertTrue(others.isEmpty, "Only the images cards show are fetched (\(others.count) others)")
        assertTrue(
            !probe.pixelBounds.isEmpty && probe.pixelBounds.allSatisfy { $0 == DecodedImageCache.Size.card.maxPixels },
            "Without a lead, every card prefetch decodes at card size, never at the reader's bound")
        assertEqual(stubborn.pixelBounds, [DecodedImageCache.Size.full.maxPixels], "A plain load decodes at full size")
        prefetch.reset()
        initial.cancel()
        while probe.queued > 0 {
            probe.release(probe.queued)
            await probe.settle()
        }
        _ = await initial.value
    }

    @MainActor
    static func testSpotlightSavedStoriesIndexing() async throws {
        print("  - Testing Spotlight indexing of saved stories (#559)...")
        let mockIndexer = MockSpotlightIndexer()
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: mockIndexer)
        await store.initialize()
        let savedManager = SavedStoriesManager(articleStore: store)

        let pubDate = Date(timeIntervalSince1970: 1_730_000_000)
        let article = FeedArticle(
            storedID: "spotlight-unit-1",
            title: "Breakthrough in Fusion Energy",
            link: "https://example.com/fusion-1",
            guid: "spotlight-unit-1",
            description: "Scientists achieved sustained net energy gain.",
            pubDate: pubDate,
            source: "Science Daily"
        )
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/rss")

        // 1. Saving a story indexes CSSearchableItem with title, publisher, summary, date, and news://story/<id>
        savedManager.save(article)
        await savedManager.waitForPendingChanges()

        let item = await mockIndexer.item(for: "spotlight-unit-1")
        assertTrue(item != nil, "Saving a story indexes a CSSearchableItem (#559)")
        assertEqual(
            item?.domainIdentifier, "com.marspater.news.saved-stories",
            "Spotlight item uses saved-stories domain (#559)"
        )
        assertEqual(item?.attributeSet.title, "Breakthrough in Fusion Energy", "Spotlight item preserves title")
        assertEqual(item?.attributeSet.publishers, ["Science Daily"], "Spotlight item preserves publisher")
        assertEqual(
            item?.attributeSet.contentDescription,
            "Scientists achieved sustained net energy gain.",
            "Spotlight item preserves summary"
        )
        assertEqual(item?.attributeSet.contentCreationDate, pubDate, "Spotlight item preserves publication date")
        assertEqual(
            item?.attributeSet.contentURL?.absoluteString,
            "news://story/spotlight-unit-1",
            "Spotlight item links to news://story/<id> (#559)"
        )
        let scopedID = "https://example.com/feed.xml#guid:https://example.com/story%201/"
        let scopedArticle = FeedArticle(
            storedID: scopedID, title: "Scoped", link: "https://example.com/story%201/",
            guid: "https://example.com/story%201/", description: "Summary", pubDate: pubDate, source: "Science Daily")
        let scopedURL = SystemSpotlightIndexer.makeSearchableItem(for: scopedArticle).attributeSet.contentURL
        assertEqual(
            scopedURL.flatMap { NewsURLParser.parse(url: $0, allowInsecureHTTP: false) },
            .story(id: scopedID),
            "Spotlight contentURL round-trips scoped GUIDs with percent-encoding and trailing slashes"
        )

        // 2. Clear All Caches preserves saved-story Spotlight items
        try await store.clearAllDatabaseCache()
        let preserved = await mockIndexer.contains(id: "spotlight-unit-1")
        assertTrue(preserved, "Clear All Caches preserves saved-story Spotlight items (#559)")

        // 3. Unsaving removes the CSSearchableItem
        savedManager.remove(article)
        await savedManager.waitForPendingChanges()
        let afterRemove = await mockIndexer.contains(id: "spotlight-unit-1")
        assertFalse(afterRemove, "Unsaving a story removes its CSSearchableItem (#559)")

        // 4. Library reset / removeAllSavedStories clears the Spotlight domain
        savedManager.save(article)
        await savedManager.waitForPendingChanges()
        assertTrue(await mockIndexer.contains(id: "spotlight-unit-1"), "Re-saved story is indexed again")
        savedManager.removeAll()
        await savedManager.waitForPendingChanges()
        assertEqual(await mockIndexer.getIndexedCount(), 0, "Removing all saved stories purges Spotlight domain (#559)")

        // 5. A rebuild keeps exactly the open library's saved stories, dropping a previous library's entries (#812)
        savedManager.save(article)
        await savedManager.waitForPendingChanges()
        let previous = FeedArticle(
            storedID: "spotlight-previous-library", title: "Previous library", link: "https://example.com/previous",
            guid: "spotlight-previous-library", description: "", pubDate: pubDate, source: "Old")
        await mockIndexer.indexSavedArticle(previous)
        await store.rebuildSpotlightIndex()
        assertFalse(
            await mockIndexer.contains(id: "spotlight-previous-library"),
            "Rebuild drops entries the open library does not hold (#812)")
        assertTrue(
            await mockIndexer.contains(id: "spotlight-unit-1"), "Rebuild indexes the library's saved stories (#812)")

        // 6. A generated summary never reaches the entry, so Clear AI Analysis leaves none behind (#983)
        let generated = "Model-written summary of the fusion story."
        let analysis = ArticleAnalysis(
            summary: generated, keyPoints: [], entities: [], category: "Science",
            modelIdentifier: "test", analysisVersion: 1)
        await store.saveArticleAnalysis(analysis, for: "spotlight-unit-1")
        await store.rebuildSpotlightIndex()
        let withSummary = await mockIndexer.item(for: "spotlight-unit-1")
        assertEqual(
            withSummary?.attributeSet.contentDescription, "Scientists achieved sustained net energy gain.",
            "A saved story with a generated summary is indexed with the publisher description only (#983)")
        try await store.clearAIAnalysis()
        await store.rebuildSpotlightIndex()
        let afterClear = await mockIndexer.item(for: "spotlight-unit-1")
        assertEqual(
            afterClear?.attributeSet.contentDescription, "Scientists achieved sustained net energy gain.",
            "The entry stays and holds the publisher description, not the generated summary, after a clear (#983)")
        // A story that already carries a generated summary when it is saved (no rebuild involved)
        let later = FeedArticle(
            storedID: "spotlight-unit-2", title: "Fusion Follow-up", link: "https://example.com/fusion-2",
            guid: "spotlight-unit-2", description: "Follow-up from the publisher.", pubDate: pubDate,
            source: "Science Daily")
        await store.batchUpsert(articles: [later], feedUrl: "https://example.com/rss")
        await store.saveArticleAnalysis(analysis, for: "spotlight-unit-2")
        let summarised = try await db.fetchArticles().first { $0.id == "spotlight-unit-2" }
        assertEqual(summarised?.aiSummary, generated, "The unsaved story carries its generated summary")
        savedManager.save(summarised ?? later)
        await savedManager.waitForPendingChanges()
        assertEqual(
            await mockIndexer.item(for: "spotlight-unit-2")?.attributeSet.contentDescription,
            "Follow-up from the publisher.",
            "Saving a story with a summary indexes the publisher description only (#983)")
        try await store.clearAIAnalysis()
        assertEqual(
            await mockIndexer.item(for: "spotlight-unit-2")?.attributeSet.contentDescription,
            "Follow-up from the publisher.",
            "The saved entry still holds no generated text after Clear AI Analysis (#983)")
        var enriched = article
        enriched.aiSummary = generated
        assertEqual(
            SystemSpotlightIndexer.makeSearchableItem(for: enriched).attributeSet.contentDescription,
            "Scientists achieved sustained net energy gain.",
            "An article carrying aiSummary still indexes the publisher description (#983)")
        await db.close()
    }

    @MainActor
    static func testMenuBarExtraSettingsAndUnreadCount() async {
        print("  - Testing Menu Bar Extra preference and unread count source (#561)...")
        let suite = testDefaultsSuite("test.menubar-extra")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }

        let settings = AppSettings(defaults: defaults)
        assertFalse(settings.showsMenuBarExtra, "Show in Menu Bar is off by default (#561)")

        settings.setShowsMenuBarExtra(true)
        assertTrue(settings.showsMenuBarExtra, "setShowsMenuBarExtra(true) updates published property")
        assertTrue(
            defaults.bool(forKey: AppSettings.showsMenuBarExtraKey),
            "Show in Menu Bar preference persists in UserDefaults (#561)"
        )

        let reloaded = AppSettings(defaults: defaults)
        assertTrue(reloaded.showsMenuBarExtra, "Reloaded AppSettings restores Show in Menu Bar preference")

        reloaded.setShowsMenuBarExtra(false)
        assertFalse(reloaded.showsMenuBarExtra, "setShowsMenuBarExtra(false) disables Menu Bar Extra")

        // Verify unreadCount source matches ArticleStore.unreadCount
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let readManager = ReadManager(articleStore: store)
        let a1 = FeedArticle(
            storedID: "mb-1", title: "Unread 1", link: "https://example.com/mb1",
            guid: "mb-1", description: "", pubDate: Date(), source: "Source"
        )
        let a2 = FeedArticle(
            storedID: "mb-2", title: "Unread 2", link: "https://example.com/mb2",
            guid: "mb-2", description: "", pubDate: Date(), source: "Source"
        )
        await store.batchUpsert(articles: [a1, a2], feedUrl: "https://example.com/rss")
        assertEqual(store.unreadCount, 2, "ArticleStore.unreadCount reflects 2 unread stories")
        readManager.markAsRead("mb-1")
        await readManager.waitForPendingChanges()
        assertEqual(store.unreadCount, 1, "ArticleStore.unreadCount decrements to 1 when story is marked read")
        await db.close()
    }

    // MARK: - Hybrid Search & RRF Tests (#708)

    @MainActor
    static func testStoryQuickLookPreview() async {
        print("  - Testing the Quick Look preview: local content, upright page, no remote references (#707)...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "com.marspater.news.quicklook.test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Remote links and a tracking pixel in the feed text must never reach the preview.
        let article = FeedArticle(
            storedID: "test-ql-1",
            title: "Autonomous Space Tug Successfully Completes Orbital Test",
            link: "https://publisher.example.com/stories/space-tug-2026",
            guid: "space-tug-12345",
            description:
                "<p>The orbital tug demonstrated automated rendezvous with a target satellite. <a href=\"https://tracking.adnetwork.com/click?id=99\">Read sponsor message</a></p>",
            pubDate: Date(timeIntervalSince1970: 1_770_000_000),
            source: "Aerospace Daily",
            imageUrl: "https://images.example.com/satellite.jpg",
            fullContent:
                "Full story with tracker: <img src=\"https://tracker.analytics.com/pixel.gif\" /> and more content."
        )

        let renderData = StoryQuickLookRenderer.renderData(for: article)
        assertEqual(renderData.title, article.title, "Render data captures article title")
        assertEqual(renderData.publisher, "Aerospace Daily", "Render data uses publisher name")
        assertTrue(renderData.image == nil, "An image that is not decoded yet is never fetched for the preview")
        assertFalse(renderData.excerpt.isEmpty, "Excerpt is extracted from local data")
        assertFalse(renderData.excerpt.contains("<"), "HTML is stripped from the excerpt")

        for isDark in [false, true] {
            let previewFile = tempDir.appendingPathComponent("preview-\(isDark).pdf")
            assertTrue(
                StoryQuickLookRenderer.renderPDF(data: renderData, to: previewFile, isDark: isDark),
                "renderPDF succeeds offline (dark: \(isDark))")
            let pdfData = (try? Data(contentsOf: previewFile)) ?? Data()
            let pdfString = String(bytes: pdfData, encoding: .isoLatin1) ?? ""
            for marker in ["http://", "https://", "/URI", "/Launch", "adnetwork", "tracker"] {
                assertFalse(pdfString.contains(marker), "Generated PDF contains no \(marker) (dark: \(isDark))")
            }

            // PDF space has its origin at the bottom left, so text near the top of the page has a large y.
            guard let page = PDFDocument(url: previewFile)?.page(at: 0), let text = page.string as NSString? else {
                assertTrue(false, "The preview PDF has a readable page (dark: \(isDark))")
                continue
            }
            // The page's extracted text and its annotations carry no link either.
            for marker in ["http://", "https://", "www.", "adnetwork", "tracker"] {
                assertFalse((text as String).contains(marker), "Page text contains no \(marker) (dark: \(isDark))")
            }
            assertTrue(page.annotations.isEmpty, "The preview page has no annotations or link actions")
            let height = page.bounds(for: .mediaBox).height
            let titleBounds = page.selection(for: text.range(of: "Autonomous Space Tug"))?.bounds(for: page) ?? .zero
            let footerBounds = page.selection(for: text.range(of: "Open in Reader"))?.bounds(for: page) ?? .zero
            assertTrue(titleBounds.minY > height * 0.7, "The headline sits at the top of an upright page")
            assertTrue(
                footerBounds.maxY > 0 && footerBounds.maxY < height * 0.15, "The footer sits at the bottom of the page")
        }
    }
}
