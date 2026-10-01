import Foundation
import os

/// Outcome of one feed request. `articles == nil && error == nil` means the server answered 304 Not Modified.
/// `validators` is set only for a fresh 200 (possibly empty, which clears stored ones) and must be persisted
/// together with the ingested articles so an interrupted ingest cannot hide them behind a later 304.
typealias FeedFetchResult = (urlString: String, articles: [FeedArticle]?, error: FeedError?, validators: FeedValidators?)

/// Fetches and parses RSS, Atom, and JSON feeds using SecureHTTPClient.
actor FeedFetcher {
    static let shared = FeedFetcher()

    static let maximumConcurrentFeeds = 6
    static let maximumConcurrentFeedsPerHost = 2

    private let client: SecureHTTPClient
    private let now: @Sendable () -> Date
    private var hostCooldowns: [String: Date] = [:]
    private let logger = Logger(subsystem: "com.marspater.news", category: "FeedFetcher")

    init(client: SecureHTTPClient = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    func fetchSingleFeed(urlString: String, allowHTTP: Bool = false, validators: FeedValidators? = nil) async -> FeedFetchResult {
        guard let url = URL(string: urlString) else {
            return (urlString, nil, .malformedURL(urlString), nil)
        }

        do {
            let (data, response) = try await client.fetchFeed(from: url, allowHTTP: allowHTTP, validators: validators)
            if response.statusCode == 304 { return (urlString, nil, nil, nil) }
            let fresh = FeedValidators(response: response)

            let sniffer = String(data: data.prefix(30), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if sniffer.hasPrefix("{") || sniffer.hasPrefix("[") {
                if let parsed = JSONFeedParser.parse(data: data, feedURL: urlString) {
                    return (urlString, parsed, nil, fresh)
                } else {
                    return (urlString, nil, .parseFailed("Malformed JSON Feed"), nil)
                }
            } else {
                let xmlParser = FeedXMLParser(data: data, feedURL: urlString)
                let parsed = xmlParser.parse()
                if let error = xmlParser.parseError {
                    return (urlString, nil, .parseFailed(error), nil)
                }
                return (urlString, parsed, nil, fresh)
            }
        } catch let error as FeedError {
            return (urlString, nil, error, nil)
        } catch {
            return (urlString, nil, .network(error.localizedDescription), nil)
        }
    }

    /// With `state`, known feeds are requested conditionally and paused ones are skipped; outcomes are recorded for the next run.
    /// Scheduled and manual refreshes take this same path, so neither can bypass a server's wait.
    func fetchAllFeeds(urls: [String], allowHTTP: Bool = false, state: DatabaseEngine? = nil) async -> [FeedFetchResult] {
        let stored = (try? await state?.feedFetchStates()) ?? [:]
        let started = now()
        var results = [FeedFetchResult]()
        var due = [String]()
        for url in urls {
            if let until = pausedUntil(url, retryAt: stored[url]?.retryAt, now: started) {
                results.append((url, nil, .retryScheduled(until: until), nil))
            } else {
                due.append(url)
            }
        }
        let attempted = await fetchWindowed(due, allowHTTP: allowHTTP, validators: stored.compactMapValues(\.validators))
        if let state, !Task.isCancelled { await recordOutcomes(attempted.filter { $0.error.map(\.isScheduledPause) != true }, in: state) }
        return results + attempted
    }

    /// At most `maximumConcurrentFeeds` requests overall and `maximumConcurrentFeedsPerHost` per host. A host that
    /// answered 429/503 is left alone until its wait ends, including feeds queued behind the one that was refused.
    private func fetchWindowed(_ urls: [String], allowHTTP: Bool, validators: [String: FeedValidators]) async -> [FeedFetchResult] {
        await withTaskGroup(of: FeedFetchResult.self) { group in
            var queue = urls
            var results = [FeedFetchResult]()
            var active = [String: Int]()
            var running = 0

            func launchEligible(_ group: inout TaskGroup<FeedFetchResult>) {
                while running < Self.maximumConcurrentFeeds, !Task.isCancelled,
                      let index = queue.firstIndex(where: { active[Self.host($0), default: 0] < Self.maximumConcurrentFeedsPerHost }) {
                    let url = queue.remove(at: index)
                    let host = Self.host(url)
                    if let until = hostCooldowns[host], until > now() {
                        results.append((url, nil, .retryScheduled(until: until), nil))
                        continue
                    }
                    active[host, default: 0] += 1
                    running += 1
                    let known = validators[url]
                    group.addTask { await self.fetchSingleFeed(urlString: url, allowHTTP: allowHTTP, validators: known) }
                }
            }

            launchEligible(&group)
            for await result in group {
                let host = Self.host(result.urlString)
                active[host, default: 1] -= 1
                running -= 1
                if case .serverBusy(_, let retryAfter)? = result.error {
                    let until = now().addingTimeInterval(FeedRetryPolicy.delay(afterFailures: 1, retryAfter: retryAfter))
                    hostCooldowns[host] = max(until, hostCooldowns[host] ?? .distantPast) // a later, shorter ask never shortens the wait
                }
                results.append(result)
                launchEligible(&group)
            }
            return results
        }
    }

    /// When a host that pushed back may be contacted again, while it is still cooling.
    func cooldown(forHost host: String) -> Date? {
        hostCooldowns[host].flatMap { $0 > now() ? $0 : nil }
    }

    private func pausedUntil(_ url: String, retryAt: Date?, now: Date) -> Date? {
        [retryAt, hostCooldowns[Self.host(url)]].compactMap { $0 }.max().flatMap { $0 > now ? $0 : nil }
    }

    private func recordOutcomes(_ attempted: [FeedFetchResult], in state: DatabaseEngine) async {
        // Every request failing to connect means this device is probably offline; that says nothing about the feeds.
        let offline = !attempted.isEmpty && attempted.allSatisfy { $0.error?.isConnectivity == true }
        let at = now()
        for result in attempted {
            do {
                if let error = result.error {
                    guard !offline, !error.isLocalRejection else { continue }
                    try await state.recordFeedFailure(result.urlString, retryAfter: error.retryAfter, at: at)
                } else {
                    try await state.recordFeedSuccess(result.urlString, at: at)
                }
            } catch {
                logger.error("Could not record feed fetch outcome: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func host(_ urlString: String) -> String {
        URL(string: urlString)?.host?.lowercased() ?? urlString
    }
}
