#!/bin/bash
# Synthetic opt-in storage and profile-informed ranking controls; no real library access.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-personalization-results.XXXXXX")}"
mkdir -p "$OUTPUT"
[[ ! -e "$OUTPUT/personalization-evaluation.json" ]] || { echo "Refusing to overwrite existing report" >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-personalization-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
script/build_test_runner.sh "$STAGE/runner" -O
NEWS_TEST_ATOM=Tests/EditorialPersonalizationTests.swift NEWS_PERSONALIZATION_OUTPUT="$OUTPUT" \
    NEWS_EDITORIAL_BUILD_CONFIGURATION=Release "$STAGE/runner"
