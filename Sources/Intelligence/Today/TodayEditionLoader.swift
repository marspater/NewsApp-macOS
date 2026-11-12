// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Angelia · Athena (editorial selection) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// Bounded SQLite loaders on `DatabaseEngine` (off the main actor) for Z2 Today lane assignment (`#934`).
/// Every query reads already-stored data only and never performs network requests or writes `story_importance`.
extension DatabaseEngine {

    func tableExists(_ name: String) throws -> Bool {
        let rows = try eventRows(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            [.text(name)]
        )
        return !rows.isEmpty
    }

    /// Builds the 30-day finer reading-interest and publisher-affinity profile (`read +1`, `saved +3`).
    ///
    /// `interactionLimit` keeps only the newest read or saved stories; the shadow evaluation lowers it to see the
    /// lanes of a reader with little history (#934).
    ///
    /// `affinityStoryFloor` is the evaluation option ``TodayEditionThresholds/yourBeatAffinityPerStoryFloor``. Only
    /// when it is set are the stories published in the window read, one row each.
    func todayUserProfile(
        now: Date = Date(), resetAt: Date? = nil, interactionLimit: Int = 200, affinityStoryFloor: Int? = nil
    ) throws -> TodayUserProfile {
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)
        let cutoff = max(thirtyDaysAgo, resetAt ?? .distantPast)
        var history = TodayReadingHistory()
        let rows = try todayReadingHistoryRows(since: cutoff, limit: interactionLimit)
        for row in rows {
            try Task.checkCancellation()
            history.add(row)
        }
        var profile = TodayUserProfile(
            categoryWeights: history.categoryWeights,
            entityWeights: try todayEntityWeights(articleWeights: history.articleWeights),
            keywordWeights: history.keywordWeights,
            publisherWeights: history.publisherWeights,
            interactionCount: history.totalInteractions
        )
        if let affinityStoryFloor {
            profile.topQuartilePublishers = try todayPerStoryAffinityPublishers(
                history: rows, weights: history.publisherWeights, from: thirtyDaysAgo, to: now,
                floor: affinityStoryFloor)
        }
        return profile
    }

    /// Your Beat's affinity publishers under the per-story option: reads the id and publisher of every visible
    /// story dated in the profile window, which the shipped rule never does.
    private func todayPerStoryAffinityPublishers(
        history rows: [[String?]], weights: [String: Double], from start: Date, to now: Date, floor: Int
    ) throws -> Set<String> {
        var published: [String: Int] = [:]
        var publishedIDs = Set<String>()
        let stories = try eventRows(
            """
            SELECT a.id, a.source, a.canonical_url
            FROM articles a
            JOIN article_state s ON s.article_id = a.id
            WHERE \(Self.visibleArticle) AND \(Self.articleDateOrder) BETWEEN ? AND ?;
            """,
            [.real(start.timeIntervalSince1970), .real(now.timeIntervalSince1970 + 300)]
        )
        for story in stories {
            guard let id = story[0] else { continue }
            publishedIDs.insert(id)
            published[TodayUserProfile.publisherKey(source: story[1], link: story[2]), default: 0] += 1
        }
        var windowWeights: [String: Double] = [:]
        var storiesRead: [String: Int] = [:]
        for row in rows {
            let key = TodayUserProfile.publisherKey(source: row[1], link: row[2])
            storiesRead[key, default: 0] += 1
            if let id = row[0], publishedIDs.contains(id) { windowWeights[key, default: 0] += row[5] == "1" ? 3 : 1 }
        }
        return TodayUserProfile.perStoryAffinityPublishers(
            weights: weights, windowWeights: windowWeights, storiesRead: storiesRead, published: published,
            floor: floor)
    }

    /// The stories read or saved since `cutoff`, newest interaction first: `id, source, canonical_url, title,
    /// category, is_saved`.
    func todayReadingHistoryRows(since cutoff: Date, limit: Int = 200) throws -> [[String?]] {
        let hasEnrichment = try tableExists("article_enrichment")
        let categoryExpr = hasEnrichment ? "coalesce(ae.category, a.category)" : "a.category"
        let enrichmentJoin = hasEnrichment ? "LEFT JOIN article_enrichment ae ON ae.article_id = a.id" : ""
        return try eventRows(
            """
            SELECT a.id, a.source, a.canonical_url, a.title, \(categoryExpr), s.is_saved
            FROM article_state s
            JOIN articles a ON a.id = s.article_id
            \(enrichmentJoin)
            WHERE (s.is_saved = 1 OR s.is_read = 1)
                AND max(coalesce(s.saved_at, 0), coalesce(s.read_at, 0)) >= ?
                AND \(Self.visibleArticle)
            ORDER BY max(coalesce(s.saved_at, 0), coalesce(s.read_at, 0)) DESC
            LIMIT \(max(0, min(200, limit)));
            """,
            [.real(cutoff.timeIntervalSince1970)]
        )
    }

    /// Entity weights of the read and saved stories from stored `entity_mentions`.
    private func todayEntityWeights(articleWeights: [String: Double]) throws -> [String: Double] {
        var entityWeights: [String: Double] = [:]
        guard !articleWeights.isEmpty, try tableExists("entity_mentions") else { return entityWeights }
        try todayBatches(Array(articleWeights.keys).sorted()) { slice, placeholders in
            let mentionRows = try eventRows(
                """
                SELECT article_id, entity_id, score
                FROM entity_mentions
                WHERE article_id IN (\(placeholders));
                """,
                slice.map { .text($0) }
            )
            for row in mentionRows {
                guard let articleID = row[0], let entityID = row[1] else { continue }
                let mentionScore = Double(row[2].flatMap { Int($0) } ?? 1)
                let base = articleWeights[articleID] ?? 1.0
                entityWeights[entityID, default: 0.0] += base * min(3.0, max(1.0, mentionScore))
            }
        }
        return entityWeights
    }

    /// Loads stored per-story signals (`originalReportCount`, stored member text, stored entities,
    /// `pair_assessments` grouping confidence, overview sector impact) in bounded batches.
    func todayStorySignals(for entries: [FeedEntry]) throws -> [String: TodayStorySignals] {
        guard !entries.isEmpty else { return [:] }
        var signals: [String: TodayStorySignals] = [:]
        for entry in entries {
            signals[entry.id] = TodayStorySignals()
        }
        let index = TodaySignalIndex(entries: entries)
        try loadTodayMemberTexts(index, into: &signals)
        try loadTodayFeedURLs(index, into: &signals)
        try loadTodayEntities(index, into: &signals)
        try loadTodayGroupingConfidence(index, into: &signals)
        try loadTodaySectorImpact(index, into: &signals)
        return signals
    }

    /// 1. Stored member full text, publisher attribution and feed URLs, then each entry's original report count.
    private func loadTodayMemberTexts(
        _ index: TodaySignalIndex,
        into signals: inout [String: TodayStorySignals]
    ) throws {
        var textsByEntryID: [String: [(publisher: String, text: String)]] = [:]
        try todayBatches(index.articleIDs) { slice, placeholders in
            let rows = try eventRows(
                """
                SELECT id, source, canonical_url, title, coalesce(description, ''), coalesce(content, ''), feed_url
                FROM articles
                WHERE id IN (\(placeholders));
                """,
                slice.map { .text($0) }
            )
            for row in rows {
                guard let id = row[0] else { continue }
                let publisher = FeedCatalog.publisher(forLink: row[2] ?? "") ?? row[1] ?? ""
                let combined = [row[3], row[4], row[5]].compactMap { $0 }.joined(separator: "\n")
                for entryID in index.entryIDsByArticleID[id] ?? [] {
                    textsByEntryID[entryID, default: []].append((publisher, combined))
                    if let feedURL = row[6], !feedURL.isEmpty {
                        signals[entryID]?.feedURLs.insert(feedURL)
                    }
                }
            }
        }
        for (entryID, reports) in textsByEntryID {
            var current = signals[entryID] ?? TodayStorySignals()
            current.originalReportCount = max(1, BriefingPriorityData.originalReports(reports))
            current.memberFullTexts = reports.map(\.text)
            signals[entryID] = current
        }
    }

    /// 1, continued. Every feed that carried a member (`article_feeds`), beside the `articles.feed_url` read above.
    private func loadTodayFeedURLs(
        _ index: TodaySignalIndex,
        into signals: inout [String: TodayStorySignals]
    ) throws {
        guard try tableExists("article_feeds") else { return }
        try todayBatches(index.articleIDs) { slice, placeholders in
            let feedRows = try eventRows(
                "SELECT article_id, feed_url FROM article_feeds WHERE article_id IN (\(placeholders));",
                slice.map { .text($0) }
            )
            for row in feedRows {
                guard let id = row[0], let feedURL = row[1], !feedURL.isEmpty else { continue }
                for entryID in index.entryIDsByArticleID[id] ?? [] {
                    signals[entryID]?.feedURLs.insert(feedURL)
                }
            }
        }
    }

    /// 2. Stored entities (`entity_mentions`).
    private func loadTodayEntities(
        _ index: TodaySignalIndex,
        into signals: inout [String: TodayStorySignals]
    ) throws {
        guard try tableExists("entity_mentions") else { return }
        try todayBatches(index.articleIDs) { slice, placeholders in
            let rows = try eventRows(
                "SELECT article_id, entity_id FROM entity_mentions WHERE article_id IN (\(placeholders));",
                slice.map { .text($0) }
            )
            for row in rows {
                guard let articleID = row[0], let entityID = row[1] else { continue }
                for entryID in index.entryIDsByArticleID[articleID] ?? [] {
                    signals[entryID]?.entityIDs.insert(entityID)
                }
            }
        }
    }

    /// 3. Stored `pair_assessments` grouping confidence: the mean score of every `match` and `related-act` pair
    /// inside the story of each requested event. A card names its story by one event (the newest of two or more
    /// reports, else the story's first), so each requested event is resolved to its story and gets that story's
    /// mean; a sibling event's pairs count toward it and never replace it.
    private func loadTodayGroupingConfidence(
        _ index: TodaySignalIndex,
        into signals: inout [String: TodayStorySignals]
    ) throws {
        guard try tableExists("pair_assessments") else { return }
        try todayBatches(index.eventIDs, size: 200) { slice, placeholders in
            // CROSS JOIN keeps SQLite on this join order, from the requested events through their story's members
            // to those members' pairs; left to itself the planner starts from every `match` pair in the library.
            let rows = try eventRows(
                """
                SELECT requested.id, avg(p.score)
                FROM events requested
                CROSS JOIN events e1
                    ON e1.story_id = coalesce(requested.story_id, requested.id)
                    OR (e1.story_id IS NULL AND e1.id = coalesce(requested.story_id, requested.id))
                CROSS JOIN event_members m1 ON m1.event_id = e1.id
                CROSS JOIN pair_assessments p ON p.article_id = m1.article_id
                CROSS JOIN event_members m2 ON m2.article_id = p.other_article_id
                CROSS JOIN events e2 ON e2.id = m2.event_id
                WHERE requested.id IN (\(placeholders))
                    AND coalesce(e2.story_id, e2.id) = coalesce(requested.story_id, requested.id)
                    AND p.decision IN ('match', 'related-act')
                GROUP BY requested.id;
                """,
                slice.map { .text($0) }
            )
            for row in rows {
                guard let eventID = row[0], let average = row[1].flatMap({ Double($0) }) else { continue }
                for entryID in index.entryIDsByEventID[eventID] ?? [] {
                    signals[entryID]?.groupingConfidence = average
                }
            }
        }
    }

    /// 4. Stored overview sector impact: an overview whose Industry Impact section holds at least one item, the
    /// test Briefing applies to the same document.
    private func loadTodaySectorImpact(
        _ index: TodaySignalIndex,
        into signals: inout [String: TodayStorySignals]
    ) throws {
        guard try tableExists("event_overviews") else { return }
        try todayBatches(index.eventIDs) { slice, placeholders in
            // The section's key in the stored text only narrows the rows: a fact can quote the word. Each match is
            // decoded as the reader decodes it, in either stored format.
            let rows = try eventRows(
                """
                SELECT event_id
                FROM event_overviews
                WHERE event_id IN (\(placeholders)) AND instr(facts_json, 'industryImpact') > 0;
                """,
                slice.map { .text($0) }
            )
            for row in rows {
                guard let eventID = row[0],
                    try fetchEventOverview(eventID: eventID)?.industryImpact.isEmpty == false
                else { continue }
                for entryID in index.entryIDsByEventID[eventID] ?? [] {
                    signals[entryID]?.hasSectorImpact = true
                }
            }
        }
    }

    /// Calls `body` with each batch of at most `size` ids and the `?, ?, …` placeholder list that binds it.
    private func todayBatches(
        _ ids: [String],
        size: Int = 400,
        _ body: (_ slice: [String], _ placeholders: String) throws -> Void
    ) rethrows {
        for start in stride(from: 0, to: ids.count, by: size) {
            let slice = Array(ids[start..<min(start + size, ids.count)])
            try body(slice, Array(repeating: "?", count: slice.count).joined(separator: ", "))
        }
    }

    /// The differing account each Coverage card shows, by story id, read from the stored overviews of the events
    /// past the grouping gate. A card without a stored overview, or with one publisher's account only, has none.
    func todayDifferingAccounts(for plan: TodayEditionPlan) throws -> [String: String] {
        var accounts: [String: String] = [:]
        for assignment in plan.allAssignments where assignment.isCoverageConfident {
            try Task.checkCancellation()
            guard case .event(let summary, _, _) = assignment.entry,
                let overview = try fetchEventOverview(eventID: summary.eventID),
                let account = StoryCardMetadata.differingAccount(in: overview.perspectives)
            else { continue }
            accounts[assignment.id] = account
        }
        return accounts
    }

    /// Loads the complete `TodayAssignmentContext` for an already-grouped list of `FeedEntry` values.
    ///
    /// `subscribedFeedURLs` is the reader's subscription list (`AppSettings.feedURLs`). The caller supplies it
    /// because the library does not hold it: the `feeds` table is fetch state, and its row outlives a removed
    /// subscription, so reading it would let a removed feed's stories into Today. An empty list admits no story.
    func loadTodayAssignmentContext(
        entries: [FeedEntry],
        now: Date = Date(),
        starredFeedURLs: Set<String> = [],
        subscribedFeedURLs: Set<String>,
        resetAt: Date? = nil,
        thresholds: TodayEditionThresholds = .standard
    ) throws -> TodayAssignmentContext {
        let profile = try todayUserProfile(
            now: now, resetAt: resetAt, affinityStoryFloor: thresholds.yourBeatAffinityPerStoryFloor)
        let signals = try todayStorySignals(for: entries)
        return TodayAssignmentContext(
            now: now,
            subscribedFeedURLs: subscribedFeedURLs,
            starredFeedURLs: starredFeedURLs,
            profile: profile,
            signalsByEntryID: signals,
            thresholds: thresholds
        )
    }
}

/// One pass over the reader's recent read and saved stories (`read +1`, `saved +3`).
private struct TodayReadingHistory {
    var categoryWeights: [String: Double] = [:]
    var keywordWeights: [String: Double] = [:]
    var publisherWeights: [String: Double] = [:]
    var articleWeights: [String: Double] = [:]
    var totalInteractions = 0

    /// Adds one row of `id, source, canonical_url, title, category, is_saved`.
    mutating func add(_ row: [String?]) {
        guard let id = row[0] else { return }
        let isSaved = row[5] == "1"
        let weight = isSaved ? 3.0 : 1.0
        totalInteractions += Int(weight)
        articleWeights[id] = max(articleWeights[id] ?? 0.0, weight)

        let pubKey = TodayUserProfile.publisherKey(source: row[1], link: row[2])
        if !pubKey.isEmpty {
            publisherWeights[pubKey, default: 0.0] += weight
        }

        if let cat = row[4].flatMap(NewsCategory.match(from:))?.rawValue.lowercased() {
            categoryWeights[cat, default: 0.0] += weight
        }

        let titleText = [row[3], row[4]].compactMap { $0 }.joined(separator: " ")
        for token in TodayEditionAssigner.substantiveHeadlineTokens(titleText) {
            keywordWeights[token, default: 0.0] += weight
        }
    }
}

/// Which entries each stored article and each event belong to, so a batched query can fan its rows out.
private struct TodaySignalIndex {
    let entryIDsByArticleID: [String: [String]]
    let entryIDsByEventID: [String: [String]]
    let articleIDs: [String]
    let eventIDs: [String]

    init(entries: [FeedEntry]) {
        var byArticle: [String: [String]] = [:]
        var byEvent: [String: [String]] = [:]
        for entry in entries {
            var articleIDs: Set<String> = Set(entry.visibleArticles.map(\.id))
            if case .event(let summary, _, _) = entry {
                byEvent[summary.eventID, default: []].append(entry.id)
                for member in summary.members {
                    articleIDs.insert(member.articleID)
                }
            }
            for aid in articleIDs {
                byArticle[aid, default: []].append(entry.id)
            }
        }
        entryIDsByArticleID = byArticle
        entryIDsByEventID = byEvent
        articleIDs = Array(byArticle.keys).sorted()
        eventIDs = Array(byEvent.keys).sorted()
    }
}
