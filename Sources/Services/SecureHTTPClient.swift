import Foundation
import ImageIO
import Network

/// Centralized, hardened HTTP client for all remote network ingestion.
/// Enforces strict scheme/port rules, DNS resolution validation, socket-level public-address enforcement,
/// redirect validation with HTTPS downgrade protection, and progressive streaming response bounds.
actor SecureHTTPClient {
    static let shared = SecureHTTPClient()

    static let defaultFeedLimit: Int64 = 10 * 1024 * 1024       // 10 MB
    static let defaultArticleLimit: Int64 = 5 * 1024 * 1024     // 5 MB
    static let defaultImageLimit: Int64 = 10 * 1024 * 1024      // 10 MB
    static let defaultTimeout: TimeInterval = 15.0
    static let maxRedirects: Int = 5

    private var session: URLSession?
    private let delegateCoordinator: SecureSessionDelegateCoordinator
    private let resolver: NetworkBoundaryProxy.Resolver

    private init() {
        let coordinator = SecureSessionDelegateCoordinator()
        self.delegateCoordinator = coordinator
        self.resolver = { IPAddressValidator.validateHost($0) }
    }

    internal init(configuration: URLSessionConfiguration,
                  resolver: @escaping NetworkBoundaryProxy.Resolver = { IPAddressValidator.validateHost($0) }) {
        let coordinator = SecureSessionDelegateCoordinator(resolver: resolver)
        self.delegateCoordinator = coordinator
        self.resolver = resolver
        self.session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)
    }

    private func protectedSession() async throws -> URLSession {
        if let session { return session }
        let proxy = try await NetworkBoundaryProxy.shared.configuration()
        // Another caller may have configured the session while listener readiness was awaited.
        if let session { return session }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.defaultTimeout
        configuration.timeoutIntervalForResource = Self.defaultTimeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.proxyConfigurations = [proxy]
        let session = URLSession(configuration: configuration, delegate: delegateCoordinator, delegateQueue: nil)
        self.session = session
        return session
    }

    // MARK: - Public Fetch Ingestion APIs

    /// With validators the request is conditional and a 304 returns an empty body instead of throwing.
    func fetchFeed(from url: URL, allowHTTP: Bool = false, validators: FeedValidators? = nil) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(from: url, maxBytes: Self.defaultFeedLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP, validators: validators, reportsBackpressure: true)
    }

    func fetchArticleHTML(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(from: url, maxBytes: Self.defaultArticleLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP)
    }

    func fetchImage(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(from: url, maxBytes: Self.defaultImageLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP, cachePolicy: .useProtocolCachePolicy)
    }

    /// Decode bounded thumbnails on the networking actor, away from SwiftUI's main actor.
    func fetchReaderImage(from url: URL) async throws -> CGImage {
        let (data, _) = try await fetchImage(from: url)
        try Task.checkCancellation()
        return try Self.decodeReaderImage(data)
    }

    nonisolated static func decodeReaderImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    /// Shared navigation/ingestion preflight. DNS work stays on this actor, off the UI actor.
    func validateDestination(_ url: URL, allowHTTP: Bool = false) throws {
        // 1. Scheme & Port Validation
        guard let scheme = url.scheme?.lowercased() else {
            throw FeedError.malformedURL(url.absoluteString)
        }
        guard scheme == "https" || (scheme == "http" && allowHTTP) else {
            throw FeedError.insecureScheme(scheme)
        }

        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let allowedPorts: Set<Int> = [80, 443, 8080, 8443]
        guard allowedPorts.contains(port) else {
            throw FeedError.blockedPort(port)
        }

        // 2. Pre-flight Host and DNS Validation
        guard let host = url.host, !host.isEmpty else {
            throw FeedError.malformedURL(url.absoluteString)
        }

        switch resolver(host) {
        case .allowed:
            break
        case .blocked(let reason):
            throw FeedError.blockedHost(host: host, reason: reason)
        case .unresolvable(let reason):
            throw FeedError.network("Host '\(host)' unresolvable: \(reason)")
        }

    }

    // MARK: - Core Secure Fetch

    func fetchData(
        from url: URL,
        maxBytes: Int64,
        timeout: TimeInterval = defaultTimeout,
        allowHTTP: Bool = false,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData,
        validators: FeedValidators? = nil,
        reportsBackpressure: Bool = false,
        customHeaders: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try validateDestination(url, allowHTTP: allowHTTP)

        // 3. Register Task Security Policy in Delegate Coordinator
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
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
        if let modified = validators?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let isConditional = !(validators?.isEmpty ?? true)

        // 4. Progressive Byte Streaming Download with Size Enforcement
        let session = try await protectedSession()
        let (asyncBytes, rawResponse) = try await session.bytes(for: request)

        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw FeedError.network("Invalid non-HTTP response received")
        }

        // 5. Pre-check Content-Length header if available
        let expectedLength = httpResponse.expectedContentLength
        if expectedLength > 0 && expectedLength > maxBytes {
            throw FeedError.responseTooLarge(bytes: expectedLength, maxAllowed: maxBytes)
        }

        // 6. Progressive byte accumulation
        var buffer = Data()
        buffer.reserveCapacity(min(Int(maxBytes), expectedLength > 0 ? Int(expectedLength) : 65536))

        for try await byte in asyncBytes {
            buffer.append(byte)
            if Int64(buffer.count) > maxBytes {
                throw FeedError.responseTooLarge(bytes: Int64(buffer.count), maxAllowed: maxBytes)
            }
        }

        // 7. Verify HTTP Status Code
        if reportsBackpressure, httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            throw FeedError.serverBusy(status: httpResponse.statusCode,
                                       retryAfter: FeedRetryPolicy.retryAfter(header: httpResponse.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        guard (200...299).contains(httpResponse.statusCode) || (isConditional && httpResponse.statusCode == 304) else {
            throw FeedError.httpStatus(httpResponse.statusCode)
        }

        return (buffer, httpResponse)
    }
}

// MARK: - Delegate Coordinator for Redirects and DNS Rebinding Detection

final class SecureSessionDelegateCoordinator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resolver: NetworkBoundaryProxy.Resolver

    init(resolver: @escaping NetworkBoundaryProxy.Resolver = { IPAddressValidator.validateHost($0) }) {
        self.resolver = resolver
        super.init()
    }
    private struct TaskSecurityState {
        var redirectCount: Int = 0
        var initialScheme: String
        var allowHTTP: Bool
    }

    private let lock = NSLock()
    private var states = [Int: TaskSecurityState]()

    func urlSession(
        _ _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        var state = states[task.taskIdentifier] ?? TaskSecurityState(
            redirectCount: 0,
            initialScheme: task.originalRequest?.url?.scheme?.lowercased() ?? "https",
            allowHTTP: false
        )
        state.redirectCount += 1
        states[task.taskIdentifier] = state
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
              [80, 443, 8080, 8443].contains(targetURL.port ?? (targetScheme == "https" ? 443 : 80)) else {
            completionHandler(nil)
            return
        }

        // 3. Prohibit HTTPS -> HTTP downgrade
        if state.initialScheme == "https" && targetScheme == "http" {
            completionHandler(nil)
            return
        }

        // 4. Validate redirect target host and IP resolution
        switch resolver(targetHost) {
        case .allowed:
            completionHandler(request)
        case .blocked, .unresolvable:
            completionHandler(nil)
        }
    }

    func urlSession(_ _: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        // Diagnostic only: metrics arrive after the request; this cannot prevent rebinding.
        for metric in metrics.transactionMetrics {
            if let remoteIP = metric.remoteAddress, IPAddressValidator.checkLiteralIP(remoteIP) != nil {
                task.cancel()
            }
        }
    }
}
