# Publisher holdout annotation preparation — 3 October 2026

Refs #102, #127, #110, #126. Base: `c55acf0`, after the requested rebase. No production source, settings, library, app installation or matching thresholds changed. Native evaluation now preserves an optional observed URL, so replay uses real document identity rather than a generated identifier URL. URL-less control fixtures keep their existing fallback.

## Evidence collected

The production protected `--corpus-capture` path fetched 1600 parsed items from 48 of 49 catalog feeds. The capture contains 1570 distinct observed document URLs after tracking normalization; all seven catalog languages are represented. This was a new isolated capture, not a reading-history export. Publisher text is retained privately at `/Users/marspater/Documents/NewsHoldout-2026-10-03/`; no bodies or feed descriptions are committed.

The native fingerprint review on **tuning only** found 933 observations, 91 eligible fingerprints (77 English, 14 Ukrainian) and **0 different-URL candidates**. Precision is undefined and `releaseGatePassed` is false. The fingerprint holdout was not opened. One capture supplies no evidence that waiting longer will produce the required 100 holdout matches.

## Provisional annotation batch

The separate [v2 proposal](../../Tests/Fixtures/story-corpus/publisher-review-v2.json) has 183 observations, 100 proposed occurrence IDs and 400 proposed pairs (263 tune / 137 holdout): 6 same-document, 199 same-event, 195 different. Forty occurrence IDs have several observations and sixty are singletons. Candidate retrieval used title terms, not production matcher or embedding predictions. Assignments were proposed from captured publisher headlines/descriptions by one coding copilot; they are **not independent gold adjudications**.

All seven languages occur in the observations, but most positives are English. The holdout contains 74 proposed same-event pairs, of which 36 come from one Spanish housing rally. Pair counts are correlated and cannot be treated as 74 independent positive events or used to claim broad >=97% performance. Further collection must improve event diversity.

Related developments are split together as families. The proposals explicitly distinguish the Spanish parliamentary housing vote from the subsequent rally, a failed execution's medical aftermath from the commissioner's resignation, and the Northern Kyiv bridge strike from earlier Southern bridge attacks. Those boundaries, ambiguous updates, singleton assignments and publisher-page dates still need independent review. Real same-company quarterly reports and identical-headline different-event negatives are still absent.

The review packet contains source links, captured feed timestamps and feed descriptions, plus blank approval fields. [The validator](../../script/evaluation/publisher_review.py) checks the frozen metadata/capture checksums, references, split and proposal consistency, rejects public publisher text and refuses to overwrite reviewer files. Reviewed native inputs export only after all pair decisions, timestamp confirmations and event assignments are supplied. Label corrections need a new reviewed version. V1 and its checksum remain unchanged. A synthetic native regression verifies that an observed URL and its tracking variant resolve to one document even when the titles differ.

## Validation and remaining gates

- Existing Swift test harness compiled on arm64, target macOS 15, and the live capture/tuning review commands completed.
- V1 corpus integrity/metric self-checks and v2 validator self-checks passed, including capture reconstruction and rejection of wrong captures or incomplete review exports. Private files were verified as 0600 and the folder as 0700.
- Full `./test.sh` regressions passed through the required commit hook. The same entry point now also runs the v2 validator before native compilation.
- No threshold tuning, holdout predictions, app build, installation or hosted CI result is claimed in this slice.

#102 remains open. The next steps are independent source/date/event adjudication, more varied positive events and the missing real hard negatives, followed by tuning and one frozen holdout replay. The >=99% fingerprint gate separately needs real different-URL matched variants; the captured pool currently cannot measure it. #127 remains blocked until accepted event labels and adequate support exist.
