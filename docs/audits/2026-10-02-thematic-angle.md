# Thematic angle from existing facts — 2 October 2026

## Scope

Issue #145 implements the thematic angle section for Phase F (Epic #96: Timeline, perspectives, angle and sentiment):
- Rule 1: No forecasts (no forward-looking speculative projections, price targets, or growth estimates).
- Rule 2: No investment advice (no buy/sell ratings, portfolio allocations, or trading advice).
- Rule 3: Every fact cited (every thematic fact and the angle summary must link to valid source citations).
- Absent sections rule: section is omitted when no coherent cluster of verified thematic facts exists (at least 2 facts required).

---

## Implementation

1. **Domain Model Enhancement (`Sources/Models/EventOverview.swift`)**:
   - `OverviewThematicAngle`:
     - `title: String`: Category title (e.g. "Financial figures", "Key figures & metrics").
     - `summary: String`: High-level non-speculative factual summary of the figures.
     - `citationIDs: [String]`: Unique citations supporting the angle.
     - `facts: [OverviewFact]`: Granular cited quantitative facts.
     - Initializer parameter count: 5 parameters (strictly <= 7, compliant with SonarCloud `swift:S107`).

2. **Deterministic Extraction & Validation (`Sources/Intelligence/OverviewThematicAngleExtractor.swift`)**:
   - `OverviewThematicAngleValidator.validateAngle`:
     - **Rule 1 (No Forecasts)**: Enforces that neither summary nor any fact contains forecast keywords ("forecast", "projected to", "predicts", "price target", "expected to surge/grow").
     - **Rule 2 (No Investment Advice)**: Enforces that neither summary nor any fact contains investment recommendations or ratings ("buy", "sell", "strong buy", "investors should", "portfolio allocation").
     - **Rule 3 (Every Fact Cited)**: Validates that every individual fact and the overall angle reference existing overview citations with non-empty quotes.
   - `OverviewThematicAngleExtractor.extractThematicAngle`:
     - Identifies quantitative and financial metrics (currencies, scale multipliers, percentages, volumes, headcount).
     - Filters out speculative forward-looking projections and advice.
     - Enforces the absent section rule: returns `nil` when fewer than 2 valid thematic facts exist.

3. **Reader Presentation (`Sources/Views/EventOverviewReaderView.swift`)**:
   - In `thematicAngleSection`:
     - Displays `angle.title` as an `h2` heading.
     - Renders `angle.summary`.
     - Renders individual quantitative facts with interactive citation pills linking to source publication quotes.
     - Omitted when `overview.thematicAngle == nil`.

4. **Overview Synthesis (`Sources/Intelligence/OverviewComposer.swift`)**:
   - Integrated `OverviewThematicAngleExtractor` into `composeOverview` to construct `evidenceSections` when quantitative facts are present.

---

## Verification

- `Tests/NewsTests.swift` (`testThematicAngleFromExistingFacts`):
  - Extraction: Identifies financial figures angle and extracts quantitative facts.
  - Rule 1: Verifies angle facts do not contain forecasts, and validator rejects candidate with forward-looking projections.
  - Rule 2: Verifies validator rejects angle containing investment advice or stock ratings.
  - Rule 3: Verifies every fact has valid citation IDs, and validator rejects uncited facts.
  - Absent sections rule: Verifies thematic angle returns `nil` when insufficient thematic facts exist.
- Suite checks:
  - `./test.sh --story-regressions`: Passed.
  - `./test.sh`: Passed (all unit tests green).
  - `./build.sh`: Passed (arm64 debug binary signed).
  - `./build_release.sh`: Passed (arm64 Hardened Runtime verification binary signed and validated).
- SonarCloud compliance: zero hardcoded URLs (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), no single-case switches (`swift:S1301`).
