# Candidate evaluation corpus — October 2, 2026

Refs #102, #91, #90. Base: `775bec0` (including merged FTS/performance and Phase D clustering/feed work).

Added a reproducible W2E metadata sample and clearly distinguished derived/authored controls: 460 pairs, 490 documents, 100 imported single-event topics and 60 fictional events. Families connected by merged topics/shared URLs stay in one split. Split counts: 322 tuning, 138 holdout. Corpus checksum: `147ef0ad148ed5693c8f01e70262a890cd65f7d6e5d46c62ae5949e3dd9e0fa2`.

The corpus and runnable instructions live in [the fixture README](../../Tests/Fixtures/story-corpus/README.md). Python standard-library checks validate the checksum, label/reference consistency, family isolation, absence of public publisher bodies, and metric calculations. The native adapter checks production URL canonicalization and calls the existing exact publisher-text fingerprint function. Local text is optional and never emitted in reports.

## Completed checks

- Byte-for-byte regeneration from the three recorded source inputs passed (`cmp`).
- Corpus/metric self-checks passed, including invalid labels, split leakage, duplicate pairs, forbidden publisher bodies, binary vs three-way scoring, missing predictions, and explicit abstentions.
- Native fingerprint **tuning only**: 42 authored pairs evaluated (21 copy positives, 21 hard negatives), all classified as expected; 280 metadata-only pairs abstained. These controls provide no real-publisher accuracy evidence.
- `./test.sh` passed on arm64 with deployment target macOS 15. No app behavior or production storage changed; app build/install/live publisher checks were not performed.
- Builder output safety checks passed: existing files, symlinks, non-JSON names and paths outside fixture/temp roots are rejected. Refactored builder regeneration retained the frozen corpus checksum.
- `git diff --check` passed.

## Acceptance still open

Imported topic-level annotations need independent event/document adjudication. Real same-document variants, private publisher text, verified timestamps and language labels remain missing. The ≥99% fingerprint holdout release gate has **not** been measured. Holdout predictions were not run and thresholds were not tuned. Source/language/provenance reporting exists, but imported language remains explicitly unknown and synthetic controls do not establish multilingual news accuracy. Event-clustering evaluation requires predictions from that pipeline.

This slice is partial coverage of #102. Do not close the issue, mark phase A complete, or infer release readiness from these checks. Phase E and G implementation was untouched.
