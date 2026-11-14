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

import Combine
import Foundation

/// Manages bookmarked / saved articles in memory for instant reactive UI updates,
/// backed asynchronously by ArticleStore and SQLite persistence.
@MainActor
final class SavedStoriesManager: ObservableObject {

    /// The saved stories, updated at once on a local change and resynchronized from `ArticleStore` once no change is
    /// pending.
    @Published var savedArticles: [FeedArticle] = []
    /// The IDs of `savedArticles`.
    @Published var savedArticleIDs: Set<String> = []
    /// The normalized links of `savedArticles` that are document URLs; a story whose link matches one counts as saved.
    @Published var savedArticleLinks: Set<String> = []
    private var mutationTask: Task<Void, Never>?
    private var pendingMutations = 0
    private let articleStore: ArticleStore
    private var cancellables = Set<AnyCancellable>()

    /// Creates a manager over the store (`ArticleStore.shared` when nil) and follows its saved stories.
    init(articleStore: ArticleStore? = nil) {
        let store = articleStore ?? ArticleStore.shared
        self.articleStore = store
        self.savedArticles = store.savedArticles
        self.savedArticleIDs = Set(store.savedArticles.map { $0.id })
        self.savedArticleLinks = Set(store.savedArticles.map { $0.normalizedLink }.filter(DatabaseEngine.isDocumentURL))

        // Keep savedArticles in sync with ArticleStore changes
        store.$savedArticles
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                guard let self, self.pendingMutations == 0 else { return }
                self.savedArticles = updated
                self.savedArticleIDs = Set(updated.map { $0.id })
                self.savedArticleLinks = Set(updated.map { $0.normalizedLink }.filter(DatabaseEngine.isDocumentURL))
            }
            .store(in: &cancellables)
    }

    /// Saves a story in memory at once and queues the write and its Spotlight update; a story already saved is left
    /// alone.
    func save(_ article: FeedArticle) {
        guard !isSaved(article) else { return }
        savedArticles.insert(article, at: 0)
        savedArticleIDs.insert(article.id)
        if DatabaseEngine.isDocumentURL(article.normalizedLink) { savedArticleLinks.insert(article.normalizedLink) }
        persistSaved([article], isSaved: true)
    }

    /// Unsaves a story and every saved story with the same document link, in memory at once, and queues the writes.
    func remove(_ article: FeedArticle) {
        guard isSaved(article) else { return }
        // Only document URLs can alias bookmarks; homepage/malformed links stay keyed by article ID.
        // Persist against the actual saved IDs.
        let matching = savedArticles.filter {
            $0.id == article.id
                || (DatabaseEngine.isDocumentURL(article.normalizedLink) && $0.normalizedLink == article.normalizedLink)
        }
        let matchingIDs = Set(matching.map { $0.id })
        savedArticles.removeAll { matchingIDs.contains($0.id) }
        savedArticleIDs = Set(savedArticles.map { $0.id })
        savedArticleLinks = Set(savedArticles.map { $0.normalizedLink }.filter(DatabaseEngine.isDocumentURL))
        persistSaved(matching, isSaved: false)
    }

    /// Empties Saved Stories in memory at once and queues the library-wide removal, which also clears the Spotlight
    /// domain. A failed removal restores the stored list once no change is pending.
    func removeAll() {
        savedArticles.removeAll()
        savedArticleIDs.removeAll()
        savedArticleLinks.removeAll()
        let previous = mutationTask
        pendingMutations += 1
        mutationTask = Task {
            await previous?.value
            await articleStore.removeAllSavedStories()
            pendingMutations -= 1
            if pendingMutations == 0 {
                savedArticles = articleStore.savedArticles
                savedArticleIDs = Set(savedArticles.map { $0.id })
                savedArticleLinks = Set(savedArticles.map { $0.normalizedLink }.filter(DatabaseEngine.isDocumentURL))
                mutationTask = nil
            }
        }
    }

    /// Whether the story is saved by ID, or by its document link when it has one.
    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticleIDs.contains(article.id)
            || (DatabaseEngine.isDocumentURL(article.normalizedLink)
                && savedArticleLinks.contains(article.normalizedLink))
    }
    private func persistSaved(_ articles: [FeedArticle], isSaved: Bool) {
        let previous = mutationTask
        pendingMutations += 1
        mutationTask = Task {
            await previous?.value
            for article in articles {
                await articleStore.setSaved(article: article, isSaved: isSaved, awaitingSpotlight: false)
            }
            pendingMutations -= 1
            if pendingMutations == 0 {
                savedArticles = articleStore.savedArticles
                savedArticleIDs = Set(savedArticles.map { $0.id })
                savedArticleLinks = Set(savedArticles.map { $0.normalizedLink }.filter(DatabaseEngine.isDocumentURL))
                mutationTask = nil
            }
        }
    }

    /// Every queued change is in the library and its Spotlight update has run.
    func waitForPendingChanges() async {
        await mutationTask?.value
        await articleStore.spotlightTail?.value
    }

    /// Every queued change is in the library; Spotlight may still be catching up. What a quit waits for.
    func waitForStoredChanges() async { await mutationTask?.value }

}
