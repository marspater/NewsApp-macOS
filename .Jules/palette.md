## 2024-05-17 - Missing Accessibility Label on Icon-only Settings Controls

**Learning:** In Settings lists and general macOS SwiftUI views for this project, icon-only buttons (like the `trash` delete button) sometimes only use `.help(...)` but lack an explicit `.accessibilityLabel(...)`. VoiceOver requires the `accessibilityLabel` property.

**Action:** When inspecting or adding icon-only UI controls, always verify and include both `.help(...)` and `.accessibilityLabel(...)` to provide proper interaction feedback for all users.
