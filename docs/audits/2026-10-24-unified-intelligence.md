# Unified intelligence — 24 October 2026

Program #520, implemented from a cloud session without a Swift toolchain; every number here comes from hosted CI or from Mars's local runs, each labelled. The design is the organism described in #520: one stored signal record per article, pair decisions as the audit trail, an act-class veto as the deterministic substitute for a judge on the related-act boundary, then a measured learned layer.

## Baseline (main at `9b65d86`, matcher v8)

- Private English holdout (18 Oct, v6 numbers; v8 not yet measured, #509): precision 93.3%, recall 36.8%.
- Authored corpus `matcher-regressions-v1.json` on v8 (CI run 40068841897): TP 21 / FP 2 / FN 3. Both false pairs are f08-a+f08-d and f08-b+f08-d: the resignation over a botched execution merged into the execution's aftermath.
- Every recorded false merge on the holdout is two different acts by the same actors on the same day.

## PR 1 (#521): one word-splitting family

`MuteRules.foldedWords` added; four duplicate splitters removed. No measured number changes by design. CI: (run link added when green).

## PR 2 (#522): stored signals, act class, related-act links (matcher v9, schema v24)

| Change | Where | Effect |
| --- | --- | --- |
| `EventFeatures` is `Codable`, stored as JSON in `article_features` under `storageVersion` 1 | `EventClustering.prefetch`, `DatabaseEngine+Events` | A pass tags each article once ever instead of once per pass, repartition and relation lookup; the rematch trigger now also drops the embedding and pair rows of a changed headline |
| `ActClass` from the act clause's lemmas; `EventConflict.differentAct` | `ActClass.swift`, `EventMatcher.pairConflict` | Two known different acts never merge; `unknown` never vetoes |
| `pair_assessments` rows for match, related-act and borderline decisions | `EventClustering.record` | Audit trail per pair; related acts shown as earlier events in the overview |
| `--export-features` | `NewsTests.exportPairFeatures` | CSV of candidate-pair features and labels for the PR 4 fit; corpus ids only |

Authored corpus on v9 (gate 1, hosted CI run 40081886073): precision 1.000 (TP 22, FP 0), recall 0.917 (FN 2). Against v8 (TP 21 / FP 2 / FN 3): both false pairs (f08-a+f08-d, f08-b+f08-d) are gone, the resignation pair f08-c+f08-d is recovered, and the two f03 misses (the rescue report 20 h after the quake) remain. The fixture ratchet is TP ≥ 22 / FP ≤ 0.

Holdout (local, Mars, #526): before/after lines added when run.

Cue table decisions worth recording: "strike" is no cue (earthquakes, courts and air forces all strike); "rule" and "charge" are no cues ("rules out", "leads the charge"); "execution", "fire" and "explosion" are no cues (background nouns and accidents); "march" never reaches the classifier (month filter). Phrases: "steps down/aside" → resign, "opens fire" → shooting, "strikes down" → overturn, "critical condition" → injure.

## PR 3 (#523): one energy rule, final refusals, one banner per event

| Change | Where | Effect |
| --- | --- | --- |
| `IntelligencePolicy.allowsEnergy` | `FeedManager`, `OverviewGenerationCoordinator`, `WorldTensionService` | Three copies of the Low Power / thermal rule become one |
| `WorldTensionError.rejected`; estimate saved under the real hash when no reading exists; rejected hashes remembered in-process otherwise | `WorldTension.generate`, `assess` | A refusal no longer re-asks the model on every reload for the same headlines; an accepted reading is never overwritten |
| `NotificationService.representatives(of:events:)` | `FeedManager` after clustering | One banner per event, the strongest report; `triageAndNotify` unchanged |

No measured matcher number changes.

## Limits

- The act-class table encodes the corpus convention (one act, one event); it is small and tested, and every miss costs recall, never precision.
- The cross-publisher wire-copy miner and the pair model (PR 4–5) are not in this audit yet.
