# Editorial novelty experiment — 6 November 2026

## Delivered boundary

The experimental `EditorialNovelty` actor retrieves a bounded historical baseline from the same event through an in-memory SQLite FTS5 index. It rejects self evidence, impossible publication/observation ordering and future evidence. A lexical miss returns a low-priority semantic-fallback decision; this slice does not schedule production background work.

Only sentences containing a whole-name core entity enter semantic selection. The injected provider reuses the shipped MiniLM engine, and similarity uses its existing vDSP cosine implementation. The bounded memory cache keys exact text, preprocessing version and model version, deduplicates same-batch requests and rejects writes from a cleared generation. One suspended analysis owns semantic work; concurrent requests defer instead of duplicating model work. Cancellation and energy checks surround model work. The chosen sentence is preserved verbatim with its article, passage fingerprint, publisher metadata and input/membership/analysis stamp.

There is no production consumer, persistent schema change or generated prose. The caller must validate the returned stamp before any future result write. Extraction preserves source wording; it does not verify the publisher's claim.

## Reproduction

```sh
bash script/test_editorial_novelty.sh Tests/Fixtures/editorial/novelty-smoke.json /private/tmp/new-novelty-results
```

The script builds the Release `NewsTestRunner` target through `News.xcodeproj`, executes only the editorial test atom and refuses to overwrite its report. Ordinary test runs use fixed vectors and never invoke the opt-in model evaluation. Xcode's synchronized source groups include the new files; `Tests/Runner.swift` provides the atom dispatch.

## Completed local evidence

- Xcode Debug build and 22 deterministic novelty checks passed, including historical exclusion, entity anchoring, exact citations, warm-cache reuse, energy deferral, concurrent-work deferral and a clear-during-inference race.
- Full local regressions passed through the current Xcode project. An arm64 Release app with a unique bundle identifier built and passed ad-hoc signature verification in a temporary directory; it was not installed or launched.
- A shipped-model Debug run completed on Apple M5 with 24 GiB memory. Its 24-case authored tune split selected repeat similarity `0.85` from the declared `0.85/0.90/0.95` sweep, using fewest false positives, then most true positives, then first threshold. Strong lexical overlap was fixed at the experimental value `0.4`.
- The untouched 24-case authored holdout produced 5 true positives, 0 false positives and 3 false negatives: observed precision 5/5 and recall 5/8. Five selected sentences are far too few to establish production precision.
- The first measured provider batch took approximately 2.419 seconds including model initialization. Later provider batches were approximately 1.75–2.15 ms. These are application-side Debug observations, not ANE spin-up attribution or a Release performance gate.
- The selected engine retained 64 unique cached vectors. Repeating the holdout added 32 cache hits and no misses. A disclosed shared provider cache reused text across tuning candidates; its timing is not an independent cold run per threshold.
- Corpus SHA-256: `3b1d14c5de241a5a52112fbb86050119df0731aa893111b5eda82e5345de341c`.

## Limits and remaining gate

The corpus contains fictional authored controls, with paired scenario templates across splits. Events and actors are disjoint, but this is narrow smoke coverage rather than a generalization holdout. Independent label review noted two ambiguous holdout repetition controls. Expected labels are used only for scoring and tune selection, never retrieval, embedding or candidate selection. Any deferred tune or holdout inference aborts evaluation instead of receiving credit as a negative outcome.

Production novelty quality, ANE/CPU power, ANE-specific spin-up and consumer integration remain unestablished. Thresholds above are experimental measurements, not shipping defaults. This report does not enable an overview, notification or Lead consumer.

## Review follow-up

Route-aware reporting now preserves predicted route counts and mismatched case IDs separately from binary novelty precision/recall. The unchanged holdout still yields 5 TP / 0 FP / 3 FN, but six route labels differ: three missed new-fact cases and three lexical-fallback controls that reach the unanchored route through shared generic words. Frozen labels were not changed to improve the result. This is an additional open routing-quality gate, not a perfect four-way classifier.

All 24 deterministic novelty checks passed after helper extraction and named cache statistics. The updated source SHA-256 is `e6a51d9ce3aacd45bb150a48706e2a77f759b65890b6c1eec3f366bfe141fb24`; model version and corpus remain unchanged.

The FTS5 candidate query previously OR-joined every token, so one shared article or preposition was a lexical hit. It now drops tokens under three characters and the shared event-matcher stopword set before querying. On the unchanged holdout the three unrelated fallback controls now route to the low-priority fallback: route mismatches fall from six to three (the three missed new-fact cases), and the result stays 5 TP / 0 FP / 3 FN with repeat similarity `0.85`. All 24 deterministic novelty checks pass. The updated source SHA-256 is `d4ad4705dcdddddf7e6a134ca32e15bcc2dc3b854a12897ebf4b6158c0bd4764`; model version and corpus remain unchanged.
