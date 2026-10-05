# Fingerprint release-language scope — 5 October 2026

Refs #102, #90. Base `617c934` (merged #271). The current release is English-only; parked #264/#268 remain outside its gates.

## Confirmed problem and fix

`StoryCorpus.capture` added the optional targeted feed list after selecting the supported catalog. That list still contains parked-language feeds, so they could be fetched despite the English-only release. `reviewCaptures` then combined historical files without filtering curated feed languages. Non-English observations could inflate the eligible canonical-document denominator and influence candidate/false-merge totals for an English release.

Both paths now reuse `FeedCatalog.supportedLanguages`. Extra feeds are filtered before fetching, and old captured observations are filtered before fingerprints, candidates and denominators are calculated. The summary reports the supported language set. Original capture files and parked catalog entries are preserved; host-based splits, matching logic, labels, Wilson bounds and acceptance thresholds are unchanged.

The existing regression now includes otherwise matching parked-language items on both synthetic tuning and holdout hosts. Observation counts, eligible documents and candidate counts stay at their original English values; a separate assertion excludes parked language eligibility. These are synthetic checks, not a replay of the private holdout.

## Live tuning evidence

A new private capture used the catalog plus the existing targeted list: **65 feeds, one failed feed, 2,153 items, all declared English**. The new file has permissions 0600; the earlier capture is retained. The installed app and user database/settings are not used.

`./test.sh --corpus-review <private capture directory>` ran without `--corpus-holdout`. [Aggregate tuning report](../benchmarks/2026-10-05-fingerprint-release-scope.json): two capture files, 1,704 unique English tuning observations, 192 eligible observations and **174 distinct eligible canonical documents**. Different-URL candidates: **zero**; precision is undefined (`null`), not 100%. Tuning false-merge Wilson upper bound: **2.16%**; `releaseGatePassed` remains false.

No holdout review file was created, no private fingerprint holdout outcomes were computed, and the accepted event holdout was not replayed. The 174 tuning documents do not establish the holdout denominator. The final fingerprint gate still requires its own held-out evidence: with zero false merges, at least 381 distinct eligible holdout documents. Existing approved captures continue accumulating data; no schedule was changed or duplicated.

## Status reconciliation

- #104/#153: closed and Done after #271 merged.
- #93: closed and Done; #246/#261 and shared reader/native QA are complete for release scope.
- #95: closed and Done for the integrated deterministic overview; no generative feature is activated.
- #91/#92/#98/#90: remain open for fingerprint acceptance and final evidence consolidation.
- #99/#235 and #244: optional backlog; #264/#268 remain parked.

## Validation

Focused `./test.sh --story-regressions`, the live English capture, tuning-only native review, private-file language/permission checks and JSON/diff checks passed. The full regression suite is required by the commit hook. This change affects evaluation tooling and documentation; no app installation or new production behavior is claimed. Hosted CI and merge are separate.
