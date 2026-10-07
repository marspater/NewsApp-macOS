import Foundation
import Combine

/// Manages bookmarked / saved articles in memory for instant reactive UI updates,
/// backed asynchronously by ArticleStore and SQLite persistence.
@MainActor
final class SavedStoriesManager: ObservableObject {
    static let shared = SavedStoriesManager()

    @Published var savedArticles: [FeedArticle] = []
    @Published var savedArticleIDs: Set<String> = []
    @Published var savedArticleLinks: Set<String> = []
    private var mutationTask: Task<Void, Never>?
    private var pendingMutations = 0
    private let articleStore: ArticleStore
    private var cancellables = Set<AnyCancellable>()

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

    func save(_ article: FeedArticle) {
        guard !isSaved(article) else { return }
        savedArticles.insert(article, at: 0)
        savedArticleIDs.insert(article.id)
        if DatabaseEngine.isDocumentURL(article.normalizedLink) { savedArticleLinks.insert(article.normalizedLink) }
        persistSaved([article], isSaved: true)
    }

    func remove(_ article: FeedArticle) {
        guard isSaved(article) else { return }
        // Only document URLs can alias bookmarks; homepage/malformed links stay keyed by article ID.
        // Persist against the actual saved IDs.
        let matching = savedArticles.filter {
            $0.id == article.id || (DatabaseEngine.isDocumentURL(article.normalizedLink) && $0.normalizedLink == article.normalizedLink)
        }
        let matchingIDs = Set(matching.map { $0.id })
        savedArticles.removeAll { matchingIDs.contains($0.id) }
        savedArticleIDs = Set(savedArticles.map { $0.id })
        savedArticleLinks = Set(savedArticles.map { $0.normalizedLink }.filter(DatabaseEngine.isDocumentURL))
        persistSaved(matching, isSaved: false)
    }

    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticleIDs.contains(article.id) || (DatabaseEngine.isDocumentURL(article.normalizedLink) && savedArticleLinks.contains(article.normalizedLink))
    }
    private func persistSaved(_ articles: [FeedArticle], isSaved: Bool) {
        let previous = mutationTask
        pendingMutations += 1
        mutationTask = Task {
            await previous?.value
            for article in articles {
                await articleStore.setSaved(article: article, isSaved: isSaved)
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

    func waitForPendingChanges() async { await mutationTask?.value }

}
