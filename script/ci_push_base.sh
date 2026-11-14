#!/bin/bash
# Prints the commit a GitHub Actions push to main is measured from: the head of WORKFLOW's newest push run on main
# that finished (passed or failed), when it is an ancestor of HEAD; with no such run, BEFORE. Main runs queue, and a
# newer push replaces a waiting run before it starts, so a run measured from BEFORE alone could find nothing to test
# while the replaced run's commits went untested by both. Prints `unknown`, which runs everything, if the API fails.
#
#   script/ci_push_base.sh WORKFLOW BEFORE        (needs GH_TOKEN with actions: read, and GITHUB_REPOSITORY)
set -euo pipefail

workflow=$1
before=$2
if ! last=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" --branch main --event push \
    --status completed --limit 20 --json headSha,conclusion \
    --jq '[.[] | select(.conclusion == "success" or .conclusion == "failure")][0].headSha // empty'); then
    echo unknown
elif [[ -n "$last" ]] && git merge-base --is-ancestor "$last" HEAD 2> /dev/null; then
    echo "$last"
else
    echo "$before"
fi
