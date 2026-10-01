# Feed health indicators — 1 October 2026

## Scope

Implements #151 (Phase G, #97): availability, freshness and full-text quality per feed, shown as operational health only.

## Implementation

- Schema v11 adds `latest_item_at`, `item_count` and `full_text_items` to the existing `feeds` table (idempotent like v10). `upsertArticles` writes them together with the validators in the ingestion transaction, from the response's own articles (`FeedContentStats`): newest dated item, item count, and items carrying at least 1200 characters of feed text. A 304 or a failure leaves them unchanged; a response with no items stores nothing. `feedFetchStates()` now returns every stored row, including `last_fetched_at`.
- `FeedHealth` is a pure value derived from the stored state and a clock. Availability: unknown (never fetched), responding, or failing with the failure count and next attempt. Freshness: recent within 3 days, quiet within 30, stale beyond (future-dated items count as recent, undated items are ignored). Text quality: full from 80% full-text items, partial from 30%, otherwise summaries; unknown without items. The 1200-character and 80% rules match how the catalog's text column was measured.
- `FeedManager.feedHealth` is published after each refresh, once the cached library loads and whenever Settings or the catalog sheet appears (`reloadFeedHealth`). Settings → Subscriptions shows one line per feed ("Responding · Newest item 2 hours ago · Full text"; "Not responding (2 failed attempts), retrying in 19 minutes · …") and the catalog shows it for subscribed feeds. Attention states (failing, inactive for over a month) use a warning icon; the text stays in the secondary color for contrast, and each line has a single accessibility label.
- The wording and the footnote under the list (`FeedHealth.disclaimer`) state that health is not a rating of accuracy or trustworthiness; a test rules out credibility, bias, reliability and score vocabulary in the summaries.

## Verification

- `./test.sh` (full suite): passed, including `testFeedHealth`: availability, freshness and text-quality boundaries, attention states, summary wording, content stats (1200 versus 1199 characters, undated items), persistence with ingest, unchanged by 304 and failures, replacement by a newer response, validators untouched, and a `FeedManager` refresh publishing responding and then failing health with content stats retained. The v4 migration fixture now ends at schema 11.
- Swift 6 type-check and staged arm64 `build.sh` with deep codesign verification: passed.
- The catalog sheet with seeded health (responding, failing, inactive, unchecked) was rendered offscreen in light and dark appearance; layout is as intended. No keyboard-only or VoiceOver audit was performed and the Settings tab itself was not rendered.

## Remaining

Health is computed when it is loaded, so "recent" can lag until the next refresh or view appearance. It is per feed and reflects one network location; it cannot tell a feed that publishes slowly from one that stopped. Quality of reporting is deliberately out of scope.
