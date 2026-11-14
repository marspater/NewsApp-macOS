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
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Native port of the `SocketTests` atom (#1070): the same four loopback socket tests, in the runner's order, each
/// still wrapped in `NewsTests.rerunningLoopbackFlake` (it only prints and reruns a test once on a loopback transport
/// error), with each `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of
/// NativeExpectations.swift and each force unwrap in a throwing scope into `#require` (the runner log is invisible to
/// Swift Testing), so a failure is recorded and later tests still run. The runner gives the atom its own serial lane;
/// here `NativeSuites` runs one test at a time. Helpers that assert (`eventually`, `socksConnect`,
/// `holdCancellationResponse`, `verifyWebKitBoundary`) have native copies below; the rest stay in SocketTests.swift and
/// NewsTestSupport.swift, which other native suites reach through `NewsTests`. The runner keeps its copy until CI shows
/// parity.
extension NativeSuites {
    @Suite(.tags(.socket, .integration)) struct SocketSuite {
        @Test @MainActor func gatewayRejectionIsTransport() async throws {
            try await NewsTests.rerunningLoopbackFlake(Self.testGatewayRejectionIsTransport)
        }
        @Test @MainActor func socketNetworkBoundary() async throws {
            try await NewsTests.rerunningLoopbackFlake(Self.testSocketNetworkBoundary)
        }
        @Test @MainActor func transportCancellation() async throws {
            try await NewsTests.rerunningLoopbackFlake(Self.testTransportCancellation)
        }
        @Test @MainActor func gatewayAddressFallback() async throws {
            try await NewsTests.rerunningLoopbackFlake(Self.testGatewayAddressFallback)
        }
    }
}

extension NativeSuites.SocketSuite {
    /// `NewsTests.eventually`, recording its timeout through Swift Testing instead of the runner's failure log.
    static func eventually(
        _ message: String, timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                expectTrue(false, message)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `NewsTests.socksConnect`, recording its greeting check through Swift Testing instead of the runner's log.
    static func socksConnect(_ proxy: NetworkBoundaryProxy, host: String, command: UInt8 = 1, port: UInt16 = 80)
        async throws -> (NWConnection, Data)
    {
        let endpoint: UInt16
        do { endpoint = try await proxy.port() } catch {
            throw NewsTests.loopbackFailure("listener start (NetworkBoundaryProxy, port .any)", error)
        }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint)!, using: .tcp)
        // A loopback connect can fail with EADDRINUSE when parallel runs churn ephemeral ports. NWConnection
        // then parks in .waiting and never completes a send, so surface that state instead of hanging.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = NewsTests.SocketObservation()
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
            throw NewsTests.loopbackFailure("connect to 127.0.0.1:\(endpoint)", error)
        }
        client.stateUpdateHandler = nil
        try await NewsTests.socketSend(client, Data([5, 1, 0]))
        expectEqual(try await NewsTests.socketRead(client, count: 2), Data([5, 0]), "SOCKS greeting succeeds")
        let hostBytes = Data(host.utf8)
        var request = Data([5, command, 0, 3, UInt8(hostBytes.count)])
        request.append(hostBytes)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 255)])
        // Fragment across every protocol boundary, not just a single network packet.
        try await NewsTests.socketSend(client, Data(request.prefix(1)))
        try await NewsTests.socketSend(client, Data(request.dropFirst()))
        return (client, try await NewsTests.socketRead(client, count: 10))
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
            expectTrue(NetworkBoundaryProxy.directParameters.preferNoProxies, "Upstream asks for no proxy (#929)")
            expectTrue(NetworkBoundaryProxy.permitsUpstream(proxyConfigured: false), "A direct connection may relay")
            expectTrue(!NetworkBoundaryProxy.permitsUpstream(proxyConfigured: true), "A proxied connection is refused")
            expectTrue(!NetworkBoundaryProxy.permitsUpstream(proxyConfigured: nil), "A missing report is refused")
            let client = SecureHTTPClient(gateway: gateway, resolver: { _ in publicAddress })
            let result = await FeedFetcher(client: client).fetchSingleFeed(urlString: "https://example.com/feed.xml")
            await gateway.stop()
            return result.error?.failureKind
        }
        expectEqual(
            await failure(gatewayAnswer: publicAddress), .transport,
            "An upstream that refuses is a transport failure")
        expectEqual(
            await failure(gatewayAnswer: .unresolvable(reason: "Timed out")), .transport,
            "A lookup the gateway could not finish is a transport failure")
    }

    /// Hold a real HTTP response open until cancellation closes the upstream socket.
    static func holdCancellationResponse(
        _ connection: NWConnection, ready: NewsTests.SocketObservation,
        closed: NewsTests.SocketObservation, request: Data = Data()
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
                    expectTrue(
                        error == nil && eof && (bytes?.isEmpty ?? true),
                        "The proxy forwards the client's write-close before the response")
                    connection.send(
                        content: Data(repeating: 120, count: 65536), contentContext: .finalMessage,
                        completion: .contentProcessed { error in
                            expectTrue(error == nil, "The upstream sends its complete response after request EOF")
                            closed.recordText("drain")
                            connection.cancel()
                        })
                }
                return
            }
            expectTrue(
                header.hasPrefix("GET /headers/") || header.hasPrefix("GET /body/"),
                "Only the cancellation fixture is requested")
            let waitForClose: @Sendable () -> Void = {
                ready.recordText(header)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { _, _, eof, error in
                    expectTrue(eof || error != nil, "Cancellation closes the upstream transport")
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
                        expectTrue(error == nil, "The partial HTTP body is written before cancellation")
                        waitForClose()
                    })
            } else {
                waitForClose()
            }
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
        let held = NewsTests.SocketObservation()
        let heldClosed = NewsTests.SocketObservation()
        silent.newConnectionHandler = { connection in
            held.recordText("held")
            connection.start(queue: silentQueue)
            NewsTests.recordClose(connection, closed: heldClosed)
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
            let operation = "listener start (\(listener === silent ? "silent" : "upstream"), port .any)"
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = NewsTests.SocketObservation()
                listener.stateUpdateHandler = { state in
                    if case .ready = state, once.claim() { continuation.resume() }
                    if case .failed(let error) = state, once.claim() {
                        continuation.resume(throwing: NewsTests.loopbackFailure(operation, error))
                    }
                }
                let queue = listener === silent ? silentQueue : upstreamQueue
                queue.asyncAfter(deadline: .now() + 5) {
                    if once.claim() {
                        listener.cancel()
                        continuation.resume(throwing: NewsTests.loopbackFailure(operation, NewsTests.LoopbackTimeout()))
                    }
                }
                listener.start(queue: queue)
            }
        }
        defer {
            silent.cancel()
            upstream.cancel()
        }
        let observed = NewsTests.SocketObservation()
        let silentPort = try #require(silent.port)
        let upstreamPort = try #require(upstream.port)
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
        expectEqual(reply[1], 0, "The second address connects while the first is still waiting")
        expectTrue(elapsed < .seconds(5), "The fallback takes about a quarter second, not the handshake timeout")
        expectEqual(
            observed.hosts, ["2606:4700::1111", "93.184.216.34"], "IPv6 was tried first, IPv4 after the delay")
        // The silent listener records the accept on its own queue, after the winner's reply can already be here.
        await eventually("The dead attempt reached the silent proxy") { held.count >= 1 }
        expectEqual(held.count, 1, "The dead attempt reached the silent proxy exactly once")
        try await NewsTests.socketSend(client, Data("fallback".utf8))
        expectEqual(
            try await NewsTests.socketRead(client, count: 8), Data("fallback".utf8), "The tunnel relays over the winner"
        )
        // Before the client closes: only the winner's selection, not the tunnel's shutdown, may close the loser.
        await eventually("The losing attempt is cancelled once the winner connects") { heldClosed.count == 1 }
        client.cancel()
        await proxy.stop()

        // Three stalled attempts fill every slot; the fourth address still starts a stagger later, retiring the
        // oldest, instead of waiting for the handshake timeout.
        let tried = NewsTests.SocketObservation()
        let crowded = NetworkBoundaryProxy(
            resolver: { _ in .allowed(ips: ["93.184.216.1", "93.184.216.2", "93.184.216.3", "93.184.216.4"]) },
            connector: { host, port in
                tried.record(host)
                guard String(describing: host) == "93.184.216.4" else { return silentConnection(host, port) }
                return NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
            })
        let crowdedStart = ContinuousClock.now
        let (crowdedClient, crowdedReply) = try await socksConnect(crowded, host: "crowded.invalid")
        expectEqual(crowdedReply[1], 0, "The fourth address connects while three attempts stall")
        expectTrue(ContinuousClock.now - crowdedStart < .seconds(5), "Stalled attempts do not hold the fourth address")
        expectEqual(tried.hosts.count, 4, "Each address was tried once")
        crowdedClient.cancel()
        await crowded.stop()
    }

    @MainActor
    static func testTransportCancellation() async throws {
        print("  - Testing refresh shutdown over real HTTP/SOCKS sockets...")
        let upstream = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.cancellation.upstream")
        let ready = NewsTests.SocketObservation()
        let closed = NewsTests.SocketObservation()
        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            holdCancellationResponse(connection, ready: ready, closed: closed)
        }
        let operation = "listener start (cancellation upstream, port .any)"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = NewsTests.SocketObservation()
            upstream.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
                if case .failed(let error) = state, once.claim() {
                    continuation.resume(throwing: NewsTests.loopbackFailure(operation, error))
                }
            }
            queue.asyncAfter(deadline: .now() + 5) {
                if once.claim() {
                    upstream.cancel()
                    continuation.resume(throwing: NewsTests.loopbackFailure(operation, NewsTests.LoopbackTimeout()))
                }
            }
            upstream.start(queue: queue)
        }
        defer { upstream.cancel() }
        let port = try #require(upstream.port)
        let observed = NewsTests.SocketObservation()
        let proxy = NetworkBoundaryProxy(connector: { host, _ in
            observed.record(host)
            return NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        })
        let (halfClosed, reply) = try await socksConnect(proxy, host: "93.184.216.34")
        expectEqual(reply[1], 0, "The drain control uses the protected socket")
        try await NewsTests.socketSend(halfClosed, Data("GET /drain HTTP/1.1\r\nHost: 93.184.216.34\r\n\r\n".utf8))
        await eventually("The drain fixture receives the request before its write-close") { ready.count == 1 }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            halfClosed.send(
                content: nil, contentContext: .finalMessage,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
        expectEqual(
            try await NewsTests.socketRead(halfClosed, count: 65536), Data(repeating: 120, count: 65536),
            "A half-closed request drains the entire response across relay buffers")
        do {
            _ = try await NewsTests.socketRead(halfClosed, count: 1)
            expectTrue(false, "The response ends with forwarded EOF")
        } catch let error as FeedError {
            expectEqual(error, .network("EOF"), "The upstream write-close reaches the client after all response bytes")
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
                let done = NewsTests.SocketObservation()
                let count = ready.count
                let refresh = Task {
                    await manager.fetchFeedsAsync()
                    let end = ContinuousClock.now
                    done.recordText("finished")
                    return end
                }
                await eventually("The real HTTP request reaches the held response") { ready.count == count + 1 }
                expectTrue(manager.isAnyFeedLoading, "A stalled response keeps refresh active")
                expectEqual(done.count, 0, "The incomplete HTTP response cannot finish before shutdown")
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
                expectFalse(manager.isAnyFeedLoading, "Shutdown clears refresh loading")
                expectEqual(try await db.counts().total, 0, "Cancellation ingests no partial articles")
                expectEqual(
                    try await db.feedFetchStates()[feed], nil, "Cancellation records no feed failure or validators")
                await db.close()
            }
        }
        expectEqual(observed.count, 11, "The drain control and each cancellation sample use one protected connection")
        expectTrue(
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

    @MainActor
    static func verifyWebKitBoundary(proxy: ProxyConfiguration) async throws {
        for address in [
            "http://127.0.0.1/page", "https://rebind.invalid/page", "http://rebind.invalid/other",
            "http://rebind.invalid:8080/page", "http://user@rebind.invalid/page",
        ] {
            expectFalse(
                NewsTests.WebBoundaryProbe.permitsNavigation(URL(string: address)!),
                "Probe rejects navigation outside its exact fixture")
        }
        expectTrue(
            NewsTests.WebBoundaryProbe.permitsNavigation(URL(string: "http://rebind.invalid/page")!),
            "Probe allows its controlled fixture")
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.configuration.userContentController.add(try await WebPreviewPolicy.contentRules())
        let probe = NewsTests.WebBoundaryProbe()
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

    static func testSocketNetworkBoundary() async throws {
        print("  - Testing socket boundary: pinning, mixed DNS, loopback, malformed commands and fail-closed proxy...")
        let upstream = try NWListener(using: .tcp, on: .any)
        let upstreamQueue = DispatchQueue(label: "test.proxy.upstream")
        let receivedRequests = NewsTests.SocketObservation()
        let live = ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1"
        if live {
            expectTrue(
                {
                    if case .blocked = IPAddressValidator.validateHost("localtest.me") { return true }
                    return false
                }(), "Live DNS-alias control resolves to a private address")
        }
        upstream.newConnectionHandler = { connection in
            connection.start(queue: upstreamQueue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, _ in
                NewsTests.respondToFixture(
                    connection, data: data, port: upstream.port!.rawValue,
                    receivedRequests: receivedRequests, live: live)
            }
        }
        let operation = "listener start (boundary upstream, port .any)"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = NewsTests.SocketObservation()
            upstream.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
                if case .failed(let error) = state, once.claim() {
                    continuation.resume(throwing: NewsTests.loopbackFailure(operation, error))
                }
            }
            upstreamQueue.asyncAfter(deadline: .now() + 5) {
                if once.claim() {
                    upstream.cancel()
                    continuation.resume(throwing: NewsTests.loopbackFailure(operation, NewsTests.LoopbackTimeout()))
                }
            }
            upstream.start(queue: upstreamQueue)
        }
        defer { upstream.cancel() }
        let fixturePort = try #require(upstream.port)
        let observed = NewsTests.SocketObservation()
        let connector: NetworkBoundaryProxy.Connector = { host, _ in
            observed.record(host)
            return NWConnection(host: "127.0.0.1", port: fixturePort, using: .tcp)
        }
        let mixed = NetworkBoundaryProxy(
            resolver: { _ in .allowed(ips: ["93.184.216.34", "127.0.0.1"]) }, connector: connector)
        let (mixedClient, mixedReply) = try await socksConnect(mixed, host: "mixed.invalid")
        expectEqual(mixedReply[1], 2, "Mixed public/private DNS answers are rejected before connecting")
        mixedClient.cancel()
        await mixed.stop()
        let production = NetworkBoundaryProxy(connector: connector)
        for host in [
            "127.0.0.1", "localhost", "2130706433", "0x7f000001", "localhost.", "test.local.", "intranet", "::1",
            "fe80::1%en0",
        ] {
            let (client, reply) = try await socksConnect(production, host: host)
            expectEqual(reply[1], 2, "Private/alternate/scoped address denied at the socket boundary")
            client.cancel()
        }
        let (udpClient, udpReply) = try await socksConnect(production, host: "93.184.216.34", command: 3)
        expectEqual(udpReply[1], 2, "UDP ASSOCIATE is denied")
        try await NewsTests.socketSend(udpClient, Data("trailing".utf8))
        do {
            _ = try await NewsTests.socketRead(udpClient, count: 1)
            expectTrue(false, "Rejected tunnel never relays trailing client bytes")
        } catch let error as FeedError {
            expectEqual(error, .network("EOF"), "Rejected tunnel drains unread bytes and closes without a reset")
        }
        udpClient.cancel()
        let (portClient, portReply) = try await socksConnect(production, host: "93.184.216.34", port: 22)
        expectEqual(portReply[1], 2, "Unapproved ports denied")
        portClient.cancel()
        expectEqual(observed.count, 0, "Rejected requests never construct an upstream connection")
        await production.stop()
        let allowed = NetworkBoundaryProxy(
            resolver: { host in
                ["rebind.invalid", "93.184.216.34", "assets.invalid"].contains(host)
                    ? .allowed(ips: ["93.184.216.34"]) : IPAddressValidator.validateHost(host)
            }, connector: connector)
        let (client, reply) = try await socksConnect(allowed, host: "rebind.invalid")
        expectEqual(reply[1], 0, "Approved destinations connect")
        try await NewsTests.socketSend(client, Data("relay proof".utf8))
        expectEqual(
            try await NewsTests.socketRead(client, count: 11), Data("relay proof".utf8),
            "Tunnel forwards data without rewriting it")
        client.cancel()
        expectEqual(
            observed.hosts, ["93.184.216.34"], "Connector receives the validated numeric IP, never the DNS hostname")
        let configuration = URLSessionConfiguration.ephemeral
        let proxy = try await allowed.configuration()
        expectFalse(proxy.allowFailover, "Native proxy may not fall back to direct connections")
        configuration.proxyConfigurations = [proxy]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let (body, _) = try await session.data(from: URL(string: "http://93.184.216.34/")!)
        expectEqual(String(decoding: body, as: UTF8.self), "OK", "Native URLSession uses the protected SOCKS tunnel")
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
        expectEqual(cachedImage, firstImage, "Cached image preserves publisher bytes")
        expectEqual(receivedRequests.count, initialRequests + 1, "Fresh images use one protected upstream request")
        do {
            _ = try await imageClient.fetchImage(from: imageURL)
            expectTrue(false, "Cached HTTP images cannot bypass disabled HTTP policy")
        } catch is URLError {
            // With HTTP off the address is requested over HTTPS instead (#794), which this plain-HTTP fixture cannot
            // answer: the cached http bytes are never returned.
        }
        _ = try await imageClient.fetchArticleHTML(from: imageURL, allowHTTP: true)
        expectEqual(receivedRequests.count, initialRequests + 2, "Article fetching still reloads cached URLs")
        let uncachedURL = URL(string: "http://93.184.216.34/uncached-image.svg")!
        _ = try await imageClient.fetchImage(from: uncachedURL, allowHTTP: true)
        _ = try await imageClient.fetchImage(from: uncachedURL, allowHTTP: true)
        expectEqual(receivedRequests.count, initialRequests + 4, "No-store images are fetched again")
        try await verifyWebKitBoundary(proxy: proxy)
        let paths = receivedRequests.hosts
        expectTrue(paths.contains { $0.contains("/style.css ") }, "WebKit stylesheet traverses the protected proxy")
        expectTrue(paths.contains { $0.contains("/image.svg ") }, "WebKit image traverses the protected proxy")
        expectFalse(
            paths.contains { $0.contains("/forbidden") }, "WebKit does not contact the reachable private fixture")
        await allowed.stop()
        let requestCount = receivedRequests.count
        do {
            _ = try await session.data(from: URL(string: "http://rebind.invalid/forbidden-after-stop")!)
            expectTrue(false, "Stopped gateway must not fall back to direct transport")
        } catch {
            // Failure is expected: the preceding assertion rejects an unexpected success.
        }
        expectEqual(
            receivedRequests.count, requestCount, "Stopped proxy never falls back to a reachable direct endpoint")
        if live {
            let publicURL = URL(string: "https://www.nasa.gov/feed/")!
            let directControl = URLSession(configuration: .ephemeral)
            let (controlBody, _) = try await directControl.data(from: publicURL)
            expectFalse(controlBody.isEmpty, "Public control is reachable without the stopped proxy")
            directControl.invalidateAndCancel()
            do {
                _ = try await session.data(from: publicURL)
                expectTrue(false, "Stopped proxy cannot fall back to a proven reachable public host")
            } catch {
                // The stopped proxy must reject the otherwise reachable public endpoint.
            }
        }
        session.invalidateAndCancel()
        for host in ["::127.0.0.1", "2002:7f00:1::", "2001::1", "2001:db8::1", "198.18.0.1", "192.0.2.1"] {
            expectTrue(
                IPAddressValidator.checkLiteralIP(host) != nil,
                "Transition/reserved addresses cannot escape the public boundary")
        }
        // A gateway that stopped or failed after startup restarts on next use; the client follows its new port.
        let gatewayClient = SecureHTTPClient(gateway: allowed, resolver: { _ in .allowed(ips: ["93.184.216.34"]) })
        let restartURL = URL(string: "http://93.184.216.34/restart")!
        let (beforeStop, _) = try await gatewayClient.fetchArticleHTML(from: restartURL, allowHTTP: true)
        expectEqual(String(decoding: beforeStop, as: UTF8.self), "OK", "The client reaches the gateway it started")
        await allowed.stop()
        let (afterStop, _) = try await gatewayClient.fetchArticleHTML(from: restartURL, allowHTTP: true)
        expectEqual(
            String(decoding: afterStop, as: UTF8.self), "OK", "The next request after a gateway stop succeeds")
        await allowed.stop()
    }

}
