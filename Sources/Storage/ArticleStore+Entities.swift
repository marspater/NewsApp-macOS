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

/// Where entity chips and dossiers read from (W2 #716). Previews and harnesses pass their own, or none, so a view
/// that shows entities never needs the library.
struct EntitySource: Sendable {
    /// The index's revision when the source was made: a view that reads through it asks again when it changes.
    var revision: UInt64 = 0
    /// The entities worth a chip for these stories, the ones most of them name first.
    let entities: @Sendable ([String]) async -> [EntityRecord]
    /// The dossier of one entity by ID; nil when it is unknown or the library cannot be read.
    let dossier: @Sendable (String) async -> EntityDossier?
}

extension ArticleStore {
    /// Chips and dossiers read the entity index; empty or nil, with a log line, when the library cannot be read.
    var entitySource: EntitySource {
        EntitySource(
            revision: entityRevision,
            entities: { [self] ids in
                do { return try await database.entities(forArticles: ids, limit: 8) } catch {
                    logger.error("Failed to read entities: \(error.localizedDescription)")
                    return []
                }
            },
            dossier: { [self] id in
                do { return try await database.fetchEntityDossier(id: id) } catch {
                    logger.error("Failed to read an entity dossier: \(error.localizedDescription)")
                    return nil
                }
            })
    }
}
