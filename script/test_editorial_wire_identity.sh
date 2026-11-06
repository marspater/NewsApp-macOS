#!/bin/bash
# Opt-in wire identity coverage and momentum replay over a copy of a library; the report holds aggregates only.
# Back up first: sqlite3 "file:<library>?mode=ro" ".backup '<copy>'", then pragma journal_mode=delete on the copy.
# It also reviews the schema upgrade on a second private copy. NEWS_WIRE_IDENTITY_FETCH_FEEDS=1 fetches the copy's
# subscribed feeds once, as a refresh would, and measures the rows those feeds still serve with their authors.
set -euo pipefail
cd "$(dirname "$0")/.."
LIBRARY="${1:?Usage: script/test_editorial_wire_identity.sh LIBRARY_COPY [OUTPUT_DIR]}"
if [[ "$(cd "$(dirname "$LIBRARY")" && pwd -P)" == */Library/Containers/* ]]; then
    echo "Refusing a live library; pass a copy: $LIBRARY" >&2
    exit 1
fi
OUTPUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/news-wire-identity-results.XXXXXX")}"
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"
[[ ! -e "$OUTPUT/wire-identity.json" ]] || { echo "Refusing to overwrite $OUTPUT/wire-identity.json" >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-wire-identity-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
python3 -m script.evaluation.wire_identity_inputs --database "$LIBRARY" --output "$STAGE/inputs.json"
if [[ "${NEWS_WIRE_IDENTITY_FETCH_FEEDS:-}" == 1 ]]; then
    mkdir -m 700 "$STAGE/feeds"
    export NEWS_WIRE_IDENTITY_FEEDS="$STAGE/feeds"
    index=0
    fetched=0
    while IFS= read -r url; do
        index=$((index + 1))
        if curl -fsSL --proto '=http,https' --proto-redir '=http,https' --max-time 20 --max-filesize 16777216 \
            -A Mozilla/5.0 -o "$STAGE/feeds/$index.xml" -- "$url"; then
            fetched=$((fetched + 1))
        else
            rm -f "$STAGE/feeds/$index.xml"
        fi
    done < <(sqlite3 -readonly "$LIBRARY" "SELECT url FROM feeds ORDER BY url")
    echo "Fetched $fetched of $index feeds"
fi
mkdir -m 700 "$STAGE/migration"
cp "$LIBRARY" "$STAGE/migration/news.sqlite3"
script/build_test_runner.sh "$STAGE/runner" -O
NEWS_TEST_ATOM=Tests/EditorialWireIdentityTests.swift NEWS_WIRE_IDENTITY_INPUT="$STAGE/inputs.json" \
    NEWS_WIRE_IDENTITY_OUTPUT="$OUTPUT/wire-identity.json" NEWS_WIRE_IDENTITY_MIGRATE="$STAGE/migration/news.sqlite3" \
    "$STAGE/runner"
