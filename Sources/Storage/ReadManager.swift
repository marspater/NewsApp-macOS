import Foundation
import Combine

/// Manages article read states in memory for instant reactive UI updates,
/// backed asynchronously by ArticleStore and SQLite persistence.
@MainActor
final class ReadManager: ObservableObject {
    static let shared = ReadManager()
    
    @Published var readArticles: Set<String> = []
    private let articleStore: ArticleStore
    private var cancellables = Set<AnyCancellable>()
    private var mutationTask: Task<Void, Never>?
    private var pendingMutations = 0
    private let reconciliationCache = NSCache<NSString, NSString>()
    
    init(articleStore: ArticleStore? = nil) {
        let store = articleStore ?? ArticleStore.shared
        self.articleStore = store
        self.readArticles = store.readArticleIDs
        
        // Keep readArticles in sync with ArticleStore changes
        store.$readArticleIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                guard let self, self.pendingMutations == 0 else { return }
                self.readArticles = updated
            }
            .store(in: &cancellables)
    }

    private func getCanonicalId(_ id: String) -> String {
        let key = id as NSString
        if let cached = reconciliationCache.object(forKey: key) {
            return cached as String
        }
        let canonicalId = ArticleIdentity.reconcileLegacyId(id)
        reconciliationCache.setObject(canonicalId as NSString, forKey: key)
        return canonicalId
    }
    
    func markAsRead(_ id: String) {
        let canonicalId = getCanonicalId(id)
        guard !readArticles.contains(canonicalId) else { return }
        readArticles.insert(canonicalId)
        persistRead(canonicalId, isRead: true)
    }
    
    func isRead(_ id: String) -> Bool {
        let canonicalId = getCanonicalId(id)
        return readArticles.contains(canonicalId)
    }
    
    func toggleRead(_ id: String) {
        let canonicalId = getCanonicalId(id)
        if readArticles.contains(canonicalId) {
            readArticles.remove(canonicalId)
            persistRead(canonicalId, isRead: false)
        } else {
            readArticles.insert(canonicalId)
            persistRead(canonicalId, isRead: true)
        }
    }
    private func persistRead(_ id: String, isRead: Bool) {
        let previous = mutationTask
        pendingMutations += 1
        mutationTask = Task {
            await previous?.value
            await articleStore.markAsRead(id: id, isRead: isRead)
            pendingMutations -= 1
            if pendingMutations == 0 {
                readArticles = articleStore.readArticleIDs
                mutationTask = nil
            }
        }
    }

    func waitForPendingChanges() async { await mutationTask?.value }

}
