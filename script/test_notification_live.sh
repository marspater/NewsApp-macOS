#!/bin/bash
# Opt-in: real News notifications, synthetic stories, in-memory SQLite and temporary preferences.
# Reuses existing notification authorization; never changes permissions or the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-notification-results.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-notification-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
rsync -a --exclude .git --exclude .antigravity --exclude .claude --exclude .build --exclude '*.app' ./ "$STAGE/src/"
# Resolve the same static dependencies from the source checkout, avoiding a fresh download for each audit build.
python3 - "$STAGE/src/script/swiftpm_dependencies.sh" "$ROOT" <<'PY_DEPS'
import pathlib,shlex,sys
path=pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('swift build ', 'swift build --package-path '+shlex.quote(sys.argv[2])+' '))
PY_DEPS
sed -i '' '/^@main$/d' "$STAGE/src/Sources/App/NewsApp.swift"
sed -i '' 's|Sources/App/NewsApp.swift \\|Sources/App/NewsApp.swift Tests/NativeNotificationQA.swift Tests/TestDefaults.swift \\|' "$STAGE/src/build.sh"
(cd "$STAGE/src" && ./build.sh > "$OUTPUT/build.log" 2>&1)
codesign --verify --deep --strict "$STAGE/src/News.app"
"$STAGE/src/News.app/Contents/MacOS/News" > "$OUTPUT/runtime.log" 2>&1
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
