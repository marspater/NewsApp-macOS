#!/bin/bash
# Native UI QA checks (Tests/Harness/NativeUIQAChecks.swift): a harness app built from the production views, run with
# the arguments given.
set -e

cd "$(dirname "$0")/.."
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-ui-qa.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

echo "Compiling Native UI QA Checks..."
NEWS_HARNESS=Tests/Harness/NativeUIQAChecks.swift NEWS_APP_DIR="$STAGE/NewsHarness.app" ./build.sh

echo "Running Native UI QA Checks..."
"$STAGE/NewsHarness.app/Contents/MacOS/NewsHarness" "$@"
echo "Native UI QA Checks completed successfully."
