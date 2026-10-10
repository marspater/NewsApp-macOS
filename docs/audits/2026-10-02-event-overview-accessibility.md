# Event Overview Accessibility & Native Interaction Audit

**Date:** 2026-10-02
**Context:** Issue #155 (Event-overview accessibility and native QA pass), stacked on PR #226 (Issue #123)
**Scope:** `EventOverviewReaderView.swift`, `ArticleDetailView.swift` (text scale plumbing), `Tests/EventOverviewAccessibilityTests.swift`, `script/test_event_overview_accessibility.sh`

---

## 1. Objectives & Scope

Validate and harden the accessibility, keyboard navigation, VoiceOver structure, citation routing, narrow window layout, text scaling, contrast, and sparse section handling in `EventOverviewReaderView`:

1. **Keyboard Focus & Traversal**: Ensure interactive controls (citation pills, disclosure toggles, source reading buttons, external link buttons) render clean system focus rings and affordances.
2. **VoiceOver Structure & Headings**: Ensure standard heading hierarchy (H1 for overview title, H2 for editorial sections), provide contextual spoken labels for all actions, and hide decorative SF Symbols and punctuation.
3. **Citation Routing**: Guarantee fact and evidence citation pills resolve and open the exact corresponding source article across article IDs, canonical URLs, titles, and publisher names.
4. **Narrow Windows & Layout Responsiveness**: Prevent horizontal overflow, clipping, or premature truncation on 380px windows by standardizing page insets and relaxing single-line constraints to 2 lines.
5. **Text Scaling & Dynamic Type**: Scale fonts, line spacings, and column widths with `textScale`, accepting in-app reader text scaling while preserving design bounds.
6. **Increase Contrast & Reduce Motion**: Provide dynamic contrast scaling for borders, dividers, pill outlines, and text levels; honor system `reduceMotion` in disclosure animations.
7. **Sparse Section Pruning**: Ensure sections without valid content (blank summaries, empty fact strings, missing images, or empty evidence items) remain cleanly absent.

---

## 2. Confirmed Defects & Implementations

### Defect 1: Citation Pill Focus Ring & Contrast Outlines
- **Root Cause**: Citation pill buttons had `.buttonStyle(.plain)` over a `Capsule()` background without `.buttonBorderShape(.capsule)` or a high-contrast stroke, producing unshaped focus outlines and low visibility under Increase Contrast.
- **Fix**: Added `.buttonBorderShape(.capsule)`, contrast-aware border strokes (`Capsule().stroke(AppColor.accent.opacity(pillBorderOpacity), lineWidth: 1)`), and explicit accessibility hints.

### Defect 2: Ambiguous "Read" and Unlabeled Web Buttons in Sources Section
- **Root Cause**: The expandable Sources list had generic `"Read"` buttons and icon-only `arrow.up.right.square` buttons without accessibility labels. VoiceOver rotor navigation by Form Controls announced repetitive, uncontextualized buttons.
- **Fix**: Added `.accessibilityLabel("Read \(article.title) from \(article.source) in Source publication mode")` and `.accessibilityLabel("Open original publication: \(article.title) on \(article.source)")`, while hiding the icon with `.accessibilityHidden(true)`.

### Defect 3: Decorative VoiceOver Noise and Missing Section Headings
- **Root Cause**: SF Symbols (`circle.fill`, `newspaper`, `text.magnifyingglass`, `arrow.up.forward.square`, `link`) and punctuation separators (`·`, `—`) were exposed to VoiceOver, interrupting speech flow. Section 5 (`Sources`) lacked an H2 heading role.
- **Fix**:
  - Marked all bullet circles, icons, and separators with `.accessibilityHidden(true)`.
  - Added `.accessibilityHeading(.h2)` and `.accessibilityAddTraits(.isHeader)` to all sections, including the Sources disclosure label (`Text("Sources (\(count))")`).
  - Combined the header metadata line into a clean spoken element: `"Updated \(time), \(articleCount), \(publisherCount)"`.
  - Combined lead image caption and credit into a single accessible description.

### Defect 4: Brittle Citation Source Matching
- **Root Cause**: `citationPill` matched solely on `memberArticles.first { $0.id == citation.articleID }`. If citation IDs were stored under URLs or different formats, or had slight title/source variations, resolution returned `nil` and failed to activate the correct source article.
- **Fix**: Implemented `matchingArticle(for:in:)` multi-stage resolution checking `articleID`, `sourceURL`, `sourceTitle`, and case-insensitive `sourceName`.

### Defect 5: Narrow Window Clipping and Fixed Padding
- **Root Cause**: `EventOverviewReaderView` hardcoded `padding(.horizontal, 48)` (96px total inset) and constrained source/publication titles to `lineLimit(1)`, causing severe truncation in 380px-wide split windows.
- **Fix**:
  - Replaced `48` inset with `AppLayout.pageInset` (24.0).
  - Expanded source and publication title lines to `lineLimit(2)`.
  - Replaced hardcoded maxWidth with `readingColumnMaxWidth(for: textScale)` (`720.0 * min(textScale, 1.3)`).

### Defect 6: Text Selection Fidelity
- **Root Cause**: Titles, summaries, facts, and perspectives in `EventOverviewReaderView` lacked `.textSelection(.enabled)`.
- **Fix**: Added `.textSelection(.enabled)` across title, introduction paragraphs, key facts, timeline summaries, perspectives, and thematic angle text.

### Defect 7: Sparse Section Ingestion
- **Root Cause**: Checks only verified array counts; items containing only whitespace or blank fields were rendered as empty bullet points or empty cards.
- **Fix**: Added `filterValidFacts`, `filterValidTimeline`, `filterValidPerspectives`, `hasThematicAngleContent`, and `hasCoverageSentimentContent` to filter out whitespace-only items. `hasEvidenceContent` ensures the entire evidence container is omitted when all sub-sections are empty.

---

## 3. Verification & Test Evidence

All checks executed locally on Apple Silicon (arm64, macOS 15.0):

```sh
# Dedicated Event Overview Accessibility Suite (49/49 passed)
./script/test_event_overview_accessibility.sh

# Dedicated Source Reader Accessibility Suite (26/26 passed)
./script/test_reader_accessibility.sh

# Full Unit Test Suite & Commit Hooks (passed)
./test.sh

# Story Regressions (passed)
./test.sh --story-regressions

# Native Arm64 App Build & Ad-Hoc Signing (passed)
./build.sh
```

---

## 4. Scope & Invariants Preserved
- No modifications to user-owned files: `DatabaseEngine.swift`, `EventCandidates.swift`, `EventClustering.swift`, and `Tests/NewsTests.swift` remain untouched.
- Shared plans (`docs/plans/`) and `CHANGELOG.md` left untouched for user integration.
