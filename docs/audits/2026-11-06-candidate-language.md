# One language per report in candidate search (#572, follows #691, 6 November 2026)

**Result: a from-scratch re-clustering drops from 55.65 s to 16.21 s warm and from 83.36 s to 16.96 s cold, with every gate number identical.** `EventCandidateFinder.candidates` now reads each candidate row's language once per pass: from its stored signals at the current version, otherwise recognized from the same text as before. No schema change.

## Method

Same six-run protocol, library copy and Release runner as [the stage audit](2026-11-06-recluster-stages.md): three warm and three cold, alternating, one at a time, each started with no build or suite and a one-minute load below 4. Raw runs are in [the benchmark file](../benchmarks/2026-11-06-candidate-language.json). The before column is that audit's. Load during these runs stayed at or below 4.48, and during the before runs reached 6.38, so part of the cold gain may be load: the fastest cold run before was 58.83 s.

## Results

Medians in seconds on 1,454 recent rows.

| Stage | Warm before | Warm after | Cold before | Cold after |
| --- | ---: | ---: | ---: | ---: |
| Total | 55.65 | 16.21 | 83.36 | 16.96 |
| Candidate search | 41.82 | 5.19 | 65.97 | 5.18 |
| Features | 6.87 | 6.14 | 8.73 | 6.17 |
| Pair model, 642 calls | 2.68 | 2.24 | 2.55 | 1.93 |
| Embeddings | 0.33 | 0.19 | 1.62 | 1.29 |

Load before / after the median run: warm 3.60 / 3.55, cold 3.55 / 4.48. Maximum resident set 338 to 368 MB, peak footprint 154 to 179 MB, about the same as before.

## Stored and recognized language

Stored signals read a differently prefixed text, so agreement is not guaranteed by construction. On this copy, all 1,539 rows with stored signals gave the same language both ways: 0 disagreements. That covers this one library.

## Gate

Identical to the baseline at the default policy in all six runs: strict 4 / 5 / 3, story 12 / 3, 442 multi-publisher stories, 7 groups. `--matcher-regressions`: precision 1.000, recall 0.923, no false pair. `--story-regressions`: passed, nothing unexpected. No pair's linked state changed in these totals; pair-level decisions were not diffed run against run.

## Budget

Per 1,000 recent rows, median plus about 25 %: **14 s warm** (11.1 s measured) and **15 s cold** (11.7 s measured), replacing 48 s and 72 s in `docs/RELEASE_CHECKLIST.md`.

## Stages now above 25 %

Features (38 % warm) and candidate search (32 % warm, mostly `EventMatchKey`'s tagging on the #691 split, not re-split here) are now the largest. Neither has a fix request yet: at this total neither is urgent, and this slice is scoped to the language check.

## Not measured

First-card time, main-thread hangs and refresh waits (no app launch), a larger library, and a strictly idle Mac.
