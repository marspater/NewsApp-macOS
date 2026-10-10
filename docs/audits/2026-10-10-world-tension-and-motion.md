# World Tension and native motion verification — 10 October 2026

Follow-up to PR #429, based on `6125666` (including merged #430). Development verification: Xcode 27, Swift 6.4, arm64, macOS 27.0.1. No distribution or notarization workflow was used.

## Behavior

World Tension v2 uses on-device reasoning about novelty, proximity to worst case, reversibility and scope of impact. It does not use the v1 casualty formula or relabel its history. Input is limited to a geographically balanced set of current international panel headlines plus earlier novelty context. Repeated headlines are deduplicated. The model returns a bounded report; a fresh model session checks factual support before accepting it. Both checks are heuristic, not independent human validation or calibrated catastrophe probabilities.

Native guided generation refused a peaceful control. Plain JSON and generated per-factor citations were also unreliable. The shipped path uses the existing plain-text model seam, a strict six-field report parser and disclosure of the complete supplied headline snapshot. A draft that paraphrased a ceasefire as a border halt was rejected. A later real-model control was accepted at **20 Mild**, with all four factors and novelty explicitly unknown without prior context, and was persisted/rendered through the production service in **3.88 seconds**.

The sidebar has a static band-coloured dot. Animated illustrations are confined to the tension sheet: green water ripples, yellow warmth, a smaller amber flame, a red flame with two embers, and a purple flame with five faster embers. `TimelineView` has no fixed frame interval and stops for Reduce Motion or an inactive scene. Card and reader transitions use native smooth animations; native ScrollView/List momentum scrolling is retained. Sidebar labels no longer swap their view type when loading begins.

Settings uses common 720 × 560 content bounds. Predefined category toggles live in General; they recognize canonical names and explicit legacy aliases without classifying/removing custom section names. The existing unified system toolbar and NavigationSplitView remain responsible for macOS Liquid Glass; no opaque toolbar/sidebar background or simulated glass was added. Apple documents automatic system adoption in [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## Completed checks

- Full `./test.sh` regressions: passed. New checks cover report shape, factor uniqueness, score bounds, current-headline requirements, repeated-headline selection, rejected model support, AI/collection policy before warm cache, daily replacement, reopen persistence and clearing derived AI history without deleting source articles.
- `script/test_native_ui_qa.sh`: **159 checks, zero failures**.
- Final arm64 `build_release.sh`: passed with sandbox entitlements and ad-hoc signing.
- Isolated native runtime harness: **27 Settings tab changes**, constant content/window size; five-state light/dark captures; reduced-motion and inactive-scene frame captures remained identical after 500 ms; live on-device acceptance, persistence and rendered sheet.
- Display-link probe over three seconds per request: at requested 60 Hz, 179 callbacks; at requested 120 Hz, 180 callbacks. Both p50/p95 intervals were **16.666 ms** on the connected **60 Hz** display. Callback cadence is not proof of GPU presentation FPS. Actual 120 Hz rendering needs a 120 Hz display.

Reproduce the isolated live probe with:

```sh
NEWS_NATIVE_HARNESS=Tests/NativeWorldTensionQA.swift ./script/native_performance_baseline.sh /private/tmp/world-tension-qa
```

It uses temporary SQLite/preferences and synthetic headlines. It needs an active Mac desktop, available Apple Intelligence and no power/thermal deferral. Outputs include captures, a cadence JSON report and the accepted assessment. It never reads the installed library.

## Verification limits

macOS 15 was a compilation target, not a runtime test. Spoken VoiceOver remains parked (#268). Actual 120 Hz presentation and compositor hitch profiling were not verified on this 60 Hz machine. The native toolbar delegates clear/tinted glass rendering to the system; both ends of the system transparency slider were not manually tested. Mission Control transitions require a separate installed-app check; stable label identity and monochrome symbols address the app-controlled redraw path, but do not establish absence of an OS compositor regression.
