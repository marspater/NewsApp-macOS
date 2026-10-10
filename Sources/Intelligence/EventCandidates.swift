import Foundation
import NaturalLanguage

/// Cheap, deterministic signals for finding articles that may report the same event. They only
/// narrow the search; whether two articles describe one event is decided by the matcher.
struct EventMatchKey: Hashable, Sendable {
    static let maximumTerms = 8
    private static let minimumWordLength = 4
    private static let languagePrefix = 600

    let language: String?
    let terms: [String]

    init(title: String, description: String) {
        let text = title + "\n" + String(description.prefix(Self.languagePrefix))
        language = Self.language(of: text)
        var seen = Set<String>()
        var terms: [String] = []
        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard terms.count < Self.maximumTerms, trimmed.count >= Self.minimumWordLength,
                trimmed.contains(where: \.isLetter), seen.insert(trimmed.lowercased()).inserted
            else { return }
            terms.append(trimmed)
        }
        // Named participants and places first, then distinctive title words.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) {
            tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { add(String(text[range])) }
            return true
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = title
        tokenizer.enumerateTokens(in: title.startIndex..<title.endIndex) { range, _ in
            add(String(title[range]).lowercased())
            return true
        }
        self.terms = terms
    }

    init(article: FeedArticle) {
        self.init(title: article.title, description: article.description)
    }

    /// Dominant language when the recognizer is reasonably sure; nil otherwise.
    static func language(of text: String, using recognizer: NLLanguageRecognizer = NLLanguageRecognizer()) -> String? {
        recognizer.reset()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
            (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.5
        else { return nil }
        return language.rawValue
    }

    /// FTS5 query over title and description: each term is a quoted phrase, so publisher text
    /// cannot inject query syntax.
    var ftsQuery: String? {
        let phrases = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }
        guard !phrases.isEmpty else { return nil }
        return "{title description} : (" + phrases.joined(separator: " OR ") + ")"
    }
}

/// Bounds that keep candidate generation incremental: a time window around the article, a cap on
/// candidates, and a lifetime after which an event no longer gains members.
struct EventCandidatePolicy: Sendable {
    var window: TimeInterval = 48 * 3600
    var activeEventLifetime: TimeInterval = 72 * 3600
    var limit = 40

    static let standard = EventCandidatePolicy()
}

struct EventCandidate: Hashable, Sendable {
    let articleID: String
    /// The active event the candidate already belongs to, if any.
    let eventID: String?
}

enum EventCandidateFinder {
    /// Candidates for one article. Reads at most twice `policy.limit` rows; never scans the archive.
    static func candidates(
        for article: FeedArticle,
        in database: DatabaseEngine,
        policy: EventCandidatePolicy = .standard,
        now: Date = Date()
    ) async throws -> [EventCandidate] {
        let key = EventMatchKey(article: article)
        guard let query = key.ftsQuery, policy.limit > 0 else { return [] }
        let date = article.pubDate == DateParser.unknownDate ? now : article.pubDate
        let rows = try await database.eventCandidateRows(
            matching: query, around: date, window: policy.window,
            activeSince: now.addingTimeInterval(-policy.activeEventLifetime),
            excluding: article.id, limit: policy.limit * 2)
        var candidates: [EventCandidate] = []
        // Reset between candidates so language evidence cannot leak from the previous article.
        let recognizer = NLLanguageRecognizer()
        for row in rows where candidates.count < policy.limit {
            try Task.checkCancellation()
            // Different languages are not compared directly; unknown languages stay eligible.
            if let language = key.language,
                let other = EventMatchKey.language(
                    of: row.title + "\n" + String(row.description.prefix(600)), using: recognizer),
                other != language
            {
                continue
            }
            candidates.append(EventCandidate(articleID: row.id, eventID: row.eventID))
        }
        return candidates
    }
}
