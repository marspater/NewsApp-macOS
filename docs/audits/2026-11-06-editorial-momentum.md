# Editorial momentum experiment — 6 November 2026

## Contract

`EditorialMomentum` is a pure, bounded publication-time replay over one event. Independent wire groups count once, conflicting known origins fail, and unknown provenance is counted separately rather than credited as independence. Fetch time controls final availability and diagnostics; it never becomes the activity timestamp. Duplicate imports and reordered available fetches produce identical points.

This is a retrospective final-as-of-`through` reconstruction. Backfills available at that cutoff can change earlier publication buckets; earlier points must not be interpreted as historical as-of alert predictions. A separate replay with the earlier cutoff excludes reports not yet fetched.

Fixed buckets include quiet periods. Short/long EMA, MACD, signal and histogram use explicit half-lives. Rate units are reports per configured nominal bucket, including partial-bucket scaling. Acceleration requires both recent independent-report and distinct-origin floors. Deceleration is a strict positive-to-negative histogram crossover; equality is neutral. The volume floor applies to acceleration only. Zero initialization and five-half-life warmup are reported explicitly; warmup is informational rather than a hidden state gate.

No production consumer, persistent momentum table or World Tension methodology is changed.

## Reproduction

```sh
bash script/test_editorial_momentum.sh /private/tmp/new-momentum-results
```

The script creates and validates an isolated Phase 0 database, exports event-disjoint controls, builds the Xcode Release test runner and refuses to overwrite its report. Normal tests run deterministic mathematical controls without that sweep.

## Completed evidence

- 27 Xcode Debug checks passed: hand-calculated EMA/MACD, partial buckets, zero bins, independence floors, syndication, unknown/conflicting provenance, duplicates, fetch order, delayed availability, pre-window wires, cancellation, invalid input limits and evaluation boundaries.
- A 64-configuration tune sweep used 25 events; the other 25 events were evaluated only after selection. Selection minimized tune false positives, then maximized true positives, then retained the first configuration.
- Selected experimental values: 300-second buckets, 1,800/10,800-second short/long half-lives, 1,800-second signal half-life, 3,600-second volume window, three independent reports and two originating publishers. These are not shipping defaults.
- Synthetic holdout: 10 true positives, 15 true negatives, no false positives or false negatives. Quiet controls include eight slow-weekend and seven syndicated events. Median Debug replay latency was approximately 0.340 ms per event over the declared 48-hour horizon.
- Scored windows are bucket-aligned and exclude the bucket ending exactly at their start. Unaligned windows fail instead of mixing earlier activity into the score.
- Full local Xcode regressions, formatting lint and an isolated arm64 ad-hoc Release app build passed. The app was not installed or launched.

## Remaining gate

The fixture validates routing, mathematics and controlled burst shapes, not editorial accuracy on real news. Production insert/update latency, live warmup policy, independent-origin evidence and consumer integration remain unestablished. Release experiment timing is not claimed from this Debug run. Existing Briefing, Lead and notification behavior remains in effect.

Independent-origin evidence on real rows is measured in [the wire identity audit](2026-11-06-editorial-wire-identity.md).
