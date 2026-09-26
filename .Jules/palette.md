
## 2024-11-20 - Ensure Tooltips Are Accessible
**Learning:** In macOS SwiftUI, VoiceOver does not automatically read `.help()` tooltips on purely informational static views or icon-only controls. They require explicit `.accessibilityLabel(...)` modifiers.
**Action:** When adding `.help()` modifiers for tooltips, ensure a matching `.accessibilityLabel(...)` modifier is also applied.
