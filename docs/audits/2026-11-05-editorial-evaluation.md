# Phase 0 editorial evaluation matrix — 5 November 2026

Status: prerequisite fixture and measurement harness, with fixture validation separate from independent review acceptance. Both must complete before new Core ML or vDSP calls are added for this pipeline. Passing Phase 0 permits algorithm experiments; it does not establish production editorial quality.

## Run

```sh
python3 -m unittest discover -s script/evaluation -p 'test_editorial*.py'
bash script/test_editorial_evaluation.sh
```

Options:

- `--output PATH` writes the JSON matrix to a chosen path.
- `--database PATH` retains the seeded SQLite database for inspection; without it, the database is temporary and removed after the run.
- `--seed INTEGER` changes the deterministic fixture seed (default `20261105`).

The default JSON output is date-stamped under `docs/benchmarks/`. Existing database, SQLite sidecar and report paths are never deleted or overwritten; choose a new path for each run. The script uses Python's standard library and SQLite FTS5 only. It does not open the user's library, make network requests, run Core ML, call Accelerate/vDSP, alter production schema, or change production consumers.

## Seeded corpus

The controlled corpus contains exactly 5,000 articles across 50 event clusters:

| Scenario | Articles | Construction |
|---|---:|---|
| Breaking spikes | 2,000 | 20 events with 80 independent reports concentrated into a 27-minute spike and an earlier baseline |
| Slow weekend | 1,500 | 15 events with independent reports spaced across 72 hours |
| Syndication | 1,500 | 15 events with five wire stories each republished by twenty outlets; each wire story keeps one originating publisher identity |

It also seeds 5,000 event passages, 10,000 candidate sentences, event burst windows, 10 ranking queries with 500 candidates each, 50,100 impression rows (including 100 repeated exposures), and a fixed 85/15 core/discovery recommendation fixture.

The text and labels are deterministic synthetic controls. They validate routing, database operations, timing collection and metric calculation. They are not manually adjudicated natural-language ground truth. Later model-reviewed labels must retain their provenance and disagreement handling; neither label source is described as human gold.

Retrieval derives queries from passage text and limits the baseline to reports available at the replay clock, excluding the current report. Expected labels are used only to score the resulting route. Ranking uses equal source weights and a stable article-ID tie-break independent of relevance labels. Impressions cannot precede article availability; scroll, click and save times remain distinct.

## Evaluation matrix

| Module | Quality metric | Performance / hardware metric | Phase 0 status |
|---|---|---|---|
| Novelty & extraction | Net-new fact precision | ANE spin-up, ANE/CPU power, vector-cache hit rate | FTS5 same-event candidate recall and persisted low-priority semantic-fallback queue routing are exercised. Net-new precision is pending. Exact-text reuse is reported only as a cache-opportunity upper bound, not a hit rate. |
| Momentum | Burst accuracy, false-positive rate | Database insert/update latency | Labeled burst/quiet/syndication windows and a distinct-wire-group volume-floor sweep are measured. This is not MACD accuracy. |
| Ranking | NDCG@10, intra-list semantic diversity | Ranking latency across 500 candidate vectors | A neutral-source NDCG@10 baseline and 500-row metadata sort timing are measured. MMR/vector diversity and vector ranking latency are pending. |
| Personalization | Recommendation relevance, topic discovery rate | Impression-log storage, update cost | Synthetic 85/15 exposure and reward/impression rows are measured. These are fixture controls, not an EWMA preference model. |

Metrics that need the future model/vector implementations are explicitly emitted as null with a status explaining why. Phase 0 does not fake those measurements.

## Acceptance contract

Counts alone do not pass the gate. Validation must assert historical same-event retrieval, lexical-hit and lexical-miss routing, wire deduplication, each 500-candidate ranking set, valid impression chronology and reward signs, and adjacent underexposed Discovery exposure. Broken deterministic controls must fail the command and CI. Unit tests include hand-calculated NDCG examples, label-independent ties and negative controls. Reports retain seed, commit, runtime versions and logical data/label hashes so repeated runs can compare data and quality results while excluding timing and output-path differences.

Fixture validation does not establish independent review acceptance, local hardware measurements or hosted CI results. Generated matrix reports always set `review_acceptance` to `pending_independent_review`; review acceptance is recorded separately. Review receipts and completed command results belong in the issue and dated evidence after execution.

## Reading the results

- The momentum volume-floor sweep counts distinct wire groups and originating publishers in the labeled window. The single-wire control has 20 local outlet rows but one independent report and one originating publisher. The CI job uploads the synthetic matrix JSON and SQLite file as a 14-day workflow artifact. This is only a pre-MACD gate study; it does not select a production threshold.
- The ranking NDCG baseline uses equal source weights and stable IDs. There is no publisher-trust or source-Elo system in this change. It is not an MMR result.
- The recommendation relevance and discovery rates are evaluated against synthetic topic labels and a fixed exposure split. They are not evidence of a learned user profile.
- ANE spin-up, ANE/CPU power draw, vector-cache hit rate, MMR semantic diversity and EWMA vector update cost require later Apple-silicon runs after this Phase 0 gate is accepted.
- Production novelty precision, MACD burst accuracy and MMR ranking quality require separately reviewed tune/holdout datasets. Split by event and syndicated-copy group, freeze parameters before holdout evaluation, and state whether labels are synthetic or model-reviewed.

## Phase ordering

1. **Phase 0:** build, run and review this seeded database and evaluation matrix.
2. **Phase 1:** only after Phase 0, implement FTS5/semantic novelty, entity anchoring, cached sentence embeddings and extractive vDSP selection.
3. **Phase 2:** implement MACD using publication timestamps, distinct independent wire groups and an empirically selected volume floor.
4. **Phase 3:** implement MMR using equal source weights and measured momentum, with continuous temporal decay and a neutral optional preference input until Phase 4.
5. **Phase 4:** implement opt-in impression-backed rewards, EWMA interest vectors and a fixed 15% adjacent, underexposed-topic Discovery allocation carried across small batches. Raw impressions expire after 30 days; disabling stops collection and reset clears impressions and the derived profile. Personalization does not reorder chronological lists or global importance. UCB1 remains deferred.
6. **Deferred/rejected:** keep the temporal knowledge graph until Entity Dossiers; do not introduce DPP, Kleinberg, NLI or generative model dependencies.

No Phase 1–4 production algorithm is part of this Phase 0 change.

## Local verification — 6 November 2026

- All 19 editorial Python regressions passed, including corrupt-index, chronology, reward and exposure failure controls.
- The full repository `./test.sh` regression suite passed locally with isolated temporary files and caches; compiler source-location warnings were non-fatal.
- Two independent fixed-seed matrix runs reproduced the logical data and label hashes with zero routing mismatches. Independent review accepted Phase 0 for algorithm experiments only.
- Logical fixture SHA-256: `8ef6484ba7b805d42100b8ed42bd77f0761efa32da6566561640a8cd44fd45e9`.
- Original label projection SHA-256: `ee7f749bf2b51471bba4671f6cd68df61f020502fdb686a4e9f8b93891277ec7`.
- Neutral-source NDCG@10: `0.14379946271267668`. This is a synthetic metadata baseline, not recommendation quality or MMR accuracy.
- The availability-index defect found by the failing end-to-end gate was corrected before acceptance. The report retains source hashes alongside the base commit for uncommitted verification.
- Local runs used Python 3.15.2 and SQLite 3.54.1. Hosted CI, hardware energy measurements and production editorial quality are not established by these results.
- Follow-up review cleanup split schema and validation helpers and replaced process-based revision lookup with direct Git metadata reads. All 22 Python regressions pass, including loose, detached and packed linked-worktree revision controls; logical fixture and label hashes remain unchanged.
- Subsequent review added passage entity/lexical routing labels and recommendation slot type to the dedicated label fingerprint, and derived the wire control count from replay. All 24 Python regressions pass. The updated label SHA-256 is `5b704dc0d6a1d0f334977dc0e3301f39da3928c079a322aa522297d4c645f690`; the logical fixture hash is unchanged. The original receipt above records the earlier projection.

- Current-main follow-up fixes required passage-class and historical-miss coverage independently of observed labels. Retained SQLite size is measured after all fallback writes and a successful WAL checkpoint; regression coverage checks the retained file and all 750 queue rows. The full Xcode regression suite passed after merging main at `0bdd34e`. Generated reports remain pending review by design; the separate receipt above accepts experiments only.
