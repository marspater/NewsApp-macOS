# Finish pass — 23 October 2026

Status: plan as approved by Mars on 23 October 2026 (baseline `origin/main` `0eeb74b`). Slices land as separate PRs; outcomes are recorded here as they merge.

## Context

Mars asked for a meticulous analysis of the current app (main `0eeb74b`, after #481) and a plan to bring it to "perfect", UI first, with the custom reader renderer called out. Planning decisions: keep the SwiftUI per-block renderer and polish it (no TextKit rewrite); Mars runs window-opening harnesses (I stay background-only); scope = reader + overview, list/cards/chrome, extraction feeding the renderer, lint/tokens.

**State.** No open PRs; only parked #264/#268 open. The 21 Oct plan is done (#470–#479). #481 merged, but `ARCHITECTURE.md:278-289` still says "In review" and one row is now wrong (selectedImage fallback). CHANGELOG lacks #475/#481. DESIGN.md §18 still lists Tag/Eyebrow/Intelligence label/Notice/Reading column as "planned" though they exist in `DesignSystem.swift`. CNA "(Updated: …)" still open. The design lint baseline is at zero, but the lint cannot see literal spacing/frames/opacity, raw environment values, ungated motion or copy. No test asserts rendered reader layout.

Short names: ADV `Sources/Views/ArticleDetailView.swift`, RSV `ReaderSupportViews.swift`, EOV `EventOverviewReaderView.swift`, DS `DesignSystem.swift`, CEP `Sources/Intelligence/ContentExtractionPipeline.swift`.

## Findings (verified in code)

### P0 — wrong behaviour
1. **Overview citations open the wrong source.** Four call sites pass `citationIDs.compactMap{…}.first` for every superscript; `sourceIndices` drops index→citation, so [2]/[3] open citation 1. `EOV:488-496, 593, 902, 942, 991`.
2. **Short paragraphs deleted** by a 25-char floor (`CEP:440`, also `:299, :320, :1310`) — "He was 34." disappears.
3. **`<br>` strips bold and links** for the whole paragraph (`combinedText` adds `\n`, `inlineContent` adds nothing, mismatch → `inlineRuns = nil`), and loses line breaks. `CEP:188, 348-373, 1102`.
4. **Tables scrambled** ("Team AWins3Losses2"); no `table` handling. `CEP:194-203, 315-345`.
5. **Settings → Subscriptions add-feed errors are invisible**: message goes to `cacheActionMessage`, rendered only in Storage. `SettingsView.swift:1021, 729`.
6. **Destructive actions without confirmation**: Clear All / three Clear buttons (`SettingsView.swift:770-873`), Remove Section (`SidebarView.swift:150-155`).
7. **Ungated motion**: search-width `NSAnimationContext` 0.22 s ignores Reduce Motion. `MainView.swift:496-501`.

### A. Reader renderer
8. Headings ignore reading style (sans in Casper/Alto); h3 15 pt < body 16–18; no line spacing. `DS:211`, `ADV:672-682`.
9. Spacing: heading top `lg` unscaled stacked on previous `lg*scale` (~48 above, 12 below); quote/code/figure/divider padding unscaled. `ADV:648-703`.
10. Code: literal `.system(.body, design: .monospaced)`, ignores text size; `readerCodeFont`/`readerQuoteFont` unused; wraps; non-continuous corners. `ADV:690-722`.
11. Double lead (standfirst + first paragraph both `leadFont`); lead style stops mid-paragraph after the 650-char split; standfirst pops in at `.ready` and compares with unfiltered blocks. `ADV:576-593, 643, 726`.
12. Body colour jumps on load (`readableText(0.9)` → primary); 0.88/0.92 elsewhere; not a token. `ADV:602, 730, 1128, 1182, 1202, 1257`.
13. Lists: marker column not fixed/monospaced; nested lists flattened; link-only items dropped. `ADV:705-715`, `CEP:315, 360, 439`.
14. Quotes: blockquote, pull quote, `aside.standfirst/dek`, embedded tweets all → same italic box; multi-paragraph quotes joined. `CEP:434, 556-560`.
15. Figures: width capped at decoded pixel width (small images left-aligned, not filling measure, Retina upscale); no portrait cap; 1.5 placeholder → jump; borders/captions ignore Increase Contrast; caption 11 pt; "Article image" alt. `RSV:108-182`, `ArticleRemoteImage.swift:103`.
16. Hero image moves from above summary (loading) to below divider (ready); `hasEarlyFigure` uses unfiltered blocks; `lastPathComponent` dedupe collides. `ADV:423-447`.
17. Links colour-only, no underline; no `OpenURLAction`; legacy relative hrefs dropped. `RSV:202-216`.
18. Video/iframe figures vanish without placeholder; `sup/sub` flattened. `CEP:380, 551`.
19. Citation jump shows a top notice only — no scroll to / highlight of the passage. `ADV:214, 271`.
20. Eyebrow publisher in accent colour (DESIGN 8.2: secondary); hand-rolled eyebrow at `ADV:521-525`.
21. Summary disclosure lacks intelligence glyph; three hand-rolled panels; raw error text. `ADV:365, 1155-1267`.
22. Terminal affordance duplicates notice buttons in `.publisherOnly`/`.fallback` and shows while loading. `ADV:389, 742-761`.
23. Reading time jumps; counts filtered boilerplate. `ADV:457-462`.
24. Increase Contrast divider weaker than the plain one. `ADV:373, 1111-1113`.
25. Web container `Divider().opacity(0.15)`, `frame(height: 2)`, "Open interactive page in browser"; `ToolbarLoadingBubble.frame(height: 24)`. `ADV:766-789`, `RSV:232`.
26. Performance: body not lazy; blocks refiltered and `AttributedString`s rebuilt every pass; `currentArticle` linear scans referenced dozens of times; `id: \.offset`. `ADV:95-99, 450, 610-663`.

### B. Event overview
27. Superscripts are separate `Button`s beside multi-line text (float at first line); `baselineOffset(4)` literal; tiny hit target. `EOV:499-597`.
28. No intelligence label on generated overview/highlights. `EOV:331, 554`.
29. Typography diverges: roles ignore reading style; body 14 pt vs 15–18; ad hoc line spacing. `DS:230-257`.
30. Lead image is a second figure implementation (`maxHeight: 380`, 220 pt placeholder jump). `EOV:418-470`.
31. Literal geometry (dots, rail, `width: 24` index overflows "[10]", `opacity(0.5)` halving contrast border, divider 0.20 vs 0.15); intro pills don't wrap; formatters per access, stale "Updated 2 minutes ago"; dead code (`activeCitationPreview`, `citationPillsView`, `colorScheme`; `ADV borderColor`). `EOV:70, 260-266, 396-400, 566, 660, 843-960`.

### C. List and cards
32. Read cards dim whole card (`opacity 0.90`, `saturation 0.92`); lead card ignores read state and uses text Labels for Saved/Unread instead of glyph/dot. `ArticleCardView.swift:175, 350-404, 421`.
33. Hover auto-cycles images every 2.5 s (DESIGN 13). `ArticleCardView.swift:119-134`.
34. Failed lead image collapses to a 54/170 pt card inside a 360 pt slot; lead radius 16 vs 12; placeholder `LinearGradient`. `ArticleCardView.swift:287-333, 438`.
35. Focus ring shown while list unfocused (typing in search). `ArticleListView.swift:839`.
36. Event card: coverage row is a separate filled surface (three surfaces per event); no hover; "Loading sources" forever on empty result; failure text without Retry; unread dot leading vs trailing, different token; "publication" copy. `EventCardView.swift:70-231`.
37. List gaps 12 vs grid 16; lead card wider than capped list cards in wide windows. `ArticleListView.swift:791-829`.
38. Briefing toolbar has 4 groups; "New Edition" vs menu "New Briefing"; updates button case and no `monospacedDigit`; "Group by Event" has four names; layout picker segments are bare `Image`; "Technical Details" repeats the description. `ArticleListView.swift:400-704`.
39. Copy: "click refresh", "bookmark … easy reading", "Main stories · Your interests…", straight apostrophes. `ArticleListView.swift:713, 972-974`.

### D. Sidebar, menus, sheets, settings
40. Sidebar: `.scrollContentBackground(.visible)`; `Divider().opacity(0.4)`; always-`.fill` icons; VoiceOver labels differ from visible titles; four names for add-feed. `SidebarView.swift:63-187`.
41. Menus: static titles "Mark as Read or Unread", "Save or Remove from Saved"; no ⌘[ ⌘] for web back/forward, no List/Grid shortcuts; World Tension has no menu command; New Briefing in Navigate; Keyboard Shortcuts window incomplete. `NewsApp.swift:84-219`, `ArticleListView.swift:1151-1183`.
42. Feed catalog: hand-rolled pills with full accent fill, no `.isSelected` trait; `.borderedProminent` on every row; hand-rolled Remove chip; success-coloured text; sparkles on deterministic topic gaps; blank list when empty; raw `colorSchemeContrast`; fixed sheet frame. `FeedCatalogView.swift:13-298`.
43. Settings: yellow warning body text; danger-coloured titles; Storage tab not a `Form`; hand-rolled pills; marketing/jargon copy ("Zero Cloud Telemetry", "Powered exclusively by", "Persistent WAL database"); name mismatches with menus; three transient-status mechanisms (3 s vs 5 s). `SettingsView.swift:129-1033`.
44. World Tension sheet: "44 / 100" vs sidebar "44°"; band name in yellow text; internal codes visible ("[C3]", "methodology v2"); custom header vs catalog's; raw error text; custom sidebar hover fill; four heading styles. `TensionIndexView.swift:56-706`.
45. Tokens: `intelligence`/`flameCore` lack dark/contrast variants; `TagView` uses micro steps and its own fill; duplicate and unused tokens (`label`/`primaryText`, `focusRing`, `bubble`, `smooth`, `modal`, `cardSelected*`, `sourceEyebrowTracking`…); missing tokens (stroke widths, dot size, card image sizes, window/sidebar/sheet sizes). GlassSystem helpers unused and don't dim with `appearsActive`. `DS`, `GlassSystem.swift`.

## Plan — slices
Each slice is one focused PR: `./test.sh`, `script/format.sh --check`, `./build.sh` in a staging directory, DESIGN.md checklist in the PR, CHANGELOG entry, project board #2 update. Unit tests land with their slice.

### Slice 0 — Docs truth (XS)
ARCHITECTURE: move #481 rows into invariants, fix selectedImage row, drop "In review". CHANGELOG for #475/#481. DESIGN §18 owners updated to the existing components.

### Slice 1 — P0 behaviour fixes (S) — EOV, SettingsView, SidebarView, MainView
- `sourceIndices` → `[(index, citation)]`; four call sites use the pair. Test: [2] maps to source 2.
- Subscriptions-tab error shown in that tab (reuse one status message helper).
- `confirmationDialog` for Clear All / Clear caches / Remove Section (pattern at `ArticleListView.swift:417`).
- Gate the search-width `NSAnimationContext` on `effectiveReduceMotion` (duration 0).

### Slice 2 — Extraction fidelity (M) — CEP, `Sources/Models/FeedArticle.swift`
- Keep short paragraphs inside the explicit/selected body unless boilerplate or link-dense; 25-char floor only for div/inline fallback.
- `br` emits a `\n` run; renderer keeps line breaks.
- Tables → new `.table` kind (cells tab-separated, rows newline-separated in `text`); >8 columns or >40 rows → `.embed`-style notice.
- Nested lists: optional `ReaderBlock.level`.
- New kinds `.standfirst`, `.pullQuote`, `.embed`; tweets/Instagram blockquotes → `.embed`; `iframe`/`video` figures → `.embed` with host + caption.
- `sup/sub` → optional run flags. Body `h1` (not the title) → heading.
- CNA: plain "(Updated: …)" timestamp-only lines dropped.
- Codable safety: all new fields Optional; tolerant `Kind` decoding (unknown → `.paragraph`).
- Bump `ReaderDocument.currentVersion` → 10 (re-extract on open, `ADV:1287`).
- Fixtures per rule; `--parsing-regressions`, `--story-regressions`, live `--catalog-reader-access` vs the 21 Oct audit.

### Slice 3 — Reader typography and spacing tokens (S) — DS, ADV
- `readerHeadingFont(level:theme:scale:)` with theme design; h2 ≈ body×1.35, h3 ≈ body×1.1 (never < body); heading line spacing.
- Scaled `readerCodeFont(theme:scale:)`; use `readerQuoteFont`.
- `readerCaptionFont` 13 pt × scale; contrast-aware caption/credit colours.
- `AppColor.readerBody(contrast)` replaces every `readableText(...)`.
- One `readerSpacing(after:before:scale:)` function: no stacking, nothing above the first block, all scaled.
- Lead font only without a standfirst, applied to the whole first logical paragraph.
- Eyebrow secondary via `EyebrowText`; one divider token that strengthens with contrast.

### Slice 4 — Reader block rendering (M) — ADV, RSV
- Lists: fixed marker column sized to widest ordinal, `monospacedDigit`, small secondary bullet, indent per level.
- Blockquote: accent bar + italic, no box; pull quote: larger lead font between thin rules; standfirst block styled like the feed standfirst (feed standfirst suppressed when present).
- Code: horizontal `ScrollView`, no wrap, continuous corners. Table: `Grid` with header row and hairlines, horizontal scroll when wide. Embed: `NoticeView` with symbol, host, caption, Open Web View.
- Links: underline on link runs; explicit `OpenURLAction` (http/https to browser); article URL as base for legacy docs.
- Figures: fill the measure unless the image is tiny (< 400 pt at backing scale), centered; portrait cap with the blurred backdrop extracted from `ArticleCardView.swift:303-310` into a shared view; stable placeholder ratio; contrast-aware border; empty alt + empty caption → hidden from VoiceOver.
- Hero placement decided once from filtered blocks; exact-URL dedupe.
- Terminal affordance only in `.ready`; reading time from rendered blocks, shown once known.
- Web container literals/copy ("Open in Browser"); `ToolbarLoadingBubble` without fixed height.
- Summary: `IntelligenceLabel` in the disclosure label; one `ContentPanel` modifier (DS) for the panels; plain error copy.
- Performance: memoize filtered blocks + `AttributedString`s per (article id, input hash); cache `currentArticle` per id; `LazyVStack` for body blocks.

### Slice 5 — Citation jump to passage (S) — ADV
`ScrollViewReader`; match the normalized quote (`EventFeedSummary.titleKey`) against block text, fallback token overlap; `scrollTo(anchor: .center)` (no animation under Reduce Motion); accent 12 % background on the matched block until dismissed. Unit-test the matcher.

### Slice 6 — Overview polish (M) — EOV, DS
- Inline superscripts: one `Text` per fact from `AttributedString`, citation runs linked `news-citation://<index>` via `.environment(\.openURL)`; scaled superscript token; `accessibilityActions` "Open Source N".
- `IntelligenceLabel` on header and Highlights.
- Facts/perspectives/timeline follow reading-style body sizes and line spacing.
- Lead image through the shared figure view; tokens for dots/rail/index column (sized by digit count); contrast-aware rail/borders; `ReaderTagLayout` for intro pills.
- Static formatters; live relative time (`Text(date, style: .relative)`); precompute fact→citations once; delete dead code.

### Slice 7 — Cards and list (M) — `ArticleCardView`, `EventCardView`, `ArticleListView`
- Read state: secondary headline only (no opacity/saturation), lead card too; lead uses the accent dot and bookmark glyph.
- Remove hover image cycling. Failed lead → full-height editorial placeholder; one radius; no gradient.
- Focus ring only when the list has focus.
- Event card: coverage row inside the card surface; hover state; empty result → "No sources" state; failure with Retry; unread dot shared component in one position; "story" copy.
- List/grid gap one token; lead respects `listMaxWidth`.
- Toolbar: ≤3 groups in Briefing; one name per action ("New Briefing", "Group Stories by Event"); Title Case + `monospacedDigit` updates button; layout picker `Label`s; drop fake "Technical Details"; copy fixes.
- Layout tokens: `listCardHeight`, `listCardImageWidth`, `editorialHeaderHeight`, `unreadDotSize`, stroke widths (`hairline`, `hoverStroke`, `focusStroke`), `hoverBorderOpacity`, `popoverWidth`.

### Slice 8 — Sidebar, menus, sheets, settings (M) — `SidebarView`, `NewsApp`, `FeedCatalogView`, `SettingsView`, `TensionIndexView`, `MainView`
- Sidebar: drop `scrollContentBackground(.visible)` and divider opacity; `.fill` only when selected; accessibility labels = visible titles; one add-feed vocabulary ("Add Feed…", "Feed URL").
- Menus: dynamic Story menu titles from `selectedStory`; ⌘[ ⌘] web back/forward; List/Grid shortcuts; World Tension command; New Briefing under a non-navigation menu; complete Keyboard Shortcuts window.
- Catalog: category pills via `TagView`/segmented `Picker` with `.isSelected`; `.bordered` Subscribe (no prominent per row); system Remove button; label-colour text + glyph for Subscribed; no sparkles on deterministic gaps; empty state; `effectiveContrast`; system sheet sizing.
- Settings: Storage/Subscriptions as native scrollable `Form`s; `NoticeView` for the HTTP warning; label colours for titles; `TagView` badges; Section footers for descriptions; one transient-status mechanism (5 s); `ByteCountFormatter`; copy rewritten per DESIGN §17 (no marketing, no jargon, names match menus).
- World Tension: degrees everywhere; band name in label colour with coloured glyph; hide internal codes; sheet header like the catalog (title + Done); friendly error; system hover in sidebar footer; one heading style.

### Slice 9 — Tokens cleanup and lint ratchet (S) — DS, GlassSystem, `script/design_lint.sh`
- Delete duplicate/unused tokens; `intelligence`/`flameCore` get dark + increased-contrast variants (asset or dynamic NSColor); `TagView` uses spacing tokens and `badgeBackground` for neutral.
- GlassSystem: dim with `appearsActive` or delete unused helpers (keep one if a floating control exists; otherwise delete and update DESIGN §3.3 in the same PR).
- Lint: scan `Sources/App/NewsApp.swift` too; new ratchet rules `literal-spacing`, `literal-frame`, `literal-opacity`, `literal-stroke`, `system-font-design`, `raw-environment` (`colorSchemeContrast`, `accessibilityReduceMotion`), `foregroundColor`, `legacy-alias`, `article-copy` (`"[^"]*\b[Aa]rticle\b` in Text/Label/Button). Baselines set after slices 3–8; counts only go down.

### Slice 10 — Appearance acceptance (Mars runs harnesses)
Mars runs `script/appearance_matrix.sh` and `script/run_isolated.sh` (Reduce Motion, Reduce Transparency) over list, grid, reader (Casper/Edition/Alto; scale 0.9/1.0/1.3/1.5; a fixture story with headings, nested list, quote, pull quote, code, table, embed, portrait/landscape/small figures), overview, Briefing, Settings tabs, catalog, tension sheet — 900 pt and wide, light/dark/Increase Contrast. I review captures, fix token-level defects, write `docs/audits/2026-10-xx-finish-pass.md`, tick the outstanding checklists.

## Order
0 and 1 first (small, independent). 2 → 4. 3 → 4 → 5. 6 after 3 and 4. 7 and 8 after 3 (tokens), independent of each other. 9 after 3–8. 10 last.

## Reuse
`ReadingColumn`, `NoticeView`, `TagView`, `IntelligenceLabel`, `EyebrowText` (DS); `ReaderFigureView`, `ReaderTagLayout`, `readerText` (RSV); blurred backdrop (`ArticleCardView.swift:303-310`); `confirmationDialog` pattern (`ArticleListView.swift:417`); `ContentExtractionPipeline.readerImageURL`; `EventFeedSummary.titleKey`; `ArticleContentRedactor.isBoilerplateLine`; `ReaderDocument.currentVersion` re-extract rule.

## Verification
- Every slice: `./test.sh` (runs design_lint), `script/format.sh --check`, `./build.sh` in a staging directory (never over the real app).
- Extraction: `./test.sh --parsing-regressions`, `--story-regressions`, live `./test.sh --catalog-reader-access` compared with `docs/audits/2026-10-21-catalog-reader-access.md`.
- Headless unit tests: citation mapping, short-paragraph keep, br runs, table parse, nested levels, tolerant Kind decoding of v9 JSON, spacing function, heading ≥ body per theme, marker width, link base resolution, passage matcher, inline citation string.
- UI: slice 10 by Mars; I report exactly what was and was not checked. Not covered: macOS 15/26 runtime (no machines), live VoiceOver (#268 parked).
