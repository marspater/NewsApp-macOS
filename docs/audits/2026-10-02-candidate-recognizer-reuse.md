# Candidate language recognition — 2 October 2026

Refs #153, #104, #90. Follow-up to #223, based on `76c9673`; one production file changes. Reader UI work remains separate in #123/#155.

## Profile and change

A five-second `sample PID 5 1` trace of the original optimized benchmark's dense pass found 2,016 stack samples inside `EventClusterer.run`: 1,180 under the SQLite candidate query (58.5%) and 807 under candidate language recognition (40.0%). The latter repeatedly constructs native language-model state. These are sampled stacks, not exact wall-time attribution. Profiling perturbs runtime; that run is excluded from the timing comparison. Raw process/library inventories are kept out of this public audit.

`EventCandidateFinder` now creates one `NLLanguageRecognizer` after fetching a candidate list and resets it before each text. The selected SDK's `NLLanguageRecognizer.h` documents reset as restoring initial state for reuse and forbids concurrent use of an instance. Here the recognizer stays local to one synchronous loop, with no suspension or cross-task sharing. Calls outside that loop still create independent instances. Detection text, confidence threshold (0.5), unknown-language eligibility, candidate order/limits and matching rules are unchanged; there is no cache, migration or matcher-version change.

A 1,000-analysis alternating English/German/empty-text probe retained identical results: fresh recognizers took 882.351 ms, reuse 474.163 ms. This small probe motivated the integrated measurement; it is not the shipping-app speedup.

## Integrated measurements

Same Apple M5 / 24 GiB, arm64, macOS 27.0.1 (26A434), Xcode 27 / Swift 6.4, `-O`, minimum macOS 15. Run `./test.sh --performance-baseline`; the app build and benchmark compilation finished before timed execution. Before: [#223 raw samples](../benchmarks/2026-10-02-integrated-core-baseline.json). After: [raw samples](../benchmarks/2026-10-02-candidate-recognizer-reuse.json). Independent runs, with five dense samples each; sample p95 is their maximum.

| Operation | Before median ms | After median ms | Before sample p95 ms | After sample p95 ms |
| --- | ---: | ---: | ---: | ---: |
| Dense clustering, 200 reset rows | 15,867.576 | 13,496.330 | 16,092.638 | 16,409.388 |
| Unchanged clustering | 11.755 | 13.721 | 12.360 | 14.242 |
| FTS, first 100 | 66.411 | 87.186 | 70.897 | 125.076 |

The observed dense-pass median decreased by **14.9%**, but its slowest sample increased from 16.093 s to 16.409 s. Unchanged clustering and FTS controls were also slower in this run despite unchanged SQL, so the run has environmental/timing variability: the median comparison is preliminary evidence, not controlled attribution of a 14.9% speedup or a tail-latency improvement. Each of the five passes resets the same 200 rows and asserts exactly 200 processed and no pending rows. Unchanged passes assert zero processed rows. Both runs end with 10,250 rows and keep the 500-row store snapshot. Generic overlapping research text deliberately stresses candidate retrieval; this is neither a representative publisher corpus nor a precision/recall evaluation. Peak benchmark-process RSS after: 119.938 MiB, including fixture setup.

SQLite candidate retrieval remains a substantial cost. Query ranking/tie order, archive filters and schema are preserved. The earlier investigation budgets remain provisional; this small resource-lifetime fix does not justify a new release-wide latency guarantee.

## Verification and remaining scope

Full `./test.sh` passed. The candidate regression alternates confident English, German and empty texts through one recognizer and compares each result with an independent recognizer, guarding against accumulated language evidence and lost nil results. Existing candidate language filtering, event membership, exclusions, incremental processing and cancellation regressions also passed. The optimized baseline passed all workload assertions.

An isolated `./build.sh` passed with Swift 6 and optimization, arm64 Mach-O output, valid Info.plist, strict signature verification, and retained App Sandbox / Hardened Runtime. The staging bundle is not installed or launched. No real library, settings, existing app bundle or UI files were modified. The mandatory commit hook reruns the full suite before publication; hosted CI is reported separately on the PR. Shared plan/changelog integration is deferred to keep the parallel reader slice independent.

#104/#153 remain open for cold launch, real transport and active-work cancellation, production memory and any future model path. Native reader interaction is assigned to the parallel #123/#155 work; clustering holdout accuracy remains #102.
