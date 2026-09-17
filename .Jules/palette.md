## 2024-09-17 - Explicit Accessibility Labels for Icon-Only Controls

**Learning:** In macOS SwiftUI for this project, icon-only controls require explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure proper VoiceOver support and clear semantics for accessibility features.

**Action:** When adding or modifying icon-only buttons, always ensure that `.accessibilityLabel` is provided, even if a `.help` tooltip exists. The tooltip text alone is not reliably sufficient for the primary accessibility role.
