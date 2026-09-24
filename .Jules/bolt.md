## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-24 - Cache legacy ID reconciliation in ReadManager to avoid repeated URL parsing

**Learning:** `ReadManager.isRead` was previously resolving canonical IDs via `ArticleIdentity.reconcileLegacyId`, which parses the URL. Since `isRead` is called frequently during `@MainActor` SwiftUI view evaluations (like in `ArticleListView` and `ArticleCardView`), this repeated expensive URL parsing operations.

**Action:** UI state managers should use `NSCache<NSString, NSString>` to cache the results of expensive, pure functions like URL canonicalization when called frequently during view rendering. Future Bolt runs should look for similar patterns where small pure functions are called repeatedly during SwiftUI invalidations and introduce caching.
