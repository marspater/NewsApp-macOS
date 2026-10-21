# State of the app and next development — 21 October 2026

Status: executed on 21 October 2026; every slice is an open PR awaiting review (outcomes in section 8). Base: `origin/main` at `1c1f05e`. Evidence: repository, GitHub, CI, and a read-only copy of the real library (snapshot 20 October 2026 19:21 UTC; private titles not reproduced).

## 1. Where the app stands

**Shipped and green.** CI and Security pass on `main`. Locally on 21 October: `./test.sh` passed, `./build.sh` produced a signed arm64 bundle with no warnings, and `script/format.sh --check` passed (window-opening harnesses not run). No pull requests are open. The only open issues are the two parked ones (#264 non-English matching, #268 live VoiceOver). The 18 October acceptance audit closed every 1.0 blocker (#307, #308, #309, #334, #435). Design-language phases 1–7 were accepted on 10 October.

**Product surface today.**
- Feed ingestion: RSS/Atom/JSON via FeedKit behind the streaming XML safety boundary; conditional requests, per-feed backoff, host limits, sleep/wake handling.
- Reader: v8 extraction (SwiftSoup selection, DOM repair, JSON-LD/Next.js fallbacks, subscriber-only and 403 previews), protected Web view, text size and reading styles.
- Stories: EventMatcher v7 (deterministic gates plus on-device MiniLM rescue/veto), event cards, publisher-excerpt overviews with citations, Highlights, Perspectives, Timeline, Earlier in This Story (#314).
- Briefing as a daily frozen edition; muting; notifications with image attachments; World Tension v2; starter catalog (English only).

**Size.** 32.6k lines of Swift in `Sources/`. The largest files are `DatabaseEngine.swift` (4,654), `ArticleDetailView.swift` (1,757), `ContentExtractionPipeline.swift` (1,685), `ArticleIntelligence.swift` (1,276) and `ArticleListView.swift` (1,201).

**Version.** `build.sh` stamps 2.0.0 (build 3). The repository has no tags and no GitHub releases, so `UpdateChecker` has nothing to compare against. Distribution stays dormant by policy.

## 2. Real-library findings

Copy of the user library: schema v23, 3,955 articles, 19 feeds rows (12 subscriptions plus panel feeds), 1,561 articles collected in the last five days.

| Finding | Evidence | Impact |
|---|---|---|
| Broken subscription | The Feedspot proxy for Popular Mechanics has 5 consecutive failures and was never fetched. | Dead row in the sidebar; refresh wastes a slot. |
| Paywalled subscription | Financial Times: 78 stories in five days, 1 with publisher text. | Conflicts with the free-and-open sources rule; most FT stories open to a subscriber card. |
| Missing card images | First count: 128 of 1,561 recent stories with neither a feed image nor a curated one. Corrected in slice 3: most of them sit in events whose card shows another member's image; only 6 of 1,006 cards from the last 72 hours show a placeholder (99.4% coverage). | No change needed. |
| Reader outcome not measurable | Extraction runs on open and failures are not stored, so the library cannot show a per-publisher failure rate. | "Do articles open?" needs a live catalog run instead of a library query. |
| Clustering coverage | 368 events (348 with two or more members, largest 23); 29% of recent articles are in an event; 32 stored overviews. | Healthy for an English library; no action. |

## 3. Unshipped branches kept during cleanup

| Branch | Content | Recommendation |
|---|---|---|
| `claude/elated-cerf-338000` | Keep meaningful trailing slashes on subscription URLs; slash-insensitive duplicate checks. Some publishers answer the slashless URL with 403/404 or a downgrading 301. No PR. | Rebase onto `main`, re-test, open a PR. A real correctness bug. |
| `claude/event-feature-fallback` | Matching for languages without a word-class model. | Parked with #264. Keep untouched. |
| `mars/kagi-compact-layout` | Kagi Headlines layout (PR #456 closed). | Kept by Mars for a possible Briefing treatment. No action. |
| `mars/release-excerpts` | Integrated as `972253b`. | Delete (local branch; deletion needs approval). |

## 4. Gaps to "pixel perfect"

1. **Unverified appearance matrix since 10 October.** PRs #455, #457, #462 and #466 left these checklist items unticked: light, Increase Contrast, Reduce Motion, Reduce Transparency, and the narrow 900 pt window. Only dark and wide were checked live. New surfaces since then: Briefing edition masthead, Highlights/Perspectives order, Earlier in This Story, subscriber and 403 cards, standfirsts, pull quotes, lead-image blur backdrop.
2. **Card image coverage** (section 2) is the most visible imperfection in daily use.
3. **macOS 15 and 26 runtime** are compile-only (no machines). Out of scope by decision; keep CI compile.
4. **Reduce Transparency** has never been checked live because it changes a system setting; `run_isolated.sh` can simulate it.

## 5. Gaps to "perfectly working, running the articles"

1. **Feed URL normalization strips meaningful trailing slashes** (branch above).
2. **Subscriptions that break policy or never work** (FT, Feedspot) are not retired or flagged beyond feed health.
3. **No current measurement of reader success per catalog feed.** The last catalog reader-access check predates reader v7/v8.
4. **Background updates wait behind the updates button even when the cached list is from a previous day** (PR #455 limitation). On first launch of the day the list shows yesterday until the user acts.
5. **Large files** make regressions likely: `DatabaseEngine.swift` and `ArticleDetailView.swift` mix several responsibilities.

## 6. Plan

Each slice is one focused PR with `./test.sh`, `script/format.sh --check`, `./build.sh`, the DESIGN.md checklist for UI changes, and a project-board update.

### Slice 1 — Feed URL trailing slashes (P1, small)
Rebase `claude/elated-cerf-338000` on `main`; resolve against current `AppSettings.normalizeFeedURL`; keep stored subscriptions unchanged (scoped GUIDs hash the exact URL). Tests: `/feed` and `/feed/` stay one subscription; root slash still removed; OPML import dedupes.

### Slice 2 — Subscription hygiene (P1, small; needs Mars's decision)
- Retire FT (`AppSettings.retiredFeeds`, version 3), matching the NYT precedent and the free-and-open rule. Read and saved FT stories stay.
- Feedspot/Popular Mechanics: a user-added custom feed, so the app must not remove it. Mars removes it or replaces it with the publisher's own feed. Optional: a feed-health row action "Remove failing feed" after N failures.

### Slice 3 — Card image coverage (P1, medium)
- Prioritise image lookup for stories that will be shown (Briefing members and the first page of Today) before the 30-story cap applies; allow a second pass when the first pass had spare time and no energy restriction.
- Measure with `./test.sh --images-live` on a library copy before and after; target: fewer than 3% recent stories without an image for publishers that declare `og:image`.
- Keep the energy rules, the 256 KiB prefix limit and the site-default guard.

### Slice 4 — Reader success measurement and fixes (P1, medium)
- Run `./test.sh --catalog-reader-access` (live) for all English catalog feeds plus the user's subscriptions; record per-publisher text/subscriber/403/failure counts in a dated audit.
- Fix the publishers that fail for extractor reasons (not paywalls) with fixtures in `Tests/Fixtures`, one publisher per commit.
- Optional: store the last extraction outcome per article (no body) so the library can report failure rates without a live run. Only if the audit shows recurring failures.

### Slice 5 — Fresh list on a new day (P2, small)
When the cached list is older than the current edition day (or older than the refresh interval at launch), apply the first background refresh directly instead of queuing it behind the updates button. Keep the open-story stability rule.

### Slice 6 — Appearance and accessibility acceptance (P1, verification)
- Run `script/appearance_matrix.sh` (light, dark, Increase Contrast) and `script/run_isolated.sh` with Reduce Motion and Reduce Transparency over list, grid, reader, overview (with Earlier in This Story), Briefing and Settings, at 900 pt and wide.
- These harnesses open windows: run only when Mars says so, or Mars runs them.
- Fix every defect found in token-only changes; record the matrix in a dated audit and tick the outstanding checklist items from #455/#457/#462/#466.

### Slice 7 — Maintainability (P3, refactor, no behavior change)
Split `DatabaseEngine.swift` along existing extension seams (events, images, FTS, aliases) and `ArticleDetailView.swift` into reader sub-views. Pure moves, one area per PR, full regressions each time. Do this after slices 1–6 so behavior PRs do not conflict.

### Not in this plan
Parked #264 and #268; Intel or notarized builds; macOS 15/26 runtime checks; a Kagi layout for the main window; new dependencies.

## 7. Order

1 and 2 first (small, independent). 3 and 4 next (both touch publisher fetching; run them one after another). 5 after 3. 6 once 1–5 land, so the matrix covers final UI. 7 last.

## 8. Outcomes — 21 October 2026

| Slice | Result | PR |
|---|---|---|
| 1 Trailing slashes | Meaningful trailing slashes kept; slash-insensitive `feedKey` for duplicates, catalog coverage and advisories | #470 |
| 2 Subscription hygiene | FT (subscriber-only) and The Hill (HTTP 403 on every story) retired at version 3; The Hill leaves the catalog. Feedspot/Popular Mechanics is a custom subscription and stays for Mars to remove or replace | #471 |
| 3 Card images | Measured, no change: 6 of 1,006 recent cards without an image | — |
| 4 Reader success | Reader v9: Africanews, CNA, IEEE Spectrum and Science News readable 5/5; Ars Technica, NASA and Variety full text; Guardian lead figure and standfirst kept; [audit](../audits/2026-10-21-catalog-reader-access.md) | #474 |
| 5 Fresh list on a new day | Today replaces a list holding only earlier days' stories on the first refresh | #472 |
| 6 Appearance and accessibility | Appearance matrix (light, dark, Increase Contrast) and Native UI QA (Reduce Motion, 900/1600 pt) pass; overview cards now share the column width; a flaky World Tension OCR check is fixed. Reduce Transparency not checked (system setting) | #476, #477 |
| 7 Maintainability | `DatabaseEngine.swift` 4,654 → 3,395 lines (`DatabaseEngine+Events.swift`); `ArticleDetailView.swift` 1,775 → 1,542 lines (`ReaderSupportViews.swift`). The view body stays in one file to keep its `@State` private | #478, #479 |

Every PR passed `./test.sh` and an arm64 `./build.sh` locally on current `main`; none was installed over the real app. All CHANGELOG entries sit at the top of Unreleased, so the second and later merges need a one-line CHANGELOG conflict resolution.

Still open after this plan: CNA's "(Updated: …)" line at the top of the body, one short Politico subscriber page, and the parked #264 and #268.
