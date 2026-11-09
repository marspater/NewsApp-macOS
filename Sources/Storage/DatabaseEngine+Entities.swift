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

/// A story waiting for the entity index, with the text its entities are read from.
struct EntityIndexCandidate: Sendable, Equatable {
    let articleID: String
    let title: String
    let description: String
    let text: String
    let publisher: String
    let publishedAt: Date
    /// The newest publisher-text revision the index read; a later one makes the story a candidate again.
    let revision: Int
}

/// An entity one story is about, with the score that earned it (mentions in the body, three times as many in the
/// title and description).
struct IndexedEntity: Sendable, Equatable {
    let name: String
    let type: EntityType
    let score: Int
}

/// Entity index, co-reporting graph and dossiers (W2 #716).
///
/// `entity_mentions` is the evidence: one row per story and entity. `entities` (counts, dates, centrality) and
/// `entity_edges` (the typed, weighted adjacency list) are aggregates of it that `refreshEntityGraph` rebuilds, so a
/// change to the rules needs no migration. Nothing here runs on the feed path: the index and the graph are written by
/// background passes, and a dossier only reads.
extension DatabaseEngine {
    /// The window a dossier covers.
    static let dossierDays = 30
    /// The most stories one background batch reads and commits.
    static let entityIndexBatch = 100

    // MARK: - Index

    /// Stories the index has not read, or read before the publisher changed their text, newest first. Stories behind
    /// a reader barrier (a paywall teaser) and reconciled duplicates are left out: wire text counts once.
    func entityIndexCandidates(limit: Int, textLimit: Int = 8_000) throws -> [EntityIndexCandidate] {
        guard db != nil else { return [] }
        let revision = "coalesce((SELECT max(version) FROM publisher_content_revisions r WHERE r.article_id = a.id), 0)"
        let rows = try eventRows(
            """
            SELECT a.id, a.title, coalesce(a.description, ''), substr(coalesce(a.content, ''), 1, ?1), a.source,
                   \(Self.articleDateOrder), \(revision)
            FROM articles a LEFT JOIN entity_index x ON x.article_id = a.id
            WHERE a.reader_barrier IS NULL AND \(Self.visibleArticle)
                AND (x.article_id IS NULL OR x.revision < \(revision))
            ORDER BY \(Self.articleDateOrder) DESC
            LIMIT ?2;
            """, [.integer(textLimit), .integer(limit)])
        return rows.compactMap { row in
            guard let id = row[0], let title = row[1], let description = row[2], let text = row[3],
                let publisher = row[4], let date = row[5].flatMap(Double.init), let revision = row[6].flatMap(Int.init)
            else { return nil }
            return EntityIndexCandidate(
                articleID: id, title: title, description: description, text: text, publisher: publisher,
                publishedAt: Date(timeIntervalSince1970: date), revision: revision)
        }
    }

    /// Replaces what the index holds for these stories, in one transaction. Re-reading a story replaces its rows, so
    /// no count grows by reading twice. False, with nothing written, when derived data was cleared since the pass began.
    @discardableResult
    func saveEntityIndex(
        _ batch: [(candidate: EntityIndexCandidate, entities: [IndexedEntity])], expectedGeneration: Int
    ) throws -> Bool {
        try requireWritable()
        return try inEventTransaction { () throws -> Bool in
            if expectedGeneration != analysisGeneration { return false }
            var touched = Set<String>()
            for (candidate, entities) in batch {
                let article = EventValue.text(candidate.articleID)
                for row in try eventRows("SELECT entity_id FROM entity_mentions WHERE article_id = ?;", [article]) {
                    if let id = row[0] { touched.insert(id) }
                }
                try eventRows("DELETE FROM entity_mentions WHERE article_id = ?;", [article])
                for entity in entities {
                    let id = EntityGraph.slug(name: entity.name, type: entity.type)
                    touched.insert(id)
                    let published = candidate.publishedAt.timeIntervalSince1970
                    try eventRows(
                        """
                        INSERT INTO entities (id, canonical_name, entity_type, story_count, first_seen, last_seen)
                        VALUES (?, ?, ?, 0, ?, ?) ON CONFLICT(id) DO NOTHING;
                        """,
                        [
                            .text(id), .text(entity.name), .text(entity.type.rawValue), .real(published),
                            .real(published),
                        ])
                    try eventRows(
                        """
                        INSERT OR REPLACE INTO entity_mentions (entity_id, article_id, publisher, published_at, score)
                        VALUES (?, ?, ?, ?, ?);
                        """, [.text(id), article, .text(candidate.publisher), .real(published), .integer(entity.score)])
                }
                try eventRows(
                    """
                    INSERT INTO entity_index (article_id, revision) VALUES (?, ?)
                    ON CONFLICT(article_id) DO UPDATE SET revision = excluded.revision;
                    """, [article, .integer(candidate.revision)])
            }
            for id in touched { try recountEntity(id) }
            return true
        }
    }

    /// Story count and first and last mention of one entity from its mentions; an entity no story names is removed.
    private func recountEntity(_ id: String) throws {
        try eventRows(
            """
            UPDATE entities SET
                story_count = (SELECT count(*) FROM entity_mentions m WHERE m.entity_id = entities.id),
                first_seen = coalesce((SELECT min(published_at) FROM entity_mentions m WHERE m.entity_id = entities.id), first_seen),
                last_seen = coalesce((SELECT max(published_at) FROM entity_mentions m WHERE m.entity_id = entities.id), last_seen)
            WHERE id = ?;
            """, [.text(id)])
        try eventRows("DELETE FROM entities WHERE id = ? AND story_count = 0;", [.text(id)])
    }

    // MARK: - Graph

    /// What `refreshEntityGraph` leaves: how many entities and edges the graph holds.
    struct EntityGraphReport: Sendable, Equatable {
        let entities: Int
        let edges: Int
    }

    /// Rebuilds the aggregates from the mentions: drops mentions of stories now reconciled as duplicates, recounts
    /// every entity and rebuilds the typed adjacency list. `withCentrality` also stores each entity's global
    /// centrality, a PageRank over the whole graph that only a background maintenance pass asks for: any other pass
    /// leaves the centrality of the last one in place, and a dossier never computes it (#716). Nil, with nothing
    /// written, when derived data was cleared since the pass began.
    func refreshEntityGraph(now: Date = Date(), expectedGeneration: Int, withCentrality: Bool) throws
        -> EntityGraphReport?
    {
        try requireWritable()
        return try inEventTransaction { () throws -> EntityGraphReport? in
            if expectedGeneration != analysisGeneration { return nil }
            try eventRows(
                "DELETE FROM entity_mentions WHERE article_id IN (SELECT duplicate_id FROM article_reconciliations);")
            try eventRows(
                """
                UPDATE entities SET
                    story_count = (SELECT count(*) FROM entity_mentions m WHERE m.entity_id = entities.id),
                    first_seen = coalesce((SELECT min(published_at) FROM entity_mentions m WHERE m.entity_id = entities.id), first_seen),
                    last_seen = coalesce((SELECT max(published_at) FROM entity_mentions m WHERE m.entity_id = entities.id), last_seen);
                """)
            try eventRows("DELETE FROM entities WHERE story_count = 0;")

            // A pair counts once per publisher, at its most recent story's weight (source independence), and needs
            // two stories before it is a relationship (evidence).
            let age = "(?1 - a.published_at) / 86400.0"
            try eventRows("DELETE FROM entity_edges;")
            try eventRows(
                """
                INSERT INTO entity_edges (source, relation, target, weight, evidence, last_seen)
                SELECT source, '\(EntityGraph.coReported)', target, sum(weight), sum(stories), max(latest) FROM (
                    SELECT a.entity_id AS source, b.entity_id AS target,
                           max(\(EntityGraph.recencySQL(ageDays: age))) AS weight,
                           count(*) AS stories, max(a.published_at) AS latest
                    FROM entity_mentions a JOIN entity_mentions b ON b.article_id = a.article_id AND b.entity_id > a.entity_id
                    GROUP BY a.entity_id, b.entity_id, a.publisher)
                GROUP BY source, target HAVING sum(stories) >= 2;
                """, [.real(now.timeIntervalSince1970)])
            try eventRows(
                """
                INSERT INTO entity_edges (source, relation, target, weight, evidence, last_seen)
                SELECT target, relation, source, weight, evidence, last_seen
                FROM (SELECT * FROM entity_edges WHERE source < target);
                """)

            if withCentrality { try storeGlobalCentrality() }
            let entityCount = try eventRows("SELECT count(*) FROM entities;").first?[0].flatMap(Int.init) ?? 0
            let edgeCount = try eventRows("SELECT count(*) FROM entity_edges;").first?[0].flatMap(Int.init) ?? 0
            return EntityGraphReport(entities: entityCount, edges: edgeCount)
        }
    }

    /// PageRank over the stored adjacency list, written to every entity (zero for one with no relationship). Runs
    /// inside the graph refresh's transaction.
    private func storeGlobalCentrality() throws {
        var adjacency: EntityGraph.Adjacency = [:]
        for row in try eventRows("SELECT source, target, weight FROM entity_edges;") {
            guard let source = row[0], let target = row[1], let weight = row[2].flatMap(Double.init) else { continue }
            adjacency[source, default: []].append((target, weight))
        }
        try eventRows("UPDATE entities SET centrality = 0;")
        for (id, rank) in EntityGraph.pageRank(adjacency) {
            try eventRows("UPDATE entities SET centrality = ? WHERE id = ?;", [.real(rank), .text(id)])
        }
    }

    // MARK: - Reading

    private static let entityColumns =
        "e.id, e.canonical_name, e.entity_type, e.story_count, e.first_seen, e.last_seen, e.centrality"

    private static func entityRecord(_ row: [String?], from offset: Int = 0) -> EntityRecord? {
        guard row.count >= offset + 7, let id = row[offset], let name = row[offset + 1],
            let type = row[offset + 2].flatMap(EntityType.init(rawValue:)),
            let stories = row[offset + 3].flatMap(Int.init), let first = row[offset + 4].flatMap(Double.init),
            let last = row[offset + 5].flatMap(Double.init), let centrality = row[offset + 6].flatMap(Double.init)
        else { return nil }
        return EntityRecord(
            id: id, canonicalName: name, entityType: type, storyCount: stories,
            firstSeen: Date(timeIntervalSince1970: first), lastSeen: Date(timeIntervalSince1970: last),
            centrality: centrality)
    }

    private static func jsonArray(_ ids: [String]) -> String {
        (try? JSONEncoder().encode(ids)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
    }

    func fetchEntity(id: String) throws -> EntityRecord? {
        try eventRows("SELECT \(Self.entityColumns) FROM entities e WHERE e.id = ?;", [.text(id)])
            .first.flatMap { Self.entityRecord($0) }
    }

    /// The entities these stories name, the ones most of them name first, for the chips of a story or an event. An
    /// entity only one story names has no coverage to show, so it is left out.
    func entities(forArticles ids: [String], limit: Int) throws -> [EntityRecord] {
        guard !ids.isEmpty else { return [] }
        return try eventRows(
            """
            SELECT \(Self.entityColumns) FROM entity_mentions m JOIN entities e ON e.id = m.entity_id
            WHERE m.article_id IN (SELECT value FROM json_each(?1)) AND e.story_count >= 2
            GROUP BY e.id ORDER BY count(*) DESC, sum(m.score) DESC, e.story_count DESC, e.id LIMIT ?2;
            """, [.text(Self.jsonArray(ids)), .integer(limit)]
        ).compactMap { Self.entityRecord($0) }
    }

    /// The most reported entities of a type, or of all types.
    func topEntities(type: EntityType? = nil, limit: Int = 30) throws -> [EntityRecord] {
        try eventRows(
            """
            SELECT \(Self.entityColumns) FROM entities e WHERE (?1 IS NULL OR e.entity_type = ?1)
            ORDER BY e.story_count DESC, e.id LIMIT ?2;
            """, [type.map { .text($0.rawValue) } ?? .null, .integer(limit)]
        ).compactMap { Self.entityRecord($0) }
    }

    /// The statements of a dossier's non-graph path and of its neighbourhood walk. Named so a test can check that each
    /// is answered by an index, which is what keeps a dossier inside its 15 ms budget on a 5,000-story library.
    static let entityCoverageSQL = """
        SELECT CAST((published_at - ?2) / 86400 AS INTEGER) AS day, count(*) FROM entity_mentions
        WHERE entity_id = ?1 AND published_at >= ?2 GROUP BY day;
        """
    static let entityPublishersSQL = """
        SELECT publisher, count(*) AS stories FROM entity_mentions WHERE entity_id = ?1 AND published_at >= ?2
        GROUP BY publisher ORDER BY stories DESC, publisher LIMIT 8;
        """
    static let entityStoriesSQL = """
        SELECT a.id, a.title, a.source, m.published_at FROM entity_mentions m JOIN articles a ON a.id = m.article_id
        WHERE m.entity_id = ?1 ORDER BY m.published_at DESC, m.article_id DESC LIMIT 6;
        """
    static let entityNeighboursSQL = """
        SELECT target, weight, evidence FROM entity_edges WHERE source = ?1 AND relation = ?2
        ORDER BY weight DESC, target LIMIT ?3;
        """

    /// The dossier of one entity as of `now`. The coverage, publishers and stories are read from the mentions with
    /// index lookups only (the part #716 budgets at 15 ms); the related entities come from the stored adjacency list,
    /// ranked by a Personalized PageRank walk over the entity's own neighbourhood, never the whole graph.
    func fetchEntityDossier(id: String, now: Date = Date()) throws -> EntityDossier? {
        guard let entity = try fetchEntity(id: id) else { return nil }
        let first = Self.windowStart(now: now)
        let window = EventValue.real(first.timeIntervalSince1970)
        let entityID = EventValue.text(id)

        var perDay: [Int: Int] = [:]
        for row in try eventRows(Self.entityCoverageSQL, [entityID, window]) {
            if let day = row[0].flatMap(Int.init), let count = row[1].flatMap(Int.init) { perDay[day] = count }
        }
        let coverage = (0..<Self.dossierDays).map { day in
            EntityCoverageDay(
                day: first.addingTimeInterval(Double(day) * 86_400), storyCount: perDay[day] ?? 0)
        }
        let inWindow = coverage.reduce(0) { $0 + $1.storyCount }

        let publishers = try eventRows(Self.entityPublishersSQL, [entityID, window]).compactMap {
            row -> EntityPublisherShare? in
            guard let name = row[0], let count = row[1].flatMap(Int.init), inWindow > 0 else { return nil }
            return EntityPublisherShare(publisher: name, storyCount: count, share: Double(count) / Double(inWindow))
        }

        let stories = try eventRows(Self.entityStoriesSQL, [entityID]).compactMap { row -> EntityStoryReference? in
            guard let id = row[0], let title = row[1], let source = row[2], let date = row[3].flatMap(Double.init)
            else { return nil }
            return EntityStoryReference(
                id: id, title: title, publisher: source, date: Date(timeIntervalSince1970: date))
        }

        return EntityDossier(
            entity: entity, coverage: coverage, publishers: publishers, recentStories: stories,
            related: try relatedEntities(to: entity))
    }

    /// First day (UTC midnight) of the 30 days that end with the day of `now`.
    static func windowStart(now: Date) -> Date {
        let today = floor(now.timeIntervalSince1970 / 86_400) * 86_400
        return Date(timeIntervalSince1970: today - Double(dossierDays - 1) * 86_400)
    }

    private static let neighbourBreadth = 40
    private static let secondOrderBreadth = 12

    /// Bounded Personalized PageRank (#716): the entity's strongest neighbours and theirs, at most
    /// 40 + 40 × 12 edges, ranked against the global centrality background maintenance stored. Only entities that
    /// share stories with this one are shown, so every relationship has the stories as its provenance.
    private func relatedEntities(to entity: EntityRecord) throws -> [RelatedEntity] {
        struct Neighbour {
            let id: String
            let weight: Double
            let evidence: Int
        }
        func neighbours(of id: String, limit: Int) throws -> [Neighbour] {
            try eventRows(Self.entityNeighboursSQL, [.text(id), .text(EntityGraph.coReported), .integer(limit)])
                .compactMap { row in
                    guard let target = row[0], let weight = row[1].flatMap(Double.init),
                        let evidence = row[2].flatMap(Int.init)
                    else { return nil }
                    return Neighbour(id: target, weight: weight, evidence: evidence)
                }
        }
        let direct = try neighbours(of: entity.id, limit: Self.neighbourBreadth)
        guard !direct.isEmpty else { return [] }
        var adjacency: EntityGraph.Adjacency = [entity.id: direct.map { ($0.id, $0.weight) }]
        for neighbour in direct {
            let onward = try neighbours(of: neighbour.id, limit: Self.secondOrderBreadth)
            // The neighbour's own strongest edges usually hold the seed again: the back-edge counts once.
            adjacency[neighbour.id] =
                [(entity.id, neighbour.weight)] + onward.filter { $0.id != entity.id }.map { ($0.id, $0.weight) }
        }
        let nodes = Array(Set(adjacency.keys).union(adjacency.values.flatMap { $0.map(\.id) }))
        let records = try eventRows(
            "SELECT \(Self.entityColumns) FROM entities e WHERE e.id IN (SELECT value FROM json_each(?1));",
            [.text(Self.jsonArray(nodes))]
        ).compactMap { Self.entityRecord($0) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let totalEntities = try eventRows("SELECT count(*) FROM entities;").first?[0].flatMap(Int.init) ?? 1
        let ranked = EntityGraph.related(
            to: entity.id, in: adjacency, centrality: byID.mapValues(\.centrality),
            floor: 1 / Double(max(totalEntities, 1)), limit: nodes.count)
        let evidence = Dictionary(uniqueKeysWithValues: direct.map { ($0.id, $0.evidence) })
        return ranked.compactMap { item -> RelatedEntity? in
            guard let shared = evidence[item.id], let related = byID[item.id] else { return nil }
            return RelatedEntity(entity: related, sharedStories: shared, score: item.score)
        }.prefix(8).map { $0 }
    }
}
