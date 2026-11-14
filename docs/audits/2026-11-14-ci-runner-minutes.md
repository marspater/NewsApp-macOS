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
| Ubuntu jobs (paths, CodeQL Actions, secret scan, dependency review) | both | 131 | 454 | 43 |

- A cancelled run has spent its minutes and verified nothing. On `main`, 23 of 32 test runs and 22 of 30 Swift analyses were cancelled by the next merge, so most `main` commits were never verified or scanned.
- Over the last 60 merges into `main` (12 and 13 November), 22 changed nothing that `swift build --target News` compiles, yet each started a 19 to 41 minute CodeQL Swift build.
- CircleCI ran a full `test-macos` for each of three merges pushed within 90 seconds on 13 November (19:17 to 19:19). A documentation-only merge still waited 18 minutes in the macOS queue, then started a macOS machine to halt after 8 seconds.
- Codemagic left no status or check on the 12 newest `main` commits or on 4 recent pull requests, and the repository has no Codemagic webhook. CONTRIBUTING.md says reporting needs the GitHub App and a webhook. Its dashboard was not inspected.

## Findings and changes

| # | Finding | Change |
|---|---|---|
| 1 | `ci.yml` started only for pull requests into `main`, so a stacked pull request's required checks waited forever (#1320). | Every base branch (separate pull request, below this one). |
| 2 | `security.yml` had the same base filter, so stacked pull requests were never scanned before they reached `main`. | Every base branch. |
| 3 | `main` runs cancelled each other (see Evidence). | Pull requests still cancel their older run. `main` queues: GitHub keeps one run going and one waiting, and a newer push replaces the waiting run before it starts. |
| 4 | Four different "nothing to test" lists: `ci.yml` (Markdown, docs, LICENSE), its push filter, CircleCI (eleven patterns) and Codemagic (docs and Markdown). None kept PRIVACY.md, which a test checks exists. | One rule, `script/ci_changes.sh`, with its own self-check, used by GitHub Actions and CircleCI; `codemagic.yaml` mirrors it. Python tooling is on the list because CircleCI `checks` runs its checks on every push. |
| 5 | CircleCI `checks` ran 8 of the 11 Python self-checks that `./test.sh` runs (no `lead_review`, `calibrate_tension` or `pretrain_pairs`), and the editorial unit tests ran only on the GitHub macOS runner. | `script/python_checks.sh` holds the list plus all `script/evaluation/test_*.py` unit tests; `./test.sh` and CircleCI `checks` both call it. |
| 6 | The editorial matrix (Python alone) ran on the macOS test runner. | A Linux job: when the evaluation tooling changes, and on each push to `main` that needs a run. |
| 7 | CodeQL Swift ran for every non-documentation change. | Only when `Sources/`, `BuildSupport/`, the package manifests or `security.yml` change, plus the weekly and manual runs. CodeQL Actions runs only when workflows change. Job ids are unchanged, so code scanning keeps its configurations. |
| 8 | Secret scanning skipped documentation-only changes, though a secret can sit in any file. | The Security workflow has no path filter; secret scanning runs on every pull request and push. |
| 9 | "Swift Security Tests" ran the whole `./test.sh` weekly on Xcode 27, under a security name, repeating what every test run covers. | Removed. |
| 10 | CircleCI measured a `main` push from `HEAD~1`, which misses the earlier commits of a multi-commit push, and ran one full macOS job per push. | It measures from the commit `main` was at before the push. It also stops when `main` has already moved on by a change that its own pipeline tests; a newer change that needs no run leaves this commit to test, so no commit is skipped by both rules. |
| 11 | `security.yml` said "normal CI tests Xcode 27" beside Xcode 26.3; `ci.yml` tests with 26.6 and builds with 27. | Comment corrected; 26.3 stays for the CodeQL extractor. |
| 12 | `stale.yml` did not exempt `parked`. The four open parked issues are covered today by their assignee or milestone only. | `parked` exempted. |

## Not changed, for a decision

- **Required checks.** The Main ruleset requires `ci/circleci: checks`, `Changed paths` and `Build Verification (Apple Silicon)`. CONTRIBUTING.md says a merge also needs `Test (macOS 26, Apple Silicon)`. As configured, no test job blocks a merge.
- **Codemagic.** It appears not to run (see Evidence). Either connect the GitHub App and webhook as CONTRIBUTING.md describes, or record that it is dormant. Its pull request trigger also covers only pull requests into `main`.
- **CircleCI macOS credits.** The sampled window had 32 pushes to `main` that ran the macOS jobs in 41 hours; at about 9 minutes each, CircleCI's free credits do not cover a run per push even after change 10 collapses the bursts. The next lever is a setup workflow (dynamic configuration) that decides on Docker, so a skipped commit starts no macOS machine at all.

## Cost of change 1

Every pull request in a stack now gets its own macOS run per push, and an upper pull request runs again when the branch below it is merged into it. Changes 3, 4 and 7 offset that: over the last 60 merges, 22 would have skipped the Swift analysis and 9 the macOS jobs (7 under the old rule). Cancelled `main` runs end with change 3.

## Verification

- `script/test_ci_changes.sh` and `script/python_checks.sh` pass locally; CircleCI's config validator accepts `.circleci/config.yml`; every changed YAML file parses.
- `actionlint` was not available. GitHub validates workflow syntax when the branch is pushed.
- The pull request stacked on the trigger fix is the check of the stacked case: its `Changed paths` and `Build Verification` must report.
