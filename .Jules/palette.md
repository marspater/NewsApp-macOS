## 2024-11-20 - Ensure icon-only buttons have explicit Accessibility Labels

**Learning:** In macOS SwiftUI, an icon-only control with only a `.help(...)` modifier lacks VoiceOver announcement support. It requires an explicit `.accessibilityLabel(...)` modifier.

**Action:** When working on UI components that use icon-only buttons (like settings actions, toolbar items, and contextual menus), verify they have an `.accessibilityLabel(...)` modifier alongside the `.help(...)` modifier.
