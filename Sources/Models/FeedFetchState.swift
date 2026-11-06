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
        self.init(
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    var isEmpty: Bool { etag == nil && lastModified == nil }

    private static func sanitized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
            value.utf8.count <= maximumLength,
            value.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
        else { return nil }
        return value
    }
}

/// What a feed's failed request ran into, stored with its fetch state so a manual refresh can tell, even after a
/// relaunch, a feed that a network change backed off from one that a server or a certificate did (#927).
enum FeedFailureKind: String, CaseIterable, Sendable {
    case dns, noSuchHost, transport, timeout, tls, http, policy, parse, unknown
    /// A VPN's or resolver's filter answered a sinkhole address, or a fake-IP tunnel answered for the name (#929).
    case dnsFiltered, fakeIP

    /// The kinds that say something about the path to the publisher and nothing about the feed.
    static let connectivity: [FeedFailureKind] = [.dns, .transport, .timeout]
    /// What a manual refresh lifts: connectivity, and a filtered or substituted answer the reader may have fixed by
    /// changing the network. A whole batch of filtered answers is still recorded, so the kind reaches diagnostics.
    static let liftedByManualRefresh: [FeedFailureKind] = connectivity + [.dnsFiltered, .fakeIP]

    var isConnectivity: Bool { Self.connectivity.contains(self) }
}

/// Everything stored about a feed's last requests.
struct FeedFetchState: Equatable, Sendable {
    var validators: FeedValidators?
    var failures = 0
    /// No request is made before this time. A manual refresh first lifts it for a feed whose last failure was
    /// connectivity (#927); a server's wait and every other failure hold for every refresh.
    var retryAt: Date?
    /// What the last failure ran into; nil after a success, and for a failure recorded before schema 32.
    var lastFailureKind: FeedFailureKind?
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
    static let disclaimer =
        "Feed health shows whether a feed responds, how recent its items are and how much text it carries. It is not a rating of accuracy or trustworthiness."

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
            var text =
                failures == 1 ? "Not responding (1 failed attempt)" : "Not responding (\(failures) failed attempts)"
            if let retryAt, retryAt > now {
                text += ", retrying \(relative.localizedString(for: retryAt, relativeTo: now))"
            }
            parts.append(text)
        }
        if let latestItem {
            parts.append("Newest item \(relative.localizedString(for: min(latestItem, now), relativeTo: now))")
        }
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

    /// Exhaustive, so a new case has to choose a kind.
    var failureKind: FeedFailureKind {
        switch self {
        case .malformedURL, .insecureScheme, .blockedPort, .blockedHost, .redirectBlocked, .dnsRebindingDetected,
            .responseTooLarge:
            return .policy
        case .substitutedAnswer(_, .sinkhole): return .dnsFiltered
        case .substitutedAnswer(_, .fakeIP): return .fakeIP
        case .tooManyRedirects, .httpStatus, .serverBusy: return .http
        case .unsupportedFormat, .parseFailed: return .parse
        case .network: return .transport
        case .timeout: return .timeout
        case .dnsUnanswered: return .dns
        case .noSuchHost: return .noSuchHost
        case .tls: return .tls
        case .retryScheduled, .unclassified: return .unknown
        }
    }

    /// The request may not have reached the publisher at all (offline, no DNS answer, no route, timeout).
    var isConnectivity: Bool { failureKind.isConnectivity }

    /// The failure for an error `URLSession` or the task reported instead of a `FeedError`. Requests run through the
    /// loopback gateway, so a failure past it reaches `URLSession` as a SOCKS outcome (measured on macOS 27, #927):
    /// - `badURL` (-1000) is the gateway's rejection, the reply it sends when no upstream connection could be made.
    ///   The URL itself passed `validateDestination`, so it is not the cause. A destination the gateway refused
    ///   looks the same; the preflight catches nearly all of those first, and every retry validates again.
    /// - `notConnectedToInternet` (-1009) is a tunnel the gateway closed with no reply.
    /// - `cannotConnectToHost` (-1004) is the gateway itself not listening.
    init(transportFailure error: Error) {
        let message = error.localizedDescription
        guard let failure = error as? URLError else {
            // A cancelled batch records nothing, whatever it is called here.
            self = error is CancellationError ? .network(message) : .unclassified(message)
            return
        }
        switch failure.code {
        case .timedOut:
            self = .timeout
        case .cannotFindHost, .dnsLookupFailed:
            self = .dnsUnanswered(host: failure.failingURL?.host ?? "unknown", reason: message)
        case .badURL, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .internationalRoamingOff,
            .callIsActive, .dataNotAllowed, .cancelled:
            self = .network(message)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .tls(message)
        default:
            self = .unclassified(message)
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
