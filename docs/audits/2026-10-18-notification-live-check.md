# Real compiled-app notification check — 18 October 2026

Wave 1 follow-up for [#334](https://github.com/marspater/NewsApp-macOS/issues/334) and [#90](https://github.com/marspater/NewsApp-macOS/issues/90). Times below are Europe/Warsaw (UTC+2).

## Result and remaining acceptance

The real compiled News app refreshed the real library, submitted three full notifications, and macOS logged two banner presentations. Mars clicked one notification; the daemon forwarded its response to that exact running executable, and the app opened a publisher story in its reader.

**Still unverified:** whether publisher-image lookup was unfinished at the instant of live OS delivery. The production control flow starts `lookUpStoryImages()` after clustering and does not await it before notification triage; the full regression suite passed the existing blocked-image dispatch check. That is separate evidence and does not establish live timing. Keep #334 open for this remaining acceptance criterion.

## Build identity and authorization

- Source: clean `aa795a4c041e61b60260c2324afcda8b6d9d56ab` from `origin/main`; branch `fix/hindu-and-notification-audit`. Only audit documentation was added afterwards.
- Command: `./build.sh`, exit 0, in the isolated worktree. The script emits `News.app` in its working directory, not `.build/News.app` as stated in the plan.
- Executed bundle: `<wave-1-worktree>/News.app`; observed PID 42330. No installed bundle was replaced or reinstalled.
- Bundle ID `com.marspater.news`, arm64, ad-hoc signature with Hardened Runtime; `codesign --verify --strict` passed.
- CDHash `aeddf772173d06080d486b764c3f34655a65b42d`.
- Executable SHA-256 `3a231dddb7164ec78e4b2038313b8e0df876b4a494e4a37314034f447eb10508`.
- Host macOS 27.0.1 (26A434); Xcode selected at `/Applications/Xcode.app/Contents/Developer`; deployment target macOS 15.
- System Settings initially showed News notifications off. Mars explicitly authorized enabling them for this audit. The resulting UI showed notifications on, Desktop/Notification Centre/Lock Screen enabled, Temporary alert style, sound and badges on. Notifications remain enabled. Authorization was observed in System Settings, not by an instrumented `getNotificationSettings` call.

## Runtime observations

| Time | Evidence |
| --- | --- |
| 06:36:53.404 | `usernoted` connected `com.marspater.news` to the exact worktree bundle above. |
| 06:37 | The production UI completed refresh and offered 173 new visible stories. The database gained 486 article rows; these are different denominators. |
| 06:37:33.099, .546, .547 | `NotificationService` logged three successful full-notification submissions. |
| 06:37:33.798–.799 | `usernoted` logged delivery of two requests to alert/lock-screen/notification-centre destinations and presentation as banners. The daemon also recorded Focus delay-delivery decisions; no Focus setting was changed. No third banner is claimed. |
| 06:42:04.731–.734 | Following Mars's click, `usernoted` received the contents/default action for one of those requests, notified PID 42330, and brought the exact worktree bundle forward. |
| After click | Accessibility inspection showed the publisher reader and story heading, with the unread count decreasing by one. Story content and private identifiers are omitted here. |

The desktop tool timed out trying to inspect Notification Centre itself. Banner evidence therefore comes from the daemon, not a screenshot. Click-through combines Mars's action, the daemon response, and the app's resulting reader UI; the notification's displayed title was not independently captured for comparison.

One unrelated `ArticleStore` enrichment-update error appeared at 06:37:42.867 with a privacy-redacted cause. Its cause was not established; no storage change or claim of an error-free refresh is included in this audit.

## Preservation

The plan's `~/Library/Application Support/News/news.sqlite` does not exist. The real database is `~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3`; its preferences are `~/Library/Containers/com.marspater.news/Data/Library/Preferences/com.marspater.news.plist`.

Before launch, a coherent SQLite backup and preferences copy were stored privately in `/private/tmp/news-wave1-preservation/`. After the audit, every original article and all 2,394 original `article_state` rows remained. Existing `is_read`, `is_saved`, `read_at` and `saved_at` values were identical. There were 2,880 article rows afterwards and one newly fetched story marked read by the requested notification click. Subscriptions and application settings were identical; only `NSWindow Frame main` changed in preferences. No backup was restored over the refreshed library. The audit bundle was quit and its process absence verified.

Raw file hashes differ because this was a real refresh and window launch. SQLite WAL means the main-file hash alone is not a logical library comparison; the coherent backup and row comparisons provide that evidence.

| File | Before SHA-256 | After SHA-256 |
| --- | --- | --- |
| Main SQLite file | `b08ebb2ed05713b4f60ce0269f6bb36a00c1f443f8f6053bf62961c03567bdf9` | `e35d95cc853da286b8b5f391baf026d1e59cc9c5e4a50e6a9293e2d7b4afe5b9` |
| Preferences | `da4c02465bd5a1e008091c21902d62e79b43a261a1820de668ee14f3df9fb36d` | `f396c4df1ceb4d0f48a8d5da28f96c34ccdd4eaebc0b27bef779b8b166c7ddc7` |

## Checks and follow-up

The full `./test.sh`, `./build.sh`, strict signature verification and catalog-review validation passed. Private logs: `/private/tmp/news-wave1-tests.log`, `/private/tmp/news-wave1-build.log`, `/private/tmp/news-wave1-runtime.log`, `/private/tmp/news-wave1-delivery.log`, `/private/tmp/news-wave1-clickthrough.log`. These local artifacts are not committed and are not durable CI evidence.

To finish #334, capture explicit start/end timing for production image lookup alongside a new eligible-story refresh and OS delivery. Also compare the notification's displayed title with the reader destination directly. Do not replace this remaining check with the already-passing injected-callback regression. This audit establishes no installation, distribution, hosted CI or Gemini embedding-track acceptance.
