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

/// Reads the entities of stored stories into the entity index and keeps the co-reporting graph current (W2 #716).
///
/// It reuses the extractor and the tag rules of the reader's summary (`NaturalLanguageEntityExtractor`,
/// `EntityResult.scoredTags`), so a name counts for a story exactly when the reader would tag it. Everything runs in
/// background passes with Apple's NaturalLanguage on this Mac: nothing here is on the feed path, nothing leaves the
/// device, and a dossier only reads what a pass wrote.
actor EntityIndexer {
    static let shared = EntityIndexer()

    /// What one pass did.
    struct Report: Sendable, Equatable {
        let indexedStories: Int
        /// Nil when the pass changed nothing and was not asked to refresh the graph.
        let graph: DatabaseEngine.EntityGraphReport?
    }

    private let extractor = NaturalLanguageEntityExtractor()

    /// Indexes the waiting stories, newest first, in batches that each commit alone, then rebuilds the aggregates once
    /// when the index changed or `refreshGraph` asks for it (the scheduled maintenance pass, which also moves the
    /// recency weights). Stops between batches when cancelled, in Low Power Mode or under thermal pressure; the
    /// backlog stays for the next pass. Clearing derived data mid-pass ends it, and the next pass starts over.
    @discardableResult
    func run(
        in database: DatabaseEngine, refreshGraph: Bool = false,
        allowsEnergy: @Sendable () -> Bool = { IntelligencePolicy.allowsEnergy() }
    ) async throws -> Report {
        let generation = await database.analysisGeneration
        var indexed = 0
        while allowsEnergy() {
            try Task.checkCancellation()
            let batch = try await database.entityIndexCandidates(limit: DatabaseEngine.entityIndexBatch)
            if batch.isEmpty { break }
            var results: [(candidate: EntityIndexCandidate, entities: [IndexedEntity])] = []
            for candidate in batch {
                try Task.checkCancellation()
                results.append((candidate, await entities(of: candidate)))
            }
            guard try await database.saveEntityIndex(results, expectedGeneration: generation) else {
                return Report(indexedStories: indexed, graph: nil)
            }
            indexed += batch.count
        }
        try Task.checkCancellation()
        guard indexed > 0 || refreshGraph else { return Report(indexedStories: 0, graph: nil) }
        let graph = try await database.refreshEntityGraph(expectedGeneration: generation)
        return Report(indexedStories: indexed, graph: graph)
    }

    /// The entities a story is about: its reader tags, most mentioned first, without the publisher's own name (every
    /// Reuters story names Reuters) and at most `EntityGraph.maximumEntitiesPerStory`.
    func entities(of candidate: EntityIndexCandidate) async -> [IndexedEntity] {
        let source = [candidate.title, candidate.description, candidate.text].filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let found = await extractor.extractEntities(from: source)
        let publisher = EntityGraph.slug(name: candidate.publisher, type: .organization)
        return EntityResult.scoredTags(
            from: found, title: candidate.title, description: candidate.description, text: candidate.text
        )
        .filter { EntityGraph.slug(name: $0.entity.name, type: .organization) != publisher }
        .prefix(EntityGraph.maximumEntitiesPerStory)
        .map { IndexedEntity(name: $0.entity.name, type: $0.entity.type, score: $0.score) }
    }
}
