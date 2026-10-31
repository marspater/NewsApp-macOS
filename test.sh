#!/bin/bash
set -e

TEST_OPT_FLAGS=()
for argument in "$@"; do
    if [[ "$argument" == "--performance-baseline" || "$argument" == "--transport-cancellation" || "$argument" == "--publisher-cancellation" ]]; then TEST_OPT_FLAGS=(-O); fi
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

script/build_test_runner.sh test_runner "${TEST_OPT_FLAGS[@]}"

if [[ $# -gt 0 ]]; then
    # A run with arguments is a single targeted mode.
    echo "Running unit tests..."
    ./test_runner "$@"
    rm -f test_runner
else
    # The plain run is one job pool over the one runner binary: every test file is its own process,
    # Tests/NewsTests.swift is split into NEWS_TEST_SHARDS processes plus one for its slow tests (see NEWS_TEST_SHARD
    # in that file), and the headless harness suites (no window, no Screen Recording: Story Overview sections
    # including Industry Impact (Epic T), reader accessibility and tension calibration) run as atoms of the same
    # binary instead of compiling three more. NEWS_TEST_JOBS bounds how many run at once. Each job's output is
    # printed whole once it ends, so logs never interleave; a failed job's log is printed again at the end.
    SHARDS="${NEWS_TEST_SHARDS:-4}"
    JOBS="${NEWS_TEST_JOBS:-$(( SHARDS + 2 ))}"
    LOGS=$(mktemp -d "${TMPDIR:-/tmp}/news-test-jobs.XXXXXX")
    JOB_LIST="$LOGS/jobs"
    : > "$JOB_LIST"
    job() { printf '%s\t%s\n' "$1" "$2" >> "$JOB_LIST"; }
    # Longest first, so the pool ends evenly.
    job "NewsTests-slow" "NEWS_TEST_ATOM=Tests/NewsTests.swift NEWS_TEST_SHARD=slow ./test_runner"
    for ((i = 0; i < SHARDS; i++)); do
        job "NewsTests-$i-of-$SHARDS" "NEWS_TEST_ATOM=Tests/NewsTests.swift NEWS_TEST_SHARD=$i/$SHARDS ./test_runner"
    done
    for atom in Tests/EventOverviewAccessibilityTests.swift Tests/ReaderAccessibilityTests.swift \
        Tests/TensionCalibrationTests.swift \
        $(grep -oE 'selected\("Tests/[A-Za-z0-9]+\.swift"\)' script/build_test_runner.sh \
        | grep -oE 'Tests/[A-Za-z0-9]+\.swift' | sort -u | grep -v '^Tests/NewsTests\.swift$'); do
        job "$(basename "$atom" .swift)" "NEWS_TEST_ATOM=$atom ./test_runner"
    done
    echo "Running $(wc -l < "$JOB_LIST" | tr -d ' ') test jobs, $JOBS at a time..."
    export LOGS
    set +e
    xargs -P "$JOBS" -L 1 sh -c '
        name="$0"
        start=$(date +%s)
        ( eval "$*" ) > "$LOGS/$name.log" 2>&1
        status=$?
        echo "$status" > "$LOGS/$name.status"
        if [ "$status" -eq 0 ]; then mark="✅"; else mark="❌"; fi
        printf "%s %s (%ss)\n" "$mark" "$name" "$(( $(date +%s) - start ))"
        cat "$LOGS/$name.log"
        exit "$status"
    ' < "$JOB_LIST"
    set -e
    rm -f test_runner
    FAILED=$(grep -L '^0$' "$LOGS"/*.status 2>/dev/null || true)
    if [ -n "$FAILED" ]; then
        for status in $FAILED; do
            name=$(basename "$status" .status)
            echo "❌ $name failed; its log again:"
            tail -n 40 "$LOGS/$name.log"
        done
        rm -rf "$LOGS"
        exit 1
    fi
    rm -rf "$LOGS"
fi

if [ -n "$PASS_STAMP" ]; then
    mkdir -p "$(dirname "$PASS_STAMP")"
    touch "$PASS_STAMP"
fi
