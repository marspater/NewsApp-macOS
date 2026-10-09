# Installed-library migration check — 9 October 2026

The production bundle built from `main` commit `c5a8fe0ac767c6adae3c33c587688fa80e29780d` successfully migrated a read-only backup of the installed library from schema v16 to v20. This records the completed migration and runtime checks for [#305](https://github.com/marspater/NewsApp-macOS/issues/305). Live macOS notification delivery remains unverified and, at Mars’s request, is deferred to real compiled-app validation in [#334](https://github.com/marspater/NewsApp-macOS/issues/334).

## Isolation and build

- macOS 27.0.1, build 26A434; arm64; Xcode 27.0 (27A266a), Swift 6.4.
- The installed SQLite source was opened read-only with `query_only` enabled and copied through SQLite's backup API. All migrations, refreshes, reading and model generation used the copy.
- `git archive origin/main` supplied the exact source snapshot. `build_release.sh` built an optimized arm64, ad-hoc signed bundle with its own `com.marspater.news.migrationcheck.6b0dc0e9` identifier and sandbox container. The staged bundle name was News Migration Check.
- Only staged packaging identity changed. The production container-migration manifest was omitted from the temporary bundle so it could not relocate real preferences, app support or caches. App implementation was unchanged.
- Bundle launch, plist validation, arm64 architecture and strict signature verification passed. The installed app executable, Info.plist and real preferences matched their recorded hashes after verification. No installation or production-library mutation was performed.

## Migration checkpoint

These measurements were taken before live refresh and UI navigation:

| Measurement | Read-only backup | After first isolated open |
| --- | ---: | ---: |
| Schema version | 16 | 20 |
| Articles | 1,611 | 1,611 |
| Saved state rows | 3 | 3 |
| Read state rows | 77 | 77 |
| History rows | 77 | 77 |
| SQLite integrity check | ok | ok |
| Foreign-key violations | 1 | 1 |

The saved/read/history row identities and timestamps match exactly at that checkpoint, verified with a digest of sorted durable state. One saved `article_state` row already lacks its parent article in the v16 backup. The migration preserves that same row and violation; the UI consequently shows two visible saved stories. This is inherited data, tracked in [#331](https://github.com/marspater/NewsApp-macOS/issues/331), rather than a clean foreign-key result or a new migration failure. No repair was attempted.

## Model-generation reconciliation

The first open stored `Version 27.0.1 (Build 26A434)` as `model_generation`. Both stored overviews and all three stored summaries became provisional at analysis version 0.

Opening one previously read source through the production reader regenerated its persisted summary at analysis version 3 with `apple.foundation-model`; opening its event overview persisted analysis version 4 and membership version 2. Both rendered in the reader. Reopening the same isolated bundle retained the generation and these v3/v4 results without resetting them to provisional again.

This verifies invalidation, regeneration and persistence. It does not establish independent summary quality or factual acceptance for [#308](https://github.com/marspater/NewsApp-macOS/issues/308).

## Refresh and UI observations

The copied library refreshed the default BBC News and Ars Technica feeds. At the post-refresh observation, it contained 1,650 articles, 238 importance ratings (5 minor, 162 notable, 71 major), and 84 persisted publisher-image URLs. Refresh and retention can change these totals; they are dated observations, not fixed expectations.

The Today view reported four waiting stories. Clicking the control changed it to “Hide 4 waiting” and revealed the filtered stories; clicking again restored the default filtering. Publisher images visibly rendered on grid cards and within the source reader. Reading added history only to the copy; migration preservation measurements above were recorded before those interactions.

One newly fetched page retained a newsletter banner and signup block in its reader document. [#330](https://github.com/marspater/NewsApp-macOS/issues/330) tracks this extraction finding. Publisher passages, generated model text, screenshots and raw library rows remain private.

## Notification boundary and checks

The initial native UserNotifications settings query under the isolated bundle identifier returned authorization status `notDetermined`. Mars then approved enabling notifications for the temporary bundle. The authorization request returned `UNErrorDomain`, code 1, “Notifications are not allowed for this application,” with `granted = false`.

A diagnostic-only rebuild captured the existing AppDelegate authorization callback in the temporary container and confirmed the same rejection as the native helper. The diagnostic changed only result capture, not the permission request or application logic, and was not committed to the repository. No permission was granted. Live operating-system banner delivery and its timing remain unverified; production settings were preserved.

`./test.sh --story-regressions` passed, including `testStoryVisibility`: the production FeedManager dispatches its notification callback after importance rating while publisher-image lookups remain blocked on an explicit gate. That is deterministic dispatch-order proof, separate from macOS delivery. The full commit-hook regressions also passed when publishing this audit.

The approved LaunchServices registration refresh completed and the existing app authorization callback returned the same rejection. The notification daemon could not find or validate the temporary client identity; the underlying cause remains undiagnosed. On 9 October Mars deferred delivery validation to the real compiled app. [#334](https://github.com/marspater/NewsApp-macOS/issues/334) tracks actual notification presentation, image-lookup timing and click-through on that build. No notification permission or registration approval is pending.

No sealed holdout replay, parked-language or VoiceOver acceptance, distribution, notarization or installation was performed. The isolated migration scope in #305 is complete and remains In review through PR #332 until merge. Notification delivery was deferred, not passed.

## Work log and remaining queue — 9 October 2026

- Resolved the Jules PR queue against current code. Useful corrections are merged through PRs #325–#327; there are no open Jules PRs at this status check.
- Test preference cleanup #311 is complete through merged PR #328 (`a4db2d4`). The runner removes only its own UUID preference after process exit; the verified run left no new plist and legacy preferences were preserved.
- Current feature documentation #315 remains In review through PR #329. Its retargeted head is `19dacc8`; new hosted CI is running. Earlier-head checks do not establish completion of that run.
- Isolated migration #305 remains In review through PR #332. The source tested was `c5a8fe0`; current main `a4db2d4` adds only the reviewed test-runner cleanup. Saved/read/history preservation, one-time provisional marking, regeneration, reopen behavior, live waiting controls and rendered images passed. Full local regressions passed; the app and real preferences were preserved.
- Ready: current matcher evaluation #307 (P1), independent overview quality/latency #308 (P1), and importance instructions plus independent-label/stability measurements #309 (P2). The data choice for #307 and borderline importance rules for #309 are already decided; scoring and implementation remain unfinished.
- Backlog: reader newsletter removal #330, inherited saved-state orphan #331 and card figure fallback #312 (P2). Real-app notification validation #334 is deferred in Backlog (P1) until the real compiled build is validated.
- #313/#314 remain optional ideas; #264/#268 remain parked; the tension experiment/calibration and source discovery #99/#235/#244 remain outside core release work.

PR #328 is merged. PR #329 should merge before the audit PR #332, which also reconciles the plan below. No new installation or real-app acceptance is claimed by this log.
