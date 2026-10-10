# Event hard-conflict guards — 10 October 2026

Refs #307; safety correction, not release-precision acceptance. Based on `origin/main` at `1324d7f`.

## Cause and change

`EventMatcher.rejected` removed a thin match but kept it compatible. The borderline-pair path ignored an explicit DIFFERENT verdict. Whole-event admission counted a compatible majority without checking hard conflicts, and fragment merging could pass that majority before checking conflicts; its whole-coverage fallback also tolerated a minority of hard conflicts. These paths could admit a pair the model explicitly called different or contradict a member's period/day/language evidence.

A DIFFERENT verdict now records an incompatible `differentEvent` conflict. Both judge paths use that result. Shared `hasHardConflict` checks protect whole-event admission, fragment merging (before majority/fallback decisions) and confirmation itself. A weak minority with no explicit contradiction remains allowed; soft conflicts can still be settled by the judge. Nil responses preserve deterministic decisions. Matcher version 3 reprocesses recent pending articles under the existing lifecycle; unchanged members retain their events. No existing event is destructively split by a version bump.

## Controlled verification

Synthetic regressions cover an explicit rejected minority, hard temporal/language/exclusion conflicts, permitted weak minorities and soft-conflict confirmation. An in-memory two-fragment fixture forces pair confirmation and supplies one DIFFERENT verdict among otherwise matching pairs; the events must remain separate even when the judge would answer SAME to whole coverage. Existing fragment, exclusion, majority and cancellation coverage stays in the suite. The earlier majority test with contradictory weekdays now asserts rejection, since that was the unsafe behavior being corrected.

- `./test.sh --story-regressions`: passed.
- Full commit-hook `./test.sh`: passed on implementation commit `a3174a4`.
- Isolated `./build.sh`: passed, including optimized Swift 6 arm64 compilation, ad-hoc signing and strict signature verification.
- Strict `swift-format` lint: changed production files passed.
- `git diff --check`: passed.
- Toolchain: Xcode 27.0 / Swift 6.4; macOS 15 deployment target.
- Existing FoundationModels sampling deprecation warnings remain unchanged.
- Publication is recorded in the linked issue/PR progress log. Hosted CI is a separate check; no installed-app or live-network result is claimed. No private holdout, corpus labels, production library, installed app or design files are touched.

## Remaining gate

The 9 October historical replay is not rerun or relabelled. These controlled checks establish the veto rules, not attribution for each historical false merge and not a ≥0.97 precision claim. The model may still incorrectly answer SAME to related acts with no detected contradiction. #307 remains open for the revised matcher freeze, a fresh English sample captured after 9 October, release-precision measurement and Mars acceptance. #314 relation links remain separate from clustering.
