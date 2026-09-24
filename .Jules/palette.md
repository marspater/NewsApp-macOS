## 2024-09-24 - Accessibility labels for icon-only controls

**Learning:** Icon-only controls in macOS SwiftUI require explicit .accessibilityLabel(...) modifiers in addition to .help(...) to ensure proper VoiceOver support.

**Action:** Always add explicit .accessibilityLabel(...) modifiers to icon-only buttons or pickers, describing the action.
