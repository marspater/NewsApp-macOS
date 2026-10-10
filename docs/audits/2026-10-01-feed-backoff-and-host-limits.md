# Retry-After, backoff and per-host limits — 1 October 2026

## Scope

Implements #148 (Phase G, #97) on top of conditional requests (#147).

## Implementation

- `FeedRetryPolicy` (`Sources/Models/FeedFetchState.swift`) is the pure schedule: 10 minutes after the first failure, doubling to a 6 hour cap, with `Retry-After` (delay-seconds or HTTP date) as a lower bound capped at 24 hours. A server asking for less than our backoff gets our backoff; a negative or absurd value cannot silence a feed for good or overflow. Obsolete RFC 850 and asctime dates are not recognized.
- `SecureHTTPClient.fetchFeed` reports 429 and 503 as `FeedError.serverBusy(status:retryAfter:)`. Article and image requests keep `httpStatus`, so reader behavior is unchanged.
- Schema v10 adds `consecutive_failures` and `next_attempt_at` to the existing `feeds` table. The migration skips columns that already exist, like v4, so reconstructed older libraries still migrate. `recordFeedFailure` forgives failures older than one maximum delay past the last wait, so a subscription re-added months later starts fresh.
- `FeedFetcher.fetchAllFeeds` is the only refresh path, scheduled or manual. Feeds whose wait has not ended are not requested and report `FeedError.retryScheduled(until:)`, shown by the existing failure status and tooltips. It runs at most six requests overall and two per host, picking the next eligible feed when a slot frees. A host that answered 429/503 is cooled for the remainder of the app run, including feeds queued behind the refused one; the cooldown is in memory, so after relaunch each other feed of that host probes once.
- Outcomes are recorded after the batch: 200/304 clears the schedule, failures extend it. Not counted: local rejections (bad URL, blocked host/port, insecure scheme), cancelled refreshes, and batches where every request failed to connect, which means this device is offline rather than the feeds being broken. Validators are untouched by schedule writes.

## Verification

- `./test.sh` (full suite, repeated runs): passed, including `testFeedBackoffAndHostLimits`: policy and header parsing, persistence across reopening, success reset, forgiveness, 429 with `Retry-After`, a manual refresh inside the wait sending no request, recovery, exponential 5xx backoff, 503 without header, local rejections, offline versus mixed batches, per-host concurrency measured with held requests (two per host, four overall across two hosts), a refused host's queued sibling never requested, cooldown outliving one refresh, cancellation recording nothing, and `FeedManager` status for a refused then paused feed. The v4/v5/v6 migration fixtures now end at schema 10.
- Swift 6 type-check and staged arm64 `build.sh` with deep codesign verification: passed.
- Tests use IP-literal public hosts and held `URLProtocol` requests; no live server was contacted.

## Remaining

Backoff counters are per feed while `Retry-After` cooling is per host and in memory. No UI offers to retry a paused feed early: the wait is the server's or the policy's. Health indicators for paused and failing feeds are #151.
