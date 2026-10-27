import Foundation

/// What one pair decision rested on, stored as JSON in `pair_assessments.features` (#551): the cosine, the pair model's
/// probability when it was asked, the conflict and the shared-evidence counts. Numbers only, no text.
struct EventPairFeatures: Codable, Equatable, Sendable {
    var cosine: Double?
    var pairModel: Double?
    var conflict: String?
    var what: Double
    var entity: Double
    var sharedAnchors: Int
    var sharedSpecific: Int
    var sharedKeywords: Int

    init(_ pair: EventPairAssessment, probability: Double?) {
        cosine = pair.embeddingCosine
        pairModel = probability
        conflict = pair.conflict?.rawValue
        what = pair.what
        entity = pair.entity
        sharedAnchors = pair.sharedAnchors
        sharedSpecific = pair.sharedSpecificAnchors
        sharedKeywords = pair.sharedKeywords
    }

    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct EventClusteringReport: Equatable, Sendable {
    var processed = 0
    var joined = 0
    var created = 0
    var detached = 0
    var conflicts = 0
    /// Event fragments of one story joined by the merge pass.
    var merged = 0
    /// Rows left for a pass with energy because a model they needed did not run (#534).
    var deferred = 0
    var changedEvents: Set<String> = []
}

/// Incremental event clustering. Each pass handles only articles that are new, whose title or description changed
/// since they were last matched, or that an older matcher version processed, within the active lifetime; then it
/// merges active events that report one story. Decisions are the deterministic rules plus the pair model for
/// borderline pairs. Matcher upgrades revalidate active memberships, never the archive.
enum EventClusterer {
    static let batchSize = 100
    private static let maximumAttempts = 2
    static func run(
        in database: DatabaseEngine,
        candidatePolicy: EventCandidatePolicy = .standard,
        matchPolicy: EventMatchPolicy = .standard,
        now: Date = Date(),
        limit: Int = 2_000,
        allowsEnergy: Bool = IntelligencePolicy.allowsEnergy(),
        pairProbability: (@Sendable (String, String) async -> Double?)? = nil
    ) async throws -> EventClusteringReport {
        let pairProbability = pairProbability ?? { a, b in await PairScorer.shared.probability(a, b) }
        var report = EventClusteringReport()
        /// Under the energy rule (#534) neither model runs: pairs they might have settled stay as the rules left them
        /// and the rows involved are marked one matcher version behind, so the next pass with energy reads them again.
        var deferred = Set<String>()
        var deferredCurrentRow = false
        /// Pair-model probabilities this pass, keyed low ID first (#525).
        var modelScores: [String: Double?] = [:]
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
        /// Pairs the reader put in one event (#524), by row, and the rows already looked up.
        var inclusions: [String: Set<String>] = [:]
        var inclusionLookups = Set<String>()
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
            let unlooked = rows.map(\.id).filter { !inclusionLookups.contains($0) }
            if !unlooked.isEmpty {
                inclusionLookups.formUnion(unlooked)
                let found = (try? await database.eventInclusions(for: unlooked)) ?? [:]
                inclusions.merge(found) { $0.union($1) }
            }
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
            // Reports recognized as another language never use the embedding (#553), so none is computed for them.
            let unembedded = rows.filter {
                embeddingCache[$0.id] == nil && !embeddingLookups.contains($0.id)
                    && (features($0).language ?? "en") == "en"
            }
            guard !unembedded.isEmpty else { return }
            embeddingLookups.formUnion(unembedded.map(\.id))
            let stored =
                (try? await database.fetchArticleEmbeddings(
                    articleIDs: unembedded.map(\.id), modelVersion: SentenceEmbedder.modelVersion)) ?? [:]
            var pending: [EventMatchRow] = []
            for row in unembedded {
                if let vector = stored[row.id] { embeddingCache[row.id] = vector } else { pending.append(row) }
            }
            guard !pending.isEmpty, allowsEnergy, await SentenceEmbedder.shared.isAvailable else { return }
            let vectors = await SentenceEmbedder.shared.embedBatch(
                pending.map { EventFeatures.matchingText(title: $0.title, description: $0.description) })
            for (row, vector) in zip(pending, vectors) {
                guard let vector else { continue }
                embeddingCache[row.id] = vector
                newEmbeddings[row.id] = vector
            }
        }
        func record(_ a: EventMatchRow, _ b: EventMatchRow, _ pair: EventPairAssessment, probability: Double? = nil) {
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
            } else if pair.conflict != nil, pair.sharedAnchors >= 1 || pair.sharedKeywords >= 2 {
                // A veto of a pair with shared evidence is reviewable (#551); pairs sharing nothing are not kept.
                decision = "vetoed"
            } else {
                decisions[key] = nil
                cleared[key] = (low, high)
                return
            }
            cleared[key] = nil
            decisions[key] = DatabaseEngine.PairDecision(
                articleID: low, otherArticleID: high, decision: decision,
                reason: pair.modelConfirmed ? "pairModel" : (pair.conflict?.rawValue ?? decision), score: pair.score,
                features: EventPairFeatures(pair, probability: probability).json)
        }
        /// The rules alone: no pair model and no audit row.
        func ruled(_ a: EventMatchRow, _ b: EventMatchRow) async -> EventPairAssessment {
            await prefetch([a, b])
            let sim: Double?
            if let vA = embeddingCache[a.id], let vB = embeddingCache[b.id] {
                sim = SentenceEmbedder.cosineSimilarity(vA, vB)
            } else {
                sim = nil
            }
            return EventMatcher.assess(
                features(a), features(b), policy: matchPolicy, embeddingSimilarity: sim,
                samePublisher: !a.source.isEmpty && a.source == b.source)
        }
        func assessed(_ a: EventMatchRow, _ b: EventMatchRow) async -> EventPairAssessment {
            var pair = await ruled(a, b)
            if !allowsEnergy {
                // Without a vector the semantic veto has not cleared a rule match, a rescue may be missing and the
                // model may have confirmed a borderline pair: such pairs stay open and are decided again later.
                let unvetted =
                    pair.embeddingCosine == nil && pair.neuralEligible && pair.conflict == nil
                    && pair.sharedSpecificAnchors >= 1
                if unvetted || EventMatcher.needsPairModel(pair) {
                    deferredCurrentRow = true
                    if pair.isMatch { pair = EventMatcher.unvetted(pair) }
                }
            } else if EventMatcher.needsPairModel(pair) {
                let key = a.id < b.id ? a.id + "\n" + b.id : b.id + "\n" + a.id
                if modelScores[key] == nil {
                    let gap: TimeInterval? = matchPolicy.pairModelPrefix ? abs(a.date.timeIntervalSince(b.date)) : nil
                    let samePublisher: Bool? =
                        matchPolicy.pairModelPrefix && !a.source.isEmpty && !b.source.isEmpty
                        ? a.source == b.source : nil
                    func input(_ row: EventMatchRow) -> String {
                        let text = EventFeatures.matchingText(title: row.title, description: row.description)
                        return matchPolicy.pairModelPrefix
                            ? EventMatcher.pairModelInput(text, gap: gap, samePublisher: samePublisher) : text
                    }
                    modelScores[key] = await pairProbability(input(a), input(b))
                }
                if let probability = modelScores[key] ?? nil, probability >= matchPolicy.pairModelThreshold {
                    pair = EventMatcher.modelConfirmed(pair, policy: matchPolicy)
                }
            }
            if matchPolicy.samePublisherRequiresMatch, !pair.isMatch, !a.source.isEmpty, a.source == b.source {
                pair.isCompatible = false
            }
            // The matcher's own verdict is recorded; a reader's inclusion only overrides it here.
            let key = a.id < b.id ? a.id + "\n" + b.id : b.id + "\n" + a.id
            record(a, b, pair, probability: modelScores[key] ?? nil)
            return inclusions[a.id]?.contains(b.id) == true ? EventMatcher.forced(pair, policy: matchPolicy) : pair
        }
        /// The row against each member. "Same Event" is transitive: a member the reader put in one event with a member
        /// the row matches is the same event for the row too, so a report of either side can still join (#524).
        func assessed(_ row: EventMatchRow, with members: [EventMatchRow]) async -> [EventPairAssessment] {
            var pairs: [EventPairAssessment] = []
            for member in members { pairs.append(await assessed(row, member)) }
            let matched = Set(zip(members, pairs).filter { $0.1.isMatch }.map { $0.0.id })
            guard !matched.isEmpty else { return pairs }
            return zip(members, pairs).map { member, pair in
                (inclusions[member.id] ?? []).isDisjoint(with: matched)
                    ? pair : EventMatcher.forced(pair, policy: matchPolicy)
            }
        }
        /// Reads the inclusions of an event's members again: the reader may have combined events since prefetch.
        func refreshInclusions(_ rows: [EventMatchRow]) async {
            let ids = rows.map(\.id)
            let found = (try? await database.eventInclusions(for: ids)) ?? [:]
            for id in ids { inclusions[id] = found[id] ?? [] }
            inclusionLookups.formUnion(ids)
        }
        func store() async {
            try? await database.storeClusteringPass(
                DatabaseEngine.ClusteringPassWrites(
                    features: newFeatures, embeddings: newEmbeddings, decisions: Array(decisions.values),
                    cleared: Array(cleared.values), readTexts: readTexts), at: now)
            newFeatures = [:]
            newEmbeddings = [:]
            decisions = [:]
            cleared = [:]
        }
        var remaining = limit
        matching: while remaining > 0 {
            try Task.checkCancellation()
            // Without energy, members already matched are not revalidated: the rules alone could split what the
            // model joined. They wait, pending, for a pass with energy.
            let pending = try await database.pendingEventMatchRows(
                activeSince: now.addingTimeInterval(-candidatePolicy.activeEventLifetime),
                matcherVersion: EventMatcher.version, limit: min(batchSize, remaining), revalidating: allowsEnergy)
            guard !pending.isEmpty else { break }
            await prefetch(pending)
            for row in pending where !handled.contains(row.id) {
                guard remaining > 0 else { break matching }
                try Task.checkCancellation()
                deferredCurrentRow = false
                defer { if deferredCurrentRow { deferred.insert(row.id) } }
                if row.previouslyMatched, let eventID = row.eventID,
                    let event = try await database.fetchEvent(id: eventID),
                    event.updatedAt >= now.addingTimeInterval(-candidatePolicy.activeEventLifetime),
                    let snapshot = try await database.eventMatchMembers(eventID: event.id)
                {
                    let members = snapshot.members.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
                    guard members.count <= remaining else { break matching }
                    await prefetch(members)
                    await refreshInclusions(members)
                    let exclusions = try await database.eventExclusions(for: members.map(\.id))
                    var groups: [[EventMatchRow]] = []
                    for member in members {
                        try Task.checkCancellation()
                        var partnerIndex: Int? = nil
                        for (idx, group) in groups.enumerated() {
                            guard !group.contains(where: { exclusions[member.id, default: []].contains($0.id) }) else {
                                continue
                            }
                            let pairs = await assessed(member, with: group)
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
                        await refreshInclusions(event.members)
                        let pairs = await assessed(row, with: others)
                        let isExcluded = others.contains { excluded.contains($0.id) }
                        let fits =
                            row.previouslyMatched
                            || (!isExcluded && EventMatcher.eventScore(pairs: pairs, policy: matchPolicy) != nil)
                        if fits || (!allowsEnergy && deferredCurrentRow) {
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
                    let pairs = await assessed(row, with: members)
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
                        if deferredCurrentRow { deferred.formUnion(partners) }
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
            if !deferred.isEmpty {
                try await database.markEventMatchProcessed(
                    Array(deferred), matcherVersion: EventMatcher.version - 1, at: now)
                report.deferred += deferred.count
                deferred = []
            }
        }
        /// Two thirds of the cross pairs between the earliest members of two events agree by the rules alone (#581): no
        /// conflict other than a different act, `storyLinkAnchors` shared specific names that are not common actors, and
        /// a shared keyword. A report alone (`single`) may instead share one such name, a headline figure ("70,000
        /// police") and two keywords, and every agreeing pair also needs the semantic veto's cosine.
        func storyPairsAgree(
            _ a: [EventMatchRow], _ b: [EventMatchRow], common: Set<String>, single: Bool = false
        ) async -> Bool {
            var agreeing = 0
            var total = 0
            for left in a.prefix(Self.storySampleSize) {
                for right in b.prefix(Self.storySampleSize) {
                    total += 1
                    let pair = await ruled(left, right)
                    // A series name one publisher repeats is no shared name here either (#688).
                    let template =
                        EventFeatures.sharedSeriesTerms(
                            features(left), features(right),
                            samePublisher: !left.source.isEmpty && left.source == right.source) ?? []
                    let (l, r) = (features(left).without(template), features(right).without(template))
                    let names = l.specificAnchors.intersection(r.specificAnchors).subtracting(common).count
                    let sharesFigure = !l.titleNumbers.isDisjoint(with: r.titleNumbers)
                    let figure = single && names >= 1 && pair.sharedKeywords >= 2 && sharesFigure
                    if (pair.conflict == nil || pair.conflict == .differentAct)
                        && (names >= matchPolicy.storyLinkAnchors || figure) && pair.sharedKeywords >= 1
                        && (!single || (pair.embeddingCosine ?? 0) >= matchPolicy.semanticVetoThreshold)
                    {
                        agreeing += 1
                    }
                }
            }
            return total > 0 && agreeing * 3 >= total * 2
        }
        /// The story pass (#581): two active events sharing at least `storyLinkAnchors` specific names that are not
        /// common actors of the week (`EventStoryRelation.commonActorShare`, the "Earlier in This Story" guard) are one
        /// story when `storyPairsAgree`; a reader's exclusion across the two events vetoes the link. Stories are
        /// connected components named by their earliest event of two or more reports; pair decisions and memberships are
        /// untouched.
        /// A report alone in the active window, unclustered or the only member of its event, joins the story of the
        /// event of two or more reports it agrees with best (`storyPairsAgree`, `single`), as a one-member event of its
        /// own, when its headline and one of the event's name a shared specific name; a reader's exclusion against that
        /// event's members vetoes it.
        func linkStories() async throws -> Set<String> {
            let activeSince = now.addingTimeInterval(-candidatePolicy.activeEventLifetime)
            let active = try await database.activeEventMembers(since: activeSince)
            let events = active.filter { $0.members.count >= 2 }
            let singles =
                active.filter { $0.members.count == 1 }.flatMap(\.members)
                + (try await database.unclusteredEventMatchRows(
                    since: activeSince, matcherVersion: EventMatcher.version))
            await prefetch(events.flatMap { $0.members } + singles)
            let exclusions = try await database.eventExclusions(
                for: events.flatMap { $0.members.map(\.id) } + singles.map(\.id))
            let allAnchors = Dictionary(
                events.map { event in
                    (event.id, event.members.reduce(into: Set<String>()) { $0.formUnion(features($1).specificAnchors) })
                }, uniquingKeysWith: { a, _ in a })
            // Only a name an event shares with another event or with a report alone can link anything, so only those
            // are checked for being common actors, each of them.
            var holders: [String: Int] = [:]
            for anchors in allAnchors.values { for anchor in anchors { holders[anchor, default: 0] += 1 } }
            for single in singles {
                for anchor in features(single).specificAnchors where holders[anchor] != nil {
                    holders[anchor, default: 0] += 1
                }
            }
            let common = try await database.commonStoryTerms(
                Set(holders.filter { $0.value >= 2 }.keys), before: now, share: EventStoryRelation.commonActorShare)
            let anchorsOf = allAnchors.mapValues { $0.subtracting(common) }
            var eventsByAnchor: [String: Set<String>] = [:]
            for (id, anchors) in anchorsOf {
                for anchor in anchors { eventsByAnchor[anchor, default: []].insert(id) }
            }
            let membersOf = Dictionary(
                events.map { ($0.id, $0.members.sorted { ($0.date, $0.id) < ($1.date, $1.id) }) },
                uniquingKeysWith: { a, _ in a })
            var components = StoryComponents()
            for event in events {
                try Task.checkCancellation()
                var shared: [String: Int] = [:]
                for anchor in anchorsOf[event.id] ?? [] {
                    for other in eventsByAnchor[anchor] ?? [] where other > event.id { shared[other, default: 0] += 1 }
                }
                for (other, count) in shared where count >= matchPolicy.storyLinkAnchors {
                    guard let a = membersOf[event.id], let b = membersOf[other],
                        !a.contains(where: { member in exclusions[member.id]?.isDisjoint(with: b.map(\.id)) == false }),
                        let gap = Self.closestGap(a, b), gap <= candidatePolicy.activeEventLifetime,
                        await storyPairsAgree(a, b, common: common)
                    else { continue }
                    components.join(event.id, other)
                }
            }
            var attached: [String: String] = [:]
            for single in singles {
                try Task.checkCancellation()
                var shared: [String: Int] = [:]
                for anchor in features(single).specificAnchors.subtracting(common) {
                    for id in eventsByAnchor[anchor] ?? [] { shared[id, default: 0] += 1 }
                }
                // Most shared names first, then the event whose first report came first (date, then article ID; event IDs
                // are random): one story per report.
                func rank(_ id: String) -> (Int, Date, String) {
                    (-(shared[id] ?? 0), membersOf[id]?.first?.date ?? .distantFuture, membersOf[id]?.first?.id ?? id)
                }
                for id in shared.keys.sorted(by: { rank($0) < rank($1) }) {
                    guard let members = membersOf[id],
                        exclusions[single.id]?.isDisjoint(with: members.map(\.id)) != false,
                        // Its own headline names the story: a live blog's latest entry can carry another one.
                        features(single).specificAnchors.subtracting(common).contains(where: { name in
                            Self.headline(single.title, names: name)
                                && members.contains { Self.headline($0.title, names: name) }
                        }),
                        let gap = Self.closestGap([single], members), gap <= candidatePolicy.activeEventLifetime,
                        await storyPairsAgree([single], members, common: common, single: true)
                    else { continue }
                    attached[single.id] = id
                    break
                }
            }
            return try await database.assignStories(components.groups, attaching: attached, since: activeSince, at: now)
        }
        /// Every cross-pair needs specific shared evidence; a contradiction or exclusion always vetoes a merge.
        var fragmentExclusions: [String: Set<String>] = [:]
        func compatibleFragments(_ first: [EventMatchRow], _ second: [EventMatchRow]) async throws -> Bool {
            for member in second {
                let exclusions = fragmentExclusions[member.id] ?? []
                if first.contains(where: { exclusions.contains($0.id) }) { return false }
            }
            // The rules settle most pairs of fragments: a conflict, or a pair without a shared specific anchor that
            // the pair model may not rescue, refuses the merge before the model is asked about anything.
            for a in first {
                for b in second where inclusions[a.id]?.contains(b.id) != true {
                    let pair = await ruled(a, b)
                    if pair.conflict != nil || (pair.sharedSpecificAnchors < 1 && !EventMatcher.needsPairModel(pair)) {
                        return false
                    }
                }
            }
            var pairs: [EventPairAssessment] = []
            for a in first {
                for b in second {
                    try Task.checkCancellation()
                    pairs.append(await assessed(a, b))
                }
            }
            guard pairs.allSatisfy({ $0.conflict == nil && ($0.sharedSpecificAnchors >= 1 || $0.modelConfirmed) })
            else {
                return false
            }
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
            let activeSince = now.addingTimeInterval(-candidatePolicy.activeEventLifetime)
            // A report the story pass attached as an act of its own stays one: attaching never changes events (#581).
            let attached = try await database.storyAttachedEventIDs(since: activeSince)
            var events = try await database.activeEventMembers(since: activeSince)
                .filter { !attached.contains($0.id) }
                .sorted { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.id < $1.id }
            fragmentExclusions = try await database.eventExclusions(for: events.flatMap { $0.members.map(\.id) })
            await prefetch(events.flatMap { $0.members })
            // Names and action words together: a name the tagger types in one report can be a plain word in another.
            // Each event's terms once, and an index from term to event (#541): only events sharing two terms are
            // compared, the same candidates the pairwise intersection found.
            var terms: [String: Set<String>] = [:]
            var eventsByTerm: [String: Set<String>] = [:]
            for event in events {
                let value = event.members.reduce(into: Set<String>()) {
                    $0.formUnion(features($1).specificAnchors.union(features($1).keywords))
                }
                terms[event.id] = value
                for term in value { eventsByTerm[term, default: []].insert(event.id) }
            }
            var index = 0
            while index < events.count {
                try Task.checkCancellation()
                var survivor = events[index]
                var survivorTerms = terms[survivor.id] ?? []
                var sharedCounts: [String: Int] = [:]
                for term in survivorTerms {
                    for id in eventsByTerm[term] ?? [] where id != survivor.id { sharedCounts[id, default: 0] += 1 }
                }
                var other = index + 1
                while other < events.count {
                    // Cross pairs are checked by the rules first and the model only after; cancellation stops both.
                    try Task.checkCancellation()
                    let candidate = events[other]
                    guard sharedCounts[candidate.id, default: 0] >= 2 else {
                        other += 1
                        continue
                    }
                    let candidateTerms = terms[candidate.id] ?? []
                    guard survivor.members.count + candidate.members.count <= matchPolicy.maximumEventSize,
                        let gap = Self.closestGap(survivor.members, candidate.members),
                        gap <= matchPolicy.maximumTimeGap
                    else {
                        other += 1
                        continue
                    }
                    guard try await compatibleFragments(survivor.members, candidate.members) else {
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
                        // The merged members' terms can reach a third fragment the survivor's alone did not.
                        for term in candidateTerms.subtracting(survivorTerms) {
                            for id in eventsByTerm[term] ?? [] where id != survivor.id {
                                sharedCounts[id, default: 0] += 1
                            }
                        }
                        survivorTerms.formUnion(candidateTerms)
                        terms[survivor.id] = survivorTerms
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
        report.changedEvents.formUnion(try await linkStories())
        return report
    }

    /// Earliest members of each event compared by the story pass; at most 25 cross pairs per candidate.
    static let storySampleSize = 5

    /// Connected components of event ids (#581), a small union-find.
    struct StoryComponents {
        private var parent: [String: String] = [:]

        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            return root
        }

        mutating func join(_ a: String, _ b: String) {
            let (left, right) = (find(a), find(b))
            parent[left] = parent[left] ?? left
            parent[right] = parent[right] ?? right
            if left != right { parent[max(left, right)] = min(left, right) }
        }

        /// Components with two or more members, each sorted.
        var groups: [[String]] {
            var groups: [String: [String]] = [:]
            for id in parent.keys { groups[find(id), default: []].append(id) }
            return groups.values.filter { $0.count >= 2 }.map { $0.sorted() }
        }
    }

    /// The name's words appear together in the headline, ignoring case, accents and punctuation (#581).
    static func headline(_ title: String, names name: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let (title, name) = (words(title), words(name))
        guard !name.isEmpty, name.count <= title.count else { return false }
        return (0...(title.count - name.count)).contains { Array(title[$0..<($0 + name.count)]) == name }
    }

    private static func closestGap(_ lhs: [EventMatchRow], _ rhs: [EventMatchRow]) -> TimeInterval? {
        lhs.flatMap { a in rhs.map { abs(a.date.timeIntervalSince($0.date)) } }.min()
    }
}
