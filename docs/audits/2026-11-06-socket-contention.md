# Loopback socket contention in the test pool (6 November 2026)

Item A1 of the testing audit. GitHub run 42239564143 (macOS 26 runner) failed `testGatewayRejectionIsTransport` with `POSIXErrorCode(rawValue: 48): Address already in use`, twice in a row (the loopback rerun covers one transport error), while 21 other test jobs ran beside it.

## Measurements on this Mac (M5, macOS 27.2, ephemeral range 49152–65535, MSL 15 s)

- Socket states sampled every 10 s during a full `./test.sh` pool of 24 jobs: TIME_WAIT peaked at 63, loopback ESTABLISHED at 16, loopback LISTEN at 7. The ephemeral range is not exhausted here.
- 3,200 refused loopback connects to `127.0.0.1:1` from 8 processes at once (the fixture's refusing destination): 3,200 × `Connection refused`, no EADDRINUSE.
- The same from 8 processes each to its own just-cancelled listener port: mostly refused, but 75 of 3,200 attempts timed out and one failed with EINVAL, so a port whose listener just closed is not a reliable refuser; the fixture keeps port 1.
- A listener-churn reproduction with the gateway's parameters failed with EINVAL from a command-line script, so the listener side could not be measured outside the app.

The collision does not reproduce locally. It is specific to the loaded CI runner, and the failing log does not say whether the listener bind or the connect raised it.

## Change

- The four loopback socket tests (`testGatewayRejectionIsTransport`, `testSocketNetworkBoundary`, `testTransportCancellation`, `testGatewayAddressFallback`) run in their own lane, `NEWS_TEST_SHARD=sockets`, one after another in one process beside the other lanes, so no two socket tests share the ephemeral range at the same instant. The slow lane is unchanged, so the pool's longest job does not grow; the sockets lane took 93 s on a loaded Mac.
- A second loopback failure prints TIME_WAIT, loopback LISTEN and ESTABLISHED counts and the ephemeral range (`loopbackSocketSummary`), so the next CI failure names what collided.
- No retry was added; the single rerun of one transport error stays.

## Acceptance left

Three consecutive green CI runs on the macOS 26 job, and no `Address already in use` in the socket state line if it fails again.
