# Native window chrome — 10 October 2026

Issue: #352. Stack: #359 → #360 → completion slice.

## Scope and overlap

The existing list-chrome (#359) and menu (#360) slices already descend from
`origin/main` at `401c90a`; no history rewrite is required. The duplicate #362
was closed. This completion slice builds on #360 (`3093b2f`) and adds only the
remaining phase-two requirements:

- Reader publisher window title without a duplicate toolbar title.
- Refresh visibility priority on macOS 26.1+, separate New Briefing group, and
  inactive-window dimming for the floating updates pill.
- Toolbar equivalents in File, Navigate, Story and View, including Share,
  reader mode/options, link copying/reloading and Web navigation. Commands use
  focused scene bindings/actions for the active list/reader/subscription control.
- Real Shift-Command-R constants and Story/Web/Overview transitions covered by
  NativeUIQAChecks. Single-key reader navigation and list update holding remain
  on their existing paths.

Phase-five text-size persistence and shortcuts, phase-three search placement,
parked VoiceOver QA (#268), and non-English matching (#264) remain outside scope.

## Local validation

Host: arm64, macOS 27.0.1 (26A434), Xcode 27 / Swift 6.4. Deployment target: macOS 15.

- Full `./test.sh`: passed, including design lint and offline regressions.
- `./script/test_native_ui_qa.sh`: 85 checks, zero failures; includes shortcut
  transitions, keyboard handling, Briefing and feed-update buffering.
- Whole-source macOS 15 typecheck: passed. Availability gates compile; this is
  not runtime evidence on macOS 15.
- Staged arm64 app build with ad-hoc signing: passed; strict signature verified.
- Glass helper examples compiled in Swift 5 and 6 with a macOS 14 target, checking
  the older-system guards without changing the production deployment target.
- Diff whitespace check: passed. Design lint remains at the inherited 118-item
  baseline; this slice adds no new baseline allowances.

## Isolated production-app checks

Launched a staged production bundle under `com.marspater.news.phase2qa` with a
synthetic SQLite library, disabled AI/notifications and a reserved `.invalid`
feed. The installed app and its settings/library were not replaced.

Observed through native accessibility state and screenshots:

- List and grid choices in View update the toolbar selection.
- Narrow main window (900-point width) retains visible Refresh and native
  list/reader controls; the toolbar uses system layout rather than a custom
  overflow control. The separate NSHostingView baseline does not include the
  production Scene toolbar, so its PNG alone is not toolbar evidence.
- Reader window title follows the publisher. Shift-Command-R selects Web, then
  Story; Command-J moves to the next story, Command-S saves, Escape returns.
- Read/save state survives return to the list. Briefing retains its selected
  membership after reading (1/10); Navigate → New Briefing recomputes unread
  membership (0/10).
- Story exposes Share and the reader actions. Help → Keyboard Shortcuts opens a
  separate window; its Back/New Briefing commands are disabled outside the main
  scene. File → Add Feed Subscription opens the existing toolbar popover and
  Cancel dismisses it without adding a feed.

No real publisher/network, installation or merge validation is claimed.

## Performance comparison

The existing native baseline was compiled from immutable main, PR360 and the
completion snapshot. Precompiled binaries were then run sequentially, with
balanced ordering and no concurrent compiler. Every bitmap sample completed;
each mocked refresh inserted exactly one story (10,001 final rows). All raw
samples are retained in [the benchmark report](../benchmarks/2026-10-10-native-window-chrome.json).

| Comparison run | Source | Median first card (ms) | Peak RSS (MiB) |
| --- | --- | ---: | ---: |
| comparison-base360-0 | PR360 3093b2f | 645.1 | 275.3 |
| comparison-base360-1 | PR360 3093b2f | 585.6 | 267.8 |
| comparison-before-4 | main 401c90a | 697.1 | 263.1 |
| comparison-before-5 | main 401c90a | 581.8 | 262.8 |
| comparison-final-0 | completion 5409716 plus selection guard | 578.2 | 271.6 |
| comparison-final-1 | completion 5409716 plus selection guard | 674.5 | 270.8 |

Earlier balanced runs measured main at 448.9/451.1 ms versus completion at
479.4/474.9 ms, with roughly 15 MiB additional peak RSS. Later runs above have
substantial host-load variance and overlapping timing distributions. The final
selection lookup now exits before scanning stories when none is focused. PR360
already shows most of the observed memory increase; no storage/refresh algorithm
changed in this phase.

**The no-regression acceptance is not established.** Do not turn the script's
successful rendering/storage result into a passing performance gate. Repeat on
an idle desktop and investigate any reproducible difference before closing #352.
This NSHostingView/Vision observation is not cold launch, live-feed, scrolling
latency, production Scene toolbar rendering or GPU profiling.

## Remaining runtime checks

The complete appearance matrix (light, dark, clear/tinted glass, Increase
Contrast, Reduce Transparency, Reduce Motion, inactive updates pill) and
full-screen hover behavior are not fully verified. The automated settings
checks do not replace those visual checks. macOS 15/26 runtime checks require
another machine and were not run. Spoken VoiceOver QA stays parked in #268.

The phase remains In review until its acceptance evidence and merges are
complete. Hosted CI results are separate from these local checks.
