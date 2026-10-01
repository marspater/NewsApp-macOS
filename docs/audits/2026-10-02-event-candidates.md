# Bounded event candidates — 2 October 2026

## Scope

Implements #125 (Phase D, #94): candidate generation for event matching by time window, language, key names and words through the existing SQLite FTS. Deciding whether candidates report the same event is #126; running it during refresh is #128.

## Implementation

- `EventMatchKey` takes up to eight terms from an article: named people, places and organizations (`NLTagger`, title plus the first 600 characters of the description), then title words of at least four characters with a letter, deduplicated case-insensitively. Language is the `NLLanguageRecognizer` dominant language when its probability is at least 0.5, otherwise unknown.
- The FTS5 query searches only `title` and `description`, ORs the terms and quotes each as a phrase with embedded quotes removed, so publisher text cannot inject query syntax.
- `DatabaseEngine.eventCandidateRows` joins the FTS hits to articles and event membership, keeps rows whose display date (publication, or ingestion when undated) is within the window, excludes the article itself, hidden reconciled copies and members of events whose membership last changed before the active lifetime, orders by FTS rank and applies a `LIMIT`.
- `EventCandidateFinder` requests at most twice `EventCandidatePolicy.limit` rows, drops rows in a different confidently detected language (unknown languages stay eligible) and returns at most `limit` candidates, each with its active event if any. Defaults: ±48 hours, 72-hour active lifetime, 40 candidates. They are starting values to tune against the #102 corpus, not measured results.

## Verification

No Swift toolchain was available in the authoring environment (Linux container); nothing was compiled or run locally. `testEventCandidateGeneration` (full suite and `--story-regressions`) covers bounded and deduplicated terms, short-word exclusion, hostile titles producing a valid query, and on an in-memory library: in-window match included; self, out-of-window, unrelated, other-language and closed-event members excluded; active event carried; the cap; a zero limit. Results come from macOS CI.

## Remaining

Language and names come from on-device NaturalLanguage models and vary by OS version and language; short headlines often have no confident language. Translations and cross-language coverage of one event are not candidates by design. No performance measurement on a large library yet (#153).
