# Today edition: specification for sign-off (Z1, #933)

**Status:** Mars approved the mocks on 9 November 2026. Nothing in Z2–Z6 (#934–#938) starts before the design documents are approved.
**Date:** 9 November 2026
**Epic:** Z · Today edition (#932)
**Presentation:** [`docs/design/today.md`](../design/today.md) owns lanes, card variants, The Lead, scrolling, focus, updates and states, with its visual references. This document keeps the quality bars, thresholds, shadow evaluation and open decisions.

Every number below is a proposal. Z2's shadow evaluation on a real library copy (#934) is the instrument that revises the thresholds; the lanes, the rules and the interaction model are what this sign-off fixes.

## 1. What changes

Today stops being one chronological list with an inset lead card. It becomes an edition: The Lead, up to four conditional lanes, and The Latest. Each lane is a horizontal row of story cards that slides under the floating glass sidebar, modelled on Apple TV's rows and built natively. Importance decides which lane a story enters; inside a lane, time decides the order.

Out of scope, by the epic's rules: topic lanes (World, Politics, Technology; the sidebar owns them), Briefing analysis (assessments, gauges, strategic impact, weak signals), and any "From your sources" lane. Unread, Saved Stories, History, Smart Binders and search keep the existing list and grid.

## 2. Lanes

In assignment order. One story enters exactly one lane: the first whose bar it clears.

| # | Lane | One-line description (sentence case, shown under the name) | Display | Cards |
| --- | --- | --- | --- | --- |
| 1 | The Lead | Today's most important stories from your publishers. | Always, 1–5 cards | Lead card, looping carousel |
| 2 | In Motion | Ongoing stories with new reporting. | When ≥ 3 stories clear the bar | Developing card |
| 3 | Your Beat | Stories close to what you read, save and follow. | When ≥ 3 stories clear the bar | Standard card; Coverage card when grouping is confident |
| 4 | The Deep Read | Long reads: investigations, explainers and opinion. | When ≥ 3 stories clear the bar | Feature card |
| 5 | Outside Your Usual | Stories from your publishers beyond your usual reading. | When ≥ 3 stories clear the bar | Standard card |
| 6 | The Latest | Everything else from your publishers, newest first. | Always | Compact card |

Lane names are Title Case (DESIGN.md 17). Descriptions never claim completeness: In Motion says "new reporting", never "every development", because clustering recall is 39 % (#737).

### 2.1 The six rules (from the epic)

1. **Chronological within every lane.** Newest first. The Lead is the one exception: its slides follow rank.
2. **No topic lanes.** Sections stay in the sidebar.
3. **No Briefing duplication.** No situation assessments, macro gauges, strategic impact or weak-signal analysis. The Lead and the Briefing hero will often hold the same stories; The Lead ranks them by Z2's editorial score, not by publisher count, and shows no analysis.
4. **One story, one lane,** by the order above. The module takes story entries (the story layer, #581), never individual publisher reports, so an event cannot appear twice.
5. **Subscriptions are the candidate pool.** Only the reader's selected publishers can enter Today. Publisher affinity raises a story's rank.
6. **The Latest is the safety net.** Personalisation shapes discovery and ranking and never hides an ordinary story.

### 2.2 Quality bars

Each conditional lane has a minimum count, a quality threshold and a minimum assignment confidence. A story below any of them falls through to the next lane in order and ends in The Latest. A lane whose survivors number fewer than its minimum is hidden and its survivors fall through too. A lane with more survivors than its cap keeps the highest `score`, breaking ties by the newest report and then the story id; the rest fall through to the next lane in order, as if they had missed this lane's bar, and end in The Latest if no later lane takes them. No filler, no padding.

Scores are on Z2's 0–1 scale (`score` = editorial relevance, `confidence` = how sure the module is of the placement).

| Lane | Minimum count | Cap | Threshold | Minimum confidence | Signals (existing first) |
| --- | --- | --- | --- | --- | --- |
| The Lead | 1 | 5 | Slide 1: the top-ranked story, always. Slides 2–5: `score` ≥ 0.60 and at least two original reports, or one original report and `score` ≥ 0.75 | 0.50, slides 2–5 only | Original report count (`originalCount`, wire copy counted once), `BriefingPriorityModule.assessImportance` (coverage, severity, momentum), the NL importance score, publisher affinity |
| In Motion | 3 | 12 | A material update in the last 24 h: `EventFeedSummary.hasSubstantiveUpdate` (new facts or a correction, not a reprint) and rising momentum | 0.70 | Event membership versions, report rate, headline novelty against the event's known headlines |
| Your Beat | 3 | 12 | Interest match ≥ 0.50 against the 30-day profile (read +1, saved +3), a starred feed, or publisher affinity in the top quartile | 0.60 | `briefingInterests`, starred feeds, publisher affinity |
| The Deep Read | 3 | 8 | Reading time ≥ 8 min (about 1,800 words of extracted text), or a content-type classification (investigation, explainer, opinion) at ≥ 0.70; the content-type label on the card shows only from the classification, never from length alone | 0.60 | Extracted text length, on-device content-type classification (new in Z2) |
| Outside Your Usual | 3 | 6 | Novelty ≥ 0.60 against the interest profile **and** `score` ≥ 0.35. Novelty alone is not relevance | 0.60 | Interest profile distance, editorial score; candidates stay inside subscriptions |
| The Latest | 0 | none (paged as today) | Everything that reached it | n/a | n/a |

Rules the bars share:

- **Publisher count is not confirmation.** Original reports weigh; wire copies count once.
- **Editorial and notification importance are separate decisions.** They may share evidence, never a threshold.
- **The Lead is never padded.** A library with one qualifying story shows one slide and no dots. The first slide is the top-ranked story even when its score or confidence is low, so The Lead always exists when Today has any story.
- **Coverage card gate.** The Coverage variant appears only when the event grouping is confident: ≥ 3 publishers, ≥ 2 original reports and grouping confidence ≥ 0.80. Below that the story shows its plain variant for the lane.
- **Developing pill.** Uses the Briefing definition (`BriefingView.isDeveloping`: a report joined in the last hour) so one word means one thing across the app.

### 2.3 Shadow evaluation before any UI

Z2 runs the assignment on a copy of a real library in a test-build mode and writes a local report with Lead precision@5, lane purity, lane distribution, publisher diversity, Latest completeness and duplicate rate, comparing publisher count alone, today's Briefing signals and the combined score on 100–200 labelled stories. The thresholds above are the starting point of that comparison, not its result.

## 3. Why The Latest is a vertical grid

The Latest holds everything that did not place: on a 60-feed library that is most of the day's stories. A horizontal row of a hundred compact cards cannot be scanned, cannot page, and would turn the safety net into the lane people never reach. A vertical grid keeps the existing paging, the existing list/grid toolbar control (the grid shows Compact cards; the list shows today's list card) and the existing prefetch. **Decision for Mars:** the alternative is a horizontal row like the others, capped at the first page, with "Show all" opening the rest below. The mock shows the grid.

## 4. Decisions for Mars

1. **The Latest as a vertical grid** (section 3), or a horizontal row like the other lanes.
2. **Publisher affinity in The Lead** (Z2's open decision): full weight as rule 5 reads, or a tie-breaker in The Lead with full weight in Your Beat. The spec assumes the tie-breaker reading; affinity never lifts a one-report story into The Lead.
3. **Coverage card at 39 % recall**: ship in Z6 behind the gate in section 2.2, or hold it until #737 improves recall.
4. **The thresholds in section 2.2** as the starting point for Z2's shadow evaluation.
5. **The masthead above The Lead** (as every other list), or The Lead first with "Today" layered over its image.

## 5. Acceptance

- [x] Mars signs off the visual references in `docs/design/today.md` (light and dark; 900 pt and wide; sidebar open and closed; full, partly filled and empty; card variants).
- [ ] Mars signs off the design documents in `docs/design/`.
- [ ] The decisions in section 4 are recorded on #933.
