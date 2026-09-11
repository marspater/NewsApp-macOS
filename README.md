# 🗞 NewsApp for macOS

A breathtaking, lightning-fast native macOS RSS news reader built purely with Swift & SwiftUI. NewsApp delivers a cinematic, ad-free reading experience, combining the power of modern glassmorphic design and on-device artificial intelligence for a personalized daily news workflow.

## ✨ Features

- **Cinematic, Glassmorphic UI:** Immersive edge-to-edge content, transparent title bars, and a carefully curated P3 wide-gamut dark mode palette that makes imagery pop.
- **Dual Reader & WebKit Mode:** Seamlessly toggle between custom Ghost typography reader and native in-app WebKit engine (`W`), with trackpad swipe navigation gestures.
- **Vim & Keyboard-First Navigation:** Fluid `J` / `K` browsing, auto-scroll centering, quick bookmarking (`S`), mark read (`M`), browser handoff (`O`), and menu bar shortcuts.
- **Subscription Portability (OPML):** Full OPML 2.0 import and export (`⇧⌘I`, `⇧⌘E`) compatible with NetNewsWire, Reeder, Feedly, and Feedbin.
- **On-Device AI Summaries:** Understand the core of any article instantly with AI-generated insights and summaries seamlessly integrated into the feed.
- **Robust 512MB Offline Cache:** Automatic `URLCache` policy, persistent JSON feeds, and isolated cache management that preserves reading history.
- **Zero Dependencies & Self-Contained:** Custom-built via `swiftc` without Xcode overhead, with an automated test suite (`./test.sh`).

## 🚀 Getting Started

### Prerequisites

- Apple Silicon (M-Series) Mac
- macOS 26.4+ / macOS 27.0+ (Automatic host detection via `build.sh`)
- Local Command Line Tools for Xcode (Swift 6.0+ CLI)

### Running Tests & Building

```bash
# Run unit test suite
./test.sh

# Build & codesign the app bundle
./build.sh

# Launch NewsApp
open News.app
```

## 🧩 Architecture Snapshot

- **`NewsApp.swift` -** The SwiftUI application wrapper with custom menu bar shortcuts, notification routing, and offline cache initialization.
- **`MainView.swift` -** The core UI loop handling `NavigationSplitView`, dual reader/WebKit views, keyboard navigation, and theme typography.
- **`ArticleWebView.swift` -** AppKit/WebKit bridge providing gesture-enabled web rendering.
- **`FeedManager.swift` -** High-concurrency RSS/Atom/JSON feed engine with SSRF validation, TaskGroup parallelism, and OPML synchronization.
- **`OPMLManager.swift` -** OPML 2.0 XML parser and serializer for seamless feed subscription portability.
- **`CacheManager.swift` -** 512MB disk/RAM caching subsystem with safe cache size calculation and cache clearing.
- **`AIManager.swift` -** On-device NaturalLanguage sentiment scoring and entity extraction.
- **`NewsTests.swift` -** Unit test suite covering security, date normalization, XML/JSON parsing, keyboard logic, and OPML.
- **`build.sh` & `test.sh` -** Fast CLI toolchain leveraging `swiftc` and macOS build utilities.

## 🎨 Asset Generation

App icons are generated dynamically from base `.png` files during the build phase via macOS binary tools. This ensures crisp resolution all the way up to 1024x1024 without bloating the repository with `.icns` files.

---

**Crafted with ❤️ for macOS by marspater.**
