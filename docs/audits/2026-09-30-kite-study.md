# Kite practices translated to native News — 30 September 2026

Reference: [`kagisearch/kite-public` at `08d15108f82fb8728832f55fc8c3799a2836bfd6`](https://github.com/kagisearch/kite-public/tree/08d15108f82fb8728832f55fc8c3799a2836bfd6). News base: `0c849c6`, including the still-open PR #86 fixes. This study reads the public source; it does not execute Kite or certify its production services.

## Conclusion

The transferable value is in product rules and state semantics, not a TypeScript-to-Swift rewrite. Keep News's SwiftUI/AppKit interface, actor-isolated SQLite, protected URLSession/WebKit and on-device intelligence. Several Kite practices are already present here. One concrete improvement is implemented: image requests can reuse fresh native HTTP-cache responses instead of forcing a download whenever a thumbnail reappears.

Kite presents precomputed story clusters from its API/data feed. The examined public repository exposes presentation, client state and [proxy endpoints](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/server/proxy.ts); it does not contain the upstream feed-to-cluster generation pipeline. Translating its source panels does not by itself reproduce multi-source clustering, factual synthesis or ranking.

## Transfer map

| Kite evidence | Native translation | News decision |
| --- | --- | --- |
| [`dataService.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/services/dataService.ts) shares an in-flight reload and returns unsubscribe closures. | Actor-owned shared Task and explicit subscription teardown. | Already covered by RefreshCoordinator, FeedManager and existing cancellation/stress tests. No second coordinator. |
| [`imagePreloader.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/utils/imagePreloader.ts) reuses cached downloads and in-flight promises. | Native URLCache freshness/revalidation through the shared protected client; SwiftUI tasks own visible image work. | Implemented HTTP cache reuse. No custom data-URL cache, bulk preloader or new dependency. Concurrent request coalescing is not promised by this change. |
| [`storiesService.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/services/storiesService.ts) deliberately avoids bulk category image preloading. | Keep expensive work demand-driven. | Already use lazy grids and view-owned image tasks; publisher extraction and summaries remain on demand. |
| [`storyOrdering.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/utils/storyOrdering.ts), its tests and [`contentFilter.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/utils/contentFilter.ts) select eligible stories before applying a count. | Put eligibility predicates in SQLite before LIMIT and use matching keyset cursors. | Already true for read/saved/section filters and archive search. Preserve this if adding muted topics or sources. Filtering a 500-row snapshot afterwards would be incorrect. |
| [`keyboardNavigation.svelte.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/stores/keyboardNavigation.svelte.ts) bounds selection to the current collection. | Stable article IDs, native commands and navigation context captured before read-state mutation. | Existing collection-relative navigation already bounds indexes. Treat stale focus across query replacement as an area for dedicated UI verification rather than inventing a second navigation store. |
| [`StorySummary.svelte`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/components/story/StorySummary.svelte), [`StorySources.svelte`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/components/story/StorySources.svelte), [`citationAggregator.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/utils/citationAggregator.ts) expose evidence and deduplicate linked citations. | Keep publisher body, source link and generated summary distinct. Only attach claim-level citations when the generation process actually provides evidence. | News already labels extractive/generated summaries and links the original. Future related coverage should show actual stored publisher articles, not fabricated citations or inferred source counts. |
| [`StoryCorrections.svelte`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/components/story/StoryCorrections.svelte) highlights corrections applied after a recorded read time. | Version publisher content and analysis; distinguish publisher updates from verified corrections. | Worth a future feature. News currently lacks trustworthy correction provenance, so an update must not be labelled a fact-check correction. |
| [`dexie.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/db/dexie.ts) uses stable story IDs and indexed read timestamps. | Existing ArticleIdentity, article_state, SQLite indexes and transactional migrations. | Already present. Retain URL/GUID/fingerprint identity appropriate to RSS rather than replacing it with Kite's cluster UUIDs. |
| [`contentFilter.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/utils/contentFilter.ts) distinguishes topic text from source hostnames and uses whole-word matching. | Separate user-controlled source muting and topic muting, with deterministic matching and explicit counts. | Useful optional product feature; do not silently hide articles or import subjective preset classifications. SQL filtering must precede pagination. |
| [`categories.ts`](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/src/lib/constants/categories.ts) caps the default category view; the README describes a daily news diet. | An optional finite briefing with a clear end and an explicitly frozen selection. | A product mode, not a mandatory RSS behavior. Retain normal refresh/archive access and preserve the user's refresh interval. |

## Implemented adaptation

`SecureHTTPClient.fetchImage` requests `.useProtocolCachePolicy`. The shared fetch method keeps `.reloadIgnoringLocalCacheData` as its default for feeds, publisher HTML and update metadata. Destination validation still occurs before URLSession; cache misses still traverse the same pinned public-IP gateway. Cached and network responses go through the existing size/status checks. Native freshness and publisher `no-store` rules determine reuse; there is no permanent custom image map.

The controlled socket regression verifies actual request counts, not just the assigned policy:

- Two fetches of a cacheable image return identical bytes with one upstream request.
- A cached HTTP image still rejects a caller that has not enabled HTTP.
- Article HTML fetching explicitly reloads the same cached URL.
- Two `no-store` image fetches make two requests.

The fixture uses an isolated memory-only URLCache and injected gateway connector; it does not access real user caches or stories. The full existing networking and persistence regressions also pass. This is sequential cache reuse evidence, not a concurrency/performance benchmark.

A contradictory architecture sentence about undated-story ordering was corrected to match PR #86's ingestion-time ordering.

## Do not transfer literally

- Kite's image cache is a Map without a capacity bound, and its preload helper launches all selected image requests at once. Use native bounded caching and existing bounded demand-driven work here.
- Its legacy-history cleanup deletes non-UUID entries and legacy localStorage keys. News must preserve and reconcile existing records through compatible migrations.
- Source labels and media classifications are data assertions, not automatically verified truth. Do not treat a source-count badge as proof of balanced coverage.
- Browser localStorage, IndexedDB, CORS proxies, cookie preference mirrors and server-rendering hydration repairs have different native equivalents or no role here.
- The upstream daily-edition, clustering and translation services cannot be recreated by porting the client components. Remote AI and account sync would also change News's documented local-first behavior.

## Recommended next product work

1. **Related coverage:** expose actual publisher articles already in the local archive. Begin with explicit links and conservative relationships; preserve each article's identity/read state. Avoid claiming two headlines describe the same event without adequate evidence.
2. **Optional finite briefing:** select a bounded set from an explicit time window and source/category mix, freeze it while reading and show a completion state. This needs ranking and time-window decisions, not a new rendering framework.
3. **User-controlled muting:** separate publisher hostnames from topic words; match before pagination, display hidden counts and provide an easy reset.
4. **Content-change provenance:** invalidate stale generated analysis when its input changes; expose publisher updates without calling them verified corrections.

These are recommendations, not implemented capabilities. A native first version should reuse the current models and services and introduce schema changes only when the selected behavior requires durable new state.

## Source/data boundary

Kite's source repository declares MIT licensing. Its [README](https://github.com/kagisearch/kite-public/blob/08d15108f82fb8728832f55fc8c3799a2836bfd6/README.md) separately identifies its generated news data as CC BY-NC. This change independently adapts a caching practice using Foundation; it imports neither Kite source code nor its feeds, media catalog, generated summaries or news data.

## Validation

- Full `./test.sh`: passed, including controlled native cache request-count checks.
- SwiftPM app build and staged `./build.sh`: passed with Swift 6 language mode, Xcode 27 and macOS 15 deployment.
- Staged bundle: arm64, strict deep signature verification and Info.plist validation passed. No live UI check was required for this networking-only adaptation.
- Verification artifacts and logs: `/tmp/news-kite-checks/`.
- No installation, changes to real user state, dependency additions or Kite execution. This branch is separate from PR #86; these changes remain uncommitted and have not been published.
