# Independent overview claim review — 10 October 2026

Refs #308. Agent 1 reviewed the handed-off claim sheet independently of overview synthesis/rating implementation. Detailed labels, passages and model records remain local. This is proposed independent adjudication, not Mars's acceptance or validation of a later synthesis fix.

## Scope and lineage

A private copy freezes the claim sheet and all 58 saved live overview records with SHA-256 fingerprints. Every one of the 167 retained model introduction/fact claims from 35 accepted overviews matches its saved text and exact cited passage. The original packet remains unchanged. The existing `script/evaluation/overview_review.py report` validates all non-label fields and produces the aggregates below.

The review tests support from the cited passage, not factual truth of publisher reporting. Ordinary reported facts may omit a reporting wrapper when actor, meaning and uncertainty remain intact. Material changes to number/date/actor, unattributed first-person quotations, and allegations, contested participant assessments or disputed positions recast as established fact are critical. Missing support without such a reversal is unsupported. Context-dependent referents and repetition are separate quality concerns.

Titles, deterministic excerpt sections and perspectives are outside this model-claim sheet. The producer's subsequent handoff identifies this as the older, overlapping 7–8 October event sample used for #412, overlapping the 9 October measurements. It is not a fresh or separate acceptance window. The producer reports the #421 working tree corresponding to `8f53770`; the run itself records neither that commit nor a capture receipt, so this code binding is reported provenance, not independently established. The copied library was modified by later #313 runs and cannot now prove the original run's inputs. The issue's numerical target of 30 accepted overviews is exceeded, but its separate-control-set requirement remains open; the capture's own requested target of 100 is not met.

## Independent labels

| Label | Claims / 167 | Rate |
| --- | ---: | ---: |
| Supported | 154 | 92.22% |
| Unsupported by the cited passage | 2 | 1.20% |
| Proposed critical attribution error | 11 | 6.59% |

Critical-error Wilson 95% interval: **3.72–11.41%**, upper bound **11.41%**. Unsupported-only interval: **0.33–4.26%**. Counting both non-supported classes gives 13/167 (7.78%). The 11 critical labels affect 7/35 accepted overviews; both non-supported classes affect 8/35.

Critical labels concern speakerless first-person quotes, political motive allegations, combatant success assessments and disputed official positions losing their reporting frame. The two other unsupported claims use passages that do not establish the displayed assertion, although another passage in their respective packet supports it. No number/date mismatch was identified in this review. Exact exception IDs and reasoning stay in the private handoff sheet.

The saved automatic auditor reported zero critical/unsupported claims. That heuristic result differs from these independent labels. Repeated claims and shared events make claim outcomes dependent; nominal per-claim Wilson bounds do not establish event-level or general release accuracy. Mars must adjudicate the proposed severity judgments.

## Existing-run measurements

- Accepted: 35/58 (60.34%); fallback: 18 weak drafts and 5 thin-evidence cases. No recorded refusal, format fallback or unavailable/error outcome.
- Generation plus per-sentence verification latency: all attempts p50 **6.88 s**, p95 **10.22 s**; accepted drafts p50 **7.39 s**, p95 **10.40 s**. Including measured evidence preparation: p50 **6.94 s**, p95 **10.22 s**. These are reanalysed saved timings, not a new device run.
- Whole-claim lexical copying: 141/167 (84.43%); at least eight consecutive copied words: 158/167 (94.61%); median longest copied run: 25 words. These use the existing reporter's word-token measure, not a copyright or semantic judgment.
- Introduction/fact repetition: 24/60 introductory claims (40%) have best content-word Jaccard similarity at least 0.6 to a retained fact; median best similarity 0.341. This is lexical overlap, not independent semantic adjudication.
- Recorded evidence preparation made 12 page requests, all HTTP failures, and stored no new publisher texts. Review uses the exact passages already saved in the packet.

## Decision and verification

Under these proposed labels, #308's rule that any critical error blocks keeping the generative path unchanged is triggered. No generation threshold, verifier, composer or rating code is changed by this review. Agent 2 can use the private exceptions for targeted corrections; this reviewed sample then provides development evidence, not a new untouched acceptance set.

All 167 labels are present, unique and accepted by the existing binding validator; original input hashes are unchanged. The reporter's synthetic self-check and documentation consistency checks are recorded with publication. No new generation, several-day collection, historical holdout replay, app launch or installation is performed. The subsequently supplied #309 packet is reviewed in the [independent importance audit](2026-10-10-independent-importance-review.md), with its own eligibility limits. Mars's keep/tune/narrow decision remains open.

Before further #313/weak-draft development runs, the producer should save a receipt binding UTC window bounds, capture time, Git commit and dirty-state fingerprint, the library snapshot SHA-256 and the exact saved output manifest. Regenerating a genuinely fresh acceptance packet requires later collection and remains outside this work's scope.
