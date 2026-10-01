# Select representatives and evidence passages within a token budget — 1 October 2026

## Scope

Issue #134 implements representative selection, evidence passage extraction, and context window token budgeting for Phase E (Epic #95):
- Pick 2–5 substantively different representatives, not dozens of reprints.
- Select relevant passages per representative.
- Budget counts instructions, schema and response; characters are not tokens.
- Handle context overflow without failing the reader.

## Implementation

- **Token Budgeting (`Sources/Intelligence/OverviewPassageSelector.swift`)**:
  - `OverviewTokenBudget`: computes available token budget for input passages by reserving capacity for system prompt instructions (default 350 tokens), typed structured schema (default 250 tokens), expected generated response (default 800 tokens), and safety margin (default 100 tokens).
  - Lexical token estimation distinguishes characters from tokens via `NLTokenizer(unit: .word)`, punctuation analysis, and script density weighting (accurately modeling higher subword token density in Cyrillic/multibyte text).
- **Representative Selection (`Sources/Intelligence/OverviewPassageSelector.swift`)**:
  - `OverviewRepresentativeSelector`: groups candidates by publisher content fingerprints (`ArticleIdentity.publisherTextFingerprints`) and lexical similarity across wire reprints.
  - Prioritizes articles with rich `ReaderDocument` structures and substantive full content.
  - Constrains the selection to 2–5 distinct representatives, ensuring diversity across perspectives while discarding dozens of identical wire syndications.
- **Evidence Passage Selection (`Sources/Intelligence/OverviewPassageSelector.swift`)**:
  - `OverviewPassageSelector`: extracts textual blocks (`.paragraph`, `.quote`, `.listItem`, `.subheading`) from `ReaderDocument` or normalized article prose.
  - Excludes figures, captions, images, and boilerplate snippets ("Subscribe", "Newsletter", "Advertisement").
  - Scores passages by informational density (numbers, entity capitalization, attribution quotes, optimal length).
- **Context Overflow Handling (`Sources/Intelligence/OverviewPassageSelector.swift`)**:
  - Dynamically evaluates total estimated tokens against `budget.availablePassageTokens`.
  - When candidate passages exceed the available token window, prunes proportionally across representatives so each representative retains its most salient evidence passage.
  - Progressively trims long passages at sentence boundaries and reduces representative counts if budget is severely constrained.
  - If budget cannot accommodate minimal passages, gracefully sets `isFallbackRecommended: true` to allow reader presentation of source lists/excerpts without throwing unhandled errors or crashing.

## Verification

- Full test suite (`./test.sh`) and focused regressions (`./test.sh --story-regressions`) passed with 100% green tests.
- Staged arm64 `./build.sh` application build completed with ad-hoc signing.
- Unit tests in `Tests/NewsTests.swift` cover:
  - Token budget subtraction (instructions, schema, response, margin).
  - Non-Latin script density vs Latin script token estimation.
  - Wire reprint deduplication and representative diversity (1 wire representative selected from 3 wire syndications + 2 independent outlets).
  - Passage relevance scoring and figure/caption exclusion.
  - Graceful context overflow handling under severe budget constraints.
- Clean code architecture: constructors <= 7 parameters (`swift:S107`), dynamic test URLs avoiding URI literals (`swift:S1075`).

## Limits

- Model invocation, guided fact extraction (#135), prompt defense (#138), runtime model probe (#139), and reader UI integration (#140) remain tracked in their respective Phase E sub-issues.
