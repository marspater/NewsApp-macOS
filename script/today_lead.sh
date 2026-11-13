#!/bin/bash
# Library snapshots and reader packs for the blind Lead comparison (#934). Protocol: docs/TOOLING.md.
#
#   script/today_lead.sh snapshot [--day YYYY-MM-DD] [--real-library]
#       Copies the development library (com.marspater.news.dev) through a read-only connection into
#       ~/news-eval/today-lead-snapshots/<day>/, with the subscription list and a manifest holding the clock.
#       The source is never written. --real-library reads the installed app's library instead; only I pass it.
#   script/today_lead.sh pack [--day YYYY-MM-DD]
#       Runs the shadow harness on a copy of that day's snapshot and leaves the private key
#       (lead-rankings-private.json), the aggregate report and the blind sheet (lead-review-private.csv) beside it.
#       NEWS_TODAY_POOL (default page: the pool the app assigns from) and NEWS_TODAY_PAGES pass through.
#   script/today_lead.sh arms [--day YYYY-MM-DD]
#       The three-arm comparison of #999 (current, base, base+mmr) on the same snapshot and pool: leaves the key,
#       the aggregate lead-arms-report.json and the blind sheet in <day>/arms/, beside any pack of that day.
#       NEWS_LEAD_ARMS_DEPTH, NEWS_LEAD_ARMS_RELEVANCE_WEIGHT, NEWS_LEAD_ARMS_DECAY_SECONDS and
#       NEWS_LEAD_ARMS_MOMENTUM_CLOCK pass through (Tests/EditorialRankingEvaluation.swift).
#
# A day's folder is never overwritten. Nothing here schedules itself.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="${NEWS_LEAD_SNAPSHOTS:-$HOME/news-eval/today-lead-snapshots}"
COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
BUNDLE="com.marspater.news.dev"
DAY="$(date +%F)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --real-library) BUNDLE="com.marspater.news" ;;
        --day) DAY="${2:?--day needs YYYY-MM-DD}"; shift ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "--day needs YYYY-MM-DD" >&2; exit 2; }
DIR="$ROOT/$DAY"
umask 077

case "$COMMAND" in
    snapshot)
        DATA="$HOME/Library/Containers/$BUNDLE/Data/Library"
        LIBRARY="$DATA/Application Support/com.marspater.news/news.sqlite3"
        PREFERENCES="$DATA/Preferences/$BUNDLE.plist"
        [[ -f "$LIBRARY" && -f "$PREFERENCES" ]] || { echo "No library or settings for $BUNDLE" >&2; exit 1; }
        [[ ! -e "$DIR" ]] || { echo "$DIR exists; a day's snapshot is never overwritten" >&2; exit 1; }
        mkdir -p "$ROOT"
        STAGE="$(mktemp -d "$ROOT/.snapshot-$DAY.XXXXXX")"
        trap 'rm -rf "$STAGE"' EXIT
        CLOCK="$(date +%s)"
        # A consistent copy, the write-ahead log included, through a connection that cannot write the source.
        sqlite3 "file:${LIBRARY// /%20}?mode=ro" "VACUUM INTO '$STAGE/library.sqlite3';"
        plutil -extract saved_feed_urls json -o - "$PREFERENCES" \
            | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)))' > "$STAGE/feeds.txt"
        python3 - "$STAGE" "$DAY" "$BUNDLE" "$CLOCK" <<'PY'
import json, sqlite3, sys
directory, day, bundle, clock = sys.argv[1:]
db = sqlite3.connect(f'file:{directory}/library.sqlite3?mode=ro', uri=True)
stories, newest = db.execute('SELECT count(*), max(published_at) FROM articles').fetchone()
manifest = {'day': day, 'bundle': bundle, 'clock': int(clock), 'stories': stories, 'newestStory': newest,
            'storiesLast72h': db.execute('SELECT count(*) FROM articles WHERE published_at >= ?', (int(clock) - 259200,)).fetchone()[0],
            'schemaVersion': db.execute('PRAGMA user_version').fetchone()[0],
            'subscribedFeeds': sum(1 for line in open(f'{directory}/feeds.txt') if line.strip())}
json.dump(manifest, open(f'{directory}/manifest.json', 'w'), indent=2, sort_keys=True)
print(json.dumps(manifest, sort_keys=True))
PY
        chmod 400 "$STAGE/library.sqlite3" "$STAGE/feeds.txt" "$STAGE/manifest.json"
        [[ ! -e "$DIR" ]] || { echo "$DIR exists; a day's snapshot is never overwritten" >&2; exit 1; }
        mv "$STAGE" "$DIR"
        trap - EXIT
        echo "Snapshot in $DIR. Next: script/today_lead.sh pack --day $DAY"
        ;;
    pack | arms)
        [[ -f "$DIR/library.sqlite3" && -f "$DIR/manifest.json" ]] || { echo "No snapshot in $DIR" >&2; exit 1; }
        if [[ "$COMMAND" == arms ]]; then
            [[ ! -e "$DIR/arms" ]] || { echo "$DIR/arms already holds a three-arm pack" >&2; exit 1; }
        else
            [[ ! -e "$DIR/lead-rankings-private.json" && ! -e "$DIR/lead-review-private.csv" ]] \
                || { echo "$DIR already holds a pack" >&2; exit 1; }
        fi
        WORK="$(mktemp -d "/private/tmp/today-lead-$DAY.XXXXXX")"
        STAGE="$(mktemp -d "$DIR/.$COMMAND.XXXXXX")"
        trap 'rm -rf "$WORK" "$STAGE"' EXIT
        cp "$DIR/library.sqlite3" "$WORK/library.sqlite3"
        chmod 600 "$WORK/library.sqlite3"
        # The clock is the newest story's date, as in the Z2 audits: a library last refreshed hours before the
        # snapshot is judged at its own "now". A story dated after the snapshot (#981) does not move it.
        NEWS_TODAY_NOW="$(python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); print(min(m["clock"], int(m["newestStory"])))' "$DIR/manifest.json")" \
        NEWS_TODAY_FEEDS="$DIR/feeds.txt" NEWS_TODAY_POOL="${NEWS_TODAY_POOL:-page}" \
        NEWS_LEAD_ARMS="$([[ "$COMMAND" == arms ]] && echo 1 || echo 0)" \
            ./test.sh --today-shadow "$WORK/library.sqlite3" "$WORK/out" > "$WORK/run.log" 2>&1 \
            || { tail -20 "$WORK/run.log" >&2; exit 1; }
        if [[ "$COMMAND" == arms ]]; then
            cp "$WORK/out/arms/lead-rankings-private.json" "$WORK/out/arms/lead-arms-report.json" "$STAGE/"
            python3 script/evaluation/lead_review.py sheet "$STAGE"
            mv "$STAGE" "$DIR/arms"
            echo "Each reader fills a copy of $DIR/arms/lead-review-private.csv named lead-review-private-<reader>.csv"
            exit 0
        fi
        cp "$WORK/out/lead-rankings-private.json" "$WORK/out/shadow-report.json" "$STAGE/"
        python3 script/evaluation/lead_review.py sheet "$STAGE"
        mv "$STAGE/lead-rankings-private.json" "$STAGE/shadow-report.json" "$STAGE/lead-review-private.csv" "$DIR/"
        rmdir "$STAGE"
        echo "Each reader fills a copy of $DIR/lead-review-private.csv named lead-review-private-<reader>.csv"
        ;;
    *)
        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
