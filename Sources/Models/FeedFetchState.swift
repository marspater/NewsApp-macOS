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
    /// Last successful response (200 or 304).
    var lastFetchedAt: Date?
    /// What the feed carried the last time its content changed.
    var latestItemAt: Date?
    var itemCount = 0
    var fullTextItems = 0
}

/// What one fresh response carried, for health reporting.
struct FeedContentStats: Equatable, Sendable {
    let itemCount: Int
    let fullTextItems: Int
    /// Newest publication date; undated items do not count.
    let latestItem: Date?

    init(articles: [FeedArticle]) {
        itemCount = articles.count
        fullTextItems = articles.filter { ($0.fullContent?.count ?? 0) >= FeedHealth.fullTextCharacters }.count
        latestItem = articles.map(\.pubDate).filter { $0 != DateParser.unknownDate }.max()
    }
}

/// Operational health of one subscription: whether it answers, how recent its items are and how much text it carries.
/// It describes the feed's plumbing only. It is never a rating of accuracy, reliability or trustworthiness.
struct FeedHealth: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case unknown, responding
        case failing(failures: Int, retryAt: Date?)
    }
    enum Freshness: Equatable, Sendable { case unknown, recent, quiet, stale }
    enum TextQuality: Equatable, Sendable { case unknown, full, partial, summaries }

    static let recentWindow: TimeInterval = 3 * 24 * 60 * 60
    static let quietWindow: TimeInterval = 30 * 24 * 60 * 60
    /// Characters of feed-provided text from which an item counts as full text.
    static let fullTextCharacters = 1200
    static let disclaimer = "Feed health shows whether a feed responds, how recent its items are and how much text it carries. It is not a rating of accuracy or trustworthiness."

    let availability: Availability
    let freshness: Freshness
    let textQuality: TextQuality
    let latestItem: Date?

    init(_ state: FeedFetchState?, now: Date) {
        guard let state else {
            (availability, freshness, textQuality, latestItem) = (.unknown, .unknown, .unknown, nil)
            return
        }
        if state.failures > 0 {
            availability = .failing(failures: state.failures, retryAt: state.retryAt)
        } else {
            availability = state.lastFetchedAt == nil ? .unknown : .responding
        }
        latestItem = state.latestItemAt
        if let latest = state.latestItemAt {
            let age = max(0, now.timeIntervalSince(latest))
            freshness = age <= Self.recentWindow ? .recent : age <= Self.quietWindow ? .quiet : .stale
        } else {
            freshness = .unknown
        }
        if state.itemCount == 0 {
            textQuality = .unknown
        } else {
            let ratio = Double(state.fullTextItems) / Double(state.itemCount)
            textQuality = ratio >= 0.8 ? .full : ratio >= 0.3 ? .partial : .summaries
        }
    }

    /// A failing or long-inactive feed deserves a second look; neither says anything about the reporting itself.
    var needsAttention: Bool {
        if case .failing = availability { return true }
        return freshness == .stale
    }

    func summary(now: Date) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        relative.dateTimeStyle = .named
        var parts: [String] = []
        switch availability {
        case .unknown:
            parts.append("Not checked yet")
        case .responding:
            parts.append("Responding")
        case .failing(let failures, let retryAt):
            var text = failures == 1 ? "Not responding (1 failed attempt)" : "Not responding (\(failures) failed attempts)"
            if let retryAt, retryAt > now { text += ", retrying \(relative.localizedString(for: retryAt, relativeTo: now))" }
            parts.append(text)
        }
        if let latestItem { parts.append("Newest item \(relative.localizedString(for: min(latestItem, now), relativeTo: now))") }
        switch textQuality {
        case .full: parts.append("Full text")
        case .partial: parts.append("Partial text")
        case .summaries: parts.append("Summaries")
        case .unknown: break
        }
        return parts.joined(separator: " · ")
    }
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
