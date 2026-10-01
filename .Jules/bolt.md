## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-25 - Statically compile NSRegularExpression for HTML image extraction

**Learning:** Compiling `NSRegularExpression` is computationally expensive. In `FeedXMLParser.swift`, the `extractImageFromHTML` method was repeatedly compiling a regular expression for image extraction up to twice per parsed article. When a feed has many items, this caused hundreds of unnecessary regex compilation cycles during background feed refresh.

**Action:** Future Bolt runs should statically compile and store `NSRegularExpression` instances using `static let` (or statically initialized arrays for multiple patterns) when they are used inside loops or frequently called methods like XML element parsers or UI render passes, instead of instantiating them on demand.
