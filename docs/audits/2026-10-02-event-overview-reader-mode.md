# Event overview reader mode — 2 October 2026

## Scope

Issue #140 implements the event overview reader mode, completing the final remaining component of Phase E (Epic #95):
- Two clearly labeled modes: **Event overview** and **Source publication**.
- Full 7-section overview layout order:
  1. Title, update time, number of articles and publishers.
  2. Short introduction, one or two paragraphs.
  3. Fitting main image with caption and source attribution.
  4. Three to five key facts with citation links.
  5. Compact expandable source list.
  6. With evidence: chronological timeline, participant perspectives, thematic angle.
  7. Links to original publications.
- Invariants & Rules:
  - Sections without enough data are completely absent (no empty cards or placeholder templates).
  - A fact link opens the specific article and displays the stored passage quote banner with dismiss affordance.
  - Keyboard navigation, VoiceOver, light/dark mode, Increase Contrast and Reduce Motion support.

## Implementation

- **Data Models (`Sources/Models/EventOverview.swift`)**:
  - `ReaderExperienceMode`: enum with cases `.eventOverview` ("Event overview") and `.sourcePublication` ("Source publication").
  - `OverviewTimelineItem`: id, date text, summary, citation IDs, and `isFuturePlan` boolean.
  - `OverviewPerspective`: id, participant name, attributed position/stance, citation IDs.
  - `OverviewThematicAngle`: id, title, summary, citation IDs.
  - `OverviewEvidenceSections`: encapsulates timeline, perspectives, and thematic angle. Parameter counts kept <= 7 for `swift:S107`.
  - Added `evidenceSections` to `OverviewContent` and convenience forwarders (`timeline`, `perspectives`, `thematicAngle`) to `EventOverviewDocument`.
- **Database Persistence & Lookup (`Sources/Storage/DatabaseEngine.swift` & `Sources/Storage/ArticleStore.swift`)**:
  - `DatabaseEngine.recordEventOverview`: encodes `evidenceSections` into an envelope inside `facts_json` when present, preserving backward compatibility and zero database migration requirement.
  - `DatabaseEngine.fetchEventOverview(eventID:)`: seamlessly decodes envelope or legacy fact arrays.
  - `DatabaseEngine.fetchEventOverview(forArticleID:)`: resolves overview by article ID via `event_members` or `event_overview_citations`.
  - `ArticleStore.fetchEventOverview(forArticleID:)`: `@MainActor` API wrapper.
- **EventOverviewReaderView (`Sources/Views/EventOverviewReaderView.swift`)**:
  - Implements all 7 sections in order.
  - Section omission rules:
    - Lead image absent if nil or URL is empty.
    - Intro absent if summary is empty.
    - Key facts absent if facts array is empty.
    - Compact source list absent if member articles array is empty.
    - Evidence sections absent if timeline is empty, perspectives are empty, and thematic angle is nil.
    - Original publications absent if member articles array is empty.
  - Accessibility & Adaptations:
    - `@Environment(\.accessibilityReduceMotion)`: suppresses layout animations.
    - `@Environment(\.colorSchemeContrast)`: applies high-contrast borders and badge fills.
    - Native VoiceOver headings, combined elements, and accessibility labels.
- **ArticleDetailView Integration (`Sources/Views/ArticleDetailView.swift`)**:
  - Principal toolbar features segmented picker between "Event overview" and "Source publication" when an overview is available.
  - Reader/Web toggle remains available under "Source publication".
  - Fact link interaction: tapping a citation switches experience mode to `.sourcePublication`, sets the active article to the cited member article, and displays a prominent highlighted stored passage banner above the text.
  - Keyboard shortcuts: `w` toggles between Event overview and Source publication when an overview exists.
- **Build Scripts & Test Suites (`build.sh`, `build_release.sh`, `test.sh`)**:
  - Included `Sources/Views/EventOverviewReaderView.swift`.

## Verification

- Full test suite (`./test.sh`) passed: 100% green tests.
- Story regression test suite (`./test.sh --story-regressions`) passed.
- Standard application build (`./build.sh`) and hardened runtime verification build (`./build_release.sh`) passed with valid ad-hoc code signature and entitlements.
- Unit tests in `Tests/NewsTests.swift` (`testEventOverviewReaderMode`) verify:
  - Document model forwarding for timeline, perspectives, and thematic angle.
  - Persistence roundtrip and retrieval via `DatabaseEngine.fetchEventOverview(forArticleID:)`.
  - Absent sections rule (omitted when empty or nil).
  - Fact citation linking to exact stored quote and target article.
  - Reader experience modes labeled "Event overview" and "Source publication".
- SonarCloud rules satisfied: zero hardcoded `https://` literals (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), zero single-case switches (`swift:S1301`).

## Limits

- On-device AI generation and clustering are covered by prior Phase E issues (#136, #137, #141, #142).
