## 2024-10-24 - Avoid O(N) array scans with URL canonicalizations during SwiftUI view evaluation

**Learning:** In `SavedStoriesManager.swift`, the `isSaved` method was previously implemented as an O(N) scan over the `savedArticles` array. Inside the scan, it performed `article.normalizedLink == $0.normalizedLink`, which parsed the URL via `URLComponents` during every loop iteration. Because `isSaved` is called frequently during `@MainActor` SwiftUI view evaluations (like filtering articles in `ArticleListView` and rendering `ArticleCardView`), this caused thousands of expensive and unnecessary URL canonicalization strings allocations and parsing operations.

**Action:** UI state managers that provide lookup capabilities (like `isSaved` or `isRead`) should maintain internal `Set<String>` collections of identifiers to allow O(1) lookups, especially if the legacy comparison logic involved expensive operations. Future Bolt runs should prefer introducing parallel `Set` tracking for `@Published` arrays if elements are frequently checked for containment during view rendering.

## 2024-10-24 - Cache legacy ID reconciliation in ReadManager to avoid repeated SwiftUI view evaluation overhead

**Learning:** The `ReadManager` performs legacy ID reconciliation (`ArticleIdentity.reconcileLegacyId`) inside `isRead`, which involves parsing URLs with `URLComponents`. Because `isRead` is called continuously during SwiftUI re-evaluations (in loops over hundreds of articles in `ArticleListView` and `ArticleCardView`), this redundant computation blocks the main thread and impacts scrolling and typing performance. Simply deleting the reconciliation call would introduce a functional regression (breaking matching for older saved/read items).

**Action:** Introduced a lightweight internal caching mechanism (`reconciledIdCache: NSCache<NSString, NSString>`) directly inside `ReadManager`. Since the same article IDs are repeatedly checked during a session, the cache effectively turns all subsequent `isRead` checks into near O(1) operations. `NSCache` is thread-safe and memory-pressure aware, avoiding crashes if `isRead` is hit concurrently from background processing, while drastically reducing main thread string allocation and CPU overhead.

## 2024-10-24 - Prevent Task Cancellation Leak in RefreshCoordinator using Task.detached

**Learning:** CI test `testRefreshCoordinatorSingleFlightCoalescing` failed because it expected a background task to complete for remaining waiters even if the first waiter was cancelled. `RefreshCoordinator.executeRefresh` was using `Task { ... }`, which inherits the cancellation context of the caller. If the first caller cancels its execution, the entire single-flight background refresh task would incorrectly cancel, breaking the refresh for other active waiters.

**Action:** Replaced `Task { ... }` with `Task.detached { ... }` in `RefreshCoordinator.swift`. This ensures the single-flight refresh operation runs independently of the initial caller's lifecycle and will correctly fulfill the results for all other coalesced callers, even if one cancels.

## 2024-10-24 - Handle GitHub Advanced Security Copilot SWE Agent CI failures

**Learning:** CI check failures in `github-advanced-security` showing `CAPIError: 400 The requested model is not supported` are infrastructure errors in the agentic PR reviewer environment (Copilot SWE agent) and require no codebase changes. They are unrelated to the actual code modifications.

**Action:** Ignore these CI failures as they are infrastructure-related. Do not attempt to modify unrelated files to fix them.

**Action:** Re-submitting the PR to force GitHub Actions to retry the `github-advanced-security` check, as this error `CAPIError: 400 The requested model is not supported` is a known intermittent Copilot infrastructure issue.
