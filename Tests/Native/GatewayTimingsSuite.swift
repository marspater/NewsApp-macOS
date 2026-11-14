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
import Network
import Testing

/// Native port of the `GatewayTimingsTests` atom (#1070): the same checks, in the runner's order, with each `check`
/// turned into `expectTrue` of NativeExpectations.swift, the port force unwrap into `#require` and the run's catch-all
/// into a throwing test, so a failure is recorded against its line. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.networking, .integration)) struct GatewayTimingsSuite {
        @Test func aggregation() { Self.checkAggregation() }
        @Test func export() { Self.checkExport() }
        @Test func tunnel() async throws { try await Self.checkTunnel() }
    }
}

extension NativeSuites.GatewayTimingsSuite {
    static func checkAggregation() {
        let timings = GatewayTimings(capacity: 2)
        timings.record(.dns, seconds: 0.1, host: "A.example")
        timings.record(.dns, seconds: 0.3, host: "a.example")
        timings.record(.connect, seconds: -1, host: "a.example")
        let host = timings.snapshot()["a.example"]
        expectTrue(host?[.dns]?.count == 2 && abs((host?[.dns]?.mean ?? 0) - 0.2) < 1e-9, "stages average per host")
        expectTrue(host?[.dns]?.slowest == 0.3, "the slowest is kept")
        expectTrue(host?[.connect]?.total == 0, "a clock step cannot record negative time")
        expectTrue(host?[.firstByte] == nil, "a stage never reached has no entry")
        timings.record(.dns, seconds: 1, host: "b.example")
        timings.record(.dns, seconds: 1, host: "c.example")
        timings.record(.dns, seconds: 1, host: "d.example")
        timings.record(.dns, seconds: 1, host: "a.example")
        let full = timings.snapshot()
        expectTrue(full["c.example"] == nil && full["d.example"] == nil, "hosts past the capacity keep no name")
        expectTrue(full[GatewayTimings.overflowHost]?[.dns]?.count == 2, "their times still count")
        expectTrue(full["a.example"]?[.dns]?.count == 3, "a known host keeps its entry when full")
    }

    static func checkExport() {
        let timings = GatewayTimings()
        timings.record(.dns, seconds: 0.012, host: "feed.example")
        timings.record(.connect, seconds: 0.05, host: "feed.example")
        timings.record(.firstByte, seconds: 0.2, host: "feed.example")
        timings.record(.dns, seconds: 0.1, host: "secret-story.example")
        timings.record(.dns, seconds: 0.3, host: "images.example")
        let text = DiagnosticsExport.gatewayTiming(
            timings.snapshot(), feedURLs: ["https://Feed.example/rss?token=abc", "https://quiet.example/rss"])
        expectTrue(
            text.contains(
                "feed.example: DNS wait mean 12 ms, slowest 12 ms, 1 samples; connect mean 50 ms, slowest 50 ms, 1 samples; first byte after connect mean 200 ms, slowest 200 ms, 1 samples"
            ), "a subscription reads by host and stage: \(text)")
        expectTrue(
            !text.contains("secret-story") && !text.contains("images.example"),
            "a host outside the subscriptions is never named")
        expectTrue(
            text.contains("Other hosts, combined: DNS wait mean 200 ms, slowest 300 ms, 2 samples"),
            "other hosts are combined")
        expectTrue(!text.contains("token") && !text.contains("/rss"), "no path or query reaches the file")
        expectTrue(!text.contains("quiet.example"), "a subscription with no requests has no line")
        expectTrue(
            DiagnosticsExport.gatewayTiming([:], feedURLs: []).contains("No gateway requests this launch"),
            "an idle gateway says so")
    }

    /// A real tunnel over loopback: one request records all three stages.
    static func checkTunnel() async throws {
        let upstream = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.gateway-timings.upstream")
        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = CompletionOnce()
            upstream.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { continuation.resume() }
                if case .failed(let error) = state, once.claim() { continuation.resume(throwing: error) }
            }
            upstream.start(queue: queue)
        }
        defer { upstream.cancel() }
        let port = try #require(upstream.port)
        let host = "timed-\(UUID().uuidString.lowercased()).invalid"
        let proxy = NetworkBoundaryProxy(
            resolver: { _ in .allowed(ips: ["93.184.216.34"]) },
            connector: { _, _ in NWConnection(host: "127.0.0.1", port: port, using: .tcp) })
        let (client, reply) = try await NativeSuites.SocketSuite.socksConnect(proxy, host: host)
        expectTrue(reply[1] == 0, "the tunnel connects")
        // The helpers time out and cancel the connection, so a missing echo fails the check instead of waiting
        // for the relay's idle timeout.
        defer { client.cancel() }
        do {
            try await NewsTests.socketSend(client, Data("ping".utf8))
            let echo = try await NewsTests.socketRead(client, count: 4)
            expectTrue(echo == Data("ping".utf8), "the tunnel echoes the request")
        } catch {
            expectTrue(false, "the tunnel echo failed: \(error)")
        }
        // The first byte is recorded on the tunnel's queue before it is forwarded, so it has landed by now.
        let times = GatewayTimings.shared.snapshot()[host]
        expectTrue(times?[.dns]?.count == 1, "the tunnel records its DNS wait")
        expectTrue(times?[.connect]?.count == 1, "the tunnel records its connect")
        expectTrue(times?[.firstByte]?.count == 1, "the tunnel records the first byte back")
        await proxy.stop()
    }
}
