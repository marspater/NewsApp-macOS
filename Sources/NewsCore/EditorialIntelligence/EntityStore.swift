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
import SQLite3

/// SQLite persistence and dossier aggregation for on-device entities (W2 #716).
extension DatabaseEngine {
    private static func formatISO8601(_ date: Date) -> String {
        date.ISO8601Format()
    }

    private static func parseISO8601(_ string: String) -> Date {
        if let d = try? Date(string, strategy: .iso8601) {
            return d
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }

    /// Saves extracted entities, article mentions, and entity co-occurrences in a single atomic transaction.
    func saveEntities(
        entities: [EntityRecord],
        mentions: [EntityMention],
        coOccurrences: [EntityCoOccurrence]
    ) throws {
        try requireWritable()
        try inEventTransaction {
            for entity in entities {
                let firstSeenStr = Self.formatISO8601(entity.firstSeen)
                let lastSeenStr = Self.formatISO8601(entity.lastSeen)
                try eventRows(
                    """
                    INSERT INTO entities (id, canonical_name, entity_type, mention_count, first_seen, last_seen)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        canonical_name = excluded.canonical_name,
                        mention_count = entities.mention_count + excluded.mention_count,
                        last_seen = CASE WHEN excluded.last_seen > entities.last_seen THEN excluded.last_seen ELSE entities.last_seen END;
                    """,
                    [
                        .text(entity.id),
                        .text(entity.canonicalName),
                        .text(entity.entityType.rawValue),
                        .integer(entity.mentionCount),
                        .text(firstSeenStr),
                        .text(lastSeenStr),
                    ]
                )
            }

            for mention in mentions {
                let publishedStr = Self.formatISO8601(mention.publishedAt)
                let offsetVal: EventValue = mention.passageOffset.map { .integer($0) } ?? .null
                try eventRows(
                    """
                    INSERT OR REPLACE INTO entity_mentions (id, entity_id, article_id, publisher_id, published_at, passage_offset, confidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(mention.id),
                        .text(mention.entityId),
                        .text(mention.articleId),
                        .text(mention.publisherId),
                        .text(publishedStr),
                        offsetVal,
                        .real(Double(mention.confidence)),
                    ]
                )
            }

            for co in coOccurrences {
                let (entityA, entityB) =
                    co.targetEntityId < co.targetCanonicalName
                    ? (co.targetEntityId, co.targetCanonicalName)
                    : (co.targetCanonicalName, co.targetEntityId)
                let nowStr = Self.formatISO8601(Date())
                try eventRows(
                    """
                    INSERT INTO entity_co_occurrences (entity_a, entity_b, count, last_seen)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(entity_a, entity_b) DO UPDATE SET
                        count = entity_co_occurrences.count + excluded.count,
                        last_seen = excluded.last_seen;
                    """,
                    [
                        .text(entityA),
                        .text(entityB),
                        .integer(co.coOccurrenceCount),
                        .text(nowStr),
                    ]
                )
            }
        }
    }

    /// Fetches an entity by canonical ID.
    func fetchEntity(id: String) throws -> EntityRecord? {
        let rows = try eventRows(
            """
            SELECT id, canonical_name, entity_type, mention_count, first_seen, last_seen
            FROM entities WHERE id = ? LIMIT 1;
            """,
            [.text(id)]
        )
        guard let row = rows.first,
            let entityId = row[0],
            let name = row[1],
            let typeStr = row[2],
            let type = EntityType(rawValue: typeStr),
            let countStr = row[3], let count = Int(countStr),
            let firstSeenStr = row[4],
            let lastSeenStr = row[5]
        else {
            return nil
        }
        return EntityRecord(
            id: entityId,
            canonicalName: name,
            entityType: type,
            mentionCount: count,
            firstSeen: Self.parseISO8601(firstSeenStr),
            lastSeen: Self.parseISO8601(lastSeenStr)
        )
    }

    /// Fetches top entities optionally filtered by type, ordered by mention count descending.
    func fetchTopEntities(type: EntityType? = nil, limit: Int = 30) throws -> [EntityRecord] {
        let rows: [[String?]]
        if let type = type {
            rows = try eventRows(
                """
                SELECT id, canonical_name, entity_type, mention_count, first_seen, last_seen
                FROM entities
                WHERE entity_type = ?
                ORDER BY mention_count DESC
                LIMIT ?;
                """,
                [.text(type.rawValue), .integer(limit)]
            )
        } else {
            rows = try eventRows(
                """
                SELECT id, canonical_name, entity_type, mention_count, first_seen, last_seen
                FROM entities
                ORDER BY mention_count DESC
                LIMIT ?;
                """,
                [.integer(limit)]
            )
        }

        return rows.compactMap { row -> EntityRecord? in
            guard let entityId = row[0],
                let name = row[1],
                let typeStr = row[2],
                let entityType = EntityType(rawValue: typeStr),
                let countStr = row[3], let count = Int(countStr),
                let firstSeenStr = row[4],
                let lastSeenStr = row[5]
            else {
                return nil
            }
            return EntityRecord(
                id: entityId,
                canonicalName: name,
                entityType: entityType,
                mentionCount: count,
                firstSeen: Self.parseISO8601(firstSeenStr),
                lastSeen: Self.parseISO8601(lastSeenStr)
            )
        }
    }

    /// Fetches mentions of entities within a specific article.
    func fetchEntityMentions(articleId: String) throws -> [EntityMention] {
        let rows = try eventRows(
            """
            SELECT id, entity_id, article_id, publisher_id, published_at, passage_offset, confidence
            FROM entity_mentions
            WHERE article_id = ?
            ORDER BY passage_offset ASC;
            """,
            [.text(articleId)]
        )

        return rows.compactMap { row -> EntityMention? in
            guard let id = row[0],
                let entityId = row[1],
                let artId = row[2],
                let pubId = row[3],
                let pubAtStr = row[4],
                let confStr = row[6], let conf = Float(confStr)
            else {
                return nil
            }
            let offset = row[5].flatMap { Int($0) }
            return EntityMention(
                id: id,
                entityId: entityId,
                articleId: artId,
                publisherId: pubId,
                publishedAt: Self.parseISO8601(pubAtStr),
                passageOffset: offset,
                confidence: conf
            )
        }
    }

    /// Assembles a 30-day coverage dossier for an entity, including co-occurrences and publisher breakdown.
    func fetchEntityDossier(entityId: String, referenceDate: Date = Date()) throws -> EntityDossier? {
        guard let entity = try fetchEntity(id: entityId) else { return nil }

        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate
        let thirtyDaysAgoStr = Self.formatISO8601(thirtyDaysAgo)

        // 1. 30-Day Coverage Timeline
        let coverageRows = try eventRows(
            """
            SELECT substr(published_at, 1, 10) AS date_bucket, count(*) AS bucket_count
            FROM entity_mentions
            WHERE entity_id = ? AND published_at >= ?
            GROUP BY date_bucket
            ORDER BY date_bucket ASC
            LIMIT 30;
            """,
            [.text(entityId), .text(thirtyDaysAgoStr)]
        )

        let coverageTimeline = coverageRows.compactMap { row -> EntityCoverageTimeseriesBucket? in
            guard let bucket = row[0],
                let countStr = row[1], let count = Int(countStr)
            else { return nil }
            return EntityCoverageTimeseriesBucket(dateBucket: bucket, mentionCount: count)
        }

        // 2. Co-occurring Entities
        let coRows = try eventRows(
            """
            SELECT
                CASE WHEN c.entity_a = ? THEN c.entity_b ELSE c.entity_a END AS target_id,
                coalesce(e.canonical_name, CASE WHEN c.entity_a = ? THEN c.entity_b ELSE c.entity_a END) AS target_name,
                coalesce(e.entity_type, 'organization') AS target_type,
                c.count
            FROM entity_co_occurrences c
            LEFT JOIN entities e ON e.id = (CASE WHEN c.entity_a = ? THEN c.entity_b ELSE c.entity_a END)
            WHERE c.entity_a = ? OR c.entity_b = ?
            ORDER BY c.count DESC
            LIMIT 30;
            """,
            [
                .text(entityId),
                .text(entityId),
                .text(entityId),
                .text(entityId),
                .text(entityId),
                .text(entityId),
            ]
        )

        let coOccurrences = coRows.compactMap { row -> EntityCoOccurrence? in
            guard let targetId = row[0],
                let name = row[1],
                let typeStr = row[2],
                let countStr = row[3], let count = Int(countStr)
            else { return nil }
            let type = EntityType(rawValue: typeStr) ?? .organization
            return EntityCoOccurrence(
                targetEntityId: targetId,
                targetCanonicalName: name,
                targetEntityType: type,
                coOccurrenceCount: count
            )
        }

        // 3. Publisher Distribution
        let pubRows = try eventRows(
            """
            SELECT publisher_id, count(*) AS mention_count
            FROM entity_mentions
            WHERE entity_id = ?
            GROUP BY publisher_id
            ORDER BY mention_count DESC
            LIMIT 30;
            """,
            [.text(entityId)]
        )

        var totalMentions = 0
        var rawDistributions: [(id: String, count: Int)] = []
        for row in pubRows {
            if let pubId = row[0], let cntStr = row[1], let cnt = Int(cntStr) {
                rawDistributions.append((pubId, cnt))
                totalMentions += cnt
            }
        }

        let publisherBreakdown = rawDistributions.map { item -> EntityPublisherDistribution in
            let share = totalMentions > 0 ? Double(item.count) / Double(totalMentions) : 0.0
            return EntityPublisherDistribution(
                publisherId: item.id,
                publisherName: item.id,
                mentionCount: item.count,
                share: share
            )
        }

        // 4. Recent Article IDs
        let articleRows = try eventRows(
            """
            SELECT DISTINCT article_id
            FROM entity_mentions
            WHERE entity_id = ?
            ORDER BY published_at DESC
            LIMIT 30;
            """,
            [.text(entityId)]
        )
        let recentArticleIds = articleRows.compactMap { $0[0] }

        return EntityDossier(
            entity: entity,
            coverage30Days: coverageTimeline,
            coOccurringEntities: coOccurrences,
            publisherBreakdown: publisherBreakdown,
            recentArticleIds: recentArticleIds
        )
    }

    /// Fetches the reader barrier recorded for an article, if any.
    func fetchArticleReaderBarrier(articleID: String) throws -> String? {
        let rows = try eventRows("SELECT reader_barrier FROM articles WHERE id = ? LIMIT 1;", [.text(articleID)])
        return rows.first?[0]
    }
}
