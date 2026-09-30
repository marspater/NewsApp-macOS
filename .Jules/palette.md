## 2024-05-18 - Semantic Corner Radius

**Learning:** The application uses semantic corner radius tokens defined in `AppRadius` (e.g., `AppRadius.control` for 6pt rounded corners) to maintain visual consistency. Hardcoded values should not be used.

**Action:** When updating or adding rounded UI elements, always use the tokens from `AppRadius` (e.g., `.cornerRadius(AppRadius.control)`) instead of arbitrary hardcoded numbers.
