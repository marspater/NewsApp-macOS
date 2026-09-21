## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-11-20 - Avoid redundant URL canonicalization in ReadManager during view evaluation

**Learning:** `ReadManager.isRead(_:)` is called frequently during SwiftUI view rendering (e.g. in `ArticleListView` and `ArticleCardView`). It previously called `ArticleIdentity.reconcileLegacyId`, which parses URLs via `URLComponents` synchronously. This repeated work is expensive, particularly because SwiftUI evaluates `isRead` for every visible row, causing continuous unnecessary allocations and parsing operations.

**Action:** When a method inside a UI state manager (like `ReadManager.isRead`) performs an expensive deterministic operation (like URL canonicalization or parsing) that gets called frequently by `@MainActor` SwiftUI views, use an `NSCache<NSString, NSString>` to memoize the results. `NSCache` guarantees thread-safety (so it can be marked `nonisolated(unsafe)`) while efficiently mitigating O(N) evaluation costs without causing shared mutable state concurrency warnings in Swift 6.
