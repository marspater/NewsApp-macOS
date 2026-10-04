#!/bin/bash
set -euo pipefail

# Isolated production views. --live requires Accessibility access; speech/rotor traversal is manual.
cd "$(dirname "$0")/.."
MODE="${1:---live}"
case "$MODE" in --live|--smoke|--manual|--self-test) ;; *) echo "Usage: $0 [--live|--smoke|--manual|--self-test]" >&2; exit 2 ;; esac
export NEWS_VOICEOVER_OUTPUT="${NEWS_VOICEOVER_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/news-vo-results.XXXXXX")}"
mkdir -p "$NEWS_VOICEOVER_OUTPUT"
NEWS_VOICEOVER_OUTPUT=$(cd "$NEWS_VOICEOVER_OUTPUT" && pwd)
export NEWS_VOICEOVER_OUTPUT
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-vo-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$NEWS_VOICEOVER_OUTPUT/News VoiceOver QA.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.marspater.news.voiceoverqa</string>
<key>CFBundleName</key><string>News VoiceOver QA</string>
<key>CFBundleExecutable</key><string>news_vo_live_qa</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
sed '/^@main$/d' Sources/App/NewsApp.swift > "$STAGE/NewsApp.swift"
SOURCES=()
while IFS= read -r source; do
    if [[ "$source" != "Sources/App/NewsApp.swift" ]]; then SOURCES+=("$source"); fi
done < <(find Sources -name '*.swift' -print | sort)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

# A process-group watchdog bounds compilation and runtime, including stuck AX calls and child hosts.
run_bounded() {
    python3 - "$@" <<'PY'
import os, signal, subprocess, sys
seconds = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    code = process.wait(timeout=seconds if seconds else None)
except subprocess.TimeoutExpired:
    print(f"VoiceOver QA exceeded its {seconds}-second deadline; stopping its test process group.", file=sys.stderr)
    code = 124
except KeyboardInterrupt:
    code = 130
finally:
    # The group belongs solely to this invocation; include any child left behind by a crashed inspector.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
sys.exit(code if code >= 0 else 128 - code)
PY
}
echo "Compiling VoiceOver QA (arm64, macOS 15 deployment target)..."
run_bounded 300 swiftc -swift-version 6 -warnings-as-errors -Onone -parse-as-library -target arm64-apple-macos15.0 \
    "${SOURCES[@]}" "$STAGE/NewsApp.swift" Tests/LiveVoiceOverQAHarness.swift -o "$STAGE/news_vo_live_qa"
cp "$STAGE/news_vo_live_qa" "$APP/Contents/MacOS/news_vo_live_qa"
codesign --force --sign - "$APP"
echo "QA bundle and render evidence: $NEWS_VOICEOVER_OUTPUT"
DEADLINE=120
# Manual mode is an intentional interactive session; closing its window cleans up fixture state.
if [[ "$MODE" == "--manual" ]]; then DEADLINE=0; fi
run_bounded "$DEADLINE" "$APP/Contents/MacOS/news_vo_live_qa" "$MODE"
