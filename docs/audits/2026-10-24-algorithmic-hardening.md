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

## Second pass (PR C, #513–#515)

| # | Defect | Change | Test |
| --- | --- | --- | --- |
| #513 | A quote-only search term became an empty FTS5 phrase (`""*`), which FTS5 rejects, so the whole search failed. | Terms empty after quote stripping are dropped; no FTS join when none remain. | `testFTS5SearchAndOperators` |
| #514 | The extractive summarizer compared whitespace-split words, so "Westfield:" never matched "westfield"; ties broke on an unstable sort. | `MuteRules.words` on both sides; position tie-break. | `testArticleAnalyzerStructuredOutputAndFallbacks` |
| #515 | `DateParser` rejected `yyyy-MM-dd` and zone-less `yyyy-MM-dd'T'HH:mm:ss`, leaving such stories undated and unclusterable. | Both forms accepted, UTC assumed, after the existing formats. | `testDateParsing` |

Reviewed and left alone, with the reason: `EventMatchKey.language` on short headlines (needs holdout evidence, #509); `NewsCategory` keyword ties and brand words such as "apple" (needs labeled data); ambiguous country names "Georgia" and "Jordan" as places (recall vs precision trade, #509); rescue, search and evacuation as consequence terms (boundary-rule decision, #509).

## Limits

- No local toolchain: nothing here was compiled or run outside hosted CI.
- The authored corpus is regression evidence written by the implementer; it cannot establish release precision.
- The 97% precision target and the holdout numbers are unchanged until #509 runs.
