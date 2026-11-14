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

// Angelia · Mnemosyne (storage and search) owns this file. Register: docs/ANGELIA.md.

import Foundation

/// The arithmetic of the entity co-reporting graph (W2 #716): pure functions over adjacency lists, so background
/// maintenance and the dossier share them and the tests run them on graphs small enough to check by hand.
///
/// A relationship here is typed and has provenance: `co_reported` joins two entities that stories name together, and
/// the stories themselves are the evidence. It never says why they appear together, so it never implies causality.
enum EntityGraph {
    /// Neighbours of each node with the weight of the edge, as the `entity_edges` table stores it.
    typealias Adjacency = [String: [(id: String, weight: Double)]]

    /// The relation type of an edge between two entities that stories name together.
    static let coReported = "co_reported"

    /// The most entities one story contributes to the index. A story names far more than it is about, and every
    /// extra pair would add a row to the graph.
    static let maximumEntitiesPerStory = 12

    /// "person:vladimir-putin": the type, then the name's words with case, diacritics and punctuation folded away,
    /// so "São Paulo" and "Sao Paulo" are one place.
    static func slug(name: String, type: EntityType) -> String {
        let folded = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.split { !$0.isLetter && !$0.isNumber }
        return "\(type.rawValue):" + words.joined(separator: "-")
    }

    /// Weight a story adds to a pair by its age: recent reporting counts more, and nothing drops to zero, so an old
    /// relationship stays visible but loses to a current one.
    private static let recencyBuckets: [(belowDays: Double, weight: Double)] = [
        (2, 1.0), (7, 0.7), (14, 0.4), (30, 0.2),
    ]
    private static let olderWeight = 0.1

    /// The weight a story `ageDays` old adds to a pair: 1 under two days, falling to 0.1 from thirty days on.
    static func recencyWeight(ageDays: Double) -> Double {
        recencyBuckets.first { ageDays < $0.belowDays }?.weight ?? olderWeight
    }

    /// `recencyWeight` as a SQL expression over an age in days, so the graph rebuild weighs stories in the database.
    static func recencySQL(ageDays: String) -> String {
        let cases = recencyBuckets.map { "WHEN \(ageDays) < \($0.belowDays) THEN \($0.weight)" }
        return "CASE \(cases.joined(separator: " ")) ELSE \(olderWeight) END"
    }

    /// Global PageRank of an undirected graph, summing to 1: how central an entity is to the whole library's
    /// reporting. Dangling nodes spread their rank evenly.
    static func pageRank(_ adjacency: Adjacency, damping: Double = 0.85, iterations: Int = 30) -> [String: Double] {
        let nodes = Array(Set(adjacency.keys).union(adjacency.values.flatMap { $0.map(\.id) })).sorted()
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        let count = Double(nodes.count)
        let edges: [[(to: Int, share: Double)]] = nodes.map { node in
            let neighbours = adjacency[node] ?? []
            let total = neighbours.reduce(0) { $0 + $1.weight }
            guard total > 0 else { return [] }
            return neighbours.compactMap { neighbour in
                guard let target = index[neighbour.id] else { return nil }
                return (target, neighbour.weight / total)
            }
        }
        var rank = [Double](repeating: 1 / count, count: nodes.count)
        for _ in 0..<iterations {
            var next = [Double](repeating: 0, count: nodes.count)
            var dangling = 0.0
            for (from, outgoing) in edges.enumerated() {
                if outgoing.isEmpty {
                    dangling += rank[from]
                    continue
                }
                for edge in outgoing { next[edge.to] += rank[from] * edge.share }
            }
            let base = (1 - damping) / count + damping * dangling / count
            for node in next.indices { next[node] = base + damping * next[node] }
            rank = next
        }
        return Dictionary(uniqueKeysWithValues: zip(nodes, rank))
    }

    /// Personalized PageRank from one entity over its own neighbourhood: where a walk that keeps restarting at the
    /// seed spends its time. Rank that would leave the neighbourhood goes back to the seed.
    static func personalizedPageRank(
        from seed: String, in adjacency: Adjacency, damping: Double = 0.85, iterations: Int = 30
    ) -> [String: Double] {
        var rank = [seed: 1.0]
        for _ in 0..<iterations {
            var next: [String: Double] = [:]
            var returned = 1 - damping
            for (node, mass) in rank {
                let neighbours = adjacency[node] ?? []
                let total = neighbours.reduce(0) { $0 + $1.weight }
                guard total > 0 else {
                    returned += damping * mass
                    continue
                }
                for neighbour in neighbours {
                    next[neighbour.id, default: 0] += damping * mass * neighbour.weight / total
                }
            }
            next[seed, default: 0] += returned
            rank = next
        }
        return rank
    }

    /// The entities most specifically tied to `seed`: their walk rank divided by their global rank, so a place that
    /// every story mentions does not top every dossier. Without centrality (before the first maintenance pass) the
    /// divisor is the same for all, and the order is the walk's.
    static func related(
        to seed: String, in adjacency: Adjacency, centrality: [String: Double], floor: Double, limit: Int
    ) -> [(id: String, score: Double)] {
        personalizedPageRank(from: seed, in: adjacency)
            .filter { $0.key != seed }
            .map { (id: $0.key, score: $0.value / ((centrality[$0.key] ?? 0) + floor)) }
            .sorted { ($0.score, $1.id) > ($1.score, $0.id) }
            .prefix(limit)
            .map { $0 }
    }
}
