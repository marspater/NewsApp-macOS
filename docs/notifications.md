# Notification delivery rules (#665)

These rules decide which new stories become banners in **Full** notification mode. They are written before the code
and are the contract the tests check. Minimal and Privacy modes are unchanged: one summary banner per delivery pass,
not counted by any lane.

## Separation of concerns

- Ingestion stores every fetched story. Clustering groups stories into events. Delivery only reads.
- Delivery never deletes, hides or edits an article, an event or an article's state. Its only writes are the two
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
- **Dedupe key**: the story's event id when it is in an event, otherwise the story id. One key yields at most one
  banner per pass, in exactly one lane.
- **Full-weight signal word**: a word of weight 1 in `breakingSignals` ("breaking", "killed", "earthquake", …), not
  the half-weight announcement words.

## Lanes

Each key is classified into the highest lane it qualifies for. Order: **priority > starred > normal**.

### Priority: exceptional news

A key is priority when its representative story has all three:

1. score ≥ **0.75** (breaking is 0.6);
2. a full-weight signal word in its **headline**;
3. an event with **≥ 3 distinct publishers**.

A story outside any event is never priority: one outlet's report is not yet exceptional. The on-device importance
model is not used: it is unavailable on some Macs and refuses harsh news (`FoundationModels` guardrails), and this
rule must behave the same everywhere.

Banner: the headline, active interruption level, with sound. Thread: the dedupe key.

### Starred: every story from a starred feed

A key is starred when it is not priority and any of its new stories comes from a starred feed. Every such story is
eligible, and a feed never gets a banner per story:

- **Coalescing window: 20 minutes per feed.** A feed gets at most one starred banner per 20 minutes.
- **Pending stories**: the feed's visible, unmuted stories with `created_at` after its last starred banner (at most
  24 h back), minus stories whose key is announced (see "Repeated events") or taken by the priority lane.
- When a pass runs and the feed's window has passed: one pending story gives an individual banner (its headline,
  thread = its dedupe key). Two or more give **one grouped banner**:
  - title: the feed's name (the stories' publisher name);
  - body: `N new stories`, a line break, then the two highest-scoring headlines, each on its own line;
  - thread: `starred-` + the feed URL; identifier: `starred-` + feed URL + delivery time, so groups do not replace
    each other;
  - passive interruption level, no sound.
- When the window has not passed, nothing is posted for that feed. Its stories stay pending and are counted in the
  feed's next starred banner, at the first pass after the window ends.

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

This replaces #649's rule that a starred feed bypasses the 24 h dedupe. A starred report of an announced event stays
in the app and is not counted in a later grouped banner.

## Priority bursts

Several exceptional events within minutes:

- **At most 3 individual priority banners in any rolling 30 minutes.**
- Further priority keys in a pass while that limit is reached: **one grouped priority banner** for the pass.
  - Title: `Major news`.
  - Body: `N more major stories`, a line break, then the two highest-scoring headlines.
  - Thread: `priority`; identifier: `priority-` + delivery time.
  - Active, with sound.
- At most one grouped priority banner per 30 minutes. Priority keys beyond that are announced silently: they are
  recorded in `event_notifications`, so later reports do not notify, and they stay in the app.

## Over the limit

| Lane | What happens to a candidate over its limit |
|---|---|
| Priority | Goes into the pass's grouped priority banner. Past that, recorded as announced, no banner. |
| Starred | Stays pending and counts in the feed's next starred banner after the 20-minute window. |
| Normal | No banner, not queued, never summarized later. It stays in the feed and the Briefing. |

Nothing is deleted or hidden in any case.

## Storage

Two side tables, created with `CREATE TABLE IF NOT EXISTS` on open, with no `user_version` (the side-table approach
Mars approved for #545 on 26 Oct):

- `event_notifications(event_id PRIMARY KEY, notified_at, lead_key)`: exists (#545). Written for every event a banner
  covers, including each event in a grouped banner and priority keys announced silently.
- `notification_deliveries(id INTEGER PRIMARY KEY, lane TEXT NOT NULL, dedupe_key TEXT, feed_url TEXT,
  story_count INTEGER NOT NULL, delivered_at REAL NOT NULL)`: one row per posted banner. `dedupe_key` is set for
  individual banners, `feed_url` for starred banners. Rows older than 7 days are pruned on write.

Reads:

- the normal limit counts rows with `lane = 'normal'` in the last 60 minutes;
- the priority limit counts `lane = 'priority'` rows (individual or grouped) in the last 30 minutes;
- a starred window reads the feed's latest `lane = 'starred'` row;
- the highest announced lane of an event reads its rows in the last 24 h.

A banner is recorded **immediately after it posts**, before the 2-second pause of #587, so quitting mid-pass loses no
count. A banner whose post fails is not recorded and counts toward nothing.

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

## Relaunch

All limits, windows and announced events are read from the two tables, so a relaunch changes nothing. A refresh
straight after launch sees the same 60-minute normal count, the same starred windows and the same announced events
as before quitting.

## Clock

Windows use the wall clock (`Date`), because they must survive relaunch and reboot.

- **Clock set back**: a recorded time later than now is treated as now when read and rewritten as now. The window
  then lasts at most its normal length from the change (60 minutes for normal), never until the clock catches up.
- **Clock set forward**: windows end early. That is accepted: it only lets banners through sooner, and loses
  nothing.

## Settings copy

Settings › Notifications (Full mode) states the rule in one sentence: exceptional news always notifies; starred feeds
are grouped; other breaking or top-interest stories notify at most five times an hour. The sentence follows DESIGN.md
section 17, and the PR carries the DESIGN.md checklist.

## What this supersedes

- #588's five-banner budget per refresh. It becomes the rolling 60-minute normal limit.
- #588's uncapped starred path and #649's starred bypass of the 24 h dedupe. They become the starred lane above.
- The three-starred-feed cap (#588) stays.
