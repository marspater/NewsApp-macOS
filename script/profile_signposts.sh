#!/bin/bash
# Records the app's os_signpost intervals with xctrace on a fixed workload and summarizes them (#577).
# Run by .github/workflows/profile.yml on a schedule; it launches the app, so it is not for a developer's Mac.
#   $1                      output directory (default: a new temporary directory)
#   PROFILE_DRY_RUN=1       build and prepare everything, print the xctrace command, stop before launching the app
#   PROFILE_TIME_LIMIT      recording length (default 60s)
#   PROFILE_RUN_ID          library suffix (default: GITHUB_RUN_ID or the current time)
# Workload: the Debug app as com.marspater.news.dev, its own library (NEWS_LIBRARY_NAME=profile-<run id>) and every
# subscription answered from Tests/Fixtures/ui-smoke/feed.xml (NEWS_FIXTURE_FEED, development bundle only).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=com.marspater.news.dev
TIME_LIMIT="${PROFILE_TIME_LIMIT:-60s}"
RUN_ID="${PROFILE_RUN_ID:-${GITHUB_RUN_ID:-$(date +%s)}}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9-]+$ ]] || { echo "❌ PROFILE_RUN_ID must be letters, digits and dashes" >&2; exit 1; }
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-profile.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
APP="$OUTPUT/News.app"

NEWS_CONFIGURATION=Debug NEWS_BUNDLE_ID="$BUNDLE_ID" NEWS_APP_DIR="$APP" NEWS_SENTRY_DISABLED=1 ./build.sh \
    > "$OUTPUT/build.log" 2>&1 || { tail -40 "$OUTPUT/build.log" >&2; exit 1; }

# Never record the real app: its container holds the user's library.
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [[ "$ACTUAL_ID" != "$BUNDLE_ID" ]]; then
    echo "❌ Built bundle is $ACTUAL_ID, expected $BUNDLE_ID; refusing to launch" >&2
    exit 1
fi

FEED=$(sed "s/{{PUBDATE}}/$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')/" Tests/Fixtures/ui-smoke/feed.xml | tr -d '\n')
RECORD=(xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --time-limit "$TIME_LIMIT"
    --no-prompt --output "$OUTPUT/News.trace"
    --env "NEWS_LIBRARY_NAME=profile-$RUN_ID" --env "NEWS_FIXTURE_FEED=$FEED"
    --launch -- "$APP/Contents/MacOS/News"
    # Argument-domain defaults, as NewsSmokeUITests: no onboarding, no notification prompt, one subscription.
    -first_launch_completed YES -notifications_enabled NO -saved_feed_urls '("https://example.com/ui-smoke/feed.xml")')

if [[ "${PROFILE_DRY_RUN:-0}" == 1 ]]; then
    printf '%q ' "${RECORD[@]/#NEWS_FIXTURE_FEED=*/NEWS_FIXTURE_FEED=<feed>}"; echo
    echo "Dry run: stopped before launching the app"
    exit 0
fi

# xctrace exits non-zero when the time limit ends the launched process; the trace is still complete.
STATUS=0
"${RECORD[@]}" || STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    [[ -d "$OUTPUT/News.trace" ]] || { echo "❌ xctrace exited $STATUS and wrote no trace" >&2; exit 1; }
    echo "xctrace exited $STATUS; using the trace it wrote (expected when the time limit ends the app)" >&2
fi
# The table of contents names every exported table, so a renamed schema shows up in the artifact.
xcrun xctrace export --input "$OUTPUT/News.trace" --toc --output "$OUTPUT/toc.xml"
xcrun xctrace export --input "$OUTPUT/News.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-interval"]' \
    --output "$OUTPUT/signposts.xml"
python3 script/summarize_signposts.py "$OUTPUT/signposts.xml" "$OUTPUT/summary" \
    --meta "revision=$(git rev-parse HEAD)" "time_limit=$TIME_LIMIT" \
    "hardware=$(sysctl -n hw.model)" "os=$(sw_vers -productVersion)" "xcode=$(xcodebuild -version | head -1)" "xctrace_exit=$STATUS"
echo "Signpost profile: $OUTPUT"
