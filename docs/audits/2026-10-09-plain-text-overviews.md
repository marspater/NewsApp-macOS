# Plain-text overviews and news analysis — 9 October 2026

## Implementation

The production reader coordinator now calls the on-device composer. Drafts contain one sentence and one short local passage ID per line; code maps that ID to the original stored article, passage and fingerprint. This avoids the model confusing long article hashes with passage IDs. Introduction sentences have persisted citations and the same source-opening controls as key facts. Overview analysis version 4 invalidates earlier parser results; article analysis remains at version 3. The [Codacy follow-up](2026-10-09-codacy-slices.md) records parser corrections and fresh verification.

Each proposed sentence passes citation/quote lineage, numeric/date/unit/negation checks and the existing quality auditor, followed by a fresh one-token support judgment against its cited passage. Rejected sentences are removed. Fewer than three retained facts, a missing introduction, excessive rejection, malformed output or refusal keeps the current deterministic overview. Support inference is a model judgment, not a proof of semantic entailment. Existing publisher-attributed perspectives and sourced timelines remain available.

Generation runs on demand and warms at most three covered, unmuted visible events after curation. AI, Low Power and thermal rules gate inference. Cancellation reaches the queued model operation; an older task cannot remove a newer task's queue entry. Publisher-input and membership checks still reject stale writes.

Classification and interactive analysis use strict plain-text contracts with their native fallbacks. Short articles may return two supported key points; requiring a third forced valid sensitive-news answers into fallback. Entities and sentiment continue to come from source-based native extractors. Older feed HTML entities are decoded in synthesized prose, while citation quotes and fingerprints retain their original input.

## Measurement

The audit used the temporary read-only backup described in [the curation/image audit](2026-10-09-story-curation-images.md), not the installed library. Eight covered events produced five accepted model overviews and three deterministic fallbacks. All 40 retained introductory/key-fact claims passed the audit, with zero numeric, date or attribution errors. Every retained generated sentence was also reviewed locally against its cited publisher passage; no added factual assertion was found. Three labeled controls retained their fallbacks, with seven supported claims and zero critical errors. **Those controls do not establish generative quality:** their drafts failed the format/retained-fact threshold.

On one live report of deaths in a strike, both classification and interactive analysis used the plain-text on-device model. The analysis preserved the two casualty figures and attribution. Model output remains variable; sample acceptance and fidelity are observations, not a guarantee for other reporting. Several accepted overviews repeat source wording, and independent quality labels would be needed for broader claims about synthesis quality.

Publisher passages, model requests/answers and private audit records remain under `/private/tmp/news-story-live/`; they are excluded from commits and public PRs. No sealed holdout, publisher-label promotion or new capture schedule was used. The snapshot's event membership was used for measurement; the separately launched verification app refreshed and clustered its own isolated copy.

## Verification

Full-suite commit hook passed for the implementation. Stub-model tests exercise malformed output, refusals, unsupported claims, citation fingerprints, introduction audit grain, SQLite persistence, reader-to-composer integration, AI policy and cancellation. Native UI 73/73, reader 26/26 and overview 49/49 harness checks passed. An isolated arm64 ad-hoc bundle built and passed strict signing/plist checks; the live reader and citation controls are checked separately. These checks do not represent spoken VoiceOver (#268 remains parked), installation, hosted CI success or merge.
