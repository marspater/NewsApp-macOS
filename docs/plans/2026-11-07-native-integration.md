# Native integration plan (#577, #1070, #1113)

Date: 7 November 2026. The external audit was reviewed at 312ec37 and checked against main 2976e53 plus PR #1114 (since merged). The maintainer's review approved items A to G with two corrections, applied below: Swift 6 language mode is switched per target, not per file, and `NEWS_LIBRARY_NAME` is a validated name. B is bounded to one reversible vertical slice and blocks nothing.

## 1. Claims verified

| Claim | Verdict on current main |
|---|---|
| Four native targets, synchronized folders, incremental builds | True |
| App in Swift 6, test targets in Swift 5 | True: `NewsTestRunner` and `NewsTests` both `SWIFT_VERSION = 5.0` |
| `NewsTestRunner` and `NewsTests.xctest` compile `Sources/` themselves, same exclusions | True: identical exception lists in `project.pbxproj`; `NewsHarness` compiles it a third time |
| Three native tests | Stale: 11 since #1109 (migration suite, 8 tests at full assertion parity, plus 3) |
| No UI-test target, no `.xctestplan`, no `#Preview` | True |
| `Logger` and `OSSignposter` in use | True: `NewsSignposts.swift` has 13 categories |
| Publisher-excerpt harness about 5m50s | Stale: 1m42s to 1m51s since #1108 (Debug build); the harness still recompiles `Sources/` |
| `.xcresult` not produced | Stale: #1109 runs `xcodebuild test -only-testing:NewsTests` with `-resultBundlePath` and uploads the bundle |
| Swift Testing parallel by default; isolate before broad execution | Done for what exists: one `.serialized` parent suite (#1109) and the scheme runs the bundle serially |
| `NewsApp.swift` builds shared state | True: 29 `.shared` references |
| `NewsShortcuts: AppShortcutsProvider` with five intents | True |
| #720 names the widget prerequisite | True, open |
| `docs/XCODE_AND_APP_REVIEW.md` says three targets | True, line 30 |
| `script/xcode_build.sh` filters one Xcode message | True, line 15, a `sed` on one bogus "exit code 0" error line |
| Debug bundle id `com.marspater.news.dev` isolates Run | True; Profile was Release with the real id until #1114 |

Verification table as of 7 November 2026.

Not in the audit, measured today: the native-test step costs 4m38s in CI, the second-largest cost of the test job, because the bundle is a full compile of `Sources/`. `Run Unit Tests` on the same runner class measured 3m32s, 6m50s and 8m04s across three runs today. Any build-time acceptance in this plan is a median of three runs per step, never one job total; `docs/audits/2026-11-07-build-measurement-protocol.md` is the protocol.

Audit constraints confirmed as fixed: GitHub Actions, CircleCI and Codemagic all stay; SQLite/FTS5 stays (no SwiftData); #264 localisation stays parked.

## 2. Work items, in order

### A. Phase 0: measurement protocol and two quick fixes (small PR, no decision needed)
- `docs/audits/`: the protocol: cold build, incremental build after one-file edit, each CI step, each a median of three runs; local numbers tagged with Xcode version and load average.
- `docs/XCODE_AND_APP_REVIEW.md`: four targets, which is the native verification path.
- `script/xcode_build.sh`: keep the filter, but write the unfiltered transcript to `build/xcodebuild-<target>.log` and name it on failure.

### B. `NewsCore` spike with a kill criterion (conditional go, one reversible PR)
Facts: `Models`, `Storage`, `Intelligence`, `Services`, `Coordinators` hold 307 top-level types and 89 `public` declarations; six of their 81 files import SwiftUI or AppKit; nine files reference `AppSettings` (26 uses), the one upward dependency.
- Scope: one meaningful vertical slice with measurable compile weight and a clean boundary, as a static library target the app, `NewsTests` and `NewsHarness` link; not the 307-type extraction. `package` access for what only the app and tests need, `public` only where the boundary forces it.
- `AppSettings` stays out of `NewsCore`: it is a main-actor observable configuration object. Pass snapshots or a narrow protocol instead.
- Resources: `bundledModelResource` falls back to `Bundle.main`, then a checkout path. Any Core ML resource the slice owns needs an explicit library-bundle resolution path; model paths and hashes stay unchanged, the entitlements and bundle-integrity tests prove it.
- No duplicate compilation: the slice leaves the other targets' source memberships, in both the Xcode build graph and `Package.swift`.
- Acceptance: cold, incremental (after a core and a UI edit) and test builds measured per the protocol on the same toolchain and machine; security, storage and model-resource tests unchanged.
- Kill criterion: a repeatable cold or incremental slowdown beyond run variance, access-control churn beyond one PR, or a need for rescue PRs: revert and record an ADR in `docs/plans/` with the hypothesis, timings and reasons. B does not block C to G.

### C. Native Swift Testing, domain by domain (#1070, continues the current pattern)
- Next domains in order: feed parsing, storage, networking, intelligence; `#expect`/`#require` only, every assertion kept, runner copy deleted once CI shows parity for that domain.
- Fold `PublisherExcerptTests` into the native target: removes the harness compile from every CI run.
- Tags per domain (`.feedParsing`, `.migration`, `.feedHealth`, then `.storage`, `.networking`, `.intelligence`) from the first ported suite on.
- Test plans (`Development`, `Integration`, `Release`) only after three domains carry tags; `UI` and `Performance` plans with E and G.
- Swift 6 language mode is a target setting: files are prepared for it as suites move, and `NewsTests` switches as a whole once its concurrency diagnostics are resolved.
- Deterministic publisher-excerpt correctness checks move; timing and performance workloads stay measured separately.

### D. Library name override (prerequisite for E)
`NEWS_LIBRARY_NAME` on `DatabaseEngine.defaultLibraryURL`: `<name>.sqlite3` in the directory the default library already uses (inside the sandbox container `Application Support/com.marspater.news/`). Validated: letters, digits, `-`, `_` and `.` only, no `/`, no `..`, not empty; an invalid value is ignored with a logged warning, never another directory. UI tests get a fresh name per run. Database isolation is not full app-state isolation: UserDefaults, caches, Keychain entries and notifications may still be shared. Smoke check: a uniquely named Debug library leaves the normal development library untouched.

### E. `NewsUITests` (XCTest, XCUIAutomation) against the Debug app
- Smoke flows from the audit: open the main window, switch sections, search, open an article, save a story, Settings; deep links and notifications once fixtures are deterministic.
- Launch arguments: `.dev` bundle, `NEWS_LIBRARY_NAME`, fixture feeds from `Tests/Fixtures`.
- CI only for agents (the local rule forbids window-opening runs); local verification is yours. Adds an `xcodebuild test -only-testing:NewsUITests` step with its own `.xcresult`.

### F. SwiftUI previews with fixtures
- `Tests/Fixtures`-backed preview fixtures: sample articles, fake store, fixed clock, refresh states.
- Five component families: article cards, feed health, publisher health, reader detail, settings panes, briefing components; variants normal, loading, empty, error, long text, dark, accessibility.
- Agents compile-check `#Preview` blocks; rendering is yours in Xcode.

### G. Instruments and performance baselines
- `xctrace` recordings of the existing signpost categories, main-only or scheduled workflow, never PR CI.
- XCTest performance metrics for memory, clock and CPU baselines inside E's target.
- MetricKit deferred.

### Deferred or declined, one line each
- Shared `.xcconfig`: the scripts pass settings on the command line, which override xcconfig; nothing to gain now.
- WidgetKit: after B and #720's snapshot design.
- Login item, string catalogs, SwiftData: declined as the audit itself suggests; #264 stays parked.

## 3. Dependencies
1. A: baselines and transcripts.
2. B (independent experiment) and D.
3. C and E.
4. F.
5. G.

B never blocks C to G: if the spike fails its measurements they proceed on the current targets. D before E. C's test plans after three tagged domains. GitHub Actions, CircleCI and Codemagic all stay.
