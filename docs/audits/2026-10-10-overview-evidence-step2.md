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

## After the verifier and format fixes

Same copy and events, all 58 attempted (`NEWS_OVERVIEWS_TARGET=100`); aggregates: [overview-evidence-step2-fixed.json](../benchmarks/2026-10-10-overview-evidence-step2-fixed.json).

| Change | Accepted |
| --- | ---: |
| Publisher text only (#414) | 17 / 58 |
| Negation compares the matching sentence; attribution compares word sequences | 27 / 58 |
| A pasted paragraph keeps its first complete sentence | 33 / 58 |
| Four-line drafts with one introduction and three facts | **35 / 58 (60.3 %, Wilson 95 % 47.5–71.9 %)** |

Final run: no line-count fallbacks, 18 weak drafts, 5 thin-evidence events. 20 sentences were rejected: 7 not one sentence, 6 negation, 4 numbers, 1 date, 1 attribution and 1 by the auditor. The auditor flags no unsupported or critical claim among the 167 retained claims. 84 % of retained claims copy a passage sentence whole, and 40 % of introductions repeat a key fact. End-to-end time is p50 6.9 s and p95 10.2 s. Accepted generation alone is p95 10.4 s, because more sentences reach the support check.

Against the step-2 targets, format fallbacks (0 %), end-to-end time and requests per event now pass. Acceptance (60.3 %, upper bound 71.9 %) remains below 70 %, and independent claim labels (step 3) are open.

## Execution receipt and provenance

- **Receipt**: [overview-step2-receipt.json](../benchmarks/2026-10-10-overview-step2-receipt.json).
- **Producer commit**: `8f5377088c1ea61696124ab9369790bce88d601f` (worktree `claude/verifier-long-passages` at `bbfd8a9b33a93addba86629723344c24d28f12aa`, clean dirty-code fingerprint).
- **Capture time**: 2026-10-10T09:37:30Z.
- **UTC window bounds**: 2026-10-06T17:20:35Z to 2026-10-08T17:10:00Z (7–8 October window; 1,659 articles across 58 multi-source events).
- **Library SHA-256**: `84a63dfb3f9669703a653832035498843773358ac4013946b05e0da0c57a33d9`.
- **Output SHA-256**:
  - `claims-review-private.csv`: `f539dce48f131ac39104c2d0859fa3880137122d4cbf271b9bf56cd7fb96b73a` (167 claims)
  - `overview-evaluation.json`: `109d34b911ee4b472c82121eb2ff798c92e7ade0d62c7daa4b4087bfc79a257d`
  - `overviews.json`: `01f9aec5eb4b04f74f34b30fbd63f5551ae3b5a594c9c1bd1aafe4844dae5989`
  - `perspectives.json`: `e40750c3d24b3466a20780e66311f999d7ee5a322dad632523ee37444a8c0539`

## Limits and acceptance status

- **Overlapping older sample**: draws on the 7–8 October window matching #412. It is not a fresh or separate acceptance window.
- **Development evidence only**: serves as diagnostic and tuning evidence. Zero claims of fresh-window acceptance.
- The run's second pass retried pages that had failed.
- No installation, isolated launch or sealed data was used.
