# Independent bounded overview review — 10 October 2026

Refs #308 and #313; independent review of [PR #427](https://github.com/marspater/NewsApp-macOS/pull/427). The corrected generation packet still contains attribution and citation errors. Automatic zero-error counts do not establish acceptance. No synthesis, rating, app or collection behavior changes in this audit.

## Scope and provenance

Agent 1 reviewed all 195 retained model introduction/fact claims in 38 accepted overviews against their exact saved cited passages, independently of Agent 2 implementation. Titles, deterministic excerpts and perspectives are outside the claim sheet. Review tests source-relative support, not publisher truth. Allegations and disputed participant assessments must preserve their reporting frame; ordinary reported facts need not preserve every reporting wrapper. Detailed labels, passages and model records stay private.

The private copy freezes 65 original capture files. Included output hashes match the original receipt; the immutable SQLite snapshot SHA-256 matches `a8250b16258ed598a654aacd1f169465b3b4089587339e82b849332a5cb2e0ee`. The pre-generation receipt records clean producer `98234e2c3416e7e2de6c34a3387cc47f319fe425`, capture/selection anchor `2026-10-10T13:50:23Z`, and UTC selection bounds `2026-10-07T13:50:23Z` to `2026-10-10T13:50:23Z`. This is a receipt-bound development run over existing data, not a genuinely fresh independent acceptance window. Original inputs and receipts remain unchanged; derived review labels have a separate private receipt.

## Independent labels

| Proposed label | Claims / 195 | Rate |
| --- | ---: | ---: |
| Supported | 188 | 96.41% |
| Unsupported by exact cited passage | 3 | 1.54% |
| Critical attribution error | 4 | 2.05% |

Critical-error Wilson 95% interval: **0.80–5.15%**, upper bound **5.15%**; unsupported-only interval: **0.52–4.42%**. Critical labels affect 3/38 accepted overviews; all seven exceptions affect 5/38. Repeated claims and shared events limit the interpretation of per-claim intervals.

These are Agent 1 proposals, not Mars-adjudicated decisions. One testimonial paraphrase is borderline: the speaker is named as the affected person, but the testimonial assessment loses its reporting frame. Its severity remains explicitly pending. The other three critical labels concern two truncated military assessments ending at a speaker-title abbreviation and one pending legal allegation recast as established conduct. The three unsupported claims use citations that do not establish all of the displayed assertion. Another packet passage or title cannot repair the selected citation. Even if the borderline case becomes supported, three critical labels remain.

## Current-revision deterministic replay

Separately, an isolated native arm64 harness compiles the production verifier and auditor from PR revision `b375bb09fd9973efc666de123e23da4e28f46802`. Other compilation dependencies come from the archived `15b4994` review harness. This targeted replay uses the 195 frozen claims plus ten invented controls; it makes no model calls or library reads and is not a full current-PR regression run.

Both gates accept all 195 reviewed claims, including all seven exceptions. Six of ten independent controls mismatch their expected outcomes: four incorrect claims pass (renamed speaker, actor mistaken for speaker, reporting verb inside a detached quote, and arrest substituted for summons); two valid claims fail (unrelated official speech elsewhere in a passage, and substring matching inside an unrelated word). These are semantic failures recorded by the replay; successful compilation/process exit does not mean the controls passed. The earlier [independent review](2026-10-10-independent-overview-claims.md) remains historical baseline evidence.

## Saved-run quality measurements

- Accepted: **38/55 (69.09%)**, Wilson 95% **55.97–79.72%**; 12 weak drafts and 5 thin-evidence fallbacks. No recorded format fallback, refusal or model error. Thirty-four model lines were rejected deterministically; four by model support judgment.
- Generation/verification latency for accepted drafts: p50 **4.84 s**, p95 **7.28 s**; all attempts: **4.57/7.11 s**. The previous accepted-draft baseline is **7.39/10.40 s**. Previously quoted **6.94/10.22 s** describes all attempts including evidence preparation, so it is not the accepted-draft comparator.
- Whole-claim lexical copying: **157/195 (80.51%)**; at least eight consecutive words: **186/195 (95.38%)**; median longest copied run: **24 words**.
- Introduction/fact repetition at content-word Jaccard >=0.6: **30/67 (44.78%)** introductory claims; median best similarity **0.333**.
- At least two perspectives: **25/55 (45.45%)**. This coverage measure is not independent claim-support adjudication.

The baseline and candidate have different event cohorts/selection bounds and stochastic generation. Acceptance changing from 35/58 to 38/55 is a descriptive observation, not a paired causal comparison. The baseline's 11 critical and two unsupported errors were independent labels; its automatic auditor also reported zero. Therefore the candidate's automatic zero cannot establish that all prior errors were eliminated. The numerical 30-accepted-overview target is exceeded, but the separate eligible control-set requirement remains open.

## Decision and verification

Keeping the generative path unchanged remains blocked under #308's critical-error rule. Agent 2 should correct attribution scope, sentence truncation, allegation modality and citation selection, preserve valid controls, then hand off corrected frozen outputs. The borderline severity can be adjudicated separately while the clear failures are fixed. Fresh multi-day collection and #309 fresh-window stability remain deferred.

The existing overview reporter validates all 195 labels and unchanged non-label fields; its self-check passes, and all 65 frozen input hashes remain unchanged. At PR revision `b375bb0`, hosted Apple Silicon test/build, Codacy and Sonar checks pass; Swift CodeQL was still running, the wrapper was neutral for missing Swift configuration, and the separate advanced-security check failed. These statuses are separate from the review findings and do not establish complete hosted verification. Documentation consistency/diff checks and the required full-suite commit hook accompany publication. No app installation, launch, new collection or holdout replay was performed.
