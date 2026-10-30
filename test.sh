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

echo "Running unit tests..."
./test_runner "$@"

# Clean up
rm -f test_runner

# The standalone headless runners (no window, no Screen Recording): Story Overview sections including Industry
# Impact (Epic T), reader accessibility and tension calibration. A run with arguments is a single targeted mode.
if [[ $# -eq 0 ]]; then
    script/test_event_overview_accessibility.sh
    script/test_reader_accessibility.sh
    script/test_tension_calibration.sh
fi

if [ -n "$PASS_STAMP" ]; then
    mkdir -p "$(dirname "$PASS_STAMP")"
    touch "$PASS_STAMP"
fi
