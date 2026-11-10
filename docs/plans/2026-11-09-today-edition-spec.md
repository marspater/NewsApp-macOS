# Today edition: specification for sign-off (Z1, #933)

**Status:** Mars approved the mocks and signed off the design documents in `docs/design/` on 9 November 2026. Every decision in section 4 is recorded, so Z2 (#934) can start.
**Date:** 9 November 2026
**Epic:** Z · Today edition (#932)
**Presentation:** [`docs/design/today.md`](../design/today.md) owns lanes, card variants, The Lead, scrolling, focus, updates and states, with its visual references. This document keeps the quality bars, thresholds, shadow evaluation and open decisions.

Every number below is a proposal. Z2's shadow evaluation on a real library copy (#934) is the instrument that revises the thresholds; the lanes, the rules and the interaction model are what this sign-off fixes.

## 1. What changes

Today stops being one chronological list with an inset lead card. It becomes an edition: The Lead, up to four conditional lanes, and The Latest. Each lane is a horizontal row of story cards that slides under the floating glass sidebar, modelled on Apple TV's rows and built natively. Importance decides which lane a story enters; inside a lane, time decides the order.

Out of scope, by the epic's rules: topic lanes (World, Politics, Technology; the sidebar owns them), Briefing analysis (assessments, gauges, strategic impact, weak signals), and any "From your sources" lane. Unread, Saved Stories, History, Smart Binders and search keep the existing list and grid.

## 2. Lanes

In assignment order. One story enters exactly one lane: the first whose bar it clears. The Deep Read is assigned before Your Beat (Mars, 9 November 2026; section 4.1). The order on the page is separate and stays as [`docs/design/today.md`](../design/today.md) shows it, with Your Beat above The Deep Read.

| # | Lane | One-line description (sentence case, shown under the name) | Display | Cards |
| --- | --- | --- | --- | --- |
| 1 | The Lead | Today's most important stories from your publishers. | Always, 1–5 cards | Lead card, looping carousel |
| 2 | In Motion | Ongoing stories with new reporting. | When ≥ 3 stories clear the bar | Developing card |
| 3 | The Deep Read | Long reads: investigations, explainers and opinion. | When ≥ 3 stories clear the bar | Feature card |
| 4 | Your Beat | Stories close to what you read, save and follow. | When ≥ 3 stories clear the bar | Standard card; Coverage card when grouping is confident |
| 5 | Outside Your Usual | Stories from your publishers beyond your usual reading. | When ≥ 3 stories clear the bar | Standard card |
| 6 | The Latest | Everything else from your publishers, newest first. | Always | Compact card |

Lane names are Title Case (DESIGN.md 17). Descriptions never claim completeness: In Motion says "new reporting", never "every development", because clustering recall is 39 % (#737).

### 2.1 The six rules (from the epic)

1. **Chronological within every lane.** Newest first. The Lead is the one exception: its slides follow rank.
2. **No topic lanes.** Sections stay in the sidebar.
3. **No Briefing duplication.** No situation assessments, macro gauges, strategic impact or weak-signal analysis. The Lead and the Briefing hero will often hold the same stories; The Lead ranks them by Z2's editorial score, not by publisher count, and shows no analysis.
4. **One story, one lane,** by the order above. The module takes story entries (the story layer, #581), never individual publisher reports, so an event cannot appear twice.
5. **Subscriptions are the candidate pool.** Only the reader's selected publishers can enter Today. Publisher affinity raises a story's rank: with full weight in Your Beat, and as a tie-breaker only in The Lead, where it never lifts a one-report story onto a slide (Mars, 9 November 2026).
6. **The Latest is the safety net.** Personalisation shapes discovery and ranking and never hides an ordinary story.

### 2.2 Quality bars

Each conditional lane has a minimum count, a quality threshold and a minimum assignment confidence. A story below any of them falls through to the next lane in order and ends in The Latest. A lane whose survivors number fewer than its minimum is hidden and its survivors fall through too. A lane with more survivors than its cap keeps the highest `score`, breaking ties by the newest report and then the story id (in The Lead a tie goes first to the story with more original reports, then to the higher publisher affinity, then to the newest report, so affinity never puts a one-report story ahead of a multi-report one); the rest fall through to the next lane in order, as if they had missed this lane's bar, and end in The Latest if no later lane takes them. No filler, no padding.

Scores are on Z2's 0–1 scale (`score` = editorial relevance, `confidence` = how sure the module is of the placement). Neither exists in the code yet: `BriefingPriorityModule.assessImportance` returns three levels, so Z2 defines both scales and every number on them is calibrated by the shadow evaluation.

| Lane | Minimum count | Cap | Threshold | Minimum confidence | Signals (existing first) |
| --- | --- | --- | --- | --- | --- |
| The Lead | 1 | 5 | Slide 1: the top-ranked story, always. Slides 2–5: `score` ≥ 0.60 and at least two original reports, or one original report and `score` ≥ 0.75 | 0.50, slides 2–5 only | Original report count (`originalCount`, wire copy counted once), `BriefingPriorityModule.assessImportance` (coverage, severity, momentum), the NL importance score, publisher affinity |
| In Motion | 3 | 12 | A report dated in the last 24 h (the member's stored date, which is its publication time or, without one, its ingestion time; membership stores a join version, not a join time, so a report that joined late is judged by its own date) with a headline not already among the event's known headlines (the `EventFeedSummary.hasSubstantiveUpdate` test taken against the clock, not against the reader's last visit), and rising momentum | 0.70 | Event membership versions, report rate, headline novelty against the event's known headlines |
| The Deep Read | 3 | 8 | Reading time ≥ 8 min (1,600 words at the reader's 200 words per minute, counted from text the app already holds), or a content-type classification (investigation, explainer, opinion) at ≥ 0.70; the content-type label on the card shows only from the classification, never from length alone | 0.60 | Extracted text length, on-device content-type classification (new in Z2) |
| Your Beat | 3 | 12 | Interest match ≥ 0.50 on a 0–1 scale that Z2 defines over a 30-day profile (read +1, saved +3) finer than today's twelve categories, a starred feed, or publisher affinity in the top quartile (a new signal) | 0.60 | `briefingInterests`, starred feeds, publisher affinity |
| Outside Your Usual | 3 | 6 | Novelty ≥ 0.60 against the interest profile **and** `score` ≥ 0.35. Novelty alone is not relevance | 0.60 | Interest profile distance, editorial score; candidates stay inside subscriptions |
| The Latest | 0 | none (paged as today) | Everything that reached it | n/a | n/a |

Rules the bars share:

- **Publisher count is not confirmation.** Original reports weigh; wire copies count once.
- **Editorial and notification importance are separate decisions.** They may share evidence, never a threshold.
- **The Lead is never padded.** A library with one qualifying story shows one slide and no dots. The first slide is the top-ranked story even when its score or confidence is low, so The Lead always exists when Today has any story.
- **Coverage card gate.** The Coverage variant appears only when the event grouping is confident: ≥ 3 publishers, ≥ 2 original reports and a grouping confidence that Z2 or #737 defines, since event membership stores no score today. Below that the story shows its plain variant for the lane.
- **Developing pill.** Uses the Briefing definition (`BriefingView.isDeveloping`: a report joined in the last hour) so one word means one thing across the app.

### 2.3 Shadow evaluation before any UI

Z2 runs the assignment on a copy of a real library in a test-build mode and writes a local report with Lead precision@5, lane purity, lane distribution, publisher diversity, Latest completeness and duplicate rate, comparing publisher count alone, today's Briefing signals and the combined score on 100–200 labelled stories. The thresholds above are the starting point of that comparison, not its result.

## 3. Why The Latest is a vertical grid

The Latest holds everything that did not place: on a 60-feed library that is most of the day's stories. A horizontal row of a hundred compact cards cannot be scanned, cannot page, and would turn the safety net into the lane people never reach. A vertical grid keeps the existing paging, the existing list/grid toolbar control (the grid shows Compact cards; the list shows today's list card) and the existing prefetch. Mars approved the grid with the mocks on 9 November 2026.

## 4. Decisions

Recorded on #933 on 9 November 2026.

| Decision | Outcome |
| --- | --- |
| The Latest | A vertical grid of Compact cards, as the approved mocks show |
| The masthead | Above The Lead, status only apart from the muted-stories menu |
| Publisher affinity in The Lead | A tie-breaker. Full weight in Your Beat. Affinity never lifts a one-report story into The Lead |
| Coverage card at 39 % recall | Ships with Z6 (#938) behind the gate in section 2.2. Clustering recall is worked on separately under #737 |
| Story card radius | 16 pt, delivered by Z6 (DESIGN.md section 12) |
| Headline typeface | The system serif. Newsreader in the mocks maps to it and the app bundles no typeface (DESIGN.md section 10) |
| Design documents in `docs/design/` | Signed off |
| Order of Your Beat and The Deep Read | The Deep Read is assigned first, from stored evidence only (section 4.1). The page order stays as the mocks show it |

**Thresholds.** Mars delegated this decision on 9 November 2026 to a review of section 2.2 against the code. Its outcome: the numbers stand as Z2's starting point, with four corrections made in this revision. In Motion's test is taken against the clock, because `hasSubstantiveUpdate` is relative to the reader's last visit and is false for an event never opened. Your Beat's match needs a scale and a finer profile from Z2. The Deep Read's 8 minutes is 1,600 words at the reader's rate. The Coverage gate's grouping confidence is not stored today. Z2 reports what each lane would have shown on a copy of a real library and proposes the final numbers for Mars to review; nothing ships from the starting values.

### 4.1 Why The Deep Read is assigned before Your Beat

The epic assigned Your Beat first. Mars asked for that order to be reassessed on 9 November 2026 and chose the order below. Reading the code the lanes are built on showed three problems. The first two came from the order; the third holds in either order.

1. **The two lanes measure different things, and the order makes one starve the other.** Your Beat asks whether a story is close to the reader; The Deep Read asks what kind of story it is. A story enters the first lane it clears, so with Your Beat first, a long investigation on a subject the reader follows becomes a Standard card in Your Beat. The Deep Read is left with the long reads the reader does not follow, which is the job of Outside Your Usual.
2. **Your Beat's bar is too wide to sit in front of anything.** The interest profile (`DatabaseEngine.briefingInterests`) is a count per category over twelve categories (Technology, Science, Business, Politics, World and seven more), and a starred feed qualifies every one of its stories. A match against twelve categories is expected to cover a large share of a reader's library, so that Your Beat fills to its cap first and whatever overflows is what the later lanes see. The share depends on the match formula and the library, and no measurement exists yet: Z2's shadow evaluation reports it. Publisher affinity, the third signal, does not exist in the code yet.
3. **The Deep Read's evidence is not there when lanes are assigned.** Reading time is computed in the reader from the rendered story (`ArticleDetailView.readingTimeEstimate`). The full text is fetched only when a story is opened or an overview is generated; until then a story holds whatever its feed carried, often a teaser. The one background page request the app makes today is the budgeted lead-image lookup for a story without an image (`StoryImportance.leadImage`), which reads the page and keeps only the image. Z2 is specified as one pure module over stored signals, so it cannot know that an unopened story is an 8-minute read. Fetching every candidate's page to find out is a network, battery and privacy cost that the Today load budget (Z5 #937) has not accepted.

Decided:

- **Assign The Deep Read before Your Beat.** The narrow lane about the kind of story takes its few stories first; Your Beat, which is broad, takes from the rest. A long read on a subject the reader follows then shows as a Feature card in The Deep Read. The assignment order is The Lead, In Motion, The Deep Read, Your Beat, Outside Your Usual, The Latest; the order on the page stays as the mocks show it, because assignment order and page order are separate.
- **The Deep Read uses stored evidence only.** A story qualifies from text the app already holds (a feed that carries the full story, or a story fetched earlier) or from a content-type classification of the headline, summary and feed. A story with neither is not a candidate, and the lane hides when fewer than three qualify. Fetching stories in the background to widen the lane is a separate decision, measured in Z2's shadow evaluation.
- **Your Beat needs a finer profile than twelve categories** before its threshold means anything. Z2 defines it (for example, named topics and entities from stories read and saved) and reports how many stories clear the bar per day.

The alternative, not chosen, kept the epic's order and made format a card variant: Your Beat would show a Feature card for a long read, and The Deep Read would hold only the long reads that missed Your Beat.

## 5. Acceptance

- [x] Mars signs off the visual references in `docs/design/today.md` (light and dark; 900 pt and wide; sidebar open and closed; full, partly filled and empty; card variants).
- [x] Mars signs off the design documents in `docs/design/`.
- [x] The decisions in section 4 are recorded on #933.
