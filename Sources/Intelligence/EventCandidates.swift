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

// MARK: - Developing-story relations (#314)

/// A navigation candidate, never a clustering decision or an asserted event date.
struct RelatedStoryEvent: Hashable, Sendable {
    let eventID: String
    let articleID: String
    let title: String
    let firstPublishedAt: Date
}

/// Experimental, read-only relation. Keep it out of the reader until reviewed wrong-link rates
/// are acceptable. Missing signals deliberately produce no link.
enum EventStoryRelation {
    static let window: TimeInterval = 72 * 3600
    static let candidateLimit = 40
    static let linkLimit = 3
    static let memberLimit = 100

    static func find(eventID: String, in database: DatabaseEngine) async throws -> [RelatedStoryEvent] {
        let snapshot = try await database.relatedStoryEventRows(eventID: eventID)
        // NaturalLanguage work must not hold either the database actor or the main actor.
        let work = Task.detached(priority: .utility) {
            try links(target: snapshot.target, candidates: snapshot.candidates)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
        }
    }

    static func supports(_ earlier: EventFeatures, _ later: EventFeatures) -> Bool {
        let gap = later.date.timeIntervalSince(earlier.date)
        guard earlier.language == "en", later.language == "en",
            earlier.date != DateParser.unknownDate, later.date != DateParser.unknownDate,
            gap > 0, gap <= window,
            !earlier.people.union(earlier.organizations)
                .isDisjoint(with: later.people.union(later.organizations)),
            !earlier.localPlaces.isDisjoint(with: later.localPlaces),
            earlier.keywords.intersection(later.keywords)
                .subtracting(earlier.anchors.union(later.anchors)).count >= 2
        else { return false }
        // A shared town must not override explicit contradictory countries or reporting periods.
        for (a, b) in [
            (earlier.countries, later.countries), (earlier.periods, later.periods), (earlier.years, later.years),
        ] {
            if !a.isEmpty && !b.isEmpty && a.isDisjoint(with: b) { return false }
        }
        return true
    }

    static func links(
        target: [EventMatchRow], candidates: [(id: String, members: [EventMatchRow])]
    ) throws -> [RelatedStoryEvent] {
        try Task.checkCancellation()
        guard !target.isEmpty, target.count <= memberLimit,
            target.allSatisfy({ $0.date != DateParser.unknownDate }),
            let start = target.map(\.date).min()
        else { return [] }
        let targetIDs = Set(target.compactMap(\.eventID))
        let targetFeatures = target.map { EventFeatures(title: $0.title, description: $0.description, date: $0.date) }
        var links: [RelatedStoryEvent] = []
        for candidate in candidates.prefix(candidateLimit) {
            try Task.checkCancellation()
            let members = candidate.members
            guard !targetIDs.contains(candidate.id), !members.isEmpty, members.count <= memberLimit,
                members.allSatisfy({
                    $0.date != DateParser.unknownDate && $0.date < start && start.timeIntervalSince($0.date) <= window
                }),
                let first = members.min(by: { ($0.date, $0.id) < ($1.date, $1.id) })
            else { continue }
            let features = members.map { EventFeatures(title: $0.title, description: $0.description, date: $0.date) }
            var supportedEarlier = Set<Int>()
            var supportedLater = Set<Int>()
            // ponytail: at most 40 events × 100 × 100 pairs; use indexed features if those caps grow.
            for (i, earlier) in features.enumerated() {
                try Task.checkCancellation()
                for (j, later) in targetFeatures.enumerated() where supports(earlier, later) {
                    supportedEarlier.insert(i)
                    supportedLater.insert(j)
                }
            }
            guard supportedEarlier.count * 3 >= members.count * 2,
                supportedLater.count * 3 >= target.count * 2
            else { continue }
            links.append(
                RelatedStoryEvent(
                    eventID: candidate.id, articleID: first.id, title: first.title, firstPublishedAt: first.date))
        }
        // Direct evidence only: never expand a link's neighbours into a transitive story family.
        return Array(
            links.sorted {
                $0.firstPublishedAt == $1.firstPublishedAt
                    ? $0.eventID < $1.eventID : $0.firstPublishedAt > $1.firstPublishedAt
            }.prefix(linkLimit))
    }
}
