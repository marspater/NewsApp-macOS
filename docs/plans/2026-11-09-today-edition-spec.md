# Today edition: specification for sign-off (Z1, #933)

**Status:** Draft for Mars's sign-off. Nothing in Z2–Z6 (#934–#938) starts before the mock and the DESIGN.md diff are approved.
**Date:** 9 November 2026
**Epic:** Z · Today edition (#932)
**Mock:** the "Today Edition" canvas, https://claude.ai/artifact/WhMdQEpLNzChu1ztS8cwwa. `docs/mocks/today_edition.md` summarizes it. When this document, DESIGN.md section 8.8 and the canvas disagree on the look, the canvas wins; on behaviour, this document wins.

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

Each conditional lane has a minimum count, a quality threshold and a minimum assignment confidence. A story below any of them falls through to the next lane in order and ends in The Latest. A lane whose survivors number fewer than its minimum is hidden and its survivors fall through too. No filler, no padding.

Scores are on Z2's 0–1 scale (`score` = editorial relevance, `confidence` = how sure the module is of the placement).

| Lane | Minimum count | Cap | Threshold | Minimum confidence | Signals (existing first) |
| --- | --- | --- | --- | --- | --- |
| The Lead | 1 | 5 | Slide 1: the top-ranked story, always. Slides 2–5: `score` ≥ 0.60 and at least two original reports, or one original report and `score` ≥ 0.75 | 0.50 | Original report count (`originalCount`, wire copy counted once), `BriefingPriorityModule.assessImportance` (coverage, severity, momentum), the NL importance score, publisher affinity |
| In Motion | 3 | 12 | A material update in the last 24 h: `EventFeedSummary.hasSubstantiveUpdate` (new facts or a correction, not a reprint) and rising momentum | 0.70 | Event membership versions, report rate, headline novelty against the event's known headlines |
| Your Beat | 3 | 12 | Interest match ≥ 0.50 against the 30-day profile (read +1, saved +3), a starred feed, or publisher affinity in the top quartile | 0.60 | `briefingInterests`, starred feeds, publisher affinity |
| The Deep Read | 3 | 8 | Reading time ≥ 8 min (about 1,800 words of extracted text), or a content-type classification (investigation, explainer, opinion) at ≥ 0.70; the content-type label on the card shows only from the classification, never from length alone | 0.60 | Extracted text length, on-device content-type classification (new in Z2) |
| Outside Your Usual | 3 | 6 | Novelty ≥ 0.60 against the interest profile **and** `score` ≥ 0.35. Novelty alone is not relevance | 0.60 | Interest profile distance, editorial score; candidates stay inside subscriptions |
| The Latest | 0 | none (paged as today) | Everything that reached it | n/a | n/a |

Rules the bars share:

- **Publisher count is not confirmation.** Original reports weigh; wire copies count once.
- **Editorial and notification importance are separate decisions.** They may share evidence, never a threshold.
- **The Lead is never padded.** A library with one qualifying story shows one slide and no dots. The first slide is the top-ranked story even when its score is low, so The Lead always exists when Today has any story.
- **Coverage card gate.** The Coverage variant appears only when the event grouping is confident: ≥ 3 publishers, ≥ 2 original reports and grouping confidence ≥ 0.80. Below that the story shows its plain variant for the lane.
- **Developing pill.** Uses the Briefing definition (`BriefingView.isDeveloping`: a report joined in the last hour) so one word means one thing across the app.

### 2.3 Shadow evaluation before any UI

Z2 runs the assignment on a copy of a real library in a test-build mode and writes a local report with Lead precision@5, lane purity, lane distribution, publisher diversity, Latest completeness and duplicate rate, comparing publisher count alone, today's Briefing signals and the combined score on 100–200 labelled stories. The thresholds above are the starting point of that comparison, not its result.

## 3. Page structure

Top to bottom, in one vertical `ScrollView`:

1. **Masthead** (DESIGN.md 8.1): "Today" and one status line ("128 stories · 41 events · updated 09:42"). Scrolls with the content, as everywhere else.
2. **The Lead**: a full-bleed hero, `AppLayout.leadStoryHeight` (360 pt) tall. The image touches the leading and trailing edges of the detail column and continues under the sidebar with `backgroundExtensionEffect()` on macOS 26 and later (DESIGN.md 3.4); macOS 15 shows the full-width image without the extension. Text and controls are layered above the image on the dark scrim (`AppColor.leadScrim`). Reuses `BriefingHeroCarouselView`: 45 s cross-fade, pause on hover and keyboard focus, halt while a story or sheet is open, first slide only under Reduce Motion, arrows and dots always interactive, position announced to VoiceOver ("2 of 5").
3. **Conditional lanes**, in assignment order, each a header plus one horizontal row.
4. **The Latest**: a header, then the existing vertical grid of Compact cards (adaptive columns 300–420 pt), paging as Today pages now.

### 3.1 Lane anatomy

- **Header**: lane name in `AppTypography.sectionTitle` with the heading trait, the one-line description in `caption` and the secondary color beneath it. No count in the header: a count would imply completeness.
- **Row**: a horizontal `ScrollView` with `LazyHStack`, `AppLayout.cardGap` (16 pt) between cards, view-aligned scrolling (`scrollTargetBehavior(.viewAligned)`), no paging dots and no auto-scroll. The row's leading inset equals `AppLayout.pageInset` (24 pt) so cards rest on the column's text edge; the row's scrollable area extends into the leading safe area so cards that scroll past the column edge pass under the glass sidebar instead of clipping at it. If a macOS 15 split view does not allow that extension, cards clip at the column edge there; the layout is otherwise identical.
- **Card widths** (new layout tokens for Z4, in `DesignSystem.swift`): standard and Developing 320 pt, Feature 400 pt, Lead full width, Compact in the grid as today. Heights follow content; cards in one row align their tops and end level (DESIGN.md 8.2's grid rule applies to a row).
- **No empty rails.** A lane that does not meet its bar is absent. Lanes appear and disappear only when the reader applies an update (section 5), never while they read.

### 3.2 Why The Latest is a vertical grid

The Latest holds everything that did not place: on a 60-feed library that is most of the day's stories. A horizontal row of a hundred compact cards cannot be scanned, cannot page, and would turn the safety net into the lane people never reach. A vertical grid keeps the existing paging, the existing list/grid toolbar control (the grid shows Compact cards; the list shows today's list card) and the existing prefetch. **Decision for Mars:** the alternative is a horizontal row like the others, capped at the first page, with "Show all" opening the rest below. The mock shows the grid.

## 4. Card variants (Z6, #938)

One card component (`ArticleCardView`, DESIGN.md 8.2) with presentation variants. Every variant keeps the 8.2 anatomy: decorative lead image, publisher eyebrow in `AppTypography.eyebrow` uppercase, headline in `cardHeadline` for its layout (at most two lines), dek in two lines, footer in `caption` with state glyphs, unread dot and primary-color headline for unread, hover border and focus ring from the tokens, the whole card one `Button`.

| Variant | Lane | Adds | Tokens |
| --- | --- | --- | --- |
| Lead | The Lead | Full-bleed image with the dark scrim, headline in `leadStoryHeadline` (28 pt serif) up to three lines, the publisher's summary (the dek) in `body`, a coverage indicator (`TagView` "6 publishers" with `square.stack.3d.up` and "4 original reports" in `caption`), timestamp, Developing pill when the Briefing rule says so, position "1 of 5" in the eyebrow line | `leadStoryHeight`, `leadScrim`, `leadText`, `leadSecondaryText` |
| Developing | In Motion | An update indicator ("Updated" `TagView` in the accent tint) in the eyebrow line, the latest report's time ("updated 14 min ago", `caption`, `monospacedDigit`) instead of the first report's date, one line of event context in `caption` ("3 publishers · 2 new reports") and, when the event has three or more membership versions, a compact progress strip: one dot per report day on a hairline, the newest filled | Existing `TagView`, `CardDateText`; the strip reuses the overview timeline dot and rail tokens |
| Feature | The Deep Read | Image-led layout 400 pt wide with the image at 3:2, `AppSpacing.lg` inner padding, reading time ("12 min read", `caption`) and a content-type label (`TagView` "Investigation", "Explainer" or "Opinion" in the badge fill) in the footer; no dek when the headline takes two lines | Existing tokens; `laneFeatureCardWidth` 400 |
| Compact | The Latest | A 56 pt square thumbnail at the leading edge or none; eyebrow, headline in the grid `cardHeadline` (15 pt), one footer line with date and glyphs; no dek | `listCardImageWidth` is not reused; a `compactThumbnail` token of 56 pt |
| Coverage | Any lane when the grouping gate passes | The coverage line "6 publishers · 4 original reports" with the stack symbol, up to three publisher monograms, and one line of differing perspective where the overview has perspectives ("Accounts differ: …" with its attribution); otherwise only the count | Existing event card and `TagView` tokens |

The `reason` field from Z2 is never shown as reader copy; it is for tests and the shadow report.

## 5. New stories while Today is open

One buffer, one button, one apply. The existing `FeedUpdateBuffer` holds the refreshed assignment; the leading toolbar shows "Show N New Stories" (U; "Show Updates" when only placements changed) with the existing tooltip and VoiceOver announcement. N counts stories new to Today across every lane.

- **Until the click, nothing moves.** No lane appears, hides, reorders or changes its slides; a card whose content refreshed in place (read state, a new image, more coverage) updates in place, as today.
- **On apply**, every lane updates at once: new stories enter at the leading edge of their lane (newest first), stories whose placement changed move lanes, lanes appear or hide, and The Lead takes its new ranking. The page scrolls to the masthead and every row to its leading edge, with `AppMotion.hover`, `nil` under Reduce Motion.
- **The existing Today exception stays.** When every listed story is from an earlier day (the cache at launch the next morning), the refresh replaces the edition at once instead of waiting behind the button.
- **Closing a story** applies an update that a subscription's first refresh produced while the reader was open (#782), as today.

## 6. Focus and selection in two dimensions

Focus is the card that takes keyboard input; selection is the open story. After a story opens, both are that card.

| Key | In a lane | In The Lead | In The Latest grid |
| --- | --- | --- | --- |
| → / ← | Next or previous card in the row; the row scrolls to keep it visible | Next or previous slide (the existing carousel keys) | Next or previous card, wrapping rows |
| ↓ / ↑ | The lane below or above, landing on that lane's remembered card (its last focused card; the first visible card if none) | ↓ moves to the first lane below | ↑ from the first row moves to the lane above |
| J / K, ⌘J / ⌘K | Next or previous story in reading order: through the row, then the next lane, through The Lead's slides first | Same | Same |
| Return, Space, U, G, M, S, O, C and the other single keys | As today | As today | As today |
| Tab | Leaves the list for the toolbar or sidebar, as today | Same | Same |

Each lane remembers its last focused card index for the session. The list keeps one focused story id, as today (`focusedArticleID`).

Where focus goes when the edition changes under it (only on apply, section 5):

- The focused card is still in the edition: focus follows its id, also when it moved to another lane; the lane scrolls to show it.
- The card is gone but its lane remains: focus lands on the card now at the same index in that lane (the last card when the index is past the end).
- The lane is gone: focus lands on the first card of the next lane below in reading order; The Latest always exists, so this is always defined.
- A lane appears: focus does not move.

After closing a story, focus returns to the same card id by the rules above, and the row scrolls to show it (#936 acceptance). Opening from The Lead returns to The Lead with that slide shown and rotation paused until focus and hover clear.

VoiceOver: each lane is one container labelled with its name and description ("In Motion, ongoing stories with new reporting"); the header carries the heading trait; a custom rotor "Lanes" moves between lanes; cards stay one element each with their full description and actions (DESIGN.md 16), and the lane adds "in <lane name>" to the card's description. Hidden lanes are not in the tree. The Lead announces the slide position as the Briefing carousel does.

## 7. Trackpad and scroll wheel

A lane is a horizontal `ScrollView` nested in the page's vertical `ScrollView`. macOS arbitrates nested scroll views by the dominant axis of the gesture at its start: a vertical swipe over a lane scrolls the page, a horizontal swipe scrolls the lane, and a gesture that began vertical never gets trapped in a row. No custom gesture recognizer, no `simultaneousGesture`. A mouse wheel without a horizontal axis scrolls the page; Shift plus wheel scrolls the row, the system behaviour. The mock cannot demonstrate arbitration; Z4 (#936) verifies it on hardware and in the UI tests.

## 8. States

| State | What shows |
| --- | --- |
| First launch, empty library | `ContentUnavailableView` with `newspaper`, "No Stories Yet" and "Subscribe to feeds or refresh to load the latest stories.", action "Refresh Feeds" (the existing Today empty state) |
| Partly filled library (a few feeds, first hour) | Masthead, The Lead with one or two slides (dots only when there are two or more), The Latest. Every conditional lane absent. |
| Full library | Masthead, The Lead with five slides, the conditional lanes that clear their bars, The Latest |
| Updates waiting | The leading toolbar button "Show N New Stories"; the edition does not move |
| Reduce Motion | The Lead shows its first slide; arrows and dots work; no cross-fade |
| Sidebar closed | The Lead and the rows span the full window width; nothing else changes |
| 900 pt window, sidebar open | The detail column is 660 pt wide: The Lead keeps its height, a row shows two standard cards, The Latest grid shows two columns |

## 9. Constraints resolved

| Constraint (epic) | Resolution |
| --- | --- |
| DESIGN.md 3.4 forbids `backgroundExtensionEffect` on the inset lead card | The Lead is a full-bleed hero, not an inset card: its image touches both column edges, so the toolbar edge is covered. The inset prohibition stays; the inset lead card leaves Today when Z3 lands (`LeadStoryPresentation` keeps serving Briefing until then). |
| DESIGN.md 8.4 and 13 make the Briefing carousel the only auto-advancing motion | Two carousels, one component, one set of pause rules; they are never on screen together. |
| "Today stays chronological" | Chronological within each lane (DESIGN.md 8.8). README's line follows when Z4 ships the behaviour. |
| In Motion depends on clustering with 39 % recall (#737) | Copy says "new reporting", the lane has no count, the minimum confidence is 0.70 and the lane hides below three stories. |
| Keyboard navigation is a flat list; image prefetch assumes one list (#591) | Section 6 defines the two-dimensional model; prefetch runs per visible row with the card's `bestCardImage` (Z4 reuses #591). |

## 10. Decisions for Mars

1. **The Latest as a vertical grid** (section 3.2), or a horizontal row like the other lanes.
2. **Publisher affinity in The Lead** (Z2's open decision): full weight as rule 5 reads, or a tie-breaker in The Lead with full weight in Your Beat. The spec assumes the tie-breaker reading; affinity never lifts a one-report story into The Lead.
3. **Coverage card at 39 % recall**: ship in Z6 behind the gate in section 2.2, or hold it until #737 improves recall.
4. **The thresholds in section 2.2** as the starting point for Z2's shadow evaluation.
5. **The masthead above The Lead** (as every other list), or The Lead first with "Today" layered over its image.

## 11. Acceptance

- [ ] Mars signs off the canvas (light and dark; 900 pt and wide; sidebar open and closed; full, partly filled and empty; card variants).
- [ ] Mars signs off the DESIGN.md diff (3.4, 8.4, 8.8, 13, 15, 17, 18, 19).
- [ ] The decisions in section 10 are recorded on #933.
