# News for macOS

A native, local-first RSS, Atom and JSON Feed reader built with SwiftUI, WebKit, SQLite and Apple's on-device intelligence frameworks. No cloud AI services or telemetry.

## Reading

- An editorial list with an optional grid, system light/dark appearance, keyboard navigation and native glass controls.
- Publisher content appears in a selectable, paragraph-based reader. AI-generated summaries are labelled and collapsible.
- Full feed content is used immediately. For summary-only feeds, the app fetches the article when opened; failed extraction leaves the feed preview and an explicit reason, with an in-app Web view and external browser option. Use **More Actions → Reload Reader Content** to refresh older cached extractions without clearing the library.
- Atom namespaces, XHTML paragraphs, alternate links, relative URLs and distinct publication/update dates are supported. JSON `content_text` remains plain text.
- Local SQLite persistence preserves saved stories, read history and extracted content. OPML imports and exports subscriptions.
- Ingestion uses cheap deterministic topic classification. Generative summaries run when an article is opened and AI is enabled, with deterministic fallbacks when Foundation Models is unavailable.

A valid feed does not guarantee that the publisher exposes a full article. Paywalls, authentication, access restrictions and JavaScript-only pages can prevent reader extraction. The app does not generate replacement article text or bypass publisher restrictions.

## Requirements

- Runtime: macOS 15 or later. Newer glass and Foundation Models features use availability checks.
- Build: Xcode 27 with its macOS SDK and bundled Icon Composer, selected with `xcode-select`.
- Release: Universal 2 (`arm64` and `x86_64`), Swift 6, Hardened Runtime and App Sandbox. Building an Intel slice does not verify execution on Intel hardware.

## Build and test

```sh
./test.sh                         # Deterministic regression suite
NEWS_LIVE_READER_CHECK=1 ./test.sh # Optional public-publisher network checks
./build.sh                        # Host architecture, News.app
./build_release.sh                # Universal 2, News.app
./script/build_and_run.sh --verify
swift build --target News         # SwiftPM compiler check; not an app bundle
```

`make run` and the Codex Run action use the app-bundle launcher. `TARGET_MACOS` defaults to `15.0`; SDK selection follows the selected Xcode. Local builds use ad-hoc signing. Set `DEVELOPER_ID` for a distribution release, then use the existing packaging/notarization scripts with your signing credentials. Local validation is not App Store approval or notarization.

## Icon Composer

Open `Assets/AppIcon.icon` in Xcode's **Open Developer Tool → Icon Composer**. The editable newspaper layer and its glass appearance are stored in the document. Both build scripts compile it with Apple's `actool` into `Assets.car` and the legacy `.icns` fallback; builds do not rewrite the source artwork.

## Storage and migration

The sandbox database is located at:

```text
~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3
```

`container-migration.plist` asks macOS to migrate the previous application-support directory, cache and preferences on the first sandboxed launch. SQLite uses WAL and FTS5. Cache-clearing operations remain separate from saved stories and read history.

## Source layout

- `Sources/App`: entry point, settings, theme and update checks.
- `Sources/Views`: sidebar, list/grid, reader, WebKit and semantic design tokens.
- `Sources/Services`: feed parsers, OPML, dates and secure HTTP ingestion.
- `Sources/Storage`: SQLite, migrations and observable stores.
- `Sources/Intelligence`: extraction, deterministic taxonomy, on-device analysis and bounded enrichment queue.
- `Sources/Coordinators`: feed refresh and notifications.
- `Tests/NewsTests.swift`: parsing, security, persistence, classification and state regression checks.

See [the implementation and validation report](AUDIT.md) and [privacy policy](PRIVACY.md).
