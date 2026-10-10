# Starter feed catalog — 1 October 2026

## Scope

Implements #150 (Phase G, #97): a curated, opt-in starter catalog. Feed health indicators are #151.

## Implementation

- `FeedCatalog` (`Sources/Models/FeedCatalog.swift`) holds 49 feeds in nine sets: world 7, politics 4, business 4, technology 6, science and health 5, culture, food and lifestyle 5, Ukraine 6, Europe 6, Asia/Middle East/Africa 6. Each entry records publisher, feed title, URL, language, region (publisher's home country or `global`), topic, set, how much text the feed carries (full 9, partial 6, summary 34), whether it carries images (40) and an availability state: `available`, or `previewOnly` (6 feeds) where the feed works but article pages refused or could not be verified for an automated reader. Seven languages: English, Ukrainian, German, French, Italian, Dutch, Polish.
- Nothing is subscribed automatically. Settings → Subscriptions → Browse Catalog opens `FeedCatalogView`: sets subscribe in one step, single feeds subscribe or are removed individually, and the sheet states that the details describe how feeds looked on the verification date and are not a rating of accuracy. A catalog subscription is an ordinary subscription: `AppSettings.addCatalogFeeds` appends to `feedURLs`, one refresh covers a batch, and custom RSS, removal, OPML and the refresh path treat it identically. A fresh install subscribes to no catalog feed beyond its own three defaults.
- Entries are stored in `AppSettings.normalizeFeedURL` form (asserted per entry), so "subscribed" is plain equality and every feed is fetched exactly as verified.

## Verification (1 October 2026, one network location)

1. Nine research agents proposed about 190 candidates and probed each with a stdlib probe (two requests to the feed, the second conditional, plus the newest article). 127 passed: HTTPS 200, parseable, at least 5 items, newest item at most a week old, at least 80% unique links, official publisher feed, no hard paywall, no near-duplicate feed of the same publisher.
2. 49 were curated for balance and re-probed fresh in the exact URL form the app stores. The feed must be under the 10 MB feed limit: the 6.8 MB RBC-Ukraine feed was left out.
   Duplication across the final 49: no pair shares more than 29% of its sampled item links (The Guardian world and politics, 6 shared links; BBC politics and business, 13%); the rest are below 10%. Shared items are the same publisher cross-listing one document, which ingestion already resolves to one stored article.
3. `NEWS_LIVE_CATALOG_CHECK=1 ./test.sh` fetched and parsed all 49 through the app's own protected networking, parsers and redirect rules: 49 of 49 passed.
4. `./test.sh` covers catalog invariants offline: size 30 to 60, unique ids and URLs, normalized HTTPS URLs on plain public hosts, language and region codes, every set at least three feeds, seven languages, opt-in defaults, set subscription idempotence, custom RSS and removal beside catalog feeds, persistence, and one refresh for a batch.
5. Swift 6 type-check and staged arm64 `build.sh` with deep codesign verification passed. The sheet was rendered offscreen in light and dark appearance with in-memory state; layout and badges are as intended. This is not a keyboard-only or VoiceOver audit: buttons carry explicit accessibility labels.

## Findings

- `normalizeFeedURL` strips a trailing slash from the path, which breaks feeds that need it. Of the curated candidates, the Japan Times (403), Evropeiska Pravda (404) and Phys.org, The Atlantic and SCMP (a 301 that downgrades to HTTP, correctly blocked) only work with the slash. They are excluded here, and a user pasting such a URL hits the same failure. This is outside #150; filed as a separate follow-up.
- Several first-round rejections were probe artifacts (servers answering brotli unconditionally); the probe now decompresses. Feeds from sites that block automated clients (Suspilne, Times of Israel) stay out.

## Not verified

Publisher terms of use and image rights (feeds are fetched client-side by the subscriber, nothing is redistributed), reachability from other countries, longevity of any URL, and paywall status beyond one sampled article per feed. The availability and text columns are snapshots; live state is the feed's own health (#151).
