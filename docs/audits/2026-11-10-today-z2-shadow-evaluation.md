# Today edition Z2 shadow evaluation (#934, 10 November 2026)

Shadow evaluation for [Z2 (#934)](https://github.com/marspater/NewsApp-macOS/issues/934) under [the signed-off Today edition specification](../plans/2026-11-09-today-edition-spec.md). Measured offline with `--today-shadow` (command below) on a migrated temporary copy of `~/news-eval/library-copy.sqlite3` (7,442 articles across 37 fetched feeds, 99 read/saved interactions over 30 days, latest snapshot timestamp `1793382432`). Aggregate metrics only are stored here and under `~/news-eval/today-shadow-2026-11-10/shadow-report.json`; all candidate titles and review sheets stay private under `/private/tmp/today-shadow-eval/`. Labels are single-pass agent labels awaiting Mars's 20-story spot check.

```sh
NEWS_TEST_ATOM=Tests/NewsTests.swift \
NEWS_TODAY_NOW=<epoch seconds> \
NEWS_TODAY_LABELS=/private/tmp/<run>/labels-private.json \
NEWS_TODAY_FEEDS=/private/tmp/<run>/feeds.txt \
./test.sh --today-shadow /private/tmp/<run>/library-copy.sqlite3 /private/tmp/<run>/<output>
```

The two arguments are the library copy and the output directory. Both must lie under `/private/tmp` or `/tmp`; the output directory is created `0700`, and an existing one must already be closed to other accounts. The variables are optional. `NEWS_TODAY_NOW` pins the clock (default: the newest story in the copy), `NEWS_TODAY_WINDOW_HOURS` sets the candidate window (default `72`), and `NEWS_TODAY_LABELS` names the private label file (without it the labelled sections are left out). `NEWS_TODAY_FEEDS` names a file with the subscribed feed URLs, one per line. A library copy does not hold the subscription list, so without that file every feed the copy has fetched stands in for it, and a feed removed since keeps its stories in the pool. These figures used `NEWS_TODAY_NOW=1793382432`, the label file and no `NEWS_TODAY_FEEDS`: the pool is the 37 fetched feeds, an upper bound on the subscriptions.

The figures were re-read after the review fixes at commit `bddd996`, with the same copy, clock and labels: the Coverage gate rose from `21 / 29` to `23 / 29`, because grouping confidence is now the mean over the whole story, and every other quality figure is unchanged.

## Score, Confidence, and Gate Definitions (Z2)

Neither the `0–1` editorial `score`, the `0–1` placement `confidence`, nor the Coverage grouping confidence existed in code prior to Z2.

- **Editorial `score` (`0.0...1.0`)**: weighted sum without publisher affinity (`affinity` acts only as a Lead tie-breaker behind `score` and `originalReportCount`, so affinity never lifts a single-report story onto a Lead slide or ahead of a multi-report story):
  - Original reporting breadth (`0.42`): $\min(1.0, \log_2(\max(1, \text{originalCount})) / \log_2(6.0)) \times 0.42$, where wire copy counts once per agency (`BriefingPriorityData.originalReports`).
  - Briefing importance (`0.28`, `+0.05` sector impact bonus below `.major` when the stored overview in `event_overviews` holds a non-empty Industry Impact section): `BriefingPriorityData.assessImportance` mapped as `.major = 0.28`, `.notable = 0.16`, `.minor = 0.04`.
  - NaturalLanguage importance (`0.20`): `NotificationService.shared.computeImportance` (`0.0...1.0`), decoupled from notification posting thresholds (`breakingScore = 0.60`, `priorityScore = 0.75`).
  - Momentum / developing cadence (`0.10`): rising + developing `0.10`, rising or developing `0.07`, steady `0.02`, fading `0.00`.
  - Promotional deals guard: headlines matching explicit deals/promo cues (`Deals:`, `Black Friday`, `Cyber Monday`, `Doorbusters`, etc.) are capped at `0.25`.
- **Coverage card grouping confidence (`0.0...1.0`)**: mean score of `'match'` and `'related-act'` rows in `pair_assessments` linking members of the story (with a deterministic headline-token Jaccard fallback when pair rows are absent). Gate threshold: `>= 0.70`, alongside `>= 3` publishers and `>= 2` original reports.
- **Stored `StoryImportance` decision (`#934`)**: Today does **not** write or consume stored `story_importance` rows; `story_importance` remains retired from app write paths while preserving `BriefingPriorityModule` / `BriefingRanking` and `--curation-live` compatibility.

## Candidate Pool & Lane Distribution (72 h Window: 738 Stories, 24 h: 522 Stories)

| Measure | Value | Notes |
| --- | --- | --- |
| Candidate pool (`72 h` / `24 h`) | `738` / `522` | Feeds resolved via `article_feeds` and `articles.feed_url`; the 37 fetched feeds stand in for the subscription list |
| `Latest` completeness | `1.00` (`100 %`) | Every eligible story placed in exactly one lane |
| Duplicate rate across lanes | `0.00` (`0 %`) | Story-layer (`#581`) deduplication |
| Loader / Assign runtime (Debug) | `104.9 ms` / `4,055.7 ms` | SQLite load (`105 ms`); pure assignment in Debug (`4.06 s`, dominated by per-story `NLTagger` passes when `entity_mentions` is unpopulated on migrated v27 copy). The re-read took `479.6 ms` / `20,291.3 ms` while the Mac was busy with other work (load average about 9): that pair is not a clean measurement, and the loader's grouping query changed in between |
| Coverage gate (`>= 3` publishers) | `23 / 29` (`79.3 %`) | Rejects `6` confirmed clusters with `< 0.70` mean `pair_assessments` score or `< 2` originals |

| Lane | Shown | Raw Qualifying (72 h) | Qualifying Rule / Breakdown |
| --- | --- | --- | --- |
| `The Lead` | `5` (`true`) | `5` (cap `5`) | `3` unique publishers; max publisher share `0.60` |
| `In Motion` | `5` (`true`) | `5` | `>= 3` min cleared (`12` cap) |
| `The Deep Read` | `8` (`true`) | `43` | Shown: `6` classified (`2` Explainer, `1` Investigation, `3` Opinion) + `2` stored `>= 8 min` (`>= 1,600` words) |
| `Your Beat` | `12` (`true`) | `375` (`254` in `24 h`) | Finer `interestMatch >= 0.50` clears `28 / 200` (`14 %`); bulk of raw `254 / 522` comes from `topQuartilePublishers` across high-volume feeds |
| `Outside Your Usual` | `6` (`true`) | `33` | Novelty `>= 0.60` and score `>= 0.35`, within subscriptions |
| `The Latest` | `702` (`true`) | `702` | `95.1 %` of edition; conditional Simpson diversity `0.835` across `13` unique publishers |

## Three-Ranking Comparison (200 Labelled Recent Stories)

| Ranker | `Lead precision@5` | Mean Originals (Top 5) | Wire-Only in Top 5 | Top-5 Overlap vs Z2 |
| --- | --- | --- | --- | --- |
| Publisher count alone | `1.00` (`5 / 5`) | `6.4` | `0` | `4 / 5` |
| Today's Briefing signals (`BriefingRanking`) | `1.00` (`5 / 5`) | `6.0` | `0` | `4 / 5` |
| Z2 combined editorial score | `1.00` (`5 / 5`) | `6.0` | `0` | — |

On `200` labelled stories (`shadow-candidates-private.json`):
- **Overall lane purity:** `0.970` (`194 / 200`), with per-lane purity: `The Lead` `1.00`, `Your Beat` `1.00`, `Outside Your Usual` `1.00`, `The Latest` `0.983`, `The Deep Read` `0.80`, `In Motion` `0.333` (see below).
- **Deep Read unfetched-body measurement:** `159 / 738` (`21.5 %`) stories already carry full stored body text; `579 / 738` (`78.5 %`) carry feed teasers/summaries only. Background fetching stays off per spec §4.1.

## `In Motion` Evaluation (50 Reviewed Events: 9 `new_information`, 10 `repetition`, 31 `initial_report`)

| Metric | Count | Reading |
| --- | --- | --- |
| True positives (`new_information`) | `2` | Genuine multi-stage developments with novel headline & rising momentum |
| False positives (`initial_report`) | `0` | `24 h` boundary test eliminates 100 % of all-inside-`24 h` new stories |
| False positives (`repetition`) | `3` | Caused by topic false-merges and promo/podcast entries inside v27 clusters (`#737`) |
| False negatives (`new_information`) | `7` | Real developments where event momentum was `.steady` or `.fading` rather than `.rising` |

## Open Threshold Proposals for Mars Review

Before Z3 (`#935`) or Z4 (`#936`) renders these lanes in UI:
1. **`Your Beat` publisher-affinity share:** Computing top-quartile publishers solely from the engaged set allowed high-volume news wires/dailies in the top quartile to qualify `~48 %` (`254 / 522`) of daily articles raw (capped cleanly at `12`, but high daily throughput). Confirm whether `topQuartilePublishers` should keep full weight (letting `score` select the top `12`) or tighten to a higher engagement ratio (e.g. `>= 10 %` of 30-day reads or top decile).
2. **`In Motion` momentum requirement:** Spec §2.2 requires `rising` momentum; in the 50-event sample that rejected `7 / 9` genuine follow-up developments whose cadence had flattened to `steady` or `fading`. Decide whether to keep `rising` strict (high precision on surging stories, sparse lane of `5` in `72 h`) or allow substantive non-repeat updates after `24 h` under `steady` momentum as well.
3. **`The Lead` multi-report threshold:** `0.60` (`>= 2` originals) and `0.75` (`1` original) yielded `5` solid Lead slides with `0` wire-only inflation (`mean originals = 6.0`, `precision@5 = 1.00`) on `library-copy.sqlite3`.
