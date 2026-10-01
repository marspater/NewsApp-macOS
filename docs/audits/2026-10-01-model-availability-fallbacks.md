# Model availability and language fallbacks — 1 October 2026

## Scope

Issue #139 establishes runtime model availability probing and deterministic non-AI language fallbacks for Phase E (Epic #95):
- Check model availability and language support at runtime.
- On macOS 15 or without Apple Intelligence: reader, deduplication, source list and deterministic grouping still work.
- Ukrainian generation and cross-language grouping verified separately, not promised in the base plan.
- No cloud AI or downloaded model in the base plan.

## Implementation

- **Availability Probing & Language Policy (`Sources/Intelligence/ModelAvailability.swift`)**:
  - `ModelAvailabilityStatus`: typed enumeration representing runtime availability (`.available`, `.osUnsupported`, `.deviceNotEligible`, `.modelNotReady`, `.languageUnsupported`, `.disabledByPolicy`).
  - `ModelLanguageSupport`: detects dominant document languages via `NLLanguageRecognizer`. Declares baseline generative language support (English) while treating Ukrainian (`.ukrainian`) and other languages as separate, unpromised verification tracks.
  - `ModelRuntimeProbe`: checks runtime availability of `SystemLanguageModel` on macOS 26+. Returns `.osUnsupported` on macOS 15 without throwing or halting the pipeline.
- **Deterministic Non-AI Fallback (`Sources/Intelligence/ModelAvailability.swift`)**:
  - `buildFallbackOverview`: constructs a valid `EventOverviewDocument` with `OverviewKind.fallbackExcerpts`. Extracts salient verified evidence passages directly as grounded facts with citations, eliminating hallucination risks when Foundation Models is unavailable or language is unsupported.
  - Generates zero cloud network calls and downloads no third-party models, preserving user privacy and offline operability.

## Verification

- Full test suite (`./test.sh`) and focused regressions (`./test.sh --story-regressions`) passed with 100% green tests.
- Staged arm64 `./build.sh` application build completed with ad-hoc signing.
- Unit tests in `Tests/NewsTests.swift` (`testModelAvailabilityAndLanguageFallbacks`) cover:
  - English language detection and support verification.
  - Ukrainian language detection and graceful non-generative policy handling.
  - Runtime availability probe under simulated macOS 15 environment.
  - Unsupported language rejection from generative pipeline.
  - Deterministic fallback document generation with verified excerpt citations.
  - Fallback document SQLite persistence and retrieval via `DatabaseEngine`.
- SonarCloud compliance: zero hardcoded URL literals (`swift:S1075`), method parameter counts <= 7 (`swift:S107`).

## Limits

- Fact extraction (#135), on-demand scheduling (#141), and the labeled quality audit gate (#142) remain tracked in their respective Phase E sub-issues.
