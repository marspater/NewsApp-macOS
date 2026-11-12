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
#   --bundle-id <id>          Build under another isolated bundle id, so a team's runs keep their own container
#                             and library (default com.marspater.news.isolatedqa; NEWS_ISOLATED_BUNDLE_ID)
#   --name-suffix <text>      Append the text to the app's name in the menu bar, Dock and app switcher, so
#                             parallel builds are easy to tell apart (e.g. "Z view"; NEWS_ISOLATED_NAME_SUFFIX)
#   --background              Launch without bringing the app to the front (open -g), for checks driven in the
#                             background while the Mac is in use

cd "$(dirname "$0")/.."
BUNDLE_ID="${NEWS_ISOLATED_BUNDLE_ID:-com.marspater.news.isolatedqa}"
NAME_SUFFIX="${NEWS_ISOLATED_NAME_SUFFIX:-}"
SEED=0
OPEN_FLAGS=(-n)
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed) SEED=1 ;;
        --background) OPEN_FLAGS+=(-g) ;;
        --bundle-id) BUNDLE_ID="${2:?--bundle-id needs a value}"; shift ;;
        --name-suffix) NAME_SUFFIX="${2:?--name-suffix needs a value}"; shift ;;
        *) EXTRA_ARGS+=("$1") ;;
    esac
    shift
done
# Only an isolated identifier: never the real app's or the development build's container (case-insensitive on APFS).
BUNDLE_ID_LOWER=$(printf '%s' "$BUNDLE_ID" | tr '[:upper:]' '[:lower:]')
if [[ ! "$BUNDLE_ID" =~ ^com\.marspater\.news\.[A-Za-z0-9]+$ || "$BUNDLE_ID_LOWER" == "com.marspater.news.dev" ]]; then
    echo "❌ --bundle-id must be com.marspater.news.<name>, not the development build's: $BUNDLE_ID" >&2
    exit 1
fi
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
LIBRARY_DIR="$CONTAINER/Library/Application Support/com.marspater.news"
# A run cannot delete its own stage (the app keeps running from it), so drop earlier
# stages whose app has quit. Resolve with pwd -P: the app runs from /private/var, not /var.
for old in "${TMPDIR:-/tmp}"/news-isolated-build.*; do
    # Only real directories this user owns: bash 3.2 keeps an unmatched glob as a literal,
    # and in a shared /tmp a symlink or another user's folder is not ours to delete.
    [[ -d "$old" && ! -L "$old" && -O "$old" ]] || continue
    old=$(cd "$old" && pwd -P) || continue
    re=$(printf '%s' "$old" | sed 's/[]\.*^$+?(){}|[]/\\&/g') # pgrep -f takes a regex
    pgrep -qf "^$re/src/News.app/Contents/MacOS/News" && continue
    # Drop the Launch Services record first; a stale one makes macOS call News damaged.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$old/src/News.app" 2>/dev/null || true
    rm -rf "$old"
done
STAGE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/news-isolated-build.XXXXXX")" && pwd -P)

echo "Building isolated News.app (bundle ID: ${BUNDLE_ID}) in ${STAGE}..."
APP="$STAGE/src/News.app"
NEWS_BUNDLE_ID="$BUNDLE_ID" NEWS_APP_DIR="$APP" ./build.sh >/dev/null
if [[ -n "$NAME_SUFFIX" ]]; then
    plutil -replace CFBundleName -string "News $NAME_SUFFIX" "$APP/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "News $NAME_SUFFIX" "$APP/Contents/Info.plist"
    # The plist is sealed by the signature: sign again as build.sh does.
    codesign --force --options runtime --entitlements News.entitlements --sign - "$APP"
fi

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
open "${OPEN_FLAGS[@]}" -a "$APP" --args ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

echo "Isolated News.app launched successfully (PID: $(pgrep -f "^$APP/Contents/MacOS/News" | tail -1 || echo 'unknown'))."
echo "Staged app: ${APP}"
echo "Isolated container: ${CONTAINER}"
echo "To terminate: pkill -f \"$APP/Contents/MacOS/News\""
