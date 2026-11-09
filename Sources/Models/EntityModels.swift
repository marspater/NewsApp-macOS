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

/// A person, organization or place the library's stories name (W2 #716). Every figure derives from the stored
/// mentions, so a clear of derived data or a retention prune leaves nothing stale behind.
struct EntityRecord: Identifiable, Hashable, Codable, Sendable {
    /// "person:vladimir-putin": the type, then the name with diacritics and punctuation folded away.
    let id: String
    let canonicalName: String
    let entityType: EntityType
    /// Stories that name the entity, not mentions: a story counts once however often it repeats the name.
    let storyCount: Int
    let firstSeen: Date
    let lastSeen: Date
    /// Global PageRank over the co-reporting graph, prepared by background maintenance; 0 until the first pass.
    let centrality: Double
}

/// One UTC day of the 30-day timeline.
struct EntityCoverageDay: Hashable, Codable, Sendable {
    let day: Date
    let storyCount: Int
}

struct EntityPublisherShare: Hashable, Codable, Sendable {
    let publisher: String
    let storyCount: Int
    /// Of the stories in the window, 0 ... 1.
    let share: Double
}

struct EntityStoryReference: Identifiable, Hashable, Codable, Sendable {
    /// The article's id.
    let id: String
    let title: String
    let publisher: String
    let date: Date
}

/// An entity reported together with the dossier's entity, with the stories that show it.
struct RelatedEntity: Identifiable, Hashable, Codable, Sendable {
    let entity: EntityRecord
    /// Stories that name both entities: the relationship's provenance.
    let sharedStories: Int
    let score: Double
    var id: String { entity.id }
}

struct EntityDossier: Identifiable, Hashable, Codable, Sendable {
    let entity: EntityRecord
    /// Thirty days ending with the reference day, every day present, oldest first.
    let coverage: [EntityCoverageDay]
    let publishers: [EntityPublisherShare]
    let recentStories: [EntityStoryReference]
    let related: [RelatedEntity]
    var id: String { entity.id }

    var storiesInWindow: Int { coverage.reduce(0) { $0 + $1.storyCount } }
}
