# Coverage Sentiment Evaluation & Go/No-Go Decision — 2 October 2026

## Scope & Purpose

Issue #146 ("Evaluate optional sentiment of coverage") fulfills the final requirement of Phase F (Epic #96: "Timeline, perspectives, angle and sentiment"):
- Scope item 1: `[x] Evaluate on the corpus before any UI`
- Scope item 2: `[x] Ship only if evaluation justifies it`
- Acceptance requirement: *"Sentiment ships only if evaluation justifies it."*
- Plan Section 5 requirement: *"Sentiment: необов’язкова тональність тексту, не оцінка істинності чи небезпеки події. Нижчий пріоритет, ніж якість викладу та джерел."*
- Design invariant: *"Absent sections rule: sections without sufficient data are absent; no template must be filled."*

This audit records the empirical methodology, quantitative corpus metrics, and release decision regarding whether automated sentiment analysis should ship as an overview section in the event reader.

---

## Evaluation Corpus & Methodology

The evaluation harness in `Sources/Intelligence/CoverageSentimentEvaluator.swift` benchmarks tone estimation on journalistic text across three news dimensions:

1. **Adverse / Crisis Hard News (Factual Reporting)**:
   - Events describing tragic, dangerous, or adverse developments: earthquakes, commuter derailments, inflation/interest rate surges, corporate fraud trials, and severe river flooding.
   - Ground truth reporting tone: **Objective Factual** (wire service and newspaper journalists reporting verifiable facts without editorializing).
2. **Editorial / Opinion Commentary**:
   - Explicit op-eds and opinion columns featuring subjective praise or sharp condemnation.
   - Ground truth tone: **Subjective Critical** or **Subjective Positive**.
3. **Milestones & Scientific Achievements**:
   - Observational astronomy, medical discoveries, public infrastructure completions.
   - Ground truth tone: **Objective Factual** / **Positive**.
4. **Multilingual Parity**:
   - Tested across all catalog languages (`en`, `de`, `fr`, `it`, `nl`, `pl`, `uk`).

---

## Quantitative Evaluation Results

| Metric | Target Threshold for Release | Measured Result | Status |
| :--- | :--- | :--- | :--- |
| **False Negativity on Objective Crisis Reports** | $\le 15.0\%$ | **$80.0\%$** (4 / 5) | **FAILED** |
| **Multilingual Catalog Coverage Rate** | $\ge 80.0\%$ | **$28.6\%$** (2 / 7) | **FAILED** |
| **Editorial Opinion Detection Precision** | $\ge 85.0\%$ | $100.0\%$ (2 / 2) | Passed |
| **Scientific Milestone Neutrality** | $\ge 85.0\%$ | $100.0\%$ (1 / 1) | Passed |

### Key Empirical Findings

1. **Conflation of Event Adversity with Reporting Tone**:
   - Naive lexical models (such as `NLTagger` with `.sentimentScore`) score text based on vocabulary frequency. Factual reporting of accidents, natural disasters, inflation, and trials heavily features vocabulary such as *"earthquake"*, *"fatalities"*, *"derails"*, *"injuries"*, *"recession"*, and *"fraud"*.
   - Consequently, **80% of neutral crisis reporting was mislabeled as "Critical" or "Negative" coverage**.
   - Surfacing this on an event card or overview would misinform the user that reputable publishers (Reuters, AP, BBC) possess a negative or critical bias, when they are merely reporting tragic events objectively.

2. **Multilingual Inequity**:
   - The Apple `NaturalLanguage` sentiment score is uncalibrated or unsupported for key catalog languages (returning `nil` or default `0.0` for Ukrainian, Polish, and Dutch).
   - Displaying sentiment on English events while remaining blank or defaulting to zero on Ukrainian or Polish events creates an inconsistent and ungrounded experience.

---

## Acceptance Decision: NO-GO for Default Overview Sentiment

In accordance with the project acceptance criteria:
1. **Gate Enforced**: `CoverageSentimentEvaluator.shouldIncludeInOverview` evaluates to `false`.
2. **Absent Sections Rule**: Because automated coverage sentiment does not satisfy the acceptance threshold, `overview.coverageSentiment` is synthesized as `nil`. The coverage tone section is omitted from the reader UI by default.
3. **Calibrated Diagnostics Preserved**: `CoverageSentimentEvaluator.assessTextToneSafely` is provided for per-article inspection and diagnostic tools. It detects adversity-confounding vocabulary and adjusts the classification to `Neutral` with an explanatory rationale.
4. **Reader UI Readiness**: `EventOverviewReaderView` includes the typed `sentimentSection` component, rendering only if `overview.coverageSentiment != nil`. It remains cleanly absent when ungrounded.

---

## Verification Summary

- `Tests/NewsTests.swift` (`testCoverageSentimentEvaluation`):
  - Corpus evaluation runs and verifies that `falseNegativityOnObjectiveEvents > 0.50` and `justifiesOverviewSection == false`.
  - Overview synthesis leaves `coverageSentiment == nil`, upholding the absent sections rule.
  - Safe text assessment detects adversity confounding on crisis news and correctly identifies explicit editorial markers.
  - Model serialization and empty state invariants pass.
- Local Checks:
  - `./test.sh --story-regressions`: Passed.
  - `./test.sh`: Passed.
  - `./build.sh`: Passed.
  - `./build_release.sh`: Passed.
- SonarCloud compliance: zero hardcoded URL literals (`swift:S1075`), parameter counts $\le 7$ (`swift:S107`), no single-case switches (`swift:S1301`).
