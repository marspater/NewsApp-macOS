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
import os

extension ArticleStore {
    /// Replaces the saved-stories Spotlight domain with exactly the stories the open library holds (#812).
    /// Run at launch, which is also where a restored library first opens, so entries of the previous library go.
    func rebuildSpotlightIndex() async {
        await serialSpotlight { indexer in
            // Read when it runs, so a story unsaved while this waited is not re-added; the whole list, not the 500-story
            // UI snapshot. If the read fails the old index stays, rather than a partial one.
            let saved: [FeedArticle]
            do {
                saved = try await self.database.fetchArticles(isSaved: true, limit: nil)
            } catch {
                self.logger.error("Spotlight rebuild skipped: \(error.localizedDescription)")
                return
            }
            await indexer.removeAllSavedArticles()
            for article in saved { await indexer.indexSavedArticle(article) }
        }
    }

    /// Runs Spotlight updates one at a time in call order, so a rebuild and a save or unsave cannot interleave (#812).
    func serialSpotlight(_ operation: @escaping @MainActor (any SpotlightIndexing) async -> Void) async {
        let previous = spotlightTail
        let indexer = spotlightIndexer
        let task = Task { @MainActor in
            await previous?.value
            await operation(indexer)
        }
        spotlightTail = task
        await task.value
    }
}
