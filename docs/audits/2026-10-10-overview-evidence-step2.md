# Overview evidence, step 2 — 10 October 2026

Refs #308. This is the first live check after #414, which extracts publisher text before overview synthesis. It measures against the step-2 targets recorded on #308 before implementation. It is not acceptance: the targets are not met. Aggregates: [overview-evidence-step2.json](../benchmarks/2026-10-10-overview-evidence-step2.json).

## Sample

The source is a backup of the isolated collection app's library (#314). That app runs `main` at `7c2d01f`, was seeded from the installed library and had made one refresh. The 72-hour window therefore matches the [summary-only audit](2026-10-10-overview-live-audit.md) (#412) on 7–8 October. Both runs draw on largely the same events, except that the earlier audit excluded the 8 events from 9 October. Only the backup was written.

`NEWS_OVERVIEWS_EXTRACT=1 ./test.sh --overviews-live` attempted all 58 multi-source events. Before each event, it used the production coordinator path (4-second deadline per page, two fetches at a time, at most four representatives).

## Results against the step-2 targets

| Target | Result | Met |
| --- | --- | --- |
| Accepted overviews ≥ 70 % of attempts | 17 / 58 (29.3 %, Wilson 95 % 19.2–42.0 %) | No |
| Format (line-count) fallbacks ≤ 10 % | 9 / 58 (15.5 %, 8.4–26.9 %) | No |
| Evidence step p95 ≤ 4.5 s | p50 0.9 s, p95 3.1 s | Yes |
| End-to-end p95 ≤ 12 s | p50 4.9 s, p95 8.2 s | Yes |
| ≤ 4 page requests per event | Maximum 4; 150 requests in total | Yes |
| Auditor critical claims 0 | 0 | Yes |

Extraction: 138 of 150 page requests stored text. The other 12 returned HTTP errors, and those pages kept their feed summary. No fetch hit the deadline.

## What changed compared with summaries only

| Fallback cause | Summaries only (49 events) | With publisher text (58 events) |
| --- | ---: | ---: |
| Accepted | 18 | 17 |
| Wrong line count | 26 | 9 |
| Thin evidence (model not asked) | — | 5 |
| Weak draft | 5 | 27 |

Richer evidence solved most format failures. The drafts then failed deterministic sentence checks instead: 59 sentences were rejected (7 before).

A second run on the same copy, with stored text and the new per-check rejection reasons, accepted 15 of 58. It rejected 59 sentences:

| First failed check | Sentences |
| --- | ---: |
| Not exactly one sentence | 20 |
| Verifier: attribution missing | 17 |
| Verifier: negation flipped | 16 |
| Verifier: number mismatch | 4 |
| Verifier: date mismatch | 1 |
| Auditor: attribution error | 1 |

## Diagnosis

Most draft sentences copy passage text verbatim. Yet 33 of the rejections are attribution or negation failures, which a verbatim copy cannot cause. Both checks behave differently on long passages:

- **Negation:** the check compares whether the claim and the whole passage contain any negation word. A multi-paragraph article almost always does, so a faithful positive sentence counts as flipped.
- **Attribution:** the check takes the three words before "said", trims punctuation from each and joins them with spaces. It then searches the raw passage, so a verbatim `…on,” Zelensky said` looks for `on Zelensky` and fails.

These are verifier defects to fix separately and remeasure; this change does not alter the verifier. Sentences that are not exactly one sentence are a genuine format rejection.

Perspectives: 2 of 58 events show two or more perspectives. 223 of 341 selected passages contain speech the extractor did not match, and 86 use typographic quotes (#313).

The three labelled controls now stop at the thin-evidence guard, because their fixture passages are short. They no longer exercise the model and need longer fixtures.

## Limits

- One window, the same as the earlier audit, with no review labels.
- The run's second pass retried pages that had failed.
- No installation, isolated launch or sealed data was used.
