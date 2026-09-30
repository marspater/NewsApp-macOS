# PR 86 review and native macOS readiness — 30 September 2026

Reviewed PR head `734e99d` against fetched main `e627ff1` on macOS 27.0.1, arm64, Xcode 27.0 and Swift 6.4. The app compiles in Swift 6 language mode and keeps the macOS 15 deployment target. This is scoped development readiness evidence, not distribution certification.

## Review findings

- Confirmed the undated-story visibility bug. `published_at` retains the stable unknown-date sentinel; SQLite now orders those rows by their original `created_at`. The projected cursor value, archive ordering, filter-only search ordering and cursor predicates agree. FTS relevance ordering stays intact.
- Applied the same fallback to retention so marking a new undated story read does not immediately make it eligible for age-based deletion. Refresh does not replace its ingestion timestamp.
- Replaced the ten SonarCloud flagged test URL call sites with URLs derived from explicit fixture roots. These remain deterministic, non-production fixtures; test coverage is retained.
- The reported `github-advanced-security` failure originates in GitHub's managed agent session requesting an unsupported model. No such model setting exists in this repository's workflows. This external configuration failure is not repaired by the source changes. The repository's advanced CodeQL workflow remains separate.

## Completed local checks

- `./test.sh`: full suite passed, including the new regression covering 501 dated stories, tied undated ingestion times, snapshot visibility, archive and filter-only search pagination, unchanged publication labels, stable refresh order and retention. The existing injected refresh regression now proves a notified undated story remains visible and does not notify again.
- `swift build --scratch-path /tmp/news-pr86-checks/swiftpm`: passed.
- `./build.sh` and `./build_release.sh`: passed in `/tmp/news-pr86-checks/staging`, preserving the existing repository app.
- Final optimized bundle: arm64; strict deep signature verification passed; ad-hoc signing with Hardened Runtime; App Sandbox and existing network/user-selected-file entitlements retained. Info.plist and bundled privacy manifest passed `plutil -lint`; icon assets and migration resource are bundled.
- `git diff --check` and shell syntax checks for the three validation scripts passed.

## Native interaction evidence

A temporary copy of the optimized bundle was identified as `com.marspater.news.pr86check` and re-signed solely for runtime verification, keeping its sandbox container separate from the real app. The running executable was confirmed as `/private/tmp/news-pr86-checks/runtime/News.app/Contents/MacOS/News`.

Accessibility inspection confirmed the native split-view sidebar, labelled toolbar controls, article actions and menu bar. Command-2 selected Unread; Command-comma opened the native Settings scene; Command-W closed Settings and returned to the main window. Opening a BBC story displayed the reader, then completed publisher extraction with the article body visible and the loading indicator gone. No generative summary was requested.

Source review confirmed existing macOS availability gates, Reduce Transparency and Reduce Motion handling, keyboard commands, isolated storage tests and shared protected networking. These checks support native macOS development readiness for the reviewed change.

## Remaining boundaries

- Current-head CI/SonarCloud reruns are independent of local success and must be checked after publication.
- Full VoiceOver operation, appearance/accessibility-setting combinations, close/reopen lifecycle and execution on macOS 15 were not exercised in this pass.
- No installation, Developer ID signing, notarization, Intel builds or distribution package publication was performed. The ad-hoc bundle is a development verification artifact.

Logs and temporary bundles are under `/tmp/news-pr86-checks/`; they are local evidence, not shipped resources.
