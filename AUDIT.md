# News modernization and reader repair

Validated on macOS 27.0 (26A428), Xcode 27.0 (27A266a), with the macOS 27 SDK. Deployment remains macOS 15. The checkout included two existing local commits above `origin/main`; these were preserved.

## Findings and implemented changes

| Area | Finding | Change |
| --- | --- | --- |
| Article clicks | A high-priority empty tap handler could consume card interactions. | Removed the competing gesture. |
| Reader state | Stale feed snapshots could override newly extracted text; asynchronous completions could update a different selected story. | Preserve extracted reader content, synchronize the feed view with the store, and check cancellation and article identity after awaits. |
| HTML extraction | Inline child text was appended after parent text, changing sentence order. Uppercase closing tags and optional paragraph endings were mishandled. | Preserve text-node order, handle case-insensitive closing tags and omitted paragraph endings, and bound nesting. |
| Article structure | Paragraph-only extraction missed div-only prose; ancillary publisher blocks could enter the body. | Support semantic blocks and div-only fallback while excluding hidden elements, controls, captions, timestamps and recognized related-content containers. |
| Feed parsing | Atom self links could replace article URLs; publication/update dates were concatenated; XHTML lost paragraph boundaries. | Namespace-aware parsing, alternate-link selection, separate dates, relative URL resolution and structured content handling. |
| Publisher labels | RSS image titles were concatenated with channel titles. | Read only direct channel/feed titles and update stored source labels on ingestion. |
| JSON Feed | Plain text was passed through HTML removal, deleting comparisons such as `x < y and y > z`. | Preserve `content_text`; normalize only HTML content. Bound item ingestion to 500. |
| Failure reporting | Invalid XML could appear as an empty successful feed; publisher HTTP errors became generic network failures. | Explicit parse and HTTP outcomes; Web view has a visible loading-error message and reload action. |
| Classification | Automatic ingestion could invoke generative classification across the library, and category changes were not propagated to the list. | Use deterministic taxonomy during background ingestion; keep generative article analysis on demand; publish category updates immediately. |
| Concurrency | Feed requests were unbounded; cancelled enrichment jobs released capacity before actually finishing and could overwrite replacement job state. | Six concurrent feed requests, three enrichment slots held until cleanup, and job-generation guards. |
| Images and redirects | Article images bypassed the validated client; redirect destinations lacked scheme/port checks. | Route reader/card images through the bounded HTTP client and validate redirected schemes and ports. |
| Reading design | Image-heavy cards and expanded intelligence distracted from article text. | Editorial list with grid option, serif headlines, collapsible labelled summaries, selectable body text and per-story scroll reset. System appearance is the default for new preferences. |
| Build | Deployment depended on the build machine, disagreed with bundle metadata, and differed from the Swift package. | Use macOS 15 consistently, compile with Swift 6 and the selected SDK, and retain Universal 2. |
| Icon | Builds resized an old flattened PNG and rewrote source assets. | Create and visually verify a glass newspaper icon in Icon Composer; compile its `.icon` document with `actool`. |
| Sandbox | The entitlement file omitted App Sandbox despite documentation claiming it. | Enable App Sandbox and include Apple's container migration manifest for existing data. |
| Distribution metadata | No privacy manifest was bundled. | Declare own-app defaults and container file metadata usage in `PrivacyInfo.xcprivacy`. |
| Launch workflow | `make run` launched a bare SwiftPM executable. | Launch the built app bundle through `script/build_and_run.sh` and the Codex Run action. |

## Verification

- Full deterministic regression suite: passed, including new parser, store propagation, redirect and cancellation checks.
- `./build.sh`: passed with Swift 6 and Xcode 27.
- `./build_release.sh`: passed for arm64 and x86_64; Universal 2 signature validated with Hardened Runtime and App Sandbox.
- SwiftPM build: passed.
- DMG/ZIP packaging: passed in an isolated temporary directory, with image verification and checksums; packaging now rejects non-universal or invalidly signed bundles.
- Icon Composer: opened the saved document, imported its vector layer, saved it and visually inspected the macOS 27 glass preview. `actool` produced `Assets.car` and `AppIcon.icns`.
- Live reader checks: Guardian (45 feed items, successful page extraction), Ars Technica (20 items, successful page extraction), NASA (10 items, readable feed body; separate page extraction did not succeed). These are point-in-time samples, not universal publisher coverage.
- In-app check: clicking a BBC story opened its full body with readable paragraphs, reader controls and a collapsed summary.
- Sandbox migration: all 203 pre-existing article IDs, all 3 saved-story markers and all 50 read markers were preserved. SQLite `quick_check` returned `ok`. A consistent pre-migration database backup was created before launch.
- No existing release archives were overwritten and no user data was reset.

## Limits

A valid RSS/Atom/JSON feed may provide only a teaser. Authentication, paywalls, unavailable servers and JavaScript-only pages can still prevent full-text extraction. The native reader displays supplied/extracted text and never invents missing prose. Web view remains available for publisher rendering.

Intel and macOS 15 execution were not tested on separate machines. Local ad-hoc signing is not Developer ID distribution, notarization or App Store approval. The work does not claim exhaustive validation of every macOS 27 capability or every feed/publisher format.

## Apple references

- [Icon Composer](https://developer.apple.com/icon-composer/)
- [Sandbox container migration](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container)
- [Required-reason privacy manifest entries](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
- [Privacy API categories and reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
