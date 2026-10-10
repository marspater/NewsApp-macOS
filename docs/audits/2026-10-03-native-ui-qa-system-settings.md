# Native UI QA & System Settings Audit

**Date:** 2026-10-03  
**Context:** Issues #155 (Native UI QA pass on isolated data) and #123 (Reader accessibility and native QA pass)  
**Scope:** `AppSettings.swift`, `NewsApp.swift`, `ArticleDetailView.swift`, `ArticleListView.swift`, `EventCardView.swift`, `ArticleCardView.swift`, `SettingsView.swift`, `Tests/NativeUIQAChecks.swift`, `script/test_native_ui_qa.sh`, `script/run_isolated.sh`

---

## 1. Problem Statement & Constraints

The QA checklists in #155 and #123 require comprehensive native UI verification across:
- **VoiceOver**: Heading hierarchy, semantic labeling without punctuation noise, rotor accessibility actions, and announcements.
- **Increase Contrast**: Stronger dividers, borders, and contrast strokes for citation pills, updates buttons, and text contrast.
- **Reduce Motion**: Total suppression of layout and navigation animations (reader transitions, queued update flashes, list animations).
- **Text Scaling**: Proportional scaling of typography and bounded column width expansion across 1.0x to 1.5x scales.
- **Window Widths**: Responsiveness from 380px narrow split views to 1200px wide displays.

Under macOS and SwiftUI:
1. `colorSchemeContrast`, `accessibilityReduceMotion`, and `accessibilityVoiceOverEnabled` on `EnvironmentValues` are read-only properties sourced from global system settings.
2. In development and CI environments, switching system preferences globally is intrusive, disrupts other applications, and violates isolation guarantees.
3. Testing must strictly operate on isolated data, never altering the user's real library, read history, saved stories, or user preferences.

---

## 2. Architecture & Implementation

### 2.1 System Settings Overrides
In `Sources/App/AppSettings.swift`, added:
- `SystemSettingsOverrides`: Parses simulated accessibility settings from direct CLI arguments (`--increase-contrast`, `--standard-contrast`, `--reduce-motion`, `--no-reduce-motion`, `--voice-over`, `--text-scale <scale>`) and standard macOS launch arguments via `UserDefaults` (`-AppleIncreaseContrast YES`, `-AppleReduceMotion YES`, `-AppleAccessibilityVoiceOverEnabled YES`, `-AppleTextScaleFactor <scale>`).
- Custom `EnvironmentKey` entries (`overrideContrast`, `overrideReduceMotion`, `overrideVoiceOver`) providing writable overrides.
- Computed environment accessors (`effectiveContrast`, `effectiveReduceMotion`, `effectiveVoiceOver`) that transparently return the override when set, or fall back to system settings when unset.
- `SystemSettingsOverrideModifier`: Attached to `MainView`, `TensionIndexView`, and `SettingsView` in `NewsApp.swift`. When no overrides are provided, it passes `content` through with zero modification, preserving 100% standard OS behavior.

### 2.2 UI Accessibility & Keyboard Focus Refinements
- **Citation Highlight Dismiss Button (`ArticleDetailView.swift`)**: Added `.buttonBorderShape(.circle)` to ensure circular keyboard focus ring semantics matching `xmark.circle.fill`.
- **Queued Updates Button (`ArticleListView.swift`)**: Added `@Environment(\.effectiveContrast)`, `.buttonBorderShape(.capsule)`, and a dynamic high-contrast stroke (`0.60` opacity under Increase Contrast) matching the citation pill pattern.
- **Event Card Coverage Toggle & Source Rows (`EventCardView.swift`)**: Added `.buttonBorderShape(.roundedRectangle(radius: AppRadius.control))` to `coverageToggle` and `.buttonBorderShape(.roundedRectangle(radius: AppRadius.card))` to `EventSourceRow`.
- **Article Cards (`ArticleCardView.swift`)**: Added `.buttonBorderShape(.roundedRectangle(radius: AppRadius.card))`.
- **Reader Text Scale (`ArticleDetailView.swift`)**: Initialized from `SystemSettingsOverrides.from().textScale ?? 1.0` so CLI `--text-scale` is honored on reader entry.

### 2.3 Isolated Build & Automated Verification Harnesses
- **`script/run_isolated.sh`**:
  - Stages the app source into a temporary directory.
  - Builds under an isolated bundle ID (`com.marspater.news.isolatedqa`) into an isolated sandbox container.
  - Supports `--seed` to populate test fixtures without touching user data.
  - Forwards system settings flags (`--increase-contrast`, `--reduce-motion`, `--voice-over`, `--text-scale 1.3`).
- **`Tests/NativeUIQAChecks.swift` & `script/test_native_ui_qa.sh`**:
  - Dedicated 11-part test suite validating all checklist items from #155 and #123.

---

## 3. Verification Checklist Coverage

| Checklist Item | Coverage | Verification Mechanism |
|---|---|---|
| Keyboard-only use & shortcuts | J, K, E, G, U, W, M, S, O, Esc, Return, Space | `NativeUIQAChecks.testKeyboardShortcutsAndKeyHandling` |
| Focus rings under `focusEffectDisabled` | Reader root disables ring; descendants re-enable `.focusEffectDisabled(false)` with explicit `.buttonBorderShape` | Verified across pills, circles, and cards |
| VoiceOver spoken label formatting | Grouped source line, overview metadata, lead image, citation quotes, rotor context | `NativeUIQAChecks.testVoiceOverStructureAndAnnouncements` (helper assertions) |
| Image alt-text fallbacks | Explicit alt preserved, nil/whitespace falls back to "Article image" | `NativeUIQAChecks.testVoiceOverStructureAndAnnouncements` (`effectiveImageAlt`) |
| VoiceOver structure, traits & announcements | Heading levels (H1/H2/H3), rotor actions, live `.announcementRequested` posting | Code-level modifiers (`ArticleDetailView`, `ArticleListView`); not asserted by unit tests |
| Several window widths | 380px (narrow split), 800px (standard), 1200px (wide) | `NativeUIQAChecks.testWindowWidthsAndLayoutMetrics` |
| Text scaling adaptation | 1.0x to 1.5x text scaling; reading column capped at 1.3x | `NativeUIQAChecks.testTextScalingAdaptation` |
| Increase Contrast | Dividers (0.20/0.15 -> 0.60), pill strokes (0.0 -> 0.60), quotes (0.50 -> 1.0) | `NativeUIQAChecks.testIncreaseContrastScalers` |
| Reduce Motion | Animation suppression in reader, overview, list updates, sidebar | `NativeUIQAChecks.testReduceMotionPolicies` |
| Light and dark appearance | Semantic tokens resolve under both appearances | `NativeUIQAChecks.testLightAndDarkAppearanceTokens` |
| Event card source list (Phase D) | E key expansion, G grouping toggle, "Not the Same Event" actions | Verified in `EventCardView` & `ArticleListView` |
| Stable feed & update buffer | Cards do not move while focused/reading; U key applies updates | `NativeUIQAChecks.testFeedStabilityAndQueuedUpdatesBuffer` |
| Event overview lifecycle (Phase E/F) | Loading indicator, caching, W toggle, split event invalidation | `NativeUIQAChecks.testEventOverviewGenerationAndCachingLifecycle` |
| Citation routing & passage banner | Direct ID, URL, and publisher matching; banner dismiss | `NativeUIQAChecks.testCitationRoutingAndBanner` |

---

## 4. Execution Commands

```sh
# Run automated Native UI QA checks (11/11 suites passed)
./script/test_native_ui_qa.sh

# Run existing Event Overview accessibility suite (49/49 passed)
./script/test_event_overview_accessibility.sh

# Run existing Source Reader accessibility suite (26/26 passed)
./script/test_reader_accessibility.sh

# Run isolated app with simulated Increase Contrast and Reduce Motion
./script/run_isolated.sh --increase-contrast --reduce-motion --text-scale 1.3 --seed

# Standard regressions & build
./test.sh
./build.sh
```

---

## 5. Limitations & Live Release Verification

- **Automated VoiceOver Scope**: The automated test suite (`Tests/NativeUIQAChecks.swift`) asserts accessibility label formatting helper output (source line grouping, header metadata, citation quotes, action context) and image alt-text fallbacks. It does not render views, inspect the live macOS accessibility tree (`NSAccessibility` hierarchy), verify heading traits (`.accessibilityHeading`) or rotor actions, or observe posted announcement notifications.
- **Live VoiceOver Verification Gap**: Real VoiceOver speech synthesis, auditory pacing, pronunciation, and keyboard cursor navigation are not exercised by headless unit tests or override flags.
- **Recommended Pre-Release Check**: Perform a manual VoiceOver pass (`Cmd+F5`) on a running isolated build (`./script/run_isolated.sh --seed`) before final release tagging to verify:
  - Live cursor navigation order and rotor headings/actions.
  - Headings are announced at their expected levels (H1/H2/H3).
  - Queued updates trigger spoken announcement notifications when applied.
  - Speech synthesis audio pronunciation and pacing across reader blocks and citations.


