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

Authored corpus on v9 (gate 1): CI numbers added from the first run on this PR; the expected block is tightened to the measured result in the follow-up commit.

Holdout (local, Mars, #526): before/after lines added when run.

Cue table decisions worth recording: "strike" is no cue (earthquakes, courts and air forces all strike); "rule" and "charge" are no cues ("rules out", "leads the charge"); "execution", "fire" and "explosion" are no cues (background nouns and accidents); "march" never reaches the classifier (month filter). Phrases: "steps down/aside" → resign, "opens fire" → shooting, "strikes down" → overturn, "critical condition" → injure.

## Limits

- The act-class table encodes the corpus convention (one act, one event); it is small and tested, and every miss costs recall, never precision.
- The cross-publisher wire-copy miner and the pair model (PR 4–5) are not in this audit yet.
