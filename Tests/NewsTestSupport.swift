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

// Shared by the test atoms; no entry point, so a change here selects every atom (script/changed_atoms.sh).

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

/// Failures the assertions, `recordFailure` and `runSuite` collect in this process. Tests/Runner.swift prints the
/// summary and sets the exit status once the atom has run, so one failure no longer hides the tests after it.
final class TestFailureLog: @unchecked Sendable {
    static let shared = TestFailureLog()
    private let lock = NSLock()
    /// The test failures are filed under; runSuite names each test, other atoms report under the atom.
    private var current = ProcessInfo.processInfo.environment["NEWS_TEST_ATOM"] ?? "runner"
    private var failures: [(test: String, line: String)] = []
    private var timings: [(test: String, duration: Duration)] = []

    var count: Int { lock.withLock { failures.count } }
    func begin(_ test: String) { lock.withLock { current = test } }
    func record(_ line: String) { lock.withLock { failures.append((current, line)) } }
    func time(_ test: String, _ duration: Duration) { lock.withLock { timings.append((test, duration)) } }

    /// Prints each failed test with its first failure line, then exits 1 if anything failed and 0 otherwise.
    func finish() -> Never {
        let (failures, timings) = lock.withLock { (self.failures, self.timings) }
        if ProcessInfo.processInfo.environment["NEWS_TEST_TIMING"] == "1" {
            for timing in timings { print("    ⏱ \(timing.test) \(timing.duration)") }
        }
        var order: [String] = []
        var first: [String: String] = [:]
        for failure in failures where first[failure.test] == nil {
            order.append(failure.test)
            first[failure.test] = failure.line
        }
        guard !order.isEmpty else { exit(0) }
        print("❌ \(order.count) failed test(s), \(failures.count) failure(s):")
        for test in order { print("   \(test): \(first[test]!)") }
        exit(1)
    }
}

/// Prints and records a failure without stopping the test; for checks the assertions below do not cover.
func recordFailure(_ message: String, file: String = #file, line: Int = #line) {
    print("❌ \(message)")
    print("   Location: \(file):\(line)")
    TestFailureLog.shared.record("\(message) (\(file):\(line))")
}

func assertEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line
) {
    if actual != expected {
        print("❌ ASSERTION FAILED: \(message)")
        print("   Expected: \(expected)")
        print("   Actual:   \(actual)")
        print("   Location: \(file):\(line)")
        TestFailureLog.shared.record(
            "ASSERTION FAILED: \(message) (expected \(expected), actual \(actual)) (\(file):\(line))")
    }
}

func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message) (expected true, got false)")
        print("   Location: \(file):\(line)")
        TestFailureLog.shared.record("ASSERTION FAILED: \(message) (expected true, got false) (\(file):\(line))")
    }
}

func assertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        print("❌ ASSERTION FAILED: \(message) (expected false, got true)")
        print("   Location: \(file):\(line)")
        TestFailureLog.shared.record("ASSERTION FAILED: \(message) (expected false, got true) (\(file):\(line))")
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

extension NewsTests {
    /// Runs an atom's tests in order, one after another in this process. A test that throws is recorded and the next
    /// one runs; Tests/Runner.swift prints the summary. NEWS_TEST_TIMING=1 prints each duration.
    static func runSuite(_ tests: [(name: String, run: () async throws -> Void)]) async throws {
        let timing = ProcessInfo.processInfo.environment["NEWS_TEST_TIMING"] == "1"
        for test in tests {
            TestFailureLog.shared.begin(test.name)
            let start = ContinuousClock.now
            do { try await test.run() } catch { recordFailure("\(test.name) threw: \(error)") }
            let duration = ContinuousClock.now - start
            TestFailureLog.shared.time(test.name, duration)
            if timing { print("    ⏱ \(test.name) \(duration)") }
        }
    }

    /// The fixture URL the suites resolve their documents against.
    static let defaultFixtureHost = "example.com"
    static let defaultFixtureRoot = URL(string: "https://\(defaultFixtureHost)")!

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

    actor TestCounter {
        var value: Int = 0
        func increment() { value += 1 }
    }

    struct SimulatedRefreshError: Error, Equatable {}

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
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = SocketObservation()
                client.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.claim() { continuation.resume() }
                    case .waiting(let error), .failed(let error):
                        if once.claim() { continuation.resume(throwing: error) }
                    case .cancelled: if once.claim() { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                client.start(queue: .global())
            }
        } catch {
            client.stateUpdateHandler = nil
            client.cancel()
            throw error
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

    static func extractDialogText(from result: some IntentResult) -> String? {
        let mirror = Mirror(reflecting: result)
        for child in mirror.children where child.label == "dialog" {
            let desc = String(describing: child.value)
            if desc.starts(with: "nil") || desc == "Optional(nil)" { return nil }
            return desc
        }
        return nil
    }
}
