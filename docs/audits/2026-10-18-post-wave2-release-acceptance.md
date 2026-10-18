# Post-Wave 2 Integration & Release Acceptance — 18 October 2026

Post-Wave 2 integration acceptance of the unified codebase on `origin/main` (commit `5fdbe58`). Validates the coexistence and integration of SwiftPM dependencies (SwiftSoup 2.14.3, FeedKit 9.1.2), on-device CoreML sentence embeddings (`all-MiniLM-L6-v2`), SQLite v21 vector persistence, and Hybrid EventMatcher v7.

## 1. Unified Architecture & Build Integration

- **SwiftPM Dependency Management**: SwiftSoup and FeedKit are declared in `Package.swift` and locked via `Package.resolved`. The build scripts (`build.sh`, `build_release.sh`, `test.sh`, and native QA scripts) source `script/swiftpm_dependencies.sh`, compiling a single static dependency archive linked into the arm64 application binary with zero dynamic library dependencies.
- **On-Device Neural Embeddings**: Bundles Int8/FP16 `all-MiniLM-L6-v2` compiled model (`minilm.mlmodelc` 43 MB including `weights/weight.bin`) and `vocab.txt` (30,522 tokens) into `News.app/Contents/Resources/Models/`. CoreML loads via `MLComputeUnits.all` (Apple Neural Engine / GPU / CPU), executing inference in ~0.70 ms per headline with Accelerate `vDSP` L2 normalization and dot-product cosine similarity.
- **SQLite v21 Vector Storage**: Ingested articles store 384-dimensional normalized float vectors in `article_embeddings` with `ON DELETE CASCADE`. The table is provisioned idempotently on startup, ensuring pre-existing v21 databases receive vector storage without disrupting historical migration checks.
- **Hybrid EventMatcher v7**:
  - **Semantic Rescue**: Rescues candidate story pairs sharing a specific anchor when cosine similarity $\ge 0.82$, even with lower token-level lexical overlap.
  - **Semantic Veto**: Vetoes candidate matches when cosine similarity $< 0.55$, preventing conflation of distinct news events sharing generic terms.
  - **Hard Factual Conflict Invariants**: High semantic similarity cannot override explicit factual conflicts (`.places`, `.period`, `.weekday`).

## 2. Automated Verification Results

All automated verification commands from `CONTRIBUTING.md` were executed directly against the merged `main` baseline:

| Check | Scope | Result | Details |
| :--- | :--- | :--- | :--- |
| `./test.sh` | Full regressions | **✅ Passed** | Unit tests, classification benchmark (12/12 100%), transport cancellation over SOCKS proxy, active work cancellation, event embedding suite. |
| `./test.sh --story-regressions` | Story regressions | **✅ Passed** | Identity, persistence, FTS5 full-text search, cache purging, multi-publisher extraction fixtures. |
| `./test.sh --parsing-regressions` | Parsing regressions | **✅ Passed** | SwiftSoup DOM repair, CSS metadata extraction, FeedKit RSS/Atom/JSON parsing, XML base propagation, XXE security boundaries. |
| `./script/design_lint.sh` | Design language ratchet | **✅ Passed** | 0 baseline deviations remaining. |
| `./script/test_native_ui_qa.sh` | Native UI QA | **✅ Passed** | 160 Native UI QA checks passed with 0 failures across layout metrics, text scaling (1.0x-1.5x), Increase Contrast, Reduce Motion, appearance tokens, and feeds buffer. |
| `swift build` | SwiftPM compilation | **✅ Passed** | Clean debug build with all dependencies and resources in 23.48s. |
| `./build.sh` | Development app bundle | **✅ Passed** | arm64 `News.app` compiled and ad-hoc codesigned. |
| `./build_release.sh` | Production release bundle | **✅ Passed** | arm64 release bundle signed with Hardened Runtime and App Sandbox (`com.apple.security.app-sandbox = true`). |

## 3. Bundle Integrity & Security Verification

- **Code Signing**:
  ```sh
  codesign --verify --deep --strict News.app
  # Output: valid on disk, satisfies its Designated Requirement
  ```
- **Binary Architecture**:
  ```sh
  lipo -info News.app/Contents/MacOS/News
  # Non-fat file: News.app/Contents/MacOS/News is architecture: arm64
  ```
- **Sandbox Entitlements**:
  - `com.apple.security.app-sandbox`: `true`
  - `com.apple.security.files.user-selected.read-write`: `true`
  - `com.apple.security.network.client`: `true`
  - `com.apple.security.network.server`: `true`
- **Resource Completeness**:
  - `News.app/Contents/Resources/Models/minilm.mlmodelc/weights/weight.bin` (45,433,088 bytes)
  - `News.app/Contents/Resources/Models/vocab.txt` (231,508 bytes)
  - `News.app/Contents/Resources/ThirdPartyNotices.txt` (SwiftSoup, FeedKit, MiniLM notices)
  - `News.app/Contents/Resources/PrivacyInfo.xcprivacy`

## 4. 1.0 Release Blockers Status Audit

| Issue | Title | Status | Resolution Summary |
| :--- | :--- | :--- | :--- |
| **#307** | Event matcher precision | **Closed** | Accepted in PR #442 / #439 with documented 93.33% precision on the reused English holdout. Hybrid EventMatcher v7 in PR #445 integrates CoreML `all-MiniLM-L6-v2` embeddings for semantic rescue ($\ge 0.82$) and veto ($< 0.55$), preserving hard factual conflict guards without claiming an unverified point-precision increase. |
| **#308** | Model-written overview attributions | **Closed** | Switched overviews to deterministic publisher excerpts and empty summaries in PR #440, eliminating multi-source synthesis attribution errors. |
| **#309** | Minor-story importance hiding | **Closed** | Removed automatic 24h deletion and hiding of single-source stories in PR #440; minor stories remain visible and subject only to ordinary retention. |
| **#314** | Developing-story links | **Parked** | Backend PR #438 merged; collector job unloaded and feature parked outside 1.0 release gate per #439. |
| **#334** | Notification delivery validation | **Audited** | Audited on compiled app build in PR #444; verified UNUserNotificationCenter submission, OS banner presentation, and reader click-through. |
| **#435** | The Hindu reader access | **Audited** | Audited in PR #444; verified live feed XML and reader extraction (3/3 succeeded, median 695 words), confirming no Cloudflare block. Feed retained in catalog. |
| **#264** | Non-English feed matching | **Parked** | Parked per AGENTS.md release scope; code preserved intact. |
| **#268** | Live VoiceOver QA | **Parked** | Parked per AGENTS.md release scope; harness preserved intact. |

## 5. Executable Test References & Reproduction

The verification scenarios documented above are validated by the following deterministic test suites and harnesses in the repository:
- **Neural Embeddings & Hybrid Matcher**: `Tests/EventEmbeddingTests.swift` (`testBertTokenizer`, `testSentenceEmbedderInference`, `testArticleEmbeddingsDatabaseRoundtrip`, `testArticleEmbeddingsForeignKeyCascade`, `testHybridEventMatcherSemanticRescueAndVeto`, `testEmbeddingAwareValidationOfAssignedMembers`).
- **FeedKit & SwiftSoup Parser Suite**: `Tests/FeedKitSwiftSoupTests.swift` (DOM repair, CSS metadata, RSS/Atom/JSONFeed, nested relative XML bases, XML entity expansion safety).
- **Cross-Integration Pipeline**: `FeedKitSwiftSoupTests.runEmbeddingIntegration` (FeedKit parsing → SwiftSoup reader repair → SQLite v21 vector persistence → EventClusterer production clustering).
- **Native UI QA Suite**: `script/test_native_ui_qa.sh` (160 automated UI checks across layout, text scaling, accessibility tokens, appearance modes).
- **Release Compilation & Hardening**: `build_release.sh` (arm64 compilation, asset packaging, Hardened Runtime codesigning, App Sandbox validation).

## 6. Limitations & Boundaries

- Pre-existing line break lint in `Sources/Coordinators/RefreshCoordinator.swift` was cleaned up in the final release pass. Repository-wide formatting lint is enforced via pre-commit hooks (`./script/format.sh --lint-staged`).
- Author metadata from FeedKit is not persisted in SQLite as `FeedArticle` intentionally does not contain an author field.
- Release verification was performed on macOS 15.0 Apple Silicon (arm64). Distribution notarization and Intel slices remain inactive in accordance with current release requirements.
