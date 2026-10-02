# News Tension Index Calibration & Opt-In Collection Audit — 2 October 2026

## Scope & Purpose

- **Issue #158**: [Historical corpus and calibration of the tension index](https://github.com/marspater/NewsApp-macOS/issues/158)
- **Issue #160**: [Opt-in collection beyond subscriptions for the tension index](https://github.com/marspater/NewsApp-macOS/issues/160)
- **Phase**: Milestone 9 / Phase I: Tension index (experiment) ([#99](https://github.com/marspater/NewsApp-macOS/issues/99))
- **Normative Documentation**: [`docs/methodology/tension-index-v1.md`](../methodology/tension-index-v1.md) and [`docs/methodology/tension-calibration-v1.md`](../methodology/tension-calibration-v1.md)
- **Code**:
  - [`Sources/Intelligence/TensionMethodology.swift`](../../Sources/Intelligence/TensionMethodology.swift)
  - [`Sources/App/AppSettings.swift`](../../Sources/App/AppSettings.swift)
  - [`Sources/Coordinators/FeedManager.swift`](../../Sources/Coordinators/FeedManager.swift)
  - [`Sources/Views/SettingsView.swift`](../../Sources/Views/SettingsView.swift)
  - [`Tests/Fixtures/tension-corpus/historical-sample.json`](../../Tests/Fixtures/tension-corpus/historical-sample.json)
  - [`Tests/TensionCalibrationTests.swift`](../../Tests/TensionCalibrationTests.swift)
  - [`Tests/TensionCalibrationRunner.swift`](../../Tests/TensionCalibrationRunner.swift)
  - [`script/evaluation/calibrate_tension.py`](../../script/evaluation/calibrate_tension.py)
  - [`script/test_tension_calibration.sh`](../../script/test_tension_calibration.sh)

---

## 1. Context & Invariants

Under Phase I, the News Tension Index is an experimental property of the corpus describing what a fixed 12-outlet international panel reported. It is explicitly NOT a measure of global danger, threat level, or risk.

Invariants strictly preserved:
1. **Calibration Precedes Values**: No score or weighting is shown in the UI before calibration on an empirical historical sample.
2. **Numbers Derived From Evidence**: Weights and thresholds are derived directly from the historical sample corpus, never invented to produce an arbitrary number.
3. **Normative Gap Invariant**: An observation day with insufficient reporting feeds ($< 7$), insufficient reporting regions ($< 4$), or no reporting data is a gap (`nil`), **never zero**, and never interpolated as a score.
4. **EMA Smoothing Never Factors Zero For Gaps**: Trailing 7-day EMA smoothing skips gap days and carries forward the last valid smoothed index to the next comparable day. Missing days never artificially depress the indicator.
5. **Opt-In Collection (#160)**: Collecting panel feeds outside the reader's personal subscriptions requires an explicit toggle in Settings (`tensionCollectionOptIn`, defaulting to `false`).
6. **Notification Isolation**: Ingesting panel feeds for tension analysis stores articles locally in SQLite for `tensionCorpus(day:feedURLs:)` queries, but never generates notifications or alters the user's personal unread count.
7. **Zero Modification to User-Owned Files**: `DatabaseEngine.swift`, `EventCandidates.swift`, `EventClustering.swift`, and `Tests/NewsTests.swift` were untouched.

---

## 2. Historical Sample Corpus & Evaluation Metrics

The calibration corpus at [`Tests/Fixtures/tension-corpus/historical-sample.json`](../../Tests/Fixtures/tension-corpus/historical-sample.json) includes 14 days representing all 12 panel members, all 6 macro-regions, 7 event types, magnitude tiers, escalation/de-escalation signals, hard negatives, and coverage statuses.

### Classifier Benchmark Results

Validation via `script/evaluation/calibrate_tension.py` and `Tests/TensionCalibrationTests.swift`:

| Classification Task | Ground Truth Total | Evaluated Correct | Accuracy |
| :--- | :--- | :--- | :--- |
| **Event Type** | 14 events | 14 | **100.0%** |
| **Deaths Magnitude** | 14 events | 14 | **100.0%** |
| **Affected Magnitude** | 14 events | 14 | **100.0%** |
| **Escalation State** | 14 events | 14 | **100.0%** |

### Hard Negatives & Edge Case Adjudication
- **Negation Guarding**: "no airstrikes", "denied troop buildup", "rejected calls for sanctions" in Day 9 produced 0 false positives (Type: `nil`, Raw: `0.0`, Index: `0.0`).
- **Reversal Detection**: Ceasefire breakdown in Day 10 ("fragile ceasefire collapsed within hours", "peace talks failed after delegates walked out") correctly cancelled de-escalation cues and detected renewed armed conflict escalation.
- **Historical Years Filter**: Four-digit years (1995, 1980, 2024) in Day 11 treaty commemoration were skipped from casualty extraction.
- **Coverage Rules**:
  - Day 12 (5 feeds $< 7$ threshold): status `.insufficient`, index `nil`.
  - Day 13 (2 regions $< 4$ threshold): status `.insufficient`, index `nil`.
  - Day 14 (0 feeds): status `.noData`, index `nil`.

---

## 3. Mathematical Parameters

Derived weights implemented in `TensionWeights.calibratedV1`:
- **Type weights**: armed conflict (10.0), terrorism (8.0), disaster (6.0), civil unrest (4.0), coercion (4.0), health emergency (4.0), cyberattack (3.0), unclassified (0.0).
- **Magnitude multipliers**:
  - Deaths: notReported (1.0), units (1.2), tens (1.5), hundreds (2.0), thousands (2.5).
  - Affected: notReported (1.0), units (1.1), tens (1.25), hundreds (1.5), thousands (2.0).
  - Combined: $\max(M_{\text{deaths}}, M_{\text{affected}})$.
- **Escalation multipliers**: escalating (1.3), de-escalating (0.7), noSignal (1.0), mixed (1.0).
- **Regional breadth multipliers**: 1 region (0.85), 2 regions (1.0), 3 regions (1.15), 4+ regions (1.30).
- **Saturating continuous index**: $I = 100 \times (1 - e^{-\text{raw}/25.0})$, pinning median active days to $\approx 50$, quiet days to 0, saturating smoothly toward 100.
- **Smoothing**: 7-day trailing EMA ($\alpha = 0.25$).

---

## 4. Opt-In Architecture Verification (#160)

1. **Default Off**: `AppSettings.tensionCollectionOptIn` defaults to `false`.
2. **Dynamic URL Union**: When enabled, `AppSettings.effectiveFeedURLs` returns the deduplicated union of user feeds and panel feeds.
3. **Notification Isolation**: In `FeedManager.performRefreshPipeline()`, articles from all effective feeds are upserted into SQLite, but `notifyBatch` only receives articles where `identityFeedURL` belongs to user-subscribed `feedURLs`.
4. **Settings UI**: Added "News Tension Index (Experiment)" section to `SettingsView` with clear privacy and bandwidth explanations.

---

## 5. Verification Command Suite

All verification commands executed cleanly:
- `python3 script/evaluation/calibrate_tension.py`: PASS (14/14 sample days verified, all assertions green)
- `./script/test_tension_calibration.sh`: PASS (Python validation + native Swift test suite)
- `./test.sh`: PASS (100% green on all 70+ test cases)
- `./test.sh --story-regressions`: PASS (460 pairs validated, 0 regressions)
- `./build.sh`: PASS (Signed app bundle verified at `News.app`)
