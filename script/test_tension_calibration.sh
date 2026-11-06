#!/bin/bash
# Tension calibration: the Python dataset verification, then the Tests/TensionCalibrationTests.swift job a plain
# ./test.sh runs, on its own.
set -e

cd "$(dirname "$0")/.."
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-tension-tests.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

echo "=== 1. Running Python Calibration and Dataset Verification ==="
python3 script/evaluation/calibrate_tension.py

echo "=== 2. Compiling Native Tension Calibration Test Suite ==="
script/build_test_runner.sh "$STAGE/runner"

echo "=== 3. Executing Native Tension Calibration Tests ==="
NEWS_TEST_ATOM=Tests/TensionCalibrationTests.swift "$STAGE/runner" "$@"
echo "=== Tension Calibration Verification Complete ==="
