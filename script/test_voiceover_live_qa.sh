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
APP="$NEWS_VOICEOVER_OUTPUT/News VoiceOver QA.app"

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
# The fixtures and the QA entry point as a harness app with its own identifier (build.sh, NewsHarness target).
NEWS_HARNESS="Tests/Harness/LiveVoiceOverQAHarness.swift Tests/Harness/LiveVoiceOverQAEntry.swift" \
    NEWS_BUNDLE_ID=com.marspater.news.voiceoverqa NEWS_APP_DIR="$APP" run_bounded 300 ./build.sh
echo "QA bundle and render evidence: $NEWS_VOICEOVER_OUTPUT"
DEADLINE=120
# Manual mode is an intentional interactive session; closing its window cleans up fixture state.
if [[ "$MODE" == "--manual" ]]; then DEADLINE=0; fi
run_bounded "$DEADLINE" "$APP/Contents/MacOS/NewsHarness" "$MODE"
