# Current event matcher: English regression replay — 9 October 2026

Refs #307, #90, #94. This is the historical regression replay Mars requested, not the fresh release gate. Production matching and judge instructions were unchanged during this evaluation.

## Frozen input and method

- Production source: main `651729b6de4ec02972282f5211667f07a01a172f`. Evaluation-only harness: `9329091bd4e0435507689a02e4f5eb2328932460`; the required full test hook passed before scoring.
- Accepted private export SHA-256: `868c62a0ec973d07aa2ca3d63de8623fbe866359d1e082fadacd7bd456acf2a0`, identical to the earlier accepted corpus. Labels remain accepted copilot reviews, not blind independent annotation.
- The freeze receipt, all Swift source/test hashes and settings were written before scoring (receipt SHA-256 `8560e7e1f6744bfa54f88e329ae934fb520433b3d0ab0e7c24573f6bc5355081`). Publisher text, labels and memberships stay private.
- Apple M5, arm64, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Apple Swift 6.4. Each judge mode uses a fresh process and in-memory database. Input is restricted to production-detected English before ingestion, sorted by publication date and ID, with the existing six-hour refresh steps.
- Candidate and matching policies use production defaults. The existing evaluator has unlimited article and judge budgets per pass; production caps are 2,000 articles and 150 settled judgements. Per-pass counts are retained so this difference remains assessable.
- Judge instructions are frozen from `EventJudge.swift`: greedy sampling, eight response tokens, permissive content-transformation guardrails. No embedding cutoff or sweep is applied to this holdout; native paraphrase checks used by production remain active when the judge is requested.

Each agreed mode was run once:

```sh
NEWS_EVENT_CORPUS=<private-accepted-export> NEWS_EVENT_LANGUAGE=en \
NEWS_EVENT_OUTPUT=<fresh-private-mode-directory> NEWS_EVENT_JUDGE=0 \
./test.sh --event-corpus --corpus-holdout
# Repeat once with NEWS_EVENT_JUDGE=1 in a separate fresh process/directory.
```

Saved memberships support error review without scoring again. This event replay does not open the separate fingerprint holdout. No thresholds, prompts, exclusions or labels are changed after observing the results.

## Results

Both processes completed successfully. The frozen English filter selected **49 documents from 13 publisher families**, with **38 positive gold pairs**. The historical baseline's English recall is 23/38 = 0.605; its all-language recall of 0.291 is not the comparable denominator.

| Mode | TP / FP / FN | Precision [Wilson 95%] | Recall [Wilson 95%] | False-merge rate [Wilson 95%] | Mixed events |
| --- | ---: | --- | --- | --- | ---: |
| Earlier accepted matcher, English | 23 / 1 / 15 | 0.958 [0.798–0.993] | 0.605 | 1 / 24 | 1 |
| judge-off | 21 / 1 / 17 | 0.955 [0.782–0.992] | 0.553 [0.397–0.699] | 0.045 [0.008–0.218] | 1 |
| judge-on | 36 / 30 / 2 | 0.545 [0.426–0.660] | 0.947 [0.827–0.985] | 0.455 [0.340–0.574] | 4 |

**Neither current mode reaches the ≥0.97 precision target.** Judge-on adds 15 correct links relative to judge-off but adds 29 false links. It returned 72 settled judgements, at most 41 in one pass; the maximum processed rows per pass was 15. These counts remain below production's 150-judgement and 2,000-article caps, so the unlimited evaluator budget did not bind this sample. The judge-on run also performed two fragment merges; judge-off performed none.

## Publisher family breakdown

Families below are grouped by publisher URL host, combining Guardian feeds whose RSS source titles differ. Generic RSS titles such as “Latest News” are not publisher families. A pair is counted once for each distinct endpoint family, including cross-publisher pairs, so these rows are overlapping and must not be summed. Each row retains its TP/FP/FN denominators. The Kyiv Independent singleton has no predicted or positive gold pair and therefore no measurable precision or recall.

### judge-off

| Publisher | Documents | TP / FP / FN | Precision [95%] | Recall [95%] | False-merge rate [95%] |
| --- | ---: | ---: | --- | --- | --- |
| Africanews | 2 | 2 / 0 / 0 | 1.000 [0.342–1.000] | 1.000 [0.342–1.000] | 0.000 [0.000–0.658] |
| Al Jazeera | 2 | 5 / 0 / 2 | 1.000 [0.566–1.000] | 0.714 [0.359–0.918] | 0.000 [0.000–0.434] |
| Arab News | 1 | 2 / 0 / 0 | 1.000 [0.342–1.000] | 1.000 [0.342–1.000] | 0.000 [0.000–0.658] |
| BBC | 10 | 5 / 0 / 3 | 1.000 [0.566–1.000] | 0.625 [0.306–0.863] | 0.000 [0.000–0.434] |
| CBC | 4 | 4 / 0 / 2 | 1.000 [0.510–1.000] | 0.667 [0.300–0.903] | 0.000 [0.000–0.490] |
| CNA | 3 | 3 / 0 / 5 | 1.000 [0.439–1.000] | 0.375 [0.137–0.694] | 0.000 [0.000–0.561] |
| CNBC | 1 | 1 / 0 / 0 | 1.000 [0.207–1.000] | 1.000 [0.207–1.000] | 0.000 [0.000–0.793] |
| DW | 6 | 5 / 0 / 5 | 1.000 [0.566–1.000] | 0.500 [0.237–0.763] | 0.000 [0.000–0.434] |
| France 24 | 6 | 4 / 1 / 7 | 0.800 [0.376–0.964] | 0.364 [0.152–0.646] | 0.200 [0.036–0.624] |
| Guardian | 2 | 4 / 0 / 2 | 1.000 [0.510–1.000] | 0.667 [0.300–0.903] | 0.000 [0.000–0.490] |
| Kyiv Independent | 1 | 0 / 0 / 0 | n/a | n/a | n/a |
| The Hill | 4 | 1 / 0 / 4 | 1.000 [0.207–1.000] | 0.200 [0.036–0.624] | 0.000 [0.000–0.793] |
| The Hindu | 7 | 6 / 1 / 3 | 0.857 [0.487–0.974] | 0.667 [0.354–0.879] | 0.143 [0.026–0.513] |

### judge-on

| Publisher | Documents | TP / FP / FN | Precision [95%] | Recall [95%] | False-merge rate [95%] |
| --- | ---: | ---: | --- | --- | --- |
| Africanews | 2 | 2 / 3 / 0 | 0.400 [0.118–0.769] | 1.000 [0.342–1.000] | 0.600 [0.231–0.882] |
| Al Jazeera | 2 | 7 / 4 / 0 | 0.636 [0.354–0.848] | 1.000 [0.646–1.000] | 0.364 [0.152–0.646] |
| Arab News | 1 | 2 / 3 / 0 | 0.400 [0.118–0.769] | 1.000 [0.342–1.000] | 0.600 [0.231–0.882] |
| BBC | 10 | 7 / 5 / 1 | 0.583 [0.320–0.807] | 0.875 [0.529–0.978] | 0.417 [0.193–0.680] |
| CBC | 4 | 5 / 4 / 1 | 0.556 [0.267–0.811] | 0.833 [0.436–0.970] | 0.444 [0.189–0.733] |
| CNA | 3 | 7 / 8 / 1 | 0.467 [0.248–0.699] | 0.875 [0.529–0.978] | 0.533 [0.301–0.752] |
| CNBC | 1 | 1 / 0 / 0 | 1.000 [0.207–1.000] | 1.000 [0.207–1.000] | 0.000 [0.000–0.793] |
| DW | 6 | 10 / 6 / 0 | 0.625 [0.386–0.815] | 1.000 [0.722–1.000] | 0.375 [0.185–0.614] |
| France 24 | 6 | 11 / 12 / 0 | 0.478 [0.292–0.670] | 1.000 [0.741–1.000] | 0.522 [0.330–0.708] |
| Guardian | 2 | 6 / 2 / 0 | 0.750 [0.409–0.929] | 1.000 [0.610–1.000] | 0.250 [0.071–0.591] |
| Kyiv Independent | 1 | 0 / 0 / 0 | n/a | n/a | n/a |
| The Hill | 4 | 5 / 1 / 0 | 0.833 [0.436–0.970] | 1.000 [0.566–1.000] | 0.167 [0.030–0.564] |
| The Hindu | 7 | 8 / 11 / 1 | 0.421 [0.231–0.637] | 0.889 [0.565–0.980] | 0.579 [0.363–0.769] |

## False-merge review

Every false pair was reviewed from the saved memberships against the unchanged accepted occurrence labels. The private review records each pair's IDs, category and reason. All 30 judge-on false pairs (and the one judge-off pair, already among those 30) join **related but separate acts**, suitable for possible timeline relationships rather than a single event. No unrelated merge was found in this small replay.

| Boundary crossed | Judge-on false pairs | Review |
| --- | ---: | --- |
| Legislative vote versus a later protest day | 12 | Same policy dispute, separate occurrence under the frozen rules; includes the earlier baseline error |
| Diplomatic decision versus a military advance/retreat | 6 | Separate developments in one conflict |
| Medical aftermath of an execution attempt versus an official resignation | 9 | The medical consequences belong to the attempt; the resignation is a separate official act |
| Prosecutor appointment versus a proposed law change | 3 | Distinct official acts prompted by the same case |

The final membership review covers all four mixed groups, including groups produced in a run with two fragment merges. Pass counters do not retain individual merge edges or judge verdicts, so they cannot prove which false pair came from a fragment chain versus initial member placement. The implementation permits whole-coverage judging after fragment compatibility fails and upgrades confirmed borderline pairs to compatible members; these are concrete paths to investigate with controlled tune cases, not established attribution for each error.

## Validation and remaining work

- The full `./test.sh` commit hook passed before scoring, including English filtering, retained pass counts and rejection of existing output before scoring. Each historical mode then completed once; saved evidence is kept for review without another run.
- This change adds evaluation output only. It changes no production thresholds, judge prompts, settings, library, installed bundle or notifications. No app build/install/launch or fresh release acceptance is claimed.
- Pairwise Wilson intervals describe these counts; pairs from the same event or publisher are correlated. The sample is small, historically selected and already accepted/reviewed, so this is regression evidence rather than a fresh generalization result.
- #307 stays open. Narrow related-act joins using tune/controlled cases, freeze the revised matcher, then capture and label a fresh English sample **after 9 October** for the release gate. Weight that sample toward multi-fragment related-act chains, alongside unrelated negatives. Do not rerun or relabel this historical holdout to claim improvement.
- Copilot error classifications remain pending Mars's acceptance. #308 overview controls, #309 importance labels/stability and deferred #334 real-app notification delivery retain their separate gates; #264/#268 remain parked.
