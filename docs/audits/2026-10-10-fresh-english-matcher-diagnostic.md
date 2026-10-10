# Fresh English matcher diagnostic — 10 October 2026

Refs #307. This is targeted diagnostic evidence with provisional copilot labels, not independent release acceptance.

## Frozen inputs and protocol

- Source `ade184a4f0cb8eb5f4636be4758a9bee878bde0a`, matcher version 3, unchanged judge instructions and production matching policies.
- One new protected catalog capture: 39 English feeds, zero failures, 1,278 observations; 1,013 distinct URLs dated within the preceding 72 hours. No app library/settings access or scheduled capture.
- Selected coverage families from captured headlines/leads before predictions: 88 English articles, 18 publisher families, 17 proposed occurrence groups, 638 positive pairs. Related-but-separate acts were deliberately included. Two large occurrence groups dominate the positive denominator; this is not representative random sampling.
- Copilot labels follow the corpus README occurrence rules. Verbal reactions and pegged profiles stay with their occurrence; new attacks, decisions and meetings remain separate. Policy-license, visa/residency and multi-attack/outage boundaries require Mars confirmation. Labels/text/checksums were frozen before scoring and were not changed afterwards.
- An initial export-selector preflight selected zero records and produced no article memberships or passes. A new export corrected only split metadata; the empty receipt and original export were preserved. The corrected new dataset was scored once per mode in separate processes with the same private binary. The sealed historical dataset was neither read nor replayed.
- Full native tests passed on the frozen isolated revision before scoring. Publisher text, URLs, captured timestamps, annotation reasons and memberships remain private. Public [aggregate evidence](../benchmarks/2026-10-10-fresh-matcher-diagnostic.json) includes checksums and publisher-family denominators.

## Results

| Mode | TP / FP / FN | Precision [Wilson 95%] | Recall [Wilson 95%] | False-merge rate [Wilson 95%] | Impure groups |
| --- | --- | --- | --- | --- | --- |
| Judge off | 215 / 54 / 423 | 0.799 [0.747–0.843] | 0.337 [0.301–0.375] | 0.201 [0.157–0.253] | 1 |
| Judge on | 193 / 38 / 445 | 0.835 [0.782–0.878] | 0.303 [0.268–0.339] | 0.165 [0.122–0.218] | 4 |

Neither mode meets the ≥0.97 point-precision target under the proposed labels. Pairwise observations within a group are correlated; the intervals describe counted pairs and must not imply independent event-level generalization. Publisher rows count each pair once for each endpoint family and overlap; do not sum them.

## Reviewed false boundaries

Judge off joins a supply agreement, subsequent fuel-site attack, separate license decision and negotiations meeting into one group. The agreement contributes 17 false pairs to each other act, plus three pairs between the other acts: 54 total.

Judge on has 38 false pairs: 12 between a peace award and a court-sanctions decision; 11 agreement/license pairs; 11 agreement/attack pairs; one license/attack pair; and three pairs among an initial data-center strike, a multiple-strike summary and service disruption. Every pair is retained in a private review packet under unchanged labels. Ambiguous boundaries remain proposed, not accepted ground truth. No fragment merge occurred in either run, so these results do not attribute errors to fragment merging.

## Evaluator defect and smallest fix

Judge on settled 1,307 judgements, with a maximum of 497 in one pass; production allows 150. Both runs processed at most 49 articles per pass, below the production 2,000-article cap. The evaluator explicitly passed `.max` for both limits in `StoryCorpus.eventMemberships`, so the judge-on result is not equivalent to production budget behavior.

Remove those overrides and reuse `EventClusterer.run` defaults. A deterministic 2,001-article replay regression verifies the adapter stops after 2,000 while preserving deferred singleton visibility. Existing clustering tests cover bounded passes, cancellation and judge/veto behavior. The PR records post-change full-test results. No matching thresholds, prompts or labels change, and this sample is not rescored after the evaluator fix.

## Remaining gate

Keep #307 open. Related acts can share enough headline/lead vocabulary to pass admission without a hard factual contradiction; hard vetoes alone do not establish occurrence precision. Narrowing requires controlled development cases and a separate fresh, frozen acceptance sample using the corrected production-budget evaluator. Mars must confirm provisional boundaries and accept the final result. No installation, production-library mutation, model tuning or release acceptance is claimed.
