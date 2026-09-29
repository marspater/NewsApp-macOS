## 2024-05-24 - Semantic Corner Radii

**Learning:** The application design system relies on semantic tokens for consistency. Hardcoded corner radii (like `cornerRadius: 6` or `.cornerRadius(5)`) create visual drift and ignore the design system.

**Action:** Always use semantic tokens from the `AppRadius` enum (e.g., `AppRadius.control`, `AppRadius.card`, `AppRadius.container`) instead of arbitrary hardcoded values for view corner radii to maintain design system consistency.
