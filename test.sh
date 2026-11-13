#!/bin/bash
set -e

# ./test.sh --changed runs only the atoms that cover the changed Swift files (script/changed_atoms.sh), the commit
# hook's run. It skips the self-checks like every targeted mode and never writes the pass stamp; the plain run stays
# the full gate.
ONLY_ATOMS=""
MODE="full"
if [[ "${1:-}" == "--changed" ]]; then
    MODE="changed"
    shift
    ONLY_ATOMS=${TEST_CHANGED_ATOMS_OVERRIDE-$(script/changed_atoms.sh)}
    unset TEST_CHANGED_ATOMS_OVERRIDE
    if [[ -z "$ONLY_ATOMS" ]]; then
        echo "✅ SUCCESS: no changed file has tests to run."
        exit 0
    fi
fi

TEST_OPT_FLAGS=()
for argument in "$@"; do
    if [[ "$argument" == "--performance-baseline" || "$argument" == "--search-memory" || "$argument" == "--transport-cancellation" || "$argument" == "--publisher-cancellation" || "$argument" == "--library-holdout" || "$argument" == "--today-shadow" ]]; then TEST_OPT_FLAGS=(-O); fi
done

# The plain run is the gate: it starts with the self-checks that need no Swift build. A run with arguments is one
# targeted mode and runs only that (its callers already passed the plain run or are measuring), so it starts fast.
if [[ $# -eq 0 && "$MODE" == "full" ]]; then
    script/design_lint.sh
    script/check_test_registry.sh
    python3 script/evaluation/evaluate.py
    python3 script/evaluation/publisher_review.py
    python3 script/evaluation/publisher_dates.py
    python3 script/evaluation/overview_review.py
    python3 script/evaluation/importance_review.py
    python3 script/evaluation/relation_review.py
    python3 script/evaluation/lead_review.py
    python3 script/evaluation/catalog_review.py
    python3 script/evaluation/fit_pair_head.py
    python3 script/evaluation/calibrate_tension.py
    python3 script/training/pretrain_pairs.py --self-check
fi

# Content key of everything the Swift runner compiles or reads: the working tree (tracked and new files) without
# docs, Markdown other than PRIVACY.md and the Python tooling checked above, plus toolchain, OS and NEWS_* settings.
# A coverage report written inside the tree is an output: it leaves the key, by its path relative to the tree so
# an absolute path is excluded too and nothing else is. A tracked file is never an output.
KEY_EXCLUDES=()
if [[ -n "${NEWS_TEST_COVERAGE:-}" ]]; then
    REPORT_PATH=$(python3 -c 'import os, sys; print(os.path.relpath(os.path.abspath(sys.argv[1]), sys.argv[2]))' \
        "$NEWS_TEST_COVERAGE" "$(git rev-parse --show-toplevel)")
    if [[ "$REPORT_PATH" != ../* ]]; then
        if git ls-files --error-unmatch -- "$REPORT_PATH" > /dev/null 2>&1; then
            echo "❌ NEWS_TEST_COVERAGE names a tracked file ($REPORT_PATH); write the report elsewhere." >&2
            exit 2
        fi
        KEY_EXCLUDES=(":(exclude)$REPORT_PATH")
    fi
fi
runner_inputs_key() {
    local index
    index=$(mktemp "${TMPDIR:-/tmp}/news-test-index.XXXXXX")
    cp "$(git rev-parse --git-path index)" "$index"
    GIT_INDEX_FILE="$index" git add -A
    {
        # A coverage report written inside the tree is an output, not an input.
        GIT_INDEX_FILE="$index" git ls-files -s -- . ':!docs' ':!script/evaluation' ':!script/training' ':!*.md' \
            "${KEY_EXCLUDES[@]}"
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
copy_coverage() {
    local source="$1" destination="$2" temporary
    mkdir -p "$(dirname "$destination")" || return 1
    temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if cp "$source" "$temporary" && mv -f "$temporary" "$destination"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

PASS_STAMP=""
if [[ $# -eq 0 ]] && [[ -z "${NEWS_TEST_FORCE:-}" ]] && KEY=$(runner_inputs_key 2>/dev/null); then
    PASS_STAMP="${TMPDIR:-/tmp}/news-test-passes/$KEY"
    # A coverage run skips only with the report these inputs produced (kept beside the stamp); a run whose export
    # failed, or whose report came from other inputs, runs again.
    if [[ -f "$PASS_STAMP" ]]; then
        if [[ -z "${NEWS_TEST_COVERAGE:-}" ]]; then
            echo "✅ SUCCESS: Swift tests already passed for these inputs ($KEY); skipped. NEWS_TEST_FORCE=1 reruns them."
            exit 0
        elif [[ -f "$PASS_STAMP.lcov" ]] && copy_coverage "$PASS_STAMP.lcov" "$NEWS_TEST_COVERAGE"; then
            echo "Coverage written to $NEWS_TEST_COVERAGE (from the earlier run with these inputs)"
            echo "✅ SUCCESS: Swift tests already passed for these inputs ($KEY); skipped. NEWS_TEST_FORCE=1 reruns them."
            exit 0
        fi
        # No report for these inputs, or it could not be copied: the run produces it.
    fi
fi

# What a runner process leaves under ~/Library, keyed by its executable name: the Neural Engine's compiled-model
# cache (com.apple.e5rt.e5bundlecache, about 100 MB per run and never reused, since every run compiles a new binary),
# the URL cache, HTTP storage and a preferences plist. Removed after each run so they do not pile up (11 GB seen).
prune_runner_state() {
    local runner="$1"
    rm -rf "$HOME/Library/Caches/$runner" "$HOME/Library/HTTPStorages/$runner" "$HOME/Library/Preferences/$runner.plist"
}

# Every run builds into its own directory and names its runner after it, so concurrent runs (another worktree's
# suite, or the pre-commit hook beside a background run) never share a runner binary or its Library state, and an
# interrupted run leaves no Library state behind.
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/news-test-jobs.XXXXXX")
RUN_TAG="${LOGS##*.}"
export LOGS RUN_TAG
# This run's runner name: test_runner.<tag> (see prune_runner_state).
cleanup_run() {
    local library="$HOME/Library"
    rm -rf "$library/Caches/test_runner.$RUN_TAG" "$library/HTTPStorages/test_runner.$RUN_TAG" \
        "$library/Preferences/test_runner.$RUN_TAG.plist" "$LOGS"
}
trap cleanup_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RUNNER="$LOGS/test_runner.$RUN_TAG"
# NEWS_TEST_COVERAGE=PATH makes the plain run write an LCOV report of itself: the one runner is built instrumented,
# every job keeps its own profile, and the profiles merge once the pool passed. One run, gate and coverage (#577).
COVERAGE_FLAGS=()
if [[ -n "${NEWS_TEST_COVERAGE:-}" && $# -eq 0 && "$MODE" == "full" ]]; then
    COVERAGE_FLAGS=(-profile-generate -profile-coverage-mapping)
    mkdir -p "$LOGS/profiles"
fi
script/build_test_runner.sh "$RUNNER" "${TEST_OPT_FLAGS[@]}" "${COVERAGE_FLAGS[@]}"

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
    # The plain run is one job pool over the one runner binary: every test atom is its own process, and the headless
    # harness suites (no window, no Screen Recording: Story Overview sections including Industry Impact (Epic T), reader
    # accessibility and tension calibration) run as atoms of the same binary instead of compiling three more.
    # SocketTests keeps the loopback tests serial in its one process. NEWS_TEST_JOBS bounds how many run at once. Each
    # job's output is printed whole once it ends, so logs never interleave; a failed job's log is printed again at the end.
    CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    JOBS="${NEWS_TEST_JOBS:-$(( 6 < CORES ? 6 : CORES ))}"
    if ! [[ "$JOBS" =~ ^[1-9][0-9]?$ ]]; then
        echo "❌ NEWS_TEST_JOBS=$JOBS must be a whole number from 1 to 99." >&2
        exit 2
    fi
    JOB_LIST="$LOGS/jobs"
    : > "$JOB_LIST"
    # A job is a name and the environment its copy of the runner gets.
    job() { printf '%s\t%s\n' "$1" "$2" >> "$JOB_LIST"; }
    ATOMS="${ONLY_ATOMS:-$(script/test_atoms.sh)}"
    # Longest first, so the pool ends evenly (times in docs/audits/2026-11-07-newstests-split.md); the rest follow.
    LONGEST="ActiveWorkCancellation Socket Clustering UserInterface Storage Intelligence
        Lifecycle AnalysisGeneration FeedKitSwiftSoup News Reader"
    for name in $LONGEST; do
        atom="Tests/${name}Tests.swift"
        if grep -qxF "$atom" <<< "$ATOMS"; then job "${name}Tests" "NEWS_TEST_ATOM=$atom"; fi
    done
    while read -r atom; do
        name=$(basename "$atom" .swift)
        grep -qw "${name%Tests}" <<< "$LONGEST" || job "$name" "NEWS_TEST_ATOM=$atom"
    done <<< "$ATOMS"
    JOB_COUNT=$(wc -l < "$JOB_LIST" | tr -d ' ')
    echo "Running $JOB_COUNT test jobs, $JOBS at a time..."
    set +e
    # Core ML keeps its compiled models in a cache named after the executable, and loading the Neural Engine programs
    # cold costs each process seconds (docs/audits/2026-11-07-shard-io.md), so every job runs this one binary and
    # reuses that cache. Two processes compiling the same model under one name race on the bundle rename (seen on
    # CI), so one process compiles the shared models first; a single job has nothing to race with and loads what it
    # needs. Sharing the name also shares the name's standard defaults and URL storage across the pool's jobs.
    # A failed warm-up only warns: atoms that need no model still run, and those that do report it themselves.
    if [[ "$JOB_COUNT" -gt 1 ]] && ! LLVM_PROFILE_FILE="$LOGS/warm.profraw" "$RUNNER" --warm-models; then
        echo "⚠️ Could not load the shared Core ML models before the pool." >&2
    fi
    # shellcheck disable=SC2016 # the pool script expands its variables inside the worker, by design
    xargs -P "$JOBS" -L 1 bash -c '
        name="$0"
        start=$(date +%s)
        # An instrumented runner writes its profile here; set in the worker, so a space in the path survives xargs.
        if [[ -d "$LOGS/profiles" ]]; then export LLVM_PROFILE_FILE="$LOGS/profiles/%p.profraw"; fi
        env "$@" "$LOGS/test_runner.$RUN_TAG" > "$LOGS/$name.log" 2>&1
        status=$?
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
    # Cleanup that fails fails the run, so a run never passes while runner state is left behind.
    if ! prune_runner_state "$(basename "$RUNNER")"; then
        echo "❌ Could not remove the runner's Library state." >&2
        exit 1
    fi
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
    if [[ ${#COVERAGE_FLAGS[@]} -gt 0 ]]; then
        # The tests are the gate and have passed; a failed export leaves no partial report and does not fail the run.
        if script/coverage_export.sh "$LOGS/profiles" "$RUNNER" "$NEWS_TEST_COVERAGE"; then
            echo "Coverage written to $NEWS_TEST_COVERAGE"
            # The copy beside the stamp lands whole or not at all; without it the next run exports again.
            if [[ -n "$PASS_STAMP" ]] && ! copy_coverage "$NEWS_TEST_COVERAGE" "$PASS_STAMP.lcov"; then
                echo "⚠️ Could not keep the coverage report beside the pass stamp; the next run exports it again." >&2
            fi
        else
            rm -f "$NEWS_TEST_COVERAGE"
            echo "⚠️ Coverage export failed; the tests passed." >&2
        fi
    fi
fi

if [[ -n "$PASS_STAMP" ]] && [[ "$MODE" == "full" ]]; then
    mkdir -p "$(dirname "$PASS_STAMP")"
    touch "$PASS_STAMP"
fi
