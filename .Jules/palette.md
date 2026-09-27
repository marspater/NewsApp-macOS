## 2024-05-17 - Avoid Hardcoded Corner Radii

**Learning:** Various SwiftUI views might use hardcoded corner radius values (e.g. `.cornerRadius(5)` or `.cornerRadius(8)`) which violates the design system consistency.

**Action:** When adding or modifying corner radiuses, always use the semantic tokens provided in `AppRadius` (e.g. `AppRadius.control`, `AppRadius.card`, `AppRadius.container`) to maintain visual alignment across the macOS application.
