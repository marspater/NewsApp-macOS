
## 2025-05-18 - Standardize Corner Radius Modifiers

**Learning:** When applying semantic corner radii to UI elements in SwiftUI, avoid using the deprecated `.cornerRadius()` modifier, which does not conform properly to the design system's standardized rounding patterns.

**Action:** Future Palette runs should always use `.clipShape(RoundedRectangle(cornerRadius: AppRadius.*))` or `.background(in: RoundedRectangle(cornerRadius: AppRadius.*))` for rounded elements to maintain consistent design semantics and platform consistency.

## 2025-05-18 - Standardize Hardcoded Corner Radii

**Learning:** Do not use hardcoded literal values for corner radius (e.g., `cornerRadius: 10` or `cornerRadius: 8`). These literal values cause visual inconsistencies when the design system tokens are updated.

**Action:** Always use the appropriate semantic token from `AppRadius` (e.g., `AppRadius.control`, `AppRadius.card`, `AppRadius.container`) when defining `RoundedRectangle` corner radii.

## 2025-05-18 - Tooltips on Toolbar Controls

**Learning:** In macOS toolbars, interactive controls that use `Label` (which visually collapse to icon-only) provide their text to VoiceOver, but do not automatically generate hover tooltips for sighted users.

**Action:** Always attach explicit `.help(...)` modifiers to icon-only toolbar controls (like `Button` or `ShareLink`) to ensure consistent interaction feedback.

## 2025-05-18 - Accessibility Labels for Buttons with Keyboard Shortcuts in Visual Text

**Learning:** In macOS SwiftUI, when a button's visual text includes a keyboard shortcut (e.g., `Text("Open Web View (W)")`), VoiceOver will read the shortcut suffix literally (e.g., "Open Web View W"), creating a noisy experience.

**Action:** Always provide an explicit `.accessibilityLabel` (e.g., `"Open Web View"`) for such buttons to override the default read-out and ensure VoiceOver reads a clean action name without the keyboard shortcut suffix.
