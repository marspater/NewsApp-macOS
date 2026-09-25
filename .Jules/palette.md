## 2024-05-18 - Missing Accessibility Labels on Article Card Badges

**Learning:** When adding `.help(...)` modifiers to provide tooltips for visual elements, VoiceOver does not automatically read them if the element is not interactive (like a Button). In SwiftUI on macOS, purely informational views like badges or icons require `.accessibilityLabel(...)` to be announced properly to screen readers.

**Action:** Whenever a `.help(...)` modifier is used on a static or informational view (like an `HStack` or `Text` acting as a badge), ensure there is also an `.accessibilityLabel(...)` modifier, or that the parent container properly combines and describes the element.
