#!/bin/bash
# Opt-in: real News notifications, synthetic stories, in-memory SQLite and temporary preferences.
# Reuses existing notification authorization; never changes permissions or the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-notification-results.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-notification-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# The installed app's identifier, so the existing notification authorization applies.
NEWS_HARNESS=Tests/Harness/NativeNotificationQA.swift NEWS_HARNESS_SANDBOX=1 NEWS_BUNDLE_ID=com.marspater.news \
    NEWS_APP_DIR="$STAGE/NewsHarness.app" ./build.sh > "$OUTPUT/build.log" 2>&1
codesign --verify --deep --strict "$STAGE/NewsHarness.app"
"$STAGE/NewsHarness.app/Contents/MacOS/NewsHarness" > "$OUTPUT/runtime.log" 2>&1
python3 - "$OUTPUT" <<'PY'
import json,pathlib,sys
out=pathlib.Path(sys.argv[1])
line=next(s for s in (out/'runtime.log').read_text().splitlines() if s.startswith('NOTIFICATION_QA_REPORT='))
report=json.loads(line.split('=',1)[1])
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
assert report['delivered']>0 and report['withImage']==1 and report['destinationMatches']
assert report['lookupStarted'] < report['deliveredObserved']
print(json.dumps(report,indent=2))
PY
