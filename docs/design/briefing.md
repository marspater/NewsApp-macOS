# Briefing

How the Briefing looks and behaves: the five pillars, module composition, editorial structure, the carousel's content and generated-content labels. [DESIGN.md](DESIGN.md) holds the design language this extends, and its section 8.4 points here.

Briefing is a war room presenting the day's essential intelligence, selected once daily at the configured edition hour (default 7:00 AM) and frozen across all windows until the next edition or explicit New Briefing. The approved look is [`docs/mocks/briefing/war-room-dark.jpg`](../mocks/briefing/war-room-dark.jpg), exported on 9 November 2026 from the design canvas approved on 31 October. It illustrates these rules; where it and this document disagree, this document wins.

The toolbar holds Back, the title "Briefing" with its edition line (date, edition selection time, last update), Customize Briefing and New Briefing. Under the title, a status line counts stories read, priority developments and active story threads. Below it, Briefing is an ordered list of modules grouped under five pillars, in this order:

| Pillar | Question |
| --- | --- |
| Situational awareness | What is happening right now? |
| Intelligence assessment | What does the reporting show? |
| Strategic impact | What could this affect? |
| Weak signals | What might we be missing? |
| Forward watch | What should we monitor next? |

**Module shell**:
- A pillar header shows the pillar's icon, its name in `AppTypography.eyebrow` (uppercase by `.textCase(.uppercase)`) and its question in `AppTypography.callout`, secondary color, with the header trait.
- Every module uses one module card style: `AppColor.surface`, `AppRadius.card`, `AppSpacing.md` inner padding, a separator-color hairline and the resting shadow token. The shared header carries the module title in `AppTypography.sectionTitle` and an options menu (`⋯`). No module draws its own frame.
- A module with no data is hidden, never shown empty. Hiding a module never reflows another pillar.
- **Layout rule**: Modules size to their available space (#1211). In wide windows (≥ 900 pt), Situational awareness presents a two-column layout: the Hero carousel takes two-thirds width on the left with the Executive sitrep positioned directly beneath it at hero width, filling the vertical space beside the right column (World Tension and Since your last briefing) without leaving an empty band. In narrow windows (< 900 pt), modules stack in a single responsive column in canvas order (Hero carousel → World Tension → Since your last briefing → Executive sitrep). Hiding or disabling any module reflows remaining modules to fill the space cleanly with no gaps or holes.

**Customize Briefing sheet**: lists the modules grouped by pillar, each with a visibility toggle. Dragging reorders modules within their pillar only; hidden modules keep their place. Order and visibility are saved per Mac and survive relaunch. Reset to Default restores the original order with every module shown; Done closes the sheet.

| Component | Hierarchy & Tokens | Anatomy & Invariants |
| --- | --- | --- |
| Hero carousel | `AppLayout.leadStoryHeight` (360 pt), `AppRadius.card` (12 pt), `AppColor.leadScrim` | Situational awareness. Up to ten stories in the order set under Ranking below. Displays lead image via `bestCardImage` across all member reports. Overlay contains publisher `EyebrowText` with position ("1 of 5"), headline in `AppTypography.leadStoryHeadline` (28 pt serif), publisher count `TagView`, timestamp in `caption`, Developing pill and `UnreadDot`. Left/Right arrow controls and bottom dot indicators. |
| World Tension | `AppColor.surface`, `AppRadius.card`, `AppSpacing.md` (16 pt) inner padding | Situational awareness. Score in `AppTypography.tensionReading` (44 pt bold rounded) followed by "of 100", and the level name with its colored dot (`AppColor.tension(level)`). Below: the 7-day change ("▲ 4 in 7 days") and coverage sufficiency ("coverage sufficient"), then rising risk types as pills (`TagView`) with their trend. Ends with the gold "Assessed on this Mac" label. Data from `WorldTensionModel`, the one model shared with the sidebar and the sheet. |
| Since your last briefing | Module card, rows in `AppTypography.callout` | Situational awareness. New events, more publishers, easing or escalation since the last opened edition; each row a kind pill, the event and a `caption` meta line. Data from an edition snapshot (event id, membership version, publisher count, escalation signal). |
| Executive sitrep | Module card, numbered rows, titles in `AppTypography.headline` | Situational awareness. A 60-second read: three lines from the three top-ranked threads (the hero order), each with its publisher count and a link to the thread. Built from overview highlights by the on-device model (plain text output) with an extractive fallback; carries the gold label. |
| Priority developments | Module card per story; accent border on the lead | Intelligence assessment. Publishers · time, Developing or Updated state, headline in `AppTypography.headline`; Impact, Momentum and Original reports ("5 of 11"); a reported fact quoted with its publisher; "Accounts differ" with each side attributed; "Not yet reported"; the story thread with Open event overview. A click anywhere on the card opens the story too. Data from story importance, report rate, overview perspectives and cited highlights. |
| Source footprint | Module card, bar rows in `AppTypography.callout` | Intelligence assessment. Publisher regions (international, regional, wire agencies, official sources) for the lead story, and a line stating how many reports are original and how many carry wire text that counts once. Data from catalog feed regions and wire reconciliation. |
| What drives World Tension | Module card, rows in `AppTypography.callout` | Intelligence assessment. Event types and regions with severity and coverage shown as two separate values ("well covered", "thin coverage", "one report"). Data from the tension methodology. |
| Industry impact | Module card, sector in `AppTypography.headline` | Strategic impact. Only sectors a cited passage names across today's stories, each with one line and its source count in `caption` ("From 2 stories · 4 cited passages"). Data from overview industry impact. |
| Regions | Module card, rows with level dot | Strategic impact. Region name, top story, level and story count; selecting a region filters every module on the board. Data from tension macro regions and event places. |
| Region tiles | `AppColor.surface`, `AppRadius.card`, hairline border, resting shadow | Strategic impact. Dense tiles under a region header in `AppTypography.sectionTitle`: publishers · time in `caption`, Developing pill, headline in `AppTypography.headline`, one serif quoted fact with its publisher. The lead tile carries an accent border. Single click opens the story. |
| Weak signals | Module card, rows with reason pills | Weak signals. Low-coverage stories that also have a major rating, a link to a big thread or rising momentum; the reasons show as pills. Low coverage alone never qualifies. |
| Forward watch | Module card, rows with kind pill | Forward watch. Scheduled, expected and conditional items, each with the source of the date or condition in `caption` ("Tuesday, as reported by 3 publishers"). |
| Escalation timeline | Module card, horizontal day track | Forward watch. Turning points across one story thread, one dot per day, the largest dot for the sharpest escalation. Data from overview timeline items. |
| Completion banner | `AppSpacing.lg` padding, centered | Title in `AppTypography.sectionTitle` ("Briefing complete" or "N of M stories read"), subtitle in `caption` with edition selection time and next edition arrival time, and "Back to Today" button. |

**Honesty rules** (every module):
- Reported text and generated text never share a line. Reported passages are quoted with their publisher; generated lines carry the gold "Assessed on this Mac" label once per module.
- Copied wire text counts once: "original reports" replaces any claim of independent confirmation.
- Severity and coverage are separate values; no number combines them.
- Forward watch only lists dates and conditions a cited passage states, in the publisher's words; nothing is scheduled by the app.
- A module with no data is hidden, never shown empty.

**Back**: in Briefing the list toolbar carries the reader's Back control (`.navigation`, `chevron.left`, "Back to [section]"), returning to the section shown before the Briefing, Today if none; Navigate › Back does the same.

**Ranking.** The hero takes up to ten stories (`BriefingView.heroLimit`; fewer when the edition has fewer) in this order (`BriefingView.heroEntries`, `BriefingRanking`): original reports first (distinct publishers with their own text; copies of one wire dispatch count once per agency, so copied text cannot inflate a story), then the stored story importance where a rating exists (an unrated story ranks below a rated one), then publisher count, then edition order. The executive sitrep, priority developments, source footprint and since-last rows use the same order, so the lead story is the same everywhere. Selection reads stored ratings and never requests one; [PRIVACY.md](../../PRIVACY.md) says so.

**Carousel motion** follows [DESIGN.md section 13.1](DESIGN.md#131-hero-carousel), rotating every 10 seconds with a slow cross-fade, shared with The Lead of the Today edition.

**Empty and Completed State Copy**:
- When no unread, unmuted stories exist in the 24 h window, Briefing renders `ContentUnavailableView`: symbol `"text.book.closed"`, title "No Stories for This Briefing", description "There are no unread, unmuted stories published in the last 24 hours. Your archive and normal feed remain available.", and "Refresh Feeds" action.
- Completed state copy: "Briefing complete", subtitle "Briefing selected at [time]. The next briefing arrives at [time]. New stories stay in Today."

**Later and not planned.** Later: a regional risk map (offline, with W4 #718) and a risk velocity chart. Not planned: market reaction, which has no free, open, offline source and would need its own ADR.
