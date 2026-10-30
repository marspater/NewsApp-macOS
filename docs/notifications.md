# Notification delivery rules (#665)

These rules decide which new stories become banners in **Full** notification mode. They are written before the code
and are the contract the tests check. Minimal and Privacy modes are unchanged: one summary banner per delivery pass,
not counted by any lane.

## Separation of concerns

- Ingestion stores every fetched story. Clustering groups stories into events. Delivery only reads.
- Delivery never deletes, hides or edits an article, an event or an article's state. Its only writes are the three
  side tables below. A story that is deduplicated, throttled or over a limit stays in the database, the feed and the
  Briefing exactly as before.
- Muted stories (`MuteRules`) and duplicate rows (`article_reconciliations`) are filtered before delivery, as today.

## Inputs to one delivery pass

A pass runs after a refresh has ingested and clustered (`FeedManager`, unchanged). It receives the new, visible,
unmuted stories of that refresh, each with its event (if clustered), the event's publisher count, the reader's top
three interests and the starred feeds (at most three, #588). Passes run one at a time: the coordinator is serial, and
a second pass waits until the first has finished posting.

## Scores and the dedupe key

- **Score**: `NotificationService.computeImportance`, computed once per story (#545).
- **Dedupe key**: the story (#581, #740) the report's event belongs to; the event id when the event is its own
  story; otherwise, for a report outside any event, the report's id. Two events of one story share a key, so a story
  yields at most one banner per pass, in exactly one lane, threaded under the story. Announcements and waiting
  priority keys stay recorded per event; a waiting key drops out when its story is covered.
- **Full-weight signal word**: a word of weight 1 in `breakingSignals` ("breaking", "killed", "earthquake", …), not
  the half-weight announcement words.

## Lanes

Each key is classified into the highest lane it qualifies for. Order: **priority > starred > normal**.

### Priority: exceptional news

A key is priority when its representative story has all three:

1. score ≥ **0.75** (breaking is 0.6);
2. a full-weight signal word in its **headline**;
3. an event with **≥ 4 distinct publishers** (counted when the story arrives).

A story outside any event is never priority: one outlet's report is not yet exceptional. The on-device importance
model is not used: it is unavailable on some Macs and refuses harsh news (`FoundationModels` guardrails), and this
rule must behave the same everywhere.

Measured on a read-only copy of the reader's library, 11–25 October 2026. The app ingested on 6 of those days. Run it
again with `test_runner --notification-priority-live <backup> <output>`.

- With ≥ 3 publishers the rule fired 14 times: 5 times on 18 October and 6 on 24 October. That included a fire at
  the Eagle's Nest and a politician praising a bystander, which are not exceptional.
- With ≥ 4 publishers it fires 5 times, at most 3 a day:
  - 18 Oct: Ukrainian drone attack on Saint Petersburg kills one, sets refinery ablaze (4 publishers); Masked settlers
    attack European diplomats in occupied West Bank (5).
  - 24 Oct: West Bank attack wounds 5 Israelis as Netanyahu cancels events (5); Pakistan denounces 'heinous' church
    attack in Jordan (5); China: Panic as 7.0-magnitude earthquake rocks Tibet (4).
  - 20, 21, 22 and 25 Oct: none.
- It no longer catches the Pakistan school collapse (32 pupils killed) or the Houthi attack that killed 58, which had
  3 publishers on arrival. They still notify in the normal lane as breaking stories.

Banner: the headline, active interruption level, with sound. Thread: the dedupe key.

### Starred: every story from a starred feed

A key is starred when it is not priority and any of its new stories comes from a starred feed. Every such story is
eligible, and a feed never gets a banner per story:

- **Coalescing window: 20 minutes per feed.** A feed gets at most one starred banner per 20 minutes.
- **Pending stories**: the feed's visible, unmuted stories with `created_at` after the latest of three times:
  - its last starred banner;
  - the time the feed was starred (`starred_feed_times` in `AppSettings`, next to the starred set), so starring a
    feed never dumps its backlog;
  - now − 24 h.

  Every pending story counts, including stories whose event is already announced or that the priority lane takes in
  the same pass. N is the feed's true count of new stories.
- A pending story is **fresh** when its key could post an individual banner now (see "Repeated events"): not
  announced, or announced only in a lower lane. A starred feed's report of an event announced only in the normal lane
  is fresh (normal → starred). One announced in the starred or priority lane is not.
- When a pass runs, the feed's window has passed and at least one pending story is fresh:
  - **one pending story**: an individual banner (its headline, thread = its dedupe key);
  - **two or more**: one grouped banner, with:
  - title: the feed's name (the stories' publisher name);
  - body: `N new stories`, a line break, then two headlines, each on its own line: fresh stories first, highest
    score first;
  - thread: `starred-` + the feed URL; identifier: `starred-` + feed URL + delivery time, so groups do not replace
    each other;
  - passive interruption level, no sound.
- When the window has not passed, or no pending story is fresh, nothing is posted for that feed. Its stories stay
  pending and count in the feed's next starred banner.
- A starred banner announces the events of its fresh stories in the starred lane.

Starred banners do not count against the normal limit.

### Normal: today's rules, rolling limit

A key is normal when it is neither priority nor starred and its representative is breaking (score ≥ 0.6), or is in
one of the top three interests with ≥ 3 publishers on its event (#588, unchanged).

- **Limit: 5 normal banners in any rolling 60 minutes**, counted from recorded deliveries (below), so neither a refresh
  nor a relaunch resets it.
- A pass may post `5 − (normal banners delivered in the last 60 minutes)` normal banners, highest score first.
- Banner: as #587. Active with sound when breaking, passive otherwise. Thread: the dedupe key.

## Precedence and dedupe across lanes

1. Group the pass's stories by dedupe key.
2. Classify each key into its highest lane. The representative is the story that qualifies the key for that lane,
   highest score first; for a starred key, a starred feed's story.
3. Drop keys announced earlier (next section), unless the lane rises.
4. Post in lane order: priority, then starred, then normal. Lower lanes never use a higher lane's allowance, and each
   lane has its own limit, so normal traffic can never crowd out a priority or starred banner.

## Repeated events (24 h)

An event is **announced** when any banner (individual or grouped, any lane) has covered one of its stories in the last
24 hours (`event_notifications`, #545). Within those 24 hours, its new reports post no banner in any lane, except:

- its lead headline changed (#545): the event notifies again, in the lane it now qualifies for;
- it now qualifies for a **higher lane** than the highest lane it was announced in (normal → starred or priority,
  starred → priority): one banner in the new lane.

**Stories (#740).** A new event of a story another of whose events is announced adds to that story and posts no
banner, unless it qualifies for a higher lane than the highest lane any event of the story was announced in. The story
then appears in the app, not as a second alert.

**Merged events.** When clustering merges an event into another (fragment merge #541, "Same Event as…" #524), the
absorbed event's announcement of the last 24 hours moves to the event it joined, keeping its time and highest lane.
The moved announcement records the survivor's lead headline as it is now, unless the survivor has its own
announcement from the last 24 hours, which it keeps. A merge alone never makes an announced story new again, and only a
later change of the survivor's lead headline notifies again. A waiting priority key moves to the survivor the same way;
a survivor that already waits keeps its own key. `notificationLedger` settles both tables at the start of each pass.

This replaces #649's rule that a starred feed bypasses the 24 h dedupe. A starred report of an event announced in the
starred or priority lane posts no individual banner. It still counts in the feed's next grouped banner's N (see
"Starred").

## Priority bursts

Several exceptional events within minutes:

- **At most 3 individual priority banners in any rolling 30 minutes.**
- Further priority keys in a pass while that limit is reached: **one grouped priority banner** for the pass.
  - Title: `Major news`.
  - Body: `N more major stories`, a line break, then the two highest-scoring headlines.
  - Thread: `priority`; identifier: `priority-` + delivery time.
  - Active, with sound.
- At most one grouped priority banner per 30 minutes. Priority keys that arrive while both limits are reached are
  never silenced:
  - they stay **pending** in `notification_priority_queue`;
  - they go into the next grouped priority banner, at the first pass after its 30-minute window passes;
  - they count as announced only once a banner covers them;
  - a pending key expires after 24 h, and the story stays in the app.
- A pending key whose event a banner covers in the meantime (for example a starred banner) leaves the queue.

## Over the limit

| Lane | What happens to a candidate over its limit |
|---|---|
| Priority | Goes into the pass's grouped priority banner. Past that, stays pending for the next grouped banner (24 h). |
| Starred | Stays pending and counts in the feed's next starred banner after the 20-minute window. |
| Normal | No banner, not queued, never summarized later. It stays in the feed and the Briefing. |

Nothing is deleted or hidden in any case.

## Worst case per hour

| Lane | Most banners in one hour |
|---|---|
| Priority | 6 individual + 2 grouped (3 + 1 per 30 minutes) |
| Starred | 3 per feed (one per 20 minutes), so 9 for three feeds |
| Normal | 5 |
| Total | 22, in an hour with several exceptional events and three busy starred feeds |

## Storage

Three side tables, created with `CREATE TABLE IF NOT EXISTS` on open, with no `user_version` (the side-table approach
Mars approved for #545 on 26 Oct):

- `event_notifications(event_id PRIMARY KEY, notified_at, lead_key, lane)`: exists (#545). Gains `lane`: 0 normal,
  1 starred, 2 priority. A database from an earlier build gets the column through one guarded `ALTER TABLE`. Written
  for every event a banner covers, including each event in a grouped banner, and under the report's own id for a
  report outside any event (#790); when that report later joins an event, the row moves to the event on the next read,
  as a merged event's row does, so the event counts as announced. Within 24 h it keeps the highest lane.
- `notification_deliveries(id INTEGER PRIMARY KEY, lane INTEGER NOT NULL, grouped INTEGER NOT NULL, feed_url TEXT,
  story_count INTEGER NOT NULL, delivered_at REAL NOT NULL)`: one row per posted banner. `feed_url` is set for starred
  banners. Rows older than 7 days are pruned on write.
- `notification_priority_queue(event_id PRIMARY KEY, title, score, lead_key, queued_at, story_id)`: pending priority
  keys (section "Priority bursts"). `story_id` is the story that qualified the key (#584), added to older databases
  through one guarded `ALTER TABLE`, empty on rows they queued. Rows older than 24 h are dropped on read.

Reads:

- the normal limit counts normal rows in the last 60 minutes;
- the priority limits count individual and grouped priority rows in the last 30 minutes;
- a starred window reads the feed's latest starred row;
- an event's announced lane and lead key come from `event_notifications` in the last 24 h.

A banner is recorded **immediately after it posts**, before the 2-second pause of #587, so quitting mid-pass loses no
count. A banner whose post fails is not recorded and counts toward nothing.

## What other features read

- **Story actions** (#560): a story's own banner carries the `ARTICLE_ACTIONS` category (Save, Mark as Read, Open).
  Grouped banners stand for several stories and carry none; clicking one opens the app.
- **Notified stories** (#584): `FeedManager.notifiedStoryIDs` holds every story a posted banner covered since launch:
  an individual banner's story, a grouped starred banner's pending stories and a grouped priority banner's stories.
  It is in memory only and resets at launch. Minimal and Privacy modes add nothing to it.

## Simultaneous arrivals

One refresh brings a priority earthquake (5 publishers), a starred feed's report of the same earthquake, three
starred stories from that feed about other things, and eight normal breaking stories, with 2 normal banners already
delivered in the last hour.

- The earthquake key is priority and posts one priority banner; the starred report of it is part of that key.
- The other three starred stories post one grouped banner, `3 new stories`.
- 3 of the 8 normal stories post, highest score first.
- Posting order: priority, starred, normal, 2 seconds apart.

## Busy starred feed

- 20 stories in one refresh: one grouped banner, `20 new stories`, never 20 banners.
- Five refreshes an hour (at 0, 12, 24, 36 and 48 minutes, 4 stories each):
  - 0 min: banner (4);
  - 12 min: silent, pending;
  - 24 min: banner (8: the 12- and 24-minute stories);
  - 36 min: silent;
  - 48 min: banner (8).
  - That is at most 3 banners an hour for the feed, and 9 for three starred feeds, with no story missing from a count.

## Permission

News does not ask for notification permission at launch (#562). `NotificationPermissionRequest` asks once per launch,
when a refresh has completed and the library holds stories, the first-launch sheet has closed and notifications are
on. Whichever comes last triggers it: a later refresh that brings the first stories, the sheet closing, or turning
notifications on. Notification categories and the delegate are still set up at launch, so
banner actions keep working. macOS shows the prompt only once; later requests return the saved answer.

## Relaunch

All limits, windows and announced events are read from the two tables, so a relaunch changes nothing. A refresh
straight after launch sees the same 60-minute normal count, the same starred windows and the same announced events
as before quitting.

## Clock

Windows use the wall clock (`Date`), because they must survive relaunch and reboot.

- **Clock set back**: a recorded time later than now, in any of the three tables or in a star time, is rewritten as
  now when read. The window
  then lasts at most its normal length from the change (60 minutes for normal), never until the clock catches up.
- **Clock set forward**: windows end early. That is accepted: it only lets banners through sooner, and loses
  nothing.

## Settings copy

Settings › Notifications (Full mode) states the rule in one sentence: major news covered by four or more publishers
always notifies, starred feeds are grouped, and other breaking or top-interest stories notify at most five times an
hour. The sentence follows DESIGN.md
section 17, and the PR carries the DESIGN.md checklist.

## What this supersedes

- #588's five-banner budget per refresh. It becomes the rolling 60-minute normal limit.
- #588's uncapped starred path and #649's starred bypass of the 24 h dedupe. They become the starred lane above.
- The three-starred-feed cap (#588) stays.

## Appendix: priority measurement, 11–25 October 2026

Every visible clustered story created in the window, each event counted on its first qualifying story, with the
publishers its event had when that story arrived. 1,573 stories; the app ingested on the dates listed.

With ≥ 3 publishers (rejected; 14 keys):

- 2026-10-18: 5
  - 0.80, 3 publishers: Trump says armed bystander who killed US school shooter a 'great hero'
  - 0.80, 4 publishers: Ukrainian drone attack on Saint Petersburg kills one, sets refinery ablaze
  - 0.75, 5 publishers: Masked settlers attack European diplomats in occupied West Bank
  - 0.75, 3 publishers: Pakistan: Classrooms reduced to rubble in deadly school disaster, at leat 32 pupils killed
  - 0.75, 3 publishers: Israeli settlers attack European diplomats, beat up French mayor
- 2026-10-20: 1
  - 0.75, 3 publishers: Houthi attack on Yemeni government forces kills 58: officials
- 2026-10-21: 1
  - 0.80, 3 publishers: Police arrest French suspect in Limoges after town hall arson attack
- 2026-10-22: 0
- 2026-10-24: 6
  - 0.90, 3 publishers: Jordan king orders 'iron fist' response to deadly church attack
  - 0.85, 5 publishers: Pakistan denounces ‘heinous’ church attack in Jordan, reiterates condemnation of terrorism
  - 0.80, 4 publishers: China: Panic as 7.0-magnitude earthquake rocks Tibet
  - 0.80, 3 publishers: Romania blames Russia for new deadly attack on ship
  - 0.75, 3 publishers: Man arrested after fire at Hitler's mountaintop Eagle's Nest retreat
  - 0.75, 3 publishers: Netanyahu orders West Bank closure, warns of major military operation after attack kills Israeli soldiers
- 2026-10-25: 1
  - 0.80, 3 publishers: Israeli strike on Gaza university kills 3; another 4 Palestinians killed in other attacks

With ≥ 4 publishers (adopted; 5 keys):

- 2026-10-18: 2
  - 0.80, 4 publishers: Ukrainian drone attack on Saint Petersburg kills one, sets refinery ablaze
  - 0.75, 5 publishers: Masked settlers attack European diplomats in occupied West Bank
- 2026-10-20: 0
- 2026-10-21: 0
- 2026-10-22: 0
- 2026-10-24: 3
  - 1.00, 5 publishers: West Bank attack wounds 5 Israelis as Netanyahu cancels events
  - 0.85, 5 publishers: Pakistan denounces ‘heinous’ church attack in Jordan, reiterates condemnation of terrorism
  - 0.80, 4 publishers: China: Panic as 7.0-magnitude earthquake rocks Tibet
- 2026-10-25: 0
