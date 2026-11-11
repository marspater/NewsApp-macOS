# Swift 6 modernization review · 11 November 2026

Base: `fix/debug-session-2026-11-10` at `5807e771117c1fda61ea4f11528b8cb22985fbe1`. This review is a **targeted, behavior-preserving hardening pass**, not a claim that every one of the repository's Swift files is migrated or dynamically race-tested.

## Findings and implemented fixes

| Area | Evidence | Change |
| --- | --- | --- |
| Concurrency / cancellation | `ArticleStore.markAllAsRead` used `try?` while waiting for startup; a cancelled caller could still perform a library-wide write once `isReady` became true. `scheduleFollowUpRefresh` also continued after a cancelled sleep. | Exit the bulk-read action on cancellation without surfacing a false storage failure; check cancellation inside the database actor before the bulk write; catch the resulting `CancellationError` separately so no false storage alert is published; stop an abandoned coalesced refresh. A native storage regression verifies no write or reported storage failure for a pre-cancelled caller. |
| Typed errors | `SecureHTTPClient.validateDestination` raises only `FeedError`, but its public signature erased that to `any Error`. | Declare `async throws(FeedError)`, preserving rejection categories at the preflight boundary. Keep `fetchData` untyped because networking and cancellation may throw other errors. |
| SwiftUI observation | `UpdateChecker` used `ObservableObject` and seven `@Published` properties; its two SwiftUI consumers were `SettingsView.@ObservedObject` and `KeyboardShortcutsCommands.@ObservedObject`. | Adopt `@MainActor @Observable` with `@State` in Settings and the Keyboard Shortcuts commands, ignoring the private throttle checkpoint; add a runner test that checks Observation invalidation. Do not mass-convert the Combine-dependent `AppSettings`, `ArticleStore`, `FeedManager`, or `ThemeManager`. |
| Type system / modern generics | `SemanticVersion.parse` unnecessarily required `String` and tested Unicode `Character.isNumber` although SemVer permits ASCII decimal digits only. | Accept `some StringProtocol`, validate UTF-8 ASCII digits, and test `Substring` and non-ASCII numerals. Keep `Comparable` alone since it already inherits `Equatable`. |
| Clean APIs | Production decodes release payloads while `LifecycleTests` encodes them as reproducible test fixtures. | Retain `Codable` on `GitHubReleasePayload` so production and tests compile; avoid unnecessary public API churn. |

## Existing isolation and deferred work

- The application target uses `SWIFT_VERSION = 6.0`, while other Xcode targets use Swift 5 language mode. A uniform switch requires target-specific migration and Xcode 26/27 CI evidence.
- The application already has actor-isolated `FeedManager`, `ArticleStore`, and `SecureHTTPClient` types and a native `@Observable` `WorldTensionModel`. A Combine-backed subscription (`AppSettings.$muteRules` consumed by `ArticleStore`) rules out a mechanical one-file migration.
- `SecureSessionDelegateCoordinator` is `@unchecked Sendable` and protects its mutable per-task state with a lock. Its delegate callbacks and shared use need Thread Sanitizer/runtime scrutiny, not blanket annotation deletion.
- Structured and detached tasks in `FeedManager`, the enrichment queue, and overview generation need focused cancellation and supersession tests before further isolation changes.
- Feed result transport uses a named tuple (`FeedFetchResult`). Replacing it with a `Sendable` value type would touch test injection closures and numerous harnesses; make that a separate, compile-gated migration if needed.

## Verification scope

Changes were prepared through the GitHub connector. A full macOS compilation, the native Swift Testing suite, SwiftUI rendering, and a Thread Sanitizer run are **not** performed in this environment (Linux Swift cannot import the app's AppKit, SwiftUI, and platform dependencies).

Required on an arm64 Mac:
1. `script/format.sh --check`, `script/design_lint.sh` and `script/check_test_registry.sh`
2. `./test.sh`, plus `xcodebuild test -project News.xcodeproj -scheme News -destination 'platform=macOS' -testPlan Development -only-testing:NewsTests/NativeSuites/StorageSuite -only-testing:NewsTests/NativeSuites/FeedParsingSuite`
3. `xcodebuild build-for-testing -project News.xcodeproj -scheme News -destination 'platform=macOS'`, then the CI Xcode 26 configuration and a targeted runtime cancellation/Observation smoke pass

Do not merge solely from this static review if these gates fail.
