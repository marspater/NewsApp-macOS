#!/bin/bash
# Merges the .profraw files of one instrumented runner into one LCOV report of the repository sources.
# usage: script/coverage_export.sh PROFILE_DIR RUNNER LCOV_PATH
set -uo pipefail
PROFILE_DIR="$1"
RUNNER="$2"
LCOV_PATH="$3"
PROFILES=("$PROFILE_DIR"/*.profraw)
if [ ! -e "${PROFILES[0]}" ]; then
    echo "Coverage export failed: the runner wrote no profile. Was it built with -profile-generate?" >&2
    exit 1
fi
xcrun llvm-profdata merge -sparse "${PROFILES[@]}" -o "$PROFILE_DIR/coverage.profdata" || exit 1
mkdir -p "$(dirname "$LCOV_PATH")"
# Report repository sources only: drop the SwiftPM dependency checkouts.
# llvm-cov can report a wrapped-around line count (2^64 - 1) that CircleCI's parser rejects. Report those lines
# as covered: impact analysis then runs the atom more often, never less.
xcrun llvm-cov export -format=lcov -instr-profile "$PROFILE_DIR/coverage.profdata" "$RUNNER" \
    -ignore-filename-regex='/SourcePackages/' \
    | sed -E 's/^(DA:[0-9]+,)[0-9]{19,}$/\11/' > "$LCOV_PATH" || exit 1
