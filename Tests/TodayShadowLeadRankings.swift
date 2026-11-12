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

/// The three Lead rankings of the Z2 comparison (`#934`), and the private key file of a blind reader comparison:
/// every story in the top 20 of at least one ranking, with its place in each. `script/evaluation/lead_review.py`
/// turns that file into a shuffled sheet without the places and scores filled sheets against it.
extension TodayShadowEvaluation {
    static let leadRankingDepth = 20

    struct LeadRankings {
        let publisherCount: [TodayStoryAssignment]
        let briefing: [TodayStoryAssignment]
        let z2: [TodayStoryAssignment]
    }

    struct PrivateLeadRankings: Encodable {
        let pool: String
        let nowTimestamp: Double
        let candidates: Int
        let depth: Int
        let stories: [PrivateLeadRankingRow]
    }

    struct PrivateLeadRankingRow: Encodable {
        let id: String
        let publisher: String
        let title: String
        let summary: String
        /// The story's place in each ranking, from 1; a ranking that does not hold it in its top 20 is left out.
        let ranks: [String: Int]
    }

    /// `stories` ordered by publisher count alone, by today's Briefing signals and by the Z2 score.
    static func leadRankings(of stories: [TodayStoryAssignment], database: DatabaseEngine) async -> LeadRankings {
        let ordered = stories.sorted {
            let lhsDate = $0.entry.representative.orderDate
            let rhsDate = $1.entry.representative.orderDate
            return lhsDate == rhsDate ? $0.id < $1.id : lhsDate > rhsDate
        }
        let entries = ordered.map(\.entry)
        let briefingRanking = await BriefingRanking.load(entries: entries, database: database)
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LeadRankings(
            publisherCount: ordered.sorted {
                if $0.publisherCount != $1.publisherCount { return $0.publisherCount > $1.publisherCount }
                return $0.sortKey > $1.sortKey
            },
            briefing: briefingRanking.order(entries).compactMap { byID[$0.id] },
            z2: ordered.sorted { a, b in
                if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
                if a.originalReportCount != b.originalReportCount {
                    return a.originalReportCount > b.originalReportCount
                }
                return a.sortKey > b.sortKey
            })
    }

    /// Writes `lead-rankings-private.json`: the union of the three top 20s over every candidate of the pool,
    /// ordered by story id so the file's order says nothing about a ranking.
    static func writeLeadRankings(
        of candidates: [TodayStoryAssignment], pool: String, now: Date, database: DatabaseEngine, privateOutput: URL
    ) async throws {
        let ranked = await leadRankings(of: candidates, database: database)
        var ranks: [String: [String: Int]] = [:]
        for (name, order) in [
            ("publisherCount", ranked.publisherCount), ("briefing", ranked.briefing), ("z2", ranked.z2),
        ] {
            for (index, story) in order.prefix(leadRankingDepth).enumerated() {
                ranks[story.id, default: [:]][name] = index + 1
            }
        }
        let rows = candidates.filter { ranks[$0.id] != nil }.sorted { $0.id < $1.id }.map { item in
            let story = item.entry.representative
            return PrivateLeadRankingRow(
                id: item.id, publisher: story.publisherName, title: story.title,
                summary: String(story.description.prefix(240)), ranks: ranks[item.id] ?? [:])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StoryCorpus.writePrivate(
            try encoder.encode(
                PrivateLeadRankings(
                    pool: pool, nowTimestamp: now.timeIntervalSince1970, candidates: candidates.count,
                    depth: leadRankingDepth, stories: rows)),
            to: privateOutput.appendingPathComponent("lead-rankings-private.json"), replacing: true)
    }
}
