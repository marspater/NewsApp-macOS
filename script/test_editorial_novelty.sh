#!/bin/bash
# Opt-in on-device novelty experiment using fictional authored controls and isolated output.
set -euo pipefail
cd "$(dirname "$0")/.."
CORPUS="${1:-Tests/Fixtures/editorial/novelty-smoke.json}"
OUTPUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/news-novelty-results.XXXXXX")}"
mkdir -p "$OUTPUT"
if [[ -e "$OUTPUT/novelty.json" ]]; then
    echo "Refusing to overwrite $OUTPUT/novelty.json" >&2
    exit 1
fi
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-novelty-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
script/build_test_runner.sh "$STAGE/novelty-runner" -O
NEWS_TEST_ATOM=Tests/EditorialNoveltyTests.swift \
    NEWS_EDITORIAL_BUILD_CONFIGURATION=Release \
    NEWS_EDITORIAL_CORPUS="$CORPUS" NEWS_EDITORIAL_OUTPUT="$OUTPUT/novelty.json" "$STAGE/novelty-runner"
