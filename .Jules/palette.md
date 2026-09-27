
## 2025-02-18 - Missing Accessibility Label on Icon-only Help Button

**Learning:** VoiceOver does not automatically announce the `.help` tooltip text for purely icon-only controls (like `Image(systemName: "questionmark.circle")`) in SwiftUI for macOS unless they explicitly have an `.accessibilityLabel`.

**Action:** When adding icon-only controls, always include `.accessibilityLabel` in addition to `.help` to ensure full VoiceOver support.
