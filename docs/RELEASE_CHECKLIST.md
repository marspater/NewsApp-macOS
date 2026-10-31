# Release checklist

Run this before every tag, on the merged `main` (a clean checkout, or a worktree at the commit to be tagged), and
record the result of each item in the release PR or the release plan under `docs/plans/`. Stacked PRs only get light
CI, so this list is the gate: a release is not cut until every item below passed or has a written reason it does not
apply. Never report an item as passed unless the command finished successfully.

Commands run from the repository root. "Library copy" means a copy of a real library, never the live file; take it
with SQLite's online backup API, which includes pages still in the write-ahead log (the exact commands are in
[the v2 completion plan](plans/2026-10-30-v2-completion.md), step 0):

```sh
(umask 077 && sqlite3 "file:$HOME/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3?mode=ro" ".backup $HOME/news-eval/library-copy.sqlite3")
stat -f %Lp "$HOME/news-eval/library-copy.sqlite3"   # must print 600: the copy holds private reading history
```

## 0. Everything, once

```sh
NEWS_TEST_FORCE=1 ./test.sh
```

`./test.sh` runs the design lint, the Python evaluation self-checks, the whole Swift suite as parallel jobs and the
three headless runners. `NEWS_TEST_FORCE=1` reruns it even if the same inputs passed on this machine. It does not read the library copy:
that is exercised by the manual migration step in item 1 and by the holdout in item 3. Also check that
`CI=1 script/format.sh --check` and `./build.sh` succeed. Without `CI` set, the format script passes with only a warning
when no swift-format is installed, so also confirm `xcrun --find swift-format` prints a path, or the check proved nothing. The items below name the part of this run that proves each gate,
plus the extra commands that are not in the plain run.

## 1. Database migration and restore on a library copy

- Automated, on synthetic libraries (it does not read `NEWS_SNAPSHOT_DB`): `./test.sh --fts-refresh-regression` runs
  the migration fixture, the pre-migration backup and newer-schema guard, and backup restore
  (`testRealLibraryMigrationFixture`, `testLibraryBackupAndFutureSchemaGuard`, `testLibraryBackupRestore` in
  `Tests/NewsTests.swift`).
- On the real-library copy (manual, below): compare the copy's
  schema version and story, read and saved counts before and after, as the v2 completion plan does:
  `sqlite3 <file> "PRAGMA user_version; SELECT count(*) FROM articles; SELECT count(*) FROM article_state WHERE is_read = 1; SELECT count(*) FROM article_state WHERE is_saved = 1;"`.
- Manual, migration and restore on the copy. `script/run_isolated.sh` builds the app under the bundle id
  `com.marspater.news.isolatedqa`, so it only ever opens the library in that container. Quit any running isolated
  News, then stage the copy there (never use `--real-library` or any other flag that opens the live library):

  ```sh
  D="$HOME/Library/Containers/com.marspater.news.isolatedqa/Data/Library/Application Support/com.marspater.news"
  mkdir -p "$D" && rm -f "$D"/news.sqlite3-wal "$D"/news.sqlite3-shm "$D"/news-before-v*.sqlite3
  install -m 600 "$HOME/news-eval/library-copy.sqlite3" "$D/news.sqlite3"
  ./script/run_isolated.sh
  ```

  Without `--seed` the script leaves the staged file alone. After the app has opened it, quit it and check
  `ls "$D"`: a `news-before-v<N>-…sqlite3` backup must sit beside `news.sqlite3`, and
  `sqlite3 "$D/news.sqlite3" "PRAGMA user_version; SELECT count(*) FROM articles; SELECT count(*) FROM article_state WHERE is_read = 1; SELECT count(*) FROM article_state WHERE is_saved = 1;"` must show the new schema and
  the original story, read and saved counts. Then restore: `mkdir -p "$TMPDIR/restore"`, copy the backup to `$TMPDIR/restore/news.sqlite3` and run
  `sqlite3 <restored> "PRAGMA integrity_check; PRAGMA user_version; SELECT count(*) FROM articles; SELECT count(*) FROM article_state WHERE is_read = 1; SELECT count(*) FROM article_state WHERE is_saved = 1;"` (expect `ok`,
  the pre-migration schema version and the original story, read and saved counts). Put that file back at `$D/news.sqlite3` (after removing
  any `-wal` and `-shm` beside it), run `./script/run_isolated.sh` again and confirm it migrates to the same three counts. Story, read and saved counts must all match the
  original copy for the migrated, the restored and the second migrated database; a restore that loses history fails.

## 2. Feed parser and networking security tests

- Automated, part of `./test.sh`: the secure HTTP client, SOCKS boundary proxy, redirect and private-address tests
  in `Tests/NewsTests.swift`, and `Tests/FeedKitSwiftSoupTests.swift`.
- `./test.sh --parsing-regressions` for the offline HTML and feed compatibility and safety checks.
- `./test.sh --transport-cancellation` for refresh shutdown over controlled HTTP and SOCKS sockets (optimized build).
- `NEWS_NATIVE_HARNESS=Tests/PublisherExcerptTests.swift ./script/native_performance_baseline.sh` (run by CI too).
- CI additionally runs `.github/workflows/security.yml` (CodeQL, dependency review, secret scan).

## 3. Matcher holdout

No precision regression against the last recorded run, and wrong story groups within 2 % (#737).

```sh
./test.sh --matcher-regressions
NEWS_HOLDOUT_NOW=<epoch of the holdout> NEWS_SNAPSHOT_DB=<library copy> NEWS_LIBRARY_HOLDOUT=<holdout.json> ./test.sh --library-holdout
```

The current holdout is `~/news-eval/holdout-2026-10-29/library-holdout-2026-10-29.json` (SHA-256 and clock pin
`NEWS_HOLDOUT_NOW=1793300435` in `docs/audits/2026-10-30-epic-m-verification.md`, which also holds the baseline). Manual: compare the printed event and story precision, recall and wrong-group
rate with that baseline and write the numbers in the release record. A matcher change that touches the holdout needs a
fresh holdout, as the audits describe.

## 4. Notification deduplication

- Automated, part of `./test.sh`: `testNotificationDedupeAcrossRefreshes` and the "notification deduplication beyond the
  snapshot" test in `Tests/NewsTests.swift`, plus `Tests/NotificationAttachmentTests.swift`.
- Optional, needs a user-authorized News: `./script/test_notification_live.sh DIR` for real OS notifications with
  synthetic reports. Manual: after a refresh on the installed build, no story banner repeats.

## 5. Reader and Briefing E2E

- Automated: `Tests/BriefingE2ETests.swift` and the other Briefing suites (`BriefingWarRoomTests`,
  `BriefingIntelligenceTests`, `BriefingImpactTests`, `BriefingSignalsTests`) are atoms of `./test.sh`. To run one:
  `script/build_test_runner.sh /tmp/runner && NEWS_TEST_ATOM=Tests/BriefingE2ETests.swift /tmp/runner`.
- Reader: `script/test_reader_accessibility.sh` (headless).
- Manual: open the installed build, read one story in the reader, open the Briefing and check that both load.

## 6. Accessibility and visual captures, offscreen

- `script/test_event_overview_accessibility.sh` (Story Overview sections), `script/test_reader_accessibility.sh`,
  `script/test_tension_calibration.sh`: headless, no window.
- Captures without a window or Screen Recording:
  `NEWS_NATIVE_HARNESS=Tests/OverviewCaptures.swift script/native_performance_baseline.sh DIR` (every Story Overview
  section at 900 and 1,400 pt, text size 1.0 and 1.3, light, dark and Increase Contrast). Review the images in `DIR`.
- `script/design_lint.sh` (first step of `./test.sh`).
- Not part of the gate: `script/appearance_matrix.sh` opens windows and needs Screen Recording, and the VoiceOver
  harness `script/test_voiceover_live_qa.sh` is parked (#268). Manual: a spoken VoiceOver pass is not required for v2.

## 7. Performance budgets

There is no automatic pass or fail budget yet: #543 re-baselines the numbers and #839 covers the list refresh. Until
they land, every command below must succeed and its numbers must be recorded in the release record next to the
newest file in `docs/benchmarks/`. Any regression against that file has to be acknowledged in the release record by
the release owner; an unacknowledged regression blocks the release.

```sh
./test.sh --performance-baseline
./script/native_performance_baseline.sh
NEWS_NATIVE_BODY_COUNTS=1 NEWS_NATIVE_HARNESS=Tests/ListInvalidationBaseline.swift script/native_performance_baseline.sh DIR
./script/launch_baseline.sh
```

## 8. Privacy manifest and documentation consistency

- Automated: `testDistributionAndEntitlementsIntegrity` (part of `./test.sh`) checks `PrivacyInfo.xcprivacy`, the
  entitlements, the container migration plist and that `PRIVACY.md` exists.
- Manual (#815, #569): read `PRIVACY.md`, `README.md`, `docs/ARCHITECTURE.md` and `CONTRIBUTING.md` against the
  code for anything this release changed (network access, stored data, notification limits, supported macOS).
  Run `python3 script/changelog_fold.py` when cutting the tag: it rewrites `CHANGELOG.md` and deletes the
  `CHANGELOG.d/` fragments. Check the result and commit it before tagging, so the tag contains the folded changelog.

## Cutting the tag

Only after every item passed: `git tag vX.Y.Z` on the checked commit and `./build_release.sh`, then check
`News.app/Contents/Info.plist`. Pushing a tag runs `.github/workflows/release.yml`; do not push one until the release
is meant to be published.
