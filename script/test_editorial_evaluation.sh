#!/bin/bash
# Opt-in local-only evaluation of novelty, event momentum and MMR primitives.
# Writes aggregate metrics to docs/benchmarks by default; no real library is opened.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUTPUT="\${1:-docs/benchmarks/$(date -u +%F)-editorial-evaluation.json}"
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac

WORK="$(mktemp -d "\${TMPDIR:-/tmp}/news-editorial-evaluation.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

script/build_test_runner.sh "$WORK/test_runner" -O

NEWS_TEST_ATOM=Tests/BriefingSignalsTests.swift \
NEWS_EDITORIAL_EVALUATION=1 \
NEWS_EDITORIAL_OUTPUT="$OUTPUT" \
"$WORK/test_runner"

test -s "$OUTPUT"
printf 'Editorial evaluation written to %s\n' "$OUTPUT"
