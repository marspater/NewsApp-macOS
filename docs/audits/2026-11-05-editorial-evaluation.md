# Phase 0 editorial evaluation matrix — 5 November 2026

Status: prerequisite fixture and measurement harness. This must be completed and reviewed before new Core ML or vDSP calls are added for this pipeline.

## Run

```sh
bash script/test_editorial_evaluation.sh
```

Options:

- `--output PATH` writes the JSON matrix to a chosen path.
- `--database PATH` retains the seeded SQLite database for inspection; without it, the database is temporary and removed after the run.
- `--seed INTEGER` changes the deterministic fixture seed (default `20261105`).

The default JSON output is date-stamped under `docs/benchmarks/`. The script uses Python's standard library and SQLite FTS5 only. It does not open the user's library, make network requests, run Core ML, call Accelerate/vDSP, alter production schema, or change production consumers.

## Seeded corpus

The controlled corpus contains exactly 5,000 articles across 50 event clusters:

| Scenario | Articles | Construction |
|---|---:|---|
| Breaking spikes | 2,000 | 20 events with 80 independent reports concentrated into a 27-minute spike and an earlier baseline |
| Slow weekend | 1,500 | 15 events with independent reports spaced across 72 hours |
| Syndication | 1,500 | 15 events with five wire stories each republished by twenty outlets; each wire story keeps one originating publisher identity |

It also seeds 5,000 event passages, 10,000 candidate sentences, event burst windows, 10 ranking queries with 500 candidates each, 50,000 impression rows, and a fixed 85/15 core/discovery recommendation fixture.

The text and labels are deterministic synthetic controls. They are useful for validating routing, database operations, timing collection and metric calculation. They are not manually adjudicated natural-language ground truth.

## Evaluation matrix

| Module | Quality metric | Performance / hardware metric | Phase 0 status |
|---|---|---|---|
| Novelty & extraction | Net-new fact precision | ANE spin-up, ANE/CPU power, vector-cache hit rate | FTS5 same-event candidate recall and low-priority fallback routing are exercised. Net-new precision is pending. Exact-text reuse is reported only as a cache-opportunity upper bound, not a hit rate. |
| Momentum | Burst accuracy, false-positive rate | Database insert/update latency | Labeled burst/quiet/syndication windows and a distinct-wire-group volume-floor sweep are measured. This is not MACD accuracy. |
| Ranking | NDCG@10, intra-list semantic diversity | Ranking latency across 500 candidate vectors | A source-Elo NDCG@10 baseline and 500-row metadata sort timing are measured. MMR/vector diversity and vector ranking latency are pending. |
| Personalization | Recommendation relevance, topic discovery rate | Impression-log storage, update cost | Synthetic 85/15 exposure and reward/impression rows are measured. These are fixture controls, not an EWMA preference model. |

Metrics that need the future model/vector implementations are explicitly emitted as null with a status explaining why. Phase 0 does not fake those measurements.

## Reading the results

- The momentum volume-floor sweep counts distinct wire groups and originating publishers in the labeled window. The single-wire control has 20 local outlet rows but one independent report and one originating publisher. This is only a pre-MACD gate study; it does not select a production threshold.
- The ranking NDCG baseline is source-Elo-only. It is not an MMR result.
- The recommendation relevance and discovery rates are evaluated against synthetic topic labels and a fixed exposure split. They are not evidence of a learned user profile.
- ANE spin-up, ANE/CPU power draw, vector-cache hit rate, MMR semantic diversity and EWMA vector update cost require later Apple-silicon runs after this Phase 0 gate is accepted.
- Real novelty precision, MACD burst accuracy and MMR ranking quality still require manually adjudicated tune/holdout datasets.

## Phase ordering

1. **Phase 0:** build, run and review this seeded database and evaluation matrix.
2. **Phase 1:** only after Phase 0, implement FTS5/semantic novelty, entity anchoring, cached sentence embeddings and extractive vDSP selection.
3. **Phase 2:** implement MACD using publication timestamps, distinct independent wire groups and an empirically selected volume floor.
4. **Phase 3:** implement MMR using source Elo, momentum and Phase 4 preference signals, with continuous temporal decay.
5. **Phase 4:** implement impression-backed rewards, EWMA interest vectors and a fixed 15% adjacent-topic Discovery allocation; defer UCB1 until impression volume is statistically sufficient.
6. **Deferred/rejected:** keep the temporal knowledge graph until Entity Dossiers; do not introduce DPP, Kleinberg, NLI or generative model dependencies.

No Phase 1–4 production algorithm is part of this Phase 0 change.
