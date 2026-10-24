# Comprehensive analysis and improvement plan — 24 October 2026

Status: plan as approved by Mars on 24 October 2026 (baseline `origin/main` `00382fe`). Slices land as separate PRs; outcomes are recorded in section "Outcomes" as they merge.

Baseline: `origin/main` `00382fe` (after #489). Worktree branch `mars/app-comprehensive-analysis-2b842c`. CI and Security green, `script/format.sh --check` and `script/design_lint.sh` pass locally, no open PRs, only parked #264/#268 open.

## Context

Mars asked for a full analysis of the app: missing features, code that does not work, dead code, continuous improvements. Three exploration passes (dead code, correctness, gaps vs. the 21/23 October plans) produced the findings below; every item cited here was re-verified in code. Mars decided: wire up retention (not delete it); scope = bugs + dead code, small missing features, and the open finish-pass slices 4–10; keep opt-in audit tooling (TensionCalibrator, OverviewQualityAuditor), delete the other test-only production code.

Short names: FM `Sources/Coordinators/FeedManager.swift`, DB `Sources/Storage/DatabaseEngine.swift`, DBE `DatabaseEngine+Events.swift`, AS `Sources/Storage/ArticleStore.swift`, ADV `Sources/Views/ArticleDetailView.swift`, RSV `ReaderSupportViews.swift`, EOV `EventOverviewReaderView.swift`, DS `DesignSystem.swift`, CEP `Sources/Intelligence/ContentExtractionPipeline.swift`, NS `NotificationService.swift`.

## Findings (verified)

### Wrong behaviour
1. **Retention never runs.** `DB:2765 pruneOldArticles` and `AS:351` have no app caller since they were written (`git log -S`). Library grows forever; `PRIVACY.md:76` promises pruning; `pruneEmptyEvents` (`DBE:1176`) only runs from there.
2. **Stories committed by a cancelled refresh never notify.** Add/remove/import feed and sleep cancel the refresh (`FM:158/171/177/194/351`); committed feeds' IDs are in `insertedIDs` but `FM:514` returns `[]`; next run sees them as existing.
3. **Loading state stuck after sleep cancel.** `cancelRefresh()` (`FM:385`) clears `refreshRunID`; the waiter returns at `FM:442` before `isAnyFeedLoading = false` (`FM:445`). Feed `.loading` statuses stay until the next refresh.
4. **Undated stories miss the Briefing window.** `publicationWindowConditions` (`DB:1839`) compares raw `a.published_at` (= `distantPast`) instead of `Self.articleDateOrder` (`DB:1702`); `EventFeed.swift:366-368` filters on `pubDate` again; `OverviewGenerationCoordinator.swift:395` same.
5. **JSON Feed items with neither `id` nor `url` get `UUID()` as id and link** (`JSONFeedParser.swift:37-38, 75`) → new story + notification every refresh.
6. **"Clear AI Analysis Data" leaves overviews and embeddings.** `clearArticleEnrichment` (`DB:2718`) deletes only `article_enrichment` + tension history; `clearEventOverviews` (`DBE:431`) has no caller.
7. **"Check for Updates…" silent when up to date or failed** (`NewsApp.swift:56-62` sets `statusMessage` nobody shows).
8. **Menu OPML import gives no feedback** (`NewsApp.swift:70-72` drops the count); Settings path (`SettingsView.swift:211-213`) shows "No new feeds imported" on a malformed file.
9. **Reader state carries over from overview → source.** `ADV:204-215` set `activeArticle` without `resetReaderState()` (`ADV:1591`); `reloadGeneration > 0` forces a network re-extraction, `webLoadError`/`webCanGoBack`/`summaryExpanded` leak.
10. **Notification IDs unstable:** `NS:181` uses `article.link.hashValue` (per-process seed).
11. **DB read errors become empty results:** `getReadArticleIDs` (`DB:2305`) → everything unread; `feedFetchStates` (`DB:1591`) + `FeedFetcher.swift:70 try?` → validators/backoff lost; `pruneOldArticles` returns 0 on prepare failure.
12. **`getUserVersion` returns 0 on failure** (`DB:1076-1089`); v1 block not transactional, v2 `ALTER TABLE` not idempotent → a transient PRAGMA failure can brick the file (unconfirmed trigger; fix is cheap).
13. **Gateway never recovers from a failed listener** (`NetworkBoundaryProxy.swift:92-94` stops; `SecureHTTPClient.swift:49` caches the port) — unconfirmed trigger; restart-on-demand is cheap.
14. **Blocking serial DNS:** `SecureHTTPClient.swift:131 getaddrinfo` inside the actor; one hung lookup stalls all requests.

### Dead code (0 references outside definition unless noted)
- Whole files: `Sources/Views/GlassSystem.swift` (4 helpers, DESIGN.md §3.3 names them), `Sources/Coordinators/RefreshCoordinator.swift` (test-only; ARCHITECTURE diagram still shows it as the refresh entry), `Sources/Intelligence/ModelAvailability.swift` (test-only).
- `ArticleIntelligence.swift`: `ArticleIntelligence` class 974–1037 (+`isFoundationModelsAvailable` 771), `ArticleContentPolicy`/`ArticlePreviewPolicy` 1247–1261, `TrackpadSwipe*` 1265–end. All test-only (`NewsTests.swift:10887, 13631`). Keep the analyzers/protocols: `ArticleAnalyzer`, `ArticleClassifier`, `NewsTextModel`, `ArticleAnalysis` are used.
- `PassageFactExtractor.swift:274 extractFactsWithModel` + `GenerablePassageFactItem` (78), `GenerablePassageFactExtraction` (93) — matches the FoundationModels `@Generable` memory (refused on harsh news).
- Functions: `CEP:1806 htmlToPlainText`; `EnrichmentQueue.swift:143 promote`, `:236 pendingJobCount`; `OverviewGenerationCoordinator.swift:515 cachedOverview`; `OverviewQualityAuditor.swift:296 measureAsync`, `:38 failureDetail`; `PromptDefense.swift:11-12 passageStartTag/EndTag`; `EOV:608 citationPillsView`, `:55 activeCitationPreview`, `:47 colorScheme`; `TensionMethodology.swift:661 latestReading`, `:718 latest(in:)`; `AS:434 deleteEventOverview`, `:410 recordVerifiedOverview`; `CacheManager.swift:66 clearAIAnalysis`, `:73 clearArticleCache` (duplicates of `AS:331/337`); `ReadManager.shared`, `SavedStoriesManager.shared` (AppContainer builds its own); `FM:238 setPrivateNotificationsEnabled` + `AppSettings.swift:85/324 privateNotificationsEnabled`; `AppSettings.swift:561/577 overrideVoiceOver/effectiveVoiceOver` (set, never read); `NewsApp.swift:7 Notification.Name.openArticleFromNotification`.
- DS tokens: `AppColor.label` (dup of `primaryText`), `tertiaryLabel`, `focusRing`; `AppSpacing.xxl`; `AppRadius.bubble`; `AppTypography.sourceEyebrowTracking`; `AppShadow.cardSelectedGlow/Radius/Y`; `AppMotion.modal/smooth`; `OverviewTextRole.detail`. Test-only: `AppLayout.sectionGap`, `AppRadius.pill/small/medium` (`NewsTests.swift:11103-11113`).
- `NewsApp.swift:294 if #available(macOS 14.0, *)` — else branch unreachable (minimum is 15).
- Duplicate helpers: `JSONFeedParser.swift:138 stripSimpleHTML` ≈ `FeedXMLParser.swift:609 stripHTMLSimple` (JSON one has a partial entity table; use `ContentExtractionPipeline.decodeHTMLEntities`); `CEP:1121 normalizedEvidenceText` ≡ `ArticleIdentity.swift:74 normalized`.
- Scripts nothing runs: `script/test_event_overview_accessibility.sh`, `test_reader_accessibility.sh`, `test_tension_calibration.sh` (stale hand-written file lists; `Tests/EventOverviewAccessibilityTests.swift`, `ReaderAccessibilityTests.swift`, `TensionCalibration*.swift` reachable only through them). `Tests/NativeWorldTensionQA.swift` referenced only by CONTRIBUTING `NEWS_NATIVE_HARNESS=` (fine).
- Tests: `NewsTests.swift:13608 assertTrue(true, …)`; `testCatalogReaderAccess` (`:3393`) asserts nothing (opt-in live, acceptable).
- Undocumented env vars: `NEWS_OVERVIEWS_MAX_EVENTS`, `NEWS_OVERVIEWS_RUN_NAME`, `NEWS_SNAPSHOT_DB`, `NEWS_WORLD_TENSION_INTERACTIVE`, `NEWS_SETTLE_SECONDS`.

### Missing (small, high value)
- Mark All as Read: `AS:198 markAllAsRead` + `DB:2194` exist, no UI.
- Remove Section (`SidebarView.swift:151`) and Unsubscribe (`SettingsView.swift:319`) have no confirmation.
- Dock badge: `.badge` authorization requested (`NewsApp.swift:265`), never set; `ArticleStore.unreadCount` is published.
- Menus: no ⌘[ / ⌘] on Web Back/Forward (`NewsApp.swift:172-173`), no List/Grid shortcuts, no World Tension command; Keyboard Shortcuts window (`ArticleListView.swift:1150`) lacks ⌘F ⇧⌘I ⇧⌘E ⌘J ⌘K ⇧⌘U ⌘S ⌘O.
- `script/format.sh --check` runs in no CI (ci.yml, .circleci/config.yml, codemagic.yaml).
- Docs drift: ARCHITECTURE sequence diagram starts at `RefreshCoordinator`; DESIGN §3.3 lists Glass helpers; PRIVACY.md:76 pruning promise.

### Finish-pass slices still open (from `docs/plans/2026-10-23-finish-pass.md`)
Slice 4 mostly open (blockquote box `ADV:701`, code wraps `:723`, links no underline / `OpenURLAction` / `baseURL: nil` at `RSV:212`, figures `RSV:150/156/180/118`, hero `ADV:424-439`, end links in all states `:389`, reading time from `fullContent` `:457`, web container literals `:813/829/831`, `ToolbarLoadingBubble` `RSV:264`, summary disclosure `:365`, `:1230/1287/1297`, performance `:95-99`, `:655`). Slice 2 leftover: `iframe`/`video` → `.embed` (`CEP:710`). Slices 5–10 not started (details in that plan; agent check confirmed every bullet open).

## Plan — slices (one PR each)

Every slice: `./test.sh`, `script/format.sh --check`, `./build.sh` in a staging directory, CHANGELOG entry, project board #2 move, DESIGN checklist in UI PRs. No AI attribution lines in commits/PRs (memory). Unit tests land with their slice. Record outcomes in this file's docs copy (`docs/plans/2026-10-24-comprehensive-analysis.md`, added in slice A).

### Slice A — Correctness fixes, storage and refresh (S/M) — FM, DB, DBE, AS, `JSONFeedParser.swift`, `EventFeed.swift`, `OverviewGenerationCoordinator.swift`, `SettingsView.swift`, `PRIVACY.md`
- Retention: `AppSettings.articleRetentionDays` (0 = never, default 30; `@AppStorage`). In `FM.fetchFeedsAsync` after a successful run, `if retention > 0 && lastPruneAt older than 24 h { await articleStore.pruneOldArticles(keepReadDays:) }` (persist `lastPruneAt` in UserDefaults). Settings › Storage: `Picker("Delete read stories after", …)` Never / 30 / 90 days with a footer: saved stories and cited sources are kept. Test: prune respects the picker and the 24 h throttle (fake clock, `FM.now` already injectable).
- Cancelled refresh: keep committed-but-unnotified IDs in `pendingNotificationIDs: Set<String>` on FM; on cancel path (`FM:514`) store `insertedIDs`; next successful run unions them into `newArticles` resolution via SQLite by ID (ARCHITECTURE: notifications resolve by stable ID). Test: cancel after feed 1 commits; next run notifies feed 1's story once.
- `cancelRefresh()`: also `isAnyFeedLoading = false` and reset per-feed `.loading` statuses (reuse the reset at `FM:445-448`, extract to `finishRefreshState()`).
- `publicationWindowConditions`: use `\(Self.articleDateOrder)`; `EventFeed.swift:366` and `:227` use `queryOrderValue ?? pubDate`; `OverviewGenerationCoordinator.swift:395` same. Test: undated story created today appears in Briefing.
- `JSONFeedParser.swift:37`: `guard item["id"] != nil || item["url"] != nil else { continue }` (drop the UUID fallback). Test fixture: item without id/url is skipped.
- `clearArticleEnrichment`: add `try clearEventOverviews()` and embeddings delete (`article_embeddings`), inside one transaction. Settings copy "Clear AI Analysis Data" footer lists what goes.
- `getUserVersion`: throw instead of returning 0; wrap the v1 block in the same BEGIN IMMEDIATE pattern as v2+.
- Read paths throw on `sqlite3_step` ≠ `SQLITE_DONE`: `getReadArticleIDs`, `feedFetchStates`, `pruneOldArticles`; `FeedFetcher.swift:70` logs instead of `try?`.
- Docs: PRIVACY.md pruning sentence matches the new setting.

### Slice B — Correctness fixes, UI and services (S) — `NewsApp.swift`, ADV, NS, `NetworkBoundaryProxy.swift`, `SecureHTTPClient.swift`
- `NewsApp.swift:56`: on `!updateAvailable` show `NSAlert` with `statusMessage` (reuse the existing alert helper used for OPML errors).
- OPML menu import: alert "Imported N feeds" / "No new feeds"; Settings path distinguishes malformed from empty (reuse the Subscriptions status helper from #484).
- `ADV:204-215`: call `resetReaderState()` in both callbacks before setting `highlightedPassage`.
- `NS:181`: `identifier = "news-\(article.id)"`.
- Gateway: `port()` restarts the listener when `state == .cancelled/.failed`; `SecureHTTPClient` drops its cached session when the port changes. Test: stop the proxy, next request succeeds.
- DNS: resolve on `Task.detached` / a concurrent queue so lookups do not serialize in the actor (keep the pinning checks).

### Slice C — Dead code removal (M, no behavior change) — many files
- Delete: `GlassSystem.swift`, `RefreshCoordinator.swift`, `ModelAvailability.swift`; the `ArticleIntelligence` class, `ArticleContentPolicy`, `TrackpadSwipe*`, `isFoundationModelsAvailable`; `extractFactsWithModel` + `Generable*` types; every function and token listed under "Dead code"; the three unreferenced scripts and the test files only they reach (`EventOverviewAccessibilityTests.swift`, `ReaderAccessibilityTests.swift`, `TensionCalibrationRunner.swift`, `TensionCalibrationTests.swift`) **only if** `TensionCalibrator`/`OverviewQualityAuditor` audit paths stay reachable via `./test.sh --overviews-live` and `--tension-*` flags (check `Tests/NewsTests.swift` dispatch first; if a flag reaches them, keep the test file and delete only the script).
- Remove tests `testArticleIntelligenceCapabilities`, `testRefreshCoordinatorSingleFlightCoalescing`, `testModelAvailabilityAndLanguageFallbacks`, the `assertTrue(true)` at `:13608`, and the token-only assertions for deleted tokens.
- Remove from `build.sh`, `script/build_test_runner.sh`, `script/native_performance_baseline.sh` and other file lists (grep each deleted file name across `script/`).
- `AppColor.label` → `primaryText`; `#available(macOS 14.0)` → direct call; `JSONFeedParser.stripSimpleHTML` → `FeedXMLParser.stripHTMLSimple` + `decodeHTMLEntities`; `ArticleIdentity.normalized` → `CEP.normalizedEvidenceText` (or the reverse, whichever has fewer callers); CacheManager duplicates → `ArticleStore`.
- Docs: ARCHITECTURE sequence diagram starts at FM (`NSBackgroundActivityScheduler`, sleep/wake live in FM); drop RefreshCoordinator from the ownership table; DESIGN §3.3 glass helpers paragraph; CONTRIBUTING documents or removes `NEWS_OVERVIEWS_MAX_EVENTS`, `NEWS_OVERVIEWS_RUN_NAME`, `NEWS_SNAPSHOT_DB`, `NEWS_WORLD_TENSION_INTERACTIVE`, `NEWS_SETTLE_SECONDS`.

### Slice D — Small missing features (S) — `NewsApp.swift`, `ArticleListView.swift`, `SidebarView.swift`, `SettingsView.swift`, `MainView.swift`, CI configs
- Mark All as Read: Story menu item + list toolbar overflow, ⌥⌘U, calls `articleStore.markAllAsRead(feedUrl:)` scoped to the current view (Today/Unread → all; a section → its feeds); `confirmationDialog` (pattern `ArticleListView.swift:417`).
- `confirmationDialog` for Remove Section and Unsubscribe (same pattern).
- Dock badge: in `MainView` `.onReceive(articleStore.$unreadCount)` → `NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil`, behind a Settings › Notifications toggle "Show unread count on Dock icon" (default on). Clear on quit not needed (Dock resets).
- Menus: ⌘[ ⌘] on Web Back/Forward; ⌃⌘1/⌃⌘2 List/Grid in `ListViewCommands`; "World Tension…" under View; Keyboard Shortcuts window lists every `keyboardShortcut` (build the table from one shared `[ShortcutRow]` constant in `NewsApp.swift` so it cannot drift).
- CI: add `script/format.sh --check` step to `ci.yml` test job, CircleCI `checks` job and `codemagic.yaml`.

### Slices E–K — Finish-pass slices 4–10
Execute as written in `docs/plans/2026-10-23-finish-pass.md` (slices 4, 5, 6, 7, 8, 9, 10 in that order: 4 → 5; 6 after 4; 7 and 8 independent; 9 after 3–8; 10 last, Mars runs harnesses). Slice 2 leftover (`iframe`/`video` → `.embed` at `CEP:710`) goes into slice 4. The agent-verified open-item list above is the checklist; tick each `file:line` as it closes. Slice 9 also deletes whatever `DS` tokens slice C left because they gained callers.

## Order
A → B → C (C after A/B so deletions do not conflict with fixes in FM/DB/ADV) → D → E…K. A, B and D are independent of each other except for the shared `SettingsView`/`NewsApp` files; land them sequentially to avoid conflicts.

## Reuse
`FM.now` injectable clock; `confirmationDialog` pattern `ArticleListView.swift:417`; Subscriptions status helper (#484, `SettingsView.swift:230`); `ArticleStore.markAllAsRead`; `ArticleStore.$unreadCount`; `DB.articleDateOrder`; `ContentExtractionPipeline.decodeHTMLEntities`; `FeedXMLParser.stripHTMLSimple`; `Tests/TestDefaults.swift` `testDefaultsSuite`/`removeTestDefaults`; `DB` BEGIN IMMEDIATE + `defer` rollback pattern for v1.

## Verification
- Every slice: `./test.sh` (includes design lint), `script/format.sh --check`, `./build.sh` into a staging directory (never over the installed app). Background only; no window-opening harnesses (memory).
- Slice A: new deterministic tests — prune throttle and picker, cancelled-refresh carry-over notification, undated Briefing story, JSON item skip, clear-AI scope, `getUserVersion` throw; `./test.sh --story-regressions`.
- Slice B: proxy restart test over the controlled socket fixtures (`./test.sh --transport-cancellation` still passes); notification ID stability test (two launches = same ID string).
- Slice C: `./test.sh` + `script/build_test_runner.sh` + `script/native_performance_baseline.sh --help`-level syntax check compile; grep each deleted symbol repo-wide = 0.
- Slice D: shortcut table test (every `keyboardShortcut` in `NewsApp` appears in the window); CI configs run format check on the PR.
- Slices E–K: per the finish-pass plan's verification list; slice 10 by Mars.
- Not covered: macOS 15/26 runtime, live VoiceOver (#268 parked), real sleep/wake (fix 3 is tested by calling `cancelRefresh` directly).

## Outcomes — 24 October 2026

Every slice is open for review as a pull request; all were built, tested (`./test.sh` via the pre-commit hook), formatted and staged-built. Mars runs the appearance harnesses (finish-pass slice 10) once the stack lands.

| Slice | PR | Base | Notes |
|---|---|---|---|
| A — storage and refresh correctness | #490 | `main` | retention wired with a Settings › Storage age; cancelled-refresh notifications; undated stories in windows; JSON ids; Clear AI scope; DB errors thrown |
| B — UI and services correctness | #491 | `main` | separate session: update/OPML feedback, reader reset, stable notification ids, gateway restart, DNS off the actor |
| 7 — cards and list | #492 | `main` | separate session |
| C — dead code removal | #493 | A | −865 lines, no behaviour change |
| D — small missing features | #494 | C | Mark All as Read, confirmations, Dock badge, shortcuts, format check in CI |
| 4 — reader block rendering | #495 | D | links, quotes, code, figures, media embeds, reader chrome |
| 5 — citation jump to passage | #496 | 4 | `ReaderPassageMatcher`, scroll and highlight |
| 6 — overview polish | #497 | 5 | inline citation links, reading-style type, shared figure, tokens |
| 8 — sidebar, menus, catalog, settings, tension | #498 | 6 | |
| 9 — tokens and lint ratchet | (this PR) | 8 | adaptive gold/flame, alias cleanup, eight new lint ratchets |

Merge order: #490, #491 and #492 against `main` (independent), then #493 → #494 → #495 → #496 → #497 → #498 → #499 in that order, each retargeted to `main` as its base merges. Codacy's Swift parser reads `Type.init` member references as method starts; two such lines were rewritten as closures (#490, #497).

Left for later, on purpose: the three unreferenced accessibility and calibration scripts stay (audit tooling); `TensionBriefFacts`, `TensionCalibrator` and the `OverviewQualityAuditor` release-gate types stay for the opt-in audits; the VoiceOver override plumbing stays for parked #268; List/Grid keyboard shortcuts (inline `Picker`); `AttributedString` memoization in the reader (no measured cost).
