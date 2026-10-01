# Story experience: first implementation slice — 1 October 2026

Branch: `codex/kite-practices`, working tree based on `0c849c6`. Fetched `origin/main`: `b3cb44d`, the merge of PR #86. This is an initial slice of the [story experience plan](../plans/2026-09-30-story-experience.md), not completion of its phases A–I. Changes remain uncommitted and unpublished.

## Implemented

- Incoming GUID variants of an existing canonical document URL update the existing row. SQLite's existing ID and canonical-URL indexes are reused; no new schema or destructive merge is introduced. Missing and homepage URLs cannot identify a document for this lookup.
- Hydrated articles retain the database primary key rather than recomputing UI identity from changed GUIDs. Bookmark writes also resolve incoming aliases to this key. Read/saved state, both feed associations, FTS results and JSON compatibility are covered by isolated regressions.
- URL normalization now strips known tracking keys exactly, with `utm_` as the intentional prefix. A meaningful key such as `reference` is retained instead of matching the former broad `ref` prefix.
- Reader document v3 supports figures, captions and publisher alt text. The HTML parser previously discarded entire `figure` elements. Figures now retain their position among paragraphs; div-only prose still works. Old v2 documents remain decodable.
- Reader extraction resolves relative media URLs, rejects non-HTTP(S) and credential-bearing URLs, excludes hidden/tiny figures, removes repeated media URLs and caps each document at eight inline images. Captions stay out of the plain article prose used for analysis. The lead image is not displayed twice when it is already an inline figure.
- The shared image-loading path decodes via ImageIO away from MainActor. Input dimensions are bounded to 16,384 per side and 64 million pixels; decoded display images are at most 1,600 pixels on the longest side. Existing protected HTTP loading and byte limits remain in effect. The same path serves cards and the reader.
- Inline images expose publisher alt text to accessibility. Decorative card thumbnails remain hidden from accessibility. Failed image loading shows an explicit unavailable state with its caption.

ImageIO's [thumbnail size option](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize) supplies the display-resolution limit; the input-dimension checks are additional application policy.

## Evidence

- `./test.sh --story-regressions`: passed. This new explicit focused option includes canonical ingestion, metadata and bookmark aliases, undated ordering, persistence, FTS, reader parsing, legacy structured-document migrations, reader-state propagation, retention/cache preservation and multi-publisher extraction fixtures. Default `./test.sh` still runs the full suite.
- Reader checks cover DOM ordering, captions/alt text, relative URLs, invalid/hidden/tiny/duplicate figures, media bounds, div-only articles, v2 compatibility, JSON round trips, and actual 2400×1200 → 1600×800 ImageIO decoding.
- Staged `./build.sh`: passed for the final production source, arm64, Swift 6, macOS 15 deployment, Xcode 27. Strict deep codesign verification and Info.plist lint passed. Nothing was installed over the existing app.
- SwiftPM build passed before the final small accessibility-label correction; the final correction was compiled by the subsequent staged app build.
- Live native UI: a disposable harness used the actual ArticleDetailView, in-memory SQLite, separate settings/app identity and synthetic image data. Verified image/caption placement, headings, list and quotation rendering, unavailable-image fallback and `S` save/unsave. The final AX tree contains `image A gold circle on a blue background` and its separate caption. This verifies exposed accessibility semantics, not a complete VoiceOver interaction audit.
- The positive UI image check used a URLProtocol fixture configured only in the disposable harness, not production source. An initial attempt to seed HTTP cache did not yield the image, so it was recorded only as fallback evidence. These checks do not prove live publisher downloads or native cache reuse.
- Full `./test.sh` on the final source: **failed** at the existing public-host assertion in `testSSRFValidation`. The environment resolves `google.com` to `192.0.0.88`; the destination validator correctly blocks it. This also failed before implementation. No security checks were relaxed, and the remaining full suite did not run.
- `git diff --check`: passed.

Logs and disposable builds: `/tmp/news-story-checks/`. The isolated UI harness may remain open for inspection; cleanup keypresses were blocked when desktop focus changed, and no unrelated app was closed.

## Scope still outstanding

This prevents the tested class of new GUID/URL duplicates; it does not merge historical duplicate rows, introduce feed-scoped GUID aliases, or solve semantic clustering. Simultaneous/serial identifier and URL changes need a durable alias migration in the next identity slice. Raw GUID collisions across unrelated publishers remain a separate existing identity limitation.

Image selection is currently limited to publisher metadata and figures. Responsive `srcset` selection, broader lazy-image patterns, semantic relevance scoring and a curated source catalog are not implemented. The fixed media bounds are deliberate initial limits, not an image-quality benchmark.

The larger labeled duplicate/cluster corpus, model benchmark, multi-source summaries, timelines, perspectives, incremental feed validators and tension index remain planned work. No precision/recall claim or complete project-readiness claim is made.

The user's existing icon edits were left untouched. Earlier image-cache changes are still present in the working tree and are not represented as newly completed work here. Real saved stories, read history and installed app were not changed by these checks.
