import Foundation

/// How much a story matters to a general reader following the news, decided on device from its headline and summary.
enum StoryImportance: Int, Sendable, Comparable {
    case minor = 0
    case notable = 1
    case major = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Bounded publisher-image lookup. Nothing in the app rates importance; the opt-in live curation measurement in the
/// test build does (#549).
enum StoryCurator {
    struct Report: Equatable, Sendable {
        var expired = 0
        var imagesFound = 0
        var imagesChecked = 0
        var changed: Bool { expired > 0 || imagesChecked > 0 }
    }

    static func run(
        in database: DatabaseEngine,
        imageFinder: StoryImageFinder = .unavailable,
        imageBudget: Int = 30,
        muting: MuteRules = MuteRules(),
        keepingFeedURLs: [String] = [],
        activeLifetime: TimeInterval = EventCandidatePolicy.standard.activeEventLifetime,
        now: Date = Date()
    ) async throws -> Report {
        var report = Report()
        if imageFinder.isAvailable, imageBudget > 0 {
            // ponytail: rows read once per pass; one lookup per event, the rest of an event waits for the next pass.
            var lookedUp = Set<String>()
            for row in try await database.imagelessStoryRows(
                activeSince: now.addingTimeInterval(-activeLifetime), limit: imageBudget * 3, muting: muting)
            where lookedUp.count < imageBudget {
                try Task.checkCancellation()
                if let event = row.eventID, lookedUp.contains(event) { continue }
                // A link that can never be requested is recorded without spending the budget on it (#818).
                guard StoryImageFinder.pageURL(row.link) != nil else {
                    try await database.recordStoryImage(row.id, imageURL: nil, at: now, expectedLink: row.link)
                    continue
                }
                lookedUp.insert(row.eventID ?? row.id)
                switch await imageFinder.find(row.link) {
                case .found(let url):
                    try Task.checkCancellation()
                    if try await database.recordStoryImage(row.id, imageURL: url, at: now, expectedLink: row.link) {
                        report.imagesFound += 1
                    }
                    report.imagesChecked += 1
                case .none:
                    try Task.checkCancellation()
                    try await database.recordStoryImage(row.id, imageURL: nil, at: now, expectedLink: row.link)
                    report.imagesChecked += 1
                case .unreachable:
                    continue
                }
            }
        }
        return report
    }
}

/// Result of looking for a story's lead image on its publisher page.
enum StoryImageLookup: Equatable, Sendable {
    case found(String)
    /// The page was read and declares no usable image.
    case none
    /// The page could not be read (offline, rate-limited, server error); try again on a later pass.
    case unreachable
}

/// Finds the lead image a publisher declares for a story (`og:image`, `twitter:image`) when its feed carries none.
struct StoryImageFinder: Sendable {
    var isAvailable = true
    let find: @Sendable (_ link: String) async -> StoryImageLookup

    static let unavailable = StoryImageFinder(isAvailable: false) { _ in .unreachable }
    /// The article page through the protected client; http links are requested over https.
    static let publisherPages = publisherPages(using: .shared)

    /// The page address a lookup requests: an absolute http(s) link with a host, http upgraded to https.
    static func pageURL(_ link: String) -> URL? {
        guard var components = URLComponents(string: link),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""), !(components.host ?? "").isEmpty
        else { return nil }
        components.scheme = "https"
        return components.url
    }

    static func publisherPages(using client: SecureHTTPClient) -> StoryImageFinder {
        StoryImageFinder { link in
            guard let url = pageURL(link) else { return .none }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await client.fetchArticleHead(from: url)
            } catch FeedError.httpStatus(let status) where (400..<500).contains(status) && status != 429 {
                // A refusal (403, 404, 410) is an answer: recorded as no image so the page is not asked again each
                // pass, spending the lookup budget other imageless stories need (#818).
                return Task.isCancelled ? .unreachable : .none
            } catch {
                return .unreachable
            }
            guard !Task.isCancelled else { return .unreachable }
            return leadImage(
                in: ContentExtractionPipeline.shared.decodeHTML(data: data, response: response),
                pageURL: response.url?.absoluteString ?? url.absoluteString)
        }
    }

    /// The page's declared lead image, resolved against the page and filtered like any reader image.
    static func leadImage(in html: String, pageURL: String) -> StoryImageLookup {
        let pipeline = ContentExtractionPipeline.shared
        for declared in pipeline.extractLeadImages(from: html) {
            if let url = ContentExtractionPipeline.readerImageURL(
                pipeline.decodeHTMLEntities(declared), baseURL: pageURL),
                ReaderImageCandidate.usable(url: url)
            {
                return .found(url)
            }
        }
        // No declaration (#312): the first qualifying figure of the article body in the page prefix. Reader extraction
        // already drops logos, banners, hidden and tiny images; recordStoryImage clears figures another story shares.
        if case .success(_, _, let document?) = pipeline.extractFromHTML(html, baseUrl: pageURL),
            let figure = document.images?.first(where: {
                $0.origin == .body && $0.aspectRatio.map { (0.25...4).contains($0) } ?? true
            })
        {
            return .found(figure.url)
        }
        return .none
    }
}
