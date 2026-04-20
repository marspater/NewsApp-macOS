import Foundation

class CacheManager {
    static let shared = CacheManager()
    private let fileManager = FileManager.default
    
    private var cacheDirectory: URL {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let appCacheDir = paths[0].appendingPathComponent("com.marspater.news.cache")
        
        if !fileManager.fileExists(atPath: appCacheDir.path) {
            try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
        }
        return appCacheDir
    }
    
    func save<T: Codable>(_ object: T, forKey key: String) {
        let fileURL = cacheDirectory.appendingPathComponent(key + ".json")
        do {
            let data = try JSONEncoder().encode(object)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save cache for key \(key): \(error)")
        }
    }
    
    func load<T: Codable>(forKey key: String, as type: T.Type) -> T? {
        let fileURL = cacheDirectory.appendingPathComponent(key + ".json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            print("Failed to load cache for key \(key): \(error)")
            return nil
        }
    }
}
