## 2024-09-16 - Explicit accessibilityLabel for Icon-Only Controls

**Learning:** In macOS SwiftUI, icon-only controls require explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure proper VoiceOver support. Relying solely on `.help(...)` is insufficient for accessibility purposes.

**Action:** When adding or reviewing icon-only controls, always verify that both `.help(...)` and an explicit `.accessibilityLabel(...)` are present and descriptive.
