## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-25 - Avoid repeated O(N) array scans with URL canonicalizations by using NSCache in ArticleIdentity
**Learning:** `ArticleIdentity.canonicalizeURL` was being called very frequently, parsing `URLComponents` thousands of times, even though `ReadManager` doesn't do a full O(N) scan.
**Action:** Adding an `NSCache` to `ArticleIdentity.canonicalizeURL` avoids repeated O(N) path component parsing and string manipulations. `NSCache` ensures thread safety.

## 2024-10-25 - Fix strict concurrency warnings with NSCache
**Learning:** Adding a static `NSCache` variable inside a `Sendable` struct causes a strict concurrency compilation error (`static property is not concurrency-safe because non-'Sendable' type 'NSCache<NSString, NSString>' may have shared mutable state`).
**Action:** Since `NSCache` is inherently thread-safe, it must be marked with `nonisolated(unsafe)` to satisfy the Swift 6 strict concurrency checks without resorting to `@MainActor`.
