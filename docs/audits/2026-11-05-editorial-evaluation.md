# Editorial algorithm evaluation harness — 5 November 2026

Status: first engineering/performance slice for W8 (#1000), not an editorial-quality acceptance run.

## Run

\`\`\`sh
bash script/test_editorial_evaluation.sh
\`\`\`

An optional first argument selects the JSON output path. The default is a date-stamped file under \`docs/benchmarks/\`. The command builds the existing headless test runner in optimized mode and runs only \`Tests/BriefingSignalsTests.swift\` with the opt-in evaluation flag.

The workload creates a temporary SQLite database. It does not open the user's library, change preferences, make network requests, or write story content to logs. It refuses to start while Low Power Mode or serious thermal state is active.

## What it measures

- 5,000 synthetic articles across 20 synthetic publishers inserted into SQLite.
- The bundled 384-dimensional MiniLM sentence encoder, including a short warm-up and the measured 5,000-item batch.
- Embedding persistence and read-back through the existing \`article_embeddings\` table.
- Seven hybrid searches through the shipped FTS5 + SQLite \`news_cosine\` path, reporting median wall time.
- A lexical-only FTS5 query followed by 1,000 bounded MaxSim passage comparisons. Each passage compares against at most 32 lexical candidates; only lexical misses use the 24-vector semantic fallback. Similarity uses the existing vDSP cosine helper.
- MMR selection from 5,000 candidates down to ten, with NDCG@10, mean intra-list similarity, distinct-topic count and distinct-publisher count.
- 100 replays of a synthetic MACD event stream, including the velocity, MACD line and histogram.

The JSON records seed, Core ML inference, SQLite persistence/read-back, search, MaxSim and MMR timings, along with the thermal state before and after the work. Core ML wall time is measured; this does not claim to isolate ANE execution time.

## Interpretation and limits

This is a reproducible engineering workload, not a real-news holdout. The synthetic archive and topic relevance grades make it useful for regression-testing runtime, vector persistence, ranking mechanics and diversity metrics. They do not establish that NewsApp finds genuinely novel reporting or that a user prefers the resulting order.

The MaxSim benchmark exercises the retrieval/scoring boundary using FTS5 results and bounded vectors. It does not add a persistent passage table or change the production event-clustering pipeline. Production passage storage needs its own schema/migration review and input-generation guard.

The MACD primitive is not yet connected to Briefing priority, notification triage or Lead selection. Its volume floor and backfill handling need a manually labelled arrival/publication-time replay before replacing the existing six-hour rule.

MMR is a pure ranking primitive. The current Briefing and Lead consumers are intentionally unchanged. Event membership is not modified.

Do not use these synthetic results as the W5/W6/W7 release gate. The next quality step is an adjudicated, source-attributed corpus of (report, event) novelty labels and event-burst labels, plus relevance judgements for NDCG. Record the split and labelling protocol before threshold tuning; keep a holdout untouched.
