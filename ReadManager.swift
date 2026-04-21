import Foundation

class ReadManager: ObservableObject {
    static let shared = ReadManager()
    
    @Published var readArticles: Set<String> = []
    private let storageKey = "com.marspater.news.readArticlesList"
    
    init() {
        if let data = UserDefaults.standard.stringArray(forKey: storageKey) {
            readArticles = Set(data)
        }
    }
    
    func markAsRead(_ id: String) {
        guard !readArticles.contains(id) else { return }
        readArticles.insert(id)
        UserDefaults.standard.set(Array(readArticles), forKey: storageKey)
    }
    
    func isRead(_ id: String) -> Bool {
        return readArticles.contains(id)
    }
    
    func toggleRead(_ id: String) {
        if readArticles.contains(id) {
            readArticles.remove(id)
        } else {
            readArticles.insert(id)
        }
        UserDefaults.standard.set(Array(readArticles), forKey: storageKey)
    }
}
