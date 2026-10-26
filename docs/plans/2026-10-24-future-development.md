# Future development plan — 24 October 2026

Status: approved by Mars on 24 October 2026; issues #534–#577 logged the same day (epics #571–#577, milestones J–P, project board #2). Baseline `origin/main` `cea1e60` (matcher v11, schema v25). Decisions taken by Mars on 24 October while planning: release track = tag + GitHub release only (ad-hoc signed, no notarization); product scope = robustness, performance, logic hardening, model infrastructure, system integration, first run and data; **no** feed-centric sidebar or reading-depth features; matcher decisions **frozen at v11** (no gated matcher change; the private holdout has been read nine times and a fresh one is the precondition if that ever resumes).

## Context

Mars asked for a comprehensive analysis of the app, of the work still landing, and a plan for future development, then to log every planned item on GitHub and project board #2. Three planning cycles (21 Oct state-and-next, 23 Oct finish pass, 24 Oct comprehensive analysis) and two intelligence programs (#501 hardening, #520 unified intelligence) are complete; the defect backlog is empty. Three exploration passes (product surface, engineering health, intelligence pipeline) produced the findings below; the items that drive P0/P1 issues were re-verified in code.

**Landed during planning:** PR #532 (re-lands #529, story-row "Same Event as…") merged as `2334b79`; #520 and #524 closed. **Parked, unchanged:** #264 non-English matching, #268 live VoiceOver. **Board:** 153 Done, 2 In review, 2 Backlog; milestones A–I all closed.

## 1. State of the app (analysis)

**Shipped and green.** Native, local-first reader: FeedKit/SwiftSoup parsing behind a protected loopback gateway; reader v11; EventMatcher v11 (rules + MiniLM rescue/veto + the project's own PairScorer for borderline pairs; holdout precision 1.000 / recall 1.000, authored corpus TP 22 / FP 0); publisher-excerpt overviews with citations, timeline, perspectives, "Earlier in This Story"; Briefing daily edition; muting; notifications with one banner per event; World Tension v2; 65-feed English catalog; retention, Dock badge, full menu/shortcut set. 34.4k lines Swift in `Sources/`, 25.6k in `Tests/`.

**Verified weaknesses (evidence in `path:line`, main checkout):**

Robustness and data safety
- Clustering is not under the energy rule: `FeedManager.swift:577-592` runs `EventClusterer.run` with no `allowsEnergy` check; only warm-up (`:612`), images (`:628`) and enrichment (`:671`) are gated. MiniLM and the pair model run in Low Power Mode, against `IntelligencePolicy.swift:3-4`.
- `EnrichmentQueue.jobs` never shrinks: `EnrichmentQueue.swift:66` stores a full `FeedArticle` per job, `:76` the dictionary; completed jobs are kept (`:119-120`, `:157`); `processNextJobs` re-sorts every job per completion.
- No `quick_check`/`integrity_check`, no `VACUUM`/`auto_vacuum`, no checkpoint at quit anywhere in `Sources` (only a comment at `DatabaseEngine.swift:649`). The file never shrinks after pruning; corruption is undetected.
- Derived rows grow with unread articles forever: `pair_assessments`, `article_features`, `article_embeddings` have no retention; unread stories are never pruned.
- 167 `try?` in `Sources` (46 in `DatabaseEngine.swift`, 34 in `ContentExtractionPipeline.swift`); 9 `@unchecked Sendable` (4 in `NetworkBoundaryProxy.swift`).
- Test harness exits on the first failing assert (`Tests/NewsTests.swift:65-89`); one 18,697-line test file with a hand-maintained `swiftc` file list (`script/build_test_runner.sh:42-112`); CircleCI impact analysis cannot split it. No real-library migration fixture in CI (`NEWS_SNAPSHOT_DB` opt-in only).

Performance
- `SentenceEmbedder.embed` pads to 128 tokens and pools through boxed `NSNumber` subscripts (`SentenceEmbedder.swift:253-257`); `embedBatch` is serial (`:275`). A cold 2,000-article backlog is CPU-heavy and serial.
- `pendingEventMatchRows` takes the oldest 2,000 rows first (`DatabaseEngine+Events.swift:932-946`): after a matcher bump or import the newest stories wait.
- `mergeFragments` compares every pair of active events over 72 h (`EventClustering.swift:392-447`), up to 100×100 pair assessments plus two 256-token model passes per candidate.
- Both models load eagerly in actor init with `.all` compute units (`SentenceEmbedder.swift:198-209`, `:302-318`).

Logic hardening (deterministic layers)
- World Tension fallback uses uncalibrated fixed cue weights (`WorldTension.swift:127-153`); `TensionWeights.calibratedV1` / `TensionHistory.load` (`TensionMethodology.swift:415-660`) exist and have no caller in `Sources`; the `ponytail:` comment at `:153` cites #158, which is closed.
- Notifications: 25 English signal words including generic ones ("president", "announces", "launches") at equal weight (`NotificationService.swift:52-58`); one-banner-per-event is per batch only, so an event notifies again when new members arrive on a later refresh (`FeedManager.swift:476-479`); importance computed twice per article.
- Topic classifier: the Foundation Models stage (`ArticleIntelligence.swift:906-951`) is unreachable (`EnrichmentQueue.swift:290-297` passes `allowFoundationModels: false`); keyword ties and brand words ("apple") are known open misfiles with no labeled sample; no user correction of a category.
- Overviews: perspectives miss unattributed speech (33 events in the live audit; 25 of 55 events reach two perspectives); `OverviewClaimVerifier` controls mismatched 6 of 10 (four wrong claims passed, two valid failed); `recordVerifiedOverview` has no production caller.
- Briefing rank reads a stored `importance` nothing writes any more (`EventFeed.swift:385`): every story is `.notable`. Interest inference (`DatabaseEngine.swift:3070-3085`) is invisible and cannot be reset.
- Reader summary sends text to Foundation Models with no language pre-check (`ArticleIntelligence.swift:994-1051`), relying on an `unsupportedLanguage` refusal.
- Dead decision code in the shipping target: `StoryImportanceJudge`/`OnDeviceImportanceJudge` (ignored `importanceJudge _:` at `FeedManager.swift:86`, `judge: .unavailable` at `:637`), `EventJudge`/`OnDeviceEventJudge` (ignored `judge _:` at `EventClustering.swift:27`), `confirmed`/`rejected`/`needsConfirmation`/`softConflict` remnants, ~90% of `OverviewQualityAuditor.swift` (905 lines; only `auditClaim` is app-reachable from `OverviewComposer.swift:560`), `TensionCalibrator`/`TensionHistory`. Mars's standing decision: keep the opt-in audit tooling; so move it to the test build, do not delete.

Model infrastructure (decisions frozen)
- `pair_assessments.features` is declared (`DatabaseEngine.swift:924`) and never written (`DatabaseEngine+Events.swift:1372-1373`); cosine, model probability and conflict are not stored. Vetoed pairs are not recorded. No UI or CLI reviews pair decisions; "Same Event"/"Not the Same Event" corrections (`event_inclusions`, `event_exclusions`) are never exported for evaluation.
- Both models are English-only, yet semantic rescue and the pair model still run for non-English pairs (rules are near-unreachable there because NLTagger returns `otherWord`); their precision outside English is unmeasured. #264 stays parked.
- Two fp16 models of the same 6-layer family: 43 MB + 43 MB. The MiniLM conversion script (coremltools 6.3, torch 1.13.1) is not in the repository; the pair model's training pins (`script/training/requirements.txt`) are outside Dependabot.

System integration and first run
- `UpdateChecker` automatic path (6 h throttle, `UpdateChecker.swift:104-108`) never runs: both callers pass `userInitiated: true` (`NewsApp.swift:64`, `SettingsView.swift:889`); the endpoint 404s because there are no releases.
- No URL scheme (`build.sh:118-146` plist has no `CFBundleURLTypes`), no `onOpenURL`; "Subscribe in News" from other apps is impossible. No App Intents, Spotlight, notification actions, menu bar item, launch at login.
- No onboarding: notification permission is requested at launch (`NewsApp.swift:301`) before any story is shown; the catalog is reachable only through Settings.
- No export of saved stories or history, no library backup/restore (Storage tab shows "Active" with no actions, `SettingsView.swift:754-759`), no diagnostics export (no `OSLogStore`, no "Export Logs").

Release and engineering hygiene
- 0 tags, 0 releases; `2.0.0` hard-coded in `build.sh:138` and `build_release.sh:144` with `CFBundleVersion` 3 vs 1; nothing derives from git. A user installs by building from source or by downloading an expiring CI artifact and bypassing Gatekeeper.
- CircleCI `checks` runs `script/format.sh --check` on `cimg/python:3.13`, where `format.sh:15-18` prints "Skipping format" and exits 0; its eval loop omits `fit_pair_head.py`. No SwiftPM caching in any of the three CI systems; the GitHub test job's 15-minute timeout is close to observed 8–18 minute runs. Codemagic duplicates GitHub Actions.
- Docs drift: `README.md:10` "EventMatcher v7", `:8` "18 October", `:26` "38 feeds verified 1 October" (code: v11, 65 catalog entries verified 2026-10-08, `FeedCatalog.swift:78,152`); `ARCHITECTURE.md:54` "SQLite v24" (v25), `:134` `build_release.sh` "dormant" (runs in every CI); `CONTRIBUTING.md:121` points to closed #90. OSLog has duplicate categories (`Database`/`DatabaseEngine`, `Feeds`/`FeedManager`/`FeedFetcher`, `Launch` twice).

**Not in this plan (by decision):** feed folders / feed list in the sidebar, autodiscovery, translation, find in page, multiple windows, print; notarization, DMG, Sparkle, Intel; gated matcher changes and the fresh holdout; #264, #268; macOS 15/26 runtime checks; new dependencies.

## 2. Plan — programs and issues

The original seven programs (J–P) each have a GitHub epic with sub-issues and a milestone. **Program S was added on 25 October 2026 as a separately parked, future-facing Epic**; it is not a release gate. **Program T was added on 26 October 2026 and is blocked by M and L.** Every implementation issue lands as one PR with `./test.sh`, `script/format.sh --check`, a staged `./build.sh`, a CHANGELOG line and board move; UI PRs carry the DESIGN.md checklist. No AI attribution lines in commits or PRs. Effort S < 1 day, M 1–3 days, L > 3 days.

### J · Robustness and data safety (epic #571, milestone J)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| J1 (#534) | Clustering under the energy rule | `FeedManager.clusterEventsInBackground` and `EventClusterer.run` consult `IntelligencePolicy.allowsEnergy`; when false, skip `SentenceEmbedder`/`PairScorer` and run rules only (pairs stay `borderline`, re-assessed on the next allowed pass). | Authored corpus ratchet unchanged (TP ≥ 22 / FP 0) in both modes; unit test with a stubbed policy. | S | P1 |
| J2 (#535) | Bound `EnrichmentQueue.jobs` | Drop completed jobs; keep a `Set<String>` of done IDs; stop sorting all jobs per completion (priority heap or sorted insert). | Memory flat over 10 refreshes on the 10,000-story seeded library (`--seed-launch-library`, `--performance-baseline`). | S | P1 |
| J3 (#536) | Database health: check, checkpoint, compact | `PRAGMA quick_check` on open (log + Settings › Storage notice on failure); `PRAGMA optimize` and `wal_checkpoint(TRUNCATE)` at termination; `auto_vacuum=INCREMENTAL` set by migration v26 + `incremental_vacuum` after the daily prune; Storage tab shows library size (`ByteCountFormatter`). | Migration v25→v26 test; prune test shows file shrink; a corrupted fixture surfaces the notice. | M | P1 |
| J4 (#537) | Retention for derived intelligence rows | Daily prune also deletes `pair_assessments` older than 30 days and `article_features`/`article_embeddings` of articles outside the 72 h active window and not in a stored event; recomputed on demand (already the behaviour for missing rows). | Test: rows for a 40-day-old singleton go, rows for an active event member stay; clustering of a pruned article recomputes. | S | P2 |
| J5 (#538) | `try?` audit in storage and extraction | Classify each `try?` in `DatabaseEngine*.swift` and `ContentExtractionPipeline.swift`: keep (truly optional), or log through one `Logger` helper with the operation name; no behaviour change besides logging. | Count of silent `try?` in those files halves; list in the PR. | M | P2 |
| J6 (#539) | Real-library migration fixture in CI | Commit a sanitized small SQLite fixture (titles replaced, 200 rows, oldest supported version) under `Tests/Fixtures`; CI runs the ladder to current, `quick_check`, and the existing `NEWS_SNAPSHOT_DB` assertions. | Test runs in `./test.sh` without env vars. | S | P2 |

### K · Performance (epic #572, milestone K)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| K1 (#540) | Embedding throughput | Pointer-based `MLMultiArray` pooling, batched inputs, no `NSNumber` subscripts; keep tokenizer and pooling semantics. | Vectors identical (cosine ≥ 0.9999 vs current on the authored corpus); cold 2,000-article pass ≥ 3× faster in `--performance-baseline`; benchmark JSON in `docs/benchmarks`. | M | P1 |
| K2 (#541) | Clustering backlog order and fragment-merge pruning | `pendingEventMatchRows` newest-first; `mergeFragments` indexes active events by shared specific anchor before pairwise assessment. | Same memberships on the authored corpus and private tune replay (TP/FP unchanged); fragment-merge time measured before/after. | M | P1 |
| K3 (#542) | Lazy model loading | Load MiniLM and PairScorer on first use, not at actor init; cold launch does not touch CoreML. | Launch baseline (`script/launch_baseline.sh`) first-card time not worse; models load within the first clustering pass. | S | P2 |
| K4 (#543) | Re-baseline performance budgets | After J1–K3: `--performance-baseline`, launch and full-app workload on the seeded library; update `docs/audits` and budgets. | Dated audit + JSON; budgets in ARCHITECTURE updated. | S | P2 |

### L · Logic hardening, deterministic layers (epic #573, milestone L)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| L1 (#544) | Calibrated World Tension fallback | `estimate` uses `TensionWeights.calibratedV1` via `TensionHistory`; delete the stale `ponytail:` comment and uncalibrated table. | `script/test_tension_calibration.sh` / `calibrate_tension.py` reproduce the documented bands on `historical-sample.json`; `NativeWorldTensionQA` unchanged. | S | P1 |
| L2 (#545) | Notification signals and cross-refresh dedupe | Weight generic signal words lower; persist `notified_at` per event (schema v26 shared with J3) so new members of an already-notified event do not re-notify within 24 h unless the headline changes; compute importance once per article. | `testNotificationModeTriageAndGrammar` extended; dedupe test across two refreshes. | S | P2 |
| L3 (#546) | Topic classifier: measured misfiles | Delete the unreachable Foundation Models stage; Mars labels a 200-story category sample from a library copy (local, `--export-categories` flag); fix the top misfile classes (brand words, ties) with whole-word rules. | Accuracy on the sample reported before/after; `testCanonicalClassificationDisambiguation` extended. | M | P2 |
| L4 (#547) | Perspectives and claim verifier | Widen speech-attribution patterns (reported speech without quotation marks, "according to", "said in a statement"); fix the 6 of 10 verifier control mismatches; wire `OverviewClaimVerifier` into `recordEventOverview` or delete `recordVerifiedOverview`. | ≥ 60% of multi-source events with two or more perspectives on the `--overviews-live` library copy (from 45%); all 10 controls match; independent 30-claim sample with 0 critical errors. | M | P1 |
| L5 (#548) | Briefing rank and interests | Drop the always-`.notable` importance factor; Settings › Reading shows the inferred interest categories with "Reset Reading Interests". | Briefing test unchanged except the removed factor; reset test. | S | P2 |
| L6 (#549) | Remove dead decision code; move audit tooling to the test build | Delete `StoryImportanceJudge`/`OnDeviceImportanceJudge`, `EventJudge`/`OnDeviceEventJudge`, ignored `judge` parameters, `confirmed`/`rejected`/`needsConfirmation`/`softConflict`, the FM classifier stage. Move `OverviewQualityAuditor` (except `auditClaim`), `TensionCalibrator`, `TensionHistory` into `Tests/` (kept, per Mars). | `./test.sh` green; `--overviews-live` and tension calibration still run; grep of deleted symbols = 0; binary smaller. | M | P1 |
| L7 (#550) | Reader summary language pre-check | `NLLanguageRecognizer` before the Foundation Models call; non-English → final extractive summary without a model call; bump analysis version for provisional rows only. | Test: German fixture never calls the model; English path unchanged. | S | P2 |

### M · Model infrastructure, decisions frozen at v11 (epic #574, milestone M)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| M1 (#551) | Complete and reviewable pair decisions | Write cosine, model probability and conflict name into `pair_assessments.features` (JSON); record vetoed pairs with their conflict; `--review-pairs` runner flag exports a library copy's rows joined with `event_inclusions`/`event_exclusions` to CSV; adjudication protocol documented. | Mars adjudicates 200 sampled `match` rows and 100 `pairModel` rows locally: false merges ≤ 2%, numbers in a dated audit. | M | P1 |
| M2 (#552) | User corrections as a regression set | `--export-corrections` writes inclusion/exclusion pairs (ids, titles) from a library copy; the private replay accepts them as hard positives/negatives. | Gate for any future matcher or model change: no recorded exclusion re-merges; documented in CONTRIBUTING. | S | P1 |
| M3 (#553) | Non-English gating of neural paths | When either article's `EventMatchKey.language` ≠ `en`, skip semantic rescue and the pair model (rules only). Keeps #264 parked and honest. | Authored corpus unchanged; unit test with a French pair never calls the embedder. | S | P1 |
| M4 (#554) | Model size | int8 palettization of both `.mlmodelc` with coremltools (or one shared trunk); decisions must be identical. | Tune replay identical (44 / 0 at cutoff 0.9), authored corpus identical, pair-model `--check-shipped` within 0.01; bundle 86 MB → ≤ 30 MB. Holdout **not** read. | M | P2 |
| M5 (#555) | Reproducible models and pins | Add the MiniLM conversion script to `script/training`, extend `--check-shipped` to MiniLM, add pip to `dependabot.yml`, record versions in `metadata.json`. | Re-export reproduces both shipped models (largest diff ≤ 0.001). | S | P2 |

### N · System integration (epic #575, milestone N)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| N1 (#556) | Automatic update check | Run the throttled path at launch and on foreground (6 h); result shown as a Settings › Updates notice and a Help menu badge, never a modal. | Test of throttle with injected clock; works against the release from P2. | S | P1 (after P2) |
| N2 (#557) | URL scheme: `feed://` and `news://` | `CFBundleURLTypes` in the generated plist (`build.sh`, `build_release.sh`); `onOpenURL`: `feed://`/`feed:https://` → Add Feed flow with confirmation; `news://story/<id>` → open story (used by N4). | Test of URL parsing; manual `open "feed://…"` recorded in the PR. | S | P1 |
| N3 (#558) | App Intents and Shortcuts | Intents: Refresh Feeds, Add Feed (URL), Open Section (Today/Unread/Briefing/Saved), Mark All as Read, New Briefing; `AppShortcutsProvider` phrases. | Intents compile and run from Shortcuts; listed in README. | M | P2 |
| N4 (#559) | Spotlight indexing of saved stories | `CSSearchableItem` per saved story (title, publisher, summary, date), removed on unsave; opens via `news://story/<id>`. Privacy: saved stories only, local index. | Save → item exists; unsave → gone (CoreSpotlight test API); PRIVACY.md sentence. | M | P2 |
| N5 (#560) | Notification actions | `UNNotificationCategory` with Save, Mark as Read, Open; handled in `NewsApp` delegate. | Test of the action routing; recorded manual check. | S | P2 |
| N6 (#561) | Menu bar unread item | Optional `MenuBarExtra` (Settings › Notifications) with unread count, Refresh, Open News; off by default. | Toggle persists; count matches Dock badge source. | S | P2 |

### O · First run and data (epic #576, milestone O)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| O1 (#562) | Onboarding and permission timing | First-launch sheet: pick catalog sets (reuse `FeedCatalogView`), choose sections; notification permission requested after the first refresh delivers stories, not at launch; AI toggle explained. | `firstLaunchCompleted` setting; tests for the deferred permission request; DESIGN checklist. | M | P1 |
| O2 (#563) | Library backup and restore | Settings › Storage: "Back Up Library…" (`sqlite3_backup` to a chosen `.sqlite3`), "Restore from Backup…" (quick_check the file, swap, relaunch). | Round-trip test on a fixture; restore refuses a failing `quick_check`. | M | P1 |
| O3 (#564) | Diagnostics export | Help › Export Diagnostics…: last 24 h of `OSLogStore` for the subsystem, app version, schema version, settings summary, feed health; no story text or URLs beyond hosts. Also dedupe OSLog categories. | Zip produced; privacy review in PRIVACY.md; test of the redaction. | S | P1 |
| O4 (#565) | Export saved stories and history | File › Export Saved Stories… / History… as JSON and Markdown (title, publisher, URL, date, saved/read time). | Test of both formats; UTF-8 BOM-free. | S | P2 |

### P · Release and engineering hygiene (epic #577, milestone P)

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| P1 (#566) | Version from git | `build.sh`/`build_release.sh` set `CFBundleShortVersionString` from `git describe --tags --abbrev=0` (fallback `0.0.0-dev`) and `CFBundleVersion` from commit count; `UpdateChecker` fallback aligned; README build section. | Both scripts agree; a tagged checkout reports its tag in Settings › Updates. | S | P0 |
| P2 (#567) | First GitHub release (2.0.0) | Cut CHANGELOG "Unreleased" → "2.0.0 — <date>"; `release.yml` on tag push builds the arm64 zip + sha256 and publishes a GitHub release with install notes (ad-hoc signed: right-click Open / `xattr`), privacy and scope statements. Mars pushes the tag. | Release visible; `UpdateChecker` returns "up to date" on a 2.0.0 build. | M | P0 |
| P3 (#568) | CI consolidation | `format.sh --check` fails (not skips) when `CI` is set and no toolchain; CircleCI eval loop adds `fit_pair_head.py`; SwiftPM cache on GitHub Actions; test job timeout 25 min; Codemagic made manual-dispatch only (one hosted pipeline of record: GitHub Actions; CircleCI kept for impact analysis). *Reversed 26 Oct: all three providers keep push and pull-request triggers.* | Green on all; minutes per run recorded before/after. | S | P1 |
| P4 (#569) | Docs truth | README (v11, current date, 65 feeds verified 8 Oct, release/install section), ARCHITECTURE (v25, `build_release.sh` role, energy rule covers clustering after J1), CONTRIBUTING (program issue → the new epics; board conventions), PRIVACY (Spotlight/diagnostics after N4/O3). | Each drift line in section 1 closed; link check. | S | P1 |
| P5 (#570) | Test harness and suite split | Asserts record failures and continue; summary with per-test timing and non-zero exit at the end; `Tests/NewsTests.swift` split into atoms by existing suite groups (storage, parsing, matching, overview, UI logic); `build_test_runner.sh` file list from globs; CircleCI `test-suites.yml` lists the new atoms. | Same test count runs; a deliberately failing test no longer hides later tests; CircleCI impact analysis selects by atom. | L | P1 |

### S · App Store monetization via StoreKit 2 (epic #651, milestone S, **PARKED**; added 25 October 2026)

**Intentional deferral:** this was approved for a future App Store distribution phase, not for current implementation. Keep #651 and #652–#656 in Backlog with the `parked` label, Priority P2 / low, no cycle and no due date. Do not move any item to Ready or In progress until Mars explicitly reopens this Epic.

**Product decision:** use Apple's StoreKit 2. Offer auto-renewable subscription product(s), initially monthly and annual, with Apple's seven-day introductory free-trial offer for eligible new subscribers, plus a separate non-consumable lifetime purchase. The seven-day trial starts when an eligible user selects and approves the subscription purchase, then automatically renews into the paid subscription unless canceled; it is not unrestricted app access for seven days before choosing a plan. Lifetime is a separate one-time purchase without a trial.

| # | Issue | Scope | Acceptance | Priority |
|---|---|---|---|---|
| S1 (#652) | Define premium feature matrix and App Store product catalog | Decide free/premium boundaries, product IDs/types, introductory offer, pricing approach and localization | Decisions approved before code gates or final product setup | P2 |
| S2 (#653) | Implement native StoreKit 2 commerce service | Product loading, purchases, transaction verification/updates, subscription status and restore | No access granted from unverified transactions; lifecycle paths tested | P2 |
| S3 (#654) | Entitlement manager and premium feature gates | One access-control source of truth for subscriptions/lifetime; expiry and revocation | Entitlements are correct across relaunch/update/refund; user library data is never deleted at expiry | P2 |
| S4 (#655) | Native paywall and purchase settings | Localized prices, seven-day offer and renewal disclosures, lifetime option, restore/manage subscription | Native purchase flow and recoverable states pass accessibility and UI checks | P2 |
| S5 (#656) | App Store Connect setup and purchase lifecycle QA | Product setup, metadata, TestFlight purchase testing and distribution signing | StoreKit/TestFlight matrix passes; App Store submission checklist complete | P2 |

**Architecture boundaries**
- Keep SwiftUI, SQLite and on-device intelligence local-first. No WorkOS, RevenueCat, accounts, cloud AI, telemetry or billing backend solely for purchases.
- StoreKit transactions and current entitlements are the source of truth. Never trust a local `isPremium` Boolean alone.
- Premium expiry may gate only the approved premium features. It must never delete feeds, saved stories, reading history, cached article content or preferences.
- App Store distribution signing is a separate future release step; leave the current ad-hoc verification workflow unchanged while parked.

**Board setup checklist**
- [x] Create milestone S (Q and R were already taken by #607 and #608).
- [x] Add #651–#656 to GitHub Project #2.
- [x] Set Status = Backlog and Priority = P2 for every card; keep the `parked` label.

### T · Story Overview and editorial UX (epic #669, milestone T, **BLOCKED** by M #574 and L #573; added 26 October 2026)

**Dependency:** #669 is blocked by #574 (M · Matching: story-level grouping and measured matcher iteration) and #573 (L · Logic hardening of the deterministic layers), recorded as GitHub issue dependencies. M's story layer (#581) changes what an overview and its timeline span; L owns the `Overview*` logic and perspective attribution (#547). Planning only: no implementation PRs, and every card stays in Backlog until both epics are closed.

| # | Issue | Scope | Acceptance | Effort | Pri |
|---|---|---|---|---|---|
| T1 (#670) | Conditional Industry Impact section | Named industries and practical implications, each cited; shown only when a cited passage states the effect; whole section omitted otherwise; fixed industry list; model drafts pass `OverviewClaimVerifier`. | No section on no-impact fixtures; cited entries on impact fixtures; no repeat of introduction or highlights; 30-event library check with 0 unsupported implications. | L | P2 |
| T2 (#671) | Connected timeline of events | Continuous spine, distinct markers (past, planned, publication-only) by shape plus text, dates and descriptions with citations; native timeline tokens; date above description at 900 pt. | Spine unbroken at 900 pt/wide and text 1.0/1.3; sort-order and missing-data tests; grayscale-distinguishable states; VoiceOver row order. | M | P2 |
| T3 (#672) | Highlight separation and hierarchy | One marker and row per takeaway (replaces publisher stacking), subordinate context line, larger gap between than within highlights, no per-item cards. | One takeaway per row (test); gap ratio ≥ 2 from tokens; unknown-publisher fallback; VoiceOver one element per highlight. | S | P2 |
| T4 (#673) | Distinct Perspectives design | Own visual identity; participant first, position second, publisher attribution secondary; positions framed as attributed, never as fact; no false balance or placeholders. | Distinct in captures (Mars approves); empty-participant positions hidden; no highlight/perspective duplicate; one-perspective fixture shows no "other side". | M | P2 |

Shared acceptance for all four (in #669): sections absent without valid data, stated missing-data fallbacks, citations on every line, DESIGN.md §16 accessibility and §9 contrast, 900 pt and wide layouts at text sizes 1.0 and 1.3, tokens and existing components only, DESIGN.md §9/§17 rule per change approved by Mars, appearance-matrix captures. File ownership: overview section code in `EventOverviewReaderView.swift` (hand-off from Q #607), a new `OverviewIndustryImpactExtractor.swift`, the industry-impact field and composition step (after L closes).

**Board setup checklist**
- [x] Create milestone T.
- [x] Create #669 with sub-issues #670–#673 and record the blocked-by dependencies on #574 and #573.
- [x] Add #669–#673 to GitHub Project #2 with Status = Backlog and Priority = P2.

## 3. Order

1. **Release first:** P1 → P2 (unblocks N1), P4 alongside.
2. **Robustness core:** J1, J2, L1, M3, L6 (small, independent; L6 before M-work so deletions do not conflict).
3. **Data and review:** J3 (+ L2's `notified_at` in the same v26 migration), K1, K2, M1, M2, L4, O3, N1, N2.
4. **Hygiene:** P3, P5, J5, J6, L3, L5, L7, O1, O2.
5. **Later:** M4, M5, N3–N6, O4, K3, K4, J4.

Shared files to land sequentially: `FeedManager.swift` (J1, J2, L2, N1), `DatabaseEngine*.swift` (J3, J4, L2, M1), `SettingsView.swift` (J3, L5, N6, O2), `NewsApp.swift` (N1, N2, N5, O3), `build.sh` (P1, N2).

## 4. Logged on GitHub and the board (24 October 2026)

Repository `marspater/NewsApp-macOS`; project #2 (`PVT_kwHOBD2v1c4BlQOO`), Status field `PVTSSF_lAHOBD2v1c4BlQOOzhj9ydM` (Backlog `cb33648f`, Ready `f75ad846`), Priority field `PVTSSF_lAHOBD2v1c4BlQOOzhkBRf0` (P0 `1746bd17`, P1 `c20e2062`, P2 `fdf83768`).

1. Create milestones J–P (`gh api repos/:owner/:repo/milestones -f title=…`), titles as in section 2.
2. Create seven epic issues (label `epic` + area labels), body = the program's table and order, "Part of the 24 October future development plan (`docs/plans/2026-10-24-future-development.md`)".
3. Create each sub-issue with the row's scope and acceptance as checklists (plain English, no caveman), labels from the existing set (`enhancement`/`bug`, `area: *`, `ai`, `area: performance`, `area: testing`), milestone, and link it as a sub-issue of its epic (GraphQL `addSubIssue`).
4. Add every issue to project #2 (`gh project item-add 2 --owner marspater --url …`), set Status Backlog (Ready for P0/P1 of phase 1: P1, P2, P4, J1, J2, L1, M3, L6) and Priority per the table (`gh project item-edit`).
5. Commit this plan as `docs/plans/2026-10-24-future-development.md` on a branch and open a docs PR; update CONTRIBUTING's program pointer in P4, not here.
6. Record a memory: distribution decision (tag + release, no notarization), matcher frozen at v11, excluded product themes.


## 5. Verification

- Plan docs: `docs/plans/2026-10-24-future-development.md` renders; every issue number recorded in its row once created.
- GitHub: `gh issue list --state open` shows 7 epics + 37 sub-issues with milestones; `gh project item-list 2` shows each with Status and Priority; each epic's sub-issue progress bar shows its children.
- Per-issue verification is the acceptance column; performance and intelligence items carry their measured gates and never read the private holdout.
