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

Before (matcher v7, fixture floors open): pending CI run.

After (matcher v8): pending CI run.

Both lines are copied from the hosted test log of the PR; the fixture's `expected` block is tightened to the measured "after" result.

## Deliberately unchanged, handed to #509

- Semantic veto (cosine < 0.55) removes pairs that pass every deterministic gate.
- `EventPairAssessment.score = max(ruleScore, cosine)` makes the whole-event mean threshold (0.45) dead code when embeddings exist.
- No common-actor guard in matching (the mechanism behind every wrong link in the #314 audit).
- The >12 h strict rule (`what ≥ 0.35`, three shared terms), kept on 17 October.

Each needs the holdout replay before and after PR A, with the command recorded in #509.

## Foundation Models on sensitive news (PR B, #507–#508)

Pending; findings are recorded in #508.

## Limits

- No local toolchain: nothing here was compiled or run outside hosted CI.
- The authored corpus is regression evidence written by the implementer; it cannot establish release precision.
- The 97% precision target and the holdout numbers are unchanged until #509 runs.
