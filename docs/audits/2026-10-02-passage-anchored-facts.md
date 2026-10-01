# Passage-anchored fact extraction with guided generation — 2 October 2026

## Scope

Issue #135 establishes the separate fact extraction stage and deterministic validation pipeline for Phase E (Epic #95):
- Fact extraction as a separate step before summarizing.
- Typed Foundation Models output where each fact references an existing passage ID.
- Reject facts whose passage ID does not exist or whose quote cannot be grounded in the source passage text.
- Typed generation guarantees result shape, not truth or correct attribution: strict deterministic validation enforces grounding.

## Implementation

- **Fact Domain Models (`Sources/Intelligence/PassageFactExtractor.swift`)**:
  - `RawFactCandidate`: lightweight candidate representation with `statement`, `passageID`, and verbatim supporting `quote`.
  - `PassageAnchoredFact`: fully validated factual claim bound directly to `passageID`, `quote`, and `articleID`.
  - `FactExtractionRejectionReason`: granular reasons for deterministic rejection (`.missingPassageID`, `.emptyStatement`, `.emptyQuote`, `.unanchoredQuote`).
  - `FactExtractionDiagnostic`: comprehensive outcome tracking candidate count, accepted facts, and detailed rejection diagnostics.
- **Deterministic Validation Pipeline (`Sources/Intelligence/PassageFactExtractor.swift`)**:
  - `PassageFactValidator.validateCandidates`: deterministically matches candidate facts against the provided `[EvidencePassage]`.
  - Rejects any candidate referencing an invalid or phantom `passageID`.
  - Rejects empty statements or empty quotes.
  - Verifies case- and diacritic-insensitive grounding of the quote within the passage body text, eliminating hallucinated source linkages.
- **Typed Guided Generation Schemas**:
  - `GenerablePassageFactItem` and `GenerablePassageFactExtraction` with `@Guide` annotations enforcing atomic statements, valid `passage_id`, and verbatim quotes under `FoundationModels` on macOS 26+.
- **Prompt Defense & Non-AI Deterministic Fallback**:
  - `PassageFactExtractor.buildFactExtractionPrompt`: leverages `GenerationPromptDefense.untrustedDataSystemGuard` and framed evidence passages to ensure source text is treated purely as passive data. Explicitly instructs the model not to summarize into an overview yet.
  - `PassageFactExtractor.deterministicExtract`: provides sentence-segmented deterministic fact extraction using `NLTokenizer` for macOS 15, unsupported languages, or testing environments.

## Verification

- Full test suite (`./test.sh`) and story regressions (`./test.sh --story-regressions`) passed with 100% green tests.
- Staged arm64 `./build.sh` application build completed with ad-hoc signing.
- Unit tests in `Tests/NewsTests.swift` (`testPassageAnchoredFactExtraction`) cover:
  - Acceptance of well-formed candidate facts with article ID derivation.
  - Rejection of facts referencing non-existent passage IDs.
  - Rejection of facts with ungrounded / hallucinated quotes.
  - Rejection of empty statements and empty quotes.
  - Deterministic fallback extraction yielding grounded facts.
  - Prompt security boundary and container framing.
- SonarCloud compliance: zero hardcoded URL literals (`swift:S1075`), parameter counts <= 7 (`swift:S107`), no single-case switch statements (`swift:S1301`).

## Limits

- Overview synthesis from verified facts (#136), claim-level overview verification (#137), on-demand scheduling (#141), and the labeled quality audit gate (#142) remain tracked in their respective Phase E sub-issues.
