# News for macOS

[![CI](https://github.com/marspater/NewsApp-macOS/actions/workflows/ci.yml/badge.svg)](https://github.com/marspater/NewsApp-macOS/actions/workflows/ci.yml)
[![Security](https://github.com/marspater/NewsApp-macOS/actions/workflows/security.yml/badge.svg)](https://github.com/marspater/NewsApp-macOS/actions/workflows/security.yml)

A native, local-first RSS, Atom and JSON Feed reader built with SwiftUI, WebKit, SQLite and Apple's on-device intelligence frameworks. No cloud AI services or telemetry.

## Latest changes — 30 September 2026

- Restore article loading for older databases and keep cached stories visible during refresh.
- Protect network connections with public-address validation and numeric IP pinning; block local Web preview resources and disable publisher scripts.
- Preserve reader headings, lists, quotations and code while excluding comments, newsletters and related-story furniture. Normalize and wrap summary tags.
- Query the full persisted archive with stable pagination, preserve multi-feed article provenance, and make read/save/cache updates reliable.
- Use native toolbar, Liquid Glass search and scroll-edge effects where supported.
- Verify arm64-only, ad-hoc-signed builds locally and in CI. Notarization and Intel builds are outside the development scope.

See the [changelog](CHANGELOG.md), [current validation report](docs/audits/2026-09-30-production-readiness.md) and [privacy policy](PRIVACY.md).

## Reading

- An editorial list with an optional grid, system light/dark appearance, keyboard navigation and native glass controls.
- Publisher content appears in a selectable, paragraph-based reader. AI-generated summaries are labelled and collapsible.
- Full feed content is used immediately. For summary-only feeds, the app fetches the article when opened; failed extraction leaves the feed preview and an explicit reason, with an in-app Web view and external browser option. Use **More Actions → Reload Reader Content** to refresh older cached extractions without clearing the library.
- Atom namespaces, XHTML paragraphs, alternate links, relative URLs and distinct publication/update dates are supported. JSON `content_text` remains plain text.
- Local SQLite persistence preserves saved stories, read history and extracted content. OPML imports and exports subscriptions. An opt-in starter catalog of 49 feeds, verified on 1 October 2026, groups feeds into sets you can subscribe to; custom RSS keeps working.
- Mute publisher hosts and topic words in Settings → Muting or from a story's context menu. Lists say how many stories muting hid and can show them again; Saved Stories and History are never filtered.
- Ingestion uses cheap deterministic topic classification. Generative summaries run when the summary is expanded and AI is enabled, with deterministic fallbacks when Foundation Models is unavailable.

Feed, image, extraction, update and protected Web preview requests use an on-device, loopback-only gateway that validates DNS answers and connects to approved numeric public addresses. The Web preview disables scripts and blocks local/IP-only resources before loading. Interactive publisher pages remain available in your browser.

A valid feed does not guarantee that the publisher exposes a full article. Paywalls, authentication, access restrictions and JavaScript-only pages can prevent reader extraction. The app does not generate replacement article text or bypass publisher restrictions.

## Requirements

- Runtime: macOS 15 or later. Newer glass and Foundation Models features use availability checks.
- Build: Xcode 27 with its macOS SDK and bundled Icon Composer, selected with `xcode-select`.
- Builds: Apple silicon (`arm64`), Swift 6, Hardened Runtime and App Sandbox. Local verification uses ad-hoc signing.

## Build and test

```sh
./test.sh                         # Deterministic regression suite
NEWS_LIVE_READER_CHECK=1 ./test.sh # Optional public-publisher network checks
./build.sh                        # arm64, News.app
./build_release.sh                # Optimized arm64 verification, News.app
./script/build_and_run.sh --verify
swift build --target News         # SwiftPM compiler check; not an app bundle
```

`make run` and the Codex Run action use the app-bundle launcher. `TARGET_MACOS` defaults to `15.0`; SDK selection follows the selected Xcode. Both build scripts use ad-hoc signing for verification. Developer ID signing, notarization and Intel builds are outside the current development scope; the dormant notarization script is not part of the build workflow.

CI uses [GitHub’s `xcode-27` Apple-silicon runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) for the required SDK. Uploaded bundles are development verification artifacts, not notarized releases.

## Icon Composer

Open `Assets/AppIcon.icon` in Xcode's **Open Developer Tool → Icon Composer**. The editable newspaper layer and its glass appearance are stored in the document. Both build scripts compile it with Apple's `actool` into `Assets.car` and the legacy `.icns` fallback; builds do not rewrite the source artwork.

## Storage and migration

The sandbox database is located at:

```text
~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3
```

`container-migration.plist` asks macOS to migrate the previous application-support directory, cache and preferences on the first sandboxed launch. SQLite uses WAL and FTS5. Cache-clearing operations remain separate from saved stories and read history.

## Repository layout

Standard project, contribution, privacy and security documents stay at the root. Architecture and dated audit evidence live under `docs/`; inactive packaging/notarization helpers live under `script/distribution/`. Active build and test commands retain their root paths.

## Source layout

- `Sources/App`: entry point, settings, theme and update checks.
- `Sources/Views`: sidebar, list/grid, reader, WebKit and semantic design tokens.
- `Sources/Services`: feed parsers, OPML, dates and secure HTTP ingestion.
- `Sources/Storage`: SQLite, migrations and observable stores.
- `Sources/Intelligence`: extraction, deterministic taxonomy, on-device analysis and bounded enrichment queue.
- `Sources/Coordinators`: feed refresh and notifications.
- `Tests/NewsTests.swift`: parsing, security, persistence, classification and state regression checks.

See the [current validation report](docs/audits/2026-09-30-production-readiness.md), [earlier modernization report](docs/audits/2026-09-27-reader-modernization.md) and [security policy](SECURITY.md).
