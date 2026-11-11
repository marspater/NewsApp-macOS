# Research tooling

The tools used for research on News (model candidates, matcher changes, holdout replays), how they are set up on Mars's Mac, and the flow every agent follows. These tools are not part of the app, its build or CI. The domains a run changes (Themis, Harmonia, Proteus and the others) are defined in the [Angelia register](ANGELIA.md). The app's own build, test and measurement tools are in [CONTRIBUTING.md](../CONTRIBUTING.md).

Changes to this setup are logged in the [change log](#change-log) at the end.

## The flow, for every agent

1. **Before a run:** read what was already tried. `news-ledger ui` shows every run; filter by `dataset` first. Do not repeat a run that is on record unless the code under it changed.
2. **Run** the experiment as its issue and [AGENTS.md](../AGENTS.md) describe. Receipts stay under `~/news-eval/`.
3. **After each run:** log one line with its real numbers (see [Logging a run](#logging-a-run)). A run counts as done once its line is in the ledger.
4. **Conclusions** still go on the issue, and a claim in a PR or audit names the ledger run it rests on.

A session without access to Mars's Mac cannot read or write the ledger. For step 1 the coordinating session puts the runs already on record for that dataset into the session's brief (name, commit, the settings that distinguish it, verdict and measures); a session that was given none asks on the issue before it runs. For step 3 it writes the complete `news-ledger log` line it would have run (experiment, what was tried, dataset, commit, verdict, source, every setting such as `knobs` and `matcher`, each measure, and `date=` when the run was measured on an earlier day) in its PR, or on the issue when there is no PR, and the coordinating session logs them.

## What is installed

| Tool | Version | Job | Opened with |
| --- | --- | --- | --- |
| [MLflow](https://mlflow.org) | 3.18.0 | The run ledger: one line per run, with parameters and numbers | `news-ledger ui` |
| [marimo](https://marimo.io) | 0.25.2 | The page Mars reads: runs per dataset against the baseline | `news-ledger notebook` |
| [Datasette](https://datasette.io) | 0.65.5 | Browse a SQLite library copy in the browser, read-only | `news-ledger data COPY.sqlite3` |

Each tool is installed in its own environment with `uv tool install --python 3.13 <tool>`, so none of them can disturb the training environment pinned in `script/training/requirements.txt`. Everything runs on this Mac and binds to `127.0.0.1`. No cloud service is involved.

## Where things live

Everything is in `~/news-eval/mlflow/`, beside the evaluation receipts and outside the repository, so every worktree and every agent shares one ledger.

| Path | What it is |
| --- | --- |
| `ledger.db` | The MLflow store (SQLite). The only copy of the ledger |
| `backups/` | One copy of the ledger per day, taken before that day's first write |
| `ledger`, `ledger.py` | The `news-ledger` command (`~/.local/bin/news-ledger` links to it) |
| `env.sh` | The MLflow settings: the store's address, usage reports off |
| `clustering_737.py` | The marimo notebook for #737; it opens the ledger read-only |

These files are not under version control. A change to them is recorded in the change log below.

## Commands

`news-ledger` works from any folder and writes only under `~/news-eval/mlflow/`.

| Command | Does | Address |
| --- | --- | --- |
| `news-ledger log <experiment> "<what was tried>" key=value…` | Records one run | |
| `news-ledger ui` | MLflow: every run, sortable and comparable | `http://127.0.0.1:5737` |
| `news-ledger notebook` | The #737 page; `news-ledger notebook edit` to change it | `http://127.0.0.1:5738` |
| `news-ledger data COPY.sqlite3` | Datasette on a library copy; refuses the live library | `http://127.0.0.1:5739` |
| `news-ledger backup` | Copies the ledger to `backups/` now | |

Use these commands, not the tools' own. A plain `marimo edit` writes a `__marimo__` folder where it starts, a plain `mlflow ui` in a shell without `env.sh` creates an empty `mlflow.db` there, and on macOS port 5000, MLflow's default, belongs to AirPlay Receiver. The repository ignores those stray files.

## Logging a run

```bash
news-ledger log 737-clustering "g + newsletter strip" \
    dataset=library-holdout-2026-11-03 commit=1a3a7ca verdict=failed \
    source=docs/audits/2026-11-06-recall-edition-admission.md \
    knobs="NEWS_VETO_SHARE=0.34 NEWS_PAIR_THRESHOLD=0.85" \
    strict_same=13 strict_related=6 strict_wrong=3 story_good=21 story_wrong=3
```

A value that is a number becomes a measure; anything else becomes a parameter. `date=YYYY-MM-DD` back-dates a run measured earlier.

| Field | Required | Meaning |
| --- | --- | --- |
| `<experiment>` | yes | One per research question, named after its issue: `737-clustering` |
| `dataset` | yes | The exact set the numbers were measured on. Numbers from different sets are not comparable, and relabelled or split sets get their own name |
| `verdict` | yes | `baseline`, `reference` (a setting kept for comparison), `passed`, `failed`, `shipped` or `superseded` |
| `source` | yes | The audit file or receipt folder that holds the evidence |
| `commit` | when known | The commit the run was measured on |
| `knobs`, `matcher`, `note` | optional | The setting that distinguishes this run |
| `failed_because` | with `verdict=failed` | What made the run fail, so the row explains itself when the same numbers are `reference` elsewhere |
| `receipt` | optional | The log or output folder of the run under `~/news-eval`, relative to it |

The command refuses a run without `dataset`, `verdict` and `source`, and a verdict outside the list.

### Measures

One name means one thing. Before adding a name, check this table and the names already in the ledger; add a row here when a new one is needed.

| Name | Meaning |
| --- | --- |
| `strict_same`, `strict_related`, `strict_wrong` | Holdout pairs linked into one event, by their label: same occurrence, related, different |
| `story_good`, `story_wrong` | Pairs linked at story level: same plus related, and different |
| `multi_publisher_story` | Recent stories in a multi-publisher **story** (the harness line "in a multi-publisher story") |
| `multi_publisher_event` | Recent stories in a multi-publisher **event** (the harness line "in a multi-publisher event") |
| `recent_stories` | The denominator of both counts above |
| `groups` | Groups in the grouping evaluation |
| `tune_matched`, `tune_false`, `tune_missed` | The tune corpus: pairs matched, false pairs, pairs missed |
| `regression_matched`, `regression_false`, `regression_missed` | The authored regression sets, likewise |
| `same`, `wrong`, `cutoff` | The 24 October library holdout: same pairs linked and wrong links at that cutoff |
| `same_pairs`, `story_pairs` | The denominators of strict and story recall: labelled `same` pairs, and `same` plus `related` pairs, in the replay |
| `pass_seconds` | Clustering time of the replay, from the harness summary line |
| `regression_event_pairs`, `regression_story_pairs` | The authored story regressions: event pairs and story pairs checked |
| `known_gaps_event`, `known_gaps_story`, `unexpected`, `passed` | The authored story regressions: known gaps, unexpected links, and 1 when the set passed |
| `pairs`, `scored_pairs`, `third_read_pairs` | A label review: pairs read, pairs both passes labelled without `unsure`, pairs sent to the third read |
| `first_second_agree_pegged_same`, `first_second_agree_pegged_later` | A label review: pairs on which first and second pass agree, with `pegged` counted as `same` or as `later` |
| `kappa_pegged_same`, `kappa_pegged_later` | A label review: Cohen's kappa of first against second pass, likewise |
| `labels_changed`, `three_way_splits` | A label review: first-pass labels the review changed, and pairs no two reads agree on |
| `page_stories`, `page_entries` | A Today page timing: stories loaded and the story entries they group into |
| `page_loader_ms`, `page_assign_ms` | A Today page timing: median milliseconds of the context load and of the lane assignment, from the `TODAY_PAGE_TIMING` line of `--today-shadow` |
| `candidates_72h`, `candidates_24h` | A Today shadow run (`--today-shadow`): stories the subscription list admits in the 72 h window, and those of the last 24 h |
| `labelled_stories`, `labelled_events` | A Today shadow run: labelled stories and labelled In Motion events that are candidates under the subscription list |
| `lead_precision_at_5`, `lead_precision_at_5_publisher_count`, `lead_precision_at_5_briefing` | A Today shadow run: share of the top five labelled candidates that the labels call Lead-worthy, ranked by the Z2 score, by publisher count and by the Briefing signals |
| `lane_purity` | A Today shadow run: share of labelled stories placed in the lane their label expects |
| `lane_lead`, `lane_in_motion`, `lane_deep_read`, `lane_your_beat`, `lane_outside`, `lane_latest` | A Today shadow run: stories each lane shows in the 72 h edition |
| `latest_completeness`, `duplicate_rate` | A Today shadow run: share of candidates placed in a lane, and share of placements that repeat a story |
| `in_motion_clearing` | A Today shadow run: stories that clear In Motion's bar, before its cap |
| `in_motion_updates_shown`, `in_motion_updates_missed` | A Today shadow run: labelled real updates among the candidates that In Motion shows, and those it does not show |
| `in_motion_borderline_shown`, `in_motion_repetitions_shown`, `in_motion_initial_shown`, `in_motion_unlabelled_shown` | A Today shadow run: what else In Motion shows, by event label (borderline, repetition, initial report) or without one |
| `your_beat_qualifying_24h` | A Today shadow run: stories of the last 24 h that clear Your Beat's bar, before its cap |
| `your_beat_top_share`, `your_beat_top3_share` | A Today shadow run: among those stories, the share of the busiest publisher and of the busiest three |
| `your_beat_shown_top_share`, `your_beat_shown_top3_share` | A Today shadow run: the same two shares inside Your Beat as the 72 h edition shows it |
| `your_beat_qualifying_24h_newest15`, `your_beat_qualifying_24h_newest5` | A Today shadow run: `your_beat_qualifying_24h` with the reading history cut to its newest 15 and its newest 5 stories |
| `outside_clearing` | A Today shadow run: stories that clear Outside Your Usual's bar, before its cap |

A rescored run keeps its replay and changes only the labels; its `dataset` names the label set, for example `validation-2026-10-29+reviewed-labels-pegged-as-same`.

`multi_publisher` on its own is refused: until 10 November 2026 it held the story count in some runs and the event count in others (442 and 451 against 433 and 443 on the 3 November holdout).

### What never goes in

- Article text, headlines or anything else from a library. Measures and settings only.
- Any reading from a sealed holdout.
- A number that was not measured.

## Reading the ledger

- `news-ledger ui`, then the experiment. Add the columns you need and filter with `tags.dataset = '<set>'`.
- `news-ledger notebook` for #737: pick a dataset, then a measure. Bars are runs, oldest first, and the dashed line is the newest baseline on that set.
- From a script: MLflow's Python API with the tracking address in `env.sh`, or SQLite opened read-only on `ledger.db`.

## Setting it up again

On a new Mac, or after a clean install. The tools are installed with [uv](https://docs.astral.sh/uv/), which comes from [Homebrew](https://brew.sh) here (install Homebrew first where `brew` is missing); check that `uv --version` answers before the next step:

```bash
brew install uv
```

```bash
uv tool install --python 3.13 mlflow
uv tool install --python 3.13 marimo
uv tool install --python 3.13 datasette
```

Then restore `~/news-eval/mlflow/` from a backup and link the command:

```bash
ln -sf ~/news-eval/mlflow/ledger ~/.local/bin/news-ledger
```

Last, source `~/news-eval/mlflow/env.sh` from `~/.zshenv`, so a plain `mlflow` command in a new shell also uses the ledger with usage reports off. Mars's Mac has this line since 10 November 2026:

```bash
echo '[ -f "$HOME/news-eval/mlflow/env.sh" ] && . "$HOME/news-eval/mlflow/env.sh"' >> ~/.zshenv
```

## Change log

| Date | Change |
| --- | --- |
| 10 November 2026 | MLflow, marimo and Datasette installed. Ledger created with the 19 runs on record before that day; the #737 session added its own. Deepnote's cloud was considered and not adopted: the models and the data stay on this Mac |
| 10 November 2026 | `news-ledger` command, fixed ports, daily backups, required fields and the verdict list. MLflow's usage reports turned off (they were on for the first hours). `multi_publisher` split into `multi_publisher_story` and `multi_publisher_event` and the affected runs renamed |
