import Foundation
import os

final class CacheManager: @unchecked Sendable {
    static let shared = CacheManager()
    private let logger = Logger(subsystem: "com.marspater.news", category: "CacheManager")
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
            logger.error("Failed to save cache for key \(key): \(error.localizedDescription)")
        }
    }
    
    func load<T: Codable>(forKey key: String, as type: T.Type) -> T? {
        let fileURL = cacheDirectory.appendingPathComponent(key + ".json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("Failed to load cache for key \(key): \(error.localizedDescription)")
            return nil
        }
    }

    func configureOfflineCache() {
        let memoryCapacity = 64 * 1024 * 1024 // 64 MB RAM
        let diskCapacity = 512 * 1024 * 1024 // 512 MB Disk
        let cacheURL = cacheDirectory.appendingPathComponent("web_cache")
        let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: cacheURL)
        URLCache.shared = cache
    }

    func calculateTotalCacheSize() -> Int64 {
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let size = resourceValues.fileSize {
                    totalSize += Int64(size)
                }
            }
        }
        return totalSize
    }

    func clearAllCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        URLCache.shared.removeAllCachedResponses()
    }
}
