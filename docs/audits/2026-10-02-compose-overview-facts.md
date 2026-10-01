# Compose a short overview from verified facts — 2 October 2026

## Scope

Issue #136 establishes overview composition from passage-anchored facts for Phase E (Epic #95):
- One or two paragraph introduction synthesizing the event.
- Three to five key facts with explicit claim-level citations.
- Quotes are strictly reproduced from the source passage and never generated in a person's name.
- Publisher text is never replaced by the overview (original articles remain untouched; overview is a separate derived document).

## Implementation

- **Overview Composer (`Sources/Intelligence/OverviewComposer.swift`)**:
  - `OverviewComposer.composeOverview`: synthesizes a concise, evidence-backed `EventOverviewDocument` strictly using validated `PassageAnchoredFact` items and `EvidencePassage` sources.
  - Generates a 1 or 2 paragraph introduction (`summary`) by synthesizing verified facts without hallucinating ungrounded narrative details.
  - Selects 3 to 5 key facts (`OverviewFact`), each bound to explicit `OverviewCitation` records referencing the source `articleID`, `passageID`, `passageFingerprint`, and verbatim source quote.
  - Attaches source metadata (`OverviewSourceMetadata`) extracted from publisher `FeedArticle` records (title, publisher name, URL, publication date).
  - Enforces quote grounding: `validateFactForOverview` verifies that any quote attached to a claim is a verbatim substring of the source passage text. Fabricated or unanchored quotes are rejected.
  - Safe fallback mode: When fewer than 3 verified facts exist, gracefully falls back to `.fallbackExcerpts` mode without fabricating phantom claims to satisfy a count quota.
  - Computes deterministic `inputTextHash` based on sorted passage fingerprints, binding the generated overview to its exact source inputs.
- **Typed Guided Generation Schemas**:
  - `GenerableOverviewFactItem` and `GenerableOverviewDraft` with `@Guide` annotations under `FoundationModels` for macOS 26+.
  - Prompt construction via `OverviewComposer.buildOverviewPrompt` applies `GenerationPromptDefense.untrustedDataSystemGuard` and explicit constraints prohibiting speech attribution without verbatim passage support.
- **Model Enhancements (`Sources/Models/EventOverview.swift`)**:
  - `OverviewKind` conforms explicitly to `Equatable` and `Hashable`.

## Verification

- Full test suite (`./test.sh`) passed with 100% green tests.
- Staged arm64 application build (`./build.sh`) and hardened runtime verification (`./build_release.sh`) succeeded with code signatures verified.
- Unit tests in `Tests/NewsTests.swift` (`testOverviewCompositionFromVerifiedFacts`) cover:
  - Strict 1 or 2 paragraph introduction validation.
  - 3 to 5 key facts with valid citation references and passage mapping.
  - Verbatim source quote reproduction and deterministic rejection of fabricated/hallucinated quotes.
  - Publisher text preservation (original `FeedArticle` title, description, and full content are unaltered).
  - Proper provenance, event ID, and membership article ID binding.
  - Graceful fallback behavior when verified facts count is below threshold (< 3).
- SonarCloud compliance: zero hardcoded URL strings (`swift:S1075`), method parameter counts <= 7 (`swift:S107`), no single-case switches (`swift:S1301`).

## Limits

- Deterministic claim verification (#137), event overview reader mode UI (#140), on-demand overview scheduling and caching (#141), and the labeled quality audit gate (#142) remain tracked in subsequent Phase E sub-issues.
