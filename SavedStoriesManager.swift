import Foundation

/// Persistent storage for saved stories.
/// Saved stories are stored separately from the article cache
/// and are NOT cleared when cache is cleared from Settings.
class SavedStoriesManager: ObservableObject {
    static let shared = SavedStoriesManager()

    @Published var savedArticles: [FeedArticle] = []

    private let storageKey = "com.marspater.news.savedStories"

    init() {
        load()
    }

    func save(_ article: FeedArticle) {
        // Don't duplicate
        guard !savedArticles.contains(where: { $0.link == article.link }) else { return }
        savedArticles.insert(article, at: 0)
        persist()
    }

    func remove(_ article: FeedArticle) {
        savedArticles.removeAll { $0.link == article.link }
        persist()
    }

    func isSaved(_ article: FeedArticle) -> Bool {
        savedArticles.contains { $0.link == article.link }
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(savedArticles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        if let articles = try? decoder.decode([FeedArticle].self, from: data) {
            self.savedArticles = articles
        }
    }
}
