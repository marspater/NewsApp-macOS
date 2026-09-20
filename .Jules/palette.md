## 2024-05-24 - Accessibility labels on help buttons

**Learning:** SwiftUI views providing a tooltip via `.help(...)` do not automatically propagate an accessibility label for VoiceOver if they are icon-only buttons. The modifier `.accessibilityLabel(...)` must explicitly be added alongside `.help(...)` in macOS SwiftUI applications to ensure full accessibility support.

**Action:** When adding or reviewing buttons, check if they are icon-only and ensure they possess both `.help(...)` for mouse hover tooltips and explicit `.accessibilityLabel(...)` modifiers for VoiceOver.
