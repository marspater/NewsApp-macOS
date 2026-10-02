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
    struct Event: Decodable { let id: String; let split: String; let group: String }
    struct Pair: Decodable { let id: String; let left: String; let right: String; let split: String }
    struct Corpus: Decodable { let documents: [Document]; let events: [Event]; let pairs: [Pair] }
    struct Text: Decodable { let title: String; let body: String; let publishedAt: String; let description: String? }

    static func run(evaluate: Bool) async throws {
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/story-corpus/corpus-v1.json")))
        let docs = Dictionary(uniqueKeysWithValues: corpus.documents.map { ($0.id, $0) })
        let events = Dictionary(uniqueKeysWithValues: corpus.events.map { ($0.id, $0) })
        var urls: [String: String] = [:]
        for doc in corpus.documents {
            guard let event = events[doc.event] else { throw Failure.invalid("Invalid corpus record") }
            let key = ArticleIdentity.canonicalizeURL(doc.url)
            if let split = urls[key], split != event.split { throw Failure.invalid("Canonical URL crosses splits: \(doc.id)") }
            urls[key] = event.split
        }
        try await checkReplay()
        guard evaluate else { return }
        var privateTexts: [String: Text] = [:]
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-texts") {
            guard CommandLine.arguments.indices.contains(index + 1) else { throw CocoaError(.fileReadInvalidFileName) }
            privateTexts = try JSONDecoder().decode([String: Text].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            guard privateTexts.keys.allSatisfy({ docs[$0] != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        let formatter = ISO8601DateFormatter()
        var fingerprints: [String: Set<String>] = [:]
        var articles: [String: FeedArticle] = [:]
        var textSplits: [String: String] = [:]
        for doc in corpus.documents {
            let local = privateTexts[doc.id]
            let body = local?.body ?? doc.body ?? ""
            let normalized = body.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !normalized.isEmpty {
                let key = ArticleIdentity.sha256Hex(normalized)
                let split = events[doc.event]!.split
                if let previous = textSplits[key], previous != split { throw Failure.invalid("Normalized body crosses splits: \(doc.id)") }
                textSplits[key] = split
            }
            let dateString = local?.publishedAt ?? doc.publishedAt
            let date = dateString.flatMap { formatter.date(from: $0) } ?? DateParser.unknownDate
            if dateString != nil && date == DateParser.unknownDate { throw CocoaError(.fileReadCorruptFile) }
            var article = FeedArticle(title: local?.title ?? doc.title ?? "", link: doc.url, guid: doc.id,
                                      description: local?.description ?? doc.description ?? "", pubDate: date, source: doc.source)
            article.fullContent = body
            articles[doc.id] = article
            fingerprints[doc.id] = Set(ArticleIdentity.publisherTextFingerprints(article))
        }
        let split = CommandLine.arguments.contains("--corpus-holdout") ? "holdout" : "tuning"
        let eventMode = CommandLine.arguments.contains("--corpus-events")
        let eligible = articles.filter { id, article in
            events[docs[id]!.event]!.split == split && !article.title.isEmpty && article.pubDate != DateParser.unknownDate
        }
        let memberships = eventMode ? try await eventMemberships(articles: Array(eligible.values)) : [:]
        var predictions: [String: Any] = [:]
        for pair in corpus.pairs where pair.split == split {
            guard let left = fingerprints[pair.left], let right = fingerprints[pair.right] else { throw CocoaError(.fileReadCorruptFile) }
            if eventMode {
                if let left = memberships[pair.left], let right = memberships[pair.right] {
                    predictions[pair.id] = left == right ? "same_event" : "different"
                } else {
                    predictions[pair.id] = NSNull()
                }
            } else {
                // Fingerprint is a binary document signal: same-event documents remain distinct.
                predictions[pair.id] = left.isEmpty || right.isEmpty ? NSNull() :
                    (left.isDisjoint(with: right) ? "different" : "same_document") as Any
            }
        }
        let output: [String: Any] = ["algorithm": eventMode ? "event-clusterer-v\(EventMatcher.version)" : "publisher-text-v1 (document signal only)",
                                   "task": eventMode ? "event_clustering" : "document_identity", "predictions": predictions]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print("CORPUS_PREDICTIONS " + String(decoding: data, as: UTF8.self))
    }

    /// Replays only the caller's selected split through real ingestion, candidate generation and clustering.
    /// Resolved single documents share a membership even when they have no multi-document event.
    static func eventMemberships(articles: [FeedArticle]) async throws -> [String: String] {
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
                    _ = try await EventClusterer.run(in: db, now: clock, limit: .max)
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
        let first = FeedArticle(title: "Local council approves library", link: "https://corpus.example/library", guid: "original",
                                description: "", pubDate: date, source: "Corpus")
        let copy = FeedArticle(title: first.title, link: first.link + "?utm_source=test", guid: "variant",
                               description: "", pubDate: date, source: first.source)
        let other = FeedArticle(title: "Unrelated astronomy report", link: "https://corpus.example/space", guid: "other",
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
            FeedArticle(title: title, link: canonical_url, guid: id, description: description ?? "",
                        pubDate: Date(timeIntervalSince1970: published_at), source: source, fullContent: content)
        }
    }

    /// Evidence inventory, not a labeled benchmark. Only equal canonical URLs independently
    /// confirm a fingerprint match; different URLs require review rather than being guessed negative.
    static func auditCache(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let records = try JSONDecoder().decode([CacheRecord].self, from: data)
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ $0.published_at.isFinite }) else { throw Failure.invalid("Invalid cache records") }
        let holdout = CommandLine.arguments.contains("--corpus-holdout")
        let split = holdout ? "holdout" : "tuning"
        let selected = records.filter {
            let key = ArticleIdentity.canonicalizeURL($0.canonical_url)
            let value = Int(ArticleIdentity.sha256Hex("news-cache-v1:" + key).prefix(8), radix: 16)!
            return (value % 10 >= 7) == holdout
        }
        let fingerprints = selected.map { Set(ArticleIdentity.publisherTextFingerprints($0.article)) }
        let languages = selected.map { EventMatchKey.language(of: $0.title + "\n" + ($0.description ?? "")) ?? "undetermined" }
        var confirmed = 0, unresolved = 0
        var byLanguage: [String: Int] = [:], bySource: [String: Int] = [:]
        for i in selected.indices where !fingerprints[i].isEmpty {
            byLanguage[languages[i], default: 0] += 1
            bySource[selected[i].source, default: 0] += 1
            for j in selected.indices where j > i && !fingerprints[i].isDisjoint(with: fingerprints[j]) {
                if ArticleIdentity.canonicalizeURL(selected[i].canonical_url) == ArticleIdentity.canonicalizeURL(selected[j].canonical_url) {
                    confirmed += 1
                } else {
                    unresolved += 1
                }
            }
        }
        let report: [String: Any] = ["split": split, "records": selected.count,
            "fingerprintEligibleRecords": fingerprints.filter { !$0.isEmpty }.count,
            "confirmedSameURLMatches": confirmed, "differentURLMatchesNeedingReview": unresolved,
            "eligibleRecordsByDetectedLanguage": byLanguage, "eligibleRecordsBySource": bySource,
            "releaseGatePassed": false, "limitation": "Unlabeled cache evidence; no event accuracy or holdout precision claim"]
        print("CACHE_CORPUS_AUDIT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

}
