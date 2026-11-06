# Full re-clustering cost by stage (#691, 6 November 2026)

**Finding: candidate search takes about three quarters of a from-scratch re-clustering.** The three-run medians put it at 75 % of the warm total. A separate warm run with a temporary patch, at a different load, split candidate search and put about 90 % of that run's candidate-search time in `NLLanguageRecognizer`, which runs on every candidate row of every article: 86,957 recognitions for 1,156 articles. That split is one run, so it locates the cost without measuring its share of the total. The 27 October figure was 505.7 s for 2,077 rows at a load of about 180. Here 1,454 rows take about a minute with a Release runner; the two runs differ in load, input and possibly build, so this does not separate those causes.

## Method

- Base `750463f`, Apple M5 (Mac17,3), 24 GiB, macOS 27.2. Release `NewsTestRunner` (`script/build_test_runner.sh OUTPUT -O`), run directly under `/usr/bin/time -l`. No app launch.
- Library: the re-clustered 3 November copy, 1,889 articles, a fresh `0600` copy per run, clock pin `1793642173`, `--library-holdout` with its 218 pairs. Each run processes 1,454 recent rows in one pass, and a second pass finds none.
- Warm keeps the stored signals and vectors, as a matcher version bump does; 170 rows still have no stored vector. Cold is `NEWS_HOLDOUT_COLD=1`, which also empties `article_features` and `article_embeddings`, as Clear AI Analysis does.
- Three runs of each, alternating, one at a time. Each started with no build or suite running and a one-minute load below 4. Other sessions were still active: the load reached 6.38 during runs, and cold totals spread from 58.8 s to 101.1 s. Treat the medians as soft. Raw runs are in [the benchmark file](../benchmarks/2026-11-06-recluster-stages.json).
- All six runs gave the baseline's strict 4 / 5 / 3, so the timers change no event decision.

## Results

Medians in seconds, stage by stage, so the columns need not add up to the median total.

| Stage | Warm | Cold | Share of warm total |
| --- | ---: | ---: | ---: |
| **Total** (load before / after the median run: 3.85 / 4.72 warm, 3.97 / 6.38 cold) | 55.65 | 83.36 | 100 % |
| Phase: matching | 55.25 | 82.58 | 99 % |
| Phase: fragment merge | 0.14 | 0.26 | 0.3 % |
| Phase: story pass, with singleton attachment | 0.27 | 0.52 | 0.5 % |
| Candidate search | 41.82 | 65.97 | 75 % |
| Feature extraction and stored-feature reads | 6.87 | 8.73 | 12 % |
| Pair model, 642 calls | 2.68 | 2.55 | 5 % |
| Embeddings (170 rows warm, 1,704 cold) | 0.33 | 1.62 | 0.6 % |
| Rule assessment | 0.53 | 0.87 | 1 % |
| Pass writes | 0.77 | 1.12 | 1 % |
| Event reads | 0.64 | 0.99 | 1 % |
| Match commits | 0.14 | 0.18 | 0.3 % |

Rows per pass: 1,454, then 0. Peak memory: maximum resident set 289 to 301 MB warm and 346 to 362 MB cold; peak footprint 148 to 179 MB.

One warm run with a temporary, uncommitted patch split candidate search (load 5.51 before, 7.17 after, so slower overall):

| Candidate search part | Seconds |
| --- | ---: |
| `NLLanguageRecognizer` over candidate rows, 86,957 recognitions | 65.00 |
| `EventMatchKey`, the article's own key | 3.99 |
| FTS query | 2.98 |

That is 0.75 ms per recognition, repeated for the same rows across articles.

## Budget

The #691 baseline budget, set before the language reuse of #572. Per 1,000 recent rows from scratch, on this machine with a Release runner, median plus about 25 %: **48 s warm** (38.3 s measured) and **72 s cold** (57.3 s measured). These describe the cost at that time, including the language check. The current budget is in `docs/RELEASE_CHECKLIST.md`.

## Stages above 25 %

- Candidate search, 75 %: fix request filed on the owning epic #574. Reuse a language per article instead of recognizing each candidate row again: `article_features` already stores one, or cache it by article id within the pass. Matching behaviour must stay the same, and the matcher regressions and the holdout decide that. This issue changes no matching code.
- Matching as a phase is 99 %, because it contains candidate search. Nothing else in it passes 25 %.

## Not measured

- What the reader sees during the pass: first-card time, main-thread hangs and whether a refresh waits. These need the app running, and this slice launches nothing, so that acceptance item of #691 stays open.
- A larger library. The 27 October input held 6,400 articles and 2,077 processed rows.
- A strictly idle Mac: see the load figures above.
