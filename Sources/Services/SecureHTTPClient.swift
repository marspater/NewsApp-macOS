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
import ImageIO
import Network

/// An image that did not load, named by the stage that refused it and what the host sent, so `log show` can tell a
/// response that is not the image from bytes ImageIO or the PNG encoder rejects (#1010). It never carries the URL.
struct ImageLoadFailure: Error, CustomStringConvertible {
    /// Where the image failed: the request, ImageIO decoding, cropping, PNG encoding, the attachment size limit or
    /// creating the notification attachment.
    enum Stage: String, Sendable { case fetch, decode, crop, encode, size, attach }
    let stage: Stage
    /// The response's MIME type, when known.
    var contentType: String?
    /// The size of the data that failed, when known.
    var bytes: Int?
    /// The error behind the failure; only its domain and code are logged.
    var underlying: NSError?

    /// A log line of the stage, content type, byte count and the underlying error's domain and code; never the URL.
    var description: String {
        let count = bytes.map(String.init) ?? "unknown"
        var text = "stage=\(stage.rawValue) type=\(contentType ?? "unknown") bytes=\(count)"
        if let underlying { text += " domain=\(underlying.domain) code=\(underlying.code)" }
        return text
    }

    /// The failure as a log line: anything that is not an `ImageLoadFailure` came from the request itself, whose
    /// own -1016 (an undecodable content encoding) would otherwise read like a decode failure.
    static func describe(_ error: Error) -> String {
        (error as? ImageLoadFailure ?? ImageLoadFailure(stage: .fetch, underlying: error as NSError)).description
    }

    /// The task's own cancellation or URLSession's (a cache clear, a dismissed banner): not a failure to log.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// Centralized, hardened HTTP client for all remote network ingestion.
/// Enforces strict scheme/port rules, DNS resolution validation, socket-level public-address enforcement,
/// redirect validation with HTTPS downgrade protection, and progressive streaming response bounds.
actor SecureHTTPClient {
    /// The client every feed, page and image request uses, routed through `NetworkBoundaryProxy.shared`.
    static let shared = SecureHTTPClient()

    /// The largest feed response accepted, in bytes.
    static let defaultFeedLimit: Int64 = 10 * 1024 * 1024  // 10 MB
    /// The largest article page accepted, in bytes.
    static let defaultArticleLimit: Int64 = 5 * 1024 * 1024  // 5 MB
    /// The largest image accepted, in bytes.
    static let defaultImageLimit: Int64 = 10 * 1024 * 1024  // 10 MB
    /// The per-request timeout in seconds; a whole resource gets twice as long.
    static let defaultTimeout: TimeInterval = 15.0
    /// Redirects a request may follow before it is refused.
    static let maxRedirects: Int = 5

    private var session: URLSession?
    private var sessionPort: UInt16?
    /// Internal so a test can drive the redirect callback directly (#945).
    let delegateCoordinator: SecureSessionDelegateCoordinator
    private let resolver: ProxyResolver
    /// Nil when a test supplies a fixed session configuration.
    private let gateway: NetworkBoundaryProxy?

    private init() {
        let coordinator = SecureSessionDelegateCoordinator()
        self.delegateCoordinator = coordinator
        self.resolver = ProxyResolver()
        self.gateway = .shared
    }

    /// `resolver` keeps a test's synchronous DNS answers; nil resolves through the system.
    internal init(configuration: URLSessionConfiguration, resolver: NetworkBoundaryProxy.Resolver? = nil) {
        let coordinator = SecureSessionDelegateCoordinator()
        self.delegateCoordinator = coordinator
        self.resolver = ProxyResolver(body: resolver)
        self.gateway = nil
        self.session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)
    }

    /// Creates a client over a test's gateway; `resolver` keeps the test's synchronous DNS answers for the preflight.
    internal init(gateway: NetworkBoundaryProxy, resolver: NetworkBoundaryProxy.Resolver? = nil) {
        self.delegateCoordinator = SecureSessionDelegateCoordinator()
        self.resolver = ProxyResolver(body: resolver)
        self.gateway = gateway
    }

    private func protectedSession() async throws -> URLSession {
        guard let gateway else { return session! }
        // A restarted gateway listens on a new port; a session built for the old one would fail every request.
        let port = try await gateway.port()
        if let session, sessionPort == port { return session }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.defaultTimeout
        configuration.timeoutIntervalForResource = Self.defaultTimeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.proxyConfigurations = [NetworkBoundaryProxy.configuration(port: port)]
        session?.finishTasksAndInvalidate()
        let session = URLSession(configuration: configuration, delegate: delegateCoordinator, delegateQueue: nil)
        self.session = session
        sessionPort = port
        return session
    }

    // MARK: - Public Fetch Ingestion APIs

    /// With validators the request is conditional and a 304 returns an empty body instead of throwing.
    func fetchFeed(from url: URL, allowHTTP: Bool = false, validators: FeedValidators? = nil) async throws -> (
        Data, HTTPURLResponse
    ) {
        try await fetchData(
            from: url, maxBytes: Self.defaultFeedLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP,
            options: FetchOptions(validators: validators, reportsBackpressure: true))
    }

    /// Fetches an article page, at most `defaultArticleLimit` bytes, after the destination checks.
    ///
    /// - Throws: A `FeedError` for a refused destination, an HTTP error status or an oversized body, or the session's
    ///   error.
    func fetchArticleHTML(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(
            from: url, maxBytes: Self.defaultArticleLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP)
    }

    /// Metadata lookup reads only the start of a page, then cancels the remaining download.
    func fetchArticleHead(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(
            from: url, maxBytes: 256 * 1024, timeout: Self.defaultTimeout, options: FetchOptions(prefixOnly: true))
    }

    /// Image requests ask for the baseline formats: a document `Accept` that lists WebP and AVIF makes a CDN serve a
    /// `Vary: Accept` variant instead of the PNG or JPEG the feed named, which the notification attachment cannot use and
    /// which was larger than the PNG for the palette image of #1010.
    static let imageAccept = "image/png,image/jpeg,image/gif,image/svg+xml,image/*;q=0.8,*/*;q=0.5"

    /// Fetches an image, at most `defaultImageLimit` bytes, asking for baseline formats and allowing the HTTP cache.
    /// Unless `allowHTTP` is set, an `http` address is upgraded to HTTPS first.
    ///
    /// - Throws: As `fetchArticleHTML(from:allowHTTP:)`.
    func fetchImage(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(
            from: allowHTTP ? url : Self.upgradedToHTTPS(url), maxBytes: Self.defaultImageLimit,
            timeout: Self.defaultTimeout, allowHTTP: allowHTTP,
            options: FetchOptions(cachePolicy: .useProtocolCachePolicy, customHeaders: ["Accept": Self.imageAccept]))
    }

    /// Feeds still publish `http://` image addresses that their hosts also serve over HTTPS (#794). Card, reader and
    /// notification images ask for HTTPS instead of being refused; a host without HTTPS fails as it did before.
    static func upgradedToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url ?? url
    }

    /// Decodes bounded thumbnails concurrently, away from SwiftUI's main actor and from this actor, so one large image
    /// never holds up other cards or feed requests. `maxPixelSize` bounds the longer side: the reader's 1600 by default,
    /// less for cards (#591).
    @concurrent nonisolated func fetchReaderImage(from url: URL, maxPixelSize: Int = 1600) async throws -> CGImage {
        let (data, response) = try await fetchImage(from: url)
        try Task.checkCancellation()
        do { return try Self.decodeReaderImage(data, maxPixelSize: maxPixelSize) } catch {
            throw ImageLoadFailure(
                stage: .decode, contentType: response.mimeType, bytes: data.count, underlying: error as NSError)
        }
    }

    /// Decodes image data into an oriented thumbnail whose longer side is at most `maxPixelSize`. Images over 16384
    /// pixels on a side or 64 megapixels are refused before decoding.
    ///
    /// - Throws: `URLError(.cannotDecodeContentData)` when the data is not a decodable image within those bounds.
    nonisolated static func decodeReaderImage(_ data: Data, maxPixelSize: Int = 1600) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    /// The only ports a request or redirect may use.
    static let allowedPorts: Set<Int> = [80, 443, 8080, 8443]

    /// Shared navigation/ingestion preflight. The DNS lookup is asynchronous, cancellable and bounded (#945).
    func validateDestination(_ url: URL, allowHTTP: Bool = false) async throws(FeedError) {
        // 1. Scheme & Port Validation
        guard let scheme = url.scheme?.lowercased() else {
            throw FeedError.malformedURL(url.absoluteString)
        }
        guard scheme == "https" || (scheme == "http" && allowHTTP) else {
            throw FeedError.insecureScheme(scheme)
        }

        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard Self.allowedPorts.contains(port) else {
            throw FeedError.blockedPort(port)
        }

        // 2. Pre-flight Host and DNS Validation
        guard let host = url.host, !host.isEmpty else {
            throw FeedError.malformedURL(url.absoluteString)
        }

        switch await resolver.resolve(host) {
        case .allowed:
            break
        case .blocked(let reason):
            // A literal address was never answered by DNS, so no filter or tunnel substituted it.
            if IPAddressValidator.checkLiteralIP(IPAddressValidator.hostnameGuard(host).host) == nil,
                let kind = IPAddressValidator.substitution(in: reason)
            {
                throw FeedError.substitutedAnswer(host: host, kind: kind)
            }
            throw FeedError.blockedHost(host: host, reason: reason)
        case .unresolvable(let reason):
            throw FeedError.dnsUnanswered(host: host, reason: reason)
        case .noSuchHost:
            throw FeedError.noSuchHost(host)
        }

    }

    // MARK: - Core Secure Fetch

    /// Per-request tweaks on top of the secure defaults.
    struct FetchOptions {
        var cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
        var validators: FeedValidators?
        var reportsBackpressure = false
        var customHeaders: [String: String]?
        var prefixOnly = false
    }

    /// Fetches a URL through the gateway after `validateDestination(_:allowHTTP:)`, streaming the body and refusing it
    /// once it passes `maxBytes` (with `options.prefixOnly`, reading stops there instead of failing). The status is
    /// checked before the body is read. `allowHTTP` permits an `http` address at all; `options` carries the cache
    /// policy, conditional validators, extra headers and whether 429 and 503 report backpressure.
    ///
    /// - Returns: The body and response; a conditional request answered 304 returns an empty body.
    /// - Throws: A `FeedError` for a refused destination, `serverBusy` (when reporting backpressure), another error
    ///   status or an oversized body; the session's error otherwise.
    func fetchData(
        from url: URL,
        maxBytes: Int64,
        timeout: TimeInterval = defaultTimeout,
        allowHTTP: Bool = false,
        options: FetchOptions = FetchOptions()
    ) async throws -> (Data, HTTPURLResponse) {
        let cachePolicy = options.cachePolicy
        let validators = options.validators
        let reportsBackpressure = options.reportsBackpressure
        let customHeaders = options.customHeaders
        let prefixOnly = options.prefixOnly
        try await validateDestination(url, allowHTTP: allowHTTP)

        // 3. Register Task Security Policy in Delegate Coordinator
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")

        if let customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        // Explicit validators with a reload policy: URLSession passes the 304 to us instead of replaying its cache.
        if let etag = validators?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = validators?.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        let isConditional = !(validators?.isEmpty ?? true)

        // 4. Progressive Byte Streaming Download with Size Enforcement
        let session = try await protectedSession()
        let (asyncBytes, rawResponse) = try await session.bytes(for: request)
        defer { asyncBytes.task.cancel() }

        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw FeedError.unclassified("Invalid non-HTTP response received")
        }

        // 5. Verify HTTP status before reading the body, so a large error page reports its status, not its size
        if reportsBackpressure, httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            throw FeedError.serverBusy(
                status: httpResponse.statusCode,
                retryAfter: FeedRetryPolicy.retryAfter(
                    header: httpResponse.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        guard (200...299).contains(httpResponse.statusCode) || (isConditional && httpResponse.statusCode == 304) else {
            throw FeedError.httpStatus(httpResponse.statusCode)
        }

        // 6. Pre-check Content-Length header if available
        let expectedLength = httpResponse.expectedContentLength
        if !prefixOnly && expectedLength > 0 && expectedLength > maxBytes {
            throw FeedError.responseTooLarge(bytes: expectedLength, maxAllowed: maxBytes)
        }

        // 7. Progressive byte accumulation
        var buffer = Data()
        buffer.reserveCapacity(min(Int(maxBytes), expectedLength > 0 ? Int(expectedLength) : 65536))

        for try await byte in asyncBytes {
            buffer.append(byte)
            if prefixOnly && Int64(buffer.count) == maxBytes { break }
            if Int64(buffer.count) > maxBytes {
                throw FeedError.responseTooLarge(bytes: Int64(buffer.count), maxAllowed: maxBytes)
            }
        }

        return (buffer, httpResponse)
    }
}

// MARK: - Delegate Coordinator for Redirects and DNS Rebinding Detection

/// Bounds redirects and refuses downgrades and non-web targets on the session's one serial delegate queue. It never
/// resolves a name there (#945): the gateway resolves, validates and pins every connection, so a redirect to a
/// private host still fails closed, and a slow lookup cannot stall every other request's callbacks.
final class SecureSessionDelegateCoordinator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct TaskSecurityState {
        var redirectCount: Int = 0
        var initialScheme: String
        var allowHTTP: Bool
    }

    private let lock = NSLock()
    private var states = [ObjectIdentifier: TaskSecurityState]()

    func urlSession(
        _ _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let taskKey = ObjectIdentifier(task)
        lock.lock()
        var state =
            states[taskKey]
            ?? TaskSecurityState(
                redirectCount: 0,
                initialScheme: task.originalRequest?.url?.scheme?.lowercased() ?? "https",
                allowHTTP: false
            )
        state.redirectCount += 1
        states[taskKey] = state
        lock.unlock()

        // 1. Bound redirect depth
        guard state.redirectCount <= SecureHTTPClient.maxRedirects else {
            completionHandler(nil)
            return
        }

        // 2. Validate redirect destination
        guard let targetURL = request.url,
            let targetScheme = targetURL.scheme?.lowercased(),
            let targetHost = targetURL.host,
            targetScheme == "https" || targetScheme == "http",
            [80, 443, 8080, 8443].contains(targetURL.port ?? (targetScheme == "https" ? 443 : 80))
        else {
            completionHandler(nil)
            return
        }

        // 3. Prohibit HTTPS -> HTTP downgrade
        if state.initialScheme == "https" && targetScheme == "http" {
            completionHandler(nil)
            return
        }

        // 4. Refuse names and literals the hostname guard refuses without DNS; the gateway validates the addresses.
        if case .blocked = IPAddressValidator.hostnameGuard(targetHost).result {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError _: Error?) {
        lock.lock()
        states.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    func urlSession(_ _: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        states.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()

        // Diagnostic only: metrics arrive after the request; this cannot prevent rebinding.
        for metric in metrics.transactionMetrics {
            if let remoteIP = metric.remoteAddress, IPAddressValidator.checkLiteralIP(remoteIP) != nil {
                task.cancel()
            }
        }
    }
}
