# Feed parsing cancellation — 2 October 2026

Refs #153, #104, #90. Base: `6322436`. Apple M5 / 24 GiB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4; optimized arm64, deployment target macOS 15.

## Finding

Feed parsing ignored cancellation. `FeedXMLParser` runs `XMLParser` synchronously and extracts each item's HTML into a reader document, up to 500 items from a response of up to 10 MB. A refresh cancelled after the response arrived — app shutdown, feed removal or sleep — kept parsing the whole feed. The aborted result was then reported as a parse failure rather than a cancellation.

## Change

- `FeedXMLParser` aborts at the next element once its task is cancelled.
- `JSONFeedParser` stops before the next item. Decoding itself is a single `JSONDecoder` call and is not interrupted.
- `FeedFetcher.fetchSingleFeed` checks cancellation after either parser, so an aborted parse is never reported as a malformed feed or returned with fresh validators. As before, `fetchAllFeeds` records no outcomes and `FeedManager` ingests nothing after cancellation.

## Measurement

`./test.sh --performance-baseline --active-work-cancellation` now adds a third workload. The fixture is a 500-item RSS feed (863,206 bytes); each item carries a heading and fifteen formatted paragraphs in `content:encoded`. An uncancelled parse of every item takes 1,207–1,233 ms. Each sample starts the real parser in a detached task, waits for it to start plus a quarter of the uncancelled time, asserts it is still running, then cancels. The parse must finish within two seconds and return no articles. [Raw evidence](../benchmarks/2026-10-02-feed-parsing-cancellation.json) holds two complete runs.

| Operation | Samples | Median ms | Sample p95 / maximum ms | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| Active feed parsing cancellation | 10 | 0.950 | 2.158 | 2.7 ms |

The budget allows 25% above the observed maximum, as in the [active-work audit](2026-10-02-active-work-cancellation.md). Latency is bounded by one item's extraction, not by the feed size. Without the parser change the same test fails: the cancelled parse returns all 500 articles.

A deterministic check also cancels a JSON Feed parse and expects no articles, and the uncancelled feed still parses. The full regression suite runs one sample of each workload.

## Limits

This is a controlled service measurement on synthetic `.example` data, with no network or model calls. It does not cover TLS or publisher transport behaviour, cancellation inside a single `JSONDecoder` call or single item extraction, or latency under arbitrary scheduler load. Production schema, settings and the installed app are unchanged; no app rebuild or installation is claimed.
