#!/bin/bash
set -euo pipefail

# Compile the real views with a separate AppKit entry point, without invoking the app delegate,
# notification authorization, production singletons, or the installed bundle.
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-native-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-native-results.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
sed '/^@main$/d' Sources/App/NewsApp.swift > "$STAGE/NewsApp.swift"
SOURCES=()
while IFS= read -r source; do
    if [[ "$source" != "Sources/App/NewsApp.swift" ]]; then SOURCES+=("$source"); fi
done < <(find Sources -name '*.swift' -print | sort)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macos15.0 \
    "${SOURCES[@]}" "$STAGE/NewsApp.swift" Tests/NativePerformanceBaseline.swift -o "$STAGE/news_native_baseline"
"$STAGE/news_native_baseline" "$OUTPUT"
echo "Native performance evidence: $OUTPUT"
