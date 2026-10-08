# Story curation and image completion — 9 October 2026

The installed library was opened read-only and copied with SQLite's backup API to `/private/tmp/news-story-live/library.sqlite3`. All ratings, migrations, expiry and image writes occurred in that copy. The installed app, subscriptions, saved stories and reading history were not replaced. No sealed corpus or holdout predictions were read or replayed.

## Importance

The snapshot had 1,611 stored rows, 1,609 visible publications after migration/reconciliation, and 667 publications in the active 72-hour window. Every active publication received a plain-text on-device rating: 158 major, 444 notable, 65 minor; zero remained unrated. The waiting predicate hid 64 publications. **Zero rated major publications were hidden.** This audits the predicate and this sample; model ratings are judgments, not independent truth labels. Membership was the copied library's existing membership, not a newly replayed clustering evaluation.

All 65 minor ratings were reviewed locally. No clear major story was found among them. Borderline general-interest cases for Mars's review are BBC Radio 4 programme cuts, arrests for suspected trespass at an RAF base, and a flour-price increase. The local `ratings-private.json` retains the full review material; publisher summaries are not committed or included in public PRs.

Curation now rejects a result if the headline or feed summary changed during inference. Notification triage waits for clustering/curation and reads the waiting predicate from committed storage. Unrated stories remain eligible. Feed collection publishes and ends its spinner before this follow-up work; a second refresh can collect while triage is running.

## Images

On that rated copy, 473 displayed event/publication cards were eligible in the active window. Before protected publisher-page lookups, 338 had a usable lead URL (71.5%). After bounded passes, 466 had one (98.5%): **128 additional cards**, with the same denominator. There were 132 completed page lookups and 130 found declarations; the recurrence filter conservatively cleared shared site-default candidates. Each pass kept the production limit of 30, and completed misses were remembered.

Requests use the production protected client, retain at most 256 KiB and cancel the remaining response. The finder reuses charset handling, accepts Open Graph, Twitter and schema.org article images, skips muted/waiting stories, and rejects a stale URL result. Shared database hydration exposes the result to Briefing and every member lookup. Event cards rank all members' curated leads by known size, then publisher host, while excluding logos and extreme aspect ratios. A publisher without a usable declaration retains the existing placeholder; this does not promise an image from every page.

All 128 retained page-derived image URLs then downloaded and decoded through `SecureHTTPClient.fetchReaderImage`; zero failed. The isolated ad-hoc bundle was launched as `com.marspater.news.storycheck` with its own container, seeded from the audited copy. Its rendered Today list showed publisher images and the waiting count; revealing waiting stories changed the list and the control to “Hide … waiting”, and hiding them restored the control. The verification instance also refreshed real feeds. This visual spot check does not establish rendering of all 473 cards.

## Verification

- Visibility: focused story regressions, full suite and mandatory commit hook passed. Isolated arm64 ad-hoc bundle built; strict signature and plist checks passed.
- Visibility UI harnesses: native UI 73/73, reader 26/26, overview 49/49. These are automated harness checks, not a spoken VoiceOver pass (parked #268).
- Image focused regressions passed, including mocked protected HTTP prefix limits, legacy encoding, schema.org, rejected-logo fallback, storage hydration and member-size selection.
- Image staged arm64 build and strict signature passed; native UI 73/73, reader 26/26 and overview 49/49 harnesses passed. The mandatory full commit hook passed.

The live core harness and staged bundle are distinct evidence. No installation, distribution, hosted CI success or merge is claimed by these local checks.
