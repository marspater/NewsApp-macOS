# Deterministic verification of overview claims — 2 October 2026

## Scope

Issue #137 establishes deterministic verification of overview claims for Phase E (Epic #95):
- Every citation ID exists and maps to a valid citation and passage.
- Supporting text is present in the cited passage.
- Numbers, units, currency and dates match the source.
- Negation and attribution are preserved.
- Failure behavior: Show verified excerpts and the source list. Never store a failed retelling as a finished overview.
- Self-checking by the same model does not replace these checks.

## Implementation

- **Overview Claim Verifier (`Sources/Intelligence/OverviewClaimVerifier.swift`)**:
  - `OverviewClaimVerifier.verifyOverview`: Deterministic multi-stage verification engine inspecting every claim, citation, and supporting passage.
  - **Citation Existence Check**: Validates that all citation IDs referenced in `OverviewFact.citationIDs` exist in `overview.citations`, and their `passageID` resolves to an existing `EvidencePassage`. Missing citations or passages yield `.missingCitation` or `.missingPassage`.
  - **Supporting Text Grounding**: Verifies that the citation's `quote` is non-empty and present verbatim (with normalized whitespace and diacritics) within the cited `EvidencePassage.text`. Unanchored quotes yield `.unanchoredQuote`.
  - **Numbers, Currencies, Units, and Dates Fidelity**:
    - Numbers extracted via regex (`\b\d+([.,]\d+)?\b`) from the claim must appear in the cited passage text. Numeric discrepancies yield `.numericMismatch`.
    - Currencies (`$`, `€`, `£`, `¥`, `₴`, `USD`, `EUR`, `GBP`, `UAH`, `грн`) must match with whole-word boundary awareness (preventing false substring matches like `EUR` in `European`). Discrepancies yield `.currencyMismatch`.
    - Measurement units (`km/h`, `mph`, `km`, `miles`, `kg`, `lbs`, `%`, `percent`, `відсот`) are verified against the passage. Discrepancies yield `.unitMismatch`.
    - Dates and 4-digit years are verified against the source text. Discrepancies yield `.dateMismatch`.
  - **Negation Preservation**: Detects negation keywords in both English (`not`, `no`, `never`, `refused`, `denied`, etc.) and Ukrainian (`не`, `ні`, `ніколи`, `відмовився`, `відхилив`, `заперечив`). Mismatched polarity (dropped negation or fabricated negation) yields `.negationFlipped`.
  - **Attribution Preservation**: Inspects attribution phrases (`announced`, `said`, `claimed`, `повідомило`, `заявив`, `за словами`, etc.) and ensures the attributed speaker/entity is grounded in the source passage. Fabricated attribution yields `.attributionMissing`.
  - **Failure Behavior & Fallback Creation**:
    - `OverviewClaimVerifier.createFallbackOverview`: When verification fails, transforms the overview into `OverviewKind.fallbackExcerpts`.
    - Retains only verified facts and their corresponding citations, dropping failed claims.
    - Generates a structured fallback summary containing verified excerpts and a clear list of source publishers and titles (`## Verified Excerpts`, `## Sources`).
    - Sets provenance kind to `.fallbackExcerpts`.
  - **Database Persistence Safety**:
    - `DatabaseEngine.recordVerifiedOverview` and `ArticleStore.recordVerifiedOverview` deterministically verify the overview before storage. If verification fails, stores the safe fallback excerpts document and never a failed retelling as `.synthesized`.
- **Composer Fix (`Sources/Intelligence/OverviewComposer.swift`)**:
  - Reduced `composeFallbackOverview` parameter count to 7 to maintain SonarCloud `swift:S107` compliance.

## Verification

- Full test suite (`./test.sh`) passed with 100% green tests.
- Staged arm64 application build (`./build.sh`) and hardened runtime verification (`./build_release.sh`) succeeded with code signatures verified.
- Unit tests in `Tests/NewsTests.swift` (`testDeterministicClaimVerification`) cover:
  - Baseline fully verified overview with grounded facts and citations.
  - Non-existent citation ID detection (`missingCitation`).
  - Missing passage ID detection (`missingPassage`).
  - Unanchored quote detection (`unanchoredQuote`).
  - Numeric mismatch detection (`numericMismatch`).
  - Currency mismatch detection (`currencyMismatch`).
  - Unit mismatch detection (`unitMismatch`).
  - Date mismatch detection (`dateMismatch`).
  - Flipped negation detection in English and Ukrainian (`negationFlipped`).
  - Fabricated attribution detection (`attributionMissing`).
  - Fallback overview creation with verified excerpts and source list.
  - DatabaseEngine safe persistence (`recordVerifiedOverview`) storing `.fallbackExcerpts` when claims fail.
- SonarCloud compliance: zero hardcoded URL strings (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), no single-case switches (`swift:S1301`).

## Limits

- Event overview reader mode UI (#140), on-demand overview scheduling and caching (#141), and the labeled quality audit gate (#142) remain tracked in subsequent Phase E sub-issues.
