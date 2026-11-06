#!/bin/bash
# Compiles the regression runner used by ./test.sh and script/ci_testsuite.sh: the NewsTestRunner target of
# News.xcodeproj, every file under Sources/ except the app's entry point plus every Tests/*.swift outside Harness/,
# built incrementally into build/DerivedData (script/xcode_build.sh) and copied to OUTPUT.
# usage: script/build_test_runner.sh OUTPUT [-O] [extra swiftc flags...]
# -O builds the Release configuration (the opt-in timing modes); other flags reach swiftc through OTHER_SWIFT_FLAGS
# (ci_testsuite.sh --lcov: -profile-generate -profile-coverage-mapping, which also links the profile runtime).
# Run OUTPUT with NEWS_TEST_ATOM set to a Tests/*.swift entry file to run only that file's tests.
set -e

cd "$(dirname "$0")/.."
OUTPUT="$1"
shift

CONFIGURATION=Debug
FLAGS=()
for flag in "$@"; do
    if [[ "$flag" == -O ]]; then CONFIGURATION=Release; else FLAGS+=("$flag"); fi
done
SETTINGS=()
if [[ ${#FLAGS[@]} -gt 0 ]]; then SETTINGS+=(OTHER_SWIFT_FLAGS="\$(inherited) ${FLAGS[*]}"); fi
case " ${FLAGS[*]} " in *" -profile-generate "*) SETTINGS+=(OTHER_LDFLAGS="\$(inherited) -fprofile-instr-generate") ;; esac

echo "Compiling tests for macOS ${TARGET_MACOS:-15.0} ($(uname -m), $CONFIGURATION)..."
source script/xcode_build.sh
news_xcodebuild NewsTestRunner "$CONFIGURATION" "${SETTINGS[@]}"
cp "$NEWS_DERIVED_DATA/Build/Products/$CONFIGURATION/NewsTestRunner" "$OUTPUT"
