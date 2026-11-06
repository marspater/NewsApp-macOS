#!/bin/bash
# Opt-in 500-vector ranking controls; no model loading or production feed changes.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-ranking-results.XXXXXX")}"
mkdir -p "$OUTPUT"
[[ ! -e "$OUTPUT/ranking.json" ]] || { echo "Refusing to overwrite $OUTPUT/ranking.json" >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-ranking-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
script/build_test_runner.sh "$STAGE/runner" -O
NEWS_TEST_ATOM=Tests/EditorialRankingTests.swift NEWS_RANKING_OUTPUT="$OUTPUT/ranking.json" \
    NEWS_EDITORIAL_BUILD_CONFIGURATION=Release "$STAGE/runner"
