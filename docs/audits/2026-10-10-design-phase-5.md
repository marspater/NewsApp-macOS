# Design phase 5: reader — 10 October 2026

Issue: #355. Based on current main, with #349's existing Overview / Story / Web control retained.

## Changes

- `ThemeManager` owns the persisted reader text size. View commands and the native Reading Options popover share the focused reader's binding; sizes run from 85% to 150% in five-point steps, with Actual Size restoring 100%.
- Casper, Edition and Alto keep the existing stored enum values. The menu and popover use the short display names.
- `ReadingColumn` applies the same `AppLayout.readingMeasure` (720 pt), 1.3 width-scale cap and page insets to story and overview.
- The reading-options toolbar item is separated from Save / Share by a macOS 26+ fixed toolbar spacer. The macOS 15 path retains standard toolbar items and the same popover.
- Citation and extraction-fallback notices reuse the Notice component merged in #398. Original-page actions use standard bordered buttons. Paragraphs share the current story's accessibility linked-group ID and namespace.
- Extraction, stored content, analysis, citations and navigation continue through their existing services. Retry retains its existing reload-generation behavior. No migration or production data access.
- Existing line-spacing tokens remain: phase 5 considered `lineHeight(_:)` and does not require it.

## Evidence

Verification uses an isolated checkout and, for interaction checks, a separate app identifier and synthetic library. No installed app replacement.

| Check | Result |
| --- | --- |
| Design lint and formatting | Passed before rebase; rebased code retains the zero-deviation baseline from phase 4 |
| Full offline regressions | Passed before rebase; final rebase verification pending |
| Native UI QA, macOS 15 deployment target | Passed before rebase; final rebase verification pending |
| arm64 ad-hoc staged bundle, macOS 15 deployment target | Passed before rebase; final rebase verification pending |
| Isolated launch and reading-options interaction | Pending |
| Light / dark and narrow / wide reader | Pending |
| macOS 15 runtime | Not run; host is macOS 27.0.1 |
| Spoken VoiceOver | Parked #268; not part of this issue |
| Installation and publisher-network checks | Not run; this change concerns offline reader controls |
