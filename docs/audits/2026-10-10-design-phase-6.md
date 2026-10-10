# Design phase 6 — isolated implementation and verification

Issue: [#356](https://github.com/marspater/NewsApp-macOS/issues/356). Scope: only optional image-backed first Today/Briefing story, concentric geometry and the conditional floating-controls rule. No feed ranking, data migration, Web controls, other design phases or issues were changed.

## Behavior contract

- macOS 26+: choose the **first existing ordered** Today or Briefing entry with a usable publisher image. This can be a grouped event with an image among its visible member publications. Retain the same representative, article actions, event coverage, keyboard navigation, read/saved state and entry IDs.
- Full-column-width image (not the centered 1000-point content measure). Only the **decoded image** receives `backgroundExtensionEffect()`. Headline, metadata, reading status and all controls are over the image, inside the content column, on an opaque dark caption scrim with a `ConcentricRectangle` bottom edge.
- Pending image: keep the lead's fixed height to avoid a download-time jump; failed image: retain the same lead slot height while showing the ordinary editorial card without a second request. No image, macOS 15, Search, Unread, Saved Stories or History: the existing standard card.
- Reuse `ArticleRemoteImage` and its protected HTTP/image cache. The content layer has no `glassEffect`; Web back/forward are existing toolbar controls, so no floating Web/media overlay is introduced.

## Verification on a macOS 27 Apple Silicon desktop

These are **required manual acceptance gates**, not evidence of completed observations:

1. `./script/design_lint.sh && ./script/test_native_ui_qa.sh && ./test.sh` on an Xcode 27 environment. Compare compiled macOS 15 availability and macOS 26+ image behavior; do not infer old-runtime coverage from a newer SDK.
2. `./script/native_performance_baseline.sh /tmp/phase6-text`, then `NEWS_NATIVE_LEAD_STORY=1 ./script/native_performance_baseline.sh /tmp/phase6-image`. The second mode seeds one mock publisher image, uses an injected offline loader and samples the same 10,000-story MainView. Compare `window_to_first_card_bitmap_ms`, `scroll_frame_capture_ms` and `peak_process_rss_bytes` between the two runs, against a before-phase baseline collected with the same machine/settings. A missing/non-scrollable detail scroller or missing scroll-frame sample **fails the benchmark** (exit status 1); never interpret zero samples as a pass. Do not claim no regression without repeat runs and acceptable variance.
3. Inspect 900 × 600, 1100 × 800 and ultrawide windows in list and grid, grouped and ungrouped, hero in first and later positions, event member fallback, loading/failure, scrolling and queued updates. Ensure image extension is clipped behind the sidebar, while the caption, its actions and floating updates pill stay above it and within the detail column.
4. Compare light/dark, Increase Contrast, Reduce Transparency, Reduce Motion, inactive window, fullscreen and both ends of macOS 27 Liquid Glass transparency. Confirm card accessibility labels, named context/accessibility actions, pointer hover and keyboard J/K/E/Return remain usable; VoiceOver live spoken QA stays parked under #268.

## Known constraints

- The offline Linux development environment cannot compile macOS SwiftUI or run the native desktop matrix and first-card/scroll benchmark. No screenshot, CI status, native performance number or no-regression result is claimed here.
- Prerequisite design phases 2–5 still have independently open acceptance items. This implementation does not close or alter them.
- Any actual measured regression or image-under-sidebar overlap must be corrected before treating issue #356 as accepted.
