# CI audit: correctness, stacks and runner minutes — 14 November 2026

Scope: every pipeline that runs for this repository: GitHub Actions (`ci.yml`, `security.yml`, `profile.yml`, `release.yml`, `labeler.yml`, `stale.yml`), CircleCI (`.circleci/config.yml`) and Codemagic (`codemagic.yaml`). Two ways of working have to be served: independent pull requests into `main`, and stacks where each pull request targets the branch below it.

## Evidence

The newest 304 CI and Security workflow runs, 12 November 22:27 to 14 November 15:23 UTC, job minutes from the Actions API (skipped jobs left out):

| Job | Event | Minutes | Jobs | Cancelled |
|---|---|---|---|---|
| CodeQL (Swift), macOS 26 | pull request | 842 | 65 | 50 |
| Test (macOS 26) | pull request | 630 | 66 | 47 |
| Build Verification, Xcode 27 | pull request | 398 | 66 | 34 |
| CodeQL (Swift), macOS 26 | push to main | 287 | 30 | 22 |
| Test (macOS 26) | push to main | 259 | 32 | 23 |
| Build Verification, Xcode 27 | push to main | 115 | 32 | 22 |
| Today Captures, macOS 26 | push to main | 90 | 32 | 22 |
| Ubuntu jobs (paths, CodeQL Actions, secret scan, dependency review) | both | 131 | 419 | 40 |

- A cancelled run has spent its minutes and verified nothing. On `main`, 23 of 32 test runs and 22 of 30 Swift analyses were cancelled by the next merge, so most `main` commits were never verified or scanned.
- Over the last 60 merges into `main` (12 and 13 November), 22 changed nothing that `swift build --target News` compiles, yet each started a 19 to 41 minute CodeQL Swift build.
- CircleCI ran a full `test-macos` for each of three merges pushed within 90 seconds on 13 November (19:17 to 19:19). A documentation-only merge still waited 18 minutes in the macOS queue, then started a macOS machine to halt after 8 seconds.
- CircleCI's usage export for 1 to 13 November: 1,008,930 credits, against a free allowance of about 30,000 a month. `test-macos` used 962,705 of them (791 jobs on branches before 12 November, 208 on `main`) at 208 credits a minute on m4pro.medium. Run on `main` only, it still cost 72,393 credits on 12 and 13 November (54 jobs, 348 minutes); a job that halted early cost about 200 credits. The Docker `checks` job used 2,263 credits for 1,436 jobs.
- Codemagic left no status or check on the 12 newest `main` commits or on 4 recent pull requests, and the repository has no Codemagic webhook. CONTRIBUTING.md says reporting needs the GitHub App and a webhook. Its dashboard was not inspected.

## Findings and changes

| # | Finding | Change |
|---|---|---|
| 1 | `ci.yml` started only for pull requests into `main`, so a stacked pull request's required checks waited forever (#1320). | Every base branch (separate pull request, below this one). |
| 2 | `security.yml` had the same base filter, so stacked pull requests were never scanned before they reached `main`. | Every base branch. |
| 3 | `main` runs cancelled each other (see Evidence). | Pull requests still cancel their older run. `main` queues: GitHub keeps one run going and one waiting, and a newer push replaces the waiting run before it starts. A push is measured from the last `main` commit the workflow finished on (`script/ci_push_base.sh`), so the commits of a replaced run fall into the newer run's range; measured from its own push alone, a documentation push could replace a waiting code run and then skip. |
| 4 | Four different "nothing to test" lists: `ci.yml` (Markdown, docs, LICENSE), its push filter, CircleCI (eleven patterns) and Codemagic (docs and Markdown). None kept PRIVACY.md, which a test checks exists. | One rule, `script/ci_changes.sh`, with its own self-check, for GitHub Actions, the only provider that now runs macOS per change (changes 10 and 14). Python tooling is on the list because CircleCI `checks` runs its checks on every push. |
| 5 | CircleCI `checks` ran 8 of the 11 Python self-checks that `./test.sh` runs (no `lead_review`, `calibrate_tension` or `pretrain_pairs`), and the editorial unit tests ran only on the GitHub macOS runner. | `script/python_checks.sh` holds the list plus all `script/evaluation/test_*.py` unit tests; `./test.sh` and CircleCI `checks` both call it. |
| 6 | The editorial matrix (Python alone) ran on the macOS test runner. | A Linux job: when the evaluation tooling changes, and on each push to `main` that needs a run. |
| 7 | CodeQL Swift ran for every non-documentation change. | Only when `Sources/`, `BuildSupport/`, the package manifests or `security.yml` change, plus the weekly and manual runs. CodeQL Actions runs only when workflows change. Job ids are unchanged, so code scanning keeps its configurations. |
| 8 | Secret scanning skipped documentation-only changes, though a secret can sit in any file. | The Security workflow has no path filter; secret scanning runs on every pull request and push. |
| 9 | "Swift Security Tests" ran the whole `./test.sh` weekly on Xcode 27, under a security name, repeating what every test run covers. | Removed. |
| 10 | CircleCI ran one full macOS job per push to `main` (see Evidence), about 30 times the free allowance. | A push runs the Docker `checks` job alone. `test-macos` and `deploy-marker` run in a scheduled pipeline (a weekly trigger on `main`, set in the project's Triggers settings) or one started by hand: about 9,000 credits a month. |
| 11 | `security.yml` said "normal CI tests Xcode 27" beside Xcode 26.3; `ci.yml` tests with 26.6 and builds with 27. | Comment corrected; 26.3 stays for the CodeQL extractor. |
| 12 | `stale.yml` did not exempt `parked`. The four open parked issues are covered today by their assignee or milestone only. | `parked` exempted. |
| 13 | The Main ruleset had lost its required checks entirely by 14 November afternoon; earlier it required `ci/circleci: checks`, `Changed paths` and `Build Verification (Apple Silicon)`, while CONTRIBUTING.md also named `Test (macOS 26, Apple Silicon)`. No test gated a merge. | The ruleset requires all four again. The test job is the only macOS 26 runtime the project has: no development Mac runs macOS 26. |
| 14 | Codemagic ran the full suite and release build for every pull request into `main` and every push to `main`. Its free plan's 500 macOS minutes cover about 16 runs of about 30 minutes (GitHub's times for the same steps), a day or two at this merge rate. It had never run: it waits for its first build to be finished on codemagic.io. | It runs for each `v*` release tag and by hand: the full suite and the release build on Xcode 27 and Apple silicon, apart from GitHub's gate. The change-set filter went with the push triggers. |

## Provider roles after this audit

| Provider | Runs per change | macOS beyond that |
|---|---|---|
| GitHub Actions (free for a public repository) | Every pull request, stacked ones included, and every push to `main`: the gate. | Weekly CodeQL Swift and signpost profile. |
| CircleCI (about 30,000 credits a month) | Docker `checks` on every push, a required check. | `test-macos` weekly on `main` and by hand. |
| Codemagic (500 macOS minutes a month) | Nothing. | The full suite and release build for each `v*` tag and by hand. |

## Left to do outside the repository

- **CircleCI:** add a schedule trigger in Project Settings → Triggers: weekly, branch `main`. Until it exists, `test-macos` runs only when started by hand.
- **Codemagic:** finish the first build on codemagic.io with the `codemagic.yaml` from `main` once this change is there, so it reads the tag trigger. That first run uses about 30 of the month's 500 minutes.

## Cost of change 1

Every pull request in a stack now gets its own macOS run per push, and an upper pull request runs again when the branch below it is merged into it. Changes 3, 4 and 7 offset that: over the last 60 merges, 22 would have skipped the Swift analysis and 9 the macOS jobs (7 under the old rule). Cancelled `main` runs end with change 3.

## Verification

- `script/test_ci_changes.sh` and `script/python_checks.sh` pass locally; CircleCI's config validator accepts `.circleci/config.yml` for a push pipeline; every changed YAML file parses.
- `actionlint` was not available. GitHub validates workflow syntax when the branch is pushed.
- The pull request stacked on the trigger fix is the check of the stacked case: its `Changed paths` and `Build Verification` must report.
