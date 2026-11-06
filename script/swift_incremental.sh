#!/bin/bash
# Source from the repository root. news_swift_compile NAME OUTPUT [swiftc flags and sources...] runs swiftc
# incrementally (#1020): objects, dependency records and the output-file map live under build/incremental/NAME-KEY,
# where KEY hashes the flags, so a changed flag (-D NEWS_SENTRY, -O, the target) gets its own cache and an unchanged
# file is never recompiled. The source list is read from the arguments; every *.swift argument is a source.
# NEWS_CLEAN_BUILD=1 removes the cache first. CI runners start empty, so they always build from scratch.
# Flags and non-Swift inputs key the cache; a linked archive (the SwiftPM dependencies) also by its modification time,
# so a rebuilt dependency gets a fresh cache. Other files named by flags (the App Intents protocol list) are rewritten
# on every build and key by path only.
news_swift_cache_key() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        *.swift) ;;
        *.a)
            printf '%s\n' "$arg"
            [ -e "$arg" ] && stat -f '%m' "$arg"
            ;;
        *) printf '%s\n' "$arg" ;;
        esac
    done | shasum -a 256 | cut -c1-12
}

news_swift_compile() {
    local name="$1" output="$2"
    shift 2
    local arg key dir map extra="" args=()
    # A caller's own output-file map (App Intents const values) is merged into the one written here, per source.
    while [ $# -gt 0 ]; do
        if [ "$1" = "-output-file-map" ]; then
            extra="$2"
            shift 2
        else
            args+=("$1")
            shift
        fi
    done
    set -- "${args[@]}"
    key=$(news_swift_cache_key "$@")
    dir="build/incremental/$name-$key"
    [ "${NEWS_CLEAN_BUILD:-0}" = 1 ] && rm -rf "$dir"
    mkdir -p "$dir"
    map="$dir/output-file-map.json"
    {
        printf '{"": {"swift-dependencies": "%s/main.swiftdeps"}' "$dir"
        for arg in "$@"; do
            case "$arg" in
            *.swift)
                # The object is named after the path, so two files with one basename cannot collide.
                local stem="${arg//\//_}"
                printf ',\n"%s": {"object": "%s/%s.o", "swift-dependencies": "%s/%s.swiftdeps"}' \
                    "$arg" "$dir" "${stem%.swift}" "$dir" "${stem%.swift}"
                ;;
            esac
        done
        printf '\n}\n'
    } > "$map"
    if [ -n "$extra" ]; then
        python3 -I - "$map" "$extra" <<'PY'
import json, sys
own, extra = (json.load(open(path)) for path in sys.argv[1:3])
for key, outputs in extra.items():
    own.setdefault(key, {}).update(outputs)
json.dump(own, open(sys.argv[1], "w"), indent=1)
PY
    fi
    # NEWS_SWIFT_INCREMENTAL_DEBUG=1 prints the driver's decision for every file.
    local debug=()
    [ "${NEWS_SWIFT_INCREMENTAL_DEBUG:-0}" = 1 ] && debug=(-driver-show-incremental)
    swiftc -incremental "${debug[@]}" -output-file-map "$map" "$@" -o "$output"
}
