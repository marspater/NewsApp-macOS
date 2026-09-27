## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2026-09-22 - Short-circuit empty string searches and eliminate redundant Set conversions in topic classification

**Learning:** In `NaturalLanguageTopicClassifier.classifyTopic` within `ArticleIntelligence.swift`, taxonomy keyword scoring iterated over all keywords for each category and repeatedly called `.contains(kw)` on title, description, and body strings even when those input strings were empty (e.g. empty description or body text). Additionally, `Array(Set(matched))` was allocated for every category evaluation when `score > maxScore`, causing unnecessary string hash and set allocation overhead during feed classification.

**Action:** Short-circuit string search checks (`hasTitle`, `hasDesc`, `hasBody`) prior to calling `.contains(kw)` on empty string buffers, and directly preserve deduplicated match appends without intermediate `Set` initialization.
