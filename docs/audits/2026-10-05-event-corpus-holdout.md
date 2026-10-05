# Event clustering tune and sealed holdout — 4–5 October 2026

Refs #102, #127, #94, #90. Matcher frozen at main `3760849` (EventMatcher, EventCandidates, EventClustering and the evaluator unchanged since `03a0a8e`). Apple M5 / 24 GiB, macOS 27.0.1. Aggregates only; headlines, descriptions and publisher text stay in the private corpus.

## Input

The accepted private export (`reviewed-event-corpus.json`, SHA-256 `868c62a0…a2ca3d63de8623fbe866359d1e082fadacd7bd456acf2a0`) holds 231 distinct native URLs: 168 tune and 63 holdout. Six same-URL copies are scored once and 24 accepted exclusions stay out. Labels are a copilot review accepted by Mars, not blind independent annotation.

## Tune (4 October)

`NEWS_EVENT_CORPUS=<tune-only export> ./test.sh --event-corpus`: precision 1.000 (TP 26, FP 0, Wilson 95% lower bound 0.871), recall 0.150 (FN 147), no impure event. English recall 0.269; all 66 cross-language and all 13 Ukrainian positive pairs were missed.

Embedding sweep (#127, English and German only; the other catalog languages have no sentence embedding on this Mac): no cutoff keeps precision near the deterministic level. Rescue reaches recall 0.398 at distance 0.20 with precision 0.860, and precision falls to 0.349 at 0.30 and 0.062 at 0.50. Veto keeps precision 1.000 but only lowers recall. 0.20 was fixed for the holdout comparison.

A narrow language-conflict relaxation changed nothing: candidate selection already drops cross-language pairs before the matcher sees them.

## Non-English matching investigation (not shipped)

Root cause of the Ukrainian misses: macOS has no word-class model for Ukrainian, Polish, French, Italian or Dutch, and `NLTagger` then tags every word `otherWord` rather than leaving it untagged. The plain-word fallback in `EventFeatures` never runs, so these articles have no action terms and cannot form events.

A branch (`claude/event-feature-fallback`) enabled plain terms for those languages with per-language boilerplate lists and local month, weekday and quarter forms. On tune it raised precision-neutral recall to 0.197 (TP 34, FP 0; Ukrainian 8 of 13). Independent review on larger public samples outside the corpus rejected it for release:

- Ukrainian/Polish, 1,155 live items: about 10 of 73 new events mixed different stories (roughly 86% purity), for example nightly air-defence reports for different dates, separate statements by one politician and repeated strikes on one city.
- French/Italian/Dutch, 2,170 live items: 16 of 310 new links were clear false merges, from repeated series or show blurbs, names after elisions or hyphens, and generic verbs.

Without name typing for these languages there is no place-conflict guard, and capitalized-word anchors plus shared template text are too weak. Production matching is unchanged; non-English stories stay unclustered, which keeps the plan's rule that a missed link is better than a wrong merge. The follow-up needs labeled non-English hard negatives before any threshold or lexicon is accepted.

## Sealed holdout (5 October, one run)

`NEWS_EMBEDDING_THRESHOLD=0.2 NEWS_EVENT_CORPUS=<export> ./test.sh --event-corpus --corpus-holdout`, receipt and log kept privately.

| Measure | Value |
| --- | --- |
| Precision | 0.958 (TP 23, FP 1; Wilson 95% 0.798–0.993) |
| Recall | 0.291 (FN 56) |
| Falsely merged pairs | 1, in 1 event |
| English | precision 0.958, recall 0.605 (FN 15) |
| Cross-language | 0 of 39 positive pairs linked |
| German, French, Ukrainian, Polish, Italian, Dutch | no links (13 holdout documents) |

The **≥97% precision target is not met** at the point estimate: one pair separates 23/24 from 24/24, and the interval is wide.

The single error joins a report of the Spanish parliament rejecting the government's housing measures with a report of the protests against that vote later the same day. Both reports describe both acts; under the documented event-boundary rules the vote and the rallies are different events, and this family was flagged as ambiguous before the holdout was opened. It is a causally linked, timeline-type pair, not an unrelated merge. No setting was changed after the result.

Embeddings on the holdout at 0.20 (English and German pairs within the window): deterministic precision 0.958, recall 0.590; rescue precision 0.812, recall 0.667; veto precision 1.000, recall 0.103; embeddings alone precision 0.583. Embeddings do not improve on deterministic matching; #127 concludes not to adopt them.

## Limits

- 24 predicted holdout pairs cannot distinguish 96% from 99% precision. Recall is low by design and almost entirely English.
- The fingerprint (identity) gate is separate and still needs fresh holdout captures from 4 October on, reviewed once; one capture on 4 October gave 143 eligible tuning documents and no different-URL candidate.
- Labels are accepted copilot reviews, not blind annotation.
