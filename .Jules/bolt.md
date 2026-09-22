## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-24 - Cache expensive canonical ID lookups in UI state managers

**Learning:** `ReadManager.isRead` (and similar UI state lookup methods) are called hundreds of times during `@MainActor` SwiftUI view evaluations. When these methods compute values derived from legacy ID normalization operations (like `ArticleIdentity.reconcileLegacyId(id)`, which parses strings using `URLComponents`), this introduces significant repeated overhead, causing UI stutter on list rendering.

**Action:** UI state managers that wrap legacy reconciliation logic should maintain an internal thread-safe cache (`NSCache<NSString, NSString>`, marked with `nonisolated(unsafe)`) for the reconciliation. Future Bolt runs should prefer using `NSCache` over repeated `URL` or `URLComponents` initialization on hot view paths.
