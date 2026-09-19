## 2023-11-20 - Explicit Accessibility Labels for Popover Icons

**Learning:** In macOS SwiftUI, icon-only controls (like `questionmark.circle` for help or syntax popovers) require explicit `.accessibilityLabel(...)` modifiers in addition to `.help(...)` to ensure proper VoiceOver support and semantic context, as `.help` alone is not reliably read as the accessibility label by VoiceOver on all platform configurations.

**Action:** Future Palette runs should explicitly add `.accessibilityLabel` directly to any icon-only `Button` or interactive element if it triggers a popover, sheet, or action, ensuring the label clearly describes the action or context (e.g., "Search Syntax & Filter Operators") rather than the visual icon itself.
