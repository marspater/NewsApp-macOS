# SwiftSoup / FeedKit integration — 18 October 2026

Wave 2 of the authorized parallel execution plan. Branch `feat/swiftsoup-and-feedkit`, based on `origin/main` at `17f4f29` (Wave 1's documentation merge; production baseline unchanged from `aa795a4`). Gemini's matcher, clustering, candidates, storage, migration and corpus files are untouched.

## Implementation

`Package.swift` declares the requested minimum versions; `Package.resolved` locks SwiftSoup 2.14.3 and FeedKit 9.1.2. App and native QA scripts source `script/swiftpm_dependencies.sh`. SwiftPM builds a static dependency archive; the existing compiler source lists and test entry points remain, with module-search paths supporting both SwiftPM output layouts. The app target also builds directly with the existing CI/CodeQL command. Parser license notices are included in the app bundle.

SwiftSoup replaces regular-expression matching of Open Graph/Twitter metadata and JSON-LD, and selects canonical link declarations. Canonical links still require protected same-origin fetching, matching titles and substantial matching text before becoming identity evidence. The original DOM scoring remains primary. Thin or quality-rejected extraction can use repaired explicit article containers, converted back into the existing reader blocks. Hidden/auxiliary ancestors, quality validation, inline URL normalization, media limits and reader-v4 curation remain enforced. Repair is bounded to 32 candidate containers, 128 levels and 50,000 converted nodes.

The streaming XML parser retains the 64-level and 500-story limits, relative XML base resolution and cancellation checks. A 64 KiB prolog scan rejects entity declarations, including UTF-16/32 forms; declaration callbacks reject those beyond the scan. The 10 MiB input limit also applies to direct parser callers. FeedKit receives only reserialized items after the guarded parse has completed, never a publisher DTD or a URL to fetch. Foundation does not support reentrant XML parsing, so invoking FeedKit inside the streaming delegate is deliberately avoided. Items exceeding 512 KiB retain the compatibility path. The adapter adds Dublin Core title/description/date/subject handling and group-level media credits while retaining publisher names, existing content and reader media.

JSON Feed uses FeedKit's typed model after existing aliases are normalized and items are capped at 500. A custom decoder uses the shared date parser and its unknown-date sentinel. Unused optional metadata cannot invalidate a previously compatible feed. RFC822 date support includes missing weekdays/seconds and nonstandard weekday spellings; ISO8601 fractional timestamps remain supported.

### Author metadata boundary

FeedKit recognizes Dublin Core creators and Atom/JSON authors, but `FeedArticle` has no author field. This slice does not invent an author-as-publisher mapping or change Gemini-owned persistence. The plan's requested persisted creator mapping is therefore **not implemented**; an explicit domain/persistence follow-up is required if author retention is wanted. No author display or preservation claim is made.

## Validation

The final source passed the full `./test.sh`, including the dedicated `FeedKitSwiftSoupTests`, existing publisher/reader fixtures and active-work cancellation checks. New checks cover malformed paragraph repair; hidden/auxiliary ancestry; false metadata inside scripts; JSON-LD image types; RDF/Dublin Core titles and dates; nested relative XML bases; media credits; JSON Feed 1.0/1.1 and compatibility aliases; invalid dates; entity declarations before/after the prolog scan and in UTF-16; depth and 500-story caps; and oversized-item compatibility.

`swift build --force-resolved-versions --target News`, `./build.sh` and the final `./build_release.sh` passed locally. The resulting arm64 bundle passed strict deep signature verification with App Sandbox, Hardened Runtime and the existing entitlements. Link inspection confirmed no runtime SwiftSoup/FeedKit or build-directory library dependency. Bundled license notices match the source. No app installation, production launch or live publisher check was performed for this slice.

`./script/format.sh --lint-staged`, shell syntax checks for all changed compiler scripts, and `git diff --check` passed. `./script/format.sh --check` is now an actual alias for repository-wide lint, rather than an unrecognized filename. It fails on pre-existing formatting in unchanged `Sources/Coordinators/NotificationService.swift`; linting that file directly from `HEAD` reproduces the same failures. Unrelated formatting was not changed and this check is not reported as passing.

The final native harness runs passed: 160 Native UI QA checks and 46 publisher-excerpt checks, both with zero failures. Earlier native/release attempts rejected a source file edited during compilation; those attempts are failures, not passing evidence. Final validation uses frozen source.

Private local logs are `/private/tmp/news-wave2-tests-final.log`, `/private/tmp/news-wave2-spm-final.log`, `/private/tmp/news-wave2-build.log`, `/private/tmp/news-wave2-release-final.log`, `/private/tmp/news-wave2-native-ui-final.log`, `/private/tmp/news-wave2-publisher-final.log`, `/private/tmp/news-wave2-format-check.log` and `/private/tmp/news-wave2-baseline-format.log`. Local results do not establish hosted CI success.
