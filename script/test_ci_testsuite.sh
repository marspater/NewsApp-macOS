#!/bin/bash
# Self-check for script/ci_testsuite.sh with a stub runner, so it needs no Swift toolchain.
set -uo pipefail

cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/news-testsuite-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The stub fails only for Tests/Failing.swift and never writes a coverage profile.
cat > "$WORK/runner" <<'STUB'
#!/bin/bash
echo "ran $NEWS_TEST_ATOM"
[ "$NEWS_TEST_ATOM" != "Tests/Failing.swift" ]
STUB
chmod +x "$WORK/runner"
export NEWS_TEST_RUNNER="$WORK/runner"

fail() { echo "❌ ci_testsuite.sh check: $1" >&2; exit 1; }

script/ci_testsuite.sh "$WORK/junit.xml" Tests/Passing.swift > /dev/null || fail "passing atom must exit 0"
grep -q 'file="Tests/Passing.swift"' "$WORK/junit.xml" || fail "testcase must carry the atom as its file"
grep -q 'failures="0"' "$WORK/junit.xml" || fail "passing run must report no failures"

script/ci_testsuite.sh "$WORK/junit.xml" Tests/Passing.swift Tests/Failing.swift > /dev/null && fail "failing atom must exit non-zero"
[ "$(grep -c '<testcase ' "$WORK/junit.xml")" -eq 2 ] || fail "each atom must get its own testcase"
grep -q 'tests="2" failures="1"' "$WORK/junit.xml" || fail "failure count must match failing atoms"
grep -q 'ran Tests/Failing.swift' "$WORK/junit.xml" || fail "failure must include the atom output"

script/ci_testsuite.sh --lcov "$WORK/out.lcov" Tests/Failing.swift > /dev/null 2> "$WORK/err" && fail "analysis of a failing atom must exit non-zero"
grep -q 'test atom(s) failed' "$WORK/err" || fail "analysis must report the atom failure, not a coverage error"

script/ci_testsuite.sh --lcov "$WORK/out.lcov" Tests/Passing.swift > /dev/null 2> "$WORK/err" && fail "analysis without profiles must exit non-zero"
grep -q 'no coverage profile' "$WORK/err" || fail "analysis must explain missing profiles"

echo "✅ ci_testsuite.sh checks passed"
