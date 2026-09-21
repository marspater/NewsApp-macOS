import Foundation
import Combine

/// Manages article read states in memory for instant reactive UI updates,
/// backed asynchronously by ArticleStore and SQLite persistence.
@MainActor
final class ReadManager: ObservableObject {
    static let shared = ReadManager()
    
    @Published var readArticles: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    
    nonisolated(unsafe) private let legacyIdCache = NSCache<NSString, NSString>()

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
    
    private func reconcile(_ id: String) -> String {
        if let cached = legacyIdCache.object(forKey: id as NSString) {
            return cached as String
        }
        let canonicalId = ArticleIdentity.reconcileLegacyId(id)
        legacyIdCache.setObject(canonicalId as NSString, forKey: id as NSString)
        return canonicalId
    }

    func markAsRead(_ id: String) {
        let canonicalId = reconcile(id)
        guard !readArticles.contains(canonicalId) else { return }
        readArticles.insert(canonicalId)
        Task {
            await ArticleStore.shared.markAsRead(id: canonicalId, isRead: true)
        }
    }
    
    func isRead(_ id: String) -> Bool {
        let canonicalId = reconcile(id)
        return readArticles.contains(canonicalId)
    }
    
    func toggleRead(_ id: String) {
        let canonicalId = reconcile(id)
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
