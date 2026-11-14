#!/bin/bash
# Opt-in 500-vector ranking controls; no model loading or production feed changes. Beside ranking.json it leaves
# lead-arms-fixture.json: the three Lead arms of #999 on the constructed fixture, a harness smoke result and no
# measure of real news. The acceptance run on a snapshot is `script/today_lead.sh arms`.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-ranking-results.XXXXXX")}"
mkdir -p "$OUTPUT"
for name in ranking.json lead-arms-fixture.json; do
    [[ ! -e "$OUTPUT/$name" ]] || { echo "Refusing to overwrite $OUTPUT/$name" >&2; exit 1; }
done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-ranking-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
script/build_test_runner.sh "$STAGE/runner" -O
NEWS_TEST_ATOM=Tests/EditorialRankingTests.swift NEWS_RANKING_OUTPUT="$OUTPUT/ranking.json" \
    NEWS_EDITORIAL_BUILD_CONFIGURATION=Release "$STAGE/runner"
