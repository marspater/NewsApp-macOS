# Contributing to NewsApp

Start with [README.md](README.md), [architecture and technology constraints](docs/ARCHITECTURE.md), [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md). These documents apply to every contributor. `AGENTS.md` and `JULES.md` contain instructions for coding agents only.

## Development

Use the existing native Swift/SwiftUI stack, keep changes focused, preserve user data and migrations, and treat feed/article input as untrusted. Maintain Swift 6 isolation and cancellation, deterministic taxonomy, accessibility and the shared design tokens. Do not add cloud AI, telemetry or third-party models.

Build on Apple silicon with Xcode 27 selected. The deployment target remains macOS 15; newer APIs require availability checks.

## Validation

```sh
./test.sh                         # Full regressions; also run by the commit hook
./test.sh --story-regressions     # Focused offline identity, reader and persistence checks
./test.sh --performance-baseline --active-work-cancellation # Active clustering, ingestion and feed parsing cancellation; temporary stress fixtures
./script/native_performance_baseline.sh # Isolated MainView window, rendered-card samples and process memory
NEWS_NATIVE_HARNESS=Tests/NativeReadingMemory.swift ./script/native_performance_baseline.sh # Live: read 20 stories twice in the production reader, isolated; waits until each image is decoded
NEWS_READING_FULL_APP=1 ./script/native_performance_baseline.sh # Live: sandboxed bundle, production cache, same reading plus ten overviews and five publisher Web views
./script/test_voiceover_live_qa.sh --self-test # Parked (#268): bounded command-protocol regressions, no AX permission required
./script/test_voiceover_live_qa.sh --smoke     # Parked (#268): isolated production views and offline image/render evidence
./script/test_voiceover_live_qa.sh --live      # Parked (#268): rendered AX tree, actions/persistence and production update notifications
./script/test_voiceover_live_qa.sh --manual    # Parked (#268): interactive isolated fixture for spoken VoiceOver/rotor traversal
./script/test_native_ui_qa.sh        # Automated Native UI QA checks with system settings overrides (#155, #123)
./script/run_isolated.sh [OPTIONS]   # Launch isolated app with simulated Increase Contrast, Reduce Motion, VoiceOver
./script/launch_baseline.sh       # Production bundle under a separate identifier: launch to first card and memory, seeded library
./test.sh --performance-baseline  # Opt-in optimized synthetic core-service timings
./test.sh --transport-cancellation # Optimized refresh shutdown over controlled HTTP/SOCKS sockets
./test.sh --publisher-cancellation # Opt-in, live: refresh and stop the twelve panel feeds over real HTTPS
NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus # Event clustering precision/recall on a local labeled corpus (#102)
NEWS_EMBEDDING_THRESHOLD=0.4 NEWS_EVENT_CORPUS=corpus.json ./test.sh --event-corpus --corpus-holdout # Holdout, embeddings at the cutoff chosen on tune (#127)
./test.sh --corpus-capture DIR    # Opt-in, live: capture catalog feed items into a private directory (#102)
./test.sh --corpus-review DIR     # Fingerprint match review sheet and precision against private labels (#102)
./test.sh --corpus-readiness DIR --corpus-holdout # Eligible held-out document counts only; no scores, labels or review-file writes
./test.sh --corpus-pages DIR --corpus-urls requests.json # Opt-in protected publisher-page evidence; [{"id":"doc-1","url":"https://…"}]
./test.sh --corpus-page-texts DIR # Offline private readability evidence; no matching predictions
./build.sh                        # arm64 app with ad-hoc verification signing
NEWS_LIVE_READER_CHECK=1 ./test.sh # Optional controlled-network and publisher checks
NEWS_LIVE_CATALOG_CHECK=1 ./test.sh # Optional: fetch every catalog feed through the app's own networking and parsers
./build_release.sh                # Optimized arm64 verification bundle
```

`make build` and `make release` compile SwiftPM executables; `make app` and `make run` use the app-bundle workflow. Packaging helpers live under `script/distribution/` and are inactive in development CI. Do not run notarization or build Intel slices in the current scope.

Add deterministic regressions for changed parsing, classification, persistence, migrations, security boundaries and state transitions. Synchronize async tests on observable state rather than short sleeps; model-dependent tests must use deterministic fallbacks. Preserve tests rather than removing failing coverage. Keep tests isolated from real user settings, databases and logs.

HTTP mock fixtures use the test client's controlled DNS results as well as `URLProtocol` responses; they must not depend on public DNS availability. Production clients keep the native resolver, and real socket/proxy tests retain their connection and pinning checks.

For app changes, build in an isolated staging directory: `build.sh` replaces `News.app` in its working directory. A successful build is not evidence of installation, launch or live network behavior; report those checks separately. Validate `build_release.sh` and affected packaging scripts for distribution changes, without invoking notarization in development. Documentation-only edits require link/path and consistency checks, not an unrelated app rebuild.

The native performance script requires an active Mac desktop. It compiles the production views with a separate test entry point, uses temporary SQLite/defaults and mocked feeds, and writes JSON plus a first-card PNG to the printed directory (or the directory supplied as its first argument). Its sampled bitmap timing is an upper bound on rendering readiness, not cold app launch; process memory includes fixture setup and the on-device Vision probe. It neither installs a bundle nor runs the production app delegate. The opt-in `NEWS_READING_FULL_APP=1` mode reuses `build.sh` and the production entitlements under `com.marspater.news.workloadcheck`; its cache and WebKit storage are isolated from the installed app. It invokes the same `CacheManager` setup as the app delegate, reads 20 live stories twice, generates/persists/captures ten deterministic overviews with three controlled source inputs, and loads five selected publisher pages through `ArticleWebView`. Timings are workload observations, not CI thresholds; app footprint excludes WebKit auxiliary processes and memory pressure. Failed documents, images or Web loads fail the run. Its report and overview capture are exported from the sandbox through stdout into the results directory.

`script/launch_baseline.sh` also needs an active desktop. It builds the production bundle under the identifier `com.marspater.news.launchcheck`, so its sandbox container is separate from the installed app, seeds that container with 10,000 stories and opens the app several times. Its feed points at a reserved `.invalid` host. The first-card time comes from a one-time `FirstCard` signpost and log line in the app.

Before publication, fetch `origin/main`, review the diff and run checks affected by the change. Never report a check as passing unless it completed successfully. Record noteworthy behavior changes in [CHANGELOG.md](CHANGELOG.md); dated evidence belongs in `docs/audits/`.

The VoiceOver harness is parked (#268) and is not part of release verification; the notes below apply when it is resumed. It builds a separate `com.marspater.news.voiceoverqa` bundle and uses temporary SQLite and preferences. Its view environment supplies an in-memory image; the installed app and its protected image loader remain unchanged. Output goes to the printed temporary directory or `NEWS_VOICEOVER_OUTPUT`. Compilation has a 300-second deadline and automated runs a 120-second process-group deadline; commands and AX inspection have shorter internal deadlines. Missing Accessibility access or unsupported announcement observation is a reported prerequisite failure, not a crash or passing check.

`--live` checks rendered AX nodes while scrolling, invokes card actions and verifies SQLite state, opens/dismisses a real citation and observes the production feed-buffer notification after inserting three fixture stories. Missing numeric heading metadata is reported as unverified and requires the manual rotor pass. AX tree order and observed notifications do not establish VoiceOver cursor order, rotor traversal, pronunciation or speech. Use `--manual`, enable VoiceOver yourself, and record that separate pass in #268. The Fixtures menu switches between Feed, Source Reader and Event Overview. On Feed, Queue New Stories holds the list through its production navigation command and inserts three stories. Close the fixture window to clean up. The harness does not change system accessibility settings.

## Story experience tracking

Use the [News · Story experience project](https://github.com/users/marspater/projects/2) and [program issue #90](https://github.com/marspater/NewsApp-macOS/issues/90) for this work. Before starting a slice, read its task acceptance criteria and dependencies. Update the relevant issue checklists and log implementation scope, completed checks, remaining gaps, and commit/PR state after each coherent slice.

Private fingerprint capture and review use `FeedCatalog.supportedLanguages`, including optional extra feed lists and historical captures. Keep existing capture files intact; parked-language observations do not enter the current release denominator. Tuning is the default; `--corpus-review --corpus-holdout` explicitly unseals the fingerprint acceptance split. Use `--corpus-readiness DIR --corpus-holdout` to count support while leaving outcomes sealed. Its zero-false-merge sufficiency flag is conditional, not observed acceptance.

Keep uncommitted implementation In progress, linked PR work In review, and reserve Done for merged implementation or completed non-code deliverables with recorded evidence. Use `Refs #N` for partial coverage and `Fixes #N` only when the PR completes that issue. Keep the image HTTP-cache task (#161) separate from identity and reader/media work. Do not mark a phase complete from a partial implementation or a focused test pass.

## Security checks

[The Security workflow](.github/workflows/security.yml) is the canonical advanced CodeQL configuration for Swift and GitHub Actions. Default CodeQL setup must remain disabled because GitHub rejects advanced uploads while it is enabled. Swift analysis builds the complete SwiftPM app target without optimization on the macOS 26 Apple Silicon runner with Xcode 26.3. Compiler subprocess sandboxing is disabled only for extraction; app sandbox entitlements are unchanged. Normal CI tests and verifies arm64 bundles on Xcode 27. Secret scanning and deterministic security regressions remain separate jobs.
