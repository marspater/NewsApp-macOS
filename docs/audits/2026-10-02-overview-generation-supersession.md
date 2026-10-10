# Overview generation: reader closed and article edited mid-generation — 2 October 2026

Refs #154, #98. Base: `455a2d4`.

## Finding

`OverviewGenerationCoordinator.requestOverview` shared in-flight work by event ID alone. An article edit changes the overview's input hash but not the event's membership version. So a request made after an edit:

1. joined the generation still running from the earlier text, and received its overview;
2. let that overview be committed, because both guards (`commitGeneratedOverview`, `recordEventOverview`) compare only the membership version.

The next request then found it stale by input hash and generated again. In the meantime, the reader showed and stored an overview of text the publisher had already changed.

"Reader closed during generation" had a test that called `cancel(eventID:)` but asserted nothing.

## Fix

- A running generation records the membership version and input hash it started from. A request joins it only if both match. Otherwise the request cancels it and starts its own.
- The coordinator records the latest requested inputs per event. A result from other inputs is neither committed nor returned. The existing membership-version guards are unchanged.
- A finished request removes its in-flight entry only if that entry is still its own. Before, it could remove the entry of a newer request.
- `inFlightInputHash(for:)` is a read-only accessor, so tests can wait on observable state.

No schema change. The database guard is unchanged; it stays the second line for membership versions.

## Verification

The authoring environment was a Linux container without a Swift toolchain. Nothing was compiled or run locally; macOS CI provides compile and test results.

- New `testOverviewGenerationCancellationAndSupersession`, in the full suite and `--story-regressions`. It fills the bounded `EnrichmentQueue` with three gated jobs, so requests stay in flight deterministically. A regression fails through `eventually` instead of hanging.
  - **Reader closed:** cancelling returns no overview, leaves nothing in flight and stores nothing.
  - **Article edited:** a second request with edited text at the same membership version replaces the running generation. The original request returns nothing. The edited request receives, and the database stores, the overview of the edited text.
- Reasoned from the code, not run: against the previous coordinator the edit case fails, because the second request joins the first and both return the overview of the earlier text.
- tree-sitter-swift parses the changed files with the same pre-existing false positives as the base. `python3 script/evaluation/evaluate.py` and `git diff --check` passed.
