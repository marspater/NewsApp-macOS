## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-25 - Cache legacy ID reconciliation in ReadManager

**Learning:** In `ReadManager.swift`, the `isRead`, `markAsRead`, and `toggleRead` methods repeatedly called `ArticleIdentity.reconcileLegacyId(id)`. This method canonicalized URLs using `URLComponents`, which is computationally expensive and resulted in excessive string allocations. Since `isRead` is heavily invoked during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused noticeable performance degradation and unnecessary CPU usage.

**Action:** UI state managers that frequently perform expensive string manipulation or legacy ID canonicalization for lookup purposes should utilize an internal `NSCache<NSString, NSString>` to cache results. This transforms repeated O(N) URL canonicalization operations into O(1) cache lookups, improving rendering performance and reducing main thread overhead. Use `nonisolated(unsafe)` for the cache property to satisfy strict Swift 6 concurrency checks since `NSCache` is thread-safe internally.
