# Codacy review follow-up — 9 October 2026

Reviewed all 16 Codacy conversations on PRs #286–#291, including outdated comments, plus findings in the review summaries. Seven conversations required new corrections, four referred to corrections already committed, and five proposed changes that did not fit the implementation. Each disposition links its implementation or explains the retained behavior.

| Slice | Disposition |
| --- | --- |
| #286 | Associate decoded-image state with its URL, prevent a stale image during view reuse, and avoid a second load on cached mounts. Retain the standard Swift `@concurrent` attribute. |
| #287 | Isolate initial article URL normalization; test both transport settings and malformed URLs through protected extraction. Identify retired feeds by URL rather than array position. |
| #288 | Read symmetric fragment exclusions in bounded SQLite batches and refresh discovery terms after a merge. Earlier regex, helper and tuple corrections remain. Keep fresh model sessions. |
| #289 | Keep fresh independent rating sessions and atomic per-result writes. The synchronous SQLite transaction helper cannot span awaited inference. Previously corrected notification ordering remains covered. |
| #290 | Add schema v19's image URL index, including upgrades from existing v18 libraries. Charset decoding was already corrected. Freshly ingested stories already have a non-null document URL. |
| #291 | Preserve pipes inside sentences, normalize complete YES verdicts, and reject explanations or ambiguous answers. Extract sentence/citation verification helpers. Overview analysis version 4 regenerates earlier parser results; article analysis stays at version 3. |

The summary-only suggestions to parallelize publisher lookups or batch semantic judgments were assessed. The existing limits, timeouts, energy policy and cancellation remain; changing independent support judgments without quality/latency evidence is not justified. The source reader stays usable while an overview loads. Repeated introduction/fact wording remains observable in model output.

## Verification

- Full regression commit hooks passed on all six updated slice branches.
- On the cumulative code head `fc7f2ca`: native UI 80/80, reader accessibility 26/26 and overview accessibility 49/49 passed. The image regression mounts real SwiftUI hosting views and suspends the replacement image load.
- Migration checks cover an existing v18 library, cancellation, indexed query planning at representative cardinality, cached images, saved/read state and reopening. Exclusion checks span SQLite binding batches and both endpoints; a three-fragment control requires terms introduced by the first merge.
- An isolated arm64 ad-hoc bundle built, passed strict signature verification and had a valid plist. It was not installed over the production app.
- A fresh on-device audit of the existing private library backup accepted 5 of 8 live overviews and retained 3 deterministic fallbacks. All 40 retained claims passed the audit with zero critical or unsupported claims. Generated sentences were reviewed locally against their cited passages; no added factual assertion was found. Three labeled controls retained fallbacks, with 7 supported claims and zero critical errors; they do not establish generative quality.

Private publisher passages and model records remain under `/private/tmp/news-codacy-overview-review/`. No new capture, sealed holdout prediction, installation, merge or spoken VoiceOver check is included. Clustering was checked with the full labeled-control regressions; historical precision/recall numbers were not remeasured in this follow-up. Hosted results and conversation closure are recorded on the PRs and tracking issues.
