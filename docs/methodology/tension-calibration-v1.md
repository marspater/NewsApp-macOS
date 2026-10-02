# News tension — calibration methodology v1

Status: Calibrated on frozen historical sample corpus. Issues [#158](https://github.com/marspater/NewsApp-macOS/issues/158) and [#160](https://github.com/marspater/NewsApp-macOS/issues/160) under Phase I ([#99](https://github.com/marspater/NewsApp-macOS/issues/99)).
Normative companion to: [`docs/methodology/tension-index-v1.md`](tension-index-v1.md).
Implementation: [`Sources/Intelligence/TensionMethodology.swift`](../../Sources/Intelligence/TensionMethodology.swift), [`Sources/App/AppSettings.swift`](../../Sources/App/AppSettings.swift), [`Sources/Coordinators/FeedManager.swift`](../../Sources/Coordinators/FeedManager.swift).
Evaluation runner: [`script/evaluation/calibrate_tension.py`](../../script/evaluation/calibrate_tension.py), [`script/test_tension_calibration.sh`](../../script/test_tension_calibration.sh).

---

## 1. Executive Summary & Calibration Objectives

The News Tension Index measures **what a fixed panel of international news feeds reported** about unique events of armed conflict, disaster, civil unrest, coercion, and emergencies on each observation day. It is a deterministic property of the corpus and editorial choices, not an objective index of world danger or risk.

As specified in methodology v1 ([#157](https://github.com/marspater/NewsApp-macOS/issues/157)), no scores or weights were invented prior to calibration on an empirical historical sample. This document establishes:
1. **Calibrated weights and multipliers** for event types, orders of magnitude, explicit escalation signals, and regional consensus breadth.
2. **Continuous monotonic saturation function** mapping raw event score sums to a bounded 0–100 index without arbitrary hard cliffs.
3. **Trailing 7-day EMA smoothing** that strictly preserves the gap invariant: **insufficient or missing days are gaps (`nil`), NEVER zero**, and never inject artificial zeros into smoothed series.
4. **Opt-in collection architecture beyond user subscriptions** ([#160](https://github.com/marspater/NewsApp-macOS/issues/160)), fetching the 12 panel feeds into SQLite without notifying or disrupting the reader's personal feed unread stream.

---

## 2. Historical Sample Corpus Benchmark

Calibration was conducted against the frozen 14-day historical sample fixture ([`Tests/Fixtures/tension-corpus/historical-sample.json`](../../Tests/Fixtures/tension-corpus/historical-sample.json)). The corpus spans all 12 panel feeds across 6 macro-regions and includes hard negatives, reversals, and edge cases.

### Corpus Classification Results

| Metric | Sample Total | Correct | Accuracy |
| :--- | :--- | :--- | :--- |
| **Event Type Accuracy** | 14 | 14 | **100.0%** |
| **Deaths Magnitude Accuracy** | 14 | 14 | **100.0%** |
| **Affected Magnitude Accuracy** | 14 | 14 | **100.0%** |
| **Escalation Signal Accuracy** | 14 | 14 | **100.0%** |

### Evaluated Edge Cases & Classifier Robustness
1. **Negation Protection:** Cues preceded within 3 words by negation tokens (`no`, `not`, `denied`, `rejected`, `ruled out`) produce 0 false positives (Day 9: "no airstrikes", "denied a troop buildup" $\rightarrow$ Type: `nil`, Raw Score: `0.0`, Index: `0.0`).
2. **Reversals:** De-escalation cues followed within 3 words by failure tokens (`collapsed`, `failed`, `violated`) correctly cancel de-escalation and detect conflict renewal (Day 10: "ceasefire collapsed", "peace talks failed" $\rightarrow$ Armed Conflict, Escalating).
3. **Historical Years Filter:** 4-digit numbers from 1900 to 2099 without thousands separators are classified as calendar years and skipped from casualty counters (Day 11: treaty years 1995, 1980, 2024 $\rightarrow$ Casualties: `notReported`, Raw Score: `0.0`).
4. **Coverage Thresholds:**
   - Feeds $< 7$: flagged as `insufficient` (Day 12: 5 feeds reporting).
   - Regions $< 4$: flagged as `insufficient` (Day 13: 6 feeds reporting, but from only 2 regions: Europe & North America).
   - 0 feeds: flagged as `noData` (Day 14).

---

## 3. Mathematical Formulation & Calibrated Weights

### 3.1 Event Raw Score
For each unique event $e$ on day $d$:
$$\text{Score}(e) = W_{\text{type}}(e) \times M_{\text{mag}}(e) \times E_{\text{esc}}(e) \times B_{\text{breadth}}(e)$$

If the event has no detected type ($W_{\text{type}} = \text{nil}$), $\text{Score}(e) = 0.0$.

#### Type Weights ($W_{\text{type}}$)
- **Armed Conflict:** 10.0 (high kinetic impact, military operations, missile strikes, frontlines)
- **Terrorism:** 8.0 (mass violence against civilian populations)
- **Disaster:** 6.0 (major geophysical / meteorological events: earthquakes, tsunamis, cyclones)
- **Civil Unrest:** 4.0 (protests, riots, curfews, martial law)
- **Coercion:** 4.0 (sanctions, blockades, weapons tests, diplomatic ultimatums)
- **Health Emergency:** 4.0 (pandemics, severe outbreaks, WHO emergency declarations)
- **Cyberattack:** 3.0 (critical infrastructure disruption, ransomware)

#### Magnitude Multiplier ($M_{\text{mag}}$)
Computed as the maximum of reported deaths and affected figures:
$$M_{\text{mag}} = \max\left(M_{\text{deaths}}, M_{\text{affected}}\right)$$

| Magnitude Bin | Figure Range | Deaths Multiplier ($M_{\text{deaths}}$) | Affected Multiplier ($M_{\text{affected}}$) |
| :--- | :--- | :--- | :--- |
| `notReported` | 0 | 1.0 | 1.0 |
| `units` | 1 – 9 | 1.2 | 1.1 |
| `tens` | 10 – 99 | 1.5 | 1.25 |
| `hundreds` | 100 – 999 | 2.0 | 1.5 |
| `thousands` | 1,000+ | 2.5 | 2.0 |

#### Escalation Multiplier ($E_{\text{esc}}$)
- `escalating`: **1.3**
- `deescalating`: **0.7**
- `noSignal`: **1.0**
- `mixed`: **1.0**

#### Regional Breadth Multiplier ($B_{\text{breadth}}$)
Measures the geographic consensus of reporting publishers across macro-regions:
- 1 region: **0.85**
- 2 regions: **1.00** (baseline international consensus)
- 3 regions: **1.15**
- 4 or more regions: **1.30**

---

### 3.2 Daily Aggregation & Continuous Scaling
For an observation day $d$ with `.sufficient` coverage:
$$\text{RawScore}(d) = \sum_{e \in \text{Events}(d)} \text{Score}(e)$$

The raw daily score is transformed into a continuous index $I(d) \in [0, 100]$ using an exponential saturation function:
$$I(d) = 100 \times \left(1 - e^{-\frac{\text{RawScore}(d)}{S}}\right)$$
where $S = 25.0$ is the scale factor calibrated to pin active median days ($\text{Raw} \approx 15\text{--}20$) to $\approx 45\text{--}55$, while quiet days remain strictly at 0.0 and extreme escalation saturates smoothly towards 100 without hard threshold clipping.

---

### 3.3 Trailing 7-Day EMA Smoothing Across Gaps
To prevent daily volatility from obscuring trends while never treating missing data as zero:
- Smoothing parameter: $\alpha = \frac{2}{7 + 1} = 0.25$ (trailing 7-day exponential moving average).
- For sufficient day $t$:
  $$S_t = \begin{cases}
  I(t) & \text{if first valid day} \\
  \alpha I(t) + (1 - \alpha) S_{\text{prev}} & \text{where } S_{\text{prev}} \text{ is the last valid smoothed index}
  \end{cases}$$
- **The Gap Rule:** If day $t$ has `.insufficient` or `.noData` coverage:
  $$I(t) = \text{nil}, \quad S_t = \text{nil}$$
  $S_{\text{prev}}$ is preserved unchanged. **Zero is NEVER substituted for missing days.** When sufficient data resumes on day $t + k$, smoothing continues from $S_{\text{prev}}$.

---

## 4. Empirical Sample Calibration Results

| Day ID | Coverage | Raw Score | Daily Index | Smoothed (7d EMA) | Assessment Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `day-01` | sufficient | 53.30 | **88.1** | **88.1** | Multi-frontline offensive, heavy casualties, 5 regions |
| `day-02` | sufficient | 15.60 | **46.4** | **77.7** | M7.4 earthquake, hundreds dead, thousands displaced |
| `day-03` | sufficient | 8.97 | **30.1** | **65.8** | National capital unrest, curfew, tear gas |
| `day-04` | sufficient | 6.76 | **23.7** | **55.3** | Ballistic missile test, sanctions, ultimatums |
| `day-05` | sufficient | 8.05 | **27.5** | **48.3** | Formal ceasefire, troop withdrawal, prisoner swap |
| `day-06` | sufficient | 0.00 | **0.0** | **36.3** | Routine international trade forum (untyped) |
| `day-07` | sufficient | 3.00 | **11.3** | **30.0** | Critical infrastructure ransomware attack |
| `day-08` | sufficient | 6.90 | **24.1** | **28.5** | Cholera outbreak public health emergency |
| `day-09` | sufficient | 0.00 | **0.0** | **21.4** | Hard negative: explicit denials and negations |
| `day-10` | sufficient | 19.50 | **54.2** | **29.6** | Reversal: ceasefire collapse, shelling resumed |
| `day-11` | sufficient | 0.00 | **0.0** | **22.2** | Hard negative: historical treaty commemoration |
| `day-12` | insufficient | *nil* | *nil* | *nil* | 5 feeds reporting ($< 7$ required threshold) |
| `day-13` | insufficient | *nil* | *nil* | *nil* | 2 regions reporting ($< 4$ required threshold) |
| `day-14` | noData | *nil* | *nil* | *nil* | 0 feeds reporting |

---

## 5. Opt-In Collection Architecture (#160)

### 5.1 Privacy & Bandwidth Protection
By default, the application only contacts feeds the user has explicitly subscribed to (`appSettings.tensionCollectionOptIn == false`).
When the user opts in:
1. `appSettings.effectiveFeedURLs` expands to include the 12 panel URLs alongside `appSettings.feedURLs`.
2. Duplicate feed URLs are coalesced so user-subscribed panel feeds are never fetched twice.
3. The user's personal feed list in UI (`SubscriptionsTab`) and OPML export are unmodified.

### 5.2 Notification Isolation
Articles fetched for panel feeds not subscribed to by the user are stored in SQLite (providing data for `tensionCorpus(day:feedURLs:)`) but are strictly filtered out of `notifyBatch`. Unread notification alerts are only dispatched for articles where `userSubscribed.contains(article.identityFeedURL)`.
