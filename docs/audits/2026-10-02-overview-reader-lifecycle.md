# Overview reader lifecycle after #219 — 2 October 2026

Refs #218, #155, #95. Base: `02a5bb0`.

## Findings in the merged wiring (#219)

- **Auto-switch.** When an overview finished generating, the reader set `experienceMode = .eventOverview`. A reader opening an article from an event was moved off the publisher's text mid-read, and out of the web view if it had been opened. While the next event's overview loaded, the previous event's overview could stay on screen for a different article.
- **Closing clears the wrong event.** `onDisappear` called `setVisibleEvent(eventID: nil)` from an unstructured task. If it ran after the next reader had made the same event visible, it cancelled that reader's generation.
- **Late queue cancel.** `cancel(eventID:)` cancelled the queue job from another unstructured task. A request for the same event made right afterwards could be cancelled by it. This was noted as a risk in #216; #219 made it reachable in normal use.

In both lifecycle cases the overview silently did not appear until the article was reopened.

## Fix

- **Reader:** stays on the publication when an overview becomes ready; the toolbar offers it.
  - It returns to the overview by itself only when it was already showing one (J/K into another event) and the web view is not open.
  - The overview of another event is cleared as soon as the opened article belongs to a different event.
- **Visible event owner:** each reader passes an owner token. `clearVisibleEvent(owner:)` changes nothing unless that reader set the visible event. The reader uses it on close, and when an opened article is not in an event.
- **Cancellation:** `cancel(eventID:)` is `async` and awaits the queue cancellation before returning.
- **Test accessor:** `visibleEventOwner()` is read-only and lets tests wait on observable state.

No schema change.

## Verification

The authoring environment was a Linux container without a Swift toolchain. Nothing was compiled or run locally; macOS CI provides compile and test results. The view change has no automated test and belongs to the native check in #155.

- `testOverviewGenerationCancellationAndSupersession` gains two cases (full suite and `--story-regressions`), with the queue held by gated jobs:
  - **Closing reader:** one reader closes after a second reader made the same event visible. The second reader stays the visible owner, its generation stays in flight, and it receives and stores the overview.
  - **Request after cancel:** a request made right after `cancel(eventID:)` returns completes. This states the contract; it does not reproduce the old timing race deterministically.
- tree-sitter-swift parse matches the base. `python3 script/evaluation/evaluate.py` and `git diff --check` passed.
