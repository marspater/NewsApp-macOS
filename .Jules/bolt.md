## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2026-09-22 - Wrap batch database modifications in explicit SQLite transactions

**Learning:** In `DatabaseEngine.swift`, `batchMarkSaved` iterated over a set of article IDs and performed `sqlite3_step(stmt)` inside a loop without an explicit transaction wrapper. In SQLite, every statement executed outside an explicit transaction operates inside an implicit transaction, forcing a disk sync/write-ahead log flush after each individual statement. For bulk operations (e.g., OPML imports or migration syncs with hundreds/thousands of saved articles), this incurs severe disk I/O overhead.

**Action:** Whenever performing repeated `sqlite3_step` operations in a loop (such as batch upserts or batch status updates), wrap the loop in `try beginTransaction()` and `try commitTransaction()`, with a `catch` block that invokes `try rollbackTransaction()`. This converts N individual disk writes into a single atomic disk write transaction.
