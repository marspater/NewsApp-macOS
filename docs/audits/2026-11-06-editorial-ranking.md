# Editorial ranking experiment — 6 November 2026

Status: gated algorithm experiment for #999, stacked on momentum PR #1031 for issue #998. No consumer is enabled. Lead integration remains with Epic Z.

The pure selector accepts at most 500 already-formed stories, normalized 384-dimensional vectors with matching model provenance, publication dates and optional preference scores. It returns up to 50 stable story IDs. Equal source weights are represented in the supplied relevance; there is no source-trust score. MMR subtracts the maximum nonnegative cosine similarity to any selected story, multiplied by continuous publication-gap decay. Missing vectors carry zero similarity penalty. Stable IDs resolve ties. Cancellation is checked between bounded selections. Parameters are explicit experimental inputs, not shipping defaults; optional preference weight defaults to zero.

Independent review found no correctness blocker for experiments. Hand examples cover relevance-only selection, duplication, temporal decay, stable ties, missing vectors, invalid models, cancellation and retained penalties from earlier selections.

The constructed evaluation has ten 500-candidate topic judgement sets and one-hot vectors. Relevance comes from normalized retrospective Phase 2 MACD controls. With relevance weight 0.7 and six-hour temporal decay, mean NDCG@10 is 0.128571 for both the relevance baseline and MMR; pairwise semantic diversity changes from 0 to 1. Per-set NDCG changes substantially, so an unchanged mean does not establish relevance preservation for individual interests. These labels and vectors are synthetic controls, not independently labelled real-news gold. Neither the current Briefing selection nor a frozen real-news holdout was measured.

An Apple M5 / 24 GiB Debug run after the main refresh measured 500-vector top-10 selections at 65.39–113.06 ms (median 74.67 ms). This includes validation, with no model load. Release latency, real-vector quality, energy and current-selector comparison remain pending. The local report contains source hash and individual samples at `/private/tmp/news-editorial-intelligence/reports/ranking-main-refresh.json`. It is local evidence, not a CI result.

Before consumer rollout: freeze parameters on event/copy-disjoint tuning data, evaluate a separately reviewed holdout against current selection, measure cold/warm target hardware costs, and coordinate publication with Epic Z. This selector has no background tasks, persistence writes or event-membership mutations.
