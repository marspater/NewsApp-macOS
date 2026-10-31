# v2.0.0 release gate (31 October 2026)

The release checklist (`docs/RELEASE_CHECKLIST.md`) run on `main` `442ccec` plus the two open pull requests that
finish Epic Y: #884 (list redraw, counts cache, card dates) and #892 (publisher-review self-check under a restrictive
umask). The tree checked is the tip of `fix/839-card-rerender` (`ca26b80`), which is `main` with #884; #892 touches
only the Python self-check and was verified on its own branch. The tag is cut on `main` after both merge and this
record merges with the folded changelog. The difference between the checked tree and that final `main` is #892 (a
Python self-check in `script/evaluation/`), #891 (an agent definition under `.claude/`) and this record with the
folded changelog: no app code. The final confirmation below reruns the full suite and the build on the merged commit.

Machine: Apple silicon, macOS 27.2 (26B123), 10 cores, 24 GiB. Library copy: online backup of the owner's library
taken 31 October (schema 27, 7,442 stories, 99 read, 0 saved; the read count fell from 115 on 30 October because
30-day pruning of read stories now runs).

## 0. Everything, once

| Check | Result |
| --- | --- |
| `NEWS_TEST_FORCE=1 ./test.sh` on `ca26b80` (as the migration run below) | all tests passed |
| `CI=1 script/format.sh --check`, `xcrun --find swift-format` prints a path | pass |
| `./build.sh` | pass |

## 1. Database migration and restore on a library copy

| Check | Result |
| --- | --- |
| `./test.sh --fts-refresh-regression` | pass |
| `NEWS_TEST_FORCE=1 NEWS_SNAPSHOT_DB=<copy> ./test.sh` | pass; copy migrated 27 → 29, `integrity_check` ok, 7,442 / 99 / 0 stories, read, saved before and after |
| Manual isolated-app migration and restore (`script/run_isolated.sh`) | not run: it opens a window, which this session does not do; the automated backup, newer-schema guard and restore tests (`testLibraryBackupAndFutureSchemaGuard`, `testLibraryBackupRestore`) passed in the full run, and the 30 October record covers the same path at 25 → 27 |

## 2. Feed parser and networking security tests

| Check | Result |
| --- | --- |
| `./test.sh --parsing-regressions` | pass |
| `./test.sh --transport-cancellation` | pass |
| `NEWS_NATIVE_HARNESS=Tests/PublisherExcerptTests.swift ./script/native_performance_baseline.sh` | pass |
| `security.yml` (CodeQL, dependency review, secret scan) | green on #884 |

## 3. Matcher holdout

`./test.sh --matcher-regressions`: pass. Library holdout (`~/news-eval/holdout-2026-10-29/library-holdout-2026-10-29.json`,
SHA-256 `a0b681bc…3545`, `NEWS_HOLDOUT_NOW=1793300435`) on a writable copy of `~/news-eval/library-2026-10-29.sqlite3`,
the library it was drawn from (a run against today's copy links nothing, because the holdout's stories are not in it):

| Level | v13 baseline (30 Oct) | Last record (#773, v15) | This run (v15) |
| --- | --- | --- | --- |
| Strict event | 6 same, 3 related, 3 different; precision 0.500 | 6 / 2 / 2; 0.600 | 6 / 2 / 2; 0.600, recall 0.074 |
| Story level | 7 + 3 / 4; 0.714 | 7 + 2 / 3; 0.750 | 7 + 2 / 3; 0.750, recall 0.096 |

No precision regression. Wrong story groups stay at 3 of 12 (above the 2% target); that is #737, moved to v3 under
ADR-001 action 8. This was the fourth read of the holdout at this setting; the next matcher change needs a fresh draw.

## 4. Notification deduplication

`testNotificationDedupeAcrossRefreshes`, the beyond-the-snapshot test and `Tests/NotificationAttachmentTests.swift`
passed in the full run. The live notification script and the installed-build check are manual and not part of this
record.

## 5. Reader and Briefing E2E

The Briefing suites (`BriefingE2ETests`, `BriefingWarRoomTests`, `BriefingIntelligenceTests`, `BriefingImpactTests`,
`BriefingSignalsTests`) are atoms of `./test.sh` and passed. `script/test_reader_accessibility.sh`: pass. The manual
open-and-read check on the installed build is for the install step.

## 6. Accessibility and visual captures, offscreen

| Check | Result |
| --- | --- |
| `script/test_event_overview_accessibility.sh` | pass |
| `script/test_reader_accessibility.sh` | pass |
| `script/test_tension_calibration.sh` | pass |
| `NEWS_NATIVE_HARNESS=Tests/OverviewCaptures.swift script/native_performance_baseline.sh DIR` | pass, 37 files (every section at 900 and 1,400 pt, text 1.0 and 1.3, light, dark, Increase Contrast); the harness needed one fix for the event card's new expansion API (in #884) |
| `script/design_lint.sh` | pass, 17 baseline deviations unchanged |

## 7. Performance budgets

`./test.sh --performance-baseline` (median ms), against the 30 October record and the 2 October budgets:

| Operation | 30 Oct `83d5046` | This run | Budget |
| --- | ---: | ---: | ---: |
| Unchanged clustering pass | 13.8 | 4.9 | 16 |
| Refresh collection (five mocked feeds) | 415.7 (nine repeats) | 139.7 | 720 |
| Dense clustering, 200 reset rows | 20,233 | 21,102 | 20,200 |
| Overview generation | 35.9 | 24.9 | 33 |
| Snapshot hydration, first 500 | 75.6 | 35.7 | 100 |

Dense clustering is 4% over its budget, as it was on 30 October (0.2% over); the run overlapped a pre-commit test
run of #884 on the same machine. Acknowledged by the release owner as unchanged, not a regression of this release.

List invalidation (`NEWS_NATIVE_BODY_COUNTS=1 NEWS_NATIVE_HARNESS=Tests/ListInvalidationBaseline.swift`), `main`
against #884: per refresh, article card renders 45 → 3 (list) and 160 → 7 (reader open), event cards 15 → 1 and
40 → 2; scroll frame median 9.6 → 9.3 ms. Main-view and list-body renders unchanged (6 and 15 per refresh).

`./script/native_performance_baseline.sh` (seeded 10,000-story library, offscreen window): time to first card
median 388 ms (10 October record: 450 to 590 ms), scroll frame capture median 94.5 ms (10 October: 158 to 240 ms),
peak RSS 577 MB. Refresh of one mocked feed into that library: 67.7 s, against 127 to 238 ms in the 10 October record; the same run on `main` `442ccec` takes 76.5 s, so this predates #884. The time is the clustering wait after collection; filed as #893 (v3, Epic K). Acknowledged by the release owner as a known regression that does not block the tag: collection, the list and the reader are unaffected, and notifications arrive about a minute after the refresh.

`script/launch_baseline.sh` was not run: it launches the app bundle repeatedly in a window.

## 8. Privacy manifest and documentation consistency

`testDistributionAndEntitlementsIntegrity` passed. README now names EventMatcher v15 and World Tension methodology v3
(it said v11 and v2). The remaining docs drift listed in ADR-001 action 7 (`docs/ARCHITECTURE.md` historical
"matcher v12" measurement line, the 28 October roadmap's schema numbers) is #569, v3. `python3 script/changelog_fold.py`
folded 121 entries from 102 fragments; the heading is now "2.0.0 — 31 October 2026" with an empty Unreleased above it.

## Forensic sweep

A read-only forensic agent (`.claude/agents/forensic.md`, #891) swept `main` `442ccec`. Seven defects: the counts
cache ignored mute rules on a read toggle (a #880 regression, fixed in #884); #885 (feed batch dropped on conflicting
identity aliases, pre-existing since 1 October, high), #886, #887, #888, #889, #890 filed for v3. None of the six is a
v2 regression; #885 is the one the release owner may want to pull forward.

## Cutting the tag

After #884, #892, #891 and this record merge, on a clean checkout of `main` at the confirmed commit: `git tag -f v2.0.0
HEAD` (the local tag from 30 October points at `8d94d38`; `-f` moves it, since a plain `git tag` fails when the tag
exists), `./build_release.sh`, check `News.app/Contents/Info.plist` says 2.0.0 and `lipo -archs` says arm64. Pushing the
tag runs `release.yml` and publishes the GitHub release (#567); that push is the owner's decision.

## Final confirmation

Merged `main` `10cf74f` (#884, #892, #891, #894 squash-merged on 31 October): `NEWS_TEST_FORCE=1 ./test.sh` all tests
passed, `./build.sh` passed. `git tag -f v2.0.0 HEAD` moved the local tag to `10cf74f`; `./build_release.sh` there
produced News.app 2.0.0 (982), arm64, `codesign --verify --deep --strict` clean. The tag is not pushed: that publishes
the release and is the owner's step, followed by the install steps of the 30 October plan.
