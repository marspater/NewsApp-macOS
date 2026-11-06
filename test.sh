#!/bin/bash
set -e

TEST_OPT_FLAGS=()
for argument in "$@"; do
    if [[ "$argument" == "--performance-baseline" || "$argument" == "--search-memory" || "$argument" == "--transport-cancellation" || "$argument" == "--publisher-cancellation" || "$argument" == "--library-holdout" ]]; then TEST_OPT_FLAGS=(-O); fi
done

script/design_lint.sh
python3 script/evaluation/evaluate.py
python3 script/evaluation/publisher_review.py
python3 script/evaluation/publisher_dates.py
python3 script/evaluation/overview_review.py
python3 script/evaluation/importance_review.py
python3 script/evaluation/relation_review.py
python3 script/evaluation/catalog_review.py
python3 script/evaluation/fit_pair_head.py
python3 script/evaluation/calibrate_tension.py
python3 script/training/pretrain_pairs.py --self-check

# Content key of everything the Swift runner compiles or reads: the working tree (tracked and new files) without
# docs, Markdown other than PRIVACY.md and the Python tooling checked above, plus toolchain, OS and NEWS_* settings.
runner_inputs_key() {
    local index
    index=$(mktemp "${TMPDIR:-/tmp}/news-test-index.XXXXXX")
    cp "$(git rev-parse --git-path index)" "$index"
    GIT_INDEX_FILE="$index" git add -A
    {
        GIT_INDEX_FILE="$index" git ls-files -s -- . ':!docs' ':!script/evaluation' ':!script/training' ':!*.md'
        GIT_INDEX_FILE="$index" git ls-files -s -- PRIVACY.md
        swiftc --version 2>&1
        sw_vers -buildVersion
        uname -m
        echo "${TARGET_MACOS:-}"
        env | grep '^NEWS_' | sort
    } | shasum -a 256 | cut -c1-32
    rm -f "$index"
}

# A plain run skips compiling and running the Swift tests when the same inputs already passed on this machine.
# NEWS_TEST_FORCE=1 runs them anyway; runs with arguments (baselines, live checks) are never skipped.
PASS_STAMP=""
if [ $# -eq 0 ] && [ -z "${NEWS_TEST_FORCE:-}" ] && KEY=$(runner_inputs_key 2>/dev/null); then
    PASS_STAMP="${TMPDIR:-/tmp}/news-test-passes/$KEY"
    if [ -f "$PASS_STAMP" ]; then
        echo "✅ SUCCESS: Swift tests already passed for these inputs ($KEY); skipped. NEWS_TEST_FORCE=1 reruns them."
        exit 0
    fi
fi

# What a runner process leaves under ~/Library, keyed by its executable name: the Neural Engine's compiled-model
# cache (com.apple.e5rt.e5bundlecache, about 100 MB per run and never reused, since every run compiles a new binary),
# the URL cache, HTTP storage and a preferences plist. Removed after each run so they do not pile up (11 GB seen).
prune_runner_state() {
    local runner="$1"
    rm -rf "$HOME/Library/Caches/$runner" "$HOME/Library/HTTPStorages/$runner" "$HOME/Library/Preferences/$runner.plist"
}
export -f prune_runner_state

# Every run builds into its own directory and names its runners after it, so concurrent runs (another worktree's
# suite, or the pre-commit hook beside a background run) never share a runner binary or its Library state, and an
# interrupted run leaves neither runner copies nor their Library state behind.
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/news-test-jobs.XXXXXX")
RUN_TAG="${LOGS##*.}"
export LOGS RUN_TAG
# This run's runner names: test_runner.<tag> and <job>.<tag>.runner (see prune_runner_state).
cleanup_run() {
    local library="$HOME/Library"
    rm -rf "$library/Caches/test_runner.$RUN_TAG" "$library/Caches/"*".$RUN_TAG.runner" \
        "$library/HTTPStorages/test_runner.$RUN_TAG" "$library/HTTPStorages/"*".$RUN_TAG.runner" \
        "$library/Preferences/test_runner.$RUN_TAG.plist" "$library/Preferences/"*".$RUN_TAG.runner.plist" "$LOGS"
}
trap cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RUNNER="$LOGS/test_runner.$RUN_TAG"
script/build_test_runner.sh "$RUNNER" "${TEST_OPT_FLAGS[@]}"

if [[ $# -gt 0 ]]; then
    # A run with arguments is a single targeted mode.
    echo "Running unit tests..."
    set +e
    "$RUNNER" "$@"
    RUNNER_STATUS=$?
    set -e
    prune_runner_state "$(basename "$RUNNER")"
    if [[ "$RUNNER_STATUS" -ne 0 ]]; then exit "$RUNNER_STATUS"; fi
else
    # The plain run is one job pool over the one runner binary: every test file is its own process,
    # Tests/NewsTests.swift is split into NEWS_TEST_SHARDS processes plus one for its slow tests (see NEWS_TEST_SHARD
    # in that file), and the headless harness suites (no window, no Screen Recording: Story Overview sections
    # including Industry Impact (Epic T), reader accessibility and tension calibration) run as atoms of the same
    # binary instead of compiling three more. NEWS_TEST_JOBS bounds how many run at once. Each job's output is
    # printed whole once it ends, so logs never interleave; a failed job's log is printed again at the end.
    SHARDS="${NEWS_TEST_SHARDS:-4}"
    CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    JOBS="${NEWS_TEST_JOBS:-$(( SHARDS + 2 < CORES ? SHARDS + 2 : CORES ))}"
    for setting in "NEWS_TEST_SHARDS=$SHARDS" "NEWS_TEST_JOBS=$JOBS"; do
        if ! [[ "${setting#*=}" =~ ^[1-9][0-9]?$ ]]; then
            echo "❌ $setting must be a whole number from 1 to 99." >&2
            exit 2
        fi
    done
    JOB_LIST="$LOGS/jobs"
    : > "$JOB_LIST"
    # A job is a name and the environment its copy of the runner gets.
    job() { printf '%s\t%s\n' "$1" "$2" >> "$JOB_LIST"; }
    # Longest first, so the pool ends evenly.
    job "NewsTests-slow" "NEWS_TEST_ATOM=Tests/NewsTests.swift NEWS_TEST_SHARD=slow"
    job "NewsTests-sockets" "NEWS_TEST_ATOM=Tests/NewsTests.swift NEWS_TEST_SHARD=sockets"
    for ((i = 0; i < SHARDS; i++)); do
        job "NewsTests-$i-of-$SHARDS" "NEWS_TEST_ATOM=Tests/NewsTests.swift NEWS_TEST_SHARD=$i/$SHARDS"
    done
    script/test_atoms.sh | grep -v '^Tests/NewsTests\.swift$' | while read -r atom; do
        job "$(basename "$atom" .swift)" "NEWS_TEST_ATOM=$atom"
    done
    JOB_COUNT=$(wc -l < "$JOB_LIST" | tr -d ' ')
    echo "Running $JOB_COUNT test jobs, $JOBS at a time..."
    set +e
    # Core ML compiles a model into a cache named after the executable, and two processes compiling the same model
    # under one name race on the bundle rename (seen on CI), so every job runs its own copy of the runner, named
    # after the job and this run.
    # shellcheck disable=SC2016 # the pool script expands its variables inside the worker, by design
    xargs -P "$JOBS" -L 1 bash -c '
        name="$0"
        start=$(date +%s)
        copy="$LOGS/$name.$RUN_TAG.runner"
        cp "$LOGS/test_runner.$RUN_TAG" "$copy"
        env "$@" "$copy" > "$LOGS/$name.log" 2>&1
        status=$?
        # Cleanup that fails marks the job failed, so a run never passes while runner state is left behind.
        if ! rm -f "$copy" || ! prune_runner_state "$(basename "$copy")"; then
            echo "❌ $name: could not remove the runner copy or its Library state" >> "$LOGS/$name.log"
            [[ "$status" -eq 0 ]] && status=1
        fi
        echo "$status" > "$LOGS/$name.status"
        if [[ "$status" -eq 0 ]]; then mark="✅"; else mark="❌"; fi
        # One finished job prints at a time (mkdir is the portable lock), so log blocks never interleave.
        until mkdir "$LOGS/print.lock" 2>/dev/null; do sleep 0.05; done
        printf "%s %s (%ss)\n" "$mark" "$name" "$(( $(date +%s) - start ))"
        cat "$LOGS/$name.log"
        rmdir "$LOGS/print.lock"
        exit "$status"
    ' < "$JOB_LIST"
    POOL_STATUS=$?
    set -e
    STATUS_COUNT=$(ls "$LOGS"/*.status 2>/dev/null | wc -l | tr -d ' ')
    FAILED=$(grep -L '^0$' "$LOGS"/*.status 2>/dev/null || true)
    if [[ -n "$FAILED" ]]; then
        while read -r status; do
            name=$(basename "$status" .status)
            echo "❌ $name failed; its log again:"
            tail -n 40 "$LOGS/$name.log"
        done <<< "$FAILED"
    fi
    if [[ -n "$FAILED" || "$STATUS_COUNT" -ne "$JOB_COUNT" || "$POOL_STATUS" -ne 0 ]]; then
        echo "❌ $STATUS_COUNT of $JOB_COUNT test jobs finished; the pool exited $POOL_STATUS." >&2
        exit 1
    fi
fi

if [ -n "$PASS_STAMP" ]; then
    mkdir -p "$(dirname "$PASS_STAMP")"
    touch "$PASS_STAMP"
fi
