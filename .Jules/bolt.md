## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## YYYY-MM-DD - Avoid O(N) URL canonicalization string allocations during SwiftUI view evaluation in ReadManager

**Learning:** `ReadManager.isRead` is called frequently during `@MainActor` SwiftUI view evaluations. It invoked `ArticleIdentity.reconcileLegacyId` unconditionally, which parses URLs via `URLComponents`. This allocates thousands of strings for identical legacy IDs.

**Action:** UI state managers that wrap expensive string operations should utilize `NSCache` for high-frequency operations, leveraging `NSCache`'s thread safety and automatic memory bounds instead of standard `Dictionary`.
