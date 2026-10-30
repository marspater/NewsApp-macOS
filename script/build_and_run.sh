#!/bin/bash
# Builds News.app and launches it. By default the build uses the development bundle id
# com.marspater.news.dev, so it runs in its own sandbox container with its own library and settings;
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
BUILT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' News.app/Contents/Info.plist)
if [[ "$BUILT_ID" != "$BUNDLE_ID" ]]; then
    echo "❌ Built News.app has bundle id $BUILT_ID, expected $BUNDLE_ID; not launching." >&2
    exit 1
fi

APP="$PWD/News.app"
# Close the previous reader only after a successful build. The development build closes only itself, never the
# installed app; the real-library build closes every News so two processes never share the real container.
if [[ "$BUNDLE_ID" == "com.marspater.news" ]]; then
    pkill -x News 2>/dev/null || true
else
    pkill -f "^$APP/Contents/MacOS/News" 2>/dev/null || true
fi
echo "Launching News.app (bundle id: $BUNDLE_ID)..."
open -n "$APP"
case "$MODE" in
    --verify)
        sleep 2
        pgrep -f "^$APP/Contents/MacOS/News"
        ;;
    --debug) lldb -p "$(pgrep -nf "^$APP/Contents/MacOS/News")" ;;
    --logs | --telemetry) log stream --info --predicate 'subsystem == "com.marspater.news"' ;;
    run) ;;
esac
