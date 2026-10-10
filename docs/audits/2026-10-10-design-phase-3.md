# Design phase 3 · sidebar, toolbar search and states

Date: 2026-10-10. Tracking issue: [#353](https://github.com/marspater/NewsApp-macOS/issues/353).

## Scoped slices and merge order

1. [#361](https://github.com/marspater/NewsApp-macOS/pull/361), **merged on main**: native sidebar `Label` / `.tag` / `.badge`, mini refresh progress.
2. [#394](https://github.com/marspater/NewsApp-macOS/pull/394), base `main`: masthead announcements for successful feed/OPML operations and existing alert for failures; no temporary sidebar confirmation row; + button and Suggested preserved.
3. [#395](https://github.com/marspater/NewsApp-macOS/pull/395), base `mars/phase3-confirmations`: one trailing-toolbar searchable field with operator chips. The archive database still parses the effective query via `ArticleFilterQuery`.
4. Final states slice, base `mars/phase3-search`: `ContentUnavailableView` for empty lists, search, query errors and feed errors; contextual Retry/Show Muted actions; diagnostic descriptions behind disclosure.

Stack must land in order. No changes to phases 1, 2, 4, 5, 6 or 7, the reader, database schema or saved/read storage.

## Verification evidence and limits

- Source inspection: sidebar still uses the existing `List(selection:)` navigation, no new button wrapper, badge drawing or row font; no change to ⌘1–⌘4 notification routes or list keyboard handler.
- The existing `ArticleFilterQuery` parser still handles `is:read`, `is:unread`, `is:saved`, `source:` and `category:`; converted token expressions are joined with the free-text query. Added deterministic tests for token-only and mixed queries, incomplete prefixes and value filters.
- No new design-lint exceptions or glass surfaces were introduced. The sidebar add-feed control and Suggested section remain.
- Local run, 2026-10-10, Apple silicon, macOS 27.0.1, Xcode 27.0 (Swift 6.4), after rebasing the stack on `main` at `2542462`: `swift build`, `script/design_lint.sh`, `script/test_native_ui_qa.sh` and the full `./test.sh` passed at each slice tip. `build.sh` produced an ad-hoc signed arm64 bundle in a staging copy.
- That run found and fixed: `build.sh` and `build_release.sh` did not compile `ArchiveSearchToken.swift`; the design-lint baseline was not lowered after the literal font sizes were removed; a repeated identical masthead notice kept the earlier five-second timer and skipped its announcement; unreadable drops were consumed silently; several chips for one filter showed although the parser keeps only the last; promoting a chip removed the space after free text, so the next word joined it.
- Isolated launch (`script/run_isolated.sh --seed`, separate container, macOS 27 only): `report is:unread ` became an `is:unread` chip plus free text and returned archive results; a later `is:read` replaced the `is:unread` chip; a query without matches showed the system no-results view without a refresh action. Masthead notices, drop alerts, feed-failure and empty views were not exercised live.
- Hosted CI, macOS 15/26, VoiceOver and appearance/performance runs remain pending; they are not reported as passes.
- No user installation, migration, live publisher requests or user library access were performed.

## Required on-device acceptance checklist

- [x] Run `script/design_lint.sh && script/test_native_ui_qa.sh && ./test.sh` on Apple silicon.
- [ ] Build and launch in an isolated ad-hoc signed staging directory on macOS 15, 26 and 27 where available (macOS 27 done).
- [ ] Confirm sidebar sizes small/medium/large, selection and arrow keys, ⌘1–⌘4, + and Suggested.
- [ ] At 900 pt and wide layouts, check search at toolbar trailing, overflow and search suggestions; opt into minimization only if 900 pt is crowded.
- [ ] Search the archive from Today, Saved, History and reader, using free text alone, each of the five token operators and combinations; removing a chip restores previous results. Search no-results must name the query and not suggest feed refresh.
- [ ] Drop valid, duplicate and malformed OPML; subscribe valid/duplicate/invalid URLs. Successful feedback appears in the masthead and VoiceOver announcement, failures use an alert and never add a list row.
- [ ] Check empty and feed-error views with Retry, collapsed technical details and no custom empty-panel backgrounds.
- [ ] Light/dark, Increase Contrast, Reduce Transparency, Reduce Motion, inactive/fullscreen window, keyboard and VoiceOver runtime checks.

Do not check off the issue's final acceptance list or close #353 until the stack is merged and these runtime gaps are addressed.

## DESIGN.md §19 review

- [x] New UI uses existing typography/spacing tokens; no literal font/height/color/radius additions.
- [x] No nested glass, sidebar/toolbar painted background or forced scroll-edge styles.
- [x] Native search field, native sidebar rows, system empty/failure states.
- [x] Copy distinguishes search-no-results from feed failure; technical detail is disclosed on request.
- [ ] macOS appearance, system sidebar size and 900 pt acceptance matrix not yet observed.
- [x] Isolated arm64 build verified locally.
- [ ] Hosted CI not yet verified.
