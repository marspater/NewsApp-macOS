import Foundation

struct EventClusteringReport: Equatable, Sendable {
    var processed = 0
    var joined = 0
    var created = 0
    var detached = 0
    var conflicts = 0
    var changedEvents: Set<String> = []
}

/// Incremental, deterministic event clustering. Each pass handles only articles that are new or
/// whose title or description changed since they were last matched, within the active lifetime.
/// It never compares the archive with itself and makes no model call per pair.
enum EventClusterer {
    static let batchSize = 100
    private static let maximumAttempts = 2

    static func run(
        in database: DatabaseEngine,
        candidatePolicy: EventCandidatePolicy = .standard,
        matchPolicy: EventMatchPolicy = .standard,
        now: Date = Date(),
        limit: Int = 2_000
    ) async throws -> EventClusteringReport {
        var report = EventClusteringReport()
        var cache: [String: EventFeatures] = [:]
        var attempts: [String: Int] = [:]
        /// Partners placed earlier in this pass; their rows in the current batch are stale.
        var handled = Set<String>()
        func features(_ row: EventMatchRow) -> EventFeatures {
            if let cached = cache[row.id] { return cached }
            let value = EventFeatures(title: row.title, description: row.description, date: row.date)
            cache[row.id] = value
            return value
        }

        var remaining = limit
        while remaining > 0 {
            try Task.checkCancellation()
            let pending = try await database.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-candidatePolicy.activeEventLifetime),
                matcherVersion: EventMatcher.version, limit: min(batchSize, remaining))
            guard !pending.isEmpty else { break }
            for row in pending where !handled.contains(row.id) {
                try Task.checkCancellation()
                remaining -= 1
                report.processed += 1
                let article = features(row)
                let excluded = try await database.eventExclusions(of: row.id)

                // A changed member stays only while it still fits the rest of its event.
                if let current = row.eventID, let event = try await database.eventMatchMembers(eventID: current) {
                    let others = event.members.filter { $0.id != row.id }
                    if !others.isEmpty {
                        let fits = EventMatcher.eventScore(
                            for: article, members: others.map(features),
                            excluded: others.contains { excluded.contains($0.id) }, policy: matchPolicy) != nil
                        if fits {
                            try await database.markEventMatchProcessed([row.id], matcherVersion: EventMatcher.version, at: now)
                            continue
                        }
                        try await database.removeArticles([row.id], fromEvent: event.id, at: now)
                        report.detached += 1
                        report.changedEvents.insert(event.id)
                    }
                }

                let probe = FeedArticle(storedID: row.id, title: row.title, link: "", guid: nil,
                                        description: row.description, pubDate: row.date, source: row.source)
                let candidates = try await EventCandidateFinder.candidates(for: probe, in: database, policy: candidatePolicy, now: now)
                let rows = Dictionary(try await database.eventMatchRows(articleIDs: candidates.map(\.articleID)).map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

                // Join the best active event the article fits as a whole.
                var best: (id: String, version: Int, score: Double)?
                for eventID in Set(candidates.compactMap(\.eventID)).sorted() {
                    try Task.checkCancellation()
                    guard let event = try await database.eventMatchMembers(eventID: eventID) else { continue }
                    let members = event.members.filter { $0.id != row.id }
                    guard !members.isEmpty, members.count < matchPolicy.maximumEventSize else { continue }
                    guard let score = EventMatcher.eventScore(
                        for: article, members: members.map(features),
                        excluded: members.contains { excluded.contains($0.id) }, policy: matchPolicy) else { continue }
                    if score > (best?.score ?? 0) { best = (event.id, event.version, score) }
                }

                var decision: EventMatchDecision?
                if let best {
                    decision = .join(eventID: best.id, expectedVersion: best.version)
                } else {
                    // Otherwise start an event with unclustered candidates that match strongly and
                    // stay compatible with each other.
                    let scored = candidates.filter { $0.eventID == nil && !excluded.contains($0.articleID) }
                        .compactMap { candidate -> (id: String, features: EventFeatures, score: Double)? in
                            guard let candidateRow = rows[candidate.articleID] else { return nil }
                            let candidateFeatures = features(candidateRow)
                            let pair = EventMatcher.assess(article, candidateFeatures, policy: matchPolicy)
                            return pair.isMatch ? (candidate.articleID, candidateFeatures, pair.score) : nil
                        }
                        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
                    var group: [(id: String, features: EventFeatures)] = []
                    for candidate in scored where group.count + 1 < matchPolicy.maximumEventSize {
                        guard group.allSatisfy({ EventMatcher.assess(candidate.features, $0.features, policy: matchPolicy).isCompatible }) else { continue }
                        let partnerExclusions = try await database.eventExclusions(of: candidate.id)
                        guard !group.contains(where: { partnerExclusions.contains($0.id) }) else { continue }
                        group.append((candidate.id, candidate.features))
                    }
                    if !group.isEmpty { decision = .create(with: group.map(\.id)) }
                }

                guard let decision else {
                    try await database.markEventMatchProcessed([row.id], matcherVersion: EventMatcher.version, at: now)
                    continue
                }
                let outcome = try await database.applyEventMatch(row.id, decision, matcherVersion: EventMatcher.version, at: now)
                switch outcome {
                case .joined(let id):
                    report.joined += 1
                    report.changedEvents.insert(id)
                case .created(let id):
                    report.created += 1
                    report.changedEvents.insert(id)
                    if case .create(let partners) = decision {
                        handled.formUnion(partners)
                        report.processed += partners.count
                    }
                case .conflict:
                    // Membership changed underneath the decision; the next batch decides again.
                    report.conflicts += 1
                    attempts[row.id, default: 0] += 1
                    if attempts[row.id, default: 0] >= maximumAttempts {
                        try await database.markEventMatchProcessed([row.id], matcherVersion: EventMatcher.version, at: now)
                    }
                }
            }
        }
        return report
    }
}
