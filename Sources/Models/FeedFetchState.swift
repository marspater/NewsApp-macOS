import Foundation

/// HTTP validators a publisher returned with a feed body, replayed to ask whether the feed changed.
/// Response headers are untrusted: only short printable ASCII is kept, so a hostile value cannot
/// inject headers or grow the stored row.
struct FeedValidators: Equatable, Sendable {
    static let maximumLength = 512

    let etag: String?
    let lastModified: String?

    init(etag: String?, lastModified: String?) {
        self.etag = Self.sanitized(etag)
        self.lastModified = Self.sanitized(lastModified)
    }

    init(response: HTTPURLResponse) {
        self.init(etag: response.value(forHTTPHeaderField: "ETag"),
                  lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    var isEmpty: Bool { etag == nil && lastModified == nil }

    private static func sanitized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              value.utf8.count <= maximumLength,
              value.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return value
    }
}

/// Everything stored about a feed's last requests.
struct FeedFetchState: Equatable, Sendable {
    var validators: FeedValidators?
    var failures = 0
    /// No request is made before this time, whether the refresh is scheduled or manual.
    var retryAt: Date?
}

/// Retry scheduling for failing feeds. Pure, so the schedule is testable without a clock or a network.
enum FeedRetryPolicy {
    static let baseDelay: TimeInterval = 10 * 60
    static let maximumDelay: TimeInterval = 6 * 60 * 60
    /// One hostile or mistaken header must not silence a feed for good.
    static let maximumRetryAfter: TimeInterval = 24 * 60 * 60

    /// 10 minutes after the first failure, doubling to the 6 hour cap.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(maximumDelay, baseDelay * pow(2, Double(min(failures, 20) - 1)))
    }

    /// A server's `Retry-After` is a lower bound: the wait is never shorter than it, and never shorter than our own backoff.
    static func delay(afterFailures failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let requested = min(max(retryAfter ?? 0, 0), maximumRetryAfter)
        return max(requested, backoff(afterFailures: failures))
    }

    /// Parses delay-seconds or an HTTP date (RFC 9110 section 10.2.3). Obsolete RFC 850 and asctime dates are not recognized.
    static func retryAfter(header: String?, now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            guard let seconds = TimeInterval(value), seconds.isFinite else { return maximumRetryAfter }
            return seconds
        }
        return DateParser.parse(value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

extension FeedError {
    /// Rejected before any request was sent: retrying later cannot change the outcome and costs the server nothing.
    var isLocalRejection: Bool {
        switch self {
        case .malformedURL, .insecureScheme, .blockedPort, .blockedHost, .dnsRebindingDetected: return true
        default: return false
        }
    }

    /// The request may not have reached the publisher at all (offline, DNS, timeout).
    var isConnectivity: Bool {
        switch self {
        case .network, .timeout: return true
        default: return false
        }
    }

    /// A feed skipped without a request because its wait has not ended.
    var isScheduledPause: Bool {
        if case .retryScheduled = self { return true }
        return false
    }

    var retryAfter: TimeInterval? {
        if case .serverBusy(_, let retryAfter) = self { return retryAfter }
        return nil
    }
}
