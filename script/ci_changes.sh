#!/bin/bash
# Prints `true` when BASE..HEAD changes a file that can affect the app, its tests or the calling pipeline, else
# `false`; GitHub Actions decides with it whether a pull request or push needs the macOS jobs. Paths that cannot:
# documentation, changelog fragments, the Python tooling (CircleCI `checks` runs its self-checks on every push,
# and test.sh's runner key leaves it out too), review-bot and linter settings, and each CI provider's own files.
# PRIVACY.md stays in: a test checks it exists.
#
#   script/ci_changes.sh BASE HEAD [OWN]
#
# OWN is an extended regex for the caller's own configuration, which always counts. An unknown BASE counts as a
# change, so a missing history never skips a test.
set -euo pipefail

base=$1
head=$2
own=${3:-}
never='(\.md$|^docs/|^LICENSE$|^NOTICE$|^changelog/|^script/(evaluation|training)/|^\.github/|^\.circleci/|^codemagic\.yaml$|^\.codacy|^\.coderabbit\.yaml$|^\.sonarcloud\.properties$|^\.claude/|^\.gitignore$)'
always="^PRIVACY\.md\$${own:+|$own}"

if ! changed=$(git diff --name-only "$base" "$head" 2> /dev/null); then
    echo true
    exit 0
fi
if [[ -n "$changed" ]] && { grep -Evq "$never" <<< "$changed" || grep -Eq "$always" <<< "$changed"; }; then
    echo true
else
    echo false
fi
