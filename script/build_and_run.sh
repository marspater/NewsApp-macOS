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

APP="$PWD/News.app"
if [[ "$BUNDLE_ID" == "com.marspater.news" ]]; then
    ./build.sh
else
    # Same build with the development id, written straight to its own bundle so a --real-library launch from this
    # checkout keeps its News.app and is never matched by the process lookups below. The container-migration plist
    # stays out so the first launch can't move a pre-sandbox library into the development container.
    APP="$PWD/News Dev.app"
    BUILD_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/news-dev-build.XXXXXX")
    trap 'rm -f "$BUILD_SCRIPT"' EXIT
    # The last sed program matches build.sh's literal ${APP_NAME}; nothing in it should expand.
    # shellcheck disable=SC2016
    sed -e "s|<string>com.marspater.news</string>|<string>$BUNDLE_ID</string>|" \
        -e "s|^cp container-migration.plist |cp |" \
        -e 's|^APP_DIR="${APP_NAME}.app"$|APP_DIR="News Dev.app"|' build.sh >"$BUILD_SCRIPT"
    bash "$BUILD_SCRIPT"
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
# Close the previous reader only after a successful build. The real-library build closes every running app with the
# real bundle id, wherever its bundle is, so two processes never share the real container; the development build
# closes only its own bundle. Neither touches another worktree's development build.
OLD_PIDS=()
if [[ "$BUNDLE_ID" == "com.marspater.news" ]]; then
    while IFS= read -r pid; do
        executable=$(ps -o comm= -p "$pid" || true)
        id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${executable%/Contents/MacOS/News}/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$id" == "$BUNDLE_ID" ]]; then OLD_PIDS+=("$pid"); fi
    done < <(pgrep -x News || true)
else
    while IFS= read -r pid; do OLD_PIDS+=("$pid"); done < <(pgrep -f "$PROCESS_PATTERN" || true)
fi
# macOS bash 3.2 treats an empty array as unbound under `set -u`.
for pid in ${OLD_PIDS[@]+"${OLD_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
done
# Launch only once they have exited, so the process lookup below can't pick up the previous instance.
for pid in ${OLD_PIDS[@]+"${OLD_PIDS[@]}"}; do
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "❌ The previous News process $pid did not exit; not launching." >&2
        exit 1
    fi
done
echo "Launching $(basename "$APP") (bundle id: $BUNDLE_ID)..."
open -n "$APP"
[[ "$MODE" == run ]] && exit 0
# The process this run launched; --real-library and development launches can run side by side.
for _ in 1 2 3 4 5; do
    PID=$(pgrep -nf "$PROCESS_PATTERN") && break
    sleep 1
done
[[ -n "$PID" ]] || {
    echo "❌ $(basename "$APP") did not start." >&2
    exit 1
}
case "$MODE" in
    --verify) echo "$PID" ;;
    --debug) lldb -p "$PID" ;;
    *) log stream --info --predicate "subsystem == \"com.marspater.news\" AND processIdentifier == $PID" ;;
esac
