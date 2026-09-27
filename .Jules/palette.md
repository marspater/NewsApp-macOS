## 2024-11-20 - Add accessibility labels to icon-only controls

**Learning:** In macOS SwiftUI, icon-only controls (like the trash button in a feed list) require explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure proper VoiceOver support, as `.help` only provides tooltips and doesn't inherently satisfy VoiceOver requirements for icon buttons without text.

**Action:** When adding or updating icon-only buttons in macOS SwiftUI, always check for and add an `.accessibilityLabel(...)` if one is missing.
