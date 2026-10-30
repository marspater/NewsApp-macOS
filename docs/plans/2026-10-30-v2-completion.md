# v2 completion (30 October 2026)

On 30 October the release scope moved: **v2 = J, L, M, N, R (done) + O (#576), Q (#607), T (#669), Y (#744)**; K, P and S moved to v3 with U–X. The aim is a correct app installed on the owner's Mac from a local `v2.0.0` tag (no GitHub release; #566/#567 stay in v3).

## What finishes each epic

| Epic | Pull requests | State |
| --- | --- | --- |
| T · Story Overview (#669) | #750 overview runners in `./test.sh` and CI · #753 Industry Impact precision (#670) · #755 "Earlier in This Story" lists the story's events (#671) · #756 offscreen captures (#669–#673) · #758 accent and tag text contrast (#754) | Captures sent; needs the owner's approval of DESIGN.md §11 and §17 and of the captures |
| Y · Improvements (#744) | #751 library backup before migration, newer-schema guard, busy timeout, migration lock (#746, #747) · #752 `make run` uses a development bundle (#749) · #757 App Intents metadata in swiftc builds (#748) · #760 replay calibration accepted (#742) · #761 matcher v14: named storms and dated round-ups (#741, #739) · #763 notify once per story (#740) · #766 carry-in measured, rule stays (#738) · #768 story country signal, off (part of #737) | #737 needs the owner's decision (see below); #769 (a load-sensitive socket test) is in the backlog |
| O · Data and onboarding (#576) | #759 export saved stories and history (#565) · #767 diagnostics export (#564, replaces #762) · #765 onboarding and permission timing (#562) · backup and restore (#563, stacked on #751) | #563 in progress |
| Q · Briefing (#607) | #764 Dock badge counts today's Briefing and notified stories (#584) | Ready |

## Decisions for the owner

- **#737 story recall.** The country signal (`NEWS_STORY_COUNTRY`) raises story precision 0.714 → 0.826 and story recall 0.106 → 0.202 on the 29 October library holdout and fixes the Jordan church case, but leaves 2.6 % wrong story groups (target ≤ 2 %) and moves the multi-publisher share 40.0 % → 40.6 % (target 60 %). It ships off. Keep the rest of #737 in v2, or move it to v3. Details: `docs/audits/2026-10-30-story-country-signal.md`.
- **Open review threads kept for the owner:** #761 all-caps storm names and the edition-word exception to the different-day veto; #751 timing of the busy-timeout test.
- **DESIGN.md rules:** §11 (accent text and tag text, #758) and §17 ("Earlier in This Story", #755).

## Merge order

All open v2 branches merge into one tree with a single trivial conflict in `CONTRIBUTING.md` (#752 and #756 each add a line in the same place; keep both). Order constraints:

1. #761 before #768 (#768 is stacked on #761).
2. #751 before the backup-and-restore PR for #563 (stacked on #751).
3. Everything else in any order.

## Verified before merging

The combined tree of every open v2 branch (all of the above except #768, which is off by default, and #563) passed `NEWS_TEST_FORCE=1 ./test.sh`, including the three standalone headless runners, with `NEWS_SNAPSHOT_DB` set to a copy of the owner's library:

| Library copy | Before | After |
| --- | --- | --- |
| Schema version | 25 | 27 |
| Stories | 6,400 | 6,400 |
| Read | 115 | 115 |
| Saved | 0 | 0 |
| Pre-migration backup | — | `news-before-v25-2026-10-30.sqlite3` beside the library, owner-only (0600), plus an empty `news.sqlite3.migration-lock` |

The owner's library was backed up read-only first to `~/news-eval/library-pre-v2-2026-10-30.sqlite3` (0444), with `library-pre-v2-2026-10-30.world-tension-v2.json` and `com.marspater.news-pre-v2-2026-10-30.plist` beside it.

## Install (after the merges)

1. On a clean checkout of the merged `main`, run `git tag v2.0.0`. **Do not push the tag:** pushing runs `release.yml`.
2. Run `./build_release.sh` and check that `News.app/Contents/Info.plist` says 2.0.0.
3. Quit News, then replace the installed app:

   ```bash
   ditto News.app /Applications/News.app
   ```

4. Launch it once from `/Applications`. Check that stories list, that the read count matches (115 at backup time), and that `news-before-v25-…sqlite3` appeared next to the library in `~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/`.
5. Check that Shortcuts lists the News actions (#748).
6. Remove stray copies (`~/Projects/News/News.app`, worktree builds) so `feed://` and `news://` open the installed app.

**Rollback:** quit News, copy `~/news-eval/library-pre-v2-2026-10-30.sqlite3` over `news.sqlite3` (and remove `news.sqlite3-wal` and `news.sqlite3-shm`), restore the tension file, and reinstall the previous app. The newer-schema guard (#751) keeps an older build from writing to a v27 library.

## Close-out

After the install: close #576, #607, #669 and #744 (or move #737's remainder to v3 first), set every v2 item to Done on board #2, and record the install in this file.
