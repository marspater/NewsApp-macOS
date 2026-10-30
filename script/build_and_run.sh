#!/bin/bash
# Builds News.app and launches it. By default the build uses the development bundle id
# com.marspater.news.dev (as "News Dev.app"), so it runs in its own sandbox container with its own library and settings;
# --real-library builds with the installed app's id and opens the real library (and migrates it).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.marspater.news.dev"
MODE=run
for arg in "$@"; do
    case "$arg" in
        --real-library) BUNDLE_ID="com.marspater.news" ;;
        --verify | --debug | --logs | --telemetry) MODE="$arg" ;;
        *)
            echo "Usage: $0 [--real-library] [--verify|--debug|--logs|--telemetry]" >&2
            exit 2
            ;;
    esac
done

if [[ "$BUNDLE_ID" == "com.marspater.news" ]]; then
    ./build.sh
else
    # Same build with the development id; the container-migration plist stays out so the first launch can't move
    # a pre-sandbox library into the development container.
    BUILD_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/news-dev-build.XXXXXX")
    trap 'rm -f "$BUILD_SCRIPT"' EXIT
    sed -e "s|<string>com.marspater.news</string>|<string>$BUNDLE_ID</string>|" \
        -e "s|^cp container-migration.plist |cp |" build.sh >"$BUILD_SCRIPT"
    bash "$BUILD_SCRIPT"
fi
APP="$PWD/News.app"
if [[ "$BUNDLE_ID" != "com.marspater.news" ]]; then
    # Its own bundle path, so the process lookups below never reach a --real-library launch from this checkout.
    APP="$PWD/News Dev.app"
    rm -rf "$APP"
    mv News.app "$APP"
fi
BUILT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [[ "$BUILT_ID" != "$BUNDLE_ID" ]]; then
    echo "❌ Built $(basename "$APP") has bundle id $BUILT_ID, expected $BUNDLE_ID; not launching." >&2
    exit 1
fi

# pgrep and pkill take a regular expression; escape the path so a folder such as "News (copy)" still matches.
# The sed program is literal on purpose: nothing in it should expand.
# shellcheck disable=SC2016
PROCESS_PATTERN="^$(printf '%s' "$APP/Contents/MacOS/News" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
# Close the previous reader only after a successful build. The development build closes only itself, never the
# installed app; the real-library build closes every News so two processes never share the real container.
if [[ "$BUNDLE_ID" == "com.marspater.news" ]]; then
    pkill -x News 2>/dev/null || true
else
    pkill -f "$PROCESS_PATTERN" 2>/dev/null || true
fi
echo "Launching $(basename "$APP") (bundle id: $BUNDLE_ID)..."
open -n "$APP"
case "$MODE" in
    --verify)
        sleep 2
        pgrep -f "$PROCESS_PATTERN"
        ;;
    --debug) lldb -p "$(pgrep -nf "$PROCESS_PATTERN")" ;;
    --logs | --telemetry) log stream --info --predicate 'subsystem == "com.marspater.news"' ;;
    *) ;; # run: launch only
esac
