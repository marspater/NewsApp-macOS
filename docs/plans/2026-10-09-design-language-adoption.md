# Design language adoption plan — 9 October 2026

Status: proposed. Base: `origin/main` at `4eaf39c`. Rules: [DESIGN.md](../DESIGN.md). Evidence and line references: [Apple News and Liquid Glass study](../audits/2026-10-09-apple-news-liquid-glass-study.md).

## Goal and limits

Make News feel native on macOS 26 and 27 by using system Liquid Glass wherever it applies, moving chrome into the toolbar and menus, and putting every screen on one set of tokens and components. This is not a redesign: the information architecture, the list and grid, the reader structure, the event model and the reading styles stay. Each phase is one to three focused PRs that leave the app shippable.

Out of scope: parked work (#264 non-English feeds, #268 live VoiceOver QA), new dependencies, notarization or Intel builds, a brand color, a new icon, and any change to ranking or story selection.

## Decisions to confirm

The rules in DESIGN.md use the recommended option. Changing a decision changes the matching rule before its phase starts.

| ID | Decision | Recommended | Alternative | Phase |
| --- | --- | --- | --- | --- |
| D1 | Search placement | Trailing end of the toolbar, as the HIG and WWDC26 recommend when results appear in the detail column | Keep the sidebar field shipped in the current Unreleased changes | 3 |
| D2 | List title | Masthead in the scroll content, toolbar title hidden, `navigationTitle` still set for the window | Toolbar title and subtitle, no masthead | 2 |
| D3 | Reader mode control | One segmented picker: Overview (events only), Story, Web | Keep the overview picker plus separate Reader and Web toggles | 5 |
| D4 | Reading measure | 720 pt for reader and overview (the value pinned by `NativeUIQAChecks`) | 700 pt for both | 5 |
| D5 | Shortcuts | Reader/Web moves from ⇧⌘W (a standard close shortcut) to ⇧⌘R (Safari's Show Reader); text size ⌘+, ⌘−, ⌘0; keep J/K, ⌘J/⌘K and ⌘O | Also add Apple News aliases ⌘→ and ⌘← for next and previous story | 2, 5 |
| D6 | Lead story | Optional lead treatment of the first Today or Briefing entry with an image, extended under the sidebar, without re-ranking | No lead treatment | 6 |
| D7 | Appearance override | Keep System, Light and Dark, default System | Remove it, as the HIG discourages app copies of system settings | — |
| D8 | Reading options | Popover with text size buttons and reading style (system glass), menu bar commands for both | Keep the current menu | 5 |

## Phase 1 — Foundations and guardrails

No visible change. Makes the rules enforceable.

- `GlassSystem.swift`: delete `FrostedElevation`, `FrostedSurfaceModifier`, `frostedSurface` and `frostedPill`. Keep `nativeLiquidGlass(in:interactive:)` and `inGlassContainer()`, gate them with `if #available(macOS 26, *)` only, and make the macOS 15 path `regularMaterial` (or `AppColor.surface` with a separator stroke under Reduce Transparency). Add `nativeGlassButtonStyle(prominent:)` (`.glass` or `.glassProminent` on macOS 26+, `.bordered` or `.borderedProminent` on macOS 15). Leave `softScrollEdge()` for phase 2.
- `DesignSystem.swift`: add the tokens DESIGN.md names (`masthead`, `sectionTitle`, `callout`, `eyebrow` with `eyebrowTracking`, `cardHeadline(_:)`, reader heading, quote, caption and code functions, `AppLayout.readingMeasure`, the 2 pt and 6 pt micro spacing, label-color text tokens, a separator-based border). Remove `AppLayout.toolbarHeight` and `controlHeight`. Existing token values do not change in this phase.
- Add `script/design_lint.sh`, run first by `./test.sh` (shell only, so it also runs where Swift cannot). It counts, per file under `Sources/Views` except `DesignSystem.swift` and `GlassSystem.swift`: `.font(.system(size:`, literal `Color.<name>` other than `clear`, `primary`, `secondary` and `accentColor`, `.cornerRadius(`, `toolbarBackground`, `glassEffect` or `GlassEffectContainer`, `scrollEdgeEffectStyle`, `.uppercased()` and material styles. A checked-in baseline records today's counts; the check fails when a count rises and asks for the baseline to be lowered when it falls. Later phases only lower it.
- Docs: link DESIGN.md from AGENTS.md, CONTRIBUTING.md, ARCHITECTURE.md and the PR template (done with this plan).

Acceptance: `./test.sh` passes and fails on a deliberately added literal font size; the app builds and looks unchanged.

## Phase 2 — Native window chrome

The largest visible improvement: the glass toolbar does its job.

- Remove `softScrollEdge()` and its five uses; scroll edges return to automatic. Remove `.toolbarBackground(.visible, for: .windowToolbar)` from the reader.
- List toolbar per DESIGN.md 5: a view options group (group by event toggle, list or grid picker), Refresh with its symbol effect, New Briefing as a separate text item in Briefing. Delete the in-content sidebar toggle and the header controls. Group with `ToolbarSpacer(.fixed)` on macOS 26+; rank Refresh with `visibilityPriority(.high)` on macOS 26.1+.
- Masthead (D2): title and status line move into the scroll content and scroll under the toolbar; the title uses `AppTypography.masthead` (`.largeTitle.bold()`, 26 pt instead of today's 32 pt) and Today's status line gains the date. Set `navigationTitle` for list and reader and hide the duplicate toolbar title.
- Queued updates: the pill floats over the top of the list as a button with `nativeGlassButtonStyle()` (glass on macOS 26+, bordered on macOS 15), keeps its count, shortcut and VoiceOver announcement, and dims with `appearsActive`.
- Menus: View gets as List, as Grid and Group Stories by Event; story actions (read state, save, open in browser, Reader or Web) move from Navigate to a new Story menu, keeping their shortcuts; Help gets Keyboard Shortcuts (the popover content moves to a window or sheet); Reader/Web moves to ⇧⌘R (D5). Update `NativeUIQAChecks` shortcut expectations in the same PR.
- Full screen: `windowToolbarFullScreenVisibility(.onHover)` on the reader.

Acceptance: no window control remains in content; every toolbar action has a menu command; the list and reader scroll under a glass toolbar with the system edge effect on macOS 26 and 27 and under a standard toolbar on macOS 15; keyboard navigation and the update-holding behavior are unchanged; the list stays usable at 900 pt with overflowed items in the system menu.

## Phase 3 — Sidebar, search and states

- Sidebar rows become `Label` rows with `.tag` and `.badge`; the loading indicator uses `.controlSize(.mini)`; no fonts or backgrounds on rows. Keep the add-feed `+` toolbar button and the Suggested section.
- Drop and import confirmations leave the list: success goes to the masthead status line for a few seconds (announced to VoiceOver), failure to an alert.
- Search (D1): move `searchable` to the toolbar and let the system collapse the field in narrow windows (opt into `searchToolbarBehavior(.minimize)` on macOS 26+ only if the toolbar is crowded at 900 pt); operators become tokens with the existing suggestions; no-result and error states stay `ContentUnavailableView`.
- Empty and feed-failure states become `ContentUnavailableView` with actions; technical detail stays in a disclosure group.

Acceptance: sidebar selection, keyboard movement and ⌘1–⌘4 behave as before; sidebar rows follow the System Settings sidebar size; search keeps archive scope and operators; no custom empty view remains in the list.

## Phase 4 — Content consistency

- Remap before redefining: today's `AppTypography.headline` (15 pt semibold) call sites move to `sectionTitle` or `cardHeadline`, `display` becomes `masthead`, `bodySmall` and `metadata` become `body` and `eyebrow`, and `body` (14 pt) call sites are reviewed before `body` becomes the system 13 pt style. Only then do the old names change value or disappear.
- Replace literal font sizes with tokens, file by file: cards and event coverage, then reader, overview, settings. Decorative symbol sizes in empty states use `imageScale` or a token.
- Add the shared Tag, Eyebrow, Intelligence label and Notice components and replace the hand-built capsules (AI badge, Updated, Plan, kicker, citation and summary tags) and callouts with them. The "✦" glyph becomes the `sparkles` symbol.
- Colors: remove `Color.blue`; text and border tokens move to system label and separator colors; contrast tokens stay.
- Strings stop uppercasing in code; eyebrows use `.textCase(.uppercase)`.
- Literal spacing becomes tokens in every file touched.

Acceptance: the lint baseline for fonts, colors and uppercasing reaches zero outside reviewed exceptions; light, dark and Increase Contrast screenshots of list, grid, event card, reader and overview show no unintended change beyond token alignment.

## Phase 5 — Reader

- One reading measure (D4) for reader and overview through `AppLayout.readingMeasure`; update the QA checks if the value changes.
- Text size becomes a persisted preference used by every story, with View menu commands ⌘+, ⌘−, ⌘0 and the Reading options control (D8).
- Reader mode control per D3; toolbar groups (navigation; mode; save and share; reading options) with `ToolbarSpacer` on macOS 26+.
- Terminal affordance uses standard bordered buttons; the cited-passage and fallback notices use the Notice component.
- Link the paragraphs of one story with `accessibilityLinkedGroup(id:in:)`; consider `lineHeight(_:)` on macOS 26+ through the reader tokens.

Acceptance: opening another story keeps the text size; ⌘+ and ⌘− work from the menu bar in reader and overview; the overview and reader share one column width; extraction states, citations and summaries behave as before.

## Phase 6 — Optional glass moments

Only after phases 2–5 and a visual review on macOS 27.

- Lead story (D6): the first Today or Briefing entry with an image shows a wide lead image with `backgroundExtensionEffect()` on macOS 26+ (text and actions layered above the image only); a normal card on macOS 15 and for entries without images.
- Concentric shapes for content that sits near a container or window corner.
- Interactive glass for any floating Web-view or media controls if such controls are introduced.

Acceptance: the native performance baseline shows no regression in first-card time or scrolling samples; the lead image never covers controls or text under the sidebar; nothing else in the content layer uses glass.

## Phase 7 — Settings and secondary windows

- Settings: remove the fixed frame so each pane sizes to its content, drop the extra padding around grouped forms, remember the last pane, replace literal fonts. Settings stays a toolbar tab window.
- News Tension and the Feed Catalog sheet: title, toolbar and token rules; no custom sheet backgrounds.

Acceptance: settings panes resize to their content and reopen on the last pane; no literal fonts remain in settings.

## Verification for each UI phase

- `./test.sh`, `./script/test_native_ui_qa.sh`, and a staged `./build.sh` in an isolated directory followed by launch, reported separately (CONTRIBUTING.md).
- Visual matrix on macOS 27: light and dark; Liquid Glass slider at clear and at tinted; Increase Contrast; Reduce Transparency; Reduce Motion; inactive window; full screen; 900 × 600 and a wide window. `./script/run_isolated.sh` covers the simulated settings.
- macOS 15 behavior for every gated API: compile for the macOS 15 target in CI; a runtime check on macOS 15 needs a separate machine and is reported as not run when unavailable.
- Phases 2 and 6 also run `./script/native_performance_baseline.sh`, since glass adds GPU work.
- The DESIGN.md review checklist goes into each PR description.

## Risks

- Moving controls out of the focusable list can break single-key shortcuts; phase 2 keeps the list's focus handling and adds menu commands rather than replacing it.
- `NativeUIQAChecks` pins some values (overview measure, contrast opacities, shortcut handling); phases update those expectations deliberately in the same PR and never delete the checks.
- Toolbar overflow at the minimum window width can hide Refresh; ranking and a narrow-window check cover it.
- Search placement (D1) reverses a recent change; if it is declined, DESIGN.md section 7 changes first.
- macOS 27 press reports may differ in detail from shipping behavior; implementation follows what the app shows on macOS 27.

## Tracking

Create one issue per phase after this plan is accepted, link each PR to its issue with `Refs #N`, and record checks and screenshots in the PR and, for phases with measurements, in `docs/audits/`.
