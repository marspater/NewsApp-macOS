# Today edition

How the Today edition looks and behaves: lanes, the six card variants, The Lead, scrolling, keyboard focus, updates and states (epic Z, #932). [DESIGN.md](DESIGN.md) holds the design language this extends, and its section 8.8 points here. Quality bars, thresholds and the shadow evaluation are in the [specification](../plans/2026-11-09-today-edition-spec.md). Unread, Saved Stories, History, Smart Binders and search keep the list and grid of DESIGN.md section 8.2. Which story lands in which lane is Athena's decision in the [Angelia register](../ANGELIA.md); this document covers how the page looks.

**Status.** The card variants exist (Z6, #938: `StoryCardVariant` and `StoryCardMetadata` in `Sources/Views/List/StoryCardVariant.swift`). Z7 (#1174) fills the metadata from the lane assignment and the event (`StoryCardMetadata.init(_:differingAccount:)`). The Lead is the hero carousel's `LeadPresentation` (Z3, #935), and the page is `TodayEditionView` over a `TodayEdition`, with `TodayFocusMap` holding the keyboard rules (Z4, #936), all under `Sources/Views/Today/`. A field with no data is hidden, never faked. The visual references below are the target the views are compared with.

## Visual references

Exported on 9 November 2026 from the design canvas. They illustrate these rules; where a reference and this document disagree, this document wins. They show a CSS imitation of glass and placeholder stories.

| Reference | Shows |
| --- | --- |
| [wide-light.jpg](../mocks/today/wide-light.jpg), [wide-dark.jpg](../mocks/today/wide-dark.jpg) | The whole page at 1440 pt |
| [narrow-light.jpg](../mocks/today/narrow-light.jpg), [narrow-dark-sidebar-closed.jpg](../mocks/today/narrow-dark-sidebar-closed.jpg) | The minimum window, sidebar open and closed |
| [card-variants.jpg](../mocks/today/card-variants.jpg) | The card variants, light and dark |
| [partly-filled.jpg](../mocks/today/partly-filled.jpg) | A new library: The Lead and The Latest only |
| [updates-waiting.jpg](../mocks/today/updates-waiting.jpg) | "Show 4 New Stories" in the toolbar |
| [first-launch.jpg](../mocks/today/first-launch.jpg) | The empty state |

## Lanes

In page order. One story enters exactly one lane, the first whose quality bar it clears. Assignment order differs from page order in one place: The Deep Read is assigned before Your Beat, so a long read on a subject the reader follows is a Feature card in The Deep Read (specification, section 4.1).

| Lane | Description, shown under the name | Display | Card |
| --- | --- | --- | --- |
| The Lead | Today's most important stories from your publishers. | Always, one to five slides | Lead |
| In Motion | Ongoing stories with new reporting. | Enough stories clear the bar | Developing |
| Your Beat | Stories close to what you read, save and follow. | Enough strong matches | Standard; Coverage when the grouping is confident |
| The Deep Read | Long reads: investigations, explainers and opinion. | Enough qualifying long-form stories | Feature |
| Outside Your Usual | Stories from your publishers beyond your usual reading. | Enough worthwhile discovery candidates | Standard |
| The Latest | Everything else from your publishers, newest first. | Always | Compact in the vertical grid; the existing list card in the list layout |

1. Chronological within every lane. The Lead follows its rank.
2. No topic lanes: sections belong to the sidebar.
3. No Briefing duplication: no assessments, gauges, strategic impact or weak signals. The Lead ranks by the editorial score from Z2 (#934), not by publisher count.
4. One story, one lane, by the assignment order. Lanes hold stories (#581), never single reports, so an event cannot appear twice.
5. Subscriptions are the candidate pool; publisher affinity raises rank, with full weight in Your Beat and as a tie-breaker only in The Lead. There is no "From your sources" lane.
6. The Latest is the safety net: personalisation never hides an ordinary story. A listed story whose feed is not known goes to The Latest; a story whose feeds the reader has all unsubscribed from leaves Today at once, also from an edition that is being held. Saved Stories and History keep it.

A conditional lane needs three stories that clear its bar. Below that it is absent: no empty rail, no filler, and The Lead is never padded to five. Lanes appear and hide only when the reader applies an update.

## Page

Top to bottom, in one vertical `ScrollView`: the masthead (DESIGN.md section 8.1), The Lead, the conditional lanes in the page order of the table above, then The Latest.

**Lane header.** The name in `AppTypography.sectionTitle` with the heading trait, the description beneath it in `caption` and the secondary color, and no count. A lane row's header ends in previous and next buttons that move the row by two cards, as the visual reference shows; the row also scrolls freely.

**Lane row.** A horizontal `ScrollView` with `LazyHStack` and `AppLayout.cardGap` between cards. It scrolls freely: view-aligned snapping with an id-bound scroll position kept the header's buttons from moving the row in a window (live pass, 11 November 2026), so the buttons set the row's own offset, two cards at a time. No paging dots and no auto-scroll. The leading inset equals `AppLayout.pageInset`. Every card of a row is as tall as the row's tallest card. On macOS 26 and later neither the row nor the page clips its content (`scrollClipDisabled`), so cards pass under the glass sidebar instead of clipping at the column edge (seen on macOS 27.2); on macOS 15 cards clip there and the layout is otherwise identical. Cards in one row align their tops and end level.

**The Latest.** A header and a vertical grid of Compact cards, adaptive columns 280–420 pt (`AppLayout.compactColumnMinimum`, so two columns fit the 660 pt column of the minimum window), or the existing list card when the reader chooses the list layout, both paging as Today pages now. It is always newest first by the date its cards show.

**Grouping off.** The edition is built from stories, so it shows while Group Stories by Event is on, which is the default. With grouping off (G), Today lists every report on its own in the list or grid of DESIGN.md section 8.2, without The Lead or lanes, and G brings the edition back (Mars, 11 November 2026). In Today the toggle's help says so: "Showing the Today edition: The Lead, lanes and one card per event. Show every story on its own, without lanes (G)".

**Trackpad.** A lane is a horizontal scroll view nested in the page's vertical one, and macOS arbitrates by the gesture's dominant axis at its start. No custom gesture. Shift plus wheel scrolls a row, the system behaviour. Z4 verifies this on hardware.

## The Lead

A full-bleed magazine-cover hero, using the shared carousel component and the motion of DESIGN.md section 13.1.

- **A slide needs a photo.** A story with no photo, or whose photo failed to load this session, takes no slide while any story has one; it goes on to the other lanes. The photo is the best of the story's whole event, not only of the reports the page lists. Only a library with no photo at all keeps its top story as The Lead. Generic artwork for stories without a photo is an experiment in the backlog, not part of this design (Mars, 11 November 2026).
- **Image.** Touches both column edges and fades into the page, with no panel behind the text. `backgroundExtensionEffect()` on the image only carries it under the sidebar on macOS 26 and later; macOS 15 shows the same full-width image without the extension.
- **Height.** Follows the window: 240 pt at the 600 pt minimum, growing by 0.6 pt per window point, capped at 440 pt (`AppLayout.leadHeight`). Z3 measures the detail column, which is the window less the toolbar and the sidebar.
- **Headline.** System serif, white, scaling with window width from 22 to 34 pt (2.4 % of the window width), up to three lines, then the publisher's summary.
- **Top line.** The breathing dot on the current slide while unread, "PUBLISHER · 1 OF N" as an eyebrow (position hidden with one slide), a status pill in the accent when the story has a status, and a read-time pill in gray once the time is known. Pills are content tags, not glass.
- **Foot.** Clock glyph and time, up to three overlapping publisher marks, the publisher count, and the original-reports count in teal (DESIGN.md section 11), always the dark value because the foot sits on a dark image. Publisher marks are monograms first; favicons follow Z7.
- **Controls.** Page dots and previous and next arrows float at the trailing foot on glass with a dark backing under the marks (`PhotoControlSurface`), in one `GlassEffectContainer`, so they stay legible on a bright photo and in an inactive window. The foot of the image is darkened for the same reason (`AppColor.leadFootScrim`). They are always visible, and absent with one slide.

## Card variants

Presentations of the one `ArticleCardView`, chosen by the lane, sharing the anatomy and line limits of DESIGN.md section 8.2 and the elevation of section 12. Cards are opaque. Glass stays around them: the toolbar, the sidebar, and the carousel's floating controls.

| Variant | Lane | Width | Image | Below the headline |
| --- | --- | --- | --- | --- |
| Lead | The Lead | Full column | Full bleed, fading | See The Lead above |
| Developing | In Motion | 320 pt | Top, 140 pt | Dek; "N publishers · N new reports"; with three or more report days, a progress rail of one ring per report day (at most seven), newest filled |
| Standard | Your Beat, Outside Your Usual | 320 pt | Top, 140 pt | Dek; date |
| Feature | The Deep Read | 400 pt | Top, 3:2 | Dek; content-type tag from the classification, never from length alone; reading time; date |
| Coverage | Any lane, when the grouping is confident | 320 pt | Top, 140 pt | Dek; publisher count, original reports in teal and up to three monograms; one attributed differing account |
| Compact | The Latest | Adaptive 280–420 pt | Banner photo | One footer line: date and saved glyph |

Headlines are serif: 15 pt on Developing, Standard, Coverage and Compact, 20 pt on Feature. A Coverage card appears only past the grouping gate in the specification; otherwise the lane's plain variant shows.

**Developing status.** The accent pill at the trailing end of the publisher line, as the visual reference places it, carries the update as one status, for example "Updated 14 min ago", with the latest report's time in `monospacedDigit`. The time does not repeat at the bottom of the card.

**Compact photo.** The notification banner's treatment ([notifications.md](notifications.md)): the photo fills the trailing 52 % of the card, top to bottom, and dissolves toward the text. Z6 draws the dissolve as a gradient of the card's own fill over the photo's leading edge, which costs no pass per image; the banner's baked alpha fade and progressive blur replace it if Z5 finds the grid can afford them. Text may extend over the dissolving edge, to at most 66 % of the card's width. Minimum height 104 pt; a three-line headline grows the card. Z5 (#937) measures what baking a full grid costs. The card lays the photo out itself (`CompactCardLayout`) and every story card is one geometry group, so a photo never animates apart from its card.

**Imagery.** Real story imagery where available, richer abstract artwork where appropriate, and a plain placeholder only for missing media. A story with no image has no photo fade.

**Not on these cards.** No unread dot (DESIGN.md section 8.2), except The Lead's breathing dot, and no intelligence tag.

## Updates

One buffer and one "Show N New Stories" button in the leading toolbar (U; "Show Updates" when only placements changed) serve every lane. N counts stories new to Today across every lane.

- Until the click, nothing moves: no lane appears, hides or reorders, and The Lead keeps its slides. A further page of stories joins The Latest and never a lane above it. A card whose content refreshed in place (read state, a new image, more coverage) updates in place.
- On the click, every lane updates at once, and the page returns to the masthead and each row to its leading edge, with `AppMotion.hover` (`nil` under Reduce Motion). When a card keeps keyboard focus through the click, keeping it visible takes priority: the page and that card's row scroll only as far as needed to show it, and every other row returns to its leading edge.
- When every listed story is from an earlier day, the refresh replaces the edition once its new stories are grouped into events, and only while the page has not been scrolled or focused. Until then the earlier edition stays, and a page the reader has touched gets the stories through the updates button. A page of ungrouped stories is never laid out for them.
- Closing a story applies an update that a subscription's first refresh produced while the reader was open (#782).

## Keyboard focus

Focus is the card that takes keys; selection is the open story. After a story opens, both are that card.

| Key | In a lane | In The Lead | In The Latest grid |
| --- | --- | --- | --- |
| ← → | Previous or next card; the row scrolls to keep it visible | Previous or next slide; rotation pauses while focused | Previous or next card, wrapping rows |
| ↑ ↓ | The lane above or below, on that lane's remembered card (its last focused card, else the first visible) | ↓ moves to the first lane below | ↑ from the first row moves to the lane above |
| J K ⌘J ⌘K | Next or previous story in reading order: through the row, then the next lane | Through the slides first | Through the grid last |
| Return, Space, U, G, M, S, O, C | As elsewhere | As elsewhere | As elsewhere |
| Tab | Leaves the list for the toolbar or sidebar | Same | Same |

Each lane remembers its last focused card for the session. When the edition changes under focus (only on the click):

- A card still in the edition keeps focus by id, also when it moved lane; the row scrolls to show it.
- A card gone from a remaining lane passes focus to the card at the same index, or the last card when the index is past the end.
- A lane gone passes focus to the first card of the next lane below that holds cards. The Latest can be empty, so when no later lane holds a card, focus lands on the last card of the nearest earlier lane. With no card left, no card holds focus.
- A lane appearing never moves focus.
- After closing a story, focus returns to the same card by these rules. From The Lead, that slide shows and rotation stays paused until hover and focus clear.

**VoiceOver.** One container per lane, labelled with its name and description; a "Lanes" rotor moves between lanes; cards stay one element each with their full description and actions, plus "in" and the lane name. Hidden lanes are not in the tree. The Lead announces the position ("2 of 5").

## States

| State | What shows |
| --- | --- |
| First launch, empty library | `ContentUnavailableView` with `newspaper`, "No Stories Yet" and "Subscribe to feeds or refresh to load the latest stories." The action "Refresh Feeds" uses `.buttonStyle(.glassProminent)` on macOS 26 and later and `.borderedProminent` on macOS 15, with no custom background or tint |
| Partly filled library | Masthead, The Lead with one or two slides, The Latest. Every conditional lane absent |
| Full library | Masthead, The Lead with up to five slides, the conditional lanes that clear their bars, The Latest |
| Updates waiting | The toolbar button; the edition does not move |
| Reduce Motion | The Lead shows its first slide; arrows and dots work; no cross-fade, breathing dot or hover movement |
| Sidebar closed | The Lead and the rows span the full window width |
| 900 pt window, sidebar open | A 660 pt column: The Lead scales to the window, a row shows two standard cards, The Latest shows two columns |

## Honesty

A lane header never shows a count, and no lane copy claims completeness, because clustering recall is partial (#737): "new reporting", never "every development". The reason behind a placement is never reader copy.
