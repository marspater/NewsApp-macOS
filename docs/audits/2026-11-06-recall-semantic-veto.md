# Semantic veto and two-member admission on the 3 November holdout (#737, 6 November 2026)

Follows [the edition admission audit](2026-11-06-recall-edition-admission.md). **No setting passes the gate.** No default changes, and the two-member knob was not kept in the code.

## Method

`~/news-eval/holdout-2026-11-03/library-holdout-2026-11-03.json` (218 pairs), a fresh `0600` copy per run, `NEWS_HOLDOUT_NOW=1793642173`, matcher v15, diagnose on, one run at a time. Setting g is `NEWS_VETO_SHARE=0.34 NEWS_PAIR_THRESHOLD=0.85 NEWS_BORDERLINE_FLOOR=0.5`. Pair numbers are 0-based.

The two-member knob, measured and then removed: a report matching one member of a two-member event joins it when its only objection to the other is `semanticDivergence` and they share a specific name. It was chosen from the g + 0.5 verdicts on pairs 75 and 130, each refused a two-member event by one such veto.

## Results

| Run | Strict same / related / different | Strict P / R | Story s+r / different | Story P / R | Multi-publisher | Groups |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 4 / 5 / 3 | 0.333 / 0.105 | 12 / 3 | 0.800 / 0.148 | 442 | 7 |
| two-member | 4 / 3 / 3 | 0.400 / 0.105 | 9 / 3 | 0.750 / 0.111 | 444 | 7 |
| g | 13 / 6 / 3 | 0.591 / 0.342 | 21 / 3 | 0.875 / 0.259 | 451 | 6 |
| g + two-member | 13 / 5 / 3 | 0.619 / 0.342 | 18 / 3 | 0.857 / 0.222 | 453 | 6 |
| g + `NEWS_SEMANTIC_VETO=0.5` | 11 / 5 / 4 | 0.550 / 0.289 | 20 / 4 | 0.833 / 0.247 | 459 | 7 |

Matcher and story regressions under the two-member knob, alone and with g, are unchanged: precision 1.000, recall 0.923, no false pair, nothing unexpected. They were not run under g + 0.5, which had already failed.

## Pairs that move

Ids are the first 12 hex digits after `feed-guid:`, `a` / `b`. "Event" and "story" mean the pair shares one.

- g to g + 0.5, gained: 71 (`cb4c6e59e67b` / `d7da3b334555`, same) and 150 (`bc64410edb25` / `e14fff6cd8d1`, same) join an event; 28 (`04496a1b55ca` / `f0bdb7ce658d`, same) joins a story.
- g to g + 0.5, lost: 10, 34 and 67 (`053fca51cc5c` / `c2e6c5f019aa`, `053fca51cc5c` / `081b8228d71a`, `081b8228d71a` / `5148518296d1`, all same) leave their event and story; 75 (`aa4fa6599994` / `f0bdb7ce658d`, same) and 21 (`04496a1b55ca` / `71f0848fb3f5`, related) leave their event but stay in a story; 22 (`03b1a88ed1c9` / `e94b13f30776`, related) leaves a story. A new wrong link: The Guardian's North Korea crypto-funding analysis with BBC's Binance report, labelled different.
- Baseline to two-member: related pairs 20 and 99 leave their event and story, and related pair 3 leaves its story. No same pair moves.

## Gate verdict

**Fail for every setting**, from the baseline:

| Gate rule | Two-member | g + two-member | g + 0.5 |
| --- | --- | --- | --- |
| Strict same must not fall | holds, 4 | holds, 13 | holds, 11 |
| Strict different must not rise | holds, 3 | holds, 3 | **fails**, 4 |
| Story different must fall | **fails**, 3 | **fails**, 3 | **fails**, 4 |
| Story recall must rise | **fails**, 0.111 | holds, 0.222, below g's 0.259 | holds, 0.247, below g's 0.259 |
| Regressions unchanged | holds | holds | not run |

## What this shows

Lowering the veto does not simply add links: greedy placement reshuffles events, so it gains three `same` pairs and loses four. The two-member knob admits what its verdicts asked for and still loses related links for the same reason. The verdicts describe final membership, so they do not predict what a change does to the order of placement.

The next blocker is not admission. Under g, 16 or more of the missed `same` pairs are `borderline` (17 of 25 in the g + two-member run), and placement order can undo correct pair decisions. The next work is reviewed training data and a grouping evaluation over arrival orders, not more admission exceptions.
