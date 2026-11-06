#!/bin/bash
# Story Overview sections, Industry Impact included (Epic T), headless: the suite a plain ./test.sh runs as the
# Tests/EventOverviewAccessibilityTests.swift job, on its own.
set -e

cd "$(dirname "$0")/.."
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-overview-tests.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
script/build_test_runner.sh "$STAGE/runner"

echo "Running Event Overview Accessibility Tests..."
NEWS_TEST_ATOM=Tests/EventOverviewAccessibilityTests.swift "$STAGE/runner" "$@"
echo "Event Overview Accessibility Tests completed successfully."
