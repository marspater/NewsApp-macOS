## 2025-01-20 - Missing Accessibility Labels on Icon-Only Controls

**Learning:** macOS `.help(...)` modifiers provide tooltips but do not replace `.accessibilityLabel(...)` for VoiceOver support on icon-only controls. Missing these labels leads to unannounced buttons for assistive technologies.

**Action:** When adding or reviewing icon-only buttons, always ensure that `.accessibilityLabel(...)` is present to accurately describe the button's action.
