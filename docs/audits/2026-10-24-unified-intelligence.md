# Unified intelligence — 24 October 2026

Program #520, implemented from a cloud session without a Swift toolchain; every number here comes from hosted CI or from Mars's local runs, each labelled. The design is the organism described in #520: one stored signal record per article, pair decisions as the audit trail, an act-class veto as the deterministic substitute for a judge on the related-act boundary, then a measured learned layer.

## Baseline (main at `9b65d86`, matcher v8)

- Private English holdout (18 Oct, v6 numbers; v8 not yet measured, #509): precision 93.3%, recall 36.8%.
- Authored corpus `matcher-regressions-v1.json` on v8 (CI run 40068841897): TP 21 / FP 2 / FN 3. Both false pairs are f08-a+f08-d and f08-b+f08-d: the resignation over a botched execution merged into the execution's aftermath.
- Every recorded false merge on the holdout is two different acts by the same actors on the same day.

## PR 1 (#521): one word-splitting family

`MuteRules.foldedWords` added; four duplicate splitters removed. No measured number changes by design. CI: (run link added when green).

## PR 2 (#522): stored signals, act class, related-act links (matcher v10, schema v24)

Written as matcher v9; #519 shipped the 0.70 semantic rescue as v9 first, so the act class ships as v10 on top of it.

| Change | Where | Effect |
| --- | --- | --- |
| `EventFeatures` is `Codable`, stored as JSON in `article_features` under `storageVersion` 1 | `EventClustering.prefetch`, `DatabaseEngine+Events` | A pass tags each article once ever instead of once per pass, repartition and relation lookup; the rematch trigger now also drops the embedding and pair rows of a changed headline |
| `ActClass` from the act clause's lemmas; `EventConflict.differentAct` | `ActClass.swift`, `EventMatcher.pairConflict` | Two known different acts never merge; `unknown` never vetoes |
| `pair_assessments` rows for match, related-act and borderline decisions | `EventClustering.record` | Audit trail per pair; related acts shown as earlier events in the overview |
| `--export-features` | `NewsTests.exportPairFeatures` | CSV of candidate-pair features and labels for the PR 4 fit; corpus ids only |

Authored corpus with the act class (hosted CI run 40081886073 before the merge with #519, and locally on the merged branch): precision 1.000 (TP 22, FP 0), recall 0.917 (FN 2). Against v8 (TP 21 / FP 2 / FN 3): both false pairs (f08-a+f08-d, f08-b+f08-d) are gone, the resignation pair f08-c+f08-d is recovered, and the two f03 misses (the rescue report 20 h after the quake) remain. The fixture ratchet is TP ≥ 22 / FP ≤ 0.

### Gate 1: private replay (local, 24 October 2026, #526)

English, judge off, corpus SHA-256 `868c62a0…`; receipts in `~/Documents/NewsHoldout-2026-10-03/unified-intelligence-2026-10-24/` (0700, not in the repository).

| Run | Tune (105 articles) | Holdout (49 articles) |
| --- | --- | --- |
| Before: `main` 4591a08, matcher v9 (receipt of #519) | TP 40 / FP 0 / FN 53 | TP 22 / FP 0 / FN 16 |
| After the merge, 4c7e3f0 | TP 39 / FP 0 / FN 54 | TP 22 / FP 0 / FN 16 |
| Final, with the fixes below | TP 40 / FP 0 / FN 53 | TP 22 / FP 0 / FN 16 |

Precision holds at 1.000 on both splits (gate 1 met); recall is unchanged. The one tune pair lost after the merge was a report of a hijacked flight's copilot "who tried to crash" it, classified `crash` and vetoed against the cockpit-attack reports of the same event; all six crash/attack vetoes on tune were gold pairs, so a crash and an attack no longer conflict. In the final run the act veto fires on 22 tune and 25 holdout pairs, all labelled different events, and on no gold pair. None of them was merged on v9 either, so the private data shows no precision gain: the act class earns its place on the authored corpus (both v8 false pairs) and as the related-act signal.

Feature export (`--export-features`, final run): tune 1,179 pairs (93 same event), holdout 356 (38). The export first wrote only pairs with a shared specific anchor or a gold label; it now writes every pair in the window that shares an anchor or a keyword, because all 16 holdout misses share no specific anchor: a head that keeps that gate cannot raise holdout recall (#524). Among conflict-free pairs without a specific anchor, the holdout has 16 same-event pairs and 2 different-event pairs, tune 3 and none.

### Review fixes before merge

- Related acts need more than one shared actor: the pair must also share at least two keywords, and the act conflict is checked last, so a pair with a place, figure or date contradiction is never a related act. The common-actor discount of #462 is not applied to these links yet.
- Cue table: "storm", "dismiss", "quit" and the dead "accord" cue are gone; "attack" counts only as a noun ("Zelensky attacks Trump over …" is words); a consequence report no longer conflicts with a vote or a ruling, whose headlines use the casualty words politically ("survives no-confidence motion", "kills the bill").
- "Earlier in This Story" applies the earlier-only filter before the three-link cap.
- Signals, vectors and pair decisions are stored after each batch, in one actor turn, and only for articles whose title and description still read as the pass saw them; a refresh that retitled a story mid-pass no longer gets the old headline's signals written back. A pair that no longer qualifies loses its stored row.

Cue table decisions worth recording: "strike" is no cue (earthquakes, courts and air forces all strike); "rule" and "charge" are no cues ("rules out", "leads the charge"); "execution", "fire" and "explosion" are no cues (background nouns and accidents); "march" never reaches the classifier (month filter). Phrases: "steps down/aside" → resign, "opens fire" → shooting, "strikes down" → overturn, "critical condition" → injure.

## PR 3 (#523): one energy rule, final refusals, one banner per event

| Change | Where | Effect |
| --- | --- | --- |
| `IntelligencePolicy.allowsEnergy` | `FeedManager`, `OverviewGenerationCoordinator`, `WorldTensionService` | Three copies of the Low Power / thermal rule become one |
| `WorldTensionError.rejected`; estimate saved under the real hash when no reading exists; rejected hashes remembered in-process otherwise | `WorldTension.generate`, `assess` | A refusal no longer re-asks the model on every reload for the same headlines; an accepted reading is never overwritten |
| `NotificationService.representatives(of:events:)` | `FeedManager` after clustering | One banner per event, the strongest report; `triageAndNotify` unchanged |

No measured matcher number changes.

Review fixes before merge: a saved refusal estimate no longer blocks the estimate of a newer headline set, and is not counted as an assessed day in the past-month comparison; the estimate is saved only if no assessment was saved meanwhile (checked inside the database actor); the in-process memo of refused inputs applies only while an assessment exists and not to Reassess. One banner per event applies to full notifications only (the summary modes still count every story and source), and its scoring runs off the main actor and only when notifications are on.

## PR 4 (#524): fitted head measured and not adopted; "Same Event" inclusions (schema v25)

`script/evaluation/fit_pair_head.py` (standard library) fits an L2 logistic regression over the exported pair features on tune's conflict-free pairs (hard conflicts keep vetoing), picks the lowest threshold with tune precision ≥ 0.95, and scores the holdout once. Pair level, private exports of the final #527 run:

| | Tune | Holdout |
| --- | --- | --- |
| Shipped rule (`is_match`) | precision 1.000, recall 0.419 (TP 39 / FP 0) | precision 0.875, recall 0.553 (TP 21 / FP 3) |
| Fitted head, threshold 0.698 | precision 0.961, recall 0.527 (TP 49 / FP 2) | precision 0.776, recall 1.000 (TP 38 / FP 11) |

Gate 2 fails: holdout precision drops. The result does not move with the regularization (0.3, 1, 3) or a tune precision target of 1.0 (holdout precision 0.80–0.83). Tune has only 59 conflict-free pairs, 9 of them different events, and the 12 conflict-free holdout negatives look like positives on these features. As #524 provides, the head is not shipped, so per-user calibration of it is not built either; the script stays as the measurement. The clustering replay never ran with a head because the pair screen already fails.

Inclusions: `event_inclusions` mirrors `event_exclusions`. "Same Event" on an "Earlier in This Story" row merges that event into the open one and records every pair across them; `EventMatcher.forced` makes a recorded pair a match inside the clusterer's `assessed`, which covers joining, creating, revalidation and fragment merging. Inclusion is transitive in every admission path: a report that matches one side is the same event as the other side, so later reports still join (without it, joining's all-pairs rule froze a combined event). Separation drops the member's inclusions and excludes it only from the side it was combined with, so its own event can form again; inclusion drops exclusions of the pairs it records, so the newer correction wins. The combine respects the 100-member cap, revalidation reads inclusions fresh, the matcher's own verdict is what `pair_assessments` records, and combining marks the event seen. `testEventInclusions` covers a vote and its protest that the rules keep apart: combined, the retitled vote report is re-matched into the event, a later vote report joins, separated a report is excluded only from the protest side, included again it returns. The story-row variant ("Same Event as…" with the same up to three earlier events) landed separately: an expanded event card loads the related events together with its members, so the submenu is ready before a context menu opens on a row; a failed lookup leaves it out. `--export-pairs` is not in this PR: its consumer is #525.

## Limits

- The act-class table encodes the corpus convention (one act, one event); it is small and tested, and every miss costs recall, never precision.
- The cross-publisher wire-copy miner and the pair model (PR 4–5) are not in this audit yet.
- On-device check of a vote/protest pair in the built app was not run (no test windows); the staged `./build.sh` passed.
