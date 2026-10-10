# Related-event backend — 10 October 2026

Refs #314; backend slice only. Based on `origin/main` at `1324d7f`.

## Implemented

`ArticleStore.relatedStoryEvents(eventID:)` returns experimental navigation candidates without writing to storage. Merge forwards resolve to live IDs. The database snapshots member metadata and bounded FTS candidates; cancellable feature extraction runs in a detached utility task outside the main and database actors.

A candidate's publications must all predate the target's first publication by no more than 72 hours. Both sides need known dates and English features. Pair evidence needs a typed actor (person or organization), a local place and at least two non-anchor topic terms. Explicit contradictory countries, periods and years reject the pair. At least two thirds of each event's members must have direct support from the other event. No graph traversal, event merges, model calls, migrations or generated wording are involved.

Bounds: 80 FTS rows, 40 distinct candidate events, 101 metadata rows per event with rejection above 100 members, three returned links. Newest first, event ID breaks ties. The date is first publication, not a claim about when the occurrence happened.

## Verification

The regression checks actor/place/topic requirements, language and factual conflicts, the inclusive 72-hour boundary, direction, majority support, stable order and the three-link cap. In-memory SQLite integration checks FTS retrieval, inactive events within the publication window, merge forwards, missing IDs, unknown publication dates, and unchanged memberships/read/saved state. Cancellation has a deterministic self-cancelled check. Registered in both the full suite and `--story-regressions`.

- `./test.sh --story-regressions`: passed on the initial implementation.
- `./test.sh`: passed on the final backend implementation; includes the relation regression and repository Python/design checks.
- `git diff --check`: passed.
- Strict `swift-format` lint passes for the changed production files; the test file reports seven existing findings (five block comments and two `forEach` loops), reproduced on `origin/main` with no new findings.
- Toolchain: Xcode 27.0, Swift 6.4, arm64, macOS 15 deployment target.
- An initial sandboxed test compile could not run Apple's compiler macros; the native run outside that restriction passed.
- `./build.sh`: source-stable rerun passed; isolated optimized arm64 app, Swift 6, ad-hoc signing and strict signature verification. The first build was rejected after a comment changed during compilation.
- Existing FoundationModels sampling-initializer deprecation warnings are unchanged.
- No installation, production launch, live network relation audit or hosted CI result is claimed.

## Remaining acceptance

This does not close #314. Reader links are intentionally absent in this backend slice. Reviewed timeline notes retain their `different` clustering labels; those notes are not automatically relation-negative labels. A separate relation review needs both related positives and hard unrelated controls, followed by a measured wrong-link rate before reader exposure. No private corpus, sealed holdout, production library, installed application or design changes were modified or evaluated. #307's clustering release gate is still open.

This conservative rule misses events without a typed actor/local place, overlapping reporting windows and unknown dates. The first target publication seeds FTS; repeated coverage can exhaust the bounded candidate rows. The results describe a snapshot: future navigation must resolve its IDs again after membership changes or retention. Synthetic regression success establishes mechanics, not real relation precision.
