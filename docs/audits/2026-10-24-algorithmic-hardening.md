# Algorithmic logic hardening — 24 October 2026

Refs #501 (program), #502–#510. Base: `origin/main` `89ab7d6`. Implementation from a cloud session without a Swift toolchain: every compile and test result below is a hosted CI result on the PR, linked where it exists. The private holdout replay (#509) is a local measurement that this audit does not claim.

## Baseline

- Last matcher measurement (18 October, v6, private English holdout, [audit](2026-10-18-matcher-307-verification.md)): precision 93.3% (14 TP / 1 FP / 24 FN), recall 36.8%. The earlier matcher on the same holdout: precision 95.8%, recall 60.5%. The v6 gates removed no holdout false merge.
- The MiniLM v7 rescue/veto layer (#453) has no corpus replay. Every false merge in every audit joins related but separate acts.
- Dedup and identity resolution (scoped GUID → URL alias → exact-text fingerprint → v9 reconciliation) were read and left unchanged.

## Confirmed defects and changes (PR A: matcher v8)

| # | Defect | Change | Test |
| --- | --- | --- | --- |
| #502 | `BertWordPieceTokenizer` never strips accents; the vocabulary has no accented letters, so "Erdoğan" became one `[UNK]` token. The clusterer embedded raw text while features read a plain version. | Uncased, accent-stripped basic tokenization; one `EventFeatures.matchingText` for features and embeddings; `SentenceEmbedder.modelVersion` 2, stored vectors recompute. | `testBertTokenizer`, `testEventMatcherRules` |
| #503 | The primary-clause guard vetoed "Three dead after …" headlines because their primary clause is only a toll. | A primary clause made only of consequence words carries no act and does not veto. | `testEventMatcherRules` (toll-after pair matches; pontoon guard kept) |
| #504 | Any capitalized word was canonicalized to a country, including words of typed person names ("Michael Jordan" → `@JO`). | Person-name words skip the country table in the lexical pass. | `testEventMatcherRules` |
| #505 | `EventMatchKey` filled its eight FTS terms with description names before headline words. | Headline names, headline words, then description names. | `testEventCandidateGeneration` |
| #506 | No public corpus scored the clusterer in CI. | `matcher-regressions-v1.json` (49 authored English reports, 15 families, 24 positive pairs, related-act and same-night negatives, singletons) replayed through `StoryCorpus.eventMemberships`; `testMatcherRegressionCorpus` prints the pairwise line and the failing pair ids and ratchets on a floor and a ceiling. | `testMatcherRegressionCorpus` |

`EventMatcher.version` is 8, so active events are revalidated under the existing repartition path; archived groups stay intact.

## Authored corpus, before and after

After (matcher v8, [CI run 40068841897](https://github.com/marspater/NewsApp-macOS/actions/runs/40068841897), PR #511 merged as `73223d3`):

```
matcher regressions v8: precision 0.913 [95% 0.732–0.976] (TP 21, FP 2), recall 0.875 [95% 0.690–0.957] (FN 3)
false pairs: f08-a+f08-d, f08-b+f08-d
missed pairs: f03-a+f03-c, f03-b+f03-c, f08-c+f08-d
```

- The two false pairs join "Commissioner steps down over failed Alabama execution" to the execution-aftermath reports: a related act with no "after" clause and shared actors, the known related-act limitation. Its sibling "… resigns after botched execution" stayed out through the primary-clause guard, which is why the resignation pair itself is missed.
- The Malatya misses are the 20 h later "Rescuers search rubble after Malatya earthquake kills four" report: its primary clause names an act (search), so the background-clause guard keeps it out although search and rescue are a consequence under the corpus rules. Candidate for #509: whether rescue, search and evacuation terms count as consequences.
- Before (matcher v7 on the same fixture): not measured in hosted CI, because the fixture landed with the fixes. Local command on a checkout of `main`: `git checkout 89ab7d6 -- Sources/Intelligence/EventMatcher.swift Sources/Intelligence/EventCandidates.swift Sources/Intelligence/EventClustering.swift Sources/Intelligence/SentenceEmbedder.swift && ./test.sh --story-regressions`; the corpus line prints with the v7 code and the ratchet reports the difference.

The fixture's `expected` block is TP ≥ 21, FP ≤ 2.

## Deliberately unchanged, handed to #509

- Semantic veto (cosine < 0.55) removes pairs that pass every deterministic gate.
- `EventPairAssessment.score = max(ruleScore, cosine)` makes the whole-event mean threshold (0.45) dead code when embeddings exist.
- No common-actor guard in matching (the mechanism behind every wrong link in the #314 audit).
- The >12 h strict rule (`what ≥ 0.35`, three shared terms), kept on 17 October.

Each needs the holdout replay before and after PR A, with the command recorded in #509.

## Foundation Models on sensitive news (PR B, #507–#508)

Production call sites: `EnrichmentQueue` classifies with `allowFoundationModels: false`; the event judge and importance scoring were switched off on 17 October; `ArticleAnalyzer` (reader summary, AI on) is the only live model call. Ingestion, search and clustering therefore cannot be blocked by the model today; the defect was in what happens after a failure.

| Cause | Before | After |
| --- | --- | --- |
| Input guardrails on violent text | `permissiveContentTransformations` already in use; a `guardrailViolation` fell into a generic `catch` and was stored as provisional, so every summary open asked again and failed again | `Rejected(.guardrail)`: final extractive summary |
| Output refusal (`GenerationError.refusal` or refusal prose) | prose failed the `SUMMARY|` contract (final); the typed error was provisional | both final |
| `exceededContextWindowSize`, `unsupportedLanguageOrLocale`, `decodingFailure`, `unsupportedGuide` | provisional, retried on every open | final |
| `assetsUnavailable`, `rateLimited`, `concurrentRequests` | provisional (generic) | `TemporarilyUnavailable`, provisional by design |
| Unknown errors | provisional | provisional; logged as `unclassified` |

Only the outcome label is logged (`NewsTextModel` category). The prompt now states that the text is published news reporting that may describe violence, to be summarized factually. No guided-generation (`@Generable`) path was added: the previous one refused harsh news and cannot be validated from the cloud session (#508 keeps it as a local experiment).

Publisher category hints (`NewsCategory.match`) matched substrings ("Wildlife" → Lifestyle, "Stockholm" → Business, "Homeland" → Lifestyle, "Archipelago" → Technology); they now match whole words with explicit inflections.

## Second pass (PR C, #513–#515, #517, #518)

| # | Defect | Change | Test |
| --- | --- | --- | --- |
| #513 | A quote-only search term became an empty FTS5 phrase (`""*`), which FTS5 rejects, so the whole search failed. | Terms empty after quote stripping are dropped; no FTS join when none remain. | `testFTS5SearchAndOperators` |
| #514 | The extractive summarizer compared whitespace-split words, so "Westfield:" never matched "westfield"; ties broke on an unstable sort. | `MuteRules.words` on both sides; position tie-break. | `testArticleAnalyzerStructuredOutputAndFallbacks` |
| #518 | Section keyword stems "politic" and "sport" never matched under whole-word matching. | "politics", "political", "sports" added. | `testCanonicalClassificationDisambiguation` |
| #517 | Notification triage counted breaking-news signals by substring ("dies" in "studies", "diesel", "bodies"). | Whole-word counting in `breakingSignalCount(in:)`. | `testNotificationModeTriageAndGrammar` |
| #515 | `DateParser` rejected `yyyy-MM-dd` and zone-less `yyyy-MM-dd'T'HH:mm:ss`, leaving such stories undated and unclusterable. | Both forms accepted, UTC assumed, after the existing formats. | `testDateParsing` |

Reviewed and left alone, with the reason: `EventMatchKey.language` on short headlines (needs holdout evidence, #509); `NewsCategory` keyword ties and brand words such as "apple" (needs labeled data); ambiguous country names "Georgia" and "Jordan" as places (recall vs precision trade, #509); rescue, search and evacuation as consequence terms (boundary-rule decision, #509).

## Limits

- No local toolchain: nothing here was compiled or run outside hosted CI.
- The authored corpus is regression evidence written by the implementer; it cannot establish release precision.
- The 97% precision target and the holdout numbers are unchanged until #509 runs.

## Local measurement and decisions — 24 October 2026 (#509, #508)

Run on Mars's Mac (Xcode 27.0 `27A266a`, Swift 6.4, macOS 27.0.1, arm64) from this branch. Private corpus SHA-256 `868c62a0ec973d07aa2ca3d63de8623fbe866359d1e082fadacd7bd456acf2a0`, English only, judge off, production article budget, MiniLM available (`Sources/Resources/Models`). Receipts: `~/Documents/NewsHoldout-2026-10-03/hardening-replay-2026-10-24/` (private, mode 0700). Aggregates: [`docs/benchmarks/2026-10-24-matcher-hardening-holdout.json`](../benchmarks/2026-10-24-matcher-hardening-holdout.json). Ids only below; no headlines.

### Holdout (49 English articles, 38 labeled pairs)

| Run | Commit | Matcher | TP | FP | FN | Precision [Wilson 95%] | Recall [Wilson 95%] |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 18 October | `eaa4527` | v6 | 14 | 1 | 24 | 0.933 [0.702–0.988] | 0.368 [0.234–0.527] |
| Before PR A | `1417703` | v7 | 17 | 1 | 21 | 0.944 [0.742–0.990] | 0.447 [0.301–0.603] |
| After PR A and B | `6079e7c` | v8 | 17 | 1 | 21 | 0.944 [0.742–0.990] | 0.447 [0.301–0.603] |
| Candidate (this PR) | rescue 0.70 | v9 | 22 | 0 | 16 | 1.000 [0.851–1.000] | 0.579 [0.422–0.721] |

- v7 and v8 produce the identical partition on the holdout: the MiniLM layer (#453) is the v6 → v7 gain; the four v8 fixes change nothing there (they do on the authored corpus, below). The single false merge is the 18 October pair (`doc-1081`/`doc-1376`, protest and its background vote).
- The candidate was measured once, after the choice was made on the tune split. It links five more labeled pairs (`doc-0254`+`doc-0921`, `doc-0292`+`doc-1081`, `doc-1081`+`doc-1577`, `doc-1084`+`doc-1091`, `doc-1098`+`doc-1376`) and no longer links `doc-1081`+`doc-1376`. 19 of the 21 v8 misses were under 12 h apart, so the >12 h rule was never the recall bottleneck.

### Tune split (105 English articles, 93 labeled pairs), one change at a time

| Configuration | TP | FP | FN |
| --- | --- | --- | --- |
| v8 as merged | 35 | 0 | 58 |
| Semantic veto off, or only for non-rule links, or at 0.45 | 36 | 0 | 57 |
| >12 h strict rule off | 36 | 0 | 57 |
| Pair score without the cosine floor (`max(rule, cosine)` → rule) | 35 | 0 | 58 |
| Rescue, search, evacuation and mourning terms as consequences | 35 | 0 | 58 |
| Rescue cutoff 0.82 → 0.75 / 0.72 | 38 | 0 | 55 |
| Rescue cutoff 0.70 / 0.68 | 40 | 0 | 53 |
| Rescue cutoff 0.65 | 40 | 3 | 53 |

The 58 v8 misses by the gate that holds them out (`NEWS_EVENT_DIAGNOSE=1`): semantic veto 25 (almost all with rule scores far below the match line as well), place conflict 15 (one multi-city event), no specific shared anchor 3, weekday 2, time gap 1, primary-clause guard 1, rule thresholds 10, pairwise match not admitted by the event 1. At 0.70 the remaining 53 are: veto 25, places 15, rule 5, no specific anchor 3, weekday 2, time gap 1, primary clause 1, event admission 1. Of the labeled pairs the rules link, the lowest cosine is 0.60; the three false pairs at 0.65 all involve one article (`doc-0655`) with one shared anchor and at most one shared keyword.

### Authored corpus (49 reports, 24 labeled pairs)

| Configuration | TP | FP | FN | Pairs |
| --- | --- | --- | --- | --- |
| v7 (`1417703` matcher, local run) | 19 | 2 | 5 | misses add `f01-a+f01-b`, `f01-a+f01-c` (the toll-after headline) |
| v8, and v8 with rescue 0.70 / score without cosine / strict off / consequence terms | 21 | 2 | 3 | unchanged from the CI line |
| v8 with the veto skipped for rule matches | 21 | 6 | 3 | adds the four `f02` same-night pairs |
| Rescue 0.70, veto skipped for rule matches, strict rule off | 20 | 8 | 4 | adds `f02` and two `f10` pairs, loses `f10-c+f10-d` |

### Decisions

| Design point (#509) | Decision | Evidence |
| --- | --- | --- |
| Semantic veto (cosine < 0.55) on pairs that pass every deterministic gate | Keep as is | Tune +1 pair at most; the authored same-night negatives (`f02`) merge as soon as the veto spares rule matches |
| `score = max(ruleScore, cosine)` | Keep as is | No change on tune, holdout or authored corpus; removing it can only drop admissions, and nothing measured asks for it |
| Common-actor guard in matching | Not adopted | Needs week-scale actor frequencies (`commonStoryTerms`, ≥ 10 events) the corpora cannot supply; the holdout false merge was a background-clause bridge, not a shared head of state; the discount stays in developing-story links (#462) |
| >12 h strict rule (`what ≥ 0.35`, three shared terms) | Keep | Tune +1; the authored `f10` family merges without it |
| Rescue, search, evacuation terms as consequences (#503 limit) | Not adopted | No effect anywhere: the Malatya primary clause also carries "rubble"; a boundary rule needs labeled cases |
| Semantic rescue cutoff | 0.82 → 0.70, matcher v9 | Tune knee (40/0 at 0.68–0.70, 38/0 at 0.72, 40/3 at 0.65); holdout once: 22/0/16 |

### On-device model outcomes (#508, local)

`./test.sh --model-outcome-check` (new, opt-in) ran `ArticleAnalyzer` with the real model over three authored reports (a council vote, a mall shooting with three dead, an air strike killing twelve): all three answered (`apple.foundation-model`, version 3, 314–348 character summaries) and the repeat request gave the same outcome, so with `permissiveContentTransformations` and the prompt line the model does not refuse ordinary violent news. The oversized-prompt probe (200,000 characters) threw `FoundationModels.LanguageModelError`, the macOS 27 type that replaces the deprecated `LanguageModelSession.GenerationError`: it bypassed the mapping, logged nothing and would have left a provisional result that is re-requested on every open. This PR maps `LanguageModelError` (guardrail, refusal, context size, unsupported language, guide, capability and transcript content → final; rate limit and timeout → retry later) and `SystemLanguageModel.Error.assetsUnavailable` (retry later) when built with the macOS 27 SDK, keeps cancellation untouched, and tests the mapping with constructed errors. The reopen check in the app itself was not run (no windows opened); the version-3 persistence path is covered by the existing deterministic tests.

### Still open

- Place conflicts inside one multi-city event (15 tune misses) and veto'd pairs with weak rule evidence (25) are the remaining recall; both need a boundary decision on labeled cases, not a threshold.
- The authored corpus floors stay at TP ≥ 21, FP ≤ 2 (unchanged by v9). The act-class veto (#522, matcher v10) raised them to TP ≥ 22, FP ≤ 0 ([unified intelligence audit](2026-10-24-unified-intelligence.md)).
