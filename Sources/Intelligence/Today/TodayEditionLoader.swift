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

    func todaySubscribedFeedURLs() throws -> Set<String> {
        guard try tableExists("feeds") else { return [] }
        let rows = try eventRows("SELECT url FROM feeds;")
        return Set(rows.compactMap { $0[0] }.filter { !$0.isEmpty })
    }

    /// Builds the 30-day finer reading-interest and publisher-affinity profile (`read +1`, `saved +3`).
    func todayUserProfile(now: Date = Date(), resetAt: Date? = nil) throws -> TodayUserProfile {
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)
        let cutoff = max(thirtyDaysAgo, resetAt ?? .distantPast)
        let hasEnrichment = try tableExists("article_enrichment")
        let categoryExpr = hasEnrichment ? "coalesce(ae.category, a.category)" : "a.category"
        let enrichmentJoin = hasEnrichment ? "LEFT JOIN article_enrichment ae ON ae.article_id = a.id" : ""

        let rows = try eventRows(
            """
            SELECT a.id, a.source, a.canonical_url, a.title, \(categoryExpr), s.is_saved
            FROM article_state s
            JOIN articles a ON a.id = s.article_id
            \(enrichmentJoin)
            WHERE (s.is_saved = 1 OR s.is_read = 1)
                AND max(coalesce(s.saved_at, 0), coalesce(s.read_at, 0)) >= ?
                AND \(Self.visibleArticle)
            ORDER BY max(coalesce(s.saved_at, 0), coalesce(s.read_at, 0)) DESC
            LIMIT 200;
            """,
            [.real(cutoff.timeIntervalSince1970)]
        )

        var categoryWeights: [String: Double] = [:]
        var keywordWeights: [String: Double] = [:]
        var publisherWeights: [String: Double] = [:]
        var articleWeights: [String: Double] = [:]
        var totalInteractions = 0

        for row in rows {
            try Task.checkCancellation()
            guard let id = row[0] else { continue }
            let isSaved = row[5] == "1"
            let weight = isSaved ? 3.0 : 1.0
            totalInteractions += Int(weight)
            articleWeights[id] = max(articleWeights[id] ?? 0.0, weight)

            let publisher = FeedCatalog.publisher(forLink: row[2] ?? "") ?? row[1] ?? ""
            let pubKey = EventFeedSummary.displaySource(publisher).lowercased()
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

        var entityWeights: [String: Double] = [:]
        if !articleWeights.isEmpty, try tableExists("entity_mentions") {
            let ids = Array(articleWeights.keys).sorted()
            for start in stride(from: 0, to: ids.count, by: 400) {
                let slice = Array(ids[start..<min(start + 400, ids.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
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
                    let mentionScore = Double(row[2].flatMap(Int.init) ?? 1)
                    let base = articleWeights[articleID] ?? 1.0
                    entityWeights[entityID, default: 0.0] += base * min(3.0, max(1.0, mentionScore))
                }
            }
        }

        return TodayUserProfile(
            categoryWeights: categoryWeights,
            entityWeights: entityWeights,
            keywordWeights: keywordWeights,
            publisherWeights: publisherWeights,
            interactionCount: totalInteractions
        )
    }

    /// Loads stored per-story signals (`originalReportCount`, stored member text, stored entities,
    /// `pair_assessments` grouping confidence, overview sector impact) in bounded batches.
    func todayStorySignals(for entries: [FeedEntry]) throws -> [String: TodayStorySignals] {
        guard !entries.isEmpty else { return [:] }
        var signals: [String: TodayStorySignals] = [:]
        let hasEntities = try tableExists("entity_mentions")
        let hasPairs = try tableExists("pair_assessments")
        let hasOverviews = try tableExists("event_overviews")

        var entryByArticleID: [String: [String]] = [:]
        var eventToEntryIDs: [String: [String]] = [:]

        for entry in entries {
            signals[entry.id] = TodayStorySignals()
            var articleIDs: Set<String> = Set(entry.visibleArticles.map(\.id))
            if case .event(let summary, _, _) = entry {
                eventToEntryIDs[summary.eventID, default: []].append(entry.id)
                for member in summary.members {
                    articleIDs.insert(member.articleID)
                }
            }
            for aid in articleIDs {
                entryByArticleID[aid, default: []].append(entry.id)
            }
        }

        let allArticleIDs = Array(entryByArticleID.keys).sorted()
        var textsByEntryID: [String: [(publisher: String, text: String)]] = [:]

        let hasArticleFeeds = try tableExists("article_feeds")

        // 1. Load stored member full text, publisher attribution, and feed URLs.
        for start in stride(from: 0, to: allArticleIDs.count, by: 400) {
            let slice = Array(allArticleIDs[start..<min(start + 400, allArticleIDs.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
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
                for entryID in entryByArticleID[id] ?? [] {
                    textsByEntryID[entryID, default: []].append((publisher, combined))
                    if let feedURL = row[6], !feedURL.isEmpty {
                        signals[entryID]?.feedURLs.insert(feedURL)
                    }
                }
            }
            if hasArticleFeeds {
                let feedRows = try eventRows(
                    "SELECT article_id, feed_url FROM article_feeds WHERE article_id IN (\(placeholders));",
                    slice.map { .text($0) }
                )
                for row in feedRows {
                    guard let id = row[0], let feedURL = row[1], !feedURL.isEmpty else { continue }
                    for entryID in entryByArticleID[id] ?? [] {
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

        // 2. Stored entities (`entity_mentions`).
        if hasEntities, !allArticleIDs.isEmpty {
            for start in stride(from: 0, to: allArticleIDs.count, by: 400) {
                let slice = Array(allArticleIDs[start..<min(start + 400, allArticleIDs.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                let rows = try eventRows(
                    "SELECT article_id, entity_id FROM entity_mentions WHERE article_id IN (\(placeholders));",
                    slice.map { .text($0) }
                )
                for row in rows {
                    guard let articleID = row[0], let entityID = row[1] else { continue }
                    for entryID in entryByArticleID[articleID] ?? [] {
                        signals[entryID]?.entityIDs.insert(entityID)
                    }
                }
            }
        }

        // 3. Stored `pair_assessments` grouping confidence for confirmed events.
        let eventIDs = Array(eventToEntryIDs.keys).sorted()
        if hasPairs, !eventIDs.isEmpty {
            for start in stride(from: 0, to: eventIDs.count, by: 200) {
                let slice = Array(eventIDs[start..<min(start + 200, eventIDs.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                let rows = try eventRows(
                    """
                    SELECT coalesce(e1.story_id, m1.event_id), m1.event_id, avg(p.score)
                    FROM pair_assessments p
                    JOIN event_members m1 ON m1.article_id = p.article_id
                    JOIN event_members m2 ON m2.article_id = p.other_article_id
                    JOIN events e1 ON e1.id = m1.event_id
                    JOIN events e2 ON e2.id = m2.event_id
                    WHERE coalesce(e1.story_id, m1.event_id) = coalesce(e2.story_id, m2.event_id)
                        AND (m1.event_id IN (\(placeholders)) OR coalesce(e1.story_id, m1.event_id) IN (\(placeholders)))
                        AND p.decision IN ('match', 'related-act')
                    GROUP BY 1, 2;
                    """,
                    (slice + slice).map { .text($0) }
                )
                for row in rows {
                    guard let avgScore = row[2].flatMap(Double.init) else { continue }
                    for key in [row[0], row[1]].compactMap({ $0 }) {
                        for entryID in eventToEntryIDs[key] ?? [] {
                            signals[entryID]?.groupingConfidence = avgScore
                        }
                    }
                }
            }
        }

        // 4. Stored overview sector impact.
        if hasOverviews, !eventIDs.isEmpty {
            for start in stride(from: 0, to: eventIDs.count, by: 400) {
                let slice = Array(eventIDs[start..<min(start + 400, eventIDs.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ", ")
                let rows = try eventRows(
                    """
                    SELECT event_id, facts_json
                    FROM event_overviews
                    WHERE event_id IN (\(placeholders));
                    """,
                    slice.map { .text($0) }
                )
                for row in rows {
                    guard let eventID = row[0], let json = row[1] else { continue }
                    if json.contains("industryImpact") {
                        for entryID in eventToEntryIDs[eventID] ?? [] {
                            signals[entryID]?.hasSectorImpact = true
                        }
                    }
                }
            }
        }

        return signals
    }

    /// Loads the complete `TodayAssignmentContext` for an already-grouped list of `FeedEntry` values.
    func loadTodayAssignmentContext(
        entries: [FeedEntry],
        now: Date = Date(),
        starredFeedURLs: Set<String> = [],
        subscribedFeedURLs: Set<String>? = nil,
        resetAt: Date? = nil
    ) throws -> TodayAssignmentContext {
        let subscriptions: Set<String>?
        if let subscribedFeedURLs {
            subscriptions = subscribedFeedURLs
        } else {
            let dbFeeds = try todaySubscribedFeedURLs()
            subscriptions = dbFeeds.isEmpty ? nil : dbFeeds
        }
        let profile = try todayUserProfile(now: now, resetAt: resetAt)
        let signals = try todayStorySignals(for: entries)
        return TodayAssignmentContext(
            now: now,
            subscribedFeedURLs: subscriptions,
            starredFeedURLs: starredFeedURLs,
            profile: profile,
            signalsByEntryID: signals
        )
    }
}
