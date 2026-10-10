# Design phase 4: content consistency

Date: 2026-10-10 · Issue #354

## Scope and implementation stack
- Merged predecessor #363: story/event cards, EyebrowText and TagView.
- #398 (slice 2): reader type tokens, summary tags, shared IntelligenceLabel/NoticeView, cited passage, display-only uppercase. Final integration also adopts NoticeView for the extraction fallback and AI error callout.
- #399 (slice 3): overview type roles and reading scale, citation/Plan/status tags, publisher eyebrow and removal of literal blue/white.
- Final slice (this commit): remap old font names before token values change; system label and separator colors; list font cleanup; hard zero gate, Native UI QA smoke test, CHANGELOG and this audit.

## Static source evidence
Starting baseline: ArticleDetailView 32 font literals + one uppercased; EventOverviewReaderView 42 font literals + two color matches; ArticleListView three font literals. Final expected baseline: **zero**. `script/design_lint.sh` now refuses literal font sizes, literal colors and code uppercasing outside token owners, including when a baseline is updated.

Card, reader and overview share TagView, EyebrowText, IntelligenceLabel and NoticeView. Editor text themes remain in AppTypography, and overview type roles are scaled with the persisted reader preference. System NSColor label and separator colors provide light/dark/adaptive contrast.

## Verification and acceptance matrix

| View | Light | Dark | Increase Contrast |
| --- | --- | --- | --- |
| Story list | Pending | Pending | Pending |
| Story grid | Pending | Pending | Pending |
| Event card/coverage | Pending | Pending | Pending |
| Reader/summary/notice | Pending | Pending | Pending |
| Event overview/citations | Pending | Pending | Pending |

Static transformation assertions ran during GitHub source editing. **Pending Mac work:** `./script/design_lint.sh`, `./script/test_native_ui_qa.sh`, `./test.sh`, isolated arm64 app build and launch, screenshots on macOS 15/26/27 (light/dark/Increase Contrast), keyboard/VoiceOver, narrow 900 pt and wide/fullscreen. Hosted CI checks may validate compilation, but do not satisfy screenshot or spoken VoiceOver acceptance. No installation or database migration performed.

Do not close #354 or mark the board Done until all stacked PRs are merged and runtime acceptance evidence is attached.
