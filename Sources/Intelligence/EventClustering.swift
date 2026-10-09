import Foundation
import NaturalLanguage

struct EventClusteringReport: Equatable, Sendable {
    var processed = 0
    var joined = 0
    var created = 0
    var detached = 0
    var conflicts = 0
    /// Event fragments of one story joined by the merge pass.
    var merged = 0
    /// Pairs the judge settled.
    var judged = 0
    var changedEvents: Set<String> = []
}

/// Incremental event clustering. Each pass handles only articles that are new, whose title or description changed
/// since they were last matched, or that an older matcher version processed, within the active lifetime; then it
/// merges active events that report one story. Deterministic rules decide; pairs they leave open
/// (`EventPairAssessment.isBorderline`) go to the judge, at most `judgeBudget` times per pass. It never compares the
/// archive with itself.
enum EventClusterer {
    static let batchSize = 100
    private static let maximumAttempts = 2
    /// Cosine distance of native sentence embeddings below which a pair that shares a name, but too few words, is
    /// worth asking the judge about. Embeddings never link a pair on their own (#127).
    static let paraphraseDistance = 0.35

    static func run(
        in database: DatabaseEngine,
        candidatePolicy: EventCandidatePolicy = .standard,
        matchPolicy: EventMatchPolicy = .standard,
        judge: EventJudge = .unavailable,
        judgeBudget: Int = 150,
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
        var judgementsLeft = judgeBudget
        var judged = 0
        var embeddings: [String: NLEmbedding?] = [:]
        func paraphrased(_ a: EventMatchRow, _ b: EventMatchRow, language: String?) -> Bool {
            guard let language else { return false }
            if embeddings[language] == nil { embeddings[language] = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language)) }
            guard let embedding = embeddings[language] ?? nil else { return false }
            return embedding.distance(between: Self.judgeText(a), and: Self.judgeText(b), distanceType: .cosine) <= paraphraseDistance
        }
        /// The deterministic assessment, settled by the judge when it is open and budget remains.
        func resolved(_ a: EventMatchRow, _ b: EventMatchRow) async -> EventPairAssessment {
            let first = features(a), second = features(b)
            var pair = EventMatcher.assess(first, second, policy: matchPolicy)
            if !pair.isMatch, !pair.isBorderline, pair.conflict == nil, pair.sharedKeywords < 2,
               !first.specificAnchors.isDisjoint(with: second.specificAnchors), judge.isAvailable, judgementsLeft > 0,
               paraphrased(a, b, language: first.language) {
                pair.isBorderline = true
            }
            guard pair.isBorderline || pair.needsConfirmation, judge.isAvailable, judgementsLeft > 0,
                  let same = await judge.sameEvent(Self.report(a), Self.report(b)) else { return pair }
            judgementsLeft -= 1
            judged += 1
            if pair.needsConfirmation { return same ? EventMatcher.confirmed(pair, policy: matchPolicy) : EventMatcher.rejected(pair) }
            return same ? EventMatcher.confirmed(pair, policy: matchPolicy) : pair
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

                // A changed member stays only while it still fits the rest of its event. An unchanged
                // member pending only for a newer matcher keeps its event: the whole-event check now
                // covers members that joined after it and would detach the earliest ones.
                if let current = row.eventID, let event = try await database.eventMatchMembers(eventID: current) {
                    let others = event.members.filter { $0.id != row.id }
                    if !others.isEmpty {
                        let fits = row.previouslyMatched || EventMatcher.eventScore(
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
                    guard !members.isEmpty, members.count < matchPolicy.maximumEventSize,
                          !members.contains(where: { excluded.contains($0.id) }) else { continue }
                    var pairs = members.map { EventMatcher.assess(article, features($0), policy: matchPolicy) }
                    // The judge settles open pairs, and confirms an admission that rests only on thin matches.
                    let admitted = EventMatcher.eventScore(pairs: pairs, policy: matchPolicy) != nil
                    let thin = !pairs.contains { $0.isMatch && !$0.needsConfirmation }
                    if (!admitted && pairs.contains(where: \.isBorderline)) || (admitted && thin) {
                        pairs = []
                        for member in members { pairs.append(await resolved(row, member)) }
                    }
                    guard let score = EventMatcher.eventScore(pairs: pairs, policy: matchPolicy) else { continue }
                    if score > (best?.score ?? 0) { best = (event.id, event.version, score) }
                }

                var decision: EventMatchDecision?
                if let best {
                    decision = .join(eventID: best.id, expectedVersion: best.version)
                } else {
                    // Otherwise start an event with unclustered candidates that match strongly and
                    // stay compatible with each other.
                    var scored: [(row: EventMatchRow, score: Double)] = []
                    for candidate in candidates where candidate.eventID == nil && !excluded.contains(candidate.articleID) {
                        guard let candidateRow = rows[candidate.articleID] else { continue }
                        let pair = await resolved(row, candidateRow)
                        if pair.isMatch { scored.append((candidateRow, pair.score)) }
                    }
                    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.row.id < $1.row.id }
                    var group: [(id: String, features: EventFeatures)] = []
                    for candidate in scored where group.count + 1 < matchPolicy.maximumEventSize {
                        let candidateFeatures = features(candidate.row)
                        guard group.allSatisfy({ EventMatcher.assess(candidateFeatures, $0.features, policy: matchPolicy).isCompatible }) else { continue }
                        let partnerExclusions = try await database.eventExclusions(of: candidate.row.id)
                        guard !group.contains(where: { partnerExclusions.contains($0.id) }) else { continue }
                        group.append((candidate.row.id, candidateFeatures))
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
        /// Whole coverage of two events, compared by the judge when member pairs do not decide.
        func sameStory(_ a: [EventMatchRow], _ b: [EventMatchRow]) async -> Bool {
            guard judge.isAvailable, judgementsLeft > 0,
                  let same = await judge.sameEvent(Self.coverage(a), Self.coverage(b)) else { return false }
            judgementsLeft -= 1
            judged += 1
            return same
        }
        /// Exclusions and hard conflicts always win; the judge only joins fragments linked by a matching pair.
        func compatibleFragments(_ first: [EventMatchRow], _ second: [EventMatchRow]) async throws -> Bool {
            for member in second {
                let exclusions = try await database.eventExclusions(of: member.id)
                if first.contains(where: { exclusions.contains($0.id) }) { return false }
            }
            var pairs: [EventPairAssessment] = []
            for a in first { for b in second { pairs.append(await resolved(a, b)) } }
            let required = Int((Double(pairs.count) * matchPolicy.compatibleShare).rounded(.up))
            let mean = pairs.isEmpty ? 0 : pairs.map(\.score).reduce(0, +) / Double(pairs.count)
            let related = pairs.contains(where: \.isMatch)
            if related, pairs.filter(\.isCompatible).count >= required, mean >= matchPolicy.compatibilityScore { return true }
            // Half or more hard conflicts cannot be overruled; fewer can be angles naming different places or days.
            let hardConflicts = pairs.filter { $0.conflict != nil && !$0.softConflict && $0.conflict != .timeGap }.count
            guard related, Double(hardConflicts) < Double(pairs.count) / 2 else { return false }
            return await sameStory(first, second)
        }

        /// The larger event survives (ties: the older ID), and the other forwards to it.
        func mergeFragments() async throws -> EventClusteringReport {
            var merges = EventClusteringReport()
            var events = try await database.activeEventMembers(since: now.addingTimeInterval(-candidatePolicy.activeEventLifetime))
                .sorted { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.id < $1.id }
            var index = 0
            while index < events.count {
                try Task.checkCancellation()
                var survivor = events[index]
                // Names and action words together: a name the tagger types in one report can be a plain word in another.
                let survivorTerms = survivor.members.reduce(into: Set<String>()) { $0.formUnion(features($1).specificAnchors.union(features($1).keywords)) }
                var other = index + 1
                while other < events.count {
                    let candidate = events[other]
                    let candidateTerms = candidate.members.reduce(into: Set<String>()) { $0.formUnion(features($1).specificAnchors.union(features($1).keywords)) }
                    guard survivor.members.count + candidate.members.count <= matchPolicy.maximumEventSize,
                          survivorTerms.intersection(candidateTerms).count >= 2,
                          let gap = Self.closestGap(survivor.members, candidate.members), gap <= matchPolicy.maximumTimeGap
                    else { other += 1; continue }
                    guard try await compatibleFragments(survivor.members, candidate.members) else { other += 1; continue }
                    do {
                        let merged = try await database.mergeEvents(candidate.id, into: survivor.id,
                                                                    expectedVersions: (candidate.version, survivor.version), at: now)
                        merges.merged += 1
                        merges.changedEvents.insert(survivor.id)
                        merges.changedEvents.insert(candidate.id)
                        survivor = (survivor.id, merged.membershipVersion, survivor.members + candidate.members)
                        events[index] = survivor
                        events.remove(at: other)
                    } catch {
                        // Membership changed underneath; the next pass decides again.
                        other += 1
                    }
                }
                index += 1
            }
            return merges
        }
        let merges = try await mergeFragments()
        report.merged = merges.merged
        report.changedEvents.formUnion(merges.changedEvents)
        report.judged = judged
        return report
    }

    private static func closestGap(_ lhs: [EventMatchRow], _ rhs: [EventMatchRow]) -> TimeInterval? {
        lhs.flatMap { a in rhs.map { abs(a.date.timeIntervalSince($0.date)) } }.min()
    }

    /// An event as one report for the judge: its first headline, with the other headlines as the summary.
    static func coverage(_ members: [EventMatchRow]) -> EventJudgeReport {
        let ordered = members.sorted { $0.date < $1.date }
        let others = ordered.dropFirst().prefix(4).map(\.title)
        return EventJudgeReport(id: "event:" + ordered.map(\.id).joined(separator: ","), title: ordered.first?.title ?? "",
                                summary: others.isEmpty ? (ordered.first?.description ?? "") : "Further coverage: " + others.joined(separator: "; "))
    }

    static func report(_ row: EventMatchRow) -> EventJudgeReport {
        EventJudgeReport(id: row.id, title: row.title, summary: row.description)
    }

    private static func judgeText(_ row: EventMatchRow) -> String {
        row.title + ". " + String(row.description.prefix(EventJudgeReport.summaryPrefix))
    }
}
