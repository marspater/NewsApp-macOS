# Protected transport cancellation — 2 October 2026

Refs #104, #153, #90. Apple M5 / 24 GiB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4; optimized arm64, deployment target macOS 15.

## Finding and fix

The controlled regression first failed because refresh shutdown returned but the upstream socket remained open beyond the two-second deadline. `SOCKSTunnel.relay` forwarded EOF with `isComplete` and the default message context. That ends a logical message, without closing the TCP write direction. The opposite endpoint therefore never saw EOF, leaving the tunnel waiting for its inactivity timeout.

The shared relay now sends each ordinary chunk as a complete default message and uses `.finalMessage` for EOF. This follows [Apple's TCP write-close contract](https://developer.apple.com/documentation/network/nwconnection/send%28content%3Acontentcontext%3Aiscomplete%3Acompletion%3A%29-5ecuz). It retains the existing two-direction drain before finishing. Destination validation, numeric-IP pinning, fail-closed routing, bounds and timeouts are unchanged.

## Reproduction and measurement

Run `./test.sh --transport-cancellation`. The command builds optimized tests and emits `TRANSPORT_CANCELLATION_REPORT`; the same assertions run in the full regression suite. [Raw samples and machine metadata](../benchmarks/2026-10-02-transport-cancellation.json) are committed.

Each sample runs `FeedManager` → `FeedFetcher` → `SecureHTTPClient` → native URLSession → production SOCKS proxy → a controlled TCP listener. Production preflight and proxy resolution validate the public literal address; the existing test connector then routes that validated numeric endpoint to the local fixture. No external publisher is contacted, no URLProtocol mock is involved, and no security check permits a private destination.

Five samples hold the response before headers. Five send headers and 4 KiB of a declared 1 MiB body, then hold the remaining bytes. Synchronization observes the full server request and, for the body case, successful partial write completion. It does not assert the exact position of URLSession's byte iterator.

The timer starts immediately before `stopBackgroundWork()` and ends when `fetchFeedsAsync()` returns. A completion timestamp inside the refresh task excludes the five-millisecond observer polling interval. Each sample separately asserts upstream EOF or socket failure within two seconds, ended loading state, zero ingested articles and no feed failure or validators. Socket teardown latency itself is not timed.

| Held response | Samples | Median ms | Maximum ms | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| Before headers | 5 | 0.156 | 0.775 | 1.0 ms |
| After partial body write | 5 | 0.139 | 0.173 | 0.3 ms |

Budgets are 25% above the observed maximum, rounded upward to 0.1 ms, for this controlled workload on comparable hardware. They are investigation triggers, not CI thresholds or production guarantees; five samples do not establish a population p95. Regression deadlines remain two seconds.

A separate raw SOCKS control closes the client's write direction before the upstream sends anything. All 64 KiB of the subsequent response, spanning multiple 32 KiB relay buffers, must arrive unchanged followed by EOF. This guards against fixing cancellation by discarding a valid half-closed response.

Each sample uses temporary defaults and an empty in-memory library. No real settings, saved/read state or installed app is touched. The production app build is staged under `/tmp`; there is no installation or launch claim. Full regressions are enforced by the mandatory commit hook; build and hosted CI results are recorded on the PR.

## Remaining acceptance

#104 and #153 remain open for cold production launch, production memory, publisher/TLS behavior and cancellation during active parsing, database work or model execution. This slice verifies explicit refresh shutdown over controlled HTTP sockets. Reader/overview accessibility remains independently tracked in #123/#155.
