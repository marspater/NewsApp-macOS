#!/bin/bash
# Opt-in retrospective momentum evaluation; all inputs and databases are synthetic and isolated.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-momentum-results.XXXXXX")}"
mkdir -p "$OUTPUT"
[[ ! -e "$OUTPUT/momentum.json" ]] || { echo "Refusing to overwrite $OUTPUT/momentum.json" >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-momentum-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
python3 -m script.evaluation.editorial_matrix --database "$STAGE/fixture.sqlite3" --output "$STAGE/matrix.json"
python3 -m script.evaluation.momentum_inputs --database "$STAGE/fixture.sqlite3" --output "$STAGE/inputs.json"
script/build_test_runner.sh "$STAGE/runner" -O
NEWS_TEST_ATOM=Tests/EditorialMomentumTests.swift NEWS_MOMENTUM_INPUT="$STAGE/inputs.json" \
    NEWS_MOMENTUM_OUTPUT="$OUTPUT/momentum.json" NEWS_EDITORIAL_BUILD_CONFIGURATION=Release "$STAGE/runner"
