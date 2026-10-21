#!/bin/bash
# Smarter Testing entry point (.circleci/test-suites.yml). Each test atom is a Tests/*.swift entry file.
# usage: script/ci_testsuite.sh JUNIT_PATH ATOM...
#        script/ci_testsuite.sh --lcov LCOV_PATH ATOM...
# Compiles the runner once, runs each atom in its own process and writes one JUnit testcase per atom.
# With --lcov (the analysis command), compiles with coverage instrumentation and writes LCOV instead of JUnit.
set -uo pipefail

cd "$(dirname "$0")/.."

LCOV_PATH=""
JUNIT_PATH=""
if [ "${1:-}" = "--lcov" ]; then
    LCOV_PATH="$2"
    shift 2
else
    JUNIT_PATH="$1"
    shift
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/news-testsuite.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

COVERAGE_FLAGS=()
if [ -n "$LCOV_PATH" ]; then COVERAGE_FLAGS=(-profile-generate -profile-coverage-mapping); fi
script/build_test_runner.sh "$WORK/test_runner" ${COVERAGE_FLAGS[@]+"${COVERAGE_FLAGS[@]}"} || exit 1

STATUS=0
CASES=""
FAILURES=0
for atom in "$@"; do
    echo "Running $atom..."
    START_TIME=$(date +%s)
    NEWS_TEST_ATOM="$atom" LLVM_PROFILE_FILE="$WORK/%p.profraw" "$WORK/test_runner" 2>&1 | tee "$WORK/output.log"
    ATOM_STATUS=${PIPESTATUS[0]}
    DURATION=$(($(date +%s) - START_TIME))
    CASES+="    <testcase name=\"$atom\" classname=\"NewsTests\" file=\"$atom\" time=\"$DURATION\">"
    if [ "$ATOM_STATUS" -ne 0 ]; then
        STATUS=1
        FAILURES=$((FAILURES + 1))
        # Keep the tail of the output so the failure is readable in the Tests tab; "]]>" would end the CDATA early.
        CASES+="<failure message=\"exit status $ATOM_STATUS\"><![CDATA[$(tail -n 50 "$WORK/output.log" | sed 's/]]>/]] >/g')]]></failure>"
    fi
    CASES+="</testcase>
"
done

if [ -n "$JUNIT_PATH" ]; then
    mkdir -p "$(dirname "$JUNIT_PATH")"
    cat > "$JUNIT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="NewsTests" tests="$#" failures="$FAILURES">
  <testsuite name="unit tests" tests="$#" failures="$FAILURES">
$CASES  </testsuite>
</testsuites>
EOF
fi

if [ -n "$LCOV_PATH" ]; then
    xcrun llvm-profdata merge -sparse "$WORK"/*.profraw -o "$WORK/coverage.profdata" || exit 1
    mkdir -p "$(dirname "$LCOV_PATH")"
    # Report repository sources only: drop the staged test copies and the SwiftPM dependency checkouts.
    xcrun llvm-cov export -format=lcov -instr-profile "$WORK/coverage.profdata" "$WORK/test_runner" \
        -ignore-filename-regex='news-tests\.|/\.build/' > "$LCOV_PATH" || exit 1
fi

exit $STATUS
