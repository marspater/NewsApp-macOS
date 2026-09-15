## 2026-09-15 - Add accessibilityLabel to Icon-Only Controls

**Learning:** In macOS SwiftUI, icon-only controls must have explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure full VoiceOver support for visually impaired users. Relying solely on `.help` is insufficient.

**Action:** Before creating icon-only controls (e.g., buttons containing only a system image), ensure an `.accessibilityLabel` is present. If one is missing, explicitly add it to describe the action, not the icon itself.
