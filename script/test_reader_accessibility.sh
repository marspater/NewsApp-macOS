#!/bin/bash
# Reader accessibility, headless: the suite a plain ./test.sh runs as the Tests/ReaderAccessibilityTests.swift job,
# on its own.
set -e

cd "$(dirname "$0")/.."
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-reader-tests.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
script/build_test_runner.sh "$STAGE/runner"

echo "Running Reader Accessibility Tests..."
NEWS_TEST_ATOM=Tests/ReaderAccessibilityTests.swift "$STAGE/runner" "$@"
echo "Reader Accessibility Tests completed successfully."
