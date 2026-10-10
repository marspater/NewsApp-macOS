# Reader Accessibility & Native QA Pass — 2 October 2026

Refs #123, #93, #116. Branch: `codex/reader-accessibility`. Base: `origin/main` (`635b0b2`).

## Summary

This audit completes the accessibility and native interaction pass for the source-reader experience (`ArticleDetailView`), addressing confirmed defects across text selection/copy, keyboard focus rings, VoiceOver semantics, Increase Contrast, and Reduce Motion.

## Confirmed Defects & Resolutions

### 1. Keyboard Focus & Focus Rings
* **Defect**: The reader root view applies `.focusable().focusEffectDisabled()` so keyboard single-key shortcuts (`j`, `k`, `s`, `m`, `o`, `c`, `w`, `b`, `h`, `escape`) function without drawing an unsightly window-level focus ring. However, in SwiftUI, `.focusEffectDisabled()` propagates down the view hierarchy environment to all descendant views. Consequently, all interactive buttons inside the reader (`Dismiss citation highlight`, `DisclosureGroup`, `Retry`, `Open Web View`, `External`, `Close summary`) had their focus rings suppressed during keyboard tab navigation.
* **Resolution**:
  - Explicitly restored `.focusEffectDisabled(false)` on descendant content layers (`readerView`, `webViewContainer`, `EventOverviewReaderView`). Interactive controls now render native system focus rings when tabbed to.
  - Added `.buttonBorderShape(.capsule)` to the terminal affordance buttons (`Open Web View` and `External`) so that focus indicators conform to the capsule geometry.
  - Refactored `body` into `contentLayer`, `ArticleNavigationCommands`, and `activeArticleContentTaskID` to resolve Swift compiler type-checking bottlenecks.

### 2. Text Selection & Copy
* **Defect**:
  - Cited passages from event overviews (`highlightedPassage`) lacked `.textSelection(.enabled)`.
  - AI analysis summaries, key takeaways, and fallback AI summaries lacked `.textSelection(.enabled)`.
* **Resolution**:
  - Added `.textSelection(.enabled)` to the highlighted citation block, AI summary text, individual key point bullets, and fallback AI summary text.
  - Verified that `readerText(_ block:)` preserves text characters verbatim across rich inline runs (bold, italic, code, link URLs).
  - Verified that `Cmd+C` and other modifier combinations pass through to the system menu handler (`shouldPassThroughToSystem`), ensuring text selection copying is never intercepted by single-key reader shortcuts.

### 3. VoiceOver Semantics & Interaction
* **Defect**:
  - In `ReaderFigureView`, empty or whitespace-only alt text (`""` or `"   "`) bypassed the fallback and rendered an empty accessibility label.
  - Purely decorative icons (`quote.bubble.fill`, `sparkles`, `doc.text.magnifyingglass`, `arrow.clockwise`, `safari`, `arrow.up.right`) were exposed as separate uninformative images ("safari, image", "sparkles, image").
  - The vertical accent bar in quote blocks and the colored bullet dots in key takeaways were exposed to accessibility traversal.
  - List items (`.listItem`) were split into separate elements for the bullet/ordinal and the text, requiring extra navigation stops.
  - Loading indicators were disjointed from their status labels.
* **Resolution**:
  - Implemented `ReaderFigureView.effectiveImageAlt(for:)` which trims whitespace and falls back to `"Article image"` when alt text is missing or blank.
  - Marked all decorative SF Symbols, shapes, and background surfaces with `.accessibilityHidden(true)`.
  - Combined list item ordinal/bullet and text into single accessibility elements (`.accessibilityElement(children: .combine)`).
  - Combined loading spinners and labels into descriptive accessibility status elements (`Loading full article`, `Analyzing article with on-device AI`).

### 4. Increase Contrast
* **Defect**:
  - Card/container divider opacities remained faint (0.15) under increased contrast.
  - The vertical quote indicator bar remained at 50% opacity.
  - Capsule button borders remained at 0.08 opacity.
* **Resolution**:
  - Introduced `ArticleDetailView.dividerOpacity(for:)` scaling divider opacity from 0.15 to 0.60 under `.increased` contrast.
  - Introduced `ArticleDetailView.quoteBarOpacity(for:)` scaling quote bar opacity from 0.5 to 1.0 under `.increased` contrast.
  - Introduced `ArticleDetailView.capsuleBorderOpacity(for:)` scaling button border stroke from 0.08 to 0.35 under `.increased` contrast.

### 5. Reduce Motion
* **Defect**: `ArticleDetailView` did not read or respect the `accessibilityReduceMotion` environment setting. The `On-device summary` disclosure group and highlight dismissal animated unconditionally.
* **Resolution**:
  - Injected `@Environment(\.accessibilityReduceMotion) private var reduceMotion`.
  - Bound `summaryExpanded` through `summaryExpandedBinding`, suppressing animation when `reduceMotion` is active (`Self.readerAnimation(reduceMotion:)`).
  - Added `reduceMotion` check to citation highlight dismissal.
  - Added `.transaction { if reduceMotion { $0.animation = nil } }` to the reader hierarchy.

## Verification Evidence

1. **Dedicated Reader Accessibility Suite**:
   - Executed `script/test_reader_accessibility.sh` (`Tests/ReaderAccessibilityTests.swift`):
   - 26/26 checks passed with 0 failures:
     - Plain text and rich inline formatting copy fidelity
     - Figure alt text fallback across nil, empty, and whitespace values
     - Spoken source line label formatting
     - Increase Contrast adjustments for dividers, quote bar, and borders
     - Reduce Motion animation suppression policy
     - Single-key vs modifier-key shortcut pass-through
2. **Regression Validation**:
   - `./test.sh`: Full regression test runner passed (all unit tests, classification, clustering, evaluation).
   - `./test.sh --story-regressions`: Passed.
3. **Application Build & Signing**:
   - `./build.sh`: Arm64 compilation, asset catalog compilation, plist creation, and strict ad-hoc code signing passed.

## Scope & Code Isolation
* Modified code: `Sources/Views/ArticleDetailView.swift`.
* Created dedicated test runner: `Tests/ReaderAccessibilityTests.swift` and `script/test_reader_accessibility.sh`.
* DatabaseEngine.swift, EventCandidates.swift, EventClustering.swift, Tests/NewsTests.swift, and shared plans/changelogs were left untouched for integration.
