import Foundation

struct EventClusteringReport: Equatable, Sendable {
    var processed = 0
    var joined = 0
    var created = 0
    var detached = 0
    var conflicts = 0
    /// Event fragments of one story joined by the merge pass.
    var merged = 0
    /// Legacy audit metric; deterministic clustering always reports zero.
    var judged = 0
    var changedEvents: Set<String> = []
}

/// Incremental event clustering. Each pass handles only articles that are new, whose title or description changed
/// since they were last matched, or that an older matcher version processed, within the active lifetime; then it
/// merges active events that report one story. Decisions are deterministic. Legacy judge arguments are retained
/// for audit callers but never invoked. Matcher upgrades revalidate active memberships, never the archive.
enum EventClusterer {
    static let batchSize = 100
    private static let maximumAttempts = 2
    static func run(
        in database: DatabaseEngine,
        candidatePolicy: EventCandidatePolicy = .standard,
        matchPolicy: EventMatchPolicy = .standard,
        judge _: EventJudge = .unavailable,
        judgeBudget _: Int = 150,
        now: Date = Date(),
        limit: Int = 2_000
    ) async throws -> EventClusteringReport {
        var report = EventClusteringReport()
        var cache: [String: EventFeatures] = [:]
        var embeddingCache: [String: [Float]] = [:]
        /// Signals and vectors computed this pass; stored after each batch and at the end (#522).
        var newFeatures: [String: EventFeatures] = [:]
        var newEmbeddings: [String: [Float]] = [:]
        /// Title and description each row had when this pass first read it; nothing computed from a text a refresh
        /// has since replaced is stored.
        var readTexts: [String: String] = [:]
        /// Rows whose vector storage was already consulted; a missing model is not asked again per pair.
        var embeddingLookups = Set<String>()
        /// Decisions worth keeping, keyed low ID first, and pairs that no longer qualify for the row they may have.
        var decisions: [String: DatabaseEngine.PairDecision] = [:]
        var cleared: [String: (String, String)] = [:]
        var attempts: [String: Int] = [:]
        /// Partners placed earlier in this pass; their rows in the current batch are stale.
        var handled = Set<String>()
        func read(_ row: EventMatchRow) {
            if readTexts[row.id] == nil { readTexts[row.id] = row.title + "\n" + row.description }
        }
        func features(_ row: EventMatchRow) -> EventFeatures {
            if let cached = cache[row.id] { return cached }
            read(row)
            let value = EventFeatures(title: row.title, description: row.description, date: row.date)
            cache[row.id] = value
            newFeatures[row.id] = value
            return value
        }
        /// Warms both caches for the rows from storage in two queries, computing what is missing. Only a warm cache
        /// is read while matching, so the greedy order of decisions does not depend on storage.
        func prefetch(_ rows: [EventMatchRow]) async {
            rows.forEach(read)
            let missing = rows.filter { cache[$0.id] == nil }
            if !missing.isEmpty {
                let stored =
                    (try? await database.fetchArticleFeatures(
                        articleIDs: missing.map(\.id), version: EventFeatures.storageVersion)) ?? [:]
                for row in missing {
                    if var value = stored[row.id] {
                        // Publication dates are rewritten on upsert without touching the stored signals.
                        value.date = row.date
                        cache[row.id] = value
                    } else {
                        _ = features(row)
                    }
                }
            }
            let unembedded = rows.filter { embeddingCache[$0.id] == nil && !embeddingLookups.contains($0.id) }
            guard !unembedded.isEmpty else { return }
            embeddingLookups.formUnion(unembedded.map(\.id))
            let stored =
                (try? await database.fetchArticleEmbeddings(
                    articleIDs: unembedded.map(\.id), modelVersion: SentenceEmbedder.modelVersion)) ?? [:]
            var pending: [EventMatchRow] = []
            for row in unembedded {
                if let vector = stored[row.id] { embeddingCache[row.id] = vector } else { pending.append(row) }
            }
            guard !pending.isEmpty, await SentenceEmbedder.shared.isAvailable else { return }
            let vectors = await SentenceEmbedder.shared.embedBatch(
                pending.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
            for (row, vector) in zip(pending, vectors) {
                guard let vector else { continue }
                embeddingCache[row.id] = vector
                newEmbeddings[row.id] = vector
            }
        }
        func record(_ a: EventMatchRow, _ b: EventMatchRow, _ pair: EventPairAssessment) {
            let (low, high) = a.id < b.id ? (a.id, b.id) : (b.id, a.id)
            let key = low + "\n" + high
            let decision: String
            if pair.isMatch {
                decision = "match"
            } else if pair.conflict == .differentAct, pair.sharedSpecificAnchors >= 1, pair.sharedKeywords >= 2 {
                // A shared actor alone is no story (#462): a related act also shares what the story is about.
                // ponytail: no common-actor discount here; add #462's if reviewed related-act links need it.
                decision = "related-act"
            } else if pair.isBorderline {
                decision = "borderline"
            } else {
                decisions[key] = nil
                cleared[key] = (low, high)
                return
            }
            cleared[key] = nil
            decisions[key] = DatabaseEngine.PairDecision(
                articleID: low, otherArticleID: high, decision: decision,
                reason: pair.conflict?.rawValue ?? decision, score: pair.score)
        }
        func assessed(_ a: EventMatchRow, _ b: EventMatchRow) async -> EventPairAssessment {
            await prefetch([a, b])
            let sim: Double?
            if let vA = embeddingCache[a.id], let vB = embeddingCache[b.id] {
                sim = SentenceEmbedder.cosineSimilarity(vA, vB)
            } else {
                sim = nil
            }
            let pair = EventMatcher.assess(features(a), features(b), policy: matchPolicy, embeddingSimilarity: sim)
            record(a, b, pair)
            return pair
        }
        func store() async {
            try? await database.storeClusteringPass(
                features: newFeatures, embeddings: newEmbeddings, decisions: Array(decisions.values),
                cleared: Array(cleared.values), readTexts: readTexts, featureVersion: EventFeatures.storageVersion,
                embeddingVersion: SentenceEmbedder.modelVersion, matcherVersion: EventMatcher.version, at: now)
            newFeatures = [:]
            newEmbeddings = [:]
            decisions = [:]
            cleared = [:]
        }
        var remaining = limit
        matching: while remaining > 0 {
            try Task.checkCancellation()
            let pending = try await database.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-candidatePolicy.activeEventLifetime),
                matcherVersion: EventMatcher.version, limit: min(batchSize, remaining))
            guard !pending.isEmpty else { break }
            await prefetch(pending)
            for row in pending where !handled.contains(row.id) {
                guard remaining > 0 else { break matching }
                try Task.checkCancellation()
                if row.previouslyMatched, let eventID = row.eventID,
                    let event = try await database.fetchEvent(id: eventID),
                    event.updatedAt >= now.addingTimeInterval(-candidatePolicy.activeEventLifetime),
                    let snapshot = try await database.eventMatchMembers(eventID: event.id)
                {
                    let members = snapshot.members.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
                    guard members.count <= remaining else { break matching }
                    await prefetch(members)
                    let exclusions = try await database.eventExclusions(for: members.map(\.id))
                    var groups: [[EventMatchRow]] = []
                    for member in members {
                        try Task.checkCancellation()
                        var partnerIndex: Int? = nil
                        for (idx, group) in groups.enumerated() {
                            guard !group.contains(where: { exclusions[member.id, default: []].contains($0.id) }) else {
                                continue
                            }
                            var pairs: [EventPairAssessment] = []
                            for other in group {
                                pairs.append(await assessed(member, other))
                            }
                            if EventMatcher.eventScore(pairs: pairs, policy: matchPolicy) != nil {
                                partnerIndex = idx
                                break
                            }
                        }
                        if let partnerIndex { groups[partnerIndex].append(member) } else { groups.append([member]) }
                    }
                    remaining -= members.count
                    report.processed += members.count
                    if let changed = try await database.repartitionEvent(
                        event.id, expectedVersion: snapshot.version, expectedMembers: snapshot.members,
                        groups: groups.map { $0.map(\.id) }, matcherVersion: EventMatcher.version,
                        activeSince: now.addingTimeInterval(-candidatePolicy.activeEventLifetime), at: now)
                    {
                        handled.formUnion(members.map(\.id))
                        report.detached += groups.dropFirst().reduce(0) { $0 + $1.count }
                        report.changedEvents.formUnion(changed)
                    } else {
                        report.conflicts += 1
                    }
                    continue
                }
                remaining -= 1
                report.processed += 1
                let excluded = try await database.eventExclusions(of: row.id)

                // Active version upgrades were partitioned above. Archived unchanged groups stay intact;
                // edited members must still fit their remaining event.
                if let current = row.eventID, let event = try await database.eventMatchMembers(eventID: current) {
                    let others = event.members.filter { $0.id != row.id }
                    if !others.isEmpty {
                        var pairs: [EventPairAssessment] = []
                        for other in others {
                            pairs.append(await assessed(row, other))
                        }
                        let isExcluded = others.contains { excluded.contains($0.id) }
                        let fits =
                            row.previouslyMatched
                            || (!isExcluded && EventMatcher.eventScore(pairs: pairs, policy: matchPolicy) != nil)
                        if fits {
                            try await database.markEventMatchProcessed(
                                [row.id], matcherVersion: EventMatcher.version, at: now)
                            continue
                        }
                        try await database.removeArticles([row.id], fromEvent: event.id, at: now)
                        report.detached += 1
                        report.changedEvents.insert(event.id)
                    }
                }

                let probe = FeedArticle(
                    storedID: row.id, title: row.title, link: "", guid: nil,
                    description: row.description, pubDate: row.date, source: row.source)
                let candidates = try await EventCandidateFinder.candidates(
                    for: probe, in: database, policy: candidatePolicy, now: now)
                let rows = Dictionary(
                    try await database.eventMatchRows(articleIDs: candidates.map(\.articleID)).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                await prefetch(Array(rows.values))

                // Join the best active event the article fits as a whole.
                var best: (id: String, version: Int, score: Double)?
                for eventID in Set(candidates.compactMap(\.eventID)).sorted() {
                    try Task.checkCancellation()
                    guard let event = try await database.eventMatchMembers(eventID: eventID) else { continue }
                    let members = event.members.filter { $0.id != row.id }
                    guard !members.isEmpty, members.count < matchPolicy.maximumEventSize,
                        !members.contains(where: { excluded.contains($0.id) })
                    else { continue }
                    await prefetch(members)
                    var pairs: [EventPairAssessment] = []
                    for member in members {
                        pairs.append(await assessed(row, member))
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
                    for candidate in candidates
                    where candidate.eventID == nil && !excluded.contains(candidate.articleID) {
                        guard let candidateRow = rows[candidate.articleID] else { continue }
                        let pair = await assessed(row, candidateRow)
                        if pair.isMatch { scored.append((candidateRow, pair.score)) }
                    }
                    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.row.id < $1.row.id }
                    var group: [EventMatchRow] = []
                    for candidate in scored where group.count < min(remaining, matchPolicy.maximumEventSize - 1) {
                        var candidatePairs: [EventPairAssessment] = []
                        for partner in ([row] + group) {
                            candidatePairs.append(await assessed(candidate.row, partner))
                        }
                        guard EventMatcher.eventScore(pairs: candidatePairs, policy: matchPolicy) != nil else {
                            continue
                        }
                        let partnerExclusions = try await database.eventExclusions(of: candidate.row.id)
                        guard !group.contains(where: { partnerExclusions.contains($0.id) }) else { continue }
                        group.append(candidate.row)
                    }
                    if !group.isEmpty { decision = .create(with: group.map(\.id)) }
                }

                guard let decision else {
                    try await database.markEventMatchProcessed([row.id], matcherVersion: EventMatcher.version, at: now)
                    continue
                }
                let outcome = try await database.applyEventMatch(
                    row.id, decision, matcherVersion: EventMatcher.version, at: now)
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
                        remaining -= partners.count
                    }
                case .conflict:
                    // Membership changed underneath the decision; the next batch decides again.
                    report.conflicts += 1
                    attempts[row.id, default: 0] += 1
                    if attempts[row.id, default: 0] >= maximumAttempts {
                        try await database.markEventMatchProcessed(
                            [row.id], matcherVersion: EventMatcher.version, at: now)
                    }
                }
            }
            // Match state is already committed per article; a later throw or cancellation keeps this batch's work.
            await store()
        }
        /// Every cross-pair needs specific shared evidence; a contradiction or exclusion always vetoes a merge.
        var fragmentExclusions: [String: Set<String>] = [:]
        func compatibleFragments(_ first: [EventMatchRow], _ second: [EventMatchRow]) async -> Bool {
            for member in second {
                let exclusions = fragmentExclusions[member.id] ?? []
                if first.contains(where: { exclusions.contains($0.id) }) { return false }
            }
            var pairs: [EventPairAssessment] = []
            for a in first {
                for b in second {
                    pairs.append(await assessed(a, b))
                }
            }
            guard pairs.allSatisfy({ $0.conflict == nil && $0.sharedSpecificAnchors >= 1 }) else { return false }
            let required = Int((Double(pairs.count) * matchPolicy.compatibleShare).rounded(.up))
            let mean = pairs.isEmpty ? 0 : pairs.map(\.score).reduce(0, +) / Double(pairs.count)
            let related = pairs.contains(where: \.isMatch)
            if related, pairs.filter(\.isCompatible).count >= required, mean >= matchPolicy.compatibilityScore {
                return true
            }
            return false
        }

        /// The larger event survives (ties: the older ID), and the other forwards to it.
        func mergeFragments() async throws -> EventClusteringReport {
            var merges = EventClusteringReport()
            var events = try await database.activeEventMembers(
                since: now.addingTimeInterval(-candidatePolicy.activeEventLifetime)
            )
            .sorted { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.id < $1.id }
            fragmentExclusions = try await database.eventExclusions(for: events.flatMap { $0.members.map(\.id) })
            await prefetch(events.flatMap { $0.members })
            var index = 0
            while index < events.count {
                try Task.checkCancellation()
                var survivor = events[index]
                // Names and action words together: a name the tagger types in one report can be a plain word in another.
                var survivorTerms = survivor.members.reduce(into: Set<String>()) {
                    $0.formUnion(features($1).specificAnchors.union(features($1).keywords))
                }
                var other = index + 1
                while other < events.count {
                    // Cross-pair checks are bounded; stop cancellation before each candidate.
                    try Task.checkCancellation()
                    let candidate = events[other]
                    let candidateTerms = candidate.members.reduce(into: Set<String>()) {
                        $0.formUnion(features($1).specificAnchors.union(features($1).keywords))
                    }
                    guard survivor.members.count + candidate.members.count <= matchPolicy.maximumEventSize,
                        survivorTerms.intersection(candidateTerms).count >= 2,
                        let gap = Self.closestGap(survivor.members, candidate.members),
                        gap <= matchPolicy.maximumTimeGap
                    else {
                        other += 1
                        continue
                    }
                    guard await compatibleFragments(survivor.members, candidate.members) else {
                        other += 1
                        continue
                    }
                    do {
                        let merged = try await database.mergeEvents(
                            candidate.id, into: survivor.id,
                            expectedVersions: (candidate.version, survivor.version), at: now)
                        merges.merged += 1
                        merges.changedEvents.insert(survivor.id)
                        merges.changedEvents.insert(candidate.id)
                        survivor = (survivor.id, merged.membershipVersion, survivor.members + candidate.members)
                        survivorTerms.formUnion(candidateTerms)
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
        await store()
        return report
    }

    private static func closestGap(_ lhs: [EventMatchRow], _ rhs: [EventMatchRow]) -> TimeInterval? {
        lhs.flatMap { a in rhs.map { abs(a.date.timeIntervalSince($0.date)) } }.min()
    }

    /// An event as one report for the judge: its first headline, with the other headlines as the summary.
    static func coverage(_ members: [EventMatchRow]) -> EventJudgeReport {
        let ordered = members.sorted { $0.date < $1.date }
        let others = ordered.dropFirst().prefix(4).map(\.title)
        return EventJudgeReport(
            id: "event:" + ordered.map(\.id).joined(separator: ","), title: ordered.first?.title ?? "",
            summary: others.isEmpty
                ? (ordered.first?.description ?? "") : "Further coverage: " + others.joined(separator: "; "))
    }

    static func report(_ row: EventMatchRow) -> EventJudgeReport {
        EventJudgeReport(id: row.id, title: row.title, summary: row.description)
    }
}
