## 2025-02-28 - Accessibility Label Requirement for Icon-Only Controls

**Learning:** macOS SwiftUI icon-only controls (e.g. Buttons or Menus using only `Image(systemName:)`) require explicit `.accessibilityLabel(...)` modifiers. Relying only on `.help(...)` (which sets tooltips) is insufficient for robust VoiceOver support, and omitting the label can result in VoiceOver incorrectly reading the system image name (e.g., "ellipsis, button").

**Action:** When designing new icon-only controls or polishing existing ones, always pair `.help(...)` with `.accessibilityLabel(...)` containing a descriptive, action-oriented string.