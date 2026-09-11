# 🗞 NewsApp for macOS

A breathtaking, lightning-fast native macOS RSS news reader built purely with Swift & SwiftUI. NewsApp delivers a cinematic, ad-free reading experience, combining the power of modern glassmorphic design and on-device artificial intelligence for a personalized daily news workflow.

## ✨ Features

- **Cinematic, Glassmorphic UI:** Immersive edge-to-edge content, transparent title bars, and a carefully curated P3 wide-gamut dark mode palette adopting macOS Liquid Glass for controls and navigation.
- **Dual Reader & WebKit Mode:** Seamlessly toggle between custom Ghost typography reader (`Casper`, `Edition`, `Alto`) and native in-app WebKit engine (`W`), with trackpad swipe navigation gestures.
- **Vim & Keyboard-First Navigation:** Fluid `J` / `K` browsing, auto-scroll centering, quick bookmarking (`S`), mark read (`M`), browser handoff (`O`), section jumps (`⌘1`–`⌘4`), and native menu bar shortcuts.
- **Local-First SQLite Persistence:** High-performance SQLite3 storage (`news_v2.sqlite`) running Write-Ahead Logging (WAL) and FTS5 full-text indexing with query operators (`source:`, `category:`, `is:read`, `is:unread`, `is:saved`).
- **Subscription Portability (OPML):** Full OPML 2.0 import and export (`⇧⌘I`, `⇧⌘E`), plus drag-and-drop subscription of OPML files and URLs directly onto the sidebar.
- **On-Device AI Intelligence:** Protocol-oriented NaturalLanguage capabilities (sentiment scoring, entity extraction, categorization, and summarization) scheduled via an actor-isolated priority queue (`EnrichmentQueue`).
- **Robust 512MB Offline Cache:** Ephemeral `URLCache` strictly segregated from durable SQLite user state, preserving bookmarks and read history.
- **Universal 2 & Hardened Runtime:** Native fat binaries (`arm64` + `x86_64`) signed with minimal App Sandbox entitlements and zero telemetry ([`PRIVACY.md`](PRIVACY.md)).

## 🚀 Getting Started

### Prerequisites

- macOS 26.4+ / macOS 27.0+ (Universal 2: Apple Silicon or Intel Mac)
- Local Command Line Tools for Xcode (Swift 6.0+ CLI)

### Running Tests & Building

```bash
# Run unit test suite (22 automated test suites)
./test.sh

# Build local debug app bundle
./build.sh

# Build Universal 2 Release bundle with Hardened Runtime
./build_release.sh

# Package compressed read-only DMG, ZIP, and SHA-256 digests
./package_dmg.sh

# Native Swift Package Manager build
swift build --target News

# Launch NewsApp
open News.app
```

## 🧩 Architecture Snapshot

- **`NewsApp.swift` -** SwiftUI application entry point with native menu bar commands, notification routing, and offline cache initialization.
- **`MainView.swift` -** Coordinator orchestrating `SidebarView`, `ArticleListView`, and `ArticleDetailView`.
- **`DesignSystem.swift` & `GlassSystem.swift` -** Semantic design tokens (`AppColor`, `AppSpacing`, `AppRadius`, `AppTypography`, `AppShadow`, `ArticleFilterQuery`) and platform Liquid Glass integration.
- **`DatabaseEngine.swift` & `ArticleStore.swift` -** SQLite3 database engine with WAL mode, FTS5 full-text index, automatic schema triggers, and domain store.
- **`ArticleIntelligence.swift` & `EnrichmentQueue.swift` -** Capability-driven NaturalLanguage pipeline and actor-isolated priority background scheduler.
- **`SecureHTTPClient.swift` & `IPAddressValidator.swift` -** Actor-isolated HTTP client with strict SSRF defense, RFC 1918 blocking, and bounded streaming responses.
- **`ArticleWebView.swift` -** AppKit/WebKit bridge providing gesture-enabled web rendering and intranet navigation protection.
- **`FeedManager.swift` -** RSS/Atom/JSON feed engine with TaskGroup concurrency and OPML synchronization.
- **`OPMLManager.swift` -** OPML 2.0 XML parser and serializer for seamless feed subscription portability.
- **`CacheManager.swift` -** 512MB disk/RAM HTTP cache subsystem decoupled from durable article storage.
- **`NewsTests.swift` -** 22 unit test suites validating security, parsing, persistence, FTS5, AI, and distribution integrity.
- **`build_release.sh` & `package_dmg.sh` -** Universal 2 compilation, Hardened Runtime signing, and compressed DMG release packaging.

## 🎨 Asset Generation

App icons are generated dynamically from base `.png` files during the build phase via macOS binary tools. This ensures crisp resolution all the way up to 1024x1024 without bloating the repository with `.icns` files.

---

**Crafted with ❤️ for macOS by marspater.**
