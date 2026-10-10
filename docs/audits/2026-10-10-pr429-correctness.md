# PR #429 correctness follow-up — 10 October 2026

PR: https://github.com/marspater/NewsApp-macOS/pull/429

The initial validation of `456809d75bfb37973491146fcaf117656aec61de` found three bugs despite passing existing checks. This follow-up fixes them on the same PR. The base was re-fetched before publication and remains `9f540ba347048a0a6d2ac6339756e757132f7db2`.

## Fixes

- The tension paraphrase guard accepted invented events and places, or a reversed band/change/average comparison, provided its numbers occurred in the input. Display the existing deterministic paragraph directly from scored facts and attributed panel headlines. Remove the model path, its acceptance guard and its pre-warm cache.
- A warmed explanation cache returned generated text even with AI disabled, and the sheet's task identity omitted the AI setting. The sheet now derives its text synchronously from its current history; no generated-text cache or asynchronous replacement remains.
- Relative card-date formatting used the wall clock despite accepting a reference time. Use `RelativeDateTimeFormatter.localizedString(for:relativeTo:)` with the supplied `now`.

Regression assertions cover the complete factual paragraph, a changed reading's band and comparison directions, missing comparison data, and relative labels at one minute, two hours and just under one day against a fixed historical clock. Scoring, calibration and stored data are unchanged; the methodology version remains v1.

## Completed checks after the fixes

Host: Apple silicon, macOS 27.0.1, Xcode 27.0 / Swift 6.4. Native builds target macOS 15.0; app builds use Swift 6.

| Check | Result |
| --- | --- |
| `./test.sh` | Pass, including design lint, evaluation self-checks and the new regressions |
| `./script/test_native_ui_qa.sh` | Pass: 154 checks, zero failures |
| `./build.sh` | Pass on retry: complete arm64 app, ad-hoc signing |
| `./build_release.sh` | Pass: optimized whole-module arm64 verification bundle |
| `codesign --verify --deep --strict`, Info.plist lint, architecture | Pass; arm64 |
| `git diff --check` | Pass |

The first app-build attempt was invalidated by a source whitespace edit while compilation was running. Its failure log is retained; the subsequent successful build is the reported result. Logs and final entitlements are in `/private/tmp/news-pr429-fix-results` on the validation host. The commit hook also runs the full regressions before creating the follow-up commit.

## Earlier comprehensive validation and boundaries

At the original PR head, full regressions, both app builds, SwiftPM, 154 native UI checks, 26 reader accessibility checks, 49 overview accessibility checks, native/Python tension calibration and the 16-render appearance matrix passed. Supplemental probes failed four assertions across the three bugs above. The appearance matrix passed on retry after a window-focus capture failure.

Isolated original-head UI interactions verified launch, toolbar/search placement, empty states, all nine Settings tabs, tension-sheet open/close and reopening the main window from Settings. An offline production-view fixture verified explicit refresh applying queued updates, reader sizing/style persistence and W mode cycling. Those interactive/appearance checks were not repeated on this follow-up; the corrected sheet was compiled by the native UI and app builds.

The installed app and real settings/library were preserved. No live publisher audit, sealed holdout, macOS 15/26 runtime, complete minimum-window sweep, clear/tinted glass sweep, Reduce Transparency or scored-sheet live rollover was verified. Spoken VoiceOver remains parked (#268). No installation over the real app, notarization or merge was performed. CI on the original head was successful when refreshed; CI on the pushed follow-up must be checked separately.
