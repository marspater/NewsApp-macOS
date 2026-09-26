## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-24 - Explicit SQLite transactions for batch operations

**Learning:** Batch operations executing SQLite statements inside a loop (like marking articles as read or saved) that do not use explicit transactions suffer from implicit per-row transaction flushes, causing significant disk I/O overhead.

**Action:** When implementing batch updates involving multiple rows, always explicitly wrap the loop with `try beginTransaction()` and `try commitTransaction()` (with a corresponding `try rollbackTransaction()` on error) to consolidate disk syncs and optimize performance.
