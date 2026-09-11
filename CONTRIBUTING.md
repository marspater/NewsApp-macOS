# Contributing to NewsApp

## Before changing code
Read `AGENTS.md` and `JULES.md`. They define the project's technology, architecture, security, privacy, UI, AI, and testing constraints.

## Development principles
- Prefer the existing native Swift/SwiftUI architecture.
- Keep changes focused and reviewable.
- Preserve local-first behavior and zero telemetry.
- Do not add third-party AI or cloud inference.
- Preserve user data and database migration compatibility.
- Treat external feed/article input as untrusted.
- Maintain Swift 6 concurrency correctness and cancellation.
- Use existing design-system tokens and native macOS controls.

## Validation
Run `./test.sh` for code changes. Run `./build.sh` for app-level changes when a compatible macOS/Xcode/Swift environment is available. Release changes should additionally validate the release/package scripts when possible.

Never report a check as passing unless it actually completed successfully.
