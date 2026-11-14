#!/bin/bash
# Self-check for script/ci_changes.sh on a scratch repository, so it needs no Swift toolchain.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ci_changes.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/news-ci-changes.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
git config user.email check@example.invalid
git config user.name check

commit() {
    mkdir -p "$(dirname "$1")"
    echo "$RANDOM" >> "$1"
    git add -A
    git commit -qm "$1"
    git rev-parse HEAD
}
expect() {
    local got
    got=$("$script" "$2" "$3" ${4:+"$4"})
    [[ "$got" == "$1" ]] || { echo "❌ ci_changes.sh check: $5 (expected $1, got $got)" >&2; exit 1; }
}

root=$(commit Sources/App.swift)
docs=$(commit docs/notes.md)
expect false "$root" "$docs" "" "documentation alone changes nothing"
tooling=$(commit script/evaluation/evaluate.py)
expect false "$docs" "$tooling" "" "Python tooling alone needs no macOS run"
privacy=$(commit PRIVACY.md)
expect true "$tooling" "$privacy" "" "PRIVACY.md is read by a test"
circle=$(commit .circleci/config.yml)
expect false "$privacy" "$circle" "" "another provider's configuration changes nothing"
expect true "$privacy" "$circle" '^\.circleci/' "the caller's own configuration counts"
code=$(commit Sources/App.swift)
expect true "$circle" "$code" "" "a source file counts"
expect true "$root" "$code" "" "a range counts every commit in it"
expect false "$code" "$code" "" "an empty range changes nothing"
expect true "0000000000000000000000000000000000000000" "$code" "" "an unknown base counts as a change"
echo "ci_changes.sh self-check passed"
