# Conditional feed requests — 1 October 2026

## Scope

Implements #147 (Phase G, #97). Honoring `Retry-After`, backoff and per-host limits is #148; decoupling refresh from enrichment is #149.

## Implementation

- `FeedValidators` (`Sources/Models/FeedFetchState.swift`) holds the `ETag` and `Last-Modified` a publisher returned. Both are untrusted response headers: only printable ASCII up to 512 bytes is kept, so a hostile value cannot inject request headers or grow the row.
- `SecureHTTPClient.fetchFeed(from:allowHTTP:validators:)` sends `If-None-Match` and `If-Modified-Since` and, only for such a conditional request, accepts 304 with an empty body. An unsolicited 304 is still `FeedError.httpStatus(304)`. The reload cache policy stays, so URLSession returns the 304 instead of replaying its own cache. Destination validation, pinning, redirects and byte bounds are unchanged.
- `FeedFetcher` takes an injectable client, reads stored validators once per batch and reports `articles == nil, error == nil` for 304. A fresh 200 carries its (possibly empty) validators in the result; a failed fetch or parse carries none.
- `DatabaseEngine.upsertArticles(_:feedUrl:validators:)` writes validators to the previously unused `feeds` columns in the ingestion transaction. A failed or cancelled ingest therefore leaves the old validators and the next refresh is not answered 304 for items that were never stored. A 200 without validators clears stale ones; a 200 with zero items stores nothing. No schema migration: the columns exist since v1.
- `clearArticleCache` and `clearAllDatabaseCache` reset all validators in their transaction, so the next refresh restores feed-provided bodies as before.
- `FeedManager.FeedBatch` elements gain `validators`; the default fetcher is built from the injected store's database. Existing injected test closures only gained a trailing `nil`.

## Verification

- `./test.sh` (full suite): passed, including `testConditionalFeedRequests`: header replay and weak ETag, unsolicited 304, header-injection and non-ASCII rejection, first refresh unconditional, 304 refresh with unchanged articles/notifications/status, failed ingestion keeping old validators (trigger-injected), server answering 200 to a conditional request, validators advancing/clearing, and cache purge reset.
- Swift 6 type-check of the app target and staged arm64 `build.sh` (isolated copy, deep codesign verify): passed.
- Real servers differ: probing live feeds showed Ukrainska Pravda answering 304 to both validators, the Guardian sending a weak ETag but answering 200 to the conditional request, and BBC sending no validators. All three paths are exercised by the fixtures; no live network behavior is claimed beyond that probe.

## Remaining

A server that wrongly answers 304 for changed content would hide updates until its validators change; there is no periodic unconditional refetch. Nothing is installed over an existing app.
