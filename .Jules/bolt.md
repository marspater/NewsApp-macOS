## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-11-20 - Cache expensive legacy ID reconciliation in `@MainActor` SwiftUI methods

**Learning:** In `ReadManager.swift`, the `isRead(id)` method unconditionally called `ArticleIdentity.reconcileLegacyId(id)`, which performs string trimming and potentially full URL parsing on every call. Because `isRead` is called frequently during `@MainActor` SwiftUI view evaluations (e.g., inside `ArticleCardView`), this caused O(N) redundant string allocations and URL canonicalization parsing operations across the visible list.

**Action:** UI state managers that must convert legacy identifiers to canonical identifiers inside frequently-evaluated SwiftUI view methods (like `isRead` or `toggleRead`) should use an internal `NSCache<NSString, NSString>` to cache the reconciliation result. `NSCache` provides thread-safe, auto-evicting O(1) lookups that eliminate repetitive string allocations during view rendering. Future Bolt runs should look for un-cached string/URL parsing functions called inside SwiftUI `.body` or manager methods consulted by `.body`.
