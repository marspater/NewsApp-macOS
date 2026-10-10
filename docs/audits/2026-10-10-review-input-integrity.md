# Reviewer input integrity — 10 October 2026

Related: #308 (overview acceptance), #309 (importance acceptance).

## Problem and fix

Both report tools previously compared only review-row IDs. On synthetic captures, changing a retained claim or story headline while preserving its ID still produced `labellingComplete: true` from the old labels.

The shared CSV reader now compares every input column with rows rebuilt from the current capture. Labels, notes and row order may change; reviewed claims, evidence and story text may not. Duplicate input IDs are rejected during sheet preparation and labelled-sheet validation; importance captures also reject duplicate stories before reporting. Validation happens before report writes, preserving previous aggregates on rejection. Existing intact sheets retain their schema and remain usable. No publisher text is included in mismatch errors or aggregate reports.

## Validation

- Both Python self-checks pass, covering changed source inputs with unchanged IDs, every immutable overview sheet column, editable labels/notes and reordered rows, duplicate IDs, existing-sheet preservation and rejected-report preservation.
- Full `./test.sh` is required by the commit hook; its outcome is recorded in the PR.
- No app runtime changes, installs, private library reads or live captures. No sealed holdout replay.

## Remaining acceptance work

This protects measurement integrity; it does not provide independent labels or complete either release decision. #308 still needs a fresh independently reviewed sample and acceptance decision. #309 still needs its independent importance review and model-update policy decision.
