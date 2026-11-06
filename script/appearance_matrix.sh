#!/bin/bash
set -euo pipefail

# Offline renders of the fixture list, grid, reader and overview in light, dark and
# increased-contrast window appearances. Reuses the VoiceOver fixture library; needs
# no Accessibility permission and never touches the installed app or system settings.
cd "$(dirname "$0")/.."
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-appearance.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-appearance-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
echo "Compiling appearance matrix (arm64, macOS 15 deployment target)..."
NEWS_HARNESS="Tests/Harness/LiveVoiceOverQAHarness.swift Tests/Harness/NativeAppearanceMatrix.swift" \
    NEWS_APP_DIR="$STAGE/NewsHarness.app" ./build.sh
"$STAGE/NewsHarness.app/Contents/MacOS/NewsHarness" "$OUTPUT"
echo "Appearance renders: $OUTPUT"
