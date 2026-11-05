# Recall levers on the 3 November holdout (#737, 5 November 2026)

Follows [the story country measurement](2026-11-03-story-country-place-veto.md), whose next lever was event-level recall: strict recall on the 3 November holdout is 0.105 (4 of 38 `same` pairs in one event). This measures two admission knobs and the existing pair cutoff override against that holdout. No default changes.

## Knobs

All are off by default and read only by the test runner (`Tests/StoryCorpus.swift`, `policyFromEnvironment`), also by `--event-corpus`, `--matcher-regressions` and `--story-regressions`.

- `NEWS_VETO_MIN` (integer ≥ 1) and `NEWS_VETO_SHARE` (0…1), in `EventMatcher.conflictsBlock`, used by `eventScore(pairs:)` and the fragment merge: a `semanticDivergence` or `places` conflict from a cross pair blocks admission only when at least `MIN` cross pairs, or more than `SHARE` of them, raise one. A tolerated veto pair stays in the two-thirds denominator as incompatible; every other conflict stays absolute.
- `NEWS_BORDERLINE_FLOOR` (0…1) and `NEWS_BORDERLINE_NAMES` (default 3), in `EventMatcher.applyingBorderlineFloor`, applied after the pair-model step: a non-match pair the model scores below the floor and that shares fewer specific names than the minimum is not compatible. Pairs the model never scored are untouched.
- `NEWS_PAIR_THRESHOLD` (existing, #582): the pair-model admission cutoff, 0.90 shipped.

## Method

- Holdout: `~/news-eval/holdout-2026-11-03/library-holdout-2026-11-03.json` (218 pairs: 38 same, 43 related, 137 different; SHA-256 `40708d89…c9ed`), clock pin `NEWS_HOLDOUT_NOW=1793642173`, matcher v15, pair-model prefix off.
- Each run re-clusters a fresh `0600` copy of the holdout's re-clustered library (`recluster.sqlite3`) from scratch; one run at a time. The baseline was reproduced on a clean `origin/main` build (6a0a9dd) and on the knob build with no knob set: identical.
- Every setting also ran `--matcher-regressions` and `--story-regressions`.
- Pair ids come from `NEWS_EVENT_DIAGNOSE=1` runs (baseline, c, g) and, for the other settings, from the event and card each article lands in (`NEWS_EVENT_OUTPUT` `story-cards.csv`); the two methods agree on every pair whose articles both appear among the cards. Five pairs (15, 24, 35, 56, 144) have an article outside the recent cards; for them the diagnose runs (baseline, c, g) are the only direct evidence, and b, e and f are inferred from the counts.
- Story groups are compared with the 9 independently labelled groups of 3 November.

## Results

| Run | Strict same / related / different | Strict P / R | Story s+r / different | Story P / R | Multi-publisher share (of 1,436) | Groups (wrong) |
| --- | --- | --- | --- | --- | --- | --- |
| a baseline | 4 / 5 / 3 | 0.333 / 0.105 | 12 / 3 | 0.800 / 0.148 | 442 | 7 (0) |
| b `NEWS_VETO_MIN=2` | 10 / 5 / 4 | 0.526 / 0.263 | 18 / 4 | 0.818 / 0.222 | 447 | 7 (0) |
| c `NEWS_VETO_SHARE=0.34` | 12 / 7 / 4 | 0.522 / 0.316 | 20 / 4 | 0.833 / 0.247 | 450 | 7 (0) |
| d `NEWS_BORDERLINE_FLOOR=0.5` | 4 / 5 / 3 | 0.333 / 0.105 | 12 / 3 | 0.800 / 0.148 | 442 | 7 (0) |
| e `NEWS_PAIR_THRESHOLD=0.85` | 6 / 5 / 3 | 0.429 / 0.158 | 13 / 3 | 0.812 / 0.160 | 444 | 6 (0) |
| f c + e | 14 / 6 / 4 | 0.583 / 0.368 | 22 / 4 | 0.846 / 0.272 | 453 | 6 (0) |
| g f + d | 13 / 6 / 3 | 0.591 / 0.342 | 21 / 3 | 0.875 / 0.259 | 451 | 6 (0) |

Matcher regressions are unchanged in every row (precision 1.000, TP 24, FN 2, no false pair; story v15 with no unexpected link) and the story regressions pass. No setting joins stories across countries.

## Pair ids

Baseline strict: same 5, 43, 70, 83; wrong related 20, 63, 72, 93, 99; wrong different 44, 73, 90. Baseline story level adds related 3, 22, 51.

| Run | Strict same gained | Strict wrong added | Story right gained / lost | Story different added |
| --- | --- | --- | --- | --- |
| b | 10, 33, 34, 67, 71, 78 | different 24 | same as strict / none | 24 |
| c | 10, 12, 33, 34, 67, 71, 78, 94 | different 24; related 22, 51 (already in one story at baseline) | same as strict / none | 24 |
| d | none | none | none / none | none |
| e | 6, 75 | none | 6, 75 / related 3 | none |
| f | 6, 10, 12, 33, 34, 67, 71, 75, 78, 94 | different 24; related 21 | same + related 21 / related 3 | 24 |
| g | 6, 10, 12, 33, 34, 67, 75, 78, 94 | related 21 | same + related 21 / related 3 | none |

- The one extra wrong link under b, c and f is pair 24 (a borderline different pair, The Guardian and BBC News): confirmed under c by diagnose; under b and f inferred from the count, the other off-card `different` candidates (15, 144) being unlinked under c and g. It is linked at the event level, so it also counts at story level. Its pair-model score is 0.08 with two shared specific names, so the floor in g removes it.
- The floor also costs g one same pair, 71 (pair-model score 0.16, one shared name), which c and f had linked.
- Raising the cutoff to 0.85 (e, f, g) separates the two events behind related pair 3 at story level while it adds same pairs 6 and 75 and related pair 21 (f, g).
- The floor changes nothing alone (d): of the 8 baseline strict wrong pairs, 6 score at least 0.5 on the pair model (0.49–0.83), one below it shares 3 names (exempt), and one (0.10, one name) stays linked through a larger event.
- Groups: g forms 6 story groups, 4 in the labelled set and 2 outside it; the 2 are the same groups the first g run formed, grown variants of two groups labelled right (checked by the coordinating agent, not independently labelled).

## Why the pair model misses (feature dump)

Pairs 5, 28, 8 and 21 share one article. The shipped `pairscorer.mlmodelc` was scored in Python via coremltools (parity with Swift: pair 5 0.106 against 0.099, pair 28 0.027 against 0.027).

- The shared article is a newsletter edition: a title with a ` | <series>` suffix and a 1,519-character multi-story digest body; pairs 5 and 8 hit the 256-token cap.
- Baseline scores 0.106 / 0.027 / 0.018 / 0.059. Removing the title suffix alone lifts them to 0.416 / 0.423 / 0.306 / 0.706. Titles alone score at most 0.023 for all four.
- Single-word occlusion: the `|` separator is the strongest riser (+0.37 on pair 5, +0.54 on pair 21), followed by words from the digest's other items and its sign-up line. Removing the shared names lowers the score, so they are not what holds it down.
- The model is order sensitive (pair 5: 0.195 forward, 0.018 backward).
- Pair 5 is linked at baseline through other members despite its pairwise 0.10; pair 28 is the real miss.

So the newsletter format (series suffix and digest body) crushes the pair-model score; no tabular feature does.

## Gate verdict

Against the CONTRIBUTING gate (strict same does not fall, strict different does not rise, story different falls, story recall rises):

- b, c and f fail: strict and story `different` rise by one (pair 24).
- d and e change no wrong link, so story `different` does not fall; e is a small recall gain only.
- g passes three of four (strict same 4 → 13, strict different level at 3, story recall 0.148 → 0.259) but story `different` is level at 3, not down. It does not pass. With 6 to 7 story groups per run, 0 wrong groups also cannot show ADR-001's ≤ 2 % wrong-group ceiling.

No knob or default changes; the knobs stay as evaluation overrides and the matcher version is unchanged. #737 stays open.

## Next lever

Strip a newsletter series suffix (` | <series>`) and a multi-story digest body from the pair-model input, then re-measure g and the baseline on this holdout. The veto share is the larger recall lever (8 same pairs), but it needs a guard against pair 24's kind of low-score link before it can ship.
