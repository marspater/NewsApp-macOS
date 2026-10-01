import Foundation

/// Outcome of one feed request. `articles == nil && error == nil` means the server answered 304 Not Modified.
/// `validators` is set only for a fresh 200 (possibly empty, which clears stored ones) and must be persisted
/// together with the ingested articles so an interrupted ingest cannot hide them behind a later 304.
typealias FeedFetchResult = (urlString: String, articles: [FeedArticle]?, error: FeedError?, validators: FeedValidators?)

/// Fetches and parses RSS, Atom, and JSON feeds using SecureHTTPClient.
actor FeedFetcher {
    static let shared = FeedFetcher()

    private let client: SecureHTTPClient

    init(client: SecureHTTPClient = .shared) {
        self.client = client
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

    /// With `state`, feeds the server has described before are requested conditionally.
    func fetchAllFeeds(urls: [String], allowHTTP: Bool = false, state: DatabaseEngine? = nil) async -> [FeedFetchResult] {
        let known = (try? await state?.feedValidators()) ?? [:]
        return await withTaskGroup(of: FeedFetchResult.self) { group in
            var remaining = urls.makeIterator()
            for _ in 0..<min(6, urls.count) {
                guard let urlString = remaining.next() else { break }
                group.addTask {
                    await self.fetchSingleFeed(urlString: urlString, allowHTTP: allowHTTP, validators: known[urlString])
                }
            }
            var results = [FeedFetchResult]()
            for await result in group {
                results.append(result)
                if !Task.isCancelled, let next = remaining.next() {
                    group.addTask { await self.fetchSingleFeed(urlString: next, allowHTTP: allowHTTP, validators: known[next]) }
                }
            }
            return results
        }
    }
}
