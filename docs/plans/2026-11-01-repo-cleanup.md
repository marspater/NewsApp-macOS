# Repository cleanup pass — 1 November 2026

Part of #744. A read-only survey of the checkout after the 2.0.0 release, what was removed, what waits for a
decision, the docs, script and test inventory, the test timing report, a sub-folder proposal for `Sources/`, and
where the on-device models live. Everything removed in this pass is either a build product, an ignored file, or
a worktree whose pull request is merged; every other candidate is listed with a reason and left in place.

## 1. Build products and leftovers

Removed (all ignored by `.gitignore` already, so nothing changed there):

- `News.app` (112 MB) and `News Dev.app` (112 MB): `./build.sh` output and the throwaway dev bundle
  (`com.marspater.news.dev`) built on 1 November. `/Applications/News.app` was not touched.
- `.build` (556 MB): SwiftPM scratch, rebuilt by `swift build` and the CI caches.
- Every `.DS_Store` under the checkout, including inside the remaining worktrees.
- 13 worktrees under `.claude/worktrees` whose pull requests are merged and whose trees were clean, with their
  branches: `fix/796-feed-dates-fields` (#834), `fix/782-today-counts` (#831), `briefing/847-design-docs` (#852),
  `fix/780-briefing-board` (#835), `fix/library-migration-backup` (#751), `fix/791-story-order` (#838),
  `claude/event-holdout-audit` (#265), `eval/story-country-737` (#768), `docs/carry-in-738` (#766),
  `fix/notify-once-per-story` (#763), `docs/replay-calibration-accepted` (#760),
  `fix/matcher-v14-storms-roundups` (#761), `fix/matcher-v15-headline-places` (#773). About 1.2 GB.

No `.orig`, `.bak`, `.tmp`, `.rej` or editor backup files exist. `git status --ignored` shows only
`.antigravity/`, `.codacy/`, `.swiftpm/`, `.claude/settings.local.json` and `all state of
local tools.

### Second pass, after my review (same day)

Every remaining worktree and branch was reviewed: a branch whose pull request is merged or closed is stale (its
work is on `main` as a squash); a branch with no pull request was checked for commits not on `main`, whether it
still merges, and whether the work landed through another branch. Result:

- Removed the other 20 worktrees: the 9 left under `.claude/worktrees`, the 5 scratchpad worktrees of another
  session, 5 Antigravity worktrees and `.antigravity/worktrees/voiceover-qa`. The two dirty ones held only agent
  state (`.claude/`) and two plan drafts already on `main` or superseded by `2026-10-30-v2-completion.md`.
- Deleted 179 local branches (33 merged by ancestry, 146 superseded) and 45 remote branches whose pull requests
  were merged or closed, plus 403 stale `refs/remotes/pr/*` refs left by a removed remote. `main` and this PR's
  branch are what remain, locally and on GitHub.
- The one branch with work not on `main` that is still wanted, `claude/event-feature-fallback` (plain-word event
  matching for languages without a word-class model, parked with the English-only release scope), no longer
  merges after the Epic M matcher rewrite; its diff and commit message are logged on #264 before deletion. The
  other no-PR branches (`agent-pr705`, `m-540-lint`, `m-581-story-layer-fix`, `mars/m-integrated-2026-10-29`,
  `m-review-scripts`, `pr729`, `fix_codacy_issues_pr705`, `l-546-work`, `scratch/l-549-importance-judge`,
  `fix/737-story-recall`, `docs-847-rebase`, `fix-780-local`, `fix/808-network-boundary`, integration and tmp
  branches) were integration or review copies of Epic L, M, T and the v2 bug pass, all shipped through their
  stack PRs; each conflicted with `main` and added nothing that is not there.
- Cleared the Swift module cache, the test pass stamps and the News test leftovers under `$TMPDIR`.
- Deleted `Sources/News.docc` (approved).

## 2. `CHANGELOG.d` → `changelog/pending`

`CHANGELOG.d/` is the pending-changelog mechanism, not a leftover: each PR adds one fragment file there instead of
editing `CHANGELOG.md`, so parallel and stacked PRs never conflict on the changelog. Before a tag,
`python3 script/changelog_fold.py` moves the fragments under `## Unreleased` and deletes them (#894 did that for
2.0.0). The two files were `README.md` (the convention) and `839-list-rerender.md` (#884, merged after the fold,
so it is pending for the next release, not consumed).

The fold script needs the directory, so it is renamed to `changelog/pending/`, which says what it holds. Updated:
`script/changelog_fold.py`, `changelog/pending/README.md`, `AGENTS.md`, `CONTRIBUTING.md`,
`docs/RELEASE_CHECKLIST.md`. The fold script also gained the blank line it was missing between the folded bullets
and the next release heading (`--dry-run` showed `## 2.0.0` glued to the last bullet).

## 3. `docs/`

Policy, from `CONTRIBUTING.md`: dated evidence belongs in `docs/audits/`, so an audit is a record even when
nothing links it. CI ignores `docs/**`, so the folder costs nothing in build time. Recommendation: keep the audits
and the methodology notes, keep every plan `CONTRIBUTING.md`, `README.md` or `docs/ARCHITECTURE.md` links, and
decide on the six items below. The full table of every file, its last commit and what references it is at the end
of this document (section 8).

| Candidate | Reason | Suggested action |
|---|---|---|
| `docs/audits/SONAR_REVIEW.md` | the only undated audit name; a 30 September backlog review superseded by `2026-10-09-sonar-slices.md`; nothing links it | renamed to `2026-09-30-sonar-review.md` (audits stay by policy) |
| `docs/benchmarks/2026-10-10-overview-bounded-comparison-receipt.json`, `…-overview-bounded-comparison.json` | the audit of the same name cites neither file by name | delete, or cite them from the audit |
| `docs/benchmarks/2026-10-17-release-core.json` | cited only by `docs/plans/2026-10-17-release-simplification.md` | keep (a plan cites it) |
| `docs/benchmarks/2026-10-25-embedding-throughput.json` | nothing cites it; the throughput numbers are in `CHANGELOG.md` and the Epic M verification audit | delete, or cite it from `2026-10-30-epic-m-verification.md` |
| `docs/plans/2026-10-21-state-and-next-development.md`, `2026-10-28-board-status-and-projections.md`, `2026-10-31-v2-release-gate.md` | plans nothing links; the work they planned is merged (v2 shipped 31 October) | deleted (approved) |
| the other ten plans (`2026-09-30-story-experience.md` … `2026-10-31-adr-001-strengthen-the-platform.md`) | each is linked from `README.md`, `CONTRIBUTING.md`, `docs/DESIGN.md`, `docs/ARCHITECTURE.md`, `docs/RELEASE_CHECKLIST.md`, `.claude/agents/forensic.md` or another plan | keep |

Everything else in `docs/` is linked: `ARCHITECTURE.md`, `DESIGN.md`, `RELEASE_CHECKLIST.md`,
`XCODE_AND_APP_REVIEW.md` and `notifications.md` from the top-level docs and from code comments; the methodology
notes from `TensionMethodology.swift`, `calibrate_tension.py` and `ARCHITECTURE.md`; the briefing mock from
`DESIGN.md`; 27 of the 32 benchmark files from their audits.

## 4. `script/` and `Tests/`

### Scripts

| Script | Run by |
|---|---|
| `app_intents_metadata.sh`, `swiftpm_dependencies.sh`, `version.sh` | sourced by `build.sh`, `build_release.sh` and every harness script |
| `build_test_runner.sh`, `ci_testsuite.sh`, `test_ci_testsuite.sh` | `test.sh`; CircleCI `checks` and `test-macos` (`.circleci/test-suites.yml`) |
| `design_lint.sh` (+ `design_lint_baseline.txt`) | `test.sh`, CircleCI `checks` |
| `format.sh` | pre-commit hook, GitHub Actions `build-arm64`, Codemagic |
| `changelog_fold.py` | release checklist, by hand before a tag |
| `test_event_overview_accessibility.sh`, `test_reader_accessibility.sh`, `test_tension_calibration.sh` | CircleCI `test-macos` (standalone binaries); `test.sh` runs the same suites inside the shared runner |
| `native_performance_baseline.sh` | all three CI providers with `NEWS_NATIVE_HARNESS=Tests/PublisherExcerptTests.swift`; by hand for the other harnesses |
| `evaluation/{evaluate, publisher_review, publisher_dates, overview_review, importance_review, relation_review, catalog_review, fit_pair_head, calibrate_tension}.py` | `test.sh` self-checks; CircleCI `checks` (all but `calibrate_tension`) |
| `training/pretrain_pairs.py` (`--self-check`) | `test.sh` |
| `training/{train_pair_model, train_embedding, convert_minilm, compress_models}.py`, `wordpiece.py`, `requirements.txt` | by hand on my Mac only (the four training scripts' docstrings say "My Mac only, never CI"); `wordpiece.py` is the tokenizer the other three import and `requirements.txt` their virtual environment |
| `evaluation/sample_pairs.py`, `evaluation/build_corpus.py` | by hand (`CONTRIBUTING.md`; the story-corpus fixture README) |
| `build_and_run.sh` | `make run`, `README.md` |
| `distribution/{notarize, package_dmg}.sh` | by hand at release; `NewsTests.swift` checks their text |
| `appearance_matrix.sh`, `launch_baseline.sh`, `run_isolated.sh`, `test_native_ui_qa.sh`, `test_notification_live.sh`, `test_voiceover_live_qa.sh` | by hand only (`CONTRIBUTING.md`); these open windows or need Screen Recording, so no CI job runs them |

Nothing in `script/` is unreferenced. The six window-opening scripts are the live QA set that the English-only
release scope parked (5 October); they stay documented as manual.

### Test files

| File | Run by |
|---|---|
| `NewsTests.swift` | `test.sh`: `NEWS_TEST_SHARDS` shard processes plus the slow shard; CircleCI test atom |
| `EventEmbeddingTests.swift`, `EpicNE2ETests.swift`, `StoryCorpus.swift`, `ImportanceAudit.swift`, `OverviewQualityAudit.swift` | compiled into the runner: `EventEmbeddingTests` extends `NewsTests` with its tests, `EpicNE2ETests` is called from `NewsTests`, and `StoryCorpus`, `ImportanceAudit` (`OnDeviceImportanceJudge`) and `OverviewQualityAudit` are helpers those tests use |
| `FeedKitSwiftSoupTests.swift`, `NotificationAttachmentTests.swift`, `BriefingE2ETests.swift`, `BriefingWarRoomTests.swift`, `BriefingIntelligenceTests.swift`, `BriefingImpactTests.swift`, `BriefingSignalsTests.swift`, `AnalysisGenerationTests.swift` | `test.sh`, one job each (the runner's `selected(...)` list) |
| `EventOverviewAccessibilityTests.swift`, `ReaderAccessibilityTests.swift`, `TensionCalibrationTests.swift` | `test.sh` jobs inside the runner, and the three standalone CircleCI scripts |
| `TensionCalibrationRunner.swift` | `script/test_tension_calibration.sh` only (the `@main` of the standalone binary) |
| `PublisherExcerptTests.swift` | all three CI providers through `native_performance_baseline.sh` |
| `TestDefaults.swift` | every runner and harness |
| `NativePerformanceBaseline.swift`, `NativeReadingMemory.swift`, `NativeWorldTensionQA.swift`, `OverviewCaptures.swift`, `ListInvalidationBaseline.swift` | by hand: `NEWS_NATIVE_HARNESS=… script/native_performance_baseline.sh` (`CONTRIBUTING.md`) |
| `NativeUIQAChecks.swift`, `NativeNotificationQA.swift`, `NativeAppearanceMatrix.swift`, `LiveVoiceOverQAHarness.swift` | by hand: the live scripts above; never in CI |

Never run automatically: the nine files in the last two rows. They are the on-device baselines and the live QA
harnesses; each is documented in `CONTRIBUTING.md`, so none is dead. Fixtures: every file under `Tests/Fixtures`
is read by a test, an evaluation script or the fixture README (the `.sha256` files are the README's checksums).

## 5. Test timing

Measured on this Mac (10 cores, `NEWS_TEST_FORCE=1 NEWS_TEST_TIMING=1 ./test.sh`, 172 timed tests in
`NewsTests.swift`, 16 jobs, 6 at a time):

| Phase | Wall time |
|---|---|
| `script/build_test_runner.sh` (one `swiftc` over ~115 files, 112 s of CPU) | 42 s |
| Job pool, bounded by `NewsTests-slow` | 20 s |
| `NewsTests-0..3-of-4` | 12, 11, 9, 10 s |
| Every other job (`BriefingSignalsTests`, `BriefingWarRoomTests`, `FeedKitSwiftSoupTests`, `NotificationAttachmentTests` 3 s; the rest 1–2 s) | ≤ 3 s |

The ten slowest tests (sum of all 172: 53.8 s):

| Test | Seconds | Where the time goes |
|---|---|---|
| `testActiveWorkCancellation` | 18.70 | writes 20,000 rows and waits for SQLite's page cache to spill to the WAL before cancelling |
| `testDiagnosticsExport` | 4.91 | zips the export twice with `NSFileCoordinator` (`.forUploading`), lists it with `/usr/bin/unzip`, polls at 100 ms |
| `testEventCorpusHarness` | 3.01 | parses `corpus-v1.json` and embeds it with the Core ML encoder |
| `testOverviewPublisherEvidence` | 2.47 | real-time deadlines (300 ms, 4 s) and delayed replies |
| `testEventEmbeddingIntegration` | 1.87 | loads the encoder and the pair model |
| `testRealLibraryMigrationFixture` | 1.79 | copies and migrates `legacy-library-v14.sqlite3` (the file is the point) |
| `testAppIntentsExecutionAndValidation` | 1.74 | runs every intent against a store |
| `testPublisherTextFingerprints` | 1.32 | fingerprint corpus |
| `testLibraryBackupRestore` | 1.21 | backup and restore on disk (the file is the point) |
| `testLibraryBackupAndFutureSchemaGuard` | 1.14 | same |

Proposals, all behaviour-preserving (same assertions, same coverage):

1. **Spill earlier in `testActiveWorkCancellation`.** The 20,000-row insert exists only to exceed the page-cache
   spill threshold; the comment says so. Give the test connection a small cache (`PRAGMA cache_size=-256`, 256 KiB,
   through a test-only `DatabaseEngine` setting or an environment variable the engine reads on open) and 2,000 rows
   spill the same way. The assertions (spill before commit, cancel rolls back, FTS stays valid) are unchanged.
   Expected: 18.7 s → about 2 s, which removes the slow shard as the pool's long pole (20 s → about 12 s).
2. **Raise the default shard count once the slow shard is gone.** With `NEWS_TEST_SHARDS=6` on 10 cores the four
   9–12 s shards become six of about 7 s; the pool already runs 6 jobs at once. The measured 2.5 s of Core ML and
   corpus load per shard argues against going higher.
3. **Archive once in `testDiagnosticsExport`.** The second `archive` call checks that an existing file is replaced;
   checking the file's modification date or size after a one-byte change to the input proves the same, and the
   `unzip` listing can run once. Expected: about 2.5 s saved.
4. **Pin the corpus tests to one shard.** `testEventCorpusHarness`, `testMatcherRegressionCorpus`,
   `testStoryRegressionCorpus` and `testEventEmbeddingIntegration` each parse the corpus and load the models in
   their own process today, because `NEWS_TEST_SHARD=i/n` spreads them by index. A second group like
   `slowTests`, `corpusTests`, run in one process, parses the JSON and loads each model once; a `static let` cache
   in `StoryCorpus` then serves the rest. Expected: about 3 s of duplicated load gone across the shards.
5. **In-memory databases where the file is not the point.** `NewsTests.swift` opens 179 file-backed
   `DatabaseEngine(path:)` databases in the temporary directory and 94 `:memory:` ones. A file is needed when the
   test reopens the path, inspects it with `sqlite3_open`, copies, backs up or migrates it; the others pay WAL
   and `fsync` for nothing. Mechanical rule: a path used once, never passed to `FileManager` or `sqlite3_open`,
   becomes `:memory:`. Expected: 10–30 ms each, about 3 s across the shards.
6. **The compile is the real floor.** 42 s of the 80 s run (the rest: 20 s pool, about 18 s of design lint and Python self-checks) is one `swiftc` over the app and the tests; `test.sh`
   already skips the whole run when the inputs hash matches a pass stamp. The only lever that beats it is an
   incremental build (a SwiftPM test target, so object files survive between runs), which changes how the suite is
   built and is out of scope for a cleanup pass.

Not proposed: shrinking seeded libraries (none of the ten slowest seeds a large library; the 20,000 rows above are
the one case and item 1 handles it) or cutting the deadlines in `testOverviewPublisherEvidence`, which assert real
time.

## 6. File placement

`Package.swift` globs `Sources/` (path-based target), so a move does not change the module. `build.sh`,
`build_release.sh`, `script/build_test_runner.sh`, `script/native_performance_baseline.sh`,
`script/test_native_ui_qa.sh`, `script/test_reader_accessibility.sh`, `script/test_event_overview_accessibility.sh`
and `script/test_tension_calibration.sh` list every Swift file by path (398 path lines; `NewsApp.swift` must stay
last because the harness scripts append their entry points after it), and `script/design_lint_baseline.txt` keys
its baseline on paths. The moves below are applied in this PR with the recipe at the end of this section; every
old path in those scripts, the lint baseline, `docs/ARCHITECTURE.md`, `docs/DESIGN.md` and two file-header
comments is rewritten, and a grep for each old path over the scripts, `Sources`, `Tests`, the CI configs and the
living docs finds none. `.sonarcloud.properties` scopes one rule to `Sources/Intelligence/**/*`, a glob, so it is
unaffected. Dated audits and plans keep the old paths: they describe the tree at their date.

### `Sources/Intelligence` (28 files → 5 folders + 3 at the root), applied

| Folder | Files |
|---|---|
| `Overview/` | `OverviewComposer`, `OverviewGenerationCoordinator`, `OverviewPassageSelector`, `OverviewQualityAuditor`, `OverviewClaimVerifier`, `OverviewTimelineBuilder`, `OverviewTimelineExtractor`, `OverviewPerspectivesExtractor`, `OverviewThematicAngleExtractor`, `OverviewIndustryImpactExtractor`, `PassageFactExtractor`, `CoverageSentimentEvaluator` |
| `Events/` | `EventCandidates`, `EventMatcher`, `EventClustering`, `EventJudge`, `ActClass`, `SentenceEmbedder`, `StoryImportance` |
| `Extraction/` | `ContentExtractionPipeline`, `EnrichmentQueue` |
| `Briefing/` | `BriefingSitrepComposer`, `ForwardWatchExtractor` |
| `Tension/` | `WorldTension`, `TensionMethodology` |
| root | `ArticleIntelligence` (the model session every extractor uses), `IntelligencePolicy`, `PromptDefense` |

### `Sources/Views` (30 files → 3 folders + 7 at the root), applied

Codacy flagged `BriefingView.swift` (684 non-comment lines) once the move made it a new file to the analyzer, so it is
split at its two seams: `BriefingHeroCarouselView.swift` (the hero carousel) and `BriefingBoardLayout.swift` (the
section, tile grid, completion banner and split layout). `BriefingView.swift` keeps the actions bundle and the board.

| Folder | Files |
|---|---|
| `Briefing/` | `BriefingView`, `BriefingComponents`, `BriefingModules` and the ten `Briefing*Module` files |
| `Reader/` | `ArticleDetailView`, `ArticleWebView`, `EventOverviewReaderView`, `ReaderSupportViews`, `WebPreviewPolicy`, `ArticleRemoteImage` |
| `List/` | `ArticleListView`, `ArticleCardView`, `EventCardView`, `FeedHealthLine` |
| root | `MainView`, `SidebarView`, `SettingsView`, `FeedCatalogView`, `OnboardingView`, `TensionIndexView`, `DesignSystem` |

### `Sources/Storage`

Eleven files, three of them extensions named after their base type. Leave flat: a `Database/` and `Store/` split
would hold four and five files and hide the `+Events`/`+Briefing` pairing the names already show.

### The recipe that was run

```bash
# 1. One line per file, from the two tables above: "<folder> <file>" (the Views table in the same form).
moves='Intelligence/Overview OverviewComposer
Intelligence/Overview OverviewGenerationCoordinator
Intelligence/Overview OverviewPassageSelector
Intelligence/Overview OverviewQualityAuditor
Intelligence/Overview OverviewClaimVerifier
Intelligence/Overview OverviewTimelineBuilder
Intelligence/Overview OverviewTimelineExtractor
Intelligence/Overview OverviewPerspectivesExtractor
Intelligence/Overview OverviewThematicAngleExtractor
Intelligence/Overview OverviewIndustryImpactExtractor
Intelligence/Overview PassageFactExtractor
Intelligence/Overview CoverageSentimentEvaluator
Intelligence/Events EventCandidates
Intelligence/Events EventMatcher
Intelligence/Events EventClustering
Intelligence/Events EventJudge
Intelligence/Events ActClass
Intelligence/Events SentenceEmbedder
Intelligence/Events StoryImportance
Intelligence/Extraction ContentExtractionPipeline
Intelligence/Extraction EnrichmentQueue
Intelligence/Briefing BriefingSitrepComposer
Intelligence/Briefing ForwardWatchExtractor
Intelligence/Tension WorldTension
Intelligence/Tension TensionMethodology
Views/Briefing BriefingView
Views/Briefing BriefingComponents
Views/Briefing BriefingModules
Views/Briefing BriefingSitrepModule
Views/Briefing BriefingSinceLastModule
Views/Briefing BriefingPriorityModule
Views/Briefing BriefingFootprintModule
Views/Briefing BriefingRegionsModule
Views/Briefing BriefingIndustryModule
Views/Briefing BriefingDriversModule
Views/Briefing BriefingTimelineModule
Views/Briefing BriefingWeakSignalsModule
Views/Briefing BriefingForwardWatchModule
Views/Reader ArticleDetailView
Views/Reader ArticleWebView
Views/Reader EventOverviewReaderView
Views/Reader ReaderSupportViews
Views/Reader WebPreviewPolicy
Views/Reader ArticleRemoteImage
Views/List ArticleListView
Views/List ArticleCardView
Views/List EventCardView
Views/List FeedHealthLine'   # the 48 moved files
scripts=(build.sh build_release.sh script/build_test_runner.sh script/native_performance_baseline.sh
  script/test_native_ui_qa.sh script/test_reader_accessibility.sh script/test_event_overview_accessibility.sh
  script/test_tension_calibration.sh)
# 2. Create each destination folder, move the file, and rewrite its old path in every script that lists files.
echo "$moves" | while read -r folder file; do
  old="Sources/${folder%/*}/$file.swift"; new="Sources/$folder/$file.swift"
  mkdir -p "$(dirname "$new")" && git mv "$old" "$new" && sed -i '' "s#$old#$new#g" "${scripts[@]}"
done
# 3. Check every old path is gone from the scripts, then build and test.
echo "$moves" | while read -r folder file; do grep -n "Sources/${folder%/*}/$file.swift" "${scripts[@]}"; done | grep . && echo STALE
./build.sh && NEWS_TEST_FORCE=1 ./test.sh
```

Docs that name old paths (24 audits and plans) can keep them: they describe the tree at their date.

## 7. The on-device models

There is no `.mlmodel` or `.mlpackage` in the repository and no weights compiled into Swift. The two models ship as
compiled Core ML bundles under `Sources/Resources/CoreML/` (until this PR `Sources/Resources/Models/`, a name that
collided with `Sources/Models`, the folder of Swift data types such as `FeedArticle`; the bundles stay under
`Resources` because SwiftPM copies that folder as a resource, and the app bundle now carries them in
`Contents/Resources/CoreML/`), which is why the Finder view of `Sources/Intelligence` shows no model files:

| Path | What it is |
|---|---|
| `Sources/Resources/CoreML/minilm.mlmodelc/` (44 MB: `weights/weight.bin`, `model.mil`, `coremldata.bin`, `metadata.json`) | the sentence encoder, `sentence-transformers/all-MiniLM-L6-v2`, fp16, one function per padded length (16/32/64/128) so it runs on the Neural Engine (#554) |
| `Sources/Resources/CoreML/pairscorer.mlmodelc/` (44 MB, same layout) | the in-house pair cross-encoder (#525), fine-tuned from the MiniLM weights on pairs from `./test.sh --export-pairs` and the public pretraining sets; functions for 64/128/256 tokens; output `probability` (different / related / same, #627) |
| `Sources/Resources/CoreML/vocab.txt` | the WordPiece vocabulary both models and `script/training/wordpiece.py` tokenize with |
| `Sources/Resources/CoreML/{minilm,pairscorer}-metadata.json` | provenance: base weights, training state SHA-256, conversion tool versions, parity checks, and the audit that measured them |

A `.mlmodelc` is a directory (Core ML's compiled form), so Finder shows it as a folder, not a model icon; the
editable `.mlpackage` is never committed. Produced by `script/training/convert_minilm.py` (Hub revision → Core ML),
`train_pair_model.py` (fine-tune and export), `compress_models.py` (fp16 fixed-length export of both, 27 October);
training states (`.pt`) and pair CSVs stay outside the checkout, with their SHA-256 in the audits. Shipped by
`build.sh` and `build_release.sh`, which copy `Sources/Resources/CoreML/*` into `News.app/Contents/Resources/CoreML/`;
SwiftPM copies the same folder as a resource. Loaded in `Sources/Intelligence/Events/SentenceEmbedder.swift`
(`bundledModelResource`, lines 156–167: `Bundle.module` for SwiftPM, then `Bundle.main` `CoreML/`, then the source
path for the test runner) with `MLModel(contentsOf:)` and `cpuAndNeuralEngine`; `PairScorer` in the same file is
what `EventClustering.swift` calls for pair probabilities. The "decision head" of `fit_pair_head.py` is an
evaluation tool that prints a Swift literal for review; the shipped cutoff calibration lives in
`EventMatcher.swift` (#629), not as model weights. Nothing is downloaded at run time.

## 8. Every file in `docs/` (as surveyed, before the deletions above)

| Last commit | File | Referenced by (outside docs/) | Links from other docs |
|---|---|---|---|
| 2026-10-31 | `docs/ARCHITECTURE.md` | .antigravity/worktrees/voiceover-qa/AGENTS.md .antigravity/worktrees/voiceover-qa/CONTRIBUTING.md .antigravity/worktrees/voiceover-qa/SECURITY.md .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-resilience-and-migration-coverage.md AGENTS.md CONTRIBUTING.md SECURITY.md docs/DESIGN.md docs/RELEASE_CHECKLIST.md docs/audits/2026-10-02-resilience-and-migration-coverage.md docs/plans/2026-10-09-design-language-adoption.md docs/plans/2026-10-23-finish-pass.md docs/plans/2026-10-24-future-development.md docs/plans/2026-10-28-next-features-roadmap.md docs/plans/2026-10-31-adr-001-strengthen-the-platform.md docs/plans/2026-10-31-v2-release-gate.md  | 9 |
| 2026-10-31 | `docs/DESIGN.md` | .github/pull_request_template.md AGENTS.md CHANGELOG.md CONTRIBUTING.md README.md Sources/App/NewsApp.swift Sources/Models/FeedArticle.swift Sources/News.docc/Articles/ArchitectureOverview.md Sources/Views/ArticleCardView.swift Sources/Views/ArticleDetailView.swift Sources/Views/ArticleListView.swift Sources/Views/BriefingComponents.swift Sources/Views/BriefingDriversModule.swift Sources/Views/BriefingForwardWatchModule.swift Sources/Views/BriefingModules.swift Sources/Views/BriefingView.swift Sources/Views/DesignSystem.swift Sources/Views/EventCardView.swift Sources/Views/EventOverviewReaderView.swift Sources/Views/OnboardingView.swift Sources/Views/ReaderSupportViews.swift Sources/Views/SettingsView.swift Sources/Views/SidebarView.swift Sources/Views/TensionIndexView.swift Tests/BriefingE2ETests.swift docs/ARCHITECTURE.md docs/XCODE_AND_APP_REVIEW.md docs/audits/2026-10-09-apple-news-liquid-glass-study.md docs/audits/2026-10-10-design-acceptance.md docs/audits/2026-10-10-design-phase-3.md docs/audits/2026-10-30-epic-m-verification.md docs/mocks/briefing_situation_board.md docs/notifications.md docs/plans/2026-10-09-design-language-adoption.md docs/plans/2026-10-21-state-and-next-development.md docs/plans/2026-10-23-finish-pass.md docs/plans/2026-10-24-comprehensive-analysis.md docs/plans/2026-10-24-future-development.md docs/plans/2026-10-24-october-feedback.md docs/plans/2026-10-28-next-features-roadmap.md docs/plans/2026-10-30-v2-completion.md script/design_lint.sh script/design_lint_baseline.txt  | 16 |
| 2026-10-31 | `docs/RELEASE_CHECKLIST.md` | CONTRIBUTING.md docs/plans/2026-10-31-v2-release-gate.md  | 1 |
| 2026-10-31 | `docs/XCODE_AND_APP_REVIEW.md` | README.md docs/ARCHITECTURE.md  | 1 |
| 2026-09-30 | `docs/audits/2026-09-27-reader-modernization.md` | .antigravity/worktrees/voiceover-qa/README.md README.md  | 0 |
| 2026-10-01 | `docs/audits/2026-09-30-kite-study.md` | .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-09-30 | `docs/audits/2026-09-30-pr-review.md` | none | 0 |
| 2026-09-30 | `docs/audits/2026-09-30-pr86-readiness.md` | none | 0 |
| 2026-09-30 | `docs/audits/2026-09-30-production-readiness.md` | .antigravity/worktrees/voiceover-qa/README.md README.md  | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-conditional-feed-requests.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-feed-backoff-and-host-limits.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-feed-health-indicators.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-feed-scoped-guids.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-historical-document-reconciliation.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-model-availability-fallbacks.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-overview-document-model.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-passage-token-budget.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-persistent-article-aliases.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-publisher-text-fingerprints.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-reader-images-phase-c.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-refresh-decoupling.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-source-text-as-data.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-starter-feed-catalog.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-01-story-foundation.md` | .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md docs/audits/2026-10-05-core-release-acceptance.md docs/plans/2026-09-30-story-experience.md  | 2 |
| 2026-10-01 | `docs/audits/2026-10-01-validated-document-aliases.md` | none | 0 |
| 2026-10-26 | `docs/audits/2026-10-02-active-work-cancellation.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-feed-parsing-cancellation.md .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-publisher-cancellation.md docs/audits/2026-10-02-feed-parsing-cancellation.md docs/audits/2026-10-03-publisher-cancellation.md docs/audits/2026-10-05-core-release-acceptance.md  | 3 |
| 2026-10-02 | `docs/audits/2026-10-02-attributed-perspectives.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-baseline-fixture-completion.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-candidate-recognizer-reuse.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-compose-overview-facts.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-core-performance-baseline.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-coverage-sentiment.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-deterministic-claim-verification.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-durable-fts-keys.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-evaluation-corpus.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-02-event-candidates.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-event-clustering.md` | none | 0 |
| 2026-10-01 | `docs/audits/2026-10-02-event-data-model.md` | none | 0 |
| 2026-10-03 | `docs/audits/2026-10-02-event-embedding-comparison.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-event-overview-accessibility.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-event-overview-reader-mode.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-event-timeline-with-sources.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-feed-parsing-cancellation.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-publisher-cancellation.md .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md docs/audits/2026-10-03-publisher-cancellation.md docs/plans/2026-09-30-story-experience.md  | 2 |
| 2026-10-02 | `docs/audits/2026-10-02-finite-briefing.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-foundation-models-probe.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-integrated-performance-budgets.md` | .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-02 | `docs/audits/2026-10-02-launch-baseline.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-reading-memory.md .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md docs/audits/2026-10-03-reading-memory.md docs/audits/2026-10-05-cold-launch.md docs/plans/2026-09-30-story-experience.md  | 3 |
| 2026-10-02 | `docs/audits/2026-10-02-overview-generation-caching.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-overview-generation-supersession.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-overview-quality-audit-gate.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-overview-reader-lifecycle.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-overview-timeline.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-passage-anchored-facts.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-reader-accessibility.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-reader-structure-on-refresh.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-real-publisher-capture.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-resilience-and-migration-coverage.md` | docs/audits/2026-10-05-core-release-acceptance.md  | 1 |
| 2026-10-02 | `docs/audits/2026-10-02-tension-index-calibration.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-tension-view.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-thematic-angle.md` | none | 0 |
| 2026-10-02 | `docs/audits/2026-10-02-transport-cancellation.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-publisher-cancellation.md docs/audits/2026-10-03-publisher-cancellation.md docs/audits/2026-10-05-core-release-acceptance.md  | 2 |
| 2026-10-02 | `docs/audits/2026-10-02-unchanged-fts-refresh.md` | none | 0 |
| 2026-10-03 | `docs/audits/2026-10-03-event-boundaries-fingerprint-scope.md` | .antigravity/worktrees/voiceover-qa/Tests/Fixtures/story-corpus/README.md Tests/Fixtures/story-corpus/README.md  | 0 |
| 2026-10-03 | `docs/audits/2026-10-03-extraction-region.md` | none | 0 |
| 2026-10-03 | `docs/audits/2026-10-03-native-ui-qa-system-settings.md` | docs/audits/2026-10-05-core-release-acceptance.md  | 1 |
| 2026-10-03 | `docs/audits/2026-10-03-plain-text-feed-content.md` | none | 0 |
| 2026-10-03 | `docs/audits/2026-10-03-publisher-cancellation.md` | .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-03 | `docs/audits/2026-10-03-publisher-holdout-review.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-event-boundaries-fingerprint-scope.md docs/audits/2026-10-03-event-boundaries-fingerprint-scope.md  | 1 |
| 2026-10-03 | `docs/audits/2026-10-03-reading-memory.md` | none | 0 |
| 2026-10-04 | `docs/audits/2026-10-04-holdout-pair-adjudication.md` | none | 0 |
| 2026-10-04 | `docs/audits/2026-10-04-publisher-content-provenance.md` | docs/audits/2026-10-05-core-release-acceptance.md  | 1 |
| 2026-10-04 | `docs/audits/2026-10-04-publisher-event-diversity.md` | none | 0 |
| 2026-10-04 | `docs/audits/2026-10-04-publisher-evidence-followup.md` | none | 0 |
| 2026-10-04 | `docs/audits/2026-10-04-reader-structure.md` | docs/audits/2026-10-05-core-release-acceptance.md  | 1 |
| 2026-10-04 | `docs/audits/2026-10-04-supplement-pair-adjudication.md` | none | 0 |
| 2026-10-04 | `docs/audits/2026-10-04-voiceover-harness.md` | docs/audits/2026-10-05-core-release-acceptance.md  | 1 |
| 2026-10-05 | `docs/audits/2026-10-05-cold-launch.md` | docs/audits/2026-10-05-core-release-acceptance.md docs/audits/2026-10-05-full-app-workload.md docs/plans/2026-09-30-story-experience.md  | 3 |
| 2026-10-05 | `docs/audits/2026-10-05-core-release-acceptance.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-05 | `docs/audits/2026-10-05-event-corpus-holdout.md` | docs/audits/2026-10-05-core-release-acceptance.md docs/plans/2026-09-30-story-experience.md  | 2 |
| 2026-10-05 | `docs/audits/2026-10-05-fingerprint-release-scope.md` | none | 0 |
| 2026-10-05 | `docs/audits/2026-10-05-full-app-workload.md` | docs/audits/2026-10-05-cold-launch.md docs/audits/2026-10-05-core-release-acceptance.md docs/plans/2026-09-30-story-experience.md  | 3 |
| 2026-10-09 | `docs/audits/2026-10-09-apple-news-liquid-glass-study.md` | docs/DESIGN.md docs/plans/2026-10-09-design-language-adoption.md  | 2 |
| 2026-10-09 | `docs/audits/2026-10-09-card-image-figure-fallback.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-09 | `docs/audits/2026-10-09-codacy-slices.md` | docs/audits/2026-10-09-plain-text-overviews.md docs/audits/2026-10-09-story-curation-images.md docs/plans/2026-09-30-story-experience.md  | 3 |
| 2026-10-09 | `docs/audits/2026-10-09-current-matcher-replay.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-09 | `docs/audits/2026-10-09-orphan-article-state.md` | none | 0 |
| 2026-10-09 | `docs/audits/2026-10-09-plain-text-overviews.md` | docs/audits/2026-10-10-overview-live-audit.md docs/plans/2026-09-30-story-experience.md  | 2 |
| 2026-10-09 | `docs/audits/2026-10-09-real-library-migration.md` | none | 0 |
| 2026-10-09 | `docs/audits/2026-10-09-sonar-slices.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-09 | `docs/audits/2026-10-09-story-curation-images.md` | docs/audits/2026-10-09-card-image-figure-fallback.md docs/audits/2026-10-09-plain-text-overviews.md docs/plans/2026-09-30-story-experience.md  | 3 |
| 2026-10-10 | `docs/audits/2026-10-10-design-acceptance.md` | docs/plans/2026-09-30-story-experience.md docs/plans/2026-10-09-design-language-adoption.md  | 2 |
| 2026-10-10 | `docs/audits/2026-10-10-design-phase-3.md` | docs/plans/2026-10-09-design-language-adoption.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-design-phase-4.md` | docs/plans/2026-10-09-design-language-adoption.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-design-phase-5.md` | docs/plans/2026-10-09-design-language-adoption.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-design-phase-6.md` | docs/plans/2026-10-09-design-language-adoption.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-event-hard-conflict-guards.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-fresh-english-matcher-diagnostic.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-independent-bounded-overview-review.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-independent-importance-review.md` | docs/audits/2026-10-10-independent-overview-claims.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-independent-overview-claims.md` | docs/audits/2026-10-10-independent-bounded-overview-review.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-matcher-pair-verdicts.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-native-window-chrome.md` | docs/plans/2026-10-09-design-language-adoption.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-overview-bounded-comparison.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-overview-evidence-step2.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-overview-live-audit.md` | docs/audits/2026-10-10-overview-evidence-step2.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-perspective-attribution.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-pr429-correctness.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-related-event-backend.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-related-event-live-check.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-reported-speech-perspectives.md` | none | 0 |
| 2026-10-10 | `docs/audits/2026-10-10-review-input-integrity.md` | docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-10 | `docs/audits/2026-10-10-source-review-criteria-and-alternatives.md` | none | 0 |
| 2026-10-11 | `docs/audits/2026-10-10-world-tension-and-motion.md` | none | 0 |
| 2026-10-11 | `docs/audits/2026-10-11-tension-search-scroll.md` | none | 0 |
| 2026-10-17 | `docs/audits/2026-10-17-release-core-validation.md` | none | 0 |
| 2026-10-18 | `docs/audits/2026-10-18-hindu-reader-access.md` | none | 0 |
| 2026-10-18 | `docs/audits/2026-10-18-matcher-307-verification.md` | docs/audits/2026-10-24-algorithmic-hardening.md  | 1 |
| 2026-10-18 | `docs/audits/2026-10-18-notification-attachments-and-overlap.md` | README.md  | 0 |
| 2026-10-18 | `docs/audits/2026-10-18-notification-live-check.md` | docs/audits/2026-10-18-notification-attachments-and-overlap.md  | 1 |
| 2026-10-18 | `docs/audits/2026-10-18-post-wave2-acceptance.md` | none | 0 |
| 2026-10-18 | `docs/audits/2026-10-18-post-wave2-release-acceptance.md` | README.md docs/plans/2026-09-30-story-experience.md  | 1 |
| 2026-10-18 | `docs/audits/2026-10-18-swiftsoup-feedkit.md` | none | 0 |
| 2026-10-20 | `docs/audits/2026-10-20-developing-story-links.md` | docs/ARCHITECTURE.md  | 1 |
| 2026-10-21 | `docs/audits/2026-10-21-catalog-reader-access.md` | CHANGELOG.md docs/plans/2026-10-21-state-and-next-development.md docs/plans/2026-10-23-finish-pass.md  | 2 |
| 2026-10-24 | `docs/audits/2026-10-24-algorithmic-hardening.md` | none | 0 |
| 2026-10-30 | `docs/audits/2026-10-24-library-clustering-diagnosis.md` | docs/audits/2026-10-30-epic-m-verification.md docs/plans/2026-10-24-october-feedback.md  | 2 |
| 2026-10-30 | `docs/audits/2026-10-24-pair-decision-review.md` | docs/audits/2026-10-24-library-clustering-diagnosis.md docs/audits/2026-10-30-epic-m-verification.md  | 2 |
| 2026-10-30 | `docs/audits/2026-10-24-pair-model-pretraining.md` | Sources/Intelligence/EventMatcher.swift Sources/Resources/Models/pairscorer-metadata.json  | 0 |
| 2026-10-26 | `docs/audits/2026-10-24-topic-classifier-sample.md` | none | 0 |
| 2026-10-24 | `docs/audits/2026-10-24-unified-intelligence.md` | docs/audits/2026-10-24-algorithmic-hardening.md  | 1 |
| 2026-10-30 | `docs/audits/2026-10-25-reproducible-models.md` | none | 0 |
| 2026-10-26 | `docs/audits/2026-10-26-perspectives-and-verifier-controls.md` | none | 0 |
| 2026-10-30 | `docs/audits/2026-10-27-model-compression.md` | none | 0 |
| 2026-10-30 | `docs/audits/2026-10-27-neural-engine-placement.md` | Sources/Resources/Models/minilm-metadata.json  | 0 |
| 2026-10-30 | `docs/audits/2026-10-27-news-embedder.md` | none | 0 |
| 2026-10-30 | `docs/audits/2026-10-27-story-singletons.md` | docs/ARCHITECTURE.md  | 1 |
| 2026-10-30 | `docs/audits/2026-10-27-three-way-pair-model.md` | Sources/Intelligence/EventMatcher.swift  | 0 |
| 2026-10-30 | `docs/audits/2026-10-30-carry-in.md` | none | 0 |
| 2026-10-30 | `docs/audits/2026-10-30-epic-m-verification.md` | docs/RELEASE_CHECKLIST.md docs/audits/2026-10-24-library-clustering-diagnosis.md docs/audits/2026-10-24-pair-decision-review.md  | 3 |
| 2026-10-30 | `docs/audits/2026-10-30-story-country-signal.md` | docs/plans/2026-10-30-v2-completion.md  | 1 |
| 2026-10-04 | `docs/audits/SONAR_REVIEW.md` | none | 0 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-active-work-cancellation.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-active-work-cancellation.md docs/audits/2026-10-02-active-work-cancellation.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-candidate-recognizer-reuse.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-candidate-recognizer-reuse.md docs/audits/2026-10-02-candidate-recognizer-reuse.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-core-baseline.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-core-performance-baseline.md .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-unchanged-fts-refresh.md docs/audits/2026-10-02-core-performance-baseline.md docs/audits/2026-10-02-unchanged-fts-refresh.md  | 2 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-feed-parsing-cancellation.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-feed-parsing-cancellation.md docs/audits/2026-10-02-feed-parsing-cancellation.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-fts-rowid-baseline.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-durable-fts-keys.md docs/audits/2026-10-02-durable-fts-keys.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-fts-rowid-migration.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-durable-fts-keys.md docs/audits/2026-10-02-durable-fts-keys.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-guarded-fts.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-unchanged-fts-refresh.md docs/audits/2026-10-02-unchanged-fts-refresh.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-integrated-core-baseline.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-candidate-recognizer-reuse.md .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-integrated-performance-budgets.md docs/audits/2026-10-02-candidate-recognizer-reuse.md docs/audits/2026-10-02-integrated-performance-budgets.md  | 2 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-launch-baseline.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-launch-baseline.md docs/audits/2026-10-02-launch-baseline.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-native-mainview-baseline.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-integrated-performance-budgets.md docs/audits/2026-10-02-integrated-performance-budgets.md  | 1 |
| 2026-10-02 | `docs/benchmarks/2026-10-02-transport-cancellation.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-transport-cancellation.md docs/audits/2026-10-02-transport-cancellation.md  | 1 |
| 2026-10-03 | `docs/benchmarks/2026-10-03-publisher-cancellation.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-publisher-cancellation.md docs/audits/2026-10-03-publisher-cancellation.md  | 1 |
| 2026-10-03 | `docs/benchmarks/2026-10-03-reading-memory.json` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-03-reading-memory.md docs/audits/2026-10-03-reading-memory.md  | 1 |
| 2026-10-04 | `docs/benchmarks/2026-10-04-reader-structure.json` | docs/audits/2026-10-04-reader-structure.md  | 1 |
| 2026-10-05 | `docs/benchmarks/2026-10-05-cold-launch.json` | docs/audits/2026-10-05-cold-launch.md  | 1 |
| 2026-10-05 | `docs/benchmarks/2026-10-05-fingerprint-holdout.json` | docs/audits/2026-10-05-core-release-acceptance.md  | 1 |
| 2026-10-05 | `docs/benchmarks/2026-10-05-fingerprint-release-scope.json` | docs/audits/2026-10-05-fingerprint-release-scope.md  | 1 |
| 2026-10-05 | `docs/benchmarks/2026-10-05-full-app-workload.json` | docs/audits/2026-10-05-full-app-workload.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-design-acceptance.json` | docs/audits/2026-10-10-design-acceptance.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-fresh-matcher-diagnostic.json` | docs/audits/2026-10-10-fresh-english-matcher-diagnostic.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-native-window-chrome.json` | docs/audits/2026-10-10-native-window-chrome.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-overview-bounded-comparison-receipt.json` | none | 0 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-overview-bounded-comparison.json` | none | 0 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-overview-evidence-step2-fixed.json` | docs/audits/2026-10-10-overview-evidence-step2.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-overview-evidence-step2.json` | docs/audits/2026-10-10-overview-evidence-step2.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-overview-live-audit.json` | docs/audits/2026-10-10-overview-live-audit.md  | 1 |
| 2026-10-10 | `docs/benchmarks/2026-10-10-overview-step2-receipt.json` | docs/audits/2026-10-10-overview-evidence-step2.md  | 1 |
| 2026-10-17 | `docs/benchmarks/2026-10-17-release-core.json` | none | 0 |
| 2026-10-18 | `docs/benchmarks/2026-10-18-matcher-307-verification.json` | docs/audits/2026-10-18-matcher-307-verification.md  | 1 |
| 2026-10-24 | `docs/benchmarks/2026-10-24-matcher-hardening-holdout.json` | docs/audits/2026-10-24-algorithmic-hardening.md  | 1 |
| 2026-10-30 | `docs/benchmarks/2026-10-25-embedding-throughput.json` | none | 0 |
| 2026-10-30 | `docs/benchmarks/2026-10-27-neural-engine-placement.json` | docs/audits/2026-10-27-neural-engine-placement.md  | 1 |
| 2026-10-02 | `docs/methodology/tension-calibration-v1.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-tension-index-calibration.md .antigravity/worktrees/voiceover-qa/docs/methodology/tension-index-v1.md docs/audits/2026-10-02-tension-index-calibration.md docs/methodology/tension-index-v1.md docs/methodology/world-tension-v3.md  | 3 |
| 2026-10-18 | `docs/methodology/tension-index-v1.md` | .antigravity/worktrees/voiceover-qa/CHANGELOG.md .antigravity/worktrees/voiceover-qa/Sources/Intelligence/TensionMethodology.swift .antigravity/worktrees/voiceover-qa/Sources/Views/TensionIndexView.swift .antigravity/worktrees/voiceover-qa/docs/ARCHITECTURE.md .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-02-tension-index-calibration.md .antigravity/worktrees/voiceover-qa/docs/methodology/tension-calibration-v1.md .antigravity/worktrees/voiceover-qa/docs/plans/2026-09-30-story-experience.md CHANGELOG.md Sources/Intelligence/TensionMethodology.swift docs/ARCHITECTURE.md docs/audits/2026-10-02-tension-index-calibration.md docs/methodology/tension-calibration-v1.md docs/plans/2026-09-30-story-experience.md  | 4 |
| 2026-10-26 | `docs/methodology/world-tension-v2.md` | docs/methodology/world-tension-v3.md  | 1 |
| 2026-10-26 | `docs/methodology/world-tension-v3.md` | docs/ARCHITECTURE.md docs/methodology/world-tension-v2.md script/evaluation/calibrate_tension.py  | 2 |
| 2026-10-31 | `docs/mocks/briefing_situation_board.md` | docs/DESIGN.md  | 1 |
| 2026-11-01 | `docs/notifications.md` | CHANGELOG.md Sources/Coordinators/FeedManager.swift Sources/Coordinators/NotificationService.swift Sources/Storage/DatabaseEngine.swift docs/ARCHITECTURE.md  | 1 |
| 2026-10-18 | `docs/plans/2026-09-30-story-experience.md` | .antigravity/worktrees/voiceover-qa/docs/audits/2026-10-01-story-foundation.md README.md docs/audits/2026-10-01-story-foundation.md  | 1 |
| 2026-10-10 | `docs/plans/2026-10-09-design-language-adoption.md` | docs/DESIGN.md docs/audits/2026-10-09-apple-news-liquid-glass-study.md docs/plans/2026-09-30-story-experience.md  | 3 |
| 2026-10-18 | `docs/plans/2026-10-17-release-simplification.md` | CONTRIBUTING.md docs/ARCHITECTURE.md  | 1 |
| 2026-10-21 | `docs/plans/2026-10-21-state-and-next-development.md` | none | 0 |
| 2026-10-24 | `docs/plans/2026-10-23-finish-pass.md` | docs/plans/2026-10-24-comprehensive-analysis.md  | 1 |
| 2026-10-24 | `docs/plans/2026-10-24-comprehensive-analysis.md` | docs/plans/2026-10-24-comprehensive-analysis.md  | 0 |
| 2026-10-30 | `docs/plans/2026-10-24-future-development.md` | CONTRIBUTING.md docs/plans/2026-10-24-future-development.md  | 0 |
| 2026-10-30 | `docs/plans/2026-10-24-october-feedback.md` | docs/plans/2026-10-24-october-feedback.md  | 0 |
| 2026-10-28 | `docs/plans/2026-10-28-board-status-and-projections.md` | none | 0 |
| 2026-10-28 | `docs/plans/2026-10-28-next-features-roadmap.md` | docs/plans/2026-10-24-future-development.md docs/plans/2026-10-31-adr-001-strengthen-the-platform.md  | 2 |
| 2026-10-30 | `docs/plans/2026-10-30-v2-completion.md` | docs/RELEASE_CHECKLIST.md  | 1 |
| 2026-10-31 | `docs/plans/2026-10-31-adr-001-strengthen-the-platform.md` | .claude/agents/forensic.md  | 0 |
| 2026-10-31 | `docs/plans/2026-10-31-v2-release-gate.md` | none | 0 |
