# Live overview and perspective audit — 10 October 2026

Refs #308 and #313. Source: `main` at `ff81d2a`, which includes typographic-quote attribution (#406, overview analysis version 5) and review-input integrity (#405). Aggregates: [overview-live-audit.json](../benchmarks/2026-10-10-overview-live-audit.json).

## Sample

The installed library was opened read-only and copied with SQLite's backup API to a private temporary directory. The harness migrated and wrote only that copy; the installed app, its settings and reading state were not changed. The installed app has not refreshed since 8 October, so the 72-hour window holds stories published from 7 October 07:36 to 8 October 17:10 UTC.

`./test.sh --overviews-live` found 57 multi-source events in the window. The 8 events generated in the [9 October audit](2026-10-09-plain-text-overviews.md) were excluded (`NEWS_OVERVIEWS_EXCLUDE`), so all 49 remaining events were attempted. The window ran out before the 30-accepted target was reached. Publisher passages, model prompts and answers, and the reviewer sheet stay in the private directory.

## Overviews (#308)

| Measure | Result |
| --- | --- |
| Accepted model overviews | 18 / 49 (36.7 %, Wilson 95 % 24.7–50.7 %) |
| Fallback causes | 26 wrong line count (format), 5 weak drafts, 0 refusals, 0 model errors |
| Labelled controls | 3 / 3 fell back on line count; 7 deterministic claims, 0 critical |
| Latency, accepted | p50 3.9 s, p95 4.6 s (includes per-sentence support checks) |
| Latency, all attempts | p50 2.9 s, p95 4.4 s |
| Retained claims in accepted overviews | 89; the auditor heuristic flags 0 unsupported and 0 critical |
| Claims copied whole from a passage | 76 / 89 (85.4 %, 76.6–91.3 %) |
| Claims copying at least 8 consecutive words | 82 / 89 (92.1 %, 84.6–96.1 %) |
| Introductions repeating a key fact (Jaccard ≥ 0.6) | 16 / 34 (47.1 %, 31.5–63.3 %) |

The auditor heuristic is not a label. The 89 retained claims are in a private review sheet (`claims-review-private.csv`) for an independent reviewer; supported, unsupported and critical rates stay undetermined until it is labelled.

Observations:

- Format is the main failure: the model returned the wrong number of protocol lines in 26 of 49 attempts and in all three controls. Refusals did not occur.
- Accepted overviews are mostly extractive. Most claims reproduce a cited sentence whole, which limits fabrication risk but adds little synthesis, and about half of the introductions restate a key fact.

## Perspectives (#313)

| Measure | Result |
| --- | --- |
| Events with two or more perspectives | 0 / 57 (Wilson 95 % upper bound 6.3 %) |
| Events with one perspective | 6 |
| Events with none | 51 |
| Selected passages | 188; 73 contain speech the extractor did not match, 15 use typographic quotes |
| Attributed candidates / voices / perspectives | 7 / 6 / 6; no vague-speaker candidates |

First step that left an event below two perspectives: speech not matched in 33 events, no attributed speech in 18, a single voice in 6.

The #406 quote forms are present but rare in this sample. The dominant gap is speech the attribution patterns do not match, so improving coverage means widening those patterns, not adding a model step.

## Limits

- One window from a library last refreshed on 8 October; results may differ for later news.
- Labels are pending, so no claim-accuracy rate is reported.
- Verbatim overlap and introduction repetition are lexical measures.
- No installation, isolated app launch or live network checks were part of this audit.
