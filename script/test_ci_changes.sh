#!/bin/bash
# Self-check for script/ci_changes.sh and script/ci_push_base.sh on a scratch repository with a stub `gh`, so it
# needs no Swift toolchain and no network.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ci_changes.sh"
push_base="$(cd "$(dirname "$0")" && pwd)/ci_push_base.sh"
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

# ci_push_base.sh: the stub prints $STUB_SHA, or fails when it is `fail`.
mkdir -p "$work/bin"
printf '#!/bin/bash\n[[ "$STUB_SHA" != fail ]] && echo "$STUB_SHA"\n' > "$work/bin/gh"
chmod +x "$work/bin/gh"
base_of() { STUB_SHA=$1 GITHUB_REPOSITORY=o/r PATH="$work/bin:$PATH" "$push_base" ci.yml before; }
[[ "$(base_of "$docs")" == "$docs" ]] || { echo "❌ ci_push_base.sh check: a finished ancestor is the base" >&2; exit 1; }
[[ "$(base_of "")" == before ]] || { echo "❌ ci_push_base.sh check: no finished run falls back to BEFORE" >&2; exit 1; }
[[ "$(base_of fail)" == unknown ]] || { echo "❌ ci_push_base.sh check: an API failure runs everything" >&2; exit 1; }
stray=$(git commit-tree "$(git hash-object -t tree -w /dev/null)" -m other)
[[ "$(base_of "$stray")" == before ]] || { echo "❌ ci_push_base.sh check: a run off this history is ignored" >&2; exit 1; }
echo "ci_changes.sh and ci_push_base.sh self-check passed"
