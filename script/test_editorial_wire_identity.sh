#!/bin/bash
# Opt-in wire identity coverage and momentum replay over a copy of a library; the report holds aggregates only.
# Back up first: sqlite3 "file:<library>?mode=ro" ".backup '<copy>'", then pragma journal_mode=delete on the copy.
set -euo pipefail
cd "$(dirname "$0")/.."
LIBRARY="${1:?Usage: script/test_editorial_wire_identity.sh LIBRARY_COPY [OUTPUT_DIR]}"
if [[ "$(realpath "$LIBRARY")" == */Library/Containers/* ]]; then
    echo "Refusing a live library; pass a copy: $LIBRARY" >&2
    exit 1
fi
OUTPUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/news-wire-identity-results.XXXXXX")}"
if [[ ! -d "$OUTPUT" ]]; then
    mkdir -p "$OUTPUT"
    chmod 700 "$OUTPUT"
fi
[[ ! -e "$OUTPUT/wire-identity.json" ]] || { echo "Refusing to overwrite $OUTPUT/wire-identity.json" >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-wire-identity-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
python3 -m script.evaluation.wire_identity_inputs --database "$LIBRARY" --output "$STAGE/inputs.json"
script/build_test_runner.sh "$STAGE/runner" -O
NEWS_TEST_ATOM=Tests/EditorialWireIdentityTests.swift NEWS_WIRE_IDENTITY_INPUT="$STAGE/inputs.json" \
    NEWS_WIRE_IDENTITY_OUTPUT="$OUTPUT/wire-identity.json" "$STAGE/runner"
