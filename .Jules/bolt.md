## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-25 - Avoid O(N) array scans with URL canonicalizations in `ReadManager`

**Learning:** In `ReadManager.swift`, methods like `isRead`, `markAsRead`, and `toggleRead` were calling `ArticleIdentity.reconcileLegacyId(id)` on every invocation. Since `isRead` is heavily used during `@MainActor` SwiftUI view evaluations (e.g., in `ArticleListView` for filtering and rendering), this repeated URL parsing and canonicalization caused significant performance overhead on the main thread.

**Action:** UI state managers should cache expensive operations like legacy ID reconciliation. Using `NSCache<NSString, NSString>` provides thread-safe memoization, reducing repeated URL canonicalizations and allocations during view evaluations. Future Bolt runs should look for repeated expensive string operations during view evaluation and cache them using `NSCache` when appropriate.
