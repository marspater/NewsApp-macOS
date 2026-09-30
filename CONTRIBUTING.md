# Contributing to NewsApp

Read [AGENTS.md](AGENTS.md) for project policy and [the architecture map](docs/ARCHITECTURE.md) for source responsibilities. `JULES.md` is the agent entry point; it links to the same canonical instructions.

## Development

Use the existing native Swift/SwiftUI stack, keep changes focused, preserve user data and migrations, and treat feed/article input as untrusted. Maintain Swift 6 isolation and cancellation, deterministic taxonomy, accessibility and the shared design tokens. Do not add cloud AI, telemetry or third-party models.

Build on Apple silicon with Xcode 27 selected. The deployment target remains macOS 15; newer APIs require availability checks.

## Validation

```sh
./test.sh                         # Deterministic regressions; also run by the commit hook
./build.sh                        # arm64 app with ad-hoc verification signing
NEWS_LIVE_READER_CHECK=1 ./test.sh # Optional controlled-network and publisher checks
./build_release.sh                # Optimized arm64 verification bundle
```

`make build` and `make release` compile SwiftPM executables; `make app` and `make run` use the app-bundle workflow. Packaging helpers live under `script/distribution/` and are inactive in development CI. Do not run notarization or build Intel slices in the current scope.

Before publication, fetch `origin/main`, review the diff and run checks affected by the change. Never report a check as passing unless it completed successfully. Record noteworthy behavior changes in [CHANGELOG.md](CHANGELOG.md); dated evidence belongs in `docs/audits/`.

## Security checks

[The Security workflow](.github/workflows/security.yml) is the canonical advanced CodeQL configuration for Swift and GitHub Actions. Default CodeQL setup must remain disabled because GitHub rejects advanced uploads while it is enabled. Swift analysis traces `./build.sh` directly, avoiding traced SwiftPM manifest execution on the arm64 runner. Secret scanning and deterministic security regressions remain separate jobs.
