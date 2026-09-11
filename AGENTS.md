# Jules / Agent Instructions

## Mission
You are an engineering agent working on **NewsApp for macOS**, a native, local-first RSS/news reader. Make focused, production-quality changes that preserve the existing product direction.

## Repository facts
- Platform: macOS
- Language: Swift
- UI: SwiftUI + AppKit/WebKit where already required
- Minimum package platform currently declared: macOS 15
- Modern Liquid Glass APIs are available conditionally where the project already uses them; do not raise deployment targets casually.
- Persistence: SQLite3 with WAL/FTS5
- Networking: native Foundation URL loading through the existing security-aware HTTP layer
- Feed formats: RSS/XML, Atom-compatible parsing, JSON Feed
- AI: Apple-native frameworks already used by the project, including NaturalLanguage and FoundationModels when available
- Architecture: local-first, zero telemetry, no cloud backend
- Distribution: Universal 2, Hardened Runtime, App Sandbox

## Non-negotiable technology constraints
1. Use the native Apple stack already present in the repository.
2. Do **not** introduce custom AI models, third-party AI APIs, hosted LLMs, telemetry SDKs, analytics services, or cloud processing.
3. Prefer Foundation, SwiftUI, AppKit, WebKit, SQLite3, NaturalLanguage, FoundationModels, OSLog/signposts, and Swift Concurrency.
4. Avoid third-party dependencies unless the task explicitly requires one and there is no reasonable native implementation.
5. Do not replace working native subsystems merely for architectural fashion.

## Product principles
- Native macOS behavior over cross-platform abstractions.
- Local-first privacy and predictable offline behavior.
- Fast startup, low memory pressure, low battery impact.
- Keyboard-first interaction and trackpad-friendly navigation.
- Liquid Glass should feel native, restrained, and semantic, not like a translucent blob was poured over the UI.
- Accessibility is part of correctness.

## AI / article intelligence rules
- Classification correctness is critical.
- The app should **not fully process every RSS item by default** when the product flow does not require it.
- Lightweight ingestion should remain cheap; expensive extraction/analysis should happen on explicit demand or through clearly defined background enrichment rules.
- Use structured outputs for classification where FoundationModels is used.
- Keep taxonomy deterministic and constrained to the app's supported categories.
- Never invent article facts. Clearly distinguish extracted facts from model-generated summaries.
- Persist only the intelligence fields that are necessary for product behavior and display.
- Keep model identifiers and analysis versions explicit so persisted results can be invalidated safely.
- Provide deterministic fallbacks for unsupported/unavailable model environments.

## Architecture rules
- Preserve actor isolation and Swift 6 concurrency correctness.
- Keep UI concerns out of database/network/domain layers.
- Reuse existing managers/services before adding parallel implementations.
- Prefer small focused types and protocol boundaries where they improve testability.
- Avoid global mutable state unless an existing singleton is already the established pattern.
- Do not introduce retain cycles through async tasks, timers, NotificationCenter observers, WebKit delegates, or closures.
- Cancellation must propagate through long-running feed fetch, content extraction, and enrichment work.
- Bound concurrency and memory for batch processing.

## Security rules
- Treat feed URLs and article URLs as untrusted input.
- Preserve SSRF defenses and IP/host validation.
- Do not weaken App Sandbox or Hardened Runtime entitlements.
- Never log secrets, full sensitive URLs containing credentials, user data, or article contents unnecessarily.
- Validate redirects and downloaded content through the existing secure networking path.
- Avoid unsafe HTML/script injection when rendering article content.

## Database rules
- SQLite schema changes require a migration path.
- Maintain WAL and FTS5 behavior unless there is a measured reason to change it.
- Avoid blocking the main actor with database work.
- Use transactions for multi-step writes where atomicity matters.
- Preserve existing user data, saved stories, and read history.

## UI / UX rules
- Follow the existing semantic design system instead of scattering raw constants.
- Reuse existing glass components/tokens where possible.
- Respect macOS conventions for toolbar, sidebar, menus, keyboard shortcuts, focus, sheets, and settings.
- Icon-only controls need accessibility labels/tooltips where appropriate.
- Do not add gratuitous animation. Prefer subtle, interruptible transitions that do not interfere with reading.
- Avoid layout hacks tied to one display size.

## Testing requirements
Before considering a change complete:
1. Run `./test.sh` when available.
2. Build with `./build.sh` for app-level changes when the environment supports macOS compilation.
3. For release/distribution changes, also validate `./build_release.sh` and relevant packaging/signing scripts when possible.
4. Add or update deterministic tests for parsing, categorization, persistence, migrations, security boundaries, and state transitions affected by your change.
5. Do not remove tests simply because they are inconvenient.

## Code change discipline
- Read the relevant existing implementation before modifying it.
- Make the smallest coherent change that fully solves the task.
- Keep public APIs stable unless the task requires an intentional breaking change.
- Match existing naming and formatting conventions.
- Do not leave dead code, compatibility shims, debug prints, commented-out experiments, or TODOs that are not part of the requested work.
- Update documentation when behavior, commands, architecture, security, or distribution changes.

## Git / PR discipline
- Prefer focused commits with descriptive messages.
- Do not rewrite unrelated files.
- Do not modify generated release artifacts unless the task explicitly targets them.
- Summarize what changed, why, tests run, and any environment limitations.
- Do not claim a build/test passed unless it actually ran successfully.

## Jules operating procedure
1. Inspect the repository structure and relevant source files.
2. Identify the existing architectural path for the requested behavior.
3. Implement within that path rather than creating a competing subsystem.
4. Run the narrowest useful tests first, then the full project test/build checks.
5. Review the diff for regressions, security issues, concurrency problems, memory/lifecycle problems, and unnecessary complexity.
6. Report concrete results and remaining limitations.

Before implementing changes, verify that the working branch is based on
the current `origin/main`.

Before creating the PR, fetch `origin/main` again and verify that the
task has not become stale relative to the current default branch.

If `origin/main` advanced materially during the task, stop and re-evaluate
the work against the new state before creating the PR.
