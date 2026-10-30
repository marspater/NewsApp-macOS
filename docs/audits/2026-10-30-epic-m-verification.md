# Epic M verification on main (30 October 2026)

Epic M (#574) merged as one stack of 21 pull requests (#617 → #701, with Epic T's #705 on top) on 30 October 2026. This file records the check of `main` at `83d5046` after the merge, the fresh library holdout built on 29 October that every later matcher slice is measured against, and what is left for later work.

## Checks on main

Run on an Apple M5, macOS 27.2, from a clean worktree at `83d5046`.

| Check | Result |
| --- | --- |
| `script/format.sh --check` | clean |
| `NEWS_TEST_FORCE=1 ./test.sh` | all tests passed |
| `./build.sh` | app built and signature verified |
| `./test.sh --matcher-regressions` | v13: precision 1.000 (TP 23, FP 0), recall 0.920 (FN 2) |
| `NEWS_ENERGY=0 ./test.sh --matcher-regressions` | TP 0, FP 0, 28 rows deferred to a pass with energy (by design, #534) |
| `./test.sh --story-regressions` | 23 event pairs, 31 story pairs; known gaps 8 event, 4 story |
| `--event-corpus`, tune | precision 1.000 (TP 45, FP 0), recall 0.260 |
| `--event-corpus --corpus-holdout` | precision 1.000 (TP 39, FP 0), recall 0.494 |
| `--library-holdout`, fresh set, cutoff 0.90 | see below |

GitHub Actions' `Test (macOS 26, Apple Silicon)` failed on `main` from the stack's merge onward. The runner's compiler could not type-check the holdout-window fixture in `testEventCorpusHarness` in time (358 ms on an M5). #736 types the offsets; with it no expression in Sources or Tests takes more than 150 ms to type-check.

## Fresh library holdout (29 October 2026)

The 24 October holdout was retired on 27 October after many reads. The fresh set comes from the only library that kept refreshing, the News Relation Check test build (41 feeds).

- Library copy: `~/news-eval/library-2026-10-29.sqlite3` (read-only, journal mode delete), 8,145 articles, newest 29 Oct 18:00:35 UTC, SHA-256 `2958d7feeb210643bd79b1ac19cca4094157a1e2392ac59129ae7945d8bd7f9c`.
- Candidates: the copy re-clustered from scratch at matcher v13 (four passes), then `--review-pairs --holdout-candidates`: 219 pairs, 100 borderline, 59 singletons, 60 fragment pairs. Every article was published between 26 Oct 18:43 and 29 Oct 17:54 UTC, after the newest training article (25 Oct 18:05), so no training row overlaps.
- Labels: an agent that trained nothing labelled the pairs under the pair review protocol in CONTRIBUTING: 81 same, 13 related, 125 different. The coordinator's blind spot-check of 30 rows (the first twenty and ten singletons) agreed on all 30. The 27 October Israeli election dominates the borderline class (75 of its 100 rows are `same`).
- File: `~/news-eval/holdout-2026-10-29/library-holdout-2026-10-29.json` (`0600`), SHA-256 `a0b681bc58d12bb1cc1b823b0bb626494a5a56afb4db57319fe2663ca8bb3545`. Clock pin `NEWS_HOLDOUT_NOW=1793300435` (29 Oct 19:00:35 UTC).

Baseline at matcher v13, pair cutoff 0.90, prefix off. The strict and story results were identical on the stack tip on 29 October and on `main` on 30 October: three reads, all at this one setting. The library line below is from `main`; the stack tip counted 3,193 recent stories, 38%.

| Measure | Result |
| --- | --- |
| Strict event | 12 linked = 6 same, 3 related, 3 different; precision 0.500, recall 0.074 (6 of 81) |
| Story level | 14 in one story = 7 same + 3 related, 4 different; precision 0.714, recall 0.106 |
| Library | 3,165 recent stories, 39% in a multi-publisher event; 1,263 (40%) in a multi-publisher story |

The shipped model does not reach the 0.97 precision gate on this set, as it did not on the retired one (0.533 at v11). No model or cutoff changed.

## Performance baseline

`./test.sh --performance-baseline` (median ms) on `main`, against the 2 October investigation budgets:

| Operation | main `83d5046` | Budget |
| --- | ---: | ---: |
| Unchanged clustering pass | 13.8 | 16 |
| Refresh collection, nine repeats | 415.7 | 720 |
| Dense clustering, 200 reset rows | 20,233 | 20,200 |
| Overview generation | 35.9 | 33 |
| Snapshot hydration, first 500 | 75.6 | 100 |

The story pass (#581) runs only when a clustering pass processed a report or changed an event, once per launch, and after a reader verdict, so an unchanged archive stays at zero work. Before that change, the unchanged pass took 13 s on the stack tip. The dense stress pass now pays for the story pass on a fixture whose rows share generic wording, and is 33 ms over its budget. Overview generation is above its budget. Both belong to #543 and #691.

## Spot-checks of the 24 October files

The 20-pair spot-checks noted as pending in `2026-10-24-pair-decision-review.md` and `2026-10-24-library-clustering-diagnosis.md` were not done. The pair review fed #688 instead (same-publisher false merges on the sample fell from 7 of 8 to 2 of 8). The 24 October holdout was retired on 27 October, before any spot-check, and the fresh set above was spot-checked by the coordinator. On 27 October Mars delegated spot-checks of Claude-labelled sets to an independent reviewer.

## Acceptance as measured

- #551: the review tooling shipped. False merges were 6.5% for rule matches and 21% for pair-model confirmations, against the ≤ 2% target; the findings drove #688 and the pair-model program.
- #580: holdout precision 0.667 against ≥ 0.97, with no new wrong link. Superseded by v13.
- #581: shipped (schema v27, one card per story, newest-event open, "Earlier in This Story", wording in DESIGN.md, story regressions). The recall targets were not met: only Eagle's Nest became one card, the multi-source share is 39% against 60%, and 24 groups were reviewed (0 wrong) against 100. The targets moved to #737.
- #552: the gate reads the verdicts stored in the library copy. `verdicts.csv` is a training export.
- #583: same-publisher duplicates alias within 12 hours, not 24, so a daily series with one recurring headline stays separate.
- #625: the before-and-after false-confirmation round was not recorded. No retrained model passed the gate, so none shipped.
- #624, #626, #627, #628: measured and not adopted. Every knob is off by default, and the shipped weights are unchanged.

## Left for later work

| Item | Issue |
| --- | --- |
| Story recall: country-only stories; multi-source share 39% against 60% | #737 |
| Third-report carry-in through the two-thirds compatibility rule | #738 |
| Dateless same-publisher round-ups ("Deals: …") merge across days | #739 |
| Notify once per story, not once per event of a story | #740 |
| Named-storm false merge (Storm Boelo inside Storm Austen) | #741 |
| Evaluation replays fit the verdict calibration once, not per step | #742 |
| "Earlier in This Story" is capped at three links | #671 |
| README still says matcher v11 and "zero false pairs" | #569 |
| Performance budgets after the story pass | #543, #691 |
| Active-work cancellation test flaky under load | #692 |

## Accepted limitation: replay calibration (#742)

Evaluation replays (`reclusteredLibraryCopy`, the library-holdout run) fit the verdict calibration (#629) once, from the copy's final verdicts, and apply it at every replay step. Production fits only from the verdicts that exist at the time. This is accepted for v2:

- The calibration stays dormant until there are at least 50 usable calibration rows (verdict pairs whose stored pair-model features come from the current matcher version) containing both "same" and "not same" verdicts (`PairCalibration.fit`, `calibrationRows()`). No evaluated library reaches that (the 29 October copy has no verdicts), so every replay so far ran without it.
- Refitting per step needs article identity on `PairCalibration.Row` and stored features for excluded pairs the replay never scores.

Revisit when a library that meets that condition is evaluated; until then a replay result is not affected.
