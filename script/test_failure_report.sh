#!/bin/bash
# Proves the runner reports every failure of an atom before its nonzero exit (#577): the hidden
# `failure-report-self-check` atom fails twice, and this expects exit 1 with both failure lines and the summary.
# usage: script/test_failure_report.sh [RUNNER]  (without RUNNER it builds one, incrementally, like ./test.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/news-failure-report.XXXXXX")
trap 'rm -rf "$WORK" "$HOME/Library/Caches/test_runner" "$HOME/Library/HTTPStorages/test_runner"' EXIT
RUNNER="${1:-}"
if [[ -z "$RUNNER" ]]; then
    RUNNER="$WORK/test_runner"
    script/build_test_runner.sh "$RUNNER" > "$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log"; exit 1; }
fi
NEWS_TEST_ATOM=failure-report-self-check "$RUNNER" > "$WORK/out.log" 2>&1
status=$?
fail=0
[[ "$status" -eq 1 ]] || { echo "❌ expected exit 1, got $status"; fail=1; }
for line in "self-check first failure" "selfCheckFirst threw" "self-check second failure" \
    "2 failed test(s), 3 failure(s)"; do
    grep -qF "$line" "$WORK/out.log" || { echo "❌ missing: $line"; fail=1; }
done
[[ "$fail" -eq 0 ]] && echo "Failure report: both failed tests reported, exit 1" || cat "$WORK/out.log"
exit "$fail"
