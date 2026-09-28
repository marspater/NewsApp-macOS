## $(date +%Y-%m-%d) - Semantic Radius Consistency
**Learning:** SwiftUI corner radius values should always use AppRadius semantic tokens (e.g., AppRadius.control) instead of hardcoded numbers like 5, 6, or 8, ensuring consistency across the app.
**Action:** Enforce usage of AppRadius constants over raw literals for all corner/clip shape operations.
