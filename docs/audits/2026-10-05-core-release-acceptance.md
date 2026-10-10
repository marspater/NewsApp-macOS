# Core release acceptance — 5 October 2026

Refs #102, #91, #92, #98, #90. Base `7ffc3e3` (merged PR #272). Current scope: English catalog and deterministic overviews. Non-English matching #264 and spoken VoiceOver #268 are parked; optional tension #99/#235 and discovery #244 do not block core completion.

## Fingerprint holdout, one final run

The existing native capture evaluator now supports `--corpus-readiness DIR --corpus-holdout`. It counts production fingerprint eligibility and distinct canonical URLs, then returns before pair comparisons, label reads and review-sheet writes. The report contains no candidate outcomes, precision or observed error bound; its sufficiency flag is explicitly conditional on zero false merges, and readiness never passes acceptance. Existing regressions cover sealed output and ignored invalid labels.

Two private captures from 4–5 October yielded **841 distinct eligible English holdout documents**, 1,147 eligible observations and 1,448 unique observations. Before acceptance, the count-only run left every private JSON file byte-for-byte unchanged and created no holdout review sheet. Tuning is for development; host-disjoint holdout is for final acceptance. No matcher, split or threshold was changed from the merged base.

Once sufficient support was established, `./test.sh --corpus-review <private directory> --corpus-holdout` ran **once**. [Native aggregate report](../benchmarks/2026-10-05-fingerprint-holdout.json):

| Measure | Result |
| --- | --- |
| Eligible canonical documents | 841 |
| Different-URL matches / false merges / unlabeled matches | 0 / 0 / 0 |
| Precision | Undefined (`null`); no matches |
| Wilson 95% false-merge upper bound | 0.0045469583 (0.455%), below 1% |
| Release gate | Passed |
| Same-URL observation pairs sharing / not sharing fingerprint | 100 / 309; diagnostic only |

The agreed gate bounds false merges per eligible canonical document; precision applies when at least 100 different-URL matches exist. No precision, recall or pair-level accuracy claim follows from zero matches. Per-source and per-language candidate metrics are empty because no candidates exist; all eligible observations are declared English by the curated feed policy. This is captured-feed evidence, not proof for all publishers or independent statistical sampling of all internet documents. Stored capture text, titles and URLs remain private. The resulting empty holdout review sheet has owner-only permissions. Original captures and the tuning sheet are unchanged.

## Core evidence consolidation

| Acceptance stream | Recorded evidence and boundary |
| --- | --- |
| Identity, aliases and migrations (#91/#92) | [Foundation](2026-10-01-story-foundation.md), [copied-database migrations and resilience](2026-10-02-resilience-and-migration-coverage.md), full native regressions; fingerprint gate now passed |
| Event corpus (#102/#94) | [One-shot event holdout](2026-10-05-event-corpus-holdout.md): 23/24 precision, overall recall 0.291, English recall 0.605; Mars accepted the single vote/protest boundary error on 5 October. No replay or post-holdout tuning |
| Reader (#93) | [Structural/live publisher evidence](2026-10-04-reader-structure.md), merged #261; originals, figures and split-anchor teaser regressions retained |
| Overview (#95) | Integrated deterministic cited overviews; [provenance and stale-write rejection](2026-10-04-publisher-content-provenance.md), lifecycle/invalidation regressions and persisted readback in the combined workload. No model path activated |
| Performance (#104/#153) | [Cold launch](2026-10-05-cold-launch.md): 1,203.3 ms first card, warm median 625.8 ms. [Combined app workload](2026-10-05-full-app-workload.md): final app-process peak 195.8 MiB, sizing maximum 214.2 MiB, 270 MiB investigation trigger; ten cited/persisted overviews, five native Web completions and 78 decoded images |
| Native QA (#123/#155) | [Native UI settings/keyboard/layout checks](2026-10-03-native-ui-qa-system-settings.md) and [rendered AX harness](2026-10-04-voiceover-harness.md). Live speech/rotor/heading acceptance is explicitly parked, not claimed passed |
| Shutdown/resilience | [Active parsing/ingestion/clustering cancellation](2026-10-02-active-work-cancellation.md), [transport cancellation](2026-10-02-transport-cancellation.md), migrations and provenance guards |

#102 and parents #91/#92/#98/#90 are ready to close on merge of this final evidence PR. Existing implementation phases are merged; this slice changes evaluator tooling and evidence only. Full regressions remain the required publication check. The project board should retain In review until merge, then mark these core trackers Done.

## Limits and publication checks

The focused story regression suite and native count-only/final holdout runs passed. Full regression results are recorded with the publication PR. No new app build, installation or distribution/notarization is required by this evaluator/documentation slice, and none is claimed. Hosted CI and merge must be confirmed separately.

The combined performance harness measures the app process, not WebKit auxiliary services. Memory pressure, leak freedom and population latency tails remain unproven; documented budgets are bounded investigation triggers. User library, settings and installed app were not touched. No capture schedule was changed or duplicated; additional samples are no longer required to meet this gate.
