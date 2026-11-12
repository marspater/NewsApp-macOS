#!/bin/bash
# Paired launches for Today's first card and its memory (#937): each arm's app starts on the same library copy,
# restored before every launch, in an order that rotates by round. It opens the app in a window, so it runs only
# when the Mac is free for a measurement (docs/audits/2026-11-07-build-measurement-protocol.md); never in CI.
#   script/paired_launch.sh OUT ROUNDS arm=/path/News.app [arm=/path/News.app ...]
# Arms; script/summarize_launches.py counts a launch only when its log shows the arm's state:
#   baseline  a build before the Today edition
#   cold      nothing stored: the page waits for the lane assignment
#   warm      the edition stored by a seeding launch on the same copy: the page shows it at once
#   swap      that edition with one lane row reversed, so the fresh edition differs and takes the untouched page
# An arm may carry a label after an underscore (cold_integration=/path/News.app) to run one kind on several builds;
# NEWS_PAIRED_ARGS_<arm> holds further launch arguments for that arm ("-today_window_pool YES"). A warm or swap arm
# is seeded by a launch of its own app.
# Every app is a Profile build (always com.marspater.news.dev); the library is a copy named by NEWS_LIBRARY_NAME in
# the development container, so neither the development library nor the real one is opened. The container's
# settings and caches are the development build's own and are shared by every arm.
#   NEWS_PAIRED_LIBRARY    the copy every launch starts from (required): a SQLite backup, never a library in use
#   NEWS_PAIRED_SETTLE     seconds from launch to the memory sample (default 20)
#   NEWS_PAIRED_HOLD=1     after the sample, wait for Return and sample again as "scrolled": for scrolling by hand
#   NEWS_PAIRED_SWAP_WAIT  maximum seconds to wait for a fresh edition after the scheduled sample (default 60)
#   NEWS_PAIRED_MAX_LOAD   refuse to start above this one-minute load average (default 2.5)
set -euo pipefail
[[ $# -ge 3 ]] || { sed -n '2,17p' "$0" >&2; exit 2; }
cd "$(dirname "$0")/.."
OUT=$1 ROUNDS=$2
shift 2
BUNDLE_ID=com.marspater.news.dev
NAME=""
NAME_DIR=""
LIB="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/com.marspater.news"
PRISTINE="${NEWS_PAIRED_LIBRARY:?Set NEWS_PAIRED_LIBRARY to the library copy every launch starts from}"
SETTLE="${NEWS_PAIRED_SETTLE:-20}"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ && "$SETTLE" =~ ^[1-9][0-9]*$ && "${NEWS_PAIRED_SWAP_WAIT:-60}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "❌ ROUNDS, NEWS_PAIRED_SETTLE and NEWS_PAIRED_SWAP_WAIT must be positive integers." >&2; exit 2; }
LOCK=/tmp/news-measure.lock # shared with script/measure_build.sh: one measurement per Mac

ARMS=() APPS=()
for spec in "$@"; do
    arm=${spec%%=*} app=${spec#*=}
    [[ "$arm" =~ ^(baseline|cold|warm|swap)(_[a-z0-9]+)?$ ]] || { echo "❌ Unknown arm $arm" >&2; exit 2; }
    # ${ARMS[*]-}: macOS bash 3.2 treats an empty array as unbound under `set -u`.
    [[ " ${ARMS[*]-} " != *" $arm "* ]] || { echo "❌ Arm $arm is named twice" >&2; exit 2; }
    app=$(cd "$app" && pwd -P)
    # Never the real app: its container holds the reader's library.
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    [[ "$id" == "$BUNDLE_ID" ]] || { echo "❌ $app is $id, expected $BUNDLE_ID; refusing to launch" >&2; exit 1; }
    ARMS+=("$arm") APPS+=("$app")
done
[[ -f "$PRISTINE" && -d "$LIB" ]] || { echo "❌ Missing $PRISTINE or the development container's library folder" >&2; exit 1; }
# Anchored, so the shell of a session that waits for a free Mac with these words in its command does not match.
if pgrep -f '[x]codebuild -project|^/bin/bash \./test\.sh' >/dev/null; then
    echo "❌ A build or test run is active; not measuring." >&2
    exit 1
fi
if pgrep -x News >/dev/null; then echo "❌ A News app is running; quit it first." >&2; exit 1; fi
LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
if awk -v load="$LOAD" -v limit="${NEWS_PAIRED_MAX_LOAD:-2.5}" 'BEGIN { exit !(load > limit) }'; then
    echo "❌ Load average $LOAD: the Mac is not idle." >&2
    exit 1
fi
# Refuse nonempty output directories: a previous run's files must not pollute the current sample.
# Do all output setup before locking, so failure leaves the shared lock untouched.
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
if [[ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "❌ $OUT is not empty; choose a fresh output directory." >&2
    exit 1
fi
chmod 700 "$OUT" # stored editions can contain a sentence of a report

PID=""
quit() {
    [[ -n "$PID" ]] || return 0
    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 200); do kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
}
cleanup() {
    quit
    # Delete only this invocation's randomly named working library.
    if [[ -n "$NAME" ]]; then rm -f "$LIB/$NAME.sqlite3"*; fi
    if [[ -n "$NAME_DIR" ]]; then rmdir "$NAME_DIR" 2>/dev/null || true; fi
    rmdir "$LOCK" 2>/dev/null || true # last, after owned working files are removed
}

mkdir "$LOCK" 2>/dev/null || { echo "❌ Another measurement holds $LOCK." >&2; exit 1; }
trap cleanup EXIT
NAME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/paired-launch-XXXXXX")
NAME=${NAME_DIR##*/}

# Starts the app on a fresh copy of the library, with the given stored edition beside it or none.
launch() { # <app> <stored edition or ""> <arm>
    local extra="NEWS_PAIRED_ARGS_$3"
    rm -f "$LIB/$NAME.sqlite3"*
    cp "$PRISTINE" "$LIB/$NAME.sqlite3"
    [[ -z "$2" ]] || cp "$2" "$LIB/$NAME.sqlite3.today-edition.json"
    # The executable directly, as xctrace launches it: the environment is certain to reach it. The arm's further
    # arguments are split on spaces on purpose.
    # shellcheck disable=SC2086
    NEWS_LIBRARY_NAME="$NAME" "$1/Contents/MacOS/News" -first_launch_completed YES -notifications_enabled NO \
        ${!extra-} >/dev/null 2>&1 &
    PID=$!
    disown "$PID" # no "Terminated" line from the shell when the launch is ended
    sleep "$SETTLE"
    # lsof can exit non-zero beside a complete listing, so its output is read, not its status.
    [[ "$(lsof -p "$PID" 2>/dev/null || true)" == *"/$NAME.sqlite3"* ]] \
        || { echo "❌ The app did not open the $NAME library; stopping." >&2; exit 1; }
}

index_of() { # <arm>; prints its position or nothing
    for i in "${!ARMS[@]}"; do [[ "${ARMS[$i]}" != "$1" ]] || { echo "$i"; return; }; done
}

# Each warm or swap arm starts from the edition a seeding launch of its own app stored on the same copy.
for i in "${!ARMS[@]}"; do
    arm=${ARMS[$i]}
    [[ "${arm%%_*}" == warm || "${arm%%_*}" == swap ]] || continue
    launch "${APPS[$i]}" "" "$arm"
    quit
    cp "$LIB/$NAME.sqlite3.today-edition.json" "$OUT/seed-$arm.today-edition.json" \
        || { echo "❌ The seeding launch of $arm stored no edition; that arm cannot run." >&2; exit 1; }
    [[ "${arm%%_*}" == swap ]] || continue
    python3 - "$OUT/seed-$arm.today-edition.json" <<'PY'
import json, sys
edition = json.load(open(sys.argv[1]))
row = next((lane for lane in edition["lanes"]
            if lane["lane"] not in ("The Lead", "The Latest") and len(lane["stories"]) > 1), None)
if row is None:
    sys.exit("No lane row with two stories to reverse for the swap arm")
row["stories"].reverse()
json.dump(edition, open(sys.argv[1], "w"))
PY
done

# Sample swap memory only once the actual fresh-edition swap has been logged for this process.
wait_for_fresh_edition() { # <launch start> <pid> <any|swapped>
    local started="$1" pid="$2" expected="$3" lines
    local deadline=$((SECONDS + ${NEWS_PAIRED_SWAP_WAIT:-60}))
    while ((SECONDS <= deadline)); do
        kill -0 "$pid" 2>/dev/null || return 1
        lines=$(/usr/bin/log show --start "$started" --info --predicate \
            "subsystem == \"com.marspater.news\" AND category == \"Launch\" AND processIdentifier == $pid" \
            2>/dev/null || true)
        if [[ "$lines" == *"today_fresh_edition_ready outcome="* ]]; then
            [[ "$expected" == any || "$lines" == *"today_fresh_edition_ready outcome=swapped "* ]]
            return $?
        fi
        sleep 1
    done
    return 1
}

one() { # <round> <arm> <app>
    local stem="$OUT/r$1-$2" stored="" start
    case "${2%%_*}" in warm | swap) stored="$OUT/seed-$2.today-edition.json" ;; esac
    sleep 2
    sysctl -n vm.loadavg | awk '{print $2}' > "$stem.load"
    start=$(date -v-2S '+%Y-%m-%d %H:%M:%S')
    launch "$3" "$stored" "$2"
    local can_sample=1
    if [[ "${2%%_*}" == swap ]] && ! wait_for_fresh_edition "$start" "$PID" swapped; then
        echo "⚠️ Round $1 $2: no observed swap; skipping post-swap memory." >&2
        can_sample=0
    fi
    if [[ "$can_sample" == 1 ]]; then
        footprint -p "$PID" > "$stem.settled.footprint" 2>&1 || true
        if [[ "${NEWS_PAIRED_HOLD:-0}" == 1 ]]; then
            read -r -p "Round $1 $2: scroll as planned, then press Return " _
            footprint -p "$PID" > "$stem.scrolled.footprint" 2>&1 || true
        fi
    fi
    if [[ "${2%%_*}" == warm ]] && ! wait_for_fresh_edition "$start" "$PID" any; then
        echo "⚠️ Round $1 $2: no fresh-edition result observed before timeout or app exit." >&2
    fi
    /usr/bin/log show --start "$start" --info --predicate \
        "subsystem == \"com.marspater.news\" AND category == \"Launch\" AND processIdentifier == $PID" \
        > "$stem.log" 2>/dev/null
    quit
    echo "round $1 $2: $(sed -n 's/.*\(First card visible .*\)/\1/p' "$stem.log" | head -1)"
}

COUNT=${#ARMS[@]}
for round in $(seq 1 "$ROUNDS"); do
    for step in $(seq 0 $((COUNT - 1))); do
        i=$(((round - 1 + step) % COUNT))
        one "$round" "${ARMS[$i]}" "${APPS[$i]}"
    done
done

python3 script/summarize_launches.py "$OUT" --meta "script_revision=$(git rev-parse HEAD)" "rounds=$ROUNDS" \
    "settle_seconds=$SETTLE" "hardware=$(sysctl -n hw.model)" "os=$(sw_vers -productVersion)" \
    "load_at_start=$LOAD"
echo "Paired launches: $OUT"
