# Attributed perspectives of participants and publishers — 2 October 2026

## Scope

Issue #144 implements the attributed perspectives section for Phase F (Epic #96: Timeline, perspectives, angle and sentiment):
- Rule 1: Only explicitly attributed positions (identified speaker/participant, verified quote/statement).
- Rule 2: Never invent an "other side" (no synthetic counter-positions or forced false balance).
- Rule 3: Reprints are not presented as independent voices (syndicated wire reprints e.g. Reuters/AP collapsed under the original source/wire).
- Rule 4: Sourced items (every perspective must link to a valid source citation).
- Absent sections rule: section omitted when no verified attributed perspective exists.

---

## Implementation

1. **Domain Model Enhancement (`Sources/Models/EventOverview.swift`)**:
   - `OverviewPerspective`:
     - `participant: String`: Explicitly identified speaker, official, organization, or publisher.
     - `position: String`: Quoted or verified stance/statement attributed to the participant.
     - `citationIDs: [String]`: Array of valid passage-anchored citation identifiers.
     - `sourcePublisher: String?`: Reporting publisher label.
     - `originalWireSource: String?`: Original wire service agency (e.g., Reuters, Associated Press, AFP) if the statement originated from a syndicated wire service.
     - `init` parameter count: 6 parameters (strictly <= 7, compliant with SonarCloud `swift:S107`).

2. **Deterministic Perspective Extraction & Validation (`Sources/Intelligence/OverviewPerspectivesExtractor.swift`)**:
   - `OverviewPerspectivesValidator.validatePerspective`:
     - **Rule 1 (Attributed Positions)**: Requires participant name count >= 2 and rejects vague anonymous generalities ("critics", "observers", "some people", "sources say", "analysts", "the other side").
     - **Rule 2 (No Invented Other Side)**: Enforces that positions are grounded in the cited source passage text; rejects synthetic counter-claims with ungrounded claims. Single-perspective events remain valid as single perspectives without artificial counter-balance.
     - **Rule 3 (Wire Reprints Collapsed)**: Identifies syndicated wire services (Reuters, AP, AFP, Bloomberg, etc.) and collapses identical/overlapping quotes across multiple republishing outlets into a single voice with combined citations.
     - **Rule 4 (Sourced)**: Enforces non-empty `citationIDs` matching existing overview citations with non-empty quotes.
   - `OverviewPerspectivesExtractor.extractPerspectives`:
     - Extracts candidate statements using regular expression attribution patterns (quote first with attribution verb, speaker first with speech verb, and "according to [Speaker]").
     - Consolidates duplicate and syndicated wire reprints under the original wire source and primary participant name.
     - Preserves all citation references across reprint instances.
     - Enforces absent section rule: returns an empty array `[]` if no valid attributed perspectives exist.

3. **Reader Presentation (`Sources/Views/EventOverviewReaderView.swift`)**:
   - In `perspectivesSection`:
     - Displays participant in bold primary typography alongside attribution badge (`"via [Wire] syndicate"` or `"via [Publisher]"`).
     - Renders verified statement / quote.
     - Renders interactive citation pills linking directly to source publication passages.
     - Fully omitted when `overview.perspectives.isEmpty` (enforcing the absent section rule).

4. **Synthesis Integration (`Sources/Intelligence/OverviewComposer.swift`)**:
   - Synthesizes `evidenceSections` including both `timeline` and `perspectives` when valid items are extracted from event passages.

---

## Verification

- `Tests/NewsTests.swift` (`testAttributedPerspectivesOfParticipantsAndPublishers`):
  - Rule 1: Verifies participant is explicitly named and rejects vague anonymous participants ("Critics say", "Observers", "Some people").
  - Rule 2: Verifies single-side events retain exactly 1 perspective without inventing an opposing side, and validator rejects synthetic ungrounded counter-positions.
  - Rule 3: Verifies syndicated reprints across multiple publishers (e.g. Coastal Herald and Metro Daily carrying the same Reuters statement) are collapsed into a single perspective citing Reuters and combining citations.
  - Rule 4: Verifies source citations and rejects perspectives with empty or invalid citation IDs.
  - Absent sections rule: Verifies purely descriptive passages yield an empty perspectives array.
- Suite tests:
  - `./test.sh --story-regressions`: Passed.
  - `./test.sh`: Passed (all unit tests green).
  - `./build.sh`: Passed (debug app binary created and signed).
  - `./build_release.sh`: Passed (Hardened Runtime verification binary signed and validated).
- SonarCloud compliance: zero hardcoded URLs (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), no single-case switches (`swift:S1301`).
