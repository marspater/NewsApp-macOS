import Foundation
import Combine

/// Manages bookmarked / saved articles in memory for instant reactive UI updates,
/// backed asynchronously by ArticleStore and SQLite persistence.
@MainActor
final class SavedStoriesManager: ObservableObject {
    static let shared = SavedStoriesManager()

    @Published var savedArticles: [FeedArticle] = []
    private var cancellables = Set<AnyCancellable>()

    init(articleStore: ArticleStore? = nil) {
        let store = articleStore ?? ArticleStore.shared
        self.savedArticles = store.savedArticles
        
        // Keep savedArticles in sync with ArticleStore changes
        store.$savedArticles
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                self?.savedArticles = updated
            }
            .store(in: &cancellables)
    }

    func save(_ article: FeedArticle) {
        guard !isSaved(article) else { return }
        savedArticles.insert(article, at: 0)
        Task {
            _ = await ArticleStore.shared.toggleSave(article: article)
        }
    }

    func remove(_ article: FeedArticle) {
        savedArticles.removeAll { $0.id == article.id || $0.link == article.link }
        Task {
            _ = await ArticleStore.shared.toggleSave(article: article)
        }
    }

    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticles.contains { $0.id == article.id || $0.normalizedLink == article.normalizedLink }
    }
}
