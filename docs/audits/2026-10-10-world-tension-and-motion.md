# World Tension and native motion verification — 10 October 2026

Follow-up to PR #429, rebased onto `ae1d384` (including merged #430 and #432). Development verification: Xcode 27, Swift 6.4, arm64, macOS 27.0.1. No distribution or notarization workflow was used.

## Behavior

World Tension v2 uses on-device reasoning about novelty, proximity to worst case, reversibility and scope of impact. It does not use the v1 casualty formula or relabel its history. Input is limited to a geographically balanced set of current international panel headlines plus earlier novelty context. Repeated headlines are deduplicated. The model returns a bounded report; a fresh model session checks factual support before accepting it. Both checks are heuristic, not independent human validation or calibrated catastrophe probabilities.

Native guided generation refused a peaceful control. Plain JSON and generated per-factor citations were also unreliable. The shipped path uses the existing plain-text model seam, a strict six-field report parser and disclosure of the complete supplied headline snapshot. A draft that paraphrased a ceasefire as a border halt was rejected. A later real-model control was accepted at **20 Mild**, with all four factors and novelty explicitly unknown without prior context, and was persisted/rendered through the production service in **3.88 seconds**.

The sidebar has a static band-coloured dot. Animated illustrations are confined to the tension sheet: a green breathing ensō ring, yellow warmth, a smaller amber flame, a red flame with two embers, and a purple flame with five faster embers. `TimelineView` has no fixed frame interval and stops for Reduce Motion or an inactive scene. Card and reader transitions use native smooth animations; native ScrollView/List momentum scrolling is retained. Sidebar labels no longer swap their view type when loading begins.

Settings uses common 720 × 560 content bounds. Predefined category toggles live in General; they recognize canonical names and explicit legacy aliases without classifying/removing custom section names. The existing unified system toolbar and NavigationSplitView remain responsible for macOS Liquid Glass; no opaque toolbar/sidebar background or simulated glass was added. Apple documents automatic system adoption in [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## Completed checks

- Full `./test.sh` regressions: passed. New checks cover report shape, factor uniqueness, score bounds, current-headline requirements, repeated-headline selection, rejected model support, AI/collection policy before warm cache, daily replacement, reopen persistence and clearing derived AI history without deleting source articles.
- `script/test_native_ui_qa.sh`: **160 checks, zero failures**.
- Final arm64 `build_release.sh`: passed with sandbox entitlements and ad-hoc signing.
- Isolated native runtime harness: **27 Settings tab changes**, constant content/window size; five-state light/dark captures; reduced-motion and inactive-scene frame captures remained identical after 500 ms; live on-device acceptance, persistence and rendered sheet.
- Installed Settings: twenty tab changes retained the same 1440 × 1296 pixel captured window bounds. Native list scrolling was exercised without opening or marking stories read. The installed toolbar visually used the system glass controls and sampled sidebar background.
- Display-link probe over three seconds per request: at requested 60 Hz, 179 callbacks; at requested 120 Hz, 180 callbacks. Both p50/p95 intervals were **16.666 ms** on the connected **60 Hz** display. Callback cadence is not proof of GPU presentation FPS. Actual 120 Hz rendering needs a 120 Hz display.

Reproduce the isolated live probe with:

```sh
NEWS_NATIVE_HARNESS=Tests/NativeWorldTensionQA.swift ./script/native_performance_baseline.sh /private/tmp/world-tension-qa
```

It uses temporary SQLite/preferences and synthetic headlines. It needs an active Mac desktop, available Apple Intelligence and no power/thermal deferral. Outputs include captures, a cadence JSON report and the accepted assessment. It never reads the installed library.

## Follow-up on 11 October

The lowest band is now **Zen**, with a green open ensō ring, breathing halo and central seed. A live library-copy diagnostic revealed unsupported novelty and international-scope claims; these drafts were rejected rather than stored. The report now reasons before choosing a number, limits the input to 12 current and 8 previous headlines, restricts prior context to the same existing event clusters and treats missing comparable history as unknown novelty, and accepts harmless bold label markup while retaining the six-field contract. Reassess uses the sheet’s cancellable task. Sidebar status is kept to a stable single-line caption; detailed failure reasons remain in the sheet. The latest main loading bubble now respects Reduce Motion and the shared transition token.

The frozen installed-library copy still produced unsupported reasoning after event-matched prior context was introduced; these readings were rejected. Focused factor-by-factor generation also failed the contract and was not added to production. Successful synthetic controls do not establish reliable real-world reasoning. This remains an experimental feature, and no current score is shown when the native model cannot produce supported reasoning.

## Verification limits

macOS 15 was a compilation target, not a runtime test. Spoken VoiceOver remains parked (#268). Actual 120 Hz presentation and compositor hitch profiling were not verified on this 60 Hz machine. The native toolbar delegates clear/tinted glass rendering to the system; both ends of the system transparency slider were not manually tested. The installed app retained sidebar symbols after three keyboard-driven Mission Control cycles. This verifies their final state, not every transition frame or the exact trackpad gesture; stable label identity and monochrome symbols address the app-controlled redraw path without establishing absence of an OS compositor regression.
