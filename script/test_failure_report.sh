#!/bin/bash
# Proves the runner reports every failure of an atom before its nonzero exit (#577): the hidden
# `failure-report-self-check` atom fails twice, and this expects exit 1 with both failure lines and the summary.
# usage: script/test_failure_report.sh [RUNNER]  (without RUNNER it builds one, incrementally, like ./test.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/news-failure-report.XXXXXX")
# A built runner is named after this run, as ./test.sh names its own, so cleanup never touches another run's state;
# a supplied runner's Library state stays the caller's.
NAME="test_runner.${WORK##*.}"
trap 'rm -rf "$WORK"' EXIT
RUNNER="${1:-}"
if [[ -z "$RUNNER" ]]; then
    RUNNER="$WORK/$NAME"
    trap 'rm -rf "$WORK" "$HOME/Library/Caches/$NAME" "$HOME/Library/HTTPStorages/$NAME" \
        "$HOME/Library/Preferences/$NAME.plist"' EXIT
    script/build_test_runner.sh "$RUNNER" > "$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log"; exit 1; }
fi
NEWS_TEST_ATOM=failure-report-self-check "$RUNNER" > "$WORK/out.log" 2>&1
status=$?
fail=0
[[ "$status" -eq 1 ]] || { echo "❌ expected exit 1, got $status"; fail=1; }
for line in "self-check first failure" "selfCheckFirst threw" "self-check second failure" \
    "2 failed test(s), 3 failure(s)" \
    "   selfCheckFirst: ASSERTION FAILED: self-check first failure" \
    "   selfCheckSecond: ASSERTION FAILED: self-check second failure"; do
    grep -qF "$line" "$WORK/out.log" || { echo "❌ missing: $line"; fail=1; }
done
if [[ "$fail" -eq 0 ]]; then echo "Failure report: both failed tests reported, exit 1"; else cat "$WORK/out.log"; fi
exit "$fail"
