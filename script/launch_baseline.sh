#!/bin/bash
set -euo pipefail

# Launch the production app bundle repeatedly against a seeded 10,000-story library and record time to the
# first story card and process memory. The bundle is rebuilt under a separate identifier, so its sandbox
# container, database and preferences are distinct from the installed app; the real library is never opened.
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUNDLE_ID="com.marspater.news.launchcheck"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
LIBRARY_DIR="$CONTAINER/Library/Application Support/com.marspater.news"
LAUNCHES="${NEWS_LAUNCHES:-5}"
OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/news-launch-results.XXXXXX")}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
STAGE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/news-launch-build.XXXXXX")" && pwd -P) # pgrep sees the resolved /private path
APP_PID=""
STREAM_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
    [[ -n "$STREAM_PID" ]] && kill "$STREAM_PID" 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

# Feeds point at a reserved .invalid host, so a refresh fails locally; notifications and AI stay off.
LAUNCH_ARGS=(-saved_feed_urls '("https://launch.invalid/feed.xml")' -notifications_enabled NO -ai_enabled NO)

rsync -a --exclude .git --exclude .antigravity --exclude .claude --exclude '*.app' "$ROOT/" "$STAGE/src/"
sed -i '' "s|<string>com.marspater.news</string>|<string>$BUNDLE_ID</string>|" "$STAGE/src/build.sh"
(cd "$STAGE/src" && ./build.sh >/dev/null)
APP="$STAGE/src/News.app"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") == "$BUNDLE_ID" ]]
EXECUTABLE="$APP/Contents/MacOS/News"

wait_for_exit() {
    for _ in $(seq 1 200); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.05; done
    kill -KILL "$1" 2>/dev/null || true
}

# One launch: returns after the first card is logged, memory is sampled and the app has quit.
launch_once() {
    local index="$1" log="$OUTPUT/launch-$1.ndjson"
    log stream --level info --style ndjson \
        --predicate "subsystem == \"com.marspater.news\" AND category == \"Launch\"" > "$log" 2>/dev/null &
    STREAM_PID=$!
    sleep 1
    python3 -c 'import time; print(f"{time.time():.6f}")' > "$OUTPUT/launch-$index.start"
    open -n -a "$APP" --args "${LAUNCH_ARGS[@]}"
    for _ in $(seq 1 600); do
        grep -q "First card visible" "$log" && break
        sleep 0.05
    done
    APP_PID=$(pgrep -f "^$EXECUTABLE" | head -1)
    grep -q "First card visible" "$log" || { echo "No first card within 30 s (launch $index)" >&2; exit 1; }
    vmmap --summary "$APP_PID" > "$OUTPUT/launch-$index.first-card.vmmap" 2>&1 || true
    sleep "${NEWS_SETTLE_SECONDS:-5}"
    vmmap --summary "$APP_PID" > "$OUTPUT/launch-$index.settled.vmmap" 2>&1 || true
    kill "$APP_PID"; wait_for_exit "$APP_PID"; APP_PID=""
    kill "$STREAM_PID" 2>/dev/null || true; wait "$STREAM_PID" 2>/dev/null || true; STREAM_PID=""
}

# The first launch creates the isolated sandbox container; its library is then replaced by the seeded one.
if [[ ! -d "$LIBRARY_DIR" ]]; then
    open -n -a "$APP" --args "${LAUNCH_ARGS[@]}"
    for _ in $(seq 1 600); do [[ -e "$LIBRARY_DIR/news.sqlite3" ]] && break; sleep 0.05; done
    sleep 2
    APP_PID=$(pgrep -f "^$EXECUTABLE" | head -1)
    kill "$APP_PID"; wait_for_exit "$APP_PID"; APP_PID=""
fi
rm -f "$LIBRARY_DIR"/news.sqlite3*
./test.sh --seed-launch-library "$STAGE/news.sqlite3" | tail -1
cp "$STAGE/news.sqlite3" "$LIBRARY_DIR/news.sqlite3"

for index in $(seq 1 "$LAUNCHES"); do launch_once "$index"; done

python3 - "$OUTPUT" "$LAUNCHES" <<'PY'
import datetime, json, platform, re, subprocess, sys
out, launches = sys.argv[1], int(sys.argv[2])
def footprint(path, label):
    text = open(path).read()
    match = re.search(rf"^{re.escape(label)}:\s+([\d.]+)([KMG])", text, re.M)
    return round(float(match[1]) * {"K": 1 / 1024, "M": 1, "G": 1024}[match[2]], 3) if match else None
samples = []
for i in range(1, launches + 1):
    start = float(open(f"{out}/launch-{i}.start").read())
    line = next(json.loads(l) for l in open(f"{out}/launch-{i}.ndjson") if "First card visible" in l)
    logged = datetime.datetime.strptime(line["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f")
    offset = line["timestamp"][26:]
    logged = logged.replace(tzinfo=datetime.timezone(datetime.timedelta(hours=int(offset[:3]), minutes=int(offset[0] + offset[3:]))))
    samples.append({
        "launch": i,
        "process_start_to_first_card_ms": float(re.search(r"ms_since_process_start=([\d.]+)", line["eventMessage"])[1]),
        "open_to_first_card_ms": round((logged.timestamp() - start) * 1000, 3),
        "footprint_at_first_card_mib": footprint(f"{out}/launch-{i}.first-card.vmmap", "Physical footprint"),
        "footprint_settled_mib": footprint(f"{out}/launch-{i}.settled.vmmap", "Physical footprint"),
        "footprint_peak_mib": footprint(f"{out}/launch-{i}.settled.vmmap", "Physical footprint (peak)"),
    })
report = {"library_stories": 10000, "launches": samples,
          "settle_seconds_before_memory_sample": 5,
          "macos": platform.mac_ver()[0],
          "hardware": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize", "hw.model"], capture_output=True, text=True).stdout.split("\n")[:3]}
json.dump(report, open(f"{out}/launch-baseline.json", "w"), indent=2)
print(json.dumps(report, indent=2))
PY
echo "Launch evidence: $OUTPUT"
