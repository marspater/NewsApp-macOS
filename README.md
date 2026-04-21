# 🗞 NewsApp for macOS

A breathtaking, lightning-fast native macOS RSS news reader built purely with Swift & SwiftUI. NewsApp delivers a cinematic, ad-free reading experience, combining the power of modern glassmorphic design and on-device artificial intelligence for a personalized daily news workflow.

## ✨ Features

- **Cinematic, Glassmorphic UI:** Immersive edge-to-edge content, transparent title bars, and a carefully curated P3 wide-gamut dark mode palette that makes imagery pop.
- **On-Device AI Summaries:** Understand the core of any article instantly with AI-generated insights and summaries seamlessly integrated into the feed.
- **Seamless RSS Integration:** Subscribe to any `.xml` or RSS feed right from the app using the `+` button in the sidebar. Comes pre-loaded with curated topics like Tech, Science, and World News.
- **Robust Caching Pipeline:** Fast parsing and persistent local caching utilizing a custom `CacheManager` to minimize network and system load.
- **Saved Stories & History:** Bookmark your favorite stories to a dedicated offline library to read later.
- **Zero Dependencies:** Custom-built via `swiftc` without Xcode overhead, using a highly optimized unified bash script. 

## 🚀 Getting Started

### Prerequisites

- Apple Silicon (M-Series) Mac
- macOS 26.4+ target execution (Configured via `build.sh`)
- Local Command Line Tools for Xcode (Swift CLI, etc.)

### Building & Running

You don't need Xcode to compile NewsApp. Just use the built-in compiler script:

```bash
# Clone the repository
git clone git@github.com:marspater/NewsApp-macOS.git
cd NewsApp-macOS

# Build the App
./build.sh
```

Once the script completes, the compiled and signed `News.app` will be automatically generated in the root directory. You can launch it by double-clicking it or using the `open` command:

```bash
open News.app
```

## 🧩 Architecture Snapshot

- **`NewsApp.swift` -** The SwiftUI application wrapper customized with `WindowAccessor` to strip standard window borders for a native glassmorphic feel.
- **`MainView.swift` -** The core UI loop handling the `NavigationSplitView`, detailed article presentation, and typography.
- **`FeedManager.swift` -** The engine for XML/RSS parsing, asynchronous state management, and section categorization.
- **`AIManager.swift` -** Handles local prompt generation and response parsing to extract smart insights for articles.
- **`CacheManager.swift` -** An intelligent on-disk caching layer for offline availability.
- **`build.sh` -** A one-click compiler wrapping `sips`, `iconutil`, and `swiftc` to construct a fully functioning `.app` bundle from scratch.

## 🎨 Asset Generation

App icons are generated dynamically from base `.png` files during the build phase via macOS binary tools. This ensures crisp resolution all the way up to 1024x1024 without bloating the repository with `.icns` files.

---

**Crafted with ❤️ for macOS by marspater.**
