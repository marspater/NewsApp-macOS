# Sourced overview timeline — 2 October 2026

Refs #143, #96. Base: `b282729` (after #205 overview reader mode and #206).

## Why

#205 added the timeline model (`OverviewTimelineItem`), its storage and the reader section, but nothing produced items, so the section never appeared. Phase F starts by filling it under the #143 rules: event date separate from publication date, unknown dates stay unknown, plans labeled, every item sourced.

## Implementation

`OverviewTimelineBuilder` is deterministic and runs inside `OverviewComposer.composeOverview` over every valid passage-anchored fact, not only the 3–5 key facts. No model is involved; a model-proposed fact contributes only through its verbatim quote.

- **Dates:** a fact enters only if its quote states exactly one explicit calendar date. Sentences with none, several or an impossible one (31 April) stay out. Accepted forms:
  - English: "15 October 2026", "October 15, 2026", "Oct. 15", "15th of October", "March 2019". Month names are matched case-sensitively, so "3 may have died" is not a date.
  - Day-first, in the exact case each language uses: German ("3. März 2026"), Dutch, French ("1er mars"), Italian, Polish and Ukrainian (genitive month names), so "3 Mars landers" is not a date.
  - ISO `2026-10-02`.
  - Relative expressions ("on Monday", "yesterday") are not resolved.
- **Event date vs publication date:** the item shows the date the source states, at its precision (`d MMM y`, `d MMM` or `MMM y`, localized). The publication date stays on the citation. It is used only to order a date without a year (the nearest year to publication; never displayed) and to label plans.
- **Plans:** an item whose date falls after the day of publication (after the month, for a month-precision date) is labeled Planned, as it was reported.
- **Unknown dates:** articles with `DateParser.unknownDate` contribute no items.
- **Sources:** each item reproduces its verbatim quote and cites every passage that printed it. Reprints of one sentence on one date merge into one item with several citations. Citations (`cite_tl_…`) are added to the overview's citation set and stored with it.
- **Absence:** fewer than two distinct dates means no timeline and no added citations. At most 8 items are kept, preferring corroborated ones, shown in date order.
- `EventOverviewDocument.currentAnalysisVersion` is now 2, so overviews stored without timelines are regenerated on the next request. The claim verifier's fallback still drops evidence sections, as before.

## Tests

`testOverviewTimeline` (full and `--story-regressions` runs):

- order and contents of a mixed set: a weekday-only sentence, a two-date sentence and a sentence from an article with an unknown date are excluded; a reprint becomes one item with two citations
- plan labels; month-precision display; a missing year is not displayed
- every item has a citation whose quote equals the item text and whose publication date is the article's
- one dated sentence, or two sentences on the same date, give no timeline
- date recognition in English, French, German, Ukrainian and Polish; rejection of "3 may", "3 Mars" and 31 April
- yearless placement across a new year; plan boundaries at day and month precision
- composed overviews carry the timeline and its citations; undated sets have no evidence section

`testOverviewDocumentModelBoundToInputsAndVersions` now uses `currentAnalysisVersion` instead of the literal 1.

## Verification

The authoring environment was a Linux container without a Swift toolchain; swift.org is blocked by its network policy. Nothing was compiled or run locally:

- A tree-sitter Swift parse found no syntax errors in the new and changed sources, and no new ones in `Tests/NewsTests.swift`.
- The regular expressions were exercised through Python's `regex` module, which uses the same lookaround and `\p{L}` syntax as ICU, on 38 sample sentences, including every sentence in the test.
- Compilation and the suite are left to macOS CI.

## Limits

- Relative dates are the most common way news dates events ("on Monday"). They are left out rather than resolved against publication dates, so many breaking-news events will show no timeline.
- A yearless date is placed in the year nearest to publication. A reference to a past anniversary ("the Jan 6 committee") is therefore placed in the wrong year, though it is shown as stated.
- Range expressions ("October 15–16") are placed at their first day.
- English month-first and day-first patterns run on every language; other languages are day-first only.
