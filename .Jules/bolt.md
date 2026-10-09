## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-26 - Statically compile NSRegularExpression for HTML parsing

**Learning:** Compiling `NSRegularExpression` dynamically inside hot loops such as `parseTagContent` and `decodeHTMLEntities` causes significant CPU overhead during feed processing.

**Action:** Future Bolt runs should avoid dynamic `NSRegularExpression` instantiations in content extraction pipelines. Always use statically compiled `NSRegularExpression` via `static let` for methods that execute per-tag or per-attribute.

## 2024-10-25 - Statically compile NSRegularExpression for HTML image extraction

**Learning:** Compiling `NSRegularExpression` is computationally expensive. In `FeedXMLParser.swift`, the `extractImageFromHTML` method was repeatedly compiling a regular expression for image extraction up to twice per parsed article. When a feed has many items, this caused hundreds of unnecessary regex compilation cycles during background feed refresh.

**Action:** Future Bolt runs should statically compile and store `NSRegularExpression` instances using `static let` (or statically initialized arrays for multiple patterns) when they are used inside loops or frequently called methods like XML element parsers or UI render passes, instead of instantiating them on demand.

## 2024-10-27 - Statically compile NSRegularExpression arrays for multiple extraction patterns

**Learning:** Compiling `NSRegularExpression` is computationally expensive. In `ContentExtractionPipeline.swift`, `extractLeadImage` was dynamically compiling multiple regex patterns for Open Graph image tags inside a loop for every parsed article, causing unnecessary CPU overhead.

**Action:** Future Bolt runs should statically compile and store arrays of `NSRegularExpression` instances using `static let` (e.g., `.compactMap { try? NSRegularExpression(...) }`) when multiple patterns are evaluated per article, avoiding repeated compilation inside loops or frequent method calls.

## 2024-10-27 - Statically compile NSRegularExpression patterns alongside their metadata

**Learning:** In `OverviewPerspectivesExtractor.swift`, the `extractAttributedQuotes` method dynamically compiled three `NSRegularExpression` patterns inside a function that is called frequently during article analysis. This repeated compilation of complex regular expressions adds unnecessary CPU overhead.

**Action:** Future Bolt runs should statically compile and store `NSRegularExpression` instances along with any related configuration metadata (like capture group indices or minimum lengths) in a `static let` array of a small private struct, rather than compiling them dynamically within hot paths. Use `try?` with a failable initializer instead of `try!`, and avoid tuples with more than two members; Codacy's SwiftLint rules reject both.
