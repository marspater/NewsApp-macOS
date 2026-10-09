#!/bin/bash
set -euo pipefail

# Runs an isolated build of News.app with an isolated sandbox container,
# isolated SQLite database, and isolated preferences.
#
# Allows verifying VoiceOver, Increase Contrast, Reduce Motion, and Text Scaling
# through system settings overrides without altering global macOS system preferences.
#
# Usage:
#   ./script/run_isolated.sh [OPTIONS]
#
# Options:
#   --increase-contrast       Simulate Increase Contrast
#   --reduce-motion           Simulate Reduce Motion
#   --voice-over              Simulate VoiceOver
#   --text-scale <scale>      Set reader text scale (e.g. 1.2, 1.5)
#   --seed                    Seed isolated library with sample events and stories

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUNDLE_ID="com.marspater.news.isolatedqa"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
LIBRARY_DIR="$CONTAINER/Library/Application Support/com.marspater.news"
STAGE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/news-isolated-build.XXXXXX")" && pwd -P)

SEED=0
EXTRA_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--seed" ]]; then
        SEED=1
    else
        EXTRA_ARGS+=("$arg")
    fi
done

echo "Staging isolated build in ${STAGE}..."
rsync -a --exclude .git --exclude .antigravity --exclude .claude --exclude '*.app' "$ROOT/" "$STAGE/src/"
sed -i '' "s|<string>com.marspater.news</string>|<string>$BUNDLE_ID</string>|" "$STAGE/src/build.sh"

echo "Building isolated News.app (bundle ID: ${BUNDLE_ID})..."
(cd "$STAGE/src" && ./build.sh >/dev/null)
APP="$STAGE/src/News.app"

# Prepare isolated library directory
mkdir -p "$LIBRARY_DIR"
if [[ $SEED -eq 1 ]]; then
    echo "Seeding isolated library with test fixtures..."
    ./test.sh --seed-launch-library "$STAGE/news.sqlite3" | tail -1
    # A WAL left by an earlier killed run would replay onto the fresh library and corrupt it.
    rm -f "$LIBRARY_DIR/news.sqlite3-wal" "$LIBRARY_DIR/news.sqlite3-shm"
    cp "$STAGE/news.sqlite3" "$LIBRARY_DIR/news.sqlite3"
fi

echo "Launching isolated News.app with arguments: ${EXTRA_ARGS[*]:-(default)}..."
# macOS bash 3.2 treats an empty array as unbound under `set -u`.
open -n -a "$APP" --args ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

echo "Isolated News.app launched successfully (PID: $(pgrep -f "^$APP/Contents/MacOS/News" | tail -1 || echo 'unknown'))."
echo "Staged app: ${APP}"
echo "Isolated container: ${CONTAINER}"
echo "To terminate: pkill -f \"$APP/Contents/MacOS/News\""
