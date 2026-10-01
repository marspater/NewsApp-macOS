
## 2025-05-18 - Standardize Corner Radius Modifiers

**Learning:** When applying semantic corner radii to UI elements in SwiftUI, avoid using the deprecated `.cornerRadius()` modifier, which does not conform properly to the design system's standardized rounding patterns.

**Action:** Future Palette runs should always use `.clipShape(RoundedRectangle(cornerRadius: AppRadius.*))` or `.background(in: RoundedRectangle(cornerRadius: AppRadius.*))` for rounded elements to maintain consistent design semantics and platform consistency.
