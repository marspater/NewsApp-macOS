# Cinematic macOS News App - Feasibility & Design Analysis

This document provides a comprehensive analysis of the feasibility, architecture, and design approach for a next-generation news application tailored to Apple Silicon.

## UI/UX & Design Vision

The goal is to move away from traditional "newspaper-like" reading interfaces to an immersive, cinematic layout that leverages the full capability of macOS.

**Core Design Tenets:**
- **Glassmorphism & Material:** Leveraging native macOS full-size content views with `.ultraThinMaterial` backdrops.
- **Cinematic Experience:** Edge-to-edge high-resolution photography with smooth gradients blending into the content.
- **Image Integration:** The app will seamlessly extract and render pictures from articles. These images will be integrated into the app's design language by standardizing corner radii, utilizing smooth blur-in loading animations, and drawing dominant colors from the images to gently tint the surrounding glassmorphic backgrounds for perfect visual continuity.
- **Typography-First:** Utilizing Apple's SF Pro Display and New York fonts for unparalleled readability.
- **Ad-Free Cleanliness:** Complete removal of clunky web views. Articles will be rendered natively.

### Design Concepts
- [Main Feed Interface](file:///Users/marspater/.gemini/antigravity/brain/cece7e66-0458-40e1-8c93-49d8b057bdd7/news_app_main_feed_1776454855126.png)
- [Clean Article View](file:///Users/marspater/.gemini/antigravity/brain/cece7e66-0458-40e1-8c93-49d8b057bdd7/news_app_article_view_1776454871613.png)

---

## Technical Feasibility & Architecture

### 1. App Foundation (Native Apple Silicon)
- **Framework:** **SwiftUI** combined with **AppKit** (where fine-grained window control is necessary).
- **Windows:** Borderless `NSWindow` setup with `titlebarAppearsTransparent = true` and `styleMask.contains(.fullSizeContentView)`.
- **Animations:** Fluid vector and spring animations using native SwiftUI primitives.

### 2. Lightweight Content Sourcing (RSS-First)
To keep the application highly performant and avoid any heavy downloading or scraping scripts:
- **Core Strategy:** The app will rely primarily on standard **RSS and Atom feeds**.
- **Implementation:** We will use a lightweight, native Swift XML parsing mechanism (like Apple's `XMLParser` or a lightweight library like `FeedKit`) built directly into the Mac app.
- **Content Loading:** For feeds with full content, it renders instantly. For feeds with only summaries, we can do a standard, silent HTTP fetch when the article is clicked, pulling *just* the raw article text and images using a native Swift readability parser. No heavy external backend or headless browsers will be used.

### 3. Intelligent Dual-Layer Filtering
We will separate the filtering logic into two distinct modes to maximize system performance and battery life:

**Layer 1: Algorithmic Background Triage (Push Notifications)**
- To minimize system load, background operations will **not** spin up any AI models. 
- We will rely on a lightweight, traditional algorithm (e.g., custom keyword matching logic, publisher reputation heuristics, and density of interest tags). 
- If an incoming RSS item scores sufficiently high in the background, a native Apple push notification is triggered immediately.

**Layer 2: On-Device AI Feed Curation (Active Session)**
- AI processing will only occur when the application is actively running and you are viewing the feed. 
- **Available Options:**
  - **Apple Intelligence / CoreML:** Leveraging Apple's upcoming native summarization APIs or embedding a very tiny on-device model (like Phi-3 Mini/Gemma 2B via MLX) to run efficiently on the M-Series Neural Engine.
  - **Ollama Integration:** Since Ollama is already installed on your machine, we can natively interface the app with the local `localhost:11434` API while the app is active, allowing you to use a model like Llama-3 to summarize and score active content.
- This creates zero recurring costs and complete privacy, while effectively avoiding system drag when the app is minimized.

---

## Open Questions

1. **AI Implementation Preference:** Since you have Ollama up and running, we can use that to power the active-session AI with essentially zero configuration. Alternatively, we could explore integrating native Apple Intelligence API / custom CoreML models so it's fully self-contained. Since we want an ultra-lightweight setup, would you like to build in an option to just point to your local Ollama instance for the model processing?

## Next Steps
Once you sign off on this AI detail, the architectural plan is complete! The next step will be to initialize the Swift Xcode project in `/Users/marspater/Documents/Projects/News` and begin building the core translucent window shell and the RSS parsing logic.
