import CryptoKit
import Foundation

/// Evaluation-only adapter. Calls the production fingerprint function; never opens a user database.
enum StoryCorpus {
    enum Failure: Error { case invalid(String) }

    struct Document: Decodable {
        let id: String
        let event: String
        let url: String
        let source: String
        let title: String?
        let body: String?
        let description: String?
        let publishedAt: String?
    }
    struct Event: Decodable {
        let id: String
        let split: String
        let group: String
    }
    struct Pair: Decodable {
        let id: String
        let left: String
        let right: String
        let split: String
    }
    struct Corpus: Decodable {
        let documents: [Document]
        let events: [Event]
        let pairs: [Pair]
    }
    struct Text: Decodable {
        let title: String
        let body: String
        let publishedAt: String
        let description: String?
    }

    static func run(evaluate: Bool) async throws {
        let corpus = try JSONDecoder().decode(
            Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/corpus-v1.json")))
        let docs = Dictionary(uniqueKeysWithValues: corpus.documents.map { ($0.id, $0) })
        let events = Dictionary(uniqueKeysWithValues: corpus.events.map { ($0.id, $0) })
        var urls: [String: String] = [:]
        for doc in corpus.documents {
            guard let event = events[doc.event] else { throw Failure.invalid("Invalid corpus record") }
            let key = ArticleIdentity.canonicalizeURL(doc.url)
            if let split = urls[key], split != event.split {
                throw Failure.invalid("Canonical URL crosses splits: \(doc.id)")
            }
            urls[key] = event.split
        }
        try await checkReplay()
        guard evaluate else { return }
        var privateTexts: [String: Text] = [:]
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-texts") {
            guard CommandLine.arguments.indices.contains(index + 1) else { throw CocoaError(.fileReadInvalidFileName) }
            privateTexts = try JSONDecoder().decode(
                [String: Text].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            guard privateTexts.keys.allSatisfy({ docs[$0] != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        let formatter = ISO8601DateFormatter()
        var fingerprints: [String: Set<String>] = [:]
        var articles: [String: FeedArticle] = [:]
        var textSplits: [String: String] = [:]
        for doc in corpus.documents {
            let local = privateTexts[doc.id]
            let body = local?.body ?? doc.body ?? ""
            let normalized = body.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !normalized.isEmpty {
                let key = ArticleIdentity.sha256Hex(normalized)
                let split = events[doc.event]!.split
                if let previous = textSplits[key], previous != split {
                    throw Failure.invalid("Normalized body crosses splits: \(doc.id)")
                }
                textSplits[key] = split
            }
            let dateString = local?.publishedAt ?? doc.publishedAt
            let date = dateString.flatMap { formatter.date(from: $0) } ?? DateParser.unknownDate
            if dateString != nil && date == DateParser.unknownDate { throw CocoaError(.fileReadCorruptFile) }
            var article = FeedArticle(
                title: local?.title ?? doc.title ?? "", link: doc.url, guid: doc.id,
                description: local?.description ?? doc.description ?? "", pubDate: date, source: doc.source)
            article.fullContent = body
            articles[doc.id] = article
            fingerprints[doc.id] = Set(ArticleIdentity.publisherTextFingerprints(article))
        }
        let split = CommandLine.arguments.contains("--corpus-holdout") ? "holdout" : "tuning"
        let eventMode = CommandLine.arguments.contains("--corpus-events")
        let eligible = articles.filter { id, article in
            events[docs[id]!.event]!.split == split && !article.title.isEmpty
                && article.pubDate != DateParser.unknownDate
        }
        let memberships = eventMode ? try await eventMemberships(articles: Array(eligible.values)) : [:]
        var predictions: [String: Any] = [:]
        for pair in corpus.pairs where pair.split == split {
            guard let left = fingerprints[pair.left], let right = fingerprints[pair.right] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if eventMode {
                if let left = memberships[pair.left], let right = memberships[pair.right] {
                    predictions[pair.id] = left == right ? "same_event" : "different"
                } else {
                    predictions[pair.id] = NSNull()
                }
            } else {
                // Fingerprint is a binary document signal: same-event documents remain distinct.
                predictions[pair.id] =
                    left.isEmpty || right.isEmpty
                    ? NSNull() : (left.isDisjoint(with: right) ? "different" : "same_document") as Any
            }
        }
        let output: [String: Any] = [
            "algorithm": eventMode
                ? "event-clusterer-v\(EventMatcher.version)" : "publisher-text-v1 (document signal only)",
            "task": eventMode ? "event_clustering" : "document_identity", "predictions": predictions,
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print("CORPUS_PREDICTIONS " + String(decoding: data, as: UTF8.self))
    }

    /// Replays only the caller's selected split through real ingestion, candidate generation and clustering.
    /// Resolved single documents share a membership even when they have no multi-document event.
    static func eventMemberships(articles: [FeedArticle], onPass: ((EventClusteringReport) -> Void)? = nil) async throws
        -> [String: String]
    {
        let items = articles.sorted { ($0.pubDate, $0.id) < ($1.pubDate, $1.id) }
        guard var clock = items.first?.pubDate else { return [:] }
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        do {
            var index = 0
            while index < items.count {
                try Task.checkCancellation()
                var batch: [FeedArticle] = []
                while index < items.count, items[index].pubDate <= clock {
                    batch.append(items[index])
                    index += 1
                }
                if !batch.isEmpty {
                    try await db.upsertArticles(batch)
                    // Keep production's per-pass article and judge limits in evaluation too.
                    let judged = ProcessInfo.processInfo.environment["NEWS_EVENT_JUDGE"] == "1"
                    let report = try await EventClusterer.run(
                        in: db, judge: judged ? .onDevice : .unavailable, now: clock)
                    onPass?(report)
                }
                clock = clock.addingTimeInterval(6 * 3600)
                if index < items.count, items[index].pubDate > clock { clock = items[index].pubDate }
            }
            var result: [String: String] = [:]
            for item in items {
                let resolved = try await db.resolvedArticleID(for: item)
                let event = try await db.eventID(forArticle: resolved)
                result[item.id] = event.map { "event:" + $0 } ?? "document:" + resolved
            }
            await db.close()
            return result
        } catch {
            await db.close()
            throw error
        }
    }

    static func checkReplay() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = FeedArticle(
            title: "Local council approves library", link: "https://corpus.example/library", guid: "original",
            description: "", pubDate: date, source: "Corpus")
        let copy = FeedArticle(
            title: first.title, link: first.link + "?utm_source=test", guid: "variant",
            description: "", pubDate: date, source: first.source)
        let other = FeedArticle(
            title: "Unrelated astronomy report", link: "https://corpus.example/space", guid: "other",
            description: "", pubDate: date.addingTimeInterval(100_000), source: "Corpus")
        let result = try await eventMemberships(articles: [other, copy, first])
        guard result.count == 3, result[first.id] == result[copy.id], result[first.id] != result[other.id] else {
            throw Failure.invalid("Replay lost aliases or merged unrelated singleton documents")
        }
    }

    struct CacheRecord: Decodable {
        let id: String
        let canonical_url: String
        let title: String
        let description: String?
        let content: String?
        let published_at: Double
        let source: String

        var article: FeedArticle {
            FeedArticle(
                title: title, link: canonical_url, guid: id, description: description ?? "",
                pubDate: Date(timeIntervalSince1970: published_at), source: source, fullContent: content)
        }
    }

    /// Evidence inventory, not a labeled benchmark. Only equal canonical URLs independently
    /// confirm a fingerprint match; different URLs require review rather than being guessed negative.
    static func auditCache(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let records = try JSONDecoder().decode([CacheRecord].self, from: data)
        guard Set(records.map(\.id)).count == records.count,
            records.allSatisfy({ $0.published_at.isFinite })
        else { throw Failure.invalid("Invalid cache records") }
        let holdout = CommandLine.arguments.contains("--corpus-holdout")
        let split = holdout ? "holdout" : "tuning"
        let selected = records.filter {
            let key = ArticleIdentity.canonicalizeURL($0.canonical_url)
            let value = Int(ArticleIdentity.sha256Hex("news-cache-v1:" + key).prefix(8), radix: 16)!
            return (value % 10 >= 7) == holdout
        }
        let fingerprints = selected.map { Set(ArticleIdentity.publisherTextFingerprints($0.article)) }
        let languages = selected.map {
            EventMatchKey.language(of: $0.title + "\n" + ($0.description ?? "")) ?? "undetermined"
        }
        var confirmed = 0
        var unresolved = 0
        var byLanguage: [String: Int] = [:]
        var bySource: [String: Int] = [:]
        for i in selected.indices where !fingerprints[i].isEmpty {
            byLanguage[languages[i], default: 0] += 1
            bySource[selected[i].source, default: 0] += 1
            for j in selected.indices where j > i && !fingerprints[i].isDisjoint(with: fingerprints[j]) {
                if ArticleIdentity.canonicalizeURL(selected[i].canonical_url)
                    == ArticleIdentity.canonicalizeURL(selected[j].canonical_url)
                {
                    confirmed += 1
                } else {
                    unresolved += 1
                }
            }
        }
        let report: [String: Any] = [
            "split": split, "records": selected.count,
            "fingerprintEligibleRecords": fingerprints.filter { !$0.isEmpty }.count,
            "confirmedSameURLMatches": confirmed, "differentURLMatchesNeedingReview": unresolved,
            "eligibleRecordsByDetectedLanguage": byLanguage, "eligibleRecordsBySource": bySource,
            "releaseGatePassed": false,
            "limitation": "Unlabeled cache evidence; no event accuracy or holdout precision claim",
        ]
        print(
            "CACHE_CORPUS_AUDIT "
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        )
    }

    // MARK: - Private real-publisher capture (#102)

    /// One parsed feed item before identity resolution. A library export cannot replace this:
    /// merged variants are collapsed into one stored row and their own text is gone.
    struct CapturedItem: Codable, Hashable {
        let feed: String
        /// Curated feed language (BCP 47), never guessed from the domain.
        let language: String
        let source: String
        let link: String
        let guid: String?
        let title: String
        let description: String
        let content: String?
        let published: Double?

        var article: FeedArticle {
            FeedArticle(
                title: title, link: link, guid: guid, description: description,
                pubDate: published.map { Date(timeIntervalSince1970: $0) } ?? DateParser.unknownDate,
                source: source, fullContent: content)
        }
    }
    struct Capture: Codable {
        let version: Int
        let capturedAt: Double
        let items: [CapturedItem]
    }
    struct CaptureFeed: Decodable {
        let url: String
        let language: String
    }

    /// Different-URL fingerprint matches. Same-URL pairs are excluded: the URL already decides them.
    struct CaptureMetrics {
        var candidates = 0, sameDocument = 0, different = 0
        var unlabeled: Int { candidates - sameDocument - different }
        var precision: Double? {
            sameDocument + different == 0 ? nil : Double(sameDocument) / Double(sameDocument + different)
        }
        var precisionLowerBound: Double? { StoryCorpus.wilson(sameDocument, of: sameDocument + different)?.lowerBound }
        mutating func add(_ label: String?) {
            candidates += 1
            if label == "same_document" { sameDocument += 1 } else if label == "different" { different += 1 }
        }
        var json: [String: Any] {
            [
                "candidates": candidates, "sameDocument": sameDocument, "different": different, "unlabeled": unlabeled,
                "precision": precision.map { $0 as Any } ?? NSNull(),
                "precisionLowerBound95": precisionLowerBound.map { $0 as Any } ?? NSNull(),
            ]
        }
    }

    struct CaptureReview {
        var split = "tuning", captureFiles = 0, observations = 0, eligible = 0, sameURLShared = 0, sameURLDisjoint = 0
        var eligibleByLanguage: [String: Int] = [:]
        /// Distinct canonical URLs among eligible observations; candidates are counted per canonical pair too.
        var eligibleDocuments = 0
        var total = CaptureMetrics()
        var byLanguage: [String: CaptureMetrics] = [:], bySource: [String: CaptureMetrics] = [:]
        var gatePassed = false
        var readinessOnly = false

        var report: [String: Any] {
            if readinessOnly {
                return [
                    "split": split, "supportedLanguages": FeedCatalog.supportedLanguages.sorted(),
                    "captureFiles": captureFiles, "observations": observations,
                    "fingerprintEligibleObservations": eligible, "eligibleObservationsByLanguage": eligibleByLanguage,
                    "fingerprintEligibleDocuments": eligibleDocuments, "scoringPerformed": false,
                    "supportSufficientIfZeroFalseMerges": StoryCorpus.captureGatePassed(
                        split: "holdout", metrics: CaptureMetrics(), eligibleDocuments: eligibleDocuments),
                    "releaseGatePassed": false,
                ]
            }
            return [
                "split": split, "supportedLanguages": FeedCatalog.supportedLanguages.sorted(),
                "captureFiles": captureFiles, "observations": observations,
                "fingerprintEligibleObservations": eligible, "eligibleObservationsByLanguage": eligibleByLanguage,
                "fingerprintEligibleDocuments": eligibleDocuments,
                "sameURLPairsSharingFingerprint": sameURLShared,
                "sameURLPairsWithoutSharedFingerprint": sameURLDisjoint,
                "differentURLCandidates": total.json, "byLanguage": byLanguage.mapValues(\.json),
                "bySource": bySource.mapValues(\.json),
                "falseMergeUpperBound95": StoryCorpus.wilson(total.different, of: eligibleDocuments).map {
                    $0.upperBound as Any
                } ?? NSNull(),
                "releaseGatePassed": gatePassed,
                "gate":
                    "holdout split, every candidate adjudicated, false merges at most 1% of eligible documents (Wilson 95% upper bound), "
                    + "and precision >= 0.99 once there are at least \(StoryCorpus.captureGateMinimumCandidates) candidates",
                "limitation":
                    "False merges and precision of different-URL fingerprint matches in captured feeds only; recall and event accuracy are not measured",
            ]
        }
    }

    /// Below 100 adjudicated candidates a single error cannot be resolved against the 1% budget.
    static let captureGateMinimumCandidates = 100

    /// Different-URL matches are too rare in captured feeds to estimate precision, so the gate bounds what readers
    /// can lose instead: falsely merged documents among all eligible documents (distinct canonical URLs, so repeated
    /// observations of one document count once). Each adjudicated different pair counts as one false merge, which
    /// can only overstate. Precision still applies once it is measurable. Without a false merge, the bound needs at
    /// least 381 eligible holdout documents.
    static func captureGatePassed(split: String, metrics: CaptureMetrics, eligibleDocuments: Int) -> Bool {
        guard split == "holdout", metrics.unlabeled == 0,
            let bound = wilson(metrics.different, of: eligibleDocuments)?.upperBound, bound <= 0.01
        else { return false }
        return metrics.candidates < captureGateMinimumCandidates
            || metrics.sameDocument * 100 >= 99 * (metrics.sameDocument + metrics.different)
    }

    /// Wilson 95% interval, so small samples show their uncertainty.
    static func wilson(_ successes: Int, of trials: Int) -> ClosedRange<Double>? {
        guard trials > 0, (0...trials).contains(successes) else { return nil }
        let n = Double(trials)
        let p = Double(successes) / n
        let z = 1.959964
        let center = p + z * z / (2 * n)
        let margin = z * ((p * (1 - p) + z * z / (4 * n)) / n).squareRoot()
        return (center - margin) / (1 + z * z / n)...(center + margin) / (1 + z * z / n)
    }

    /// Fingerprints include the host and canonical URLs never span hosts, so a host-level split keeps every
    /// candidate family on one side and measures publishers that were not looked at during tuning.
    static func captureSplit(host: String) -> String {
        Int(ArticleIdentity.sha256Hex("news-capture-v1:" + host).prefix(8), radix: 16)! % 10 >= 7 ? "holdout" : "tuning"
    }

    /// Stable across runs and argument order; derived from canonical URLs only.
    static func capturePairKey(_ first: String, _ second: String) -> String {
        let (left, right) = first < second ? (first, second) : (second, first)
        return String(ArticleIdentity.sha256Hex("news-capture-pair-v1:" + left + "\n" + right).prefix(16))
    }

    /// Publisher text stays in an existing directory that belongs to the user, is closed to everyone else
    /// and lies outside the checkout.
    static func privateDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw Failure.invalid("Private corpus directory must be an absolute path") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        guard url.path != checkout.path, !url.path.hasPrefix(checkout.path + "/") else {
            throw Failure.invalid("Keep publisher text outside the checkout")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.invalid("Private corpus directory does not exist")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o077 == 0
        else {
            throw Failure.invalid(
                "Private corpus directory must belong to you and be closed to other users (chmod 700)")
        }
        return url
    }

    static func writePrivate(_ data: Data, to file: URL, replacing: Bool) throws {
        try data.write(to: file, options: replacing ? [.atomic] : [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    @discardableResult
    static func writeCapture(_ capture: Capture, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("capture-\(Int64(capture.capturedAt * 1000)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(try encoder.encode(capture), to: file, replacing: false)
        return file
    }

    /// Opt-in live capture of the catalog (plus an optional private feed list) through the app's own
    /// networking and parsers. Opens no user database or settings; prints counts only.
    static func capture(directory path: String) async throws {
        let directory = try privateDirectory(path)
        var feeds = FeedCatalog.feeds.map { CaptureFeed(url: $0.url, language: $0.language) }
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-feeds") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                throw Failure.invalid("Missing feed list path")
            }
            feeds += try JSONDecoder().decode(
                [CaptureFeed].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        var languages: [String: String] = [:]
        for feed in feeds where FeedCatalog.supportedLanguages.contains(feed.language) && languages[feed.url] == nil {
            languages[feed.url] = feed.language
        }
        let results = await FeedFetcher().fetchAllFeeds(urls: languages.keys.sorted())
        var items: [CapturedItem] = []
        var failed = 0
        for result in results {
            guard let articles = result.articles else {
                failed += 1
                continue
            }
            items += articles.map {
                CapturedItem(
                    feed: result.urlString, language: languages[result.urlString] ?? "undetermined", article: $0)
            }
        }
        let file = try writeCapture(
            Capture(version: 1, capturedAt: Date().timeIntervalSince1970, items: items), in: directory)
        let summary: [String: Any] = [
            "file": file.lastPathComponent, "feeds": languages.count, "failedFeeds": failed, "items": items.count,
        ]
        print(
            "CORPUS_CAPTURE "
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self
                ))
    }

    struct PageRequest: Codable, Sendable {
        let id: String
        let url: String
    }
    struct PageEvidence: Codable, Sendable {
        let id: String
        let url: String
        let fetchedAt: Double
        var finalURL: String?
        var file: String?
        var sha256: String?
        var error: String?
    }

    static func validPageRequests(_ requests: [PageRequest]) -> Bool {
        !requests.isEmpty && requests.count <= 500 && Set(requests.map(\.id)).count == requests.count
            && requests.allSatisfy {
                !$0.id.isEmpty && $0.id.utf8.count <= 80
                    && $0.id.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                    }
            }
    }

    struct PageText: Codable {
        let id: String
        let url: String
        let canonicalURL: String
        let title: String
        let content: String?
        let contentSHA256: String?
    }

    /// Offline readability evidence for human URL review; never computes fingerprints or event predictions.
    static func pageTexts(directory path: String) throws {
        let directory = try privateDirectory(path)
        let records = try JSONDecoder().decode(
            [PageEvidence].self, from: Data(contentsOf: directory.appendingPathComponent("pages.json")))
        var texts: [PageText] = []
        for record in records {
            guard let file = record.file, let finalURL = record.finalURL else { continue }
            guard URL(fileURLWithPath: file).lastPathComponent == file else {
                throw Failure.invalid("Invalid page evidence path")
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            guard data.count <= SecureHTTPClient.defaultArticleLimit,
                SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.sha256
            else { throw Failure.invalid("Publisher page checksum mismatch") }
            let pipeline = ContentExtractionPipeline.shared
            let html = pipeline.decodeHTML(data: data)
            let title = HTMLDOMBuilder.parse(html: html).findNodes(tag: "title").map { $0.combinedText() }.joined()
            let content = pipeline.extractFromHTML(html, baseUrl: finalURL).content
            let normalized = content?.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            texts.append(
                PageText(
                    id: record.id, url: record.url, canonicalURL: ArticleIdentity.canonicalizeURL(record.url),
                    title: title,
                    content: content, contentSHA256: normalized.map(ArticleIdentity.sha256Hex)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(
            try encoder.encode(texts), to: directory.appendingPathComponent("page-texts.json"), replacing: false)
        print(
            "PUBLISHER_TEXTS pages=\(texts.count) extracted=\(texts.filter { $0.content != nil }.count); no predictions"
        )
    }

    /// Private publisher-page evidence through the same bounded, pinned client as the reader.
    /// One request per host at a time, at most six hosts; no database, scoring or page scripts.
    static func capturePages(directory path: String, requestsPath: String) async throws {
        let directory = try privateDirectory(path)
        let requests = try JSONDecoder().decode(
            [PageRequest].self, from: Data(contentsOf: URL(fileURLWithPath: requestsPath)))
        guard validPageRequests(requests) else {
            throw Failure.invalid(
                "Use at most 500 uniquely identified pages; IDs must be ASCII letters, numbers or hyphens")
        }
        let groups = Dictionary(grouping: requests) { URL(string: $0.url)?.host?.lowercased() ?? "" }.sorted {
            $0.key < $1.key
        }.map(\.value)
        var evidence: [PageEvidence] = []
        for start in stride(from: 0, to: groups.count, by: 6) {
            try Task.checkCancellation()
            let batch = try await withThrowingTaskGroup(of: [PageEvidence].self) { group in
                for requests in groups[start..<min(start + 6, groups.count)] {
                    group.addTask {
                        var records: [PageEvidence] = []
                        for request in requests {
                            try Task.checkCancellation()
                            var record = PageEvidence(
                                id: request.id, url: request.url, fetchedAt: Date().timeIntervalSince1970)
                            do {
                                guard let url = URL(string: request.url) else {
                                    throw Failure.invalid("Invalid page URL")
                                }
                                let (data, response) = try await SecureHTTPClient.shared.fetchArticleHTML(from: url)
                                try Task.checkCancellation()
                                let file = request.id + ".html"
                                try writePrivate(data, to: directory.appendingPathComponent(file), replacing: false)
                                record.finalURL = response.url?.absoluteString
                                record.file = file
                                record.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                            } catch {
                                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                                if error is CocoaError { throw error }  // Never overwrite or silently lose local evidence.
                                record.error = String(describing: error)
                            }
                            records.append(record)
                        }
                        return records
                    }
                }
                var records: [PageEvidence] = []
                for try await result in group { records += result }
                return records
            }
            evidence += batch
            print("PUBLISHER_PAGES completed=\(evidence.count) succeeded=\(evidence.filter { $0.file != nil }.count)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writePrivate(
            try encoder.encode(evidence.sorted { $0.id < $1.id }), to: directory.appendingPathComponent("pages.json"),
            replacing: false)
    }

    /// Lists different-URL fingerprint matches of one split for review and scores them against `labels.json`
    /// (`{"<pair>": "same_document" | "different"}`). The review sheet carries URLs and titles, never body text.
    static func reviewCaptures(directory path: String, holdout: Bool, readinessOnly: Bool = false) throws
        -> CaptureReview
    {
        let directory = try privateDirectory(path)
        var review = CaptureReview()
        review.split = holdout ? "holdout" : "tuning"
        review.readinessOnly = readinessOnly
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        review.captureFiles = files.count
        var unique = Set<CapturedItem>()
        for file in files {
            let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: file))
            guard capture.version == 1 else { throw Failure.invalid("Unsupported capture version") }
            unique.formUnion(capture.items)
        }
        func host(_ item: CapturedItem) -> String {
            URLComponents(string: item.article.normalizedLink)?.host?.lowercased() ?? ""
        }
        func order(_ item: CapturedItem) -> (String, String, String, String, Double, String) {
            (item.link, item.feed, item.guid ?? "", item.title, item.published ?? -1, item.description)
        }
        let split = review.split
        let items = unique.filter {
            FeedCatalog.supportedLanguages.contains($0.language) && captureSplit(host: host($0)) == split
        }.sorted { order($0) < order($1) }
        review.observations = items.count
        let canonical = items.map(\.article.normalizedLink)
        let fingerprints = items.map { Set(ArticleIdentity.publisherTextFingerprints($0.article)) }

        var byURL: [String: [Int]] = [:]
        var byFingerprint: [String: [Int]] = [:]
        for index in items.indices where !fingerprints[index].isEmpty {
            review.eligible += 1
            review.eligibleByLanguage[items[index].language, default: 0] += 1
            byURL[canonical[index], default: []].append(index)
            for fingerprint in fingerprints[index] { byFingerprint[fingerprint, default: []].append(index) }
        }
        review.eligibleDocuments = byURL.count
        // Count support before comparing pairs, reading labels or writing a review sheet.
        if readinessOnly { return review }
        for members in byURL.values {
            for (offset, i) in members.enumerated() {
                for j in members[(offset + 1)...] {
                    if fingerprints[i].isDisjoint(with: fingerprints[j]) {
                        review.sameURLDisjoint += 1
                    } else {
                        review.sameURLShared += 1
                    }
                }
            }
        }
        var candidates: [String: (Int, Int)] = [:]
        for members in byFingerprint.values {
            for (offset, i) in members.enumerated() {
                for j in members[(offset + 1)...] where canonical[i] != canonical[j] {
                    let pair = canonical[i] < canonical[j] ? (i, j) : (j, i)
                    let key = capturePairKey(canonical[i], canonical[j])
                    if let existing = candidates[key], existing <= pair { continue }
                    candidates[key] = pair
                }
            }
        }

        var labels: [String: String] = [:]
        let labelsFile = directory.appendingPathComponent("labels.json")
        if FileManager.default.fileExists(atPath: labelsFile.path) {
            labels = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: labelsFile))
            guard labels.values.allSatisfy({ $0 == "same_document" || $0 == "different" }) else {
                throw Failure.invalid("Labels must be same_document or different")
            }
        }
        let formatter = ISO8601DateFormatter()
        func side(_ index: Int) -> [String: Any] {
            [
                "url": items[index].link, "canonicalURL": canonical[index], "title": items[index].title,
                "source": items[index].source,
                "language": items[index].language, "feed": items[index].feed,
                "published": items[index].published.map {
                    formatter.string(from: Date(timeIntervalSince1970: $0)) as Any
                } ?? NSNull(),
            ]
        }
        var sheet: [[String: Any]] = []
        for key in candidates.keys.sorted() {
            let (i, j) = candidates[key]!
            let label = labels[key]
            let language = items[i].language == items[j].language ? items[i].language : "mixed"
            review.total.add(label)
            review.byLanguage[language, default: CaptureMetrics()].add(label)
            for source in Set([items[i].source, items[j].source]) {
                review.bySource[source, default: CaptureMetrics()].add(label)
            }
            sheet.append(["pair": key, "label": label.map { $0 as Any } ?? NSNull(), "left": side(i), "right": side(j)])
        }
        review.gatePassed = captureGatePassed(
            split: review.split, metrics: review.total, eligibleDocuments: review.eligibleDocuments)
        let data = try JSONSerialization.data(withJSONObject: sheet, options: [.prettyPrinted, .sortedKeys])
        try writePrivate(data, to: directory.appendingPathComponent("review-\(review.split).json"), replacing: true)
        return review
    }

}

extension StoryCorpus.CapturedItem {
    init(feed: String, language: String, article: FeedArticle) {
        self.init(
            feed: feed, language: language, source: article.source, link: article.link, guid: article.guid,
            title: article.title, description: article.description, content: article.fullContent,
            published: article.pubDate == DateParser.unknownDate ? nil : article.pubDate.timeIntervalSince1970)
    }
}
