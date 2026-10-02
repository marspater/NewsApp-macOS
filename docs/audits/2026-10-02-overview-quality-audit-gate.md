# Labeled overview quality audit as the generative release gate — 2 October 2026

## Scope

Issue #142 establishes the labeled overview quality audit and generative release gate for Phase E (Epic #95):
- Manual audit of claim support on a labeled control sample.
- Deterministic count and classification of critical errors in numbers, dates, and attribution.
- Recording and percentile calculation of p50 and p95 overview generation timing.
- **Release Gate**: Critical number, date, or attribution errors on the control sample strictly block the generative release.

## Implementation

- **Overview Quality Auditor (`Sources/Intelligence/OverviewQualityAuditor.swift`)**:
  - `OverviewQualityAuditor`: static analyzer auditing `EventOverviewDocument` claims against cited `EvidencePassage` sources and ground-truth expectations.
  - `ClaimAuditResult` & `ClaimSupportStatus`: classifies each claim as `.supported`, `.unsupported(reason:)`, or `.criticalError(kind:detail:)`.
  - `CriticalErrorKind`: flags high-risk hallucinations:
    - `.numberMismatch`: detects quantities, values, currency figures, and percentages that are altered or ungrounded in cited passages (with decimal point and thousands-separator normalization).
    - `.dateMismatch`: detects hallucinated months, years, or day timestamps absent from source passages.
    - `.attributionError`: identifies entity attribution misassignments (via `NaturalLanguage` `NLTagger` personal and organization name extraction, attribution phrase regexes, and citation quote verbatim checks).
  - Structured parameter grouping (`QualityClaimMetrics`, `QualityErrorBreakdown`, `QualityTimingMetrics`) strictly conforms to SonarCloud method parameter limits (`swift:S107` <= 7 parameters).
  - `ReleaseGateDecision` & `evaluateReleaseGate`: returns `.passed(supportedClaims:totalClaims:)` when zero critical errors exist, or `.blocked(criticalErrors:reasons:)` detailing each violation.
  - Safe URL handling: control sample fixtures use schema interpolation without hardcoded `https://` literals (`swift:S1075`).
  - No single-case pattern matching (`swift:S1301`).

- **Control Benchmark Suite (`OverviewControlSample`)**:
  - `OverviewControlSample.standardBenchmark`: curated set of 3 real-world representative events (Series B venture funding, clinical vaccine trial, and offshore wind power grid interconnection).
  - Supplies verified passages, ground-truth anchored facts, and publisher articles.

- **Overview Timing Tracker (`OverviewTimingTracker`)**:
  - Records duration per overview generation with thread-safe locking.
  - Emits lightweight Apple Instruments performance intervals via `NewsSignposts.intelligence` ("AIOverviewGeneration").
  - Computes `p50Duration` and `p95Duration` using linear interpolation across sorted duration samples.

## Verification

- Full test suite (`./test.sh`) passed 100% green tests across all suites.
- Staged arm64 application build (`./build.sh`) and hardened runtime verification (`./build_release.sh`) succeeded with verified signatures and entitlements.
- Story regressions (`./test.sh --story-regressions`) verified without failures.
- Unit tests in `Tests/NewsTests.swift` (`testOverviewQualityAuditAndReleaseGate`) verify:
  1. Standard benchmark suite (3 control events, 9 claims) executes with zero critical errors, 100% claim support, and successfully passes the release gate (`canReleaseGenerativeOverview == true`, `isReleaseBlocked == false`, gate decision `.passed`).
  2. Recorded duration metrics produce valid `p50Duration` and `p95Duration`.
  3. Perturbed number claim ($500 million vs $50 million) triggers `.numberMismatch`, halts release (`isReleaseBlocked == true`), and emits `.blocked` decision.
  4. Perturbed date claim (November vs October) triggers `.dateMismatch` and blocks release.
  5. Perturbed entity attribution (Tim Cook vs Jane Doe) triggers `.attributionError` and blocks release.
  6. Fabricated quote in citation triggers `.attributionError` and blocks release.
  7. Timing tracker percentile math validated against multi-sample distribution.

## Limits

- Issue #140 ("Event overview reader mode") remains blocked by #137 and tracked in Phase E backlog.
- Foundation model runtime availability on macOS 26+ remains governed by probe results (#103) and deterministic extractive fallbacks (#139).
