# Refresh decoupled from follow-up work — 1 October 2026

## Scope

Implements #149 (Phase G, #97). No generated overviews exist yet (Phases D/E); this slice fixes what the refresh path waited for today and fixes the contract those phases will build on.

## Findings

- `performRefreshPipeline` awaited notification triage (NaturalLanguage scoring and delivery) before the refresh finished, so the spinner, the disabled refresh button and the single-flight task all lasted until triage ended. A Cmd-R during that time was coalesced onto the finishing run and fetched nothing.
- Every refresh cancelled the whole classification queue with `cancelAll(.superseded)` and re-enqueued the 500 visible articles. `cancelAll` also marked finished jobs cancelled, so the queue's duplicate check never held and the same articles were classified and rewritten (and republished to the UI) on every refresh.
- The enrichment queue is bounded (three jobs) and cheap by design: topic classification without Foundation Models. Nothing in the refresh path waited for it.

## Implementation

- `FeedManager.fetchFeedsAsync` returns once collection is done. The refresh task resolves to the newly stored articles, clears the single-flight state and `isAnyFeedLoading`, then the caller that started the run performs triage and schedules classification. Joiners return when collection ends. Cancellation by removing a feed or stopping still skips follow-up work.
- `EnrichmentQueue.cancelAll` leaves completed jobs alone, matching its documented "pending and in-flight" contract; re-enqueueing a finished article is a no-op, so only new or interrupted articles are classified.
- `FeedManager` skips scheduling classification when Low Power Mode is on or the thermal state is serious or worse (injectable `allowsBackgroundWork`); the next refresh picks the backlog up again. The `NSBackgroundActivityScheduler` handler completes with `.deferred` when `shouldDefer` is true. The existing settings copy already limits updates to while the app runs, and no refresh is promised while it is closed.
- `FeedManager` accepts an injectable `EnrichmentQueue`, defaulting to the previous behavior.

## Verification

- `./test.sh` (full suite, repeated runs): passed, including `testRefreshEndsAtCollection` (blocked triage leaves the spinner off, articles published and the feed idle; a second refresh during triage collects again; energy saving schedules nothing, then classification completes once it ends) and the extended queue test (finished work survives `cancelAll` and re-enqueueing). The earlier queue assertion now accepts a job that finished before it was superseded, which the old test only avoided by timing.
- Swift 6 type-check and staged arm64 `build.sh` with deep codesign verification: passed.
- Low Power Mode, thermal state and `shouldDefer` are platform signals; they are injected or inspected, not exercised on a device here.

## Remaining

Notification triage is still awaited by the caller that started the run, so a test or script awaiting `fetchFeedsAsync()` also waits for it; the UI starts refreshes without awaiting. Per-visible-event overview generation arrives with Phase E.
