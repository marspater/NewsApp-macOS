## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2025-02-12 - Avoid repeated regex compilation during SwiftUI view evaluation

**Learning:** In `ArticleContentRedactor.cleanText`, `NSRegularExpression` was being instantiated inside a loop for every cleaning operation. Because `cleanText` is called directly within `ArticleCardView`'s `body` evaluation, this caused multiple expensive regex compilation operations on the `@MainActor` every time a card was rendered or state changed.

**Action:** Regular expressions used in hot paths or SwiftUI view evaluations should be compiled once and stored statically. Future Bolt runs should look for `NSRegularExpression(pattern:)` inside loops or frequently called functions and elevate them to lazy static properties.
