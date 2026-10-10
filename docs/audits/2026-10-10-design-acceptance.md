# Design phases 2–4 acceptance — 10 October 2026

Issues: #352 (native window chrome), #353 (sidebar, search and states), #354 (content consistency); program #350. Phase 5 (#355) was handled separately.

All implementation PRs for phases 2–4 were already merged. This slice ran the remaining acceptance checks on `main` at `4a6f53f` plus the fixes below, then moved to `main` at `65fcd83` (phase 5 and event PRs merged), on Apple silicon, macOS 27.0.1 (26A434), Xcode 27, arm64 ad-hoc. No installed app, real library or real settings were used.

## Defects found and fixed

1. **Overview sections turned mid-gray in light mode.** `AppColor.cardBackground` was `Color(NSColor.controlBackgroundColor.withAlphaComponent(0.6))`. `withAlphaComponent` resolves the dynamic system color once, at first use, so the token kept whichever appearance was active then. On a dark system with the in-app Light override (D7), or after switching the macOS appearance while News runs, the key facts, sources, timeline and perspectives boxes were dark gray at 60 % over white, and citation tags and timeline dates were hard to read. The token is now `Color(NSColor.controlBackgroundColor).opacity(0.6)`, which stays dynamic. This dates from `446a7bb`, before the redesign. The Native UI QA "Light and Dark Appearance Tokens" check used to only touch the tokens; it now resolves seven adaptive tokens in light and dark and fails if any is frozen. It failed on the old token and passes on the new one.
2. **Cards ignored Increase Contrast.** DESIGN.md 11 and 16 ask borders and secondary text to use the contrast tokens. The reader and overview did; story cards, event coverage rows and their dates did not (0 changed pixels between dark and dark + Increase Contrast). `AppColor.border(for:)` and `AppColor.tertiaryText(for:)` now carry the existing reader/overview rule (stroke at primary 50 %, tertiary text up to secondary) and the cards use them. The reader and overview now call the same helpers.
3. **The sidebar never kept keyboard focus.** Clicking a sidebar row selected it, but arrow keys then moved the story focus (or nothing), and Tab never reached the sidebar. A minimal SwiftUI reproduction showed the cause: on macOS 27, once the window title and the toolbar `searchable` field update for the new selection, the sidebar list loses first responder. The sidebar now binds `@FocusState` to the list and sets it from the selection binding's setter, which only clicks and arrow keys reach (⌘1–⌘4 set the selection directly and leave focus alone).

## Phase 4 · appearance matrix (#354)

`./script/appearance_matrix.sh` (new) captures the offline VoiceOver fixture library — list, grid, an event with three sources, a structured reader story and an event overview — through the window server in four appearances. The window server composites sidebar vibrancy, materials and the toolbar; `cacheDisplay` did not (selected sidebar rows rendered black), so the harness uses `screencapture -l` and checks the captured size, since a window that loses focus can be shrunk by Stage Manager.

Increase Contrast is emulated, not toggled: the window uses the `accessibilityHighContrast*` appearance and SwiftUI's contrast environment, plus the app's own `overrideContrast`, because split-view columns re-derive the system value. System label and separator colors therefore show their standard variants; the app's contrast tokens show their increased variants. The system Increase Contrast setting was not changed.

| View | Light | Dark | Increase Contrast (light, dark) |
| --- | --- | --- | --- |
| Story list | Pass | Pass | Pass after fix 2 |
| Story grid | Pass | Pass | Pass after fix 2 |
| Event card and coverage row | Pass | Pass | Pass after fix 2 |
| Reader and notices | Pass | Pass | Pass (divider and secondary text strengthen) |
| Event overview and citations | Pass after fix 1 | Pass | Pass (borders, dividers and pills strengthen) |

The same harness compiled against `401c90a` (before phase 2) gives a before/after comparison: content alignment, type scale and card structure are unchanged; the differences are the phase 2 chrome (toolbar controls, masthead with date, no in-content sidebar toggle or search), the phase 4 tag styling ("Event overview" tag in sentence case instead of code-uppercased) and the two fixes. The gray overview boxes are present in the before capture too.

## Phase 2 · runtime and performance (#352)

- **Scrolling under glass, macOS 27:** in the isolated app, the list's lead image and the reader's story image pass under the Liquid Glass toolbar; the inactive window dims the toolbar and the floating updates pill.
- **Performance gate:** [raw samples](../benchmarks/2026-10-10-design-acceptance.json). `NativePerformanceBaseline.swift` from `main`, compiled once per snapshot, ten interleaved rounds per comparison. The desktop was not idle (another agent session; load average 3.4–6.2), which is why only run-level medians and a permutation test are reported.

| Comparison | First card (median) | Scroll frame readback | Mocked refresh | Peak RSS |
| --- | --- | --- | --- | --- |
| Before → after phase 2 (`401c90a` → `3370e42`) | 501 → 542 ms, p = 0.37 | 188 → 196 ms, p = 0.07 | 149 → 150 ms, p = 0.81 | 269.5 → 277.3 MiB, p = 0.001 |
| Before → current main (`401c90a` → `4a6f53f`) | 481 → 489 ms (+1.7 %), p = 0.68 | 176 → 183 ms (+4.0 %), p = 0.025 | 134 → 134 ms, p = 0.96 | 268.4 → 273.1 MiB (+1.7 %), p = 0.011 |

First-card time and refresh show no detectable change. Scroll-frame readback (+7 ms, a synchronous full-window bitmap read, not frame time) and peak RSS (+5 to +8 MiB of a process that includes Vision) are small but measurable. Since phase 2, the harness window carries the real glass toolbar, which is consistent with both. Both stay well inside the existing investigation budgets (575 ms first card, 300 MiB RSS; 2026-10-02 integrated budgets). Whether that satisfies "no regression" is an acceptance decision for Mars; it is not claimed as a pass here.

## Phase 3 · live acceptance (#353)

Isolated app: `script/run_isolated.sh --seed` (bundle `com.marspater.news.isolatedqa`, separate container, synthetic 10,000-story library). Its default settings subscribe the starter feeds, so live public feeds were fetched into that container; the real library was not touched.

- [x] ⌘1–⌘4 and Navigate → Today/Unread/Saved Stories/History select the right section.
- [x] Sidebar selection and arrow keys: fixed (defect 3). After a click, ↓ moves Unread → Briefing → Saved Stories with the focused highlight; a click in the story area returns ↓/↑ to the cards; Tab and Shift-Tab move between stories, search and sidebar.
- [x] Rows follow the sidebar size (per-launch `-NSTableViewDefaultSizeMode`, no system change): row pitch about 24.8 pt small, 32.5 pt medium, 40.5 pt large.
- [x] 900 pt window: add, sidebar, grouping, list/grid, refresh and the search field all fit without overflow; `searchToolbarBehavior(.minimize)` is not needed.
- [x] Search from Saved Stories: `is:unread report ` becomes a chip plus free text and returns archive results (200); removing the chip keeps "report" and its results; Escape clears the search and returns to the section; a query without matches shows "No Results for "…"" without a refresh action. Token suggestions list the five operators.
- [x] Subscribe: an invalid or already-subscribed URL shows the "Feed not added" alert and adds no row; a new URL shows "Subscribed to www.theguardian.com" in the masthead.
- [x] Empty Saved Stories and History use the system unavailable view.
- [ ] Not exercised live: OPML file drops (needs a Finder drag) and the feed-failure view with Retry and collapsed details.

## Not verified here

- macOS 15 and 26 runtime: no such machine or VM is available. CI builds the app and the tests with `-target arm64-apple-macos15.0`, so every availability-gated API compiles for macOS 15 (#350's CI item); runtime behavior on 15/26 is not claimed.
- System Increase Contrast, Reduce Transparency, Reduce Motion and the Liquid Glass clear/tinted setting: these are system settings and were not changed. Full-screen toolbar hover was not observed.
- Spoken VoiceOver stays parked (#268).

## Phase 5

Phase 5 (#355, PR #402) merged and closed while these checks ran. This slice was moved onto that `main` without rewriting history, and the reader and overview now call the shared contrast helpers instead of their identical private copies. A reader defect seen during the checks is not fixed here: the story image caption repeats its caption and credit text.

## DESIGN.md 19 review

- [x] No new literal font size, color, spacing, radius or control height outside `DesignSystem.swift`.
- [x] No glass added or changed.
- [x] No toolbar or sidebar background, no forced scroll edge.
- [x] Toolbar and menus unchanged; every toolbar action still has a menu command.
- [x] Sidebar, search and empty states use the system components.
- [x] Light, dark and Increase Contrast checked (emulated, see above); Reduce Motion and Reduce Transparency not affected by these changes and not re-checked; macOS 15 compiled, not run.
- [x] Narrow (900 pt) and wide windows checked; keyboard path works.
- [x] Copy unchanged.
