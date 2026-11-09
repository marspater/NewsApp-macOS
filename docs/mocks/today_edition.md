# Today edition

The single source of truth for the Today edition's look is the "Today Edition" canvas, submitted for sign-off on 9 November 2026 (Z1, #933):

https://claude.ai/artifact/WhMdQEpLNzChu1ztS8cwwa

This file is a text summary only. When it and the canvas disagree, the canvas wins. Behaviour, quality bars and the interaction model are in [the specification](../plans/2026-11-09-today-edition-spec.md); component tokens and invariants are in `docs/DESIGN.md` section 8.8.

## Artboards

| Artboard | Shows |
| --- | --- |
| Wide · Light · whole page | The whole page at 1440 pt, scrolled out in full (1440 × 2640), sidebar open, full library: masthead, The Lead extending under the sidebar, In Motion, Your Beat, The Deep Read, Outside Your Usual, The Latest grid. A row is scrolled so a card passes under the glass sidebar. A 1440 × 900 window shows the masthead, The Lead and the first row. |
| Wide · Dark · whole page | The same in dark. |
| 900 × 600 · Light · Sidebar open | The minimum window's first screen: a 660 pt column with the masthead, The Lead and the start of In Motion, two cards per row. |
| 900 × 600 · Dark · Sidebar closed | The same window with the sidebar hidden: The Lead and the rows span the window. |
| Partly filled | A library an hour after subscribing: The Lead with two slides and The Latest; every conditional lane hidden. |
| First launch | The existing Today empty state: "No Stories Yet", "Refresh Feeds". |
| Updates waiting | "Show 4 New Stories" in the leading toolbar; the edition has not moved. |
| Card variants | Lead, Developing, Feature, Compact and Coverage, light and dark, with the 8.2 anatomy and the token each part uses. |
| Lanes and bars | The six lanes with their copy, display condition, quality bar, minimum confidence and card variant. |
| Keyboard and focus | The two-dimensional keyboard map and where focus lands when a lane appears, hides or changes, and after closing a story. |

Images on the canvas are placeholders; the app shows publisher images or the editorial placeholder.
