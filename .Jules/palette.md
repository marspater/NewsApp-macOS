## 2024-05-24 - Accessibility Labels for Icon-Only Controls

**Learning:** In macOS SwiftUI for this project, icon-only controls require explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure proper VoiceOver support.

**Action:** Always add an `.accessibilityLabel(...)` modifier to icon-only buttons or interactive elements, even if they already have a `.help(...)` modifier.
