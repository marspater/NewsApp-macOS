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

/// Native port of the `NetworkingTests` atom (#1070): the same eleven tests, in the runner's order, with each
/// `assertEqual`/`assertTrue`/`assertFalse` turned into the matching `expect` helper of NativeExpectations.swift and
/// each caught `recordFailure` into `expectTrue(false, ...)` (the runner log is invisible to Swift Testing), so a
/// failure is recorded and later tests still run. The runner keeps its copy until CI shows parity.
extension NativeSuites {
    @Suite(.tags(.networking, .integration)) struct NetworkingSuite {
        @Test func urlNormalization() async { await Self.testURLNormalization() }
        @Test func ssrfValidation() async { await Self.testSSRFValidation() }
        @Test func isBlockedIPv4() async { await Self.testIsBlockedIPv4() }
        @Test func ipAddressValidatorDeep() async { await Self.testIPAddressValidatorDeep() }
        @Test func secureHTTPClientFetchImage() async { await Self.testSecureHTTPClientFetchImage() }
        @Test func secureHTTPClientPolicies() async { await Self.testSecureHTTPClientPolicies() }
        @Test func completionOnce() async { await Self.testCompletionOnce() }
        @Test func proxyWaitingClassification() async { await Self.testProxyWaitingClassification() }
        @Test func resolverLifecycle() async { await Self.testResolverLifecycle() }
        @Test func lookupFailsClosedAcrossFamilies() { Self.testLookupFailsClosedAcrossFamilies() }
        @Test func redirectDelegateDoesNoDNS() async { await Self.testRedirectDelegateDoesNoDNS() }
    }
}

extension NativeSuites.NetworkingSuite {
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

    static func testURLNormalization() async {
        print("  - Testing URL Normalization...")

        let url1 = "https://example.com/story?utm_source=feed&utm_medium=rss&ref=share"
        expectEqual(
            ArticleIdentity.canonicalizeURL(url1), "https://example.com/story", "Should strip tracking query parameters"
        )

        let url2 = "https://example.com/path/"
        expectEqual(ArticleIdentity.canonicalizeURL(url2), "https://example.com/path", "Should strip trailing slashes")

        let url3 = "https://EXamPLE.COm/Path/"
        expectEqual(
            ArticleIdentity.canonicalizeURL(url3), "https://example.com/Path",
            "Should lowercase the host and strip trailing slash")

        let url4 = "http://example.com/path"
        expectEqual(ArticleIdentity.canonicalizeURL(url4), "https://example.com/path", "Should upgrade scheme to https")
    }

    static func testSSRFValidation() async {
        print("  - Testing SSRF block list...")

        expectTrue(FeedManager.isBlockedLocalAddress("localhost"), "Should block localhost")
        expectTrue(FeedManager.isBlockedLocalAddress("127.0.0.1"), "Should block 127.0.0.1")
        expectTrue(FeedManager.isBlockedLocalAddress("10.0.1.5"), "Should block private range 10.x")
        expectTrue(FeedManager.isBlockedLocalAddress("192.168.1.100"), "Should block private range 192.168.x")
        expectTrue(FeedManager.isBlockedLocalAddress("172.20.5.5"), "Should block private range 172.16-31.x")
        expectTrue(FeedManager.isBlockedLocalAddress("::1"), "Should block IPv6 loopback")
        expectTrue(FeedManager.isBlockedLocalAddress("fe80::1"), "Should block IPv6 link-local")

        expectTrue(FeedManager.isBlockedLocalAddress("192.0.0.88"), "Should block IETF special-use 192.0.0.0/24")
        // Hostname allowance depends on the local resolver, so it runs only with controlled network checks.
        if ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1" {
            expectFalse(FeedManager.isBlockedLocalAddress("google.com"), "Should allow public hostnames")
        }
        expectFalse(FeedManager.isBlockedLocalAddress("8.8.8.8"), "Should allow public IPs")
        expectFalse(FeedManager.isBlockedLocalAddress("172.15.2.2"), "Should allow public range outside 172.16-31")
    }

    static func testIsBlockedIPv4() async {
        print("  - Testing isBlockedIPv4 directly...")

        func makeInAddr(_ ipString: String) -> in_addr {
            var sin = in_addr()
            inet_pton(AF_INET, ipString, &sin)
            return sin
        }

        // Loopback
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("127.0.0.1")) != nil, "127.0.0.1 must be blocked")

        // Current network
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("0.0.0.0")) != nil, "0.0.0.0 must be blocked")

        // Private
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("10.0.0.1")) != nil, "10.0.0.1 must be blocked")
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("172.16.0.1")) != nil, "172.16.0.1 must be blocked")
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("192.168.0.1")) != nil, "192.168.0.1 must be blocked")

        // Link-Local
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("169.254.0.1")) != nil, "169.254.0.1 must be blocked")

        // Carrier-Grade NAT
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("100.64.0.1")) != nil, "100.64.0.1 must be blocked")

        // Multicast
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("224.0.0.1")) != nil, "224.0.0.1 must be blocked")

        // Broadcast
        expectTrue(
            IPAddressValidator.isBlockedIPv4(makeInAddr("255.255.255.255")) != nil, "255.255.255.255 must be blocked")

        // Valid
        expectTrue(IPAddressValidator.isBlockedIPv4(makeInAddr("8.8.8.8")) == nil, "8.8.8.8 must be allowed")
    }

    static func testIPAddressValidatorDeep() async {
        print("  - Testing IPAddressValidator (IPv4, IPv6, mapped IPv6, DNS)...")

        for host in ["localhost", "printer.local", "127.0.0.1", "169.254.169.254", "[::1]"] {
            let result = IPAddressValidator.validateHost(
                host,
                resolver: { _ in
                    expectTrue(false, "Blocked destinations never reach an injected resolver")
                    return .allowed(ips: ["8.8.8.8"])
                })
            expectTrue(
                {
                    if case .blocked = result { return true }
                    return false
                }(), "Injected DNS cannot bypass hostname/literal guards")
        }
        for (host, address) in [("93.184.216.34", "93.184.216.34"), ("[2606:4700::1111]", "2606:4700::1111")] {
            let result = IPAddressValidator.validateHost(
                host,
                resolver: { _ in
                    expectTrue(false, "Public literals never depend on host DNS or configured address families")
                    return .unresolvable(reason: "No IPv4 interface configured")
                })
            expectEqual(result, .allowed(ips: [address]), "A public literal pins itself without resolution")
        }

        // 1. Literal IPv4 Loopback & Private
        expectTrue(IPAddressValidator.checkLiteralIP("127.0.0.1") != nil, "127.0.0.1 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("127.255.255.255") != nil, "127.255.255.255 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("0.0.0.0") != nil, "0.0.0.0 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("10.254.1.2") != nil, "10.254.1.2 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("172.16.0.1") != nil, "172.16.0.1 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("172.31.255.254") != nil, "172.31.255.254 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("192.168.0.1") != nil, "192.168.0.1 must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("169.254.169.254") != nil, "169.254.169.254 link-local must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("224.0.0.1") != nil, "224.0.0.1 multicast must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("255.255.255.255") != nil, "255.255.255.255 broadcast must be blocked")

        // 2. Allowed Public IPv4
        expectTrue(IPAddressValidator.checkLiteralIP("93.184.216.34") == nil, "example.com public IP must be allowed")
        expectTrue(IPAddressValidator.checkLiteralIP("1.1.1.1") == nil, "1.1.1.1 public IP must be allowed")
        expectTrue(IPAddressValidator.checkLiteralIP("8.8.8.8") == nil, "8.8.8.8 public IP must be allowed")

        // 3. Literal IPv6 Loopback, ULA, Link-Local
        expectTrue(IPAddressValidator.checkLiteralIP("::1") == "IPv6 loopback (::1)", "::1 must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("::") != nil, ":: must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("fe80::1") != nil, "fe80::1 link-local must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("fc00::1") != nil, "fc00::1 ULA must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("fd12:3456::1") != nil, "fd12:3456::1 ULA must be blocked")
        expectTrue(IPAddressValidator.checkLiteralIP("ff02::1") != nil, "ff02::1 multicast must be blocked")

        // 4. IPv4-mapped IPv6 normalization
        expectTrue(
            IPAddressValidator.checkLiteralIP("::ffff:127.0.0.1") != nil,
            "::ffff:127.0.0.1 mapped loopback must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("::ffff:192.168.1.1") != nil,
            "::ffff:192.168.1.1 mapped private must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("::ffff:10.0.0.1") != nil,
            "::ffff:10.0.0.1 mapped private must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("::ffff:93.184.216.34") == nil,
            "::ffff:93.184.216.34 mapped public must be allowed")

        // 5. NAT64 IPv6 normalization
        expectTrue(
            IPAddressValidator.checkLiteralIP("64:ff9b::127.0.0.1")
                == "NAT64 IPv6 (IPv4 loopback address (127.0.0.0/8))",
            "64:ff9b::127.0.0.1 NAT64 loopback must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("64:ff9b::192.168.1.1")
                == "NAT64 IPv6 (RFC 1918 private network (192.168.0.0/16))",
            "64:ff9b::192.168.1.1 NAT64 private must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("64:ff9b::10.0.0.1")
                == "NAT64 IPv6 (RFC 1918 private network (10.0.0.0/8))",
            "64:ff9b::10.0.0.1 NAT64 private must be blocked")
        expectTrue(
            IPAddressValidator.checkLiteralIP("64:ff9b::93.184.216.34") == nil,
            "64:ff9b::93.184.216.34 NAT64 public must be allowed")

        // 6. Hostname string validation
        if case .blocked = IPAddressValidator.validateHost("localhost") {
            // expected
        } else {
            expectTrue(false, "validateHost('localhost') was not blocked")
        }

        if case .blocked = IPAddressValidator.validateHost("test.local") {
            // expected
        } else {
            expectTrue(false, "validateHost('test.local') was not blocked")
        }

        if case .blocked = IPAddressValidator.validateHost("router.internal") {
            // expected
        } else {
            expectTrue(false, "validateHost('router.internal') was not blocked")
        }

        // 7. Socket Address Validation (validateSocketAddress)
        var loopbackAddress = sockaddr_in()
        loopbackAddress.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &loopbackAddress.sin_addr)
        let blockedLoopback = withUnsafePointer(to: &loopbackAddress) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        expectTrue(blockedLoopback != nil, "127.0.0.1 socket address must be blocked")

        var publicAddress = sockaddr_in()
        publicAddress.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "8.8.8.8", &publicAddress.sin_addr)
        let allowedPublic = withUnsafePointer(to: &publicAddress) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        expectTrue(allowedPublic == nil, "8.8.8.8 socket address must be allowed")

        var loopbackIPv6Address = sockaddr_in6()
        loopbackIPv6Address.sin6_family = sa_family_t(AF_INET6)
        inet_pton(AF_INET6, "::1", &loopbackIPv6Address.sin6_addr)
        let blockedLoopback6 = withUnsafePointer(to: &loopbackIPv6Address) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        expectTrue(blockedLoopback6 != nil, "::1 socket address must be blocked")

        var publicIPv6Address = sockaddr_in6()
        publicIPv6Address.sin6_family = sa_family_t(AF_INET6)
        inet_pton(AF_INET6, "2606:4700:4700::1111", &publicIPv6Address.sin6_addr)
        let allowedPublic6 = withUnsafePointer(to: &publicIPv6Address) { ptr -> String? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                IPAddressValidator.validateSocketAddress(sockaddrPtr)
            }
        }
        expectTrue(allowedPublic6 == nil, "2606:4700:4700::1111 socket address must be allowed")

        var unsupportedAddress = sockaddr()
        unsupportedAddress.sa_family = sa_family_t(AF_UNIX)
        let allowedUnsupported = withUnsafePointer(to: &unsupportedAddress) { ptr -> String? in
            IPAddressValidator.validateSocketAddress(ptr)
        }
        expectTrue(allowedUnsupported == nil, "Unsupported family socket address must return nil")
    }

    static func testSecureHTTPClientFetchImage() async {
        print("  - Testing SecureHTTPClient fetchImage with MockURLProtocol...")

        // Setup custom configuration with MockURLProtocol
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        let client = NewsTests.mockHTTPClient(configuration: config)

        let targetURL = URL(string: "https://reader.invalid/test-image.jpg")!

        // Test 1: Successful image fetch
        let mockData = Data(repeating: 0xAA, count: 1024)
        let requestedAccept = NewsTests.SocketObservation()
        MockURLProtocol.requestHandler = { request in
            requestedAccept.recordText(request.value(forHTTPHeaderField: "Accept") ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, mockData)
        }

        do {
            let (data, response) = try await client.fetchImage(from: targetURL)
            expectEqual(data.count, 1024, "Should download exact mock bytes")
            expectEqual(response.statusCode, 200, "Should get 200 status code")
            // The request itself carries the image Accept header, not the document one (#1010).
            expectEqual(requestedAccept.hosts, [SecureHTTPClient.imageAccept], "Image requests send the image Accept")
        } catch {
            expectTrue(false, "Unexpected error in fetchImage success test: \(error)")
        }

        // #794: an http image address is requested over HTTPS instead of being refused.
        let requestedScheme = NewsTests.SocketObservation()
        MockURLProtocol.requestHandler = { request in
            requestedScheme.recordText(request.url?.scheme ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, mockData)
        }
        do {
            let (data, _) = try await client.fetchImage(from: URL(string: "http://reader.invalid/test-image.jpg")!)
            expectEqual(data.count, 1024, "An http image address still loads")
            expectEqual(requestedScheme.hosts, ["https"], "An http image address is requested over HTTPS")
        } catch {
            expectTrue(false, "An http image address is upgraded, not refused: \(error)")
        }
        expectEqual(
            SecureHTTPClient.upgradedToHTTPS(URL(string: "http://img.example:80/a.jpg?v=1")!).absoluteString,
            "https://img.example/a.jpg?v=1", "The upgrade drops the default http port and keeps the query")
        expectEqual(
            SecureHTTPClient.upgradedToHTTPS(URL(string: "https://img.example/a.jpg")!).absoluteString,
            "https://img.example/a.jpg", "An https image address is unchanged")

        // Test 2: Image too large
        let maxAllowed = Int(SecureHTTPClient.defaultImageLimit)
        let tooLargeDataSize = maxAllowed + 1024
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(tooLargeDataSize)"]
            )!
            let largeData = Data(repeating: 0xBB, count: tooLargeDataSize)
            return (response, largeData)
        }

        do {
            _ = try await client.fetchImage(from: targetURL)
            expectTrue(false, "Expected fetchImage to throw responseTooLarge error")
        } catch let error as FeedError {
            if case .responseTooLarge(let bytes, let maxAllowedLimit) = error {
                expectEqual(Int(bytes), tooLargeDataSize, "Expected byte size in error")
                expectEqual(Int(maxAllowedLimit), maxAllowed, "Expected max limit in error")
            } else {
                expectTrue(false, "Expected responseTooLarge error, got: \(error)")
            }
        } catch {
            expectTrue(false, "Unexpected error type: \(error)")
        }

        // Cleanup MockURLProtocol state
        MockURLProtocol.requestHandler = nil
    }

    static func testSecureHTTPClientPolicies() async {
        print("  - Testing SecureHTTPClient security policies...")

        // 1. Insecure scheme rejection (e.g. file://, javascript://)
        do {
            _ = try await SecureHTTPClient.shared.fetchData(from: URL(string: "file:///etc/passwd")!, maxBytes: 1024)
            expectTrue(false, "file:///etc/passwd should have thrown an insecureScheme error")
        } catch let err as FeedError {
            if case .insecureScheme = err {
                // expected
            } else {
                expectTrue(false, "Unexpected error for file scheme: \(err)")
            }
        } catch {
            expectTrue(false, "Unexpected error type: \(error)")
        }

        // 2. Blocked port rejection (e.g. port 22, port 6379)
        do {
            _ = try await SecureHTTPClient.shared.fetchData(
                from: URL(string: "https://example.com:22/feed")!, maxBytes: 1024)
            expectTrue(false, "Port 22 should have been blocked")
        } catch let err as FeedError {
            if case .blockedPort(let p) = err {
                expectEqual(p, 22, "Should block port 22")
            } else {
                expectTrue(false, "Unexpected error for blocked port: \(err)")
            }
        } catch {
            expectTrue(false, "Unexpected error: \(error)")
        }

        // 3. Blocked host rejection (e.g. localhost)
        do {
            _ = try await SecureHTTPClient.shared.fetchData(
                from: URL(string: "https://localhost/feed")!, maxBytes: 1024)
            expectTrue(false, "https://localhost should have been blocked")
        } catch let err as FeedError {
            if case .blockedHost = err {
                // expected
            } else {
                expectTrue(false, "Unexpected error for localhost: \(err)")
            }
        } catch {
            expectTrue(false, "Unexpected error: \(error)")
        }
    }

    static func testProxyWaitingClassification() async {
        print("  - Testing which waiting connect errors the proxy waits out and which it refuses at once (#769)...")
        for code in [POSIXErrorCode.ECONNREFUSED, .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN] {
            expectTrue(
                NetworkBoundaryProxy.waitingFailsAtOnce(.posix(code)), "\(code) is refused at once, fail-closed")
        }
        for code in [POSIXErrorCode.ETIMEDOUT, .ENOBUFS, .EADDRNOTAVAIL, .EMFILE] {
            expectFalse(
                NetworkBoundaryProxy.waitingFailsAtOnce(.posix(code)),
                "\(code) may clear under load, so the handshake timeout bounds the wait")
        }
        expectEqual(
            NetworkBoundaryProxy.logDescription(.posix(.ECONNREFUSED)), "posix 61", "The log names domain and code only"
        )
        expectFalse(
            NetworkBoundaryProxy.waitingFailsAtOnce(.dns(DNSServiceErrorType(kDNSServiceErr_Timeout))),
            "A non-POSIX waiting error is waited out")
    }

    static func testLookupFailsClosedAcrossFamilies() {
        print("  - Testing the lookup: a blocked address in the slower family still refuses the host (#945)...")
        let v4 = Int32(AF_INET)
        let v6 = Int32(AF_INET6)
        let noRecord = DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)
        // The first family ends with a public address; the host is not allowed until the other family has answered,
        // so a blocked address arriving later, after any grace a stagger would have given, still fails it closed.
        var late = DNSAnswer()
        expectEqual(
            late.received(family: v4, moreComing: false, error: 0, blocked: nil, address: "93.184.216.34"), nil,
            "One family's end does not answer while the other is still owed")
        expectEqual(
            late.received(family: v6, moreComing: false, error: 0, blocked: "Private address", address: nil),
            .blocked(reason: "Private address"), "A blocked address after the first family ended fails the host closed")
        // One batch carrying both families answers when its flag clears, in arrival order.
        var batch = DNSAnswer()
        expectEqual(
            batch.received(family: v6, moreComing: true, error: 0, blocked: nil, address: "2606:2800:21f:cb07::1"), nil,
            "More coming keeps the batch open")
        expectEqual(
            batch.received(family: v4, moreComing: false, error: 0, blocked: nil, address: "93.184.216.34"),
            .allowed(ips: ["2606:2800:21f:cb07::1", "93.184.216.34"]), "Both families in one batch answer at its end")
        // A family without records ends at once; the host answers when the other has ended too.
        var v4Only = DNSAnswer()
        expectEqual(
            v4Only.received(family: v6, moreComing: false, error: noRecord, blocked: nil, address: nil), nil,
            "No IPv6 record alone does not answer")
        expectEqual(
            v4Only.received(family: v4, moreComing: false, error: 0, blocked: nil, address: "93.184.216.34"),
            .allowed(ips: ["93.184.216.34"]), "The host answers once both families ended")
        var none = DNSAnswer()
        _ = none.received(family: v6, moreComing: true, error: noRecord, blocked: nil, address: nil)
        expectEqual(
            none.received(family: v4, moreComing: false, error: noRecord, blocked: nil, address: nil),
            .noSuchHost, "No record in either family says the host has no address")
        var failed = DNSAnswer()
        expectEqual(
            failed.received(
                family: v4, moreComing: false, error: Int32(kDNSServiceErr_ServiceNotRunning), blocked: nil,
                address: nil),
            .unresolvable(reason: "dns \(kDNSServiceErr_ServiceNotRunning)"),
            "A resolver error is no answer, not a missing host")
    }

    static func testResolverLifecycle() async {
        print("  - Testing the resolver: bounded lookups, prompt cancellation, no worker to exhaust (#945)...")
        let hang: ProxyResolver.Lookup = { _ in
            try? await Task.sleep(for: .seconds(600))
            return .unresolvable(reason: "Cancelled")
        }
        // A resolver that never answers ends inside the deadline.
        let started = ContinuousClock.now
        let timedOut = await ProxyResolver(lookup: hang, deadline: .milliseconds(200)).resolve("slow.invalid")
        expectEqual(timedOut, .unresolvable(reason: "Timed out"), "An unanswered lookup ends at the deadline")
        expectTrue(ContinuousClock.now - started < .seconds(5), "The deadline is the bound, not the system's")
        // Cancelling the caller resumes it at once and leaves no pending work behind. The lookup signals that it is
        // in flight, so the cancellation reaches a started lookup, not one still queued.
        let lookupStarted = NewsTests.SocketObservation()
        let resolver = ProxyResolver(
            lookup: { host in
                lookupStarted.recordText("started")
                return await hang(host)
            }, deadline: .seconds(600))
        let cancelled = Task { await resolver.resolve("slow.invalid") }
        await eventually("The lookup is in flight before it is cancelled") { lookupStarted.count == 1 }
        let cancelledAt = ContinuousClock.now
        cancelled.cancel()
        expectEqual(await cancelled.value, .unresolvable(reason: "Cancelled"), "A cancelled lookup says so")
        expectTrue(ContinuousClock.now - cancelledAt < .seconds(5), "Cancellation resumes the caller at once")
        // Hung lookups do not occupy anything other lookups wait for.
        let mixed = ProxyResolver(
            lookup: { host in
                if host.hasPrefix("hang") { return await hang(host) }
                return .allowed(ips: ["93.184.216.34"])
            }, deadline: .seconds(600))
        let hung = (0..<12).map { index in Task { await mixed.resolve("hang-\(index).invalid") } }
        let quick = await mixed.resolve("quick.invalid")
        expectEqual(quick, .allowed(ips: ["93.184.216.34"]), "A lookup behind twelve hung ones still resolves")
        for task in hung { task.cancel() }
        for task in hung { _ = await task.value }
        // The production path answers names and literals the hostname guard decides without any DNS.
        let production = ProxyResolver(deadline: .seconds(600))
        for host in ["localhost", "127.0.0.1", "printer.local", "intranet", "[::1]"] {
            if case .blocked = await production.resolve(host) { continue }
            expectTrue(false, "\(host) is refused by the hostname guard before DNS")
        }
        expectEqual(
            await production.resolve("93.184.216.34"), .allowed(ips: ["93.184.216.34"]),
            "A public literal is its own answer")
        if ProcessInfo.processInfo.environment["NEWS_LIVE_READER_CHECK"] == "1" {
            if case .allowed(let ips) = await production.resolve("example.com") {
                expectTrue(!ips.isEmpty, "The system lookup answers a public name with its addresses")
            } else {
                expectTrue(false, "The system lookup resolves a public name")
            }
            if case .blocked = await production.resolve("localtest.me") {
            } else {
                expectTrue(false, "A name answering with a private address is refused by the system lookup")
            }
        }
        expectEqual(
            NetworkBoundaryProxy.interleaved(["2606:4700::1111", "2606:4700::1001", "1.1.1.1", "1.0.0.1"]),
            ["2606:4700::1111", "1.1.1.1", "2606:4700::1001", "1.0.0.1"], "Address families take turns")
        expectEqual(
            NetworkBoundaryProxy.interleaved(["1.1.1.1", "2606:4700::1111"]), ["1.1.1.1", "2606:4700::1111"],
            "The first answer's family leads")
    }

    /// A redirect does no DNS on the session's serial delegate queue (#945): with a resolver that hangs, redirects
    /// for two tasks still complete at once, and the resolver is never consulted.
    static func testRedirectDelegateDoesNoDNS() async {
        print("  - Testing that redirects never wait on a slow resolver on the delegate queue (#945)...")
        let lookups = NewsTests.SocketObservation()
        let client = SecureHTTPClient(
            configuration: .ephemeral,
            resolver: { host in
                lookups.recordText(host)
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 600)
                return .unresolvable(reason: "Timed out")
            })
        let coordinator = client.delegateCoordinator
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let first = session.dataTask(with: URL(string: "https://example.com/first")!)
        let started = ContinuousClock.now
        let followed = await NewsTests.redirect(coordinator, session, first, to: "https://slow.invalid/next")
        expectEqual(followed?.url?.absoluteString, "https://slow.invalid/next", "The redirect is followed")
        expectTrue(ContinuousClock.now - started < .seconds(1), "The redirect completes without waiting on DNS")
        let tasks = ["a", "b"].map { session.dataTask(with: URL(string: "https://example.com/\($0)")!) }
        let concurrentStart = ContinuousClock.now
        let results = await withTaskGroup(of: String?.self) { group in
            for (index, task) in tasks.enumerated() {
                group.addTask {
                    await NewsTests.redirect(coordinator, session, task, to: "https://slow.invalid/\(index)")?.url?
                        .absoluteString
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        expectEqual(
            Set(results.compactMap { $0 }), ["https://slow.invalid/0", "https://slow.invalid/1"],
            "Both tasks' redirects are followed")
        expectTrue(
            ContinuousClock.now - concurrentStart < .seconds(1), "Neither task's callback waits behind the other's")
        expectEqual(lookups.count, 0, "The redirect path never reaches the resolver")
        for task in [first] + tasks { task.cancel() }
    }

    static func testCompletionOnce() async {
        print("  - Testing CompletionOnce atomicity...")
        let completion = CompletionOnce()
        let gate = OpenGate()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await gate.wait()
                    return completion.claim()
                }
            }
            await eventually("Every claim worker reaches the start gate") { await gate.arrivals == 100 }
            await gate.open()
            var claims = 0
            for await result in group {
                if result {
                    claims += 1
                }
            }
            expectEqual(claims, 1, "CompletionOnce must allow exactly one claim across concurrent tasks")
        }
        expectFalse(completion.claim(), "The completion stays claimed after all workers finish")
    }
}
