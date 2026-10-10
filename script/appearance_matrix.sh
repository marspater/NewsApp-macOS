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
sed '/^@main$/d' Sources/App/NewsApp.swift > "$STAGE/NewsApp.swift"
sed '/^@main$/d' Tests/LiveVoiceOverQAHarness.swift > "$STAGE/LiveVoiceOverQAFixtures.swift"
SOURCES=()
while IFS= read -r source; do
    if [[ "$source" != "Sources/App/NewsApp.swift" ]]; then SOURCES+=("$source"); fi
done < <(find Sources -name '*.swift' -print | sort)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
echo "Compiling appearance matrix (arm64, macOS 15 deployment target)..."
swiftc -swift-version 6 -Onone -parse-as-library -target arm64-apple-macos15.0 \
    "${SOURCES[@]}" "$STAGE/NewsApp.swift" "$STAGE/LiveVoiceOverQAFixtures.swift" Tests/NativeAppearanceMatrix.swift \
    -o "$STAGE/news_appearance_matrix"
"$STAGE/news_appearance_matrix" "$OUTPUT"
echo "Appearance renders: $OUTPUT"
