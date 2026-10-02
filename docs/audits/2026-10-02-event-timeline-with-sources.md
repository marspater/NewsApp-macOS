# Event timeline with sourced items — 2 October 2026

## Scope

Issue #143 implements the event timeline section for Phase F (Epic #96: Timeline, perspectives, angle and sentiment):
- Event date kept separate from publication date.
- An unknown date stays unknown (never defaulted to publication date).
- Future plans are labeled as plans.
- Every item has a verified source citation.
- Absent sections rule: sections without sufficient data are absent; no template must be filled.

---

## Implementation

1. **Domain Model Enhancement (`Sources/Models/EventOverview.swift`)**:
   - `OverviewTimelineItem`:
     - `eventDate: Date?`: Explicit occurrence date/time parsed from the event report, or `nil` if unspecified.
     - `publicationDate: Date?`: Reporting publication timestamp of the source article. Kept strictly distinct from `eventDate`.
     - `dateText: String`: Display string (e.g., "15 October 2026", "06:14 UTC", "Second Quarter 2027", "Date unspecified").
     - `summary: String`: Atomic summary of the timeline occurrence or plan.
     - `citationIDs: [String]`: Array of valid passage-anchored citation identifiers.
     - `isFuturePlan: Bool`: Flag indicating whether this entry represents a planned, scheduled, or projected future action.

2. **Deterministic Timeline Extraction & Validation (`Sources/Intelligence/OverviewTimelineExtractor.swift`)**:
   - `OverviewTimelineValidator.validateItem`:
     - **Rule 4 (Sourced)**: Enforces non-empty `citationIDs` matching existing overview citations with non-empty quotes.
     - **Rule 3 (Future Plans)**: Enforces `isFuturePlan == true` if the entry contains plan keywords ("scheduled to", "plans to", "will begin", "slated to") or if `eventDate` is in the future relative to `publicationDate`.
     - **Rules 1 & 2 (Date Separation & Unknown Dates)**: Ensures unknown dates remain `nil` without synthesizing fabricated timestamps.
   - `OverviewTimelineExtractor.extractTimeline`:
     - Parses temporal anchors from evidence passages using sentence tokenization and regex patterns.
     - Aligns with source articles to record `publicationDate` independently.
     - Sorts chronologically: past/occurred events ordered by date, followed by future plans at the end.
     - Enforces the absent section rule: returns an empty array `[]` if fewer than 2 valid items exist.

3. **Reader Presentation (`Sources/Views/EventOverviewReaderView.swift`)**:
   - In `timelineSection`:
     - Displays `dateText` in prominent accent typography.
     - Displays a distinct blue `"Plan"` capsule badge for items with `isFuturePlan == true`.
     - When `publicationDate` is available and distinct from `eventDate`, displays secondary metadata `"Reported [date]"` to maintain clear separation for the reader.
     - Renders interactive citation pills linking directly to source publication quotes.

---

## Verification

- `Tests/NewsTests.swift` (`testEventTimelineWithSourcedItems`):
  - Rule 1: Verifies event date and publication date separation.
  - Rule 2: Verifies unknown dates remain `nil` and rejects fabricated timestamps for unspecified dates.
  - Rule 3: Verifies future plan extraction and rejects future plans missing the `isFuturePlan` flag.
  - Rule 4: Verifies source citations and rejects items with empty or non-existent citation IDs.
  - Absent sections: Verifies timeline is omitted when fewer than 2 items exist.
  - Chronological ordering: Verifies past events precede future plans.
- SonarCloud compliance: zero hardcoded URLs (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), no single-case switches (`swift:S1301`).
