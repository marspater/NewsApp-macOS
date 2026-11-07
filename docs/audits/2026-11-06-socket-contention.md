# Loopback socket contention in the test pool (6 November 2026)

Item A1 of the testing audit. GitHub run 42239564143 (macOS 26 runner) failed `testGatewayRejectionIsTransport` with `POSIXErrorCode(rawValue: 48): Address already in use`, twice in a row (the loopback rerun covers one transport error), while 21 other test jobs ran beside it.

## Measurements on this Mac (M5, macOS 27.2, ephemeral range 49152–65535, MSL 15 s)

- Socket states sampled every 10 s during a full `./test.sh` pool of 24 jobs: TIME_WAIT peaked at 63, loopback ESTABLISHED at 16, loopback LISTEN at 7. The ephemeral range is not exhausted here.
- 3,200 refused loopback connects to `127.0.0.1:1` from 8 processes at once (the fixture's refusing destination): 3,200 × `Connection refused`, no EADDRINUSE.
- The same from 8 processes each to its own just-cancelled listener port: mostly refused, but 75 of 3,200 attempts timed out and one failed with EINVAL, so a port whose listener just closed is not a reliable refuser; the fixture keeps port 1.
- A listener-churn reproduction with the gateway's parameters failed with EINVAL from a command-line script, so the listener side could not be measured outside the app.

The collision does not reproduce locally. It is specific to the loaded CI runner, and the failing log does not say whether the listener bind or the connect raised it.

Update, 7 November 2026: the `NEWS_TEST_SHARD=sockets` lane below is now the `Tests/SocketTests.swift` atom, still one process running the four tests in order (docs/audits/2026-11-07-newstests-split.md).

## Change

- The four loopback socket tests (`testGatewayRejectionIsTransport`, `testSocketNetworkBoundary`, `testTransportCancellation`, `testGatewayAddressFallback`) run in their own lane, `NEWS_TEST_SHARD=sockets`, one after another in one process beside the other lanes, so no two socket tests share the ephemeral range at the same instant. The slow lane is unchanged, so the pool's longest job does not grow; the sockets lane took 93 s on a loaded Mac.
- A second loopback failure prints TIME_WAIT, loopback LISTEN and ESTABLISHED counts and the ephemeral range (`loopbackSocketSummary`), so the next CI failure names what collided.
- No retry was added; the single rerun of one transport error stays.

## Acceptance left

Three consecutive green runs of the GitHub macOS 26 test job with this lane in place. If a loopback test fails again with a transport error (`LoopbackTimeout` or `EADDRINUSE`) and its rerun throws too, the job log carries a `socket state at the second failure (<error>):` line with the error and the counts: TIME_WAIT overall and on loopback with the number of distinct loopback local ports inside the ephemeral range, loopback LISTEN and ESTABLISHED, and the range itself. A first error of another kind, or an assertion failure (the harness exits on it), produces no line and is read from the test's own output. The line is a hypothesis to check against the error, not a verdict. `Address already in use` with loopback TIME_WAIT ports near the size of the ephemeral range points at port exhaustion, and the lane needs fewer connections per test; the summary cannot tell a listener bind from a connect, but every listener in these tests binds port `.any`, so address-in-use from either operation is the kernel finding no free port, the same condition. `Address already in use` with low counts is inconclusive: the summary is one sample taken after the failure, so both the listener start and the connect path are read next; any other error is a new failure and is read on its own.

## First-failure evidence (7 November 2026, #577)

A green macOS 26 run (GitHub run 42359059160, main) logged `↻ Loopback transport error under load (POSIXErrorCode(rawValue: 48): Address already in use)` in `testSocketNetworkBoundary` on the first attempt; the rerun passed, so no summary printed and the log could not say which operation failed. The test helpers now name the operation where the error leaves them, and the socket summary prints on the first failure as well as the second. No retry, timeout or lane changed.

The new lines, in the order a first transport error prints them:

```
  loopback <operation> failed (<error>)
  ↻ Loopback transport error under load (<error>); running the socket test once more
  socket state at the first failure (<error>): TIME_WAIT … ephemeral ports 49152-65535
```

`<operation>` is one of `listener start (<listener>, port .any)` (the silent, upstream, cancellation upstream and boundary upstream fixture listeners in `Tests/SocketTests.swift`, or `NetworkBoundaryProxy` when its `port()` fails inside `socksConnect`), `connect to 127.0.0.1:<port>` (the `socksConnect` client), `send to <endpoint>` or `receive from <endpoint>`. A transport error with no `loopback … failed` line above it came from somewhere the helpers do not wrap (the production gateway's own upstream connection or a URLSession path) and is read from the test's own code. The counts stay hypotheses, as in the paragraph above. Since #577's failure aggregation, an assertion failure no longer exits the atom: it is recorded, the atom continues and its summary names it, and it still never triggers the rerun.

No CI failure has produced the new lines yet; the CI logs after this change are read for them.

Local reproduction on this Mac, same day: 24 copies of the `Tests/SocketTests.swift` atom started at once from one runner build. Four first attempts failed with `Address already in use`, each printed `loopback connect to 127.0.0.1:<port> failed`, the port being the `NetworkBoundaryProxy` listener `socksConnect` dials (twice in `testGatewayAddressFallback`, once each in `testSocketNetworkBoundary` and `testTransportCancellation`); all four reruns passed. No listener start failed. On this machine the collision is therefore the outbound connect, still with listeners on port `.any`. One more finding: every first-failure summary read `TIME_WAIT 0 … loopback LISTEN 0, loopback ESTABLISHED 0`, while a shell `netstat -an -p tcp` right after the 24 runs counted 1,714 TIME_WAIT rows. The runner is not sandboxed (its entitlements carry only `get-task-allow`) and the same `Process`/`netstat` call works from a script, so the zero TIME_WAIT is a real sample taken early in the burst, before the runs had closed their connections: exhaustion did not cause these collisions. The loopback LISTEN count, though, could never be nonzero: listeners on port `.any` appear as `*.<port>`, not `127.0.0.1`. The summary now counts every TCP `LISTEN` row instead.
