# Briefing war room

The single source of truth for the Briefing layout is the "Briefing War Room" canvas, approved on 31 October 2026:

https://claude.ai/artifact/7hHJUQX1q2evEYjh2EtfQ8

This file is a text summary only. When it and the canvas disagree, the canvas wins. Component tokens and invariants are in `docs/DESIGN.md` section 8.4.

## Toolbar

- Back
- Title "Briefing" with the edition line: date, edition selection time, last update (for example "Friday 31 October · edition selected 07:00 · updated 17:42")
- Customize Briefing
- New Briefing

Under the title, a status line counts stories read, priority developments and active story threads.

## Pillars and modules

Every module is optional, ordered by the reader, and hidden when it has nothing true to show. Pillars appear in this order; each header shows an icon, the uppercase name and the question.

### 1. Situational awareness: What is happening right now?

- **Hero carousel**: top 3–5 stories by publisher count, 45 s auto-advance. Source: `BriefingHeroCarouselView`, `bestCardImage`.
- **World Tension**: score of 100, level, 7-day change, rising risk types, coverage sufficiency, gold "Assessed on this Mac" label. Source: `WorldTensionModel` and the tension methodology's type scores and coverage.
- **Since your last briefing**: new events, more publishers, easing or escalation since the last opened edition. Source: a new edition snapshot (event id, membership version, publisher count, escalation signal).
- **Executive sitrep**: three lines from the three most-covered threads, each linked. Source: overview highlights, on-device model with plain text output, extractive fallback.

### 2. Intelligence assessment: What does the reporting show?

- **Priority developments**: impact, momentum, original reports; a reported fact, differing accounts, what is not yet reported. Source: story importance, report rate, overview perspectives, cited highlights.
- **Source footprint**: publisher regions and wire copies for the selected story. Source: catalog feed region, original wire source, article reconciliations.
- **What drives World Tension**: event types and regions, severity beside coverage. Source: tension methodology event types, macro regions, coverage.

### 3. Strategic impact: What could this affect?

- **Industry impact**: sectors named by cited passages across today's stories. Source: overview industry impact (standard sector names).
- **Regions**: level and story count per region; selecting one filters the board. Source: tension macro regions, event places.
- **Region tiles**: dense tiles per region with publishers · time, a quoted fact, Developing pill, accent border on the lead tile. Source: partly built in the #835 draft and the sketch A rework.

### 4. Weak signals: What might we be missing?

- **Weak signals**: low coverage plus a major rating, a thread link or rising momentum; low coverage alone never qualifies. Source: story importance, story layer, report rate.

### 5. Forward watch: What should we monitor next?

- **Forward watch**: scheduled, expected and conditional items stated in reporting. Source: a new extractor over cited passages, modelled on the overview timeline extractor.
- **Escalation timeline**: turning points across a story thread. Source: overview timeline items, Earlier in This Story.

Later: regional risk map (offline, with W4 #718) and risk velocity chart. Not planned: market reaction (no free, open, offline source; adding one needs its own ADR).

## Customize Briefing sheet

- Lists modules grouped by pillar, each with a visibility toggle.
- Drag to reorder within a pillar; hidden modules keep their place.
- Order and visibility are saved per Mac.
- Reset to Default; Done closes the sheet.

## Completion banner

"N of M stories read" (or "Briefing complete"), then "Briefing selected at [time]. The next briefing arrives at [time]. New stories stay in Today." and a Back to Today button.

## Honesty rules

- Reported text and generated text never share a line: reported passages are quoted with their publisher; generated lines carry the gold "Assessed on this Mac" label once per module.
- Copied wire text counts once: "original reports" replaces any claim of independent confirmation.
- Severity and coverage are separate values; no number combines them.
- Forward watch only lists dates and conditions a cited passage states, in the publisher's words; nothing is scheduled by the app.
- A module with no data is hidden, never shown empty.
