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
[[ "$(grep -c '<testcase ' "$WORK/junit.xml")" -eq 2 ]] || fail "each atom must get its own testcase"
grep -q 'tests="2" failures="1"' "$WORK/junit.xml" || fail "failure count must match failing atoms"
grep -q 'ran Tests/Failing.swift' "$WORK/junit.xml" || fail "failure must include the atom output"

script/ci_testsuite.sh --lcov "$WORK/out.lcov" Tests/Failing.swift > /dev/null 2> "$WORK/err" && fail "analysis of a failing atom must exit non-zero"
grep -q 'test atom(s) failed' "$WORK/err" || fail "analysis must report the atom failure, not a coverage error"

script/ci_testsuite.sh --lcov "$WORK/out.lcov" Tests/Passing.swift > /dev/null 2> "$WORK/err" && fail "analysis without profiles must exit non-zero"
grep -q 'no coverage profile' "$WORK/err" || fail "analysis must explain missing profiles"

# A stub toolchain and a runner that writes a profile reach the export, which reports a wrapped-around count.
mkdir "$WORK/bin"
cat > "$WORK/bin/xcrun" <<'STUB'
#!/bin/bash
[ "$1" != "llvm-cov" ] || printf 'DA:1,0\nDA:2,999999999999999999\nDA:3,9999999999999999999\nDA:4,18446744073709551615\n'
STUB
cat > "$WORK/profiling-runner" <<'STUB'
#!/bin/bash
touch "${LLVM_PROFILE_FILE/\%p/$$}"
STUB
chmod +x "$WORK/bin/xcrun" "$WORK/profiling-runner"
PATH="$WORK/bin:$PATH" NEWS_TEST_RUNNER="$WORK/profiling-runner" \
    script/ci_testsuite.sh --lcov "$WORK/out.lcov" Tests/Passing.swift > /dev/null 2>&1 || fail "analysis with a profile must exit 0"
[[ "$(tr '\n' ' ' < "$WORK/out.lcov")" == "DA:1,0 DA:2,999999999999999999 DA:3,1 DA:4,1 " ]] || fail "a count of 19 or more digits must become 1 and other counts stay"

NEWS_TEST_RUNNER="$WORK/unbuilt" script/ci_testsuite.sh "$WORK/junit.xml" > /dev/null || fail "no selected atom must exit 0"
[[ ! -e "$WORK/unbuilt" ]] || fail "no selected atom must not compile the runner"
grep -q 'tests="0" failures="0"' "$WORK/junit.xml" || fail "no selected atom must report an empty suite"

# Every atom needs its own selection rule in the suite, or a change to an atom file may not run that atom.
for atom in $(script/test_atoms.sh); do
    grep -qx "    - test-atom: $atom" .circleci/test-suites.yml || fail "$atom has no test-selection rule in .circleci/test-suites.yml"
done

echo "✅ ci_testsuite.sh checks passed"
