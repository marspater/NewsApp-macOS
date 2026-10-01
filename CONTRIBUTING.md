# Contributing to NewsApp

Start with [README.md](README.md), [architecture and technology constraints](docs/ARCHITECTURE.md), [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md). These documents apply to every contributor. `AGENTS.md` and `JULES.md` contain instructions for coding agents only.

## Development

Use the existing native Swift/SwiftUI stack, keep changes focused, preserve user data and migrations, and treat feed/article input as untrusted. Maintain Swift 6 isolation and cancellation, deterministic taxonomy, accessibility and the shared design tokens. Do not add cloud AI, telemetry or third-party models.

Build on Apple silicon with Xcode 27 selected. The deployment target remains macOS 15; newer APIs require availability checks.

## Validation

```sh
./test.sh                         # Full regressions; also run by the commit hook
./test.sh --story-regressions     # Focused offline identity, reader and persistence checks
./build.sh                        # arm64 app with ad-hoc verification signing
NEWS_LIVE_READER_CHECK=1 ./test.sh # Optional controlled-network and publisher checks
./build_release.sh                # Optimized arm64 verification bundle
```

`make build` and `make release` compile SwiftPM executables; `make app` and `make run` use the app-bundle workflow. Packaging helpers live under `script/distribution/` and are inactive in development CI. Do not run notarization or build Intel slices in the current scope.

Add deterministic regressions for changed parsing, classification, persistence, migrations, security boundaries and state transitions. Synchronize async tests on observable state rather than short sleeps; model-dependent tests must use deterministic fallbacks. Preserve tests rather than removing failing coverage. Keep tests isolated from real user settings, databases and logs.

For app changes, build in an isolated staging directory: `build.sh` replaces `News.app` in its working directory. A successful build is not evidence of installation, launch or live network behavior; report those checks separately. Validate `build_release.sh` and affected packaging scripts for distribution changes, without invoking notarization in development. Documentation-only edits require link/path and consistency checks, not an unrelated app rebuild.

Before publication, fetch `origin/main`, review the diff and run checks affected by the change. Never report a check as passing unless it completed successfully. Record noteworthy behavior changes in [CHANGELOG.md](CHANGELOG.md); dated evidence belongs in `docs/audits/`.

## Security checks

[The Security workflow](.github/workflows/security.yml) is the canonical advanced CodeQL configuration for Swift and GitHub Actions. Default CodeQL setup must remain disabled because GitHub rejects advanced uploads while it is enabled. Swift analysis builds the complete SwiftPM app target without optimization on the macOS 26 Apple Silicon runner with Xcode 26.3. Compiler subprocess sandboxing is disabled only for extraction; app sandbox entitlements are unchanged. Normal CI tests and verifies arm64 bundles on Xcode 27. Secret scanning and deterministic security regressions remain separate jobs.
