
## 2025-05-18 - Standardize Corner Radius Modifiers

**Learning:** When applying semantic corner radii to UI elements in SwiftUI, avoid using the deprecated `.cornerRadius()` modifier, which does not conform properly to the design system's standardized rounding patterns.

**Action:** Future Palette runs should always use `.clipShape(RoundedRectangle(cornerRadius: AppRadius.*))` or `.background(in: RoundedRectangle(cornerRadius: AppRadius.*))` for rounded elements to maintain consistent design semantics and platform consistency.

## 2025-05-18 - Standardize Hardcoded Corner Radii

**Learning:** Do not use hardcoded literal values for corner radius (e.g., `cornerRadius: 10` or `cornerRadius: 8`). These literal values cause visual inconsistencies when the design system tokens are updated.

**Action:** Always use the appropriate semantic token from `AppRadius` (e.g., `AppRadius.control`, `AppRadius.card`, `AppRadius.container`) when defining `RoundedRectangle` corner radii.
