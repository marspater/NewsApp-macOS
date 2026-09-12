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
    private var cancellables = Set<AnyCancellable>()

    init(articleStore: ArticleStore? = nil) {
        let store = articleStore ?? ArticleStore.shared
        self.savedArticles = store.savedArticles
        self.savedArticleIDs = Set(store.savedArticles.map { $0.id })
        self.savedArticleLinks = Set(store.savedArticles.map { $0.normalizedLink })
        
        // Keep savedArticles in sync with ArticleStore changes
        store.$savedArticles
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                self?.savedArticles = updated
                self?.savedArticleIDs = Set(updated.map { $0.id })
                self?.savedArticleLinks = Set(updated.map { $0.normalizedLink })
            }
            .store(in: &cancellables)
    }

    func save(_ article: FeedArticle) {
        guard !isSaved(article) else { return }
        savedArticles.insert(article, at: 0)
        savedArticleIDs.insert(article.id)
        savedArticleLinks.insert(article.normalizedLink)
        Task {
            _ = await ArticleStore.shared.toggleSave(article: article)
        }
    }

    func remove(_ article: FeedArticle) {
        savedArticles.removeAll { $0.id == article.id || $0.link == article.link }
        savedArticleIDs.remove(article.id)
        savedArticleLinks.remove(article.normalizedLink)
        Task {
            _ = await ArticleStore.shared.toggleSave(article: article)
        }
    }

    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticleIDs.contains(article.id) || savedArticleLinks.contains(article.normalizedLink)
    }
}
