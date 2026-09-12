import Foundation
import os

/// Dedicated HTTP response and asset cache manager.
/// Configures and manages the 512MB URLCache for WebKit pages, HTTP responses,
/// and remote media assets. Strictly isolated from domain state and article persistence.
public final class CacheManager: @unchecked Sendable {
    public static let shared = CacheManager()
    private let logger = Logger(subsystem: "com.marspater.news", category: "CacheManager")
    private let fileManager = FileManager.default
    
    private var cacheDirectory: URL {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let isTest = ProcessInfo.processInfo.processName.contains("test")
        let dirName = isTest ? "com.marspater.news.testcache" : "com.marspater.news.cache"
        let appCacheDir = paths[0].appendingPathComponent(dirName)
        
        if !fileManager.fileExists(atPath: appCacheDir.path) {
            try? fileManager.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
        }
        return appCacheDir
    }
    
    /// Configures the shared URLCache with 64MB RAM and 512MB disk capacity
    /// for persistent offline WebKit rendering and asset retrieval.
    public func configureOfflineCache() {
        let memoryCapacity = 64 * 1024 * 1024 // 64 MB RAM
        let diskCapacity = 512 * 1024 * 1024 // 512 MB Disk
        let cacheURL = cacheDirectory.appendingPathComponent("web_cache")
        let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: cacheURL)
        URLCache.shared = cache
        logger.info("Configured 512MB persistent URLCache at \(cacheURL.path)")
    }

    /// Calculates total byte size of cached network responses and web assets on disk.
    public func calculateTotalCacheSize() -> Int64 {
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

    /// Clears the HTTP network cache and removes temporary web data.
    /// Does NOT touch user articles, bookmarks, or reading history in the database.
    public func clearWebCache() {
        URLCache.shared.removeAllCachedResponses()
        logger.info("Cleared HTTP network cache.")
    }

    /// Legacy convenience alias for clearWebCache.
    public func clearAllCache() {
        clearWebCache()
    }

    /// Clears all AI enrichment analysis data (summaries, key points, entities).
    /// Articles and subscriptions remain completely intact.
    func clearAIAnalysis(database: DatabaseEngine = DatabaseEngine.shared) async throws {
        try await database.clearArticleEnrichment()
        logger.info("Cleared AI analysis cache via CacheManager.")
    }

    /// Clears persisted article body text from local storage.
    /// Preserves subscriptions, saved stories, and read history markers.
    func clearArticleCache(database: DatabaseEngine = DatabaseEngine.shared) async throws {
        try await database.clearArticleCache()
        logger.info("Cleared article cache via CacheManager.")
    }

    /// Completely purges web cache and all cached database articles, state, and enrichment.
    /// Strictly preserves subscribed feed URLs and user settings. Runs VACUUM on SQLite database.
    func clearEverything(database: DatabaseEngine = DatabaseEngine.shared) async throws {
        clearWebCache()
        try await database.clearAllDatabaseCache()
        logger.info("Cleared all web and database caches via CacheManager.")
    }
}
