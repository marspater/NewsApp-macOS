# Live publisher refresh and cancellation — 3 October 2026

Refs #153, #104, #90. Base: `381c003`. Apple M5 / 24 GiB, macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4; optimized arm64.

Earlier cancellation slices used controlled sockets ([transport](2026-10-02-transport-cancellation.md)), synthetic service work ([active work](2026-10-02-active-work-cancellation.md)) and a synthetic feed ([parsing](2026-10-02-feed-parsing-cancellation.md)). This slice runs the production refresh against real publishers over HTTPS.

## Method

Run `./test.sh --publisher-cancellation`. It is opt-in, live and optimized. Each sample builds a new temporary library and settings, subscribes to the twelve tension panel feeds (stable, catalog-verified publishers from six regions) and runs `FeedManager.fetchFeedsAsync` through the production `SecureHTTPClient`: real DNS, TLS, the protected proxy, parsing and ingestion.

1. Two uncancelled refreshes from an empty library record refresh duration.
2. Six refreshes are stopped with `stopBackgroundWork()` after 25, 75, 150, 300, 600 and 1,200 ms, so the stop lands in different phases: connection and TLS setup, transfer and parsing, or ingestion. A refresh that already finished is recorded but not timed.

Each sample asserts completion within two seconds, cleared loading state, an intact database and that no feed keeps HTTP validators without its stored articles, so a later `304 Not Modified` cannot hide items that were never saved.

## Results

[Raw evidence](../benchmarks/2026-10-03-publisher-cancellation.json): two complete runs.

| Measure | Samples | Median | Maximum | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| Uncancelled refresh, 12 live feeds, ~429 stories | 4 | 1,068.6 ms | 1,452.1 ms | — |
| Stop during a live refresh | 10 | 1.0 ms | 18.4 ms | 23 ms |

The first refresh of each run (1,422–1,452 ms) includes cold DNS and TLS session setup; the second took 683–715 ms. Network conditions vary, so the refresh times are observations, not a budget.

Stops at 25–300 ms stored nothing and recorded no feed state: they landed before the batch reached ingestion. Stops at 600 ms landed during ingestion: 336 and 181 of 429 stories were stored from the feeds already ingested, each with its validators, and the remaining feeds kept none, so the next refresh fetches them in full. At 1,200 ms both refreshes had already finished.

## Limits

Two runs from one network on one day. Which phase a stop hits depends on network timing and is inferred from the stored rows, not observed directly. Cancellation inside a single TLS handshake or URLSession transfer is the system's; the measurement covers the app returning from it. The test contacts twelve public feeds about eight times per run; it is not part of the default suite.
