import Foundation

/// Fetches and parses RSS, Atom, and JSON feeds using SecureHTTPClient.
actor FeedFetcher {
    static let shared = FeedFetcher()

    func fetchSingleFeed(urlString: String, allowHTTP: Bool = false) async -> (urlString: String, articles: [FeedArticle]?, error: FeedError?) {
        guard let url = URL(string: urlString) else {
            return (urlString, nil, .malformedURL(urlString))
        }

        do {
            let (data, _) = try await SecureHTTPClient.shared.fetchFeed(from: url, allowHTTP: allowHTTP)

            let sniffer = String(data: data.prefix(30), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if sniffer.hasPrefix("{") || sniffer.hasPrefix("[") {
                if let parsed = JSONFeedParser.parse(data: data, feedURL: urlString) {
                    return (urlString, parsed, nil)
                } else {
                    return (urlString, nil, .parseFailed("Malformed JSON Feed"))
                }
            } else {
                let xmlParser = FeedXMLParser(data: data, feedURL: urlString)
                let parsed = xmlParser.parse()
                return (urlString, parsed, nil)
            }
        } catch let error as FeedError {
            return (urlString, nil, error)
        } catch {
            return (urlString, nil, .network(error.localizedDescription))
        }
    }

    func fetchAllFeeds(urls: [String], allowHTTP: Bool = false) async -> [(urlString: String, articles: [FeedArticle]?, error: FeedError?)] {
        await withTaskGroup(of: (String, [FeedArticle]?, FeedError?).self) { group in
            for urlString in urls {
                group.addTask {
                    await self.fetchSingleFeed(urlString: urlString, allowHTTP: allowHTTP)
                }
            }
            var results = [(String, [FeedArticle]?, FeedError?)]()
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}
