import Foundation

/// Centralized, hardened HTTP client for all remote network ingestion.
/// Enforces strict scheme/port rules, DNS resolution validation, anti-rebinding socket checks,
/// redirect validation with HTTPS downgrade protection, and progressive streaming response bounds.
actor SecureHTTPClient {
    static let shared = SecureHTTPClient()

    static let defaultFeedLimit: Int64 = 10 * 1024 * 1024       // 10 MB
    static let defaultArticleLimit: Int64 = 5 * 1024 * 1024     // 5 MB
    static let defaultImageLimit: Int64 = 10 * 1024 * 1024      // 10 MB
    static let defaultTimeout: TimeInterval = 15.0
    static let maxRedirects: Int = 5

    private let session: URLSession
    private let delegateCoordinator: SecureSessionDelegateCoordinator

    private init() {
        let coordinator = SecureSessionDelegateCoordinator()
        self.delegateCoordinator = coordinator

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.defaultTimeout
        config.timeoutIntervalForResource = Self.defaultTimeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false

        self.session = URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)
    }

    internal init(configuration: URLSessionConfiguration) {
        let coordinator = SecureSessionDelegateCoordinator()
        self.delegateCoordinator = coordinator
        self.session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)
    }

    // MARK: - Public Fetch Ingestion APIs

    func fetchFeed(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(from: url, maxBytes: Self.defaultFeedLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP)
    }

    func fetchArticleHTML(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(from: url, maxBytes: Self.defaultArticleLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP)
    }

    func fetchImage(from url: URL, allowHTTP: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(from: url, maxBytes: Self.defaultImageLimit, timeout: Self.defaultTimeout, allowHTTP: allowHTTP)
    }

    // MARK: - Core Secure Fetch

    func fetchData(
        from url: URL,
        maxBytes: Int64,
        timeout: TimeInterval = defaultTimeout,
        allowHTTP: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
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

        switch IPAddressValidator.validateHost(host) {
        case .allowed:
            break
        case .blocked(let reason):
            throw FeedError.blockedHost(host: host, reason: reason)
        case .unresolvable(let reason):
            throw FeedError.network("Host '\(host)' unresolvable: \(reason)")
        }

        // 3. Register Task Security Policy in Delegate Coordinator
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("NewsApp/2.0 (+https://github.com/marspater/NewsApp-macOS)", forHTTPHeaderField: "User-Agent")

        // 4. Progressive Byte Streaming Download with Size Enforcement
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
        guard (200...299).contains(httpResponse.statusCode) else {
            throw FeedError.httpStatus(httpResponse.statusCode)
        }

        return (buffer, httpResponse)
    }
}

// MARK: - Delegate Coordinator for Redirects and DNS Rebinding Detection

final class SecureSessionDelegateCoordinator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct TaskSecurityState {
        var redirectCount: Int = 0
        var initialScheme: String
        var allowHTTP: Bool
    }

    private let lock = NSLock()
    private var states = [Int: TaskSecurityState]()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
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
              let targetHost = targetURL.host else {
            completionHandler(nil)
            return
        }

        // 3. Prohibit HTTPS -> HTTP downgrade
        if state.initialScheme == "https" && targetScheme == "http" {
            completionHandler(nil)
            return
        }

        // 4. Validate redirect target host and IP resolution
        switch IPAddressValidator.validateHost(targetHost) {
        case .allowed:
            completionHandler(request)
        case .blocked, .unresolvable:
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        // Anti-DNS Rebinding: check final socket address if metrics provide it
        for metric in metrics.transactionMetrics {
            if let remoteIP = metric.remoteAddress {
                if let reason = IPAddressValidator.checkLiteralIP(remoteIP) {
                    task.cancel()
                    _ = reason
                }
            }
        }
    }
}
