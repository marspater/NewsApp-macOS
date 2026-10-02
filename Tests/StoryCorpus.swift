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
        let publishedAt: String?
    }
    struct Event: Decodable { let id: String; let split: String; let group: String }
    struct Pair: Decodable { let id: String; let left: String; let right: String; let split: String }
    struct Corpus: Decodable { let documents: [Document]; let events: [Event]; let pairs: [Pair] }
    struct Text: Decodable { let title: String; let body: String; let publishedAt: String }

    static func run(evaluate: Bool) throws {
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
        guard evaluate else { return }
        var privateTexts: [String: Text] = [:]
        if let index = CommandLine.arguments.firstIndex(of: "--corpus-texts") {
            guard CommandLine.arguments.indices.contains(index + 1) else { throw CocoaError(.fileReadInvalidFileName) }
            privateTexts = try JSONDecoder().decode([String: Text].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            guard privateTexts.keys.allSatisfy({ docs[$0] != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        let formatter = ISO8601DateFormatter()
        var fingerprints: [String: Set<String>] = [:]
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
                                      description: "", pubDate: date, source: doc.source)
            article.fullContent = body
            fingerprints[doc.id] = Set(ArticleIdentity.publisherTextFingerprints(article))
        }
        let split = CommandLine.arguments.contains("--corpus-holdout") ? "holdout" : "tuning"
        var predictions: [String: Any] = [:]
        for pair in corpus.pairs where pair.split == split {
            guard let left = fingerprints[pair.left], let right = fingerprints[pair.right] else { throw CocoaError(.fileReadCorruptFile) }
            // Fingerprint is a binary document signal: same-event documents remain distinct.
            predictions[pair.id] = left.isEmpty || right.isEmpty ? NSNull() :
                (left.isDisjoint(with: right) ? "different" : "same_document") as Any
        }
        let output: [String: Any] = ["algorithm": "publisher-text-v1 (document signal only)", "task": "document_identity", "predictions": predictions]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print("CORPUS_PREDICTIONS " + String(decoding: data, as: UTF8.self))
    }
}
