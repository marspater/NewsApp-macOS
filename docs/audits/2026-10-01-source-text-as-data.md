# Treat source text as data in generation — 1 October 2026

## Scope

Issue #138 establishes the prompt security boundaries and injection defenses for on-device generation in Phase E (Epic #95):
- Third-party text is data, never instructions for the model.
- Generation has no tools, cannot perform actions and cannot follow arbitrary URLs.
- Fixtures with injection attempts inside article text.

## Implementation

- **Prompt Defense & Data Encapsulation (`Sources/Intelligence/PromptDefense.swift`)**:
  - `GenerationPromptDefense`: provides canonical XML data boundary markers (`<source_data>`, `<article_title>`, `<article_description>`, `<article_content>`, `<evidence_passage>`).
  - `untrustedDataSystemGuard`: strict system invariant explicitly commanding the Foundation Model to treat all enclosed text strictly as untrusted external data, forbidding following instructions, executing commands, adopting re-defined roles, or following URLs.
  - `sanitizeSourceText`: escapes and neutralizes delimiter breakout attempts (`</source_data>`, `</evidence_passage>`, etc.) and conversational role-spoofing markers (`\n[SYSTEM]`, `\nAssistant:`, `\nUser:`, etc.).
  - `frameArticleData` & `frameEvidencePassages`: safely frame single articles and multi-source evidence passages into bounded data containers, stripping hostile attribute quotes and escape characters.
  - `verifyHermeticGenerationPreconditions`: confirms generation environment remains tool-less, non-executable, and strictly partitioned from network access.
- **Integration (`Sources/Intelligence/ArticleIntelligence.swift`)**:
  - Integrated `GenerationPromptDefense` into `ArticleClassifier.classifyTopic` and `ArticleAnalyzer.analyze`, ensuring publisher content cannot escape prompt containment.

## Verification

- Full test suite (`./test.sh`) and focused regressions (`./test.sh --story-regressions`) passed with 100% green tests.
- Staged arm64 `./build.sh` application build completed with ad-hoc signing.
- Unit tests in `Tests/NewsTests.swift` (`testPromptInjectionDefenses`) cover:
  - System invariant directive validation.
  - Direct instruction override containment.
  - Delimiter breakout tag escaping (`</source_data>`).
  - Conversational role spoofing neutralization (`[SYSTEM]`, `Assistant:`, `User:`).
  - Multi-passage attribute quote escaping and body closure neutralization.
  - Tool-less hermetic environment verification.
- SonarCloud compliance: zero hardcoded URL literals (`swift:S1075`), method parameter counts <= 7 (`swift:S107`).

## Limits

- Runtime model availability probe (#139), fact extraction (#135), and on-demand overview scheduling (#141) are tracked in subsequent Phase E sub-issues.
