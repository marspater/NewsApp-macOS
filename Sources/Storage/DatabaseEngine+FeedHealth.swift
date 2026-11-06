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

/// Stored numbers behind the Publisher Health inspector (#715).
extension DatabaseEngine {
    /// Counters halve from this many attempts, so a feed's history fades instead of outweighing how it behaves now.
    static let feedSampleWindow = 200

    /// Counts one request a feed answered or failed; `latency` is nil for a failure. Requests the fetcher skips, a
    /// device that was offline and local rejections never reach this (`FeedFetcher.recordOutcomes`).
    func recordFeedSample(_ feedURL: String, latency: TimeInterval?) throws {
        try requireWritable()
        try inEventTransaction {
            try eventRows(
                """
                UPDATE feeds SET fetch_attempts = fetch_attempts + 1, fetch_successes = fetch_successes + ?,
                    fetch_latency_total = fetch_latency_total + ? WHERE url = ?;
                """, [.integer(latency == nil ? 0 : 1), .real(max(0, latency ?? 0)), .text(feedURL)])
            try eventRows(
                """
                UPDATE feeds SET fetch_attempts = fetch_attempts / 2, fetch_successes = fetch_successes / 2,
                    fetch_latency_total = fetch_latency_total / 2 WHERE url = ? AND fetch_attempts >= ?;
                """, [.text(feedURL), .integer(Self.feedSampleWindow)])
        }
    }

    /// Remembers why the reader could not take a story's text from its publisher's page.
    func recordReaderBarrier(_ barrier: ReaderBarrier, articleID: String) throws {
        try requireWritable()
        try eventRows(
            "UPDATE articles SET reader_barrier = ? WHERE id = ?;", [.text(barrier.rawValue), .text(articleID)])
    }

    /// The inspector's numbers for every stored feed. It scans the feed's stories, so call it from a task, not a
    /// view body; the actor keeps it off the main thread.
    func feedHealthMetrics(now: Date) throws -> [String: FeedHealthMetrics] {
        var observed: [String: FeedHealthObservations] = [:]
        for row in try eventRows("SELECT url, fetch_attempts, fetch_successes, fetch_latency_total FROM feeds;") {
            guard let url = row[0] else { continue }
            observed[url] = FeedHealthObservations(
                attempts: Int(row[1] ?? "") ?? 0, successes: Int(row[2] ?? "") ?? 0,
                latencyTotal: Double(row[3] ?? "") ?? 0)
        }
        let cutoff = now.addingTimeInterval(-FeedHealthMetrics.frequencyWindow).timeIntervalSince1970
        let rows = try eventRows(
            """
            SELECT feed_url, sum(published_at >= ?1), min(CASE WHEN published_at >= ?1 THEN published_at END),
                sum(kind = 'full'), sum(kind = 'teaser'), sum(kind = 'subscriber'), sum(kind = 'blocked')
            FROM (
                SELECT af.feed_url, a.published_at, CASE
                    WHEN complete = 1 OR length(coalesce(a.content, '')) >= \(FeedHealth.fullTextCharacters)
                        THEN 'full'
                    WHEN a.reader_barrier IS NOT NULL THEN a.reader_barrier
                    WHEN complete = 0 THEN 'teaser' END AS kind
                FROM article_feeds af JOIN (
                    SELECT *, CASE WHEN json_valid(reader_document)
                        THEN json_extract(reader_document, '$.isComplete') END AS complete FROM articles
                ) a ON a.id = af.article_id
            ) GROUP BY feed_url;
            """, [.real(cutoff)])
        for row in rows {
            guard let url = row[0] else { continue }
            var feed = observed[url] ?? FeedHealthObservations()
            feed.recentItems = Int(row[1] ?? "") ?? 0
            feed.oldestRecentItem = Double(row[2] ?? "").map { Date(timeIntervalSince1970: $0) }
            feed.fullReader = Int(row[3] ?? "") ?? 0
            feed.teaser = Int(row[4] ?? "") ?? 0
            feed.subscriberOnly = Int(row[5] ?? "") ?? 0
            feed.blocked = Int(row[6] ?? "") ?? 0
            observed[url] = feed
        }
        return observed.mapValues { FeedHealthMetrics($0, now: now) }
    }
}
