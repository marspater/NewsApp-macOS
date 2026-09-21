## 2025-02-12 - Accessibility labels on icon-only buttons

**Learning:** In macOS SwiftUI for this project, icon-only controls require explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure proper VoiceOver support.

**Action:** When auditing or implementing icon-only buttons (like a trash icon for unsubscription), ensure that an `.accessibilityLabel()` is present.
