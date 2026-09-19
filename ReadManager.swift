import Foundation
import Combine

/// Manages article read states in memory for instant reactive UI updates,
/// backed asynchronously by ArticleStore and SQLite persistence.
@MainActor
final class ReadManager: ObservableObject {
    static let shared = ReadManager()
    
    @Published var readArticles: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    
    nonisolated(unsafe) private let legacyIdCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 5000
        return cache
    }()

    init(articleStore: ArticleStore? = nil) {
        let store = articleStore ?? ArticleStore.shared
        self.readArticles = store.readArticleIDs
        
        // Keep readArticles in sync with ArticleStore changes
        store.$readArticleIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                self?.readArticles = updated
            }
            .store(in: &cancellables)
    }
    
    private func canonicalId(for id: String) -> String {
        let nsId = id as NSString
        if let cached = legacyIdCache.object(forKey: nsId) {
            return cached as String
        }
        let canonical = ArticleIdentity.reconcileLegacyId(id)
        legacyIdCache.setObject(canonical as NSString, forKey: nsId)
        return canonical
    }

    func markAsRead(_ id: String) {
        let canonicalId = canonicalId(for: id)
        guard !readArticles.contains(canonicalId) else { return }
        readArticles.insert(canonicalId)
        Task {
            await ArticleStore.shared.markAsRead(id: canonicalId, isRead: true)
        }
    }
    
    func isRead(_ id: String) -> Bool {
        let canonicalId = canonicalId(for: id)
        return readArticles.contains(canonicalId)
    }
    
    func toggleRead(_ id: String) {
        let canonicalId = canonicalId(for: id)
        if readArticles.contains(canonicalId) {
            readArticles.remove(canonicalId)
            Task {
                await ArticleStore.shared.markAsRead(id: canonicalId, isRead: false)
            }
        } else {
            readArticles.insert(canonicalId)
            Task {
                await ArticleStore.shared.markAsRead(id: canonicalId, isRead: true)
            }
        }
    }
}
