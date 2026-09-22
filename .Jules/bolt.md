## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## Database Performance: Batch Operations & Explicit Transactions
* **Context**: When updating multiple records in SQLite using a prepared statement loop (e.g., `markReadBatch`), omitting explicit `BEGIN TRANSACTION` / `COMMIT TRANSACTION` blocks forces SQLite to create and flush an implicit transaction for every single iteration.
* **Optimization**: Wrapping loop operations in explicit transaction blocks (`beginTransaction()` / `commitTransaction()`) ensures that all updates are committed atomically in a single write operation, drastically reducing disk I/O and statement overhead.
