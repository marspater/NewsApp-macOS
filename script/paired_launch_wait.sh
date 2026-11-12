#!/bin/bash
# Wait for the launch log to report the fresh edition, without changing the memory checkpoint.
read_fresh_launch_log() {
    local started="$1" pid="$2"
    /usr/bin/log show --start "$started" --info --predicate \
        "subsystem == \"com.marspater.news\" AND category == \"Launch\" AND processIdentifier == $pid" \
        2>/dev/null || true
}

wait_for_fresh_edition() {
    local started="$1" pid="$2" expected="$3" lines
    local deadline=$((SECONDS + ${NEWS_PAIRED_SWAP_WAIT:-60}))
    while ((SECONDS <= deadline)); do
        kill -0 "$pid" 2>/dev/null || return 1
        lines=$(read_fresh_launch_log "$started" "$pid")
        if [[ "$lines" == *"today_fresh_edition_ready outcome="* ]]; then
            [[ "$expected" == any || "$lines" == *"today_fresh_edition_ready outcome=swapped "* ]]
            return $?
        fi
        sleep 1
    done
    return 1
}
