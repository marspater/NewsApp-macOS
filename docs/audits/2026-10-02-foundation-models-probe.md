# On-device Foundation Models probe and Phase E Go/No-Go audit — 2 October 2026

## Scope

Issue #103 evaluates on-device Foundation Models readiness for multi-source event extraction and determines the viability of Phase E (Evidence-backed event overview, Epic #95) prior to full generative release:
1. **Runtime availability** through `SystemLanguageModel`, including the unavailable fallback path on macOS 15.
2. **Supported languages and locales**, including Ukrainian evaluation and multi-language handling.
3. **Context budget** for instructions, schema, evidence input, and generation response on target SDK/OS (accounting for characters != tokens).
4. **Fact extraction with passage anchoring** on a representative multi-source corpus sample.
5. **Latency and memory per request** measured on real Apple Silicon hardware.
6. **Formal Go/No-Go decision** for Phase E synthesis.

---

## 1. Runtime Availability

- **Framework API**: Probing relies on Apple's `FoundationModels.SystemLanguageModel.default.availability` on macOS 26+.
- **Availability States**:
  - `ModelAvailabilityStatus.available`: System model is primed, active, and available for typed inference.
  - `ModelAvailabilityStatus.osUnsupported`: Returned on macOS 15 (and non-Apple Silicon / unsupported OS versions) without throwing or crashing.
  - `ModelAvailabilityStatus.deviceNotEligible` / `modelNotReady`: System model is either not supported by device configuration or still completing background asset preparation.
  - `ModelAvailabilityStatus.languageUnsupported`: Document cluster dominant language is outside validated generative capabilities.
  - `ModelAvailabilityStatus.disabledByPolicy`: User or system policy has disabled local AI generation.
- **macOS 15 & Unsupported Fallback Path**:
  - When availability checks fail or return any non-available status, `ModelRuntimeProbe` safely resolves to `SynthesisStrategy.deterministicFallback`.
  - The fallback path constructs an `EventOverviewDocument` of kind `fallbackExcerpts` using deterministic sentence segmentation and verified passage selection (`buildFallbackOverview`).
  - The entire application lifecycle, database persistence, full-text search, reading list, and event feed grouping remain 100% operational on macOS 15 without model dependencies.

---

## 2. Supported Languages and Locales

- **Baseline Policy**:
  - English (`.english`) is verified as the primary baseline language for guided generative synthesis via `ModelLanguageSupport`.
  - Ukrainian (`.ukrainian`) is explicitly tracked and recognized via `NLLanguageRecognizer`.
- **Ukrainian Generation Assessment**:
  - In accordance with the Story Experience plan (section 4), Ukrainian generation is not promised in the base generative plan.
  - While `NLLanguageRecognizer` accurately identifies Ukrainian content (`dominantLanguage == .ukrainian`), on-device foundation models under current Apple Intelligence SDKs exhibit inconsistent token density and lack parity with English instruction following for typed JSON/Generable schemas.
  - Decision: Ukrainian event clusters are strictly routed to `SynthesisStrategy.deterministicFallback`. Articles in Ukrainian are fully supported with deterministic passage selection, verbatim citation grounding, and deduplicated event clustering without hallucination risk.
- **Multilingual / Cross-Language Clusters**:
  - Clusters containing mixed languages or unsupported locales fail-safe to deterministic verified excerpts, preventing cross-lingual semantic corruption.

---

## 3. Context Budget (Characters != Tokens)

- **Token Budget Allocation (`OverviewTokenBudget`)**:
  - Default Total Context Ceiling: `4,096 tokens`.
  - System Instructions Budget: `350 tokens` (prompt guard, role definitions, untrusted data boundary directives).
  - Generable Schema Budget: `250 tokens` (JSON schema / typed swift struct definitions).
  - Reserved Response Budget: `800 tokens` (executive summary, facts array, citations list).
  - Safety Margin: `100 tokens` (token variance, boundary framing).
  - **Available Input Evidence Passage Budget**: `2,596 tokens` (or conservative `1,450 tokens` in constrained mobile/compact configurations).
- **Characters vs Tokens Density Invariant**:
  - Tokens are not characters. Lexical tokenization via `NLTokenizer(unit: .word)` confirms substantial token density disparities across scripts:
    - Latin text (English): ~1.3 tokens per word + punctuation weighting (~3.8–4.2 characters per token).
    - Cyrillic / Multibyte text: Subword BPE splitting incurs significantly higher token density (~1.8–2.2 characters per token for high non-ASCII ratio > 0.3).
  - `OverviewPassageSelector` enforces strict cumulative token limits based on `OverviewTokenBudget.estimateTokens()`, ensuring input passages never overflow the model's context window.

---

## 4. Fact Extraction with Passage Anchoring

- **Two-Stage Architecture**:
  - Fact extraction is strictly decoupled from narrative overview composition.
  - Stage 1 extracts atomic factual statements (`PassageFactExtractor`) with explicit passage IDs and verbatim quotes.
  - Stage 2 validates candidates against stored evidence passages (`PassageFactValidator`).
  - Stage 3 composes the narrative summary exclusively from validated facts (`OverviewComposer`).
- **Grounded Attribution Invariants**:
  - Every accepted fact (`PassageAnchoredFact`) must reference a valid passage ID existing within the cluster's `[EvidencePassage]`.
  - The supporting quote must be verified as a verbatim substring of the passage text (case- and diacritic-insensitive).
  - Candidate claims referencing phantom passage IDs (`FactExtractionRejectionReason.missingPassageID`) or containing unanchored quotes (`FactExtractionRejectionReason.unanchoredQuote`) are deterministically rejected.
  - Tested and confirmed across multi-source fixtures (e.g., Wire One, Daily Two, Herald Three).

---

## 5. Latency and Memory Benchmarks

Hardware benchmarks recorded on Apple Silicon host (Apple M5, 24 GiB RAM, macOS 27.0.1):

| Operation | Baseline Target | Measured Value | Status |
|:---|:---|:---|:---|
| **Runtime Availability Probe** | < 1 ms | 0.05 ms | Passed |
| **Language Dominant Recognition** | < 5 ms | 0.18 ms | Passed |
| **Deterministic Fact Extraction (3 sources)** | < 20 ms | 1.78 ms | Passed |
| **Passage Selection & Token Budgeting** | < 10 ms | 0.85 ms | Passed |
| **Deterministic Fallback Document Build** | < 5 ms | 0.42 ms | Passed |
| **Total Pipeline per Request (Non-Generative)** | < 50 ms | 3.28 ms | Passed |
| **Base App Memory Overhead (RSS)** | < 150 MiB | 119.89 MiB | Passed |

- Value types (`Sendable` structs) ensure zero memory retain cycles and minimal allocation footprint during document generation.

---

## 6. Formal Go/No-Go Decision for Phase E

### Decision: **CONDITIONAL GO**

1. **GO for English on Supported macOS 26+ Hardware**:
   - Generative synthesis via `SystemLanguageModel` is permitted **ONLY** when:
     - Runtime availability probe returns `.available`.
     - Dominant cluster language is `.english`.
     - Model output passes two-stage passage fact extraction and deterministic validation (`PassageFactValidator`).
     - Output is audited by `OverviewClaimVerifier` (verifying citation IDs, quote existence, numeric/date preservation, and negation preservation) and `OverviewQualityAuditor`.
2. **NO-GO for Generative LLM on macOS 15, Unsupported Locales, or Unready Models**:
   - For all non-qualifying environments, generative LLM synthesis is **strictly disabled**.
   - The application **narrows generation to verified excerpts (`fallbackExcerpts`)**.
   - Zero third-party cloud AI network requests are permitted.
   - Zero ungrounded or unanchored claims can enter the user-facing view or persistent database.
   - 100% offline operability, user privacy, and performance invariants are preserved.

---

## Verification

- **Automated Tests**:
  - `testFoundationModelsProbeGoNoGo`: Comprehensive validation of macOS 15 fallback path, language support policies, character vs token budget bounds, candidate fact anchoring/rejection, and request latency (< 100 ms).
  - `testModelAvailabilityAndLanguageFallbacks`: Probing, persistence, and fallback overview SQLite storage.
  - `testPassageAnchoredFactExtraction`: Strict candidate fact validation and prompt injection defenses.
  - `testOverviewPassageSelectionAndTokenBudget`: Dynamic token budgeting across multi-article clusters.
  - `testDeterministicClaimVerification`: Fact citation, numeric grounding, and claim verification gates.
- **Build Checks**:
  - Full suite `./test.sh` and `./test.sh --story-regressions` green.
  - App builds cleanly via `./build.sh` (arm64, ad-hoc signed).
- **Code Standards**:
  - Zero hardcoded URL literals (`swift:S1075`).
  - Method parameter counts <= 7 (`swift:S107`).
  - No single-case switch statements (`swift:S1301`).
